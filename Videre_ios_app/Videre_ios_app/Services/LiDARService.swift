//
//  LiDARService.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//

import ARKit
import RealityKit
import Combine

class LiDARService: NSObject, ObservableObject {

    static let shared = LiDARService()

    // ── Published ─────────────────────────────────────
    @Published var isRunning:     Bool  = false
    @Published var nearestCm:     Int   = 999
    @Published var isAvailable:   Bool  = false

    // ── Internal ──────────────────────────────────────
    private var session:          ARSession?
    private var appState:         AppState?

    // alert cooldown
    private var lastAlertTime:    Date  = .distantPast
    private let alertCooldown:    TimeInterval = 1.5

    override init() {
        super.init()
        isAvailable = ARWorldTrackingConfiguration
            .supportsSceneReconstruction(.mesh)
        // start automatically if device supports it
        if isAvailable {
            start()
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
        appState.lidarAvailable = isAvailable
    }

    // ── Start LiDAR session ───────────────────────────
    func start() {
        guard isAvailable else {
            print("LiDAR not available on this device")
            VoiceService.shared.speak(
                "LiDAR is not available on this device.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction    = .mesh
        config.frameSemantics         = .sceneDepth
        config.environmentTexturing   = .none

        session                       = ARSession()
        session?.delegate             = self
        session?.run(config,
                     options: [.resetTracking,
                                .removeExistingAnchors])
        isRunning                     = true
        appState?.lidarEnabled        = true

        print("LiDAR started")
        VoiceService.shared.speak("LiDAR depth detection on.")
    }

    // ── Stop LiDAR session ────────────────────────────
    func stop() {
        session?.pause()
        session           = nil
        isRunning         = false
        nearestCm         = 999
        appState?.lidarEnabled  = false
        appState?.lidarDistance = 0

        print("LiDAR stopped")
        VoiceService.shared.speak("LiDAR depth detection off.")
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

        guard let depthMap = frame.sceneDepth?.depthMap
        else { return }

        // get nearest depth in the center region
        let nearest = getNearestDepth(depthMap: depthMap)

        DispatchQueue.main.async {
            self.nearestCm         = Int(nearest * 100)
            self.appState?.lidarDistance = nearest

            // voice alert if something close
            self.handleDepthAlert(nearest)
        }
    }

    // ── Get nearest depth in center crop ──────────────
    private func getNearestDepth(depthMap: CVPixelBuffer) -> Float {

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap,
                                               .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let base = CVPixelBufferGetBaseAddress(depthMap)
        else { return 999 }

        let floatBuffer = base.assumingMemoryBound(
                              to: Float32.self)

        // sample center 20% of the frame
        let xStart = width  / 2 - width  / 10
        let xEnd   = width  / 2 + width  / 10
        let yStart = height / 2 - height / 10
        let yEnd   = height / 2 + height / 10

        var nearest: Float = 999

        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let depth = floatBuffer[y * width + x]
                // valid depth range 0.1m to 5m
                if depth > 0.1 && depth < 5.0 {
                    nearest = min(nearest, depth)
                }
            }
        }
        return nearest
    }

    // ── Voice alerts from LiDAR ───────────────────────
    private func handleDepthAlert(_ meters: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime)
                  > alertCooldown else { return }

        // only alert if LiDAR detects closer than cane threshold
        // and cane hasn't already alerted
        guard let appState = appState else { return }

        let cm = Int(meters * 100)

        // don't duplicate cane alerts
        if cm < appState.distanceCm - 20 {
            if meters < 0.3 {
                VoiceService.shared.speak(
                    "Stop — very close.",
                    priority: .high)
                lastAlertTime = now
            } else if meters < 0.6 {
                VoiceService.shared.speak(
                    "Obstacle \(cm) centimetres.")
                lastAlertTime = now
            }
        }
    }
}
