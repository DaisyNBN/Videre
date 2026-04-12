import SwiftUI

struct ContentView: View {

    @EnvironmentObject var ble:   BLEManager
    @EnvironmentObject var lidar: LiDARService
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var navigation: NavigationContextService
    @State private var lastNavigationInstruction: String = ""
    @State private var lastNavigationMeta: String = ""
    @State private var showCalibrationPopup: Bool = false

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

                // ── Navigate API payload (matches backend NavRequest) ──
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Navigate payload")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Menu {
                            Button(showCalibrationPopup
                                   ? "Hide calibration popup"
                                   : "Show calibration popup") {
                                showCalibrationPopup.toggle()
                            }
                        } label: {
                            Label("Debug menu", systemImage: "ellipsis.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 20)

                    Toggle(isOn: Binding(
                        get: { appState.walkState == .walking },
                        set: { on in
                            appState.walkState = on ? .walking : .idle
                        }
                    )) {
                        Text("Walking (speed in JSON)")
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 20)

                    if !navigation.locationAuthorized {
                        Text("Location: using default lat/lng until you allow access")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 20)
                    }

                    Text("Nearby hazards (backend): \(navigation.nearbyHazardsCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)

                    if !navigation.hazardPollStatus.isEmpty {
                        Text(navigation.hazardPollStatus)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !navigation.autoRerouteStatus.isEmpty {
                        Text(navigation.autoRerouteStatus)
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

                    Button {
                        Task {
                            let p = navigation.payload(
                                ble: ble,
                                lidar: lidar,
                                appState: appState)
                            do {
                                let response = try await APIService.shared
                                    .postNavigate(p)

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
                                }
                            } catch {
                                await MainActor.run {
                                    lastNavigationMeta =
                                        "Navigation request failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    } label: {
                        Text("Get backend guidance")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Request navigation guidance from backend")

                    if let activeRouteId = APIService.shared.activeRouteId,
                       !activeRouteId.isEmpty {
                        Text("Active route: \(activeRouteId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !lastNavigationInstruction.isEmpty {
                        Text(lastNavigationInstruction)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                    }

                    if !lastNavigationMeta.isEmpty {
                        Text(lastNavigationMeta)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
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
