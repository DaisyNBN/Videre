//
//  ScanService.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation
import ARKit
import simd
import UIKit

class ScanService: NSObject, ObservableObject {

    static let shared = ScanService()

    // ── Published ─────────────────────────────────────
    @Published var isScanning:    Bool   = false
    @Published var pointCount:    Int    = 0
    @Published var landmarkCount: Int    = 0
    @Published var keyframeCount: Int    = 0
    @Published var uploadStatus:  String = ""
    @Published var isUploading:   Bool   = false
    @Published var backendScanId: String = ""
    @Published var backendMapId: String = ""
    @Published var backendRouteId: String = ""
    @Published var aiDetectionsCount: Int = 0
    @Published var mapLandmarks: [MapLandmarkRecord] = []
    @Published var mapActionStatus: String = ""

    // ── Session data ──────────────────────────────────
    private var scanId:         String            = ""
    private var userId:         String            = DeviceIdentity.userId
    private var roomName:       String            = ""
    private var startedAt:      Date              = Date()
    private var points:         [TrajectoryPoint] = []
    private var landmarks:      [Landmark]        = []
    private var keyframes:      [Keyframe]        = []
    private var depthSamples:   [DepthSample]     = []
    private var sequenceNumber: Int               = 0
    private var retryCount:     Int               = 0

    // ── Sampling intervals ────────────────────────────
    private var lastPointTime:    TimeInterval = 0
    private var lastKeyframeTime: TimeInterval = 0
    private var lastDepthTime:    TimeInterval = 0
    private var lastMeshLandmarkTime: TimeInterval = 0

    /// Camera pose samples for trajectory (1 Hz - one per second).
    let POINT_INTERVAL:    TimeInterval = 1.0
    /// Keyframes only when environment rotates significantly or every max interval.
    let KEYFRAME_INTERVAL: TimeInterval = 5.0
    let DEPTH_INTERVAL:    TimeInterval = 1.0
    private let meshLandmarkInterval: TimeInterval = 2.0
    /// Cache expiration: images older than 5 hours can be updated.
    private let imageCacheExpiration: TimeInterval = 5 * 60 * 60  // 5 hours in seconds
    /// Rotation threshold to trigger new keyframe: 15 degrees.
    private let rotationThresholdDegrees: Float = 15.0
    /// Position change threshold: 0.5 meters.
    private let positionChangeThreshold: Float = 0.5
    /// Hard image budget per scan to avoid excessive backend image analysis spend.
    private let maxImageKeyframesPerScan: Int = 24

    /// Dedupe ARKit mesh landmarks (meters).
    private var arkitLandmarkCentroids: [simd_float3] = []
    private let arkitLandmarkMinSpacing: Float = 1.0

    // ── Current camera position & rotation tracking ──────────
    // used for adding landmarks
    private(set) var currentPosition: simd_float3 = .zero
    private var lastKeyframePosition: simd_float3 = .zero
    private var lastKeyframeRotation: simd_quatf = simd_quatf()
    private var lastKeyframeCacheClearTime: Date = Date()
    private var didLogKeyframeBudgetReached = false

    // ── Start ─────────────────────────────────────────
    func startScan(
            roomName: String,
            userId: String = DeviceIdentity.userId) {
        self.scanId         = UUID().uuidString
        self.userId         = userId
        self.roomName       = roomName
        self.startedAt      = Date()
        self.points         = []
        self.landmarks      = []
        self.keyframes      = []
        self.depthSamples   = []
        self.sequenceNumber = 0
        self.retryCount     = 0
        arkitLandmarkCentroids = []
        lastPointTime          = 0
        lastKeyframeTime       = 0
        lastDepthTime          = 0
        lastMeshLandmarkTime   = 0
        lastKeyframePosition   = .zero
        lastKeyframeRotation   = simd_quatf()
        lastKeyframeCacheClearTime = Date()
        didLogKeyframeBudgetReached = false
        isScanning          = true
        pointCount          = 0
        landmarkCount       = 0
        keyframeCount       = 0
        uploadStatus        = "Scanning..."
        backendScanId       = ""
        backendMapId        = ""
        backendRouteId      = ""
        aiDetectionsCount   = 0
        mapLandmarks        = []
        mapActionStatus     = ""
        APIService.shared.clearActiveRouteContext()
    }

    // ── Stop and upload ───────────────────────────────
    func stopScan() {
        guard isScanning else { return }

        if landmarks.isEmpty {
            // Backend currently requires at least one landmark.
            let fallback = Landmark(
                type: "unknown",
                label: "auto-anchor",
                x: currentPosition.x,
                y: currentPosition.y,
                z: currentPosition.z,
                source: "user",
                timestamp: currentMs()
            )
            landmarks.append(fallback)
            landmarkCount = landmarks.count
        }

        isScanning   = false
        isUploading  = true
        uploadStatus = "Uploading scan..."

        Task {
            let payload = buildPayload(endedAt: Date())
            await upload(payload: payload)
        }
    }

    // ── Called from LiDARService every AR frame ────────
    func onARFrame(_ frame: ARFrame) {
        let t   = frame.camera.transform
        currentPosition = simd_float3(
            t.columns.3.x,
            t.columns.3.y,
            t.columns.3.z
        )

        guard isScanning else { return }

        let now = frame.timestamp

        // Always record trajectory points for better LiDAR coverage
        if now - lastPointTime >= POINT_INTERVAL {
            lastPointTime = now
            addPoint(frame: frame)
        }

        // Capture keyframes only when environment changes
        let cameraRotation = simd_quatf(frame.camera.transform)
        if shouldCaptureNewKeyframe(
            newPosition: currentPosition,
            newRotation: cameraRotation,
            lastTime: lastKeyframeTime,
            now: now) {
            lastKeyframeTime = now
            lastKeyframePosition = currentPosition
            lastKeyframeRotation = cameraRotation
            captureKeyframe(frame: frame)
        }

        // Check if cache has expired (5 hours)
        if Date().timeIntervalSince(lastKeyframeCacheClearTime) >= imageCacheExpiration {
            lastKeyframeCacheClearTime = Date()
            print("Keyframe cache expired - old images can be re-captured")
        }

        if now - lastDepthTime >= DEPTH_INTERVAL {
            lastDepthTime = now
            captureDepth(frame: frame)
        }

        if now - lastMeshLandmarkTime >= meshLandmarkInterval {
            lastMeshLandmarkTime = now
            addMeshClassificationLandmarks(frame: frame)
        }
    }

    // ── Determine if we should capture a new keyframe ─────────
    private func shouldCaptureNewKeyframe(
            newPosition: simd_float3,
            newRotation: simd_quatf,
            lastTime: TimeInterval,
            now: TimeInterval) -> Bool {

        if keyframes.count >= maxImageKeyframesPerScan {
            if !didLogKeyframeBudgetReached {
                didLogKeyframeBudgetReached = true
                print("Keyframe budget reached (\(maxImageKeyframesPerScan)); skipping additional image capture")
            }
            return false
        }
        
        // Always capture for first keyframe
        if keyframes.isEmpty {
            return true
        }

        // Check time-based fallback (every 5 seconds at most)
        if now - lastTime >= KEYFRAME_INTERVAL {
            return true
        }

        // Check rotation change (15 degrees threshold)
        let rotationDiff = rotationAngleDifference(
            lastKeyframeRotation,
            newRotation)
        if rotationDiff >= rotationThresholdDegrees {
            print("New keyframe: rotation changed by \(rotationDiff)°")
            return true
        }

        // Check position change (0.5 meters threshold)
        let positionDiff = simd_distance(
            lastKeyframePosition,
            newPosition)
        if positionDiff >= positionChangeThreshold {
            print("New keyframe: position changed by \(positionDiff)m")
            return true
        }

        return false
    }

    // ── Calculate angle between two rotations ─────────────────
    private func rotationAngleDifference(
            _ rot1: simd_quatf,
            _ rot2: simd_quatf) -> Float {
        let diff = simd_inverse(rot1) * rot2
        let angleRadians = 2.0 * acos(simd_clamp(diff.real, -1.0, 1.0))
        let angleDegrees = angleRadians * 180.0 / .pi
        return abs(angleDegrees)
    }

    // ── Add user landmark at current position ──────────
    func addLandmark(type: String, label: String) {
        let normalizedType = normalizedLandmarkType(type)
        let lm = Landmark(
            type:      normalizedType,
            label:     label,
            x:         currentPosition.x,
            y:         currentPosition.y,
            z:         currentPosition.z,
            source:    "user",
            timestamp: currentMs()
        )
        landmarks.append(lm)
        DispatchQueue.main.async {
            self.landmarkCount = self.landmarks.count
        }
        print("Landmark: \(label) at \(currentPosition)")
    }

    private func normalizedLandmarkType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "door":
            return "door"
        case "wall":
            return "wall"
        case "stair", "stairs":
            return "stair"
        case "elevator":
            return "elevator"
        case "obstacle", "hazard":
            return "obstacle"
        case "exit":
            return "exit"
        default:
            return "unknown"
        }
    }

    /// Door / wall / window from scene mesh classification (throttled).
    private func addMeshClassificationLandmarks(frame: ARFrame) {
        let hits = ARMeshLandmarkSampler.landmarksNearCamera(
            frame: frame,
            maxHits: 2)
        for hit in hits {
            appendARKitLandmarkIfSpaced(
                type: hit.type,
                label: hit.label,
                position: hit.position)
        }
    }

    private func appendARKitLandmarkIfSpaced(
            type: String,
            label: String,
            position: simd_float3) {
        for c in arkitLandmarkCentroids {
            if simd_distance(c, position) < arkitLandmarkMinSpacing {
                return
            }
        }
        arkitLandmarkCentroids.append(position)
        let normalizedType = normalizedLandmarkType(type)
        let lm = Landmark(
            type:      normalizedType,
            label:     label,
            x:         position.x,
            y:         position.y,
            z:         position.z,
            source:    "user",
            timestamp: currentMs()
        )
        landmarks.append(lm)
        DispatchQueue.main.async {
            self.landmarkCount = self.landmarks.count
        }
        print("ARKit landmark: \(label) at \(position)")
    }

    // ── Collect trajectory point (continuous LiDAR locations) ──
    private func addPoint(frame: ARFrame) {
        let t = frame.camera.transform
        let p = TrajectoryPoint(
            x:             t.columns.3.x,
            y:             t.columns.3.y,
            z:             t.columns.3.z,
            timestamp:     currentMs(),
            trackingState: trackingString(
                               frame.camera.trackingState)
        )
        points.append(p)
        DispatchQueue.main.async {
            self.pointCount = self.points.count
        }
    }

    // ── Capture keyframe image ────────────────────────
    private func captureKeyframe(frame: ARFrame) {
        guard keyframes.count < maxImageKeyframesPerScan else {
            return
        }

        let t     = frame.camera.transform
        let pose  = CameraPose(
            x: t.columns.3.x,
            y: t.columns.3.y,
            z: t.columns.3.z
        )
        let ts    = currentMs()
        let intr  = frame.camera.intrinsics

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let uiImg   = UIImage(ciImage: ciImage)
        guard let jpegData = uiImg.jpegData(compressionQuality: 0.5)
        else { return }
        let imageBase64 = jpegData.base64EncodedString()

        let kf = Keyframe(
            imageBase64: imageBase64,
            imageUrl:   nil,
            timestamp:  ts,
            cameraPose: pose,
            fx:         intr.columns.0.x,
            fy:         intr.columns.1.y,
            cx:         intr.columns.2.x,
            cy:         intr.columns.2.y
        )
        keyframes.append(kf)
        DispatchQueue.main.async {
            self.keyframeCount = self.keyframes.count
        }
    }

    // ── Capture depth sample ──────────────────────────
    private func captureDepth(frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap
        else { return }

        let t    = frame.camera.transform
        let pose = CameraPose(
            x: t.columns.3.x,
            y: t.columns.3.y,
            z: t.columns.3.z
        )
        let ts  = currentMs()

        let hasDepthData: Bool = {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }
            let height      = CVPixelBufferGetHeight(depthMap)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
            return height > 0 && bytesPerRow > 0
        }()
        guard hasDepthData else { return }

        let ds = DepthSample(
            timestamp:  ts,
            cameraPose: pose,
            depthUrl:   "local-depth://\(scanId)/\(ts).bin"
        )
        depthSamples.append(ds)
    }

    // ── Build payload ─────────────────────────────────
    private func buildPayload(endedAt: Date) -> ScanPayload {
        let keyframesForUpload = constrainedKeyframesForUpload()

        return ScanPayload(
            scanId:    scanId,
            userId:    userId,
            roomName:  roomName,
            startedAt: isoDate(startedAt),
            endedAt:   isoDate(endedAt),
            device: DeviceInfo(
                model:      deviceModel(),
                osVersion:  "iOS \(UIDevice.current.systemVersion)",
                appVersion: appVersion()
            ),
            arTrackingQuality: "good",
            coordinateSystem: CoordinateSystem(
                origin: "world",
                units:  "meters"
            ),
            points:         points,
            landmarks:      landmarks,
            keyframes:      keyframesForUpload,
            depthSamples:   depthSamples,
            sequenceNumber: sequenceNumber,
            checksum:       buildChecksum(),
            offlineSync:    false,
            retryCount:     retryCount,
            idempotencyKey: "\(scanId)_\(sequenceNumber)"
        )
    }

    private func constrainedKeyframesForUpload() -> [Keyframe] {
        guard keyframes.count > maxImageKeyframesPerScan else {
            return keyframes
        }

        let stride = max(
            1,
            Int(ceil(Double(keyframes.count) / Double(maxImageKeyframesPerScan)))
        )

        var sampled = keyframes.enumerated().compactMap { index, frame in
            index % stride == 0 ? frame : nil
        }

        if let last = keyframes.last,
           sampled.last?.timestamp != last.timestamp {
            sampled.append(last)
        }

        if sampled.count > maxImageKeyframesPerScan,
           let last = sampled.last {
            sampled = Array(sampled.prefix(maxImageKeyframesPerScan))
            sampled[sampled.count - 1] = last
        }

        return sampled
    }

    // ── Upload payload to backend API ─────────────────
    private func upload(payload: ScanPayload) async {
        guard let dict = payload.toDictionary()
        else {
            await MainActor.run {
                uploadStatus = "Build failed"
                isUploading  = false
            }
            return
        }

        var finalStatus = "Upload failed"
        var shouldIncrementRetry = false

        do {
            let result = try await APIService.shared
                .callFunction(
                    name:    "ingest-scan",
                    payload: dict
                )

            let success = result["success"] as? Bool ?? false
            if !success {
                finalStatus = "Upload failed"
                shouldIncrementRetry = true
                await MainActor.run {
                    isUploading = false
                    uploadStatus = finalStatus
                    retryCount += 1
                    sequenceNumber += 1
                }
                return
            }

            if Constants.apiDryRun || (result["dryRun"] as? Bool ?? false) {
                await MainActor.run {
                    backendScanId = "dry-run"
                    uploadStatus = "Dry run — manifest logged, not sent"
                    isUploading = false
                    sequenceNumber += 1
                }
                return
            }

            guard let scanData = result["data"] as? [String: Any],
                  let scanId = scanData["id"] as? String,
                  !scanId.isEmpty
            else {
                finalStatus = "Scan uploaded but no scan id returned"
                shouldIncrementRetry = true
                await MainActor.run {
                    isUploading = false
                    uploadStatus = finalStatus
                    retryCount += 1
                    sequenceNumber += 1
                }
                return
            }

            await MainActor.run {
                backendScanId = scanId
                uploadStatus = "Scan uploaded. Checking processing..."
            }

            let processing = try await APIService.shared.fetchScanProcessingStatus(scanId: scanId)
            await MainActor.run {
                uploadStatus = "Scan status: \(processing). Fetching detections..."
            }

            let detections = try await APIService.shared.fetchScanDetections(scanId: scanId)
            await MainActor.run {
                aiDetectionsCount = detections.count
                uploadStatus = "Detections: \(detections.count). Creating map..."
            }

            let mapId = try await APIService.shared.createMapFromScan(
                scanId: scanId,
                roomName: roomName
            )

            let syncedLandmarks = await syncMapLandmarks(mapId: mapId)
            let verificationSummary = try? await APIService.shared
                .fetchMapVerificationSummary(mapId: mapId)
            let pendingCount = verificationSummary?["pending"] as? Int ?? 0
            let verifiedCount = verificationSummary?["verified"] as? Int ?? 0

            await MainActor.run {
                backendMapId = mapId
                uploadStatus =
                    "Map created. Synced \(syncedLandmarks) landmarks " +
                    "(verified: \(verifiedCount), pending: \(pendingCount)). Building route..."
            }

            let fetchedMapLandmarks = try await APIService.shared.fetchMapLandmarks(mapId: mapId)
            await MainActor.run {
                mapLandmarks = fetchedMapLandmarks
            }

            let graph = try await APIService.shared.fetchMapGraph(mapId: mapId)
            let routeId: String
            if let coordinatePair = selectRouteCoordinates(from: points) {
                do {
                    routeId = try await APIService.shared.generateRouteFromCoordinates(
                        mapId: mapId,
                        startX: coordinatePair.start.x,
                        startY: coordinatePair.start.y,
                        startZ: coordinatePair.start.z,
                        endX: coordinatePair.end.x,
                        endY: coordinatePair.end.y,
                        endZ: coordinatePair.end.z
                    )
                } catch {
                    guard let (startNodeId, endNodeId) = selectRouteNodes(from: graph.nodes) else {
                        finalStatus = "Map created, but graph has insufficient nodes for routing"
                        await MainActor.run {
                            uploadStatus = finalStatus
                            isUploading = false
                            sequenceNumber += 1
                        }
                        return
                    }

                    await MainActor.run {
                        uploadStatus =
                            "Coordinate route failed, falling back to node route: \(error.localizedDescription)"
                    }

                    routeId = try await APIService.shared.generateRoute(
                        mapId: mapId,
                        startNodeId: startNodeId,
                        endNodeId: endNodeId
                    )
                }
            } else {
                guard let (startNodeId, endNodeId) = selectRouteNodes(from: graph.nodes) else {
                    finalStatus = "Map created, but graph has insufficient nodes for routing"
                    await MainActor.run {
                        uploadStatus = finalStatus
                        isUploading = false
                        sequenceNumber += 1
                    }
                    return
                }

                routeId = try await APIService.shared.generateRoute(
                    mapId: mapId,
                    startNodeId: startNodeId,
                    endNodeId: endNodeId
                )
            }

            await MainActor.run {
                backendRouteId = routeId
            }

            finalStatus = "Upload complete — map and route ready"
        } catch {
            finalStatus = "Error: \(error.localizedDescription)"
            shouldIncrementRetry = true
        }

        await MainActor.run {
            uploadStatus = finalStatus
            isUploading  = false
            if shouldIncrementRetry {
                retryCount += 1
            }
            sequenceNumber += 1
        }
    }

    private func selectRouteNodes(from nodes: [[String: Any]]) -> (String, String)? {
        let nodeIds = nodes.compactMap { $0["id"] as? String }
        guard !nodeIds.isEmpty else { return nil }

        let startNodeId = nodes.first {
            (($0["type"] as? String) ?? "").lowercased() == "start"
        }?["id"] as? String ?? nodeIds.first!

        let endNodeId = nodes.first {
            (($0["type"] as? String) ?? "").lowercased() == "end"
        }?["id"] as? String ?? nodeIds.last!

        if startNodeId != endNodeId {
            return (startNodeId, endNodeId)
        }

        if let alternateEnd = nodeIds.last(where: { $0 != startNodeId }) {
            return (startNodeId, alternateEnd)
        }

        return nil
    }

    private func selectRouteCoordinates(
            from points: [TrajectoryPoint],
            minimumDistanceMeters: Float = 1.0
    ) -> (
        start: (x: Double, y: Double, z: Double),
        end: (x: Double, y: Double, z: Double)
    )? {
        guard let startPoint = points.first else {
            return nil
        }

        let start = (
            x: Double(startPoint.x),
            y: Double(startPoint.y),
            z: Double(startPoint.z)
        )

        let endCandidate = points.reversed().first { point in
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            let dz = point.z - startPoint.z
            let distance = sqrt((dx * dx) + (dy * dy) + (dz * dz))
            return distance >= minimumDistanceMeters
        } ?? points.last

        guard let endPoint = endCandidate else {
            return nil
        }

        let end = (
            x: Double(endPoint.x),
            y: Double(endPoint.y),
            z: Double(endPoint.z)
        )

        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let dz = endPoint.z - startPoint.z
        let distance = sqrt((dx * dx) + (dy * dy) + (dz * dz))
        guard distance > 0.05 else {
            return nil
        }

        return (start: start, end: end)
    }

    @MainActor
    func refreshMapLandmarks() {
        guard !backendMapId.isEmpty else {
            mapActionStatus = "No map available yet"
            return
        }

        mapActionStatus = "Refreshing landmarks..."

        Task {
            do {
                let records = try await APIService.shared.fetchMapLandmarks(mapId: backendMapId)
                await MainActor.run {
                    mapLandmarks = records
                    mapActionStatus = "Loaded \(records.count) landmarks"
                }
            } catch {
                await MainActor.run {
                    mapActionStatus = "Failed to refresh landmarks: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    func verifyLandmark(
            landmarkId: String,
            approve: Bool,
            notes: String = ""
    ) {
        guard !backendMapId.isEmpty else {
            mapActionStatus = "No map available yet"
            return
        }

        let verificationStatus = approve ? "verified" : "rejected"
        mapActionStatus = "Submitting \(verificationStatus) verification..."

        Task {
            do {
                try await APIService.shared.verifyLandmark(
                    landmarkId: landmarkId,
                    status: verificationStatus,
                    notes: notes.isEmpty ? nil : notes
                )

                let records = try await APIService.shared.fetchMapLandmarks(mapId: backendMapId)
                await MainActor.run {
                    mapLandmarks = records
                    mapActionStatus = "Landmark marked as \(verificationStatus)"
                }
            } catch {
                await MainActor.run {
                    mapActionStatus = "Verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    func submitContribution(notes: String) {
        guard !backendMapId.isEmpty else {
            mapActionStatus = "No map available yet"
            return
        }

        mapActionStatus = "Submitting contribution..."

        let payload: [String: Any] = [
            "scanId": backendScanId,
            "routeId": backendRouteId,
            "landmarkCount": landmarks.count,
            "detectionCount": aiDetectionsCount,
            "note": notes,
        ]

        Task {
            do {
                let result = try await APIService.shared.createMapContribution(
                    mapId: backendMapId,
                    contributionType: "landmark_review",
                    payload: payload,
                    notes: notes
                )

                await MainActor.run {
                    mapActionStatus =
                        "Contribution submitted (id: \(result.contributionId), status: \(result.status))"
                }
            } catch {
                await MainActor.run {
                    mapActionStatus = "Contribution failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func syncMapLandmarks(mapId: String) async -> Int {
        var syncedCount = 0

        for landmark in landmarks.prefix(25) {
            do {
                _ = try await APIService.shared.createMapLandmark(
                    mapId: mapId,
                    type: landmark.type,
                    label: landmark.label,
                    x: landmark.x,
                    y: landmark.y,
                    z: landmark.z,
                    source: landmark.source
                )
                syncedCount += 1
            } catch {
                print("Landmark sync failed for \(landmark.label): \(error)")
            }
        }

        return syncedCount
    }

    // ── Helpers ───────────────────────────────────────
    private func currentMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func isoDate(_ date: Date) -> String {
        let f           = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(
                to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"]
            as? String ?? "0.0.1"
    }

    private func buildChecksum() -> String {
        String("\(scanId)\(points.count)".hashValue)
    }

    private func trackingString(
            _ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:                         return "good"
        case .limited(.initializing):         return "initializing"
        case .limited(.excessiveMotion):      return "limited"
        case .limited(.insufficientFeatures): return "limited"
        case .notAvailable:                   return "unavailable"
        default:                              return "limited"
        }
    }
}
