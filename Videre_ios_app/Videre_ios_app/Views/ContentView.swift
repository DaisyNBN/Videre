import SwiftUI
import Combine

struct ContentView: View {

    @EnvironmentObject var ble:   BLEManager
    @EnvironmentObject var lidar: LiDARService
    @EnvironmentObject var scan: ScanService
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var navigation: NavigationContextService
    @StateObject private var destinationVoice = RoomNameSpeechController()
    private let openScan: () -> Void
    @State private var lastNavigationInstruction: String = ""
    @State private var lastNavigationMeta: String = ""
    @State private var showCalibrationPopup: Bool = false
    @State private var showNavigationDebug: Bool = false
    @State private var autoGuidanceEnabled: Bool = true
    @State private var isGuidanceRequestInFlight: Bool = false
    @State private var lastGuidanceRequestAt: Date = .distantPast
    @State private var destinationRoomLabel: String = ""
    @State private var isDestinationRouteInFlight: Bool = false
    @State private var destinationRouteStatus: String = ""
    @State private var destinationSuggestions: [String] = []
    @State private var destinationSuggestionsStatus: String = ""
    @State private var isDestinationSuggestionsLoading: Bool = false
    @State private var recentDestinations: [String] = []
    private let autoGuidanceTimer = Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()
    private let guidanceThrottleInterval: TimeInterval = 2.5
    private let recentDestinationsStorageKey = "videre.recentDestinations"
    private let maxRecentDestinations = 3

    init(openScan: @escaping () -> Void = {}) {
        self.openScan = openScan
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── Status bar ─────────────────────────
                HStack(spacing: 8) {
                    Circle()
                        .fill(ble.isConnected
                              ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(ble.statusMessage)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: batteryIcon)
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                        Text("\(ble.battery)%")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    }
                    Button {
                        showCalibrationPopup = true
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(.leading, 8)
                    }
                    .accessibilityLabel("Open calibration debug popup")
                }
                .padding(.horizontal, 20)
                .padding(.top, 50)
                .padding(.bottom, 16)

                Divider()

                // ── Navigation quick actions ──────────
                VStack(alignment: .leading, spacing: 10) {
                    Text("Navigation")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 12))

                        Text(activeRouteSummary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text("Nearby hazards: \(navigation.nearbyHazardsCount)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if !navigation.autoRerouteStatus.isEmpty {
                        Text(navigation.autoRerouteStatus)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Toggle(isOn: Binding(
                        get: { appState.walkState == .walking },
                        set: { on in
                            appState.walkState = on ? .walking : .idle
                        }
                    )) {
                        Text("Walking mode")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Toggle(isOn: $autoGuidanceEnabled) {
                        Text("Auto guidance")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Text(autoGuidanceStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination room")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        if !recentDestinations.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Recent destinations")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(recentDestinations, id: \.self) { destination in
                                            Button {
                                                destinationRoomLabel = destination
                                                routeToDestinationRoom(destinationOverride: destination)
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "clock.arrow.circlepath")
                                                        .font(.system(size: 10, weight: .semibold))
                                                    Text(destination)
                                                        .font(.system(size: 12, weight: .medium))
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .background(Color.orange.opacity(0.15))
                                                .foregroundColor(.orange)
                                                .cornerRadius(8)
                                            }
                                            .disabled(isDestinationRouteInFlight)
                                        }
                                    }
                                }
                            }
                        }

                        TextField("Type room label, e.g. Room 201", text: $destinationRoomLabel)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                            .cornerRadius(10)

                        HStack(spacing: 8) {
                            Button {
                                refreshDestinationSuggestions()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(isDestinationSuggestionsLoading ? "Loading" : "Load suggestions")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                            }
                            .disabled(isDestinationSuggestionsLoading)

                            if isDestinationSuggestionsLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }

                            Spacer(minLength: 0)
                        }

                        if !destinationSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(destinationSuggestions, id: \.self) { suggestion in
                                        Button {
                                            destinationRoomLabel = suggestion
                                        } label: {
                                            Text(suggestion)
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .background(Color.teal.opacity(0.12))
                                                .foregroundColor(.teal)
                                                .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                        }

                        if !destinationSuggestionsStatus.isEmpty {
                            Text(destinationSuggestionsStatus)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Button {
                            if destinationVoice.isListening {
                                destinationVoice.stopListening()
                            } else {
                                destinationVoice.clearRoomName()
                                destinationVoice.startListening()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: destinationVoice.isListening ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.system(size: 13))
                                Text(destinationVoice.isListening
                                     ? "Listening for destination..."
                                     : "Voice command")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(destinationVoice.isListening ? Color.red.opacity(0.15) : Color.indigo.opacity(0.15))
                            .foregroundColor(destinationVoice.isListening ? .red : .indigo)
                            .cornerRadius(10)
                        }
                        .disabled(isDestinationRouteInFlight)

                        Text("Try: Navigate to Room 201")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        if !destinationVoice.roomName.isEmpty {
                            Text("Heard: \(destinationVoice.roomName)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        if !destinationVoice.speechError.isEmpty {
                            Text(destinationVoice.speechError)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }

                        Button {
                            routeToDestinationRoom()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                    .font(.system(size: 12))
                                Text("Route to room")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.teal.opacity(0.15))
                            .foregroundColor(.teal)
                            .cornerRadius(10)
                        }
                        .disabled(isDestinationRouteInFlight)

                        if !destinationRouteStatus.isEmpty {
                            Text(destinationRouteStatus)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            requestBackendGuidance(force: true)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 12))
                                Text("Get guidance")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                        }
                        .disabled(isGuidanceRequestInFlight)
                        .accessibilityLabel("Request guidance from backend")

                        Button {
                            openScan()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "record.circle.fill")
                                    .font(.system(size: 12))
                                Text("Scan room")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(10)
                        }
                        .accessibilityLabel("Open scan tab")
                    }

                    if !lastNavigationInstruction.isEmpty {
                        Text(lastNavigationInstruction)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    if !lastNavigationMeta.isEmpty {
                        Text(lastNavigationMeta)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(.systemGray6))
                .cornerRadius(14)
                .padding(.horizontal, 20)
                .padding(.top, 14)

                // ── Main distance display ──────────────
                VStack(spacing: 6) {
                    Text(ble.distanceCm == 999
                         ? "---" : "\(ble.distanceCm)")
                        .font(.system(size: 90,
                                      weight: .bold,
                                      design: .rounded))
                        .foregroundColor(distanceColor)
                        .animation(.easeInOut(duration: 0.2),
                                   value: ble.distanceCm)
                        .accessibilityLabel(
                            ble.distanceCm == 999
                            ? "No reading"
                            : "\(ble.distanceCm) centimetres ahead")

                    Text("cm")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)

                    Text(distanceLabel)
                        .font(.system(size: 15,
                                      weight: .semibold))
                        .foregroundColor(distanceColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(distanceColor.opacity(0.12))
                        .cornerRadius(8)
                        .accessibilityLabel(distanceLabel)
                }
                .padding(.vertical, 24)

                // ── LiDAR distance (when active) ───────
                if lidar.isRunning {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 8, height: 8)
                        Text("LiDAR:")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text(lidar.nearestCm == 999
                             ? "---"
                             : "\(lidar.nearestCm) cm")
                            .font(.system(size: 13,
                                          weight: .semibold))
                            .foregroundColor(.cyan)
                    }
                    .padding(.bottom, 12)
                    .accessibilityLabel(
                        lidar.nearestCm == 999
                        ? "LiDAR: no reading"
                        : "LiDAR: \(lidar.nearestCm) centimetres")
                }

                Divider()

                // ── Buzzer + Vibration status ──────────
                HStack(spacing: 12) {
                    statusCard(
                        label: "Buzzer",
                        value: ble.buzzerOn ? "On" : "Off",
                        icon:  ble.buzzerOn
                               ? "speaker.wave.2.fill"
                               : "speaker.slash.fill",
                        color: ble.buzzerOn ? .green : .red
                    )
                    statusCard(
                        label: "Vibration",
                        value: ble.vibOn ? "On" : "Off",
                        icon:  ble.vibOn
                               ? "waveform.circle.fill"
                               : "waveform.circle",
                        color: ble.vibOn ? .green : .red
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                // ── LiDAR toggle ───────────────────────
                VStack(spacing: 8) {
                    HStack {
                        Text("LiDAR depth")
                            .font(.system(size: 14,
                                          weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        if !lidar.isAvailable {
                            Text("Not available")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { lidar.isRunning },
                                set: { _ in lidar.toggle() }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(
                                lidar.isRunning
                                ? "LiDAR on. Tap to turn off."
                                : "LiDAR off. Tap to turn on.")
                        }
                    }
                    .padding(.horizontal, 20)

                    if !lidar.isAvailable {
                        Text("LiDAR requires iPhone 12 Pro or newer")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    } else if lidar.isRunning {
                        Text("Scanning")
                            .font(.system(size: 12))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                // ── Controls ───────────────────────────
                VStack(spacing: 8) {
                    Text("Controls")
                        .font(.system(size: 12,
                                      weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity,
                               alignment: .leading)
                        .padding(.horizontal, 20)

                    HStack(spacing: 10) {
                        controlButton(
                            "Buzzer Off",
                            icon: "speaker.slash.fill",
                            color: .red) {
                            ble.sendSettings(
                                ["buzzer_on": false])
                        }
                        controlButton(
                            "Buzzer On",
                            icon: "speaker.wave.2.fill",
                            color: .green) {
                            ble.sendSettings(
                                ["buzzer_on": true])
                        }
                    }
                    .padding(.horizontal, 20)

                    HStack(spacing: 10) {
                        controlButton(
                            "Vibration Off",
                            icon: "waveform.circle",
                            color: .red) {
                            ble.sendSettings(
                                ["vib_on": false])
                        }
                        controlButton(
                            "Vibration On",
                            icon: "waveform.circle.fill",
                            color: .green) {
                            ble.sendSettings(
                                ["vib_on": true])
                        }
                    }
                    .padding(.horizontal, 20)

                    HStack(spacing: 10) {
                        controlButton(
                            "Less sensitive",
                            icon: "minus.circle",
                            color: .orange) {
                            ble.sendSettings(
                                ["zone_caution": 80])
                        }
                        controlButton(
                            "More sensitive",
                            icon: "plus.circle",
                            color: .orange) {
                            ble.sendSettings(
                                ["zone_caution": 120])
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                // ── Navigation diagnostics ───────────
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Navigation diagnostics")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Menu {
                            Button(showCalibrationPopup
                                   ? "Hide calibration popup"
                                   : "Show calibration popup") {
                                showCalibrationPopup.toggle()
                            }
                            Button(showNavigationDebug
                                   ? "Hide payload debug"
                                   : "Show payload debug") {
                                showNavigationDebug.toggle()
                            }
                        } label: {
                            Label("Debug menu", systemImage: "ellipsis.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 20)

                    if !navigation.locationAuthorized {
                        Text("Location: using default lat/lng until you allow access")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 20)
                    }

                    if showNavigationDebug {
                        if !navigation.hazardPollStatus.isEmpty {
                            Text(navigation.hazardPollStatus)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(navigatePayloadPretty)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                // ── Raw JSON debug ─────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("Debug — raw JSON")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal,
                               showsIndicators: false) {
                        Text(ble.rawJSON.isEmpty
                             ? "waiting for data..."
                             : ble.rawJSON)
                            .font(.system(size: 11,
                                          design: .monospaced))
                            .foregroundColor(
                                ble.rawJSON.isEmpty
                                ? .secondary : .primary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showCalibrationPopup) {
            CalibrationDebugPopupView(navigation: navigation)
        }
        .onReceive(autoGuidanceTimer) { _ in
            guard autoGuidanceEnabled else {
                return
            }

            guard appState.walkState == .walking else {
                return
            }

            requestBackendGuidance(force: false)
        }
        .onAppear {
            loadRecentDestinations()
            refreshDestinationSuggestions()
        }
        .onChange(of: scan.backendMapId) { _ in
            refreshDestinationSuggestions()
        }
        .onChange(of: destinationVoice.isRoomNameLocked) { isLocked in
            guard isLocked else {
                return
            }

            let transcript = destinationVoice.roomName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                return
            }

            let parsedDestination = parseDestinationFromVoiceCommand(transcript)
            destinationRoomLabel = parsedDestination
            destinationRouteStatus = "Voice destination: \(parsedDestination)"
            destinationVoice.clearRoomName()
            routeToDestinationRoom(destinationOverride: parsedDestination)
        }
    }

    private var navigatePayloadPretty: String {
        let p = navigation.payload(
            ble: ble,
            lidar: lidar,
            appState: appState)
        guard JSONSerialization.isValidJSONObject(p),
              let data = try? JSONSerialization.data(
                  withJSONObject: p,
                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    private var activeRouteSummary: String {
        if let activeRouteId = APIService.shared.activeRouteId,
           !activeRouteId.isEmpty {
            return "Active route: \(activeRouteId)"
        }

        return "No active route. Scan a room to build one."
    }

    private func routeToDestinationRoom(destinationOverride: String? = nil) {
        guard !isDestinationRouteInFlight else {
            return
        }

        let destinationInput = destinationOverride ?? destinationRoomLabel
        let destination = destinationInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            destinationRouteStatus = "Enter a destination room label first"
            return
        }

        let mapId = (APIService.shared.activeMapId ?? scan.backendMapId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mapId.isEmpty else {
            destinationRouteStatus = "No active map available. Scan and upload a floor first"
            return
        }

        isDestinationRouteInFlight = true
        destinationRouteStatus = "Generating route to \(destination)..."

        let position = scan.currentPosition
        Task {
            do {
                let routeId = try await APIService.shared.generateRouteToRoom(
                    mapId: mapId,
                    startX: Double(position.x),
                    startY: Double(position.y),
                    startZ: Double(position.z),
                    destinationLabel: destination
                )

                await MainActor.run {
                    destinationRouteStatus = "Route to \(destination) ready: \(routeId)"
                    appState.walkState = .walking
                    autoGuidanceEnabled = true
                    isDestinationRouteInFlight = false
                    rememberRecentDestination(destination)
                    VoiceService.shared.speak("Route to \(destination) ready")
                    requestBackendGuidance(force: true)
                }
            } catch {
                await MainActor.run {
                    destinationRouteStatus =
                        "Failed to route to \(destination): \(error.localizedDescription)"
                    isDestinationRouteInFlight = false
                }
            }
        }
    }

    private func refreshDestinationSuggestions() {
        guard !isDestinationSuggestionsLoading else {
            return
        }

        let mapId = (APIService.shared.activeMapId ?? scan.backendMapId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mapId.isEmpty else {
            destinationSuggestions = []
            destinationSuggestionsStatus = "No active map for destination suggestions"
            return
        }

        isDestinationSuggestionsLoading = true
        destinationSuggestionsStatus = "Loading destination suggestions..."

        Task {
            do {
                let landmarks = try await APIService.shared.fetchMapLandmarks(mapId: mapId)
                let sorted = landmarks.sorted { lhs, rhs in
                    let lhsScore = destinationSuggestionScore(lhs)
                    let rhsScore = destinationSuggestionScore(rhs)
                    if lhsScore == rhsScore {
                        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                    }
                    return lhsScore > rhsScore
                }

                var seen = Set<String>()
                var labels: [String] = []

                for landmark in sorted {
                    let label = landmark.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = label.lowercased()

                    guard !label.isEmpty,
                          normalized != "(unlabeled)",
                          landmark.status.lowercased() != "rejected",
                          !seen.contains(normalized)
                    else {
                        continue
                    }

                    seen.insert(normalized)
                    labels.append(label)
                }

                await MainActor.run {
                    destinationSuggestions = Array(labels.prefix(12))
                    if destinationSuggestions.isEmpty {
                        destinationSuggestionsStatus = "No destination labels available on this map"
                    } else {
                        destinationSuggestionsStatus = "Loaded \(destinationSuggestions.count) destination suggestions"
                    }
                    isDestinationSuggestionsLoading = false
                }
            } catch {
                await MainActor.run {
                    destinationSuggestions = []
                    destinationSuggestionsStatus =
                        "Failed to load destination suggestions: \(error.localizedDescription)"
                    isDestinationSuggestionsLoading = false
                }
            }
        }
    }

    private func destinationSuggestionScore(_ landmark: MapLandmarkRecord) -> Double {
        var score = 0.0

        switch landmark.status.lowercased() {
        case "verified":
            score += 100
        case "pending":
            score += 50
        default:
            score += 10
        }

        if landmark.type.lowercased() == "door" {
            score += 8
        }

        if let confidence = landmark.confidence {
            score += max(0, min(confidence, 1)) * 20
        }

        return score
    }

    private func parseDestinationFromVoiceCommand(_ transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }

        let lower = normalized.lowercased()
        let prefixes = [
            "navigate to ",
            "go to ",
            "route to ",
            "take me to ",
            "guide me to ",
            "directions to ",
            "find ",
        ]

        for prefix in prefixes where lower.hasPrefix(prefix) {
            let dropCount = prefix.count
            let suffix = normalized.dropFirst(dropCount).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                return suffix
            }
        }

        return normalized
    }

    private func loadRecentDestinations() {
        let stored = UserDefaults.standard.stringArray(forKey: recentDestinationsStorageKey) ?? []

        var seen = Set<String>()
        var cleaned: [String] = []

        for destination in stored {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()

            guard !trimmed.isEmpty, !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            cleaned.append(trimmed)
        }

        recentDestinations = Array(cleaned.prefix(maxRecentDestinations))
    }

    private func rememberRecentDestination(_ destination: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        var updated = recentDestinations.filter {
            $0.compare(trimmed, options: .caseInsensitive) != .orderedSame
        }
        updated.insert(trimmed, at: 0)
        recentDestinations = Array(updated.prefix(maxRecentDestinations))
        UserDefaults.standard.set(recentDestinations, forKey: recentDestinationsStorageKey)
    }

    private var autoGuidanceStatus: String {
        if !autoGuidanceEnabled {
            return "Auto guidance paused"
        }

        if appState.walkState != .walking {
            return "Auto guidance waiting for walking mode"
        }

        if APIService.shared.activeRouteId == nil {
            return "Auto guidance waiting for active route"
        }

        if isGuidanceRequestInFlight {
            return "Auto guidance requesting update..."
        }

        return "Auto guidance active (every 4s, throttled)"
    }

    private func requestBackendGuidance(force: Bool) {
        guard !isGuidanceRequestInFlight else {
            return
        }

        if !force {
            guard APIService.shared.activeRouteId != nil else {
                return
            }

            let elapsed = Date().timeIntervalSince(lastGuidanceRequestAt)
            guard elapsed >= guidanceThrottleInterval else {
                return
            }
        }

        isGuidanceRequestInFlight = true
        lastGuidanceRequestAt = Date()

        Task {
            let payload = navigation.payload(
                ble: ble,
                lidar: lidar,
                appState: appState
            )

            do {
                let response = try await APIService.shared.postNavigate(payload)

                await MainActor.run {
                    lastNavigationInstruction = response.instruction
                    let fallbackText = response.fallbackUsed ? "yes" : "no"
                    let distanceText: String = {
                        guard let distance = response.distanceToNextM else {
                            return "n/a"
                        }
                        return String(format: "%.1f m", distance)
                    }()

                    lastNavigationMeta =
                        "Urgency: \(response.urgency), " +
                        "Haptic: \(response.hapticPattern), " +
                        "Next: \(response.nextCheckpoint ?? "none"), " +
                        "Distance: \(distanceText), " +
                        "Fallback: \(fallbackText)"

                    let priority: VoiceService.Priority =
                        response.urgency == "high" ? .high : .normal
                    VoiceService.shared.speak(
                        response.instruction,
                        priority: priority
                    )

                    isGuidanceRequestInFlight = false
                }
            } catch {
                await MainActor.run {
                    lastNavigationMeta =
                        "Navigation request failed: \(error.localizedDescription)"
                    isGuidanceRequestInFlight = false
                }
            }
        }
    }

    private var batteryIcon: String {
        switch ble.battery {
        case ...20:
            return "battery.25"
        case ...50:
            return "battery.50"
        case ...80:
            return "battery.75"
        default:
            return "battery.100"
        }
    }

    // ── Distance color ────────────────────────────────
    var distanceColor: Color {
        let cm = ble.distanceCm
        if cm < 30  { return .red }
        if cm < 60  { return .orange }
        if cm < 100 { return .yellow }
        return .green
    }

    // ── Distance label ────────────────────────────────
    var distanceLabel: String {
        let cm = ble.distanceCm
        if cm == 999 { return "Clear" }
        if cm < 30   { return "Danger — stop" }
        if cm < 60   { return "Warning — slow down" }
        if cm < 100  { return "Caution" }
        return "Clear"
    }

    // ── Status card ───────────────────────────────────
    func statusCard(label: String,
                    value: String,
                    icon:  String,
                    color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 14,
                                  weight: .semibold))
                    .foregroundColor(color)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // ── Control button ────────────────────────────────
    func controlButton(_ title: String,
                       icon: String,
                       color: Color,
                       action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13,
                                  weight: .medium))
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.1))
            .cornerRadius(8)
        }
        .accessibilityLabel(title)
    }
}

private struct CalibrationDebugPopupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var navigation: NavigationContextService

    private var snapshot: RouteCalibrationDebugSnapshot {
        APIService.shared.calibrationDebugSnapshot(
            latitude: navigation.latitude,
            longitude: navigation.longitude
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Calibration") {
                    row("Status", snapshot.active ? "Active" : "Inactive")
                    row("Heading offset", formatDegrees(snapshot.headingOffsetDegrees))
                    row("Meters per local unit", formatNumber(snapshot.metersPerUnit, decimals: 3))
                    row("Anchor", formatAnchor)
                }

                Section("Route context") {
                    row("Map ID", snapshot.mapId ?? "None")
                    row("Route ID", snapshot.routeId ?? "None")
                    row("Start node", snapshot.startNodeId ?? "None")
                    row("End node", snapshot.endNodeId ?? "None")
                    row("Route node count", "\(snapshot.routeNodeCount)")
                }

                Section("Nearest projected node") {
                    row("Node ID", snapshot.nearestNodeId ?? "None")
                    row("Distance", formatMeters(snapshot.nearestNodeDistanceM))
                }

                Section("Live context") {
                    row(
                        "Current location",
                        "\(String(format: "%.6f", navigation.latitude)), \(String(format: "%.6f", navigation.longitude))"
                    )
                    row("Heading", formatDegrees(navigation.headingDegrees))
                    row("Nearby hazards", "\(navigation.nearbyHazardsCount)")
                    if !navigation.autoRerouteStatus.isEmpty {
                        row("Reroute", navigation.autoRerouteStatus)
                    }
                    if !navigation.hazardPollStatus.isEmpty {
                        row("Hazard polling", navigation.hazardPollStatus)
                    }
                }
            }
            .navigationTitle("Calibration Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var formatAnchor: String {
        guard let lat = snapshot.anchorLat,
              let lng = snapshot.anchorLng
        else {
            return "None"
        }

        return "\(String(format: "%.6f", lat)), \(String(format: "%.6f", lng))"
    }

    private func formatNumber(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.*f", decimals, value)
    }

    private func formatDegrees(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f°", value)
    }

    private func formatMeters(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f m", value)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13, design: .monospaced))
        }
    }
}
