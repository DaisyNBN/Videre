import SwiftUI

struct ContentView: View {

    @EnvironmentObject var ble:   BLEManager
    @EnvironmentObject var lidar: LiDARService
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var navigation: NavigationContextService

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
                        Image(systemName: "battery.100")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                        Text("100%")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    }
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
                    Text("Navigate payload")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

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
                            try? await APIService.shared
                                .postNavigate(p)
                        }
                    } label: {
                        Text("Log navigate to console")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Log navigate payload to console")
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
