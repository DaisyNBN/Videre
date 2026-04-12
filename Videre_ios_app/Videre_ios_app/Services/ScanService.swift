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
    /// Position change threshold: 3.0 meters (only capture when user walks much further).
    private let positionChangeThreshold: Float = 3.0
    /// Dedupe ARKit mesh landmarks (meters).
    private var arkitLandmarkCentroids: [simd_float3] = []
    private let arkitLandmarkMinSpacing: Float = 1.0

    // ── Current camera position & rotation tracking ──────────
    // used for adding landmarks
    private(set) var currentPosition: simd_float3 = .zero
    private var lastKeyframePosition: simd_float3 = .zero
    private var lastKeyframeCacheClearTime: Date = Date()

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
        lastKeyframeCacheClearTime = Date()
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
        guard isScanning else { return }

        let t   = frame.camera.transform
        currentPosition = simd_float3(
            t.columns.3.x,
            t.columns.3.y,
            t.columns.3.z
        )

        let now = frame.timestamp

        // Always record trajectory points for better LiDAR coverage
        if now - lastPointTime >= POINT_INTERVAL {
            lastPointTime = now
            addPoint(frame: frame)
        }

        // Capture keyframes only when position changes or user rotates 180 degrees
        let cameraRotation = simd_quatf(frame.camera.transform)
        if shouldCaptureNewKeyframe(
            newPosition: currentPosition,
            newRotation: cameraRotation,
            lastTime: lastKeyframeTime,
            now: now) {
            lastKeyframeTime = now
            lastKeyframePosition = currentPosition

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
        
        // Always capture for first keyframe
        if keyframes.isEmpty {
            return true
        }

        // Check position change (3.0 meters threshold)
        // ONLY trigger on significant physical movement, ignore rotation entirely
        let positionDiff = simd_distance(
            lastKeyframePosition,
            newPosition)
        if positionDiff >= positionChangeThreshold {
            print("New keyframe: position changed by \(positionDiff)m")
            return true
        }

        // Check time-based fallback (every 5 seconds at most)
        // AND check 5-hour cache expiration restriction
        let cacheExpired = Date().timeIntervalSince(lastKeyframeCacheClearTime) >= imageCacheExpiration
        if now - lastTime >= KEYFRAME_INTERVAL && cacheExpired {
            print("New keyframe: timeout reached and cache valid")
            return true
        }

        // If cache has expired but time hasn't reached interval, still allow capture
        if cacheExpired && now - lastTime >= (KEYFRAME_INTERVAL / 2.0) {
            print("New keyframe: cache expired - allowing update")
            return true
        }

        return false
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
        ScanPayload(
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
            keyframes:      keyframes,
            depthSamples:   depthSamples,
            sequenceNumber: sequenceNumber,
            checksum:       buildChecksum(),
            offlineSync:    false,
            retryCount:     retryCount,
            idempotencyKey: "\(scanId)_\(sequenceNumber)"
        )
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
            guard let (startNodeId, endNodeId) = selectRouteNodes(from: graph.nodes) else {
                finalStatus = "Map created, but graph has insufficient nodes for routing"
                await MainActor.run {
                    uploadStatus = finalStatus
                    isUploading = false
                    sequenceNumber += 1
                }
                return
            }

            let routeId = try await APIService.shared.generateRoute(
                mapId: mapId,
                startNodeId: startNodeId,
                endNodeId: endNodeId
            )

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
