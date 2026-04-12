import ARKit
import RealityKit
import Combine

struct DepthAnalysis {
    var leftCm:   Int = 999
    var centerCm: Int = 999
    var rightCm:  Int = 999
    var floorCm:  Int = 999

    var clearSide: String {
        if leftCm > rightCm + 50  { return "left" }
        if rightCm > leftCm + 50  { return "right" }
        return "center"
    }

    /// Slightly stricter thresholds than before to cut false positives
    /// from depth noise in the lower band of the frame.
    var stepDetected: String {
        if floorCm < 25  { return "step up" }
        if floorCm > 220 { return "step down" }
        return "none"
    }
}

class LiDARService: NSObject, ObservableObject {

    static let shared = LiDARService()

    @Published var isRunning:   Bool  = false
    @Published var nearestCm:   Int   = 999
    /// From depth thirds: which side has more open space (`left` / `center` / `right`).
    @Published var depthClearSide: String = "center"
    /// From classified scene mesh (`door`, `wall`, …) or `obstacle` if unknown.
    @Published var navigationObstacleLabel: String = "obstacle"
    @Published var isAvailable: Bool  = false

    private var session:   ARSession?
    private var appState:  AppState?

    private var lastAlertTime: Date = .distantPast
    /// Short gap between generic obstacle / path hints.
    private let alertCooldown: TimeInterval = 1.5

    /// Step warnings use noisy floor depth; keep them rare.
    private var lastStepAlertTime: Date = .distantPast
    private let stepAlertCooldown: TimeInterval = 12.0
    /// Require the same step reading briefly so one spike does not speak.
    private var pendingStepKind:     String?
    private var pendingStepSince:  Date?
    private let stepStableDuration: TimeInterval = 0.45

    private var lastObstacleLabelSampleTime: TimeInterval = 0
    private let obstacleLabelSampleInterval: TimeInterval = 0.35

    override init() {
        super.init()
        isAvailable =
            ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .meshWithClassification)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .mesh)
        if isAvailable {
            start()
        }
    }

    func configure(appState: AppState) {
        self.appState           = appState
        appState.lidarAvailable = isAvailable
    }

    // ── Start ─────────────────────────────────────────
    func start() {
        guard isAvailable else {
            print("LiDAR not available on this device")
            VoiceService.shared.speak(
                "LiDAR is not available on this device.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else {
            config.sceneReconstruction = .mesh
        }
        config.frameSemantics       = .sceneDepth
        config.environmentTexturing = .none

        session          = ARSession()
        session?.delegate = self
        session?.run(config,
                     options: [.resetTracking,
                                .removeExistingAnchors])
        isRunning             = true
        appState?.lidarEnabled = true
        print("LiDAR started")
    }

    // ── Stop ──────────────────────────────────────────
    func stop() {
        session?.pause()
        session                = nil
        isRunning              = false
        nearestCm              = 999
        depthClearSide         = "center"
        navigationObstacleLabel = "obstacle"
        appState?.lidarEnabled = false
        appState?.lidarDistance = 0
        print("LiDAR stopped")
    }

    // ── Toggle ────────────────────────────────────────
    func toggle() {
        isRunning ? stop() : start()
    }
}

// ── ARSessionDelegate ─────────────────────────────────
extension LiDARService: ARSessionDelegate {

    func session(_ session: ARSession,
                 didUpdate frame: ARFrame) {

        let nowMono = ProcessInfo.processInfo.systemUptime
        if nowMono - lastObstacleLabelSampleTime
                >= obstacleLabelSampleInterval {
            lastObstacleLabelSampleTime = nowMono
            let sampled =
                ARMeshLandmarkSampler.nearestObstacleLabel(frame: frame)
                ?? "obstacle"
            DispatchQueue.main.async {
                self.navigationObstacleLabel = sampled
            }
        }

        if let depthMap = frame.sceneDepth?.depthMap {
            let nearest  = getNearestDepth(depthMap: depthMap)
            let analysis = analyseDepthMap(depthMap)

            DispatchQueue.main.async {
                self.nearestCm = Int(nearest * 100)
                self.depthClearSide = analysis.clearSide
                self.appState?.lidarDistance = nearest
                self.handleDepthAlert(nearest,
                                      analysis: analysis)
            }
        }

        // Scanning needs frames even when scene depth is missing briefly.
        ScanService.shared.onARFrame(frame)
    }

    // ── Get nearest depth in center crop ──────────────
    private func getNearestDepth(
            depthMap: CVPixelBuffer) -> Float {

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(
                depthMap, .readOnly)
        }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let base = CVPixelBufferGetBaseAddress(
                             depthMap)
        else { return 999 }

        let buf    = base.assumingMemoryBound(
                         to: Float32.self)
        let xStart = width  / 2 - width  / 10
        let xEnd   = width  / 2 + width  / 10
        let yStart = height / 2 - height / 10
        let yEnd   = height / 2 + height / 10

        var nearest: Float = 999

        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let depth = buf[y * width + x]
                if depth > 0.1 && depth < 5.0 {
                    nearest = min(nearest, depth)
                }
            }
        }
        return nearest
    }

    // ── Analyse full depth map ─────────────────────────
    private func analyseDepthMap(
            _ depthMap: CVPixelBuffer) -> DepthAnalysis {

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(
                depthMap, .readOnly)
        }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let base = CVPixelBufferGetBaseAddress(
                             depthMap)
        else { return DepthAnalysis() }

        let buf = base.assumingMemoryBound(
                      to: Float32.self)

        var leftSum:   Float = 0
        var centerSum: Float = 0
        var rightSum:  Float = 0
        var floorSum:  Float = 0
        var leftCount   = 0
        var centerCount = 0
        var rightCount  = 0
        var floorCount  = 0

        for y in 0..<height {
            for x in 0..<width {
                let d = buf[y * width + x]
                guard d > 0.1 && d < 5.0 else { continue }

                let xRatio = Float(x) / Float(width)
                let yRatio = Float(y) / Float(height)

                // left third — mid height
                if xRatio < 0.33 &&
                   yRatio > 0.3 && yRatio < 0.7 {
                    leftSum += d
                    leftCount += 1
                }
                // center third — mid height
                if xRatio > 0.33 && xRatio < 0.66 &&
                   yRatio > 0.3 && yRatio < 0.7 {
                    centerSum += d
                    centerCount += 1
                }
                // right third — mid height
                if xRatio > 0.66 &&
                   yRatio > 0.3 && yRatio < 0.7 {
                    rightSum += d
                    rightCount += 1
                }
                // bottom — floor
                if yRatio > 0.8 {
                    floorSum += d
                    floorCount += 1
                }
            }
        }

        return DepthAnalysis(
            leftCm:   leftCount   > 0
                      ? Int((leftSum   / Float(leftCount))   * 100)
                      : 999,
            centerCm: centerCount > 0
                      ? Int((centerSum / Float(centerCount)) * 100)
                      : 999,
            rightCm:  rightCount  > 0
                      ? Int((rightSum  / Float(rightCount))  * 100)
                      : 999,
            floorCm:  floorCount  > 0
                      ? Int((floorSum  / Float(floorCount))  * 100)
                      : 999
        )
    }

    // ── Voice alerts from depth ────────────────────────
    private func handleDepthAlert(
            _ meters: Float,
            analysis: DepthAnalysis) {

        let now = Date()
        let cm  = Int(meters * 100)
        let step = analysis.stepDetected

        // reset debounce when floor no longer reads as a step
        if step == "none" {
            pendingStepKind    = nil
            pendingStepSince   = nil
        } else {
            if pendingStepKind != step {
                pendingStepKind  = step
                pendingStepSince = now
            }
        }

        // step detection — long cooldown + stability gate (depth flickers)
        if step != "none",
           let since = pendingStepSince,
           now.timeIntervalSince(since) >= stepStableDuration,
           now.timeIntervalSince(lastStepAlertTime) >= stepAlertCooldown {
            VoiceService.shared.speak(
                "Warning — \(step) ahead.",
                priority: .high)
            lastStepAlertTime = now
            lastAlertTime     = now
            pendingStepKind   = nil
            pendingStepSince  = nil
            return
        }

        guard now.timeIntervalSince(lastAlertTime)
                  > alertCooldown else { return }

        // clear path direction when close
        if meters < 1.0 {
            let side = analysis.clearSide
            if side != "center" {
                VoiceService.shared.speak(
                    "Move \(side) — clearer path.")
                lastAlertTime = now
                return
            }
        }

        // general obstacle alert
        if meters < 0.6 {
            VoiceService.shared.speak(
                "Obstacle \(cm) centimetres.",
                priority: meters < 0.3 ? .high : .normal)
            lastAlertTime = now
        }
    }
}
