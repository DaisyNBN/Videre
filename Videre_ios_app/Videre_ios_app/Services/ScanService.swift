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

    /// Camera pose samples for trajectory (~2 Hz per hackathon spec).
    let POINT_INTERVAL:    TimeInterval = 0.5
    let KEYFRAME_INTERVAL: TimeInterval = 2.0
    let DEPTH_INTERVAL:    TimeInterval = 1.0
    private let meshLandmarkInterval: TimeInterval = 2.0

    /// Dedupe ARKit mesh landmarks (meters).
    private var arkitLandmarkCentroids: [simd_float3] = []
    private let arkitLandmarkMinSpacing: Float = 1.0

    /// Keyframe / depth uploads run in `Task`; wait for them before manifest.
    private let pendingUploadLock = NSLock()
    private var pendingMediaUploadCount = 0
    private let pendingUploadWaitSeconds: TimeInterval = 90

    // ── Current camera position ───────────────────────
    // used for adding landmarks
    private(set) var currentPosition: simd_float3 = .zero

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
        isScanning          = true
        pointCount          = 0
        landmarkCount       = 0
        keyframeCount       = 0
        uploadStatus        = "Scanning..."
    }

    // ── Stop and upload ───────────────────────────────
    func stopScan() {
        guard isScanning else { return }
        isScanning   = false
        isUploading  = true
        uploadStatus = "Finishing media uploads..."

        Task {
            await waitForPendingMediaUploads()
            await MainActor.run {
                self.uploadStatus = "Uploading manifest..."
            }
            let payload = buildPayload(endedAt: Date())
            await upload(payload: payload)
        }
    }

    private func registerPendingMediaUpload() {
        pendingUploadLock.lock()
        pendingMediaUploadCount += 1
        pendingUploadLock.unlock()
    }

    private func unregisterPendingMediaUpload() {
        pendingUploadLock.lock()
        pendingMediaUploadCount -= 1
        pendingUploadLock.unlock()
    }

    private func waitForPendingMediaUploads() async {
        let deadline = Date().addingTimeInterval(pendingUploadWaitSeconds)
        while Date() < deadline {
            pendingUploadLock.lock()
            let n = pendingMediaUploadCount
            pendingUploadLock.unlock()
            if n == 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("ScanService: timeout waiting for pending media uploads")
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

        if now - lastPointTime >= POINT_INTERVAL {
            lastPointTime = now
            addPoint(frame: frame)
        }

        if now - lastKeyframeTime >= KEYFRAME_INTERVAL {
            lastKeyframeTime = now
            captureKeyframe(frame: frame)
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

    // ── Add user landmark at current position ──────────
    func addLandmark(type: String, label: String) {
        let lm = Landmark(
            type:      type,
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
        let lm = Landmark(
            type:      type,
            label:     label,
            x:         position.x,
            y:         position.y,
            z:         position.z,
            source:    "arkit",
            timestamp: currentMs()
        )
        landmarks.append(lm)
        DispatchQueue.main.async {
            self.landmarkCount = self.landmarks.count
        }
        print("ARKit landmark: \(label) at \(position)")
    }

    // ── Collect trajectory point ───────────────────────
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
        let sid   = scanId

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let uiImg   = UIImage(ciImage: ciImage)
        guard let jpegData = uiImg.jpegData(compressionQuality: 0.5)
        else { return }

        Task { [weak self] in
            guard let self else { return }
            self.registerPendingMediaUpload()
            defer { self.unregisterPendingMediaUpload() }

            let url = await self.uploadKeyframeJPEG(
                jpegData,
                name: "kf_\(sid)_\(ts).jpg"
            )
            guard !url.isEmpty else { return }

            let kf = Keyframe(
                imageUrl:   url,
                timestamp:  ts,
                cameraPose: pose,
                fx:         intr.columns.0.x,
                fy:         intr.columns.1.y,
                cx:         intr.columns.2.x,
                cy:         intr.columns.2.y
            )
            await MainActor.run {
                self.keyframes.append(kf)
                self.keyframeCount = self.keyframes.count
            }
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
        let sid = scanId

        // Copy now — `ARFrame` buffers are not safe to use after delegate returns.
        let depthBytes: Data = {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }
            let height      = CVPixelBufferGetHeight(depthMap)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
            guard let base = CVPixelBufferGetBaseAddress(depthMap),
                  height > 0,
                  bytesPerRow > 0
            else { return Data() }
            return Data(bytes: base, count: bytesPerRow * height)
        }()
        guard !depthBytes.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            self.registerPendingMediaUpload()
            defer { self.unregisterPendingMediaUpload() }

            let url = await self.uploadDepthData(
                depthBytes,
                name: "d_\(sid)_\(ts).bin"
            )
            guard !url.isEmpty else { return }

            let ds = DepthSample(
                timestamp:  ts,
                cameraPose: pose,
                depthUrl:   url
            )
            await MainActor.run {
                self.depthSamples.append(ds)
            }
        }
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

    // ── Upload payload to Supabase ────────────────────
    private func upload(payload: ScanPayload) async {
        guard let dict = payload.toDictionary()
        else {
            await MainActor.run {
                uploadStatus = "Build failed"
                isUploading  = false
            }
            return
        }

        do {
            let result = try await SupabaseService.shared
                .callFunction(
                    name:    "ingest-scan",
                    payload: dict
                )
            await MainActor.run {
                if let success = result["success"] as? Bool,
                   success {
                    uploadStatus = Constants.supabaseDryRun
                        ? "Dry run — manifest logged, not sent"
                        : "Upload complete"
                } else {
                    uploadStatus = "Upload failed"
                    retryCount  += 1
                }
                isUploading = false
                sequenceNumber += 1
            }
        } catch {
            await MainActor.run {
                uploadStatus = "Error: \(error.localizedDescription)"
                isUploading  = false
                retryCount  += 1
            }
        }
    }

    // ── Upload keyframe JPEG to Supabase storage ──────
    private func uploadKeyframeJPEG(_ data: Data,
                                     name: String) async -> String {
        guard !data.isEmpty else { return "" }

        let urlStr = "\(Secrets.supabaseURL)" +
                     "/storage/v1/object/keyframes/\(name)"
        if Constants.supabaseDryRun {
            return urlStr
        }

        guard let url = URL(string: urlStr) else { return "" }

        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.supabaseAnonKey)",
                     forHTTPHeaderField: "Authorization")
        req.setValue(Secrets.supabaseAnonKey,
                     forHTTPHeaderField: "apikey")
        req.setValue("image/jpeg",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        do {
            let (_, response) = try await URLSession.shared
                .data(for: req)
            guard Self.storageResponseOK(response) else {
                let code = (response as? HTTPURLResponse)?
                    .statusCode ?? -1
                print("Keyframe upload HTTP \(code)")
                return ""
            }
            return urlStr
        } catch {
            print("Keyframe upload failed: \(error)")
            return ""
        }
    }

    // ── Upload depth binary to Supabase storage ────────
    private func uploadDepthData(_ data: Data,
                                  name: String) async -> String {
        guard !data.isEmpty else { return "" }

        let urlStr = "\(Secrets.supabaseURL)" +
                     "/storage/v1/object/depth/\(name)"
        if Constants.supabaseDryRun {
            return urlStr
        }

        guard let url = URL(string: urlStr) else { return "" }

        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.supabaseAnonKey)",
                     forHTTPHeaderField: "Authorization")
        req.setValue(Secrets.supabaseAnonKey,
                     forHTTPHeaderField: "apikey")
        req.setValue("application/octet-stream",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        do {
            let (_, response) = try await URLSession.shared
                .data(for: req)
            guard Self.storageResponseOK(response) else {
                let code = (response as? HTTPURLResponse)?
                    .statusCode ?? -1
                print("Depth upload HTTP \(code)")
                return ""
            }
            return urlStr
        } catch {
            print("Depth upload failed: \(error)")
            return ""
        }
    }

    private static func storageResponseOK(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        return (200...299).contains(http.statusCode)
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
