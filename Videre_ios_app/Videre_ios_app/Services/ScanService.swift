//
//  ScanService.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation
import ARKit
import CoreLocation
import simd
import UIKit

private struct AnchorReuseRecord: Codable {
    let roomKey: String
    let roomName: String
    let latitude: Double
    let longitude: Double
    let localX: Float
    let localY: Float
    let localZ: Float
    let mapId: String
    let routeId: String
    let recordedAtEpoch: TimeInterval
}

class ScanService: NSObject, ObservableObject {

    static let shared = ScanService()

    // ── Published ─────────────────────────────────────
    @Published var isScanning:    Bool   = false
    @Published var pointCount:    Int    = 0
    @Published var landmarkCount: Int    = 0
    @Published var keyframeCount: Int    = 0
    @Published var waypointCount: Int    = 0 // Route waypoint count for route creation
    @Published var uploadStatus:  String = ""
    @Published var isUploading:   Bool   = false
    @Published var backendScanId: String = ""
    @Published var backendMapId: String = ""
    @Published var backendRouteId: String = ""
    @Published var aiDetectionsCount: Int = 0
    @Published var mapLandmarks: [MapLandmarkRecord] = []
    @Published var mapActionStatus: String = ""
    @Published var anchorReuseStatus: String = ""

    // ── Session data ──────────────────────────────────
    private var scanId:         String            = ""
    private var userId:         String            = DeviceIdentity.userId
    private var roomName:       String            = ""
    private var startedAt:      Date              = Date()
    private var points:         [TrajectoryPoint] = []
    private var landmarks:      [Landmark]        = []
    private var keyframes:      [Keyframe]        = []
    private var depthSamples:   [DepthSample]     = []
    private var waypoints:      [Waypoint]        = [] // Route waypoints from rapid LiDAR sampling
    private var sequenceNumber: Int               = 0
    private var retryCount:     Int               = 0

    // ── Sampling intervals ────────────────────────────
    private var lastPointTime:    TimeInterval = 0
    private var lastKeyframeTime: TimeInterval = 0
    private var lastDepthTime:    TimeInterval = 0
    private var lastMeshLandmarkTime: TimeInterval = 0
    private var lastWaypointTime: TimeInterval = 0 // For rapid LiDAR waypoint collection

    /// Camera pose samples for trajectory (1 Hz - one per second).
    let POINT_INTERVAL:    TimeInterval = 1.0
    /// Keyframes only when environment rotates significantly or every max interval.
    let KEYFRAME_INTERVAL: TimeInterval = 5.0
    let DEPTH_INTERVAL:    TimeInterval = 1.0
    private let meshLandmarkInterval: TimeInterval = 2.0
    /// Rapid waypoint collection for route creation (0.25 seconds - 4 samples per second).
    private let waypointInterval: TimeInterval = 0.25
    /// Cache expiration: images older than 5 hours can be updated.
    private let imageCacheExpiration: TimeInterval = 5 * 60 * 60  // 5 hours in seconds
    /// Rotation threshold to trigger new keyframe: 15 degrees.
    private let rotationThresholdDegrees: Float = 15.0
    /// Position change threshold: 0.5 meters.
    private let positionChangeThreshold: Float = 0.5
    /// Hard image budget per scan to avoid excessive backend image analysis spend.
    private let maxImageKeyframesPerScan: Int = 24
    /// Skip new keyframe image capture when user starts near a known anchor.
    private var suppressKeyframeCaptureForCurrentScan = false
    private var activeAnchorReuseRecord: AnchorReuseRecord?

    private let anchorReuseCacheKey = "videre.anchorReuse.cache.v1"
    private let anchorReuseDistanceMeters: CLLocationDistance = 12
    private let anchorReuseDedupDistanceMeters: CLLocationDistance = 4
    private let anchorReuseCacheMaxRecords = 24
    private let anchorReuseMaxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60

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
    private let locationManager = CLLocationManager()
    private var lastKnownLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 3
    }

    // ── Start ─────────────────────────────────────────
    func startScan(
            roomName: String,
            userId: String = DeviceIdentity.userId) {
        startLocationTrackingIfNeeded()
        if let currentLocation = locationManager.location {
            lastKnownLocation = currentLocation
        }

        self.scanId         = UUID().uuidString
        self.userId         = userId
        self.roomName       = roomName
        self.startedAt      = Date()
        self.points         = []
        self.landmarks      = []
        self.keyframes      = []
        self.depthSamples   = []
        self.waypoints      = [] // Reset waypoints for new scan
        self.sequenceNumber = 0
        self.retryCount     = 0
        arkitLandmarkCentroids = []
        lastPointTime          = 0
        lastKeyframeTime       = 0
        lastDepthTime          = 0
        lastMeshLandmarkTime   = 0
        lastWaypointTime       = 0 // Reset waypoint timing
        lastKeyframePosition   = .zero
        lastKeyframeRotation   = simd_quatf()
        lastKeyframeCacheClearTime = Date()
        didLogKeyframeBudgetReached = false
        suppressKeyframeCaptureForCurrentScan = false
        activeAnchorReuseRecord = nil
        isScanning          = true
        pointCount          = 0
        landmarkCount       = 0
        keyframeCount       = 0
        waypointCount       = 0 // Reset waypoint count
        uploadStatus        = "Scanning..."
        backendScanId       = ""
        backendMapId        = ""
        backendRouteId      = ""
        aiDetectionsCount   = 0
        mapLandmarks        = []
        mapActionStatus     = ""
        anchorReuseStatus   = ""
        APIService.shared.clearActiveRouteContext()

        configureAnchorReuseForNewScan()
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

        // Collect waypoints rapidly for route creation (4 samples per second)
        if now - lastWaypointTime >= waypointInterval {
            lastWaypointTime = now
            collectWaypoint(frame: frame)
        }
    }

    // ── Determine if we should capture a new keyframe ─────────
    private func shouldCaptureNewKeyframe(
            newPosition: simd_float3,
            newRotation: simd_quatf,
            lastTime: TimeInterval,
            now: TimeInterval) -> Bool {

        if suppressKeyframeCaptureForCurrentScan {
            return false
        }

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

    // ── Collect waypoint from current LiDAR position ──────────
    /// Rapidly collects route waypoints during scanning.
    /// Waypoints are sampled from LiDAR/AR positioning at regular intervals (4 Hz).
    private func collectWaypoint(frame: ARFrame) {
        let t = frame.camera.transform
        let ts = currentMs()
        
        // Get LiDAR depth confidence from latest depth sample
        var depthConfidence: Float = 1.0
        if let depthMap = frame.sceneDepth?.depthMap {
            depthConfidence = min(1.0, max(0.5, Float(frame.sceneDepth?.confidence ?? 0) / 255.0))
        }
        
        // Classify LiDAR point if mesh is available
        var classification: String? = nil
        if let classificationMap = frame.sceneDepth?.confidenceMap {
            // Simple classification: if we have mesh data, mark as 'mapped'
            classification = "mapped"
        }
        
        let waypoint = Waypoint(
            x: t.columns.3.x,
            y: t.columns.3.y,
            z: t.columns.3.z,
            timestamp: ts,
            depthConfidence: depthConfidence,
            lidarClassification: classification
        )
        
        waypoints.append(waypoint)
        DispatchQueue.main.async {
            self.waypointCount = self.waypoints.count
        }
        print("Waypoint collected: \(waypoint.x), \(waypoint.y), \(waypoint.z) - \(waypoints.count) waypoints total")
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
            waypoints:      waypoints.isEmpty ? nil : waypoints, // Include waypoints if collected
            createRouteImmediately: waypoints.isEmpty ? nil : true, // Create route from waypoints
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
            // Choose endpoint based on whether we have waypoints for route creation
            let hasWaypoints = !waypoints.isEmpty
            let functionName = hasWaypoints ? "ingest-scan-with-route" : "ingest-scan"

            let result = try await APIService.shared
                .callFunction(
                    name:    functionName,
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

            var routeId: String?
            
            // Check if route was already created from waypoints
            if let routeData = result["data"] as? [String: Any],
               let route = routeData["route"] as? [String: Any],
               let waypointRouteId = route["routeId"] as? String {
                routeId = waypointRouteId
                await MainActor.run {
                    uploadStatus = "Route created from LiDAR waypoints (\(route["waypointCount"] ?? 0) waypoints)"
                }
            }

            // If no route from waypoints, create one from graph
            if routeId == nil {
                let graph = try await APIService.shared.fetchMapGraph(mapId: mapId)
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
            }

            if let finalRouteId = routeId {
                await MainActor.run {
                    backendRouteId = finalRouteId
                }
                persistAnchorReuseRecord(mapId: mapId, routeId: finalRouteId)
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

    private func startLocationTrackingIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    private func normalizeRoomKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func loadAnchorReuseRecords() -> [AnchorReuseRecord] {
        guard let data = UserDefaults.standard.data(forKey: anchorReuseCacheKey) else {
            return []
        }

        guard let records = try? JSONDecoder().decode([AnchorReuseRecord].self, from: data) else {
            return []
        }

        return records
    }

    private func saveAnchorReuseRecords(_ records: [AnchorReuseRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: anchorReuseCacheKey)
    }

    private func activeAnchorCandidate(
            for roomName: String,
            at currentLocation: CLLocation
    ) -> (record: AnchorReuseRecord, distanceMeters: CLLocationDistance)? {
        let roomKey = normalizeRoomKey(roomName)
        let now = Date().timeIntervalSince1970

        let fresh = loadAnchorReuseRecords().filter {
            now - $0.recordedAtEpoch <= anchorReuseMaxAgeSeconds
        }

        let candidates = fresh.filter { $0.roomKey == roomKey }
        guard !candidates.isEmpty else {
            return nil
        }

        let nearest = candidates
            .map { record -> (record: AnchorReuseRecord, distanceMeters: CLLocationDistance) in
                let anchorLocation = CLLocation(latitude: record.latitude, longitude: record.longitude)
                let distance = currentLocation.distance(from: anchorLocation)
                return (record, distance)
            }
            .min(by: { $0.distanceMeters < $1.distanceMeters })

        guard let nearest,
              nearest.distanceMeters <= anchorReuseDistanceMeters
        else {
            return nil
        }

        return nearest
    }

    private func configureAnchorReuseForNewScan() {
        guard let currentLocation = lastKnownLocation else {
            anchorReuseStatus = "No GPS fix yet; capturing new keyframes"
            return
        }

        guard let candidate = activeAnchorCandidate(for: roomName, at: currentLocation) else {
            anchorReuseStatus = "No nearby saved anchor; capturing new keyframes"
            return
        }

        suppressKeyframeCaptureForCurrentScan = true
        activeAnchorReuseRecord = candidate.record
        anchorReuseStatus = String(
            format: "Reusing saved anchor %.0f m away; skipping new keyframe photos",
            candidate.distanceMeters
        )
    }

    private func persistAnchorReuseRecord(mapId: String, routeId: String) {
        guard let currentLocation = lastKnownLocation else {
            return
        }

        let roomKey = normalizeRoomKey(roomName)
        guard !roomKey.isEmpty else {
            return
        }

        let newRecord = AnchorReuseRecord(
            roomKey: roomKey,
            roomName: roomName,
            latitude: currentLocation.coordinate.latitude,
            longitude: currentLocation.coordinate.longitude,
            localX: currentPosition.x,
            localY: currentPosition.y,
            localZ: currentPosition.z,
            mapId: mapId,
            routeId: routeId,
            recordedAtEpoch: Date().timeIntervalSince1970
        )

        var records = loadAnchorReuseRecords().filter { existing in
            let existingLocation = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
            let distance = existingLocation.distance(from: currentLocation)
            let sameRoom = existing.roomKey == roomKey
            return !(sameRoom && distance <= anchorReuseDedupDistanceMeters)
        }

        records.insert(newRecord, at: 0)
        if records.count > anchorReuseCacheMaxRecords {
            records = Array(records.prefix(anchorReuseCacheMaxRecords))
        }

        saveAnchorReuseRecords(records)
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

extension ScanService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else {
            return
        }

        lastKnownLocation = latest

        if isScanning && keyframes.isEmpty && !suppressKeyframeCaptureForCurrentScan {
            configureAnchorReuseForNewScan()
        }
    }
}
