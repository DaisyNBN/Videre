import SwiftUI

struct ScanView: View {

    @EnvironmentObject var scan:  ScanService
    @EnvironmentObject var lidar: LiDARService

    @StateObject private var roomSpeech = RoomNameSpeechController()

    @State private var showLandmarkSheet = false
    @State private var landmarkType      = "door"
    @State private var landmarkLabel     = ""
    @State private var contributionNotes = ""

    let landmarkTypes = ["door", "stairs", "elevator",
                         "toilet", "exit", "hazard", "other"]

    /// Demo uses `ScanDemoConfig.hardcodedRoomName`; otherwise voice capture.
    private var effectiveRoomName: String {
        ScanDemoConfig.useHardcodedRoomName
            ? ScanDemoConfig.hardcodedRoomName
            : roomSpeech.roomName
    }

    private var canStartScan: Bool {
        ScanDemoConfig.useHardcodedRoomName
            || !roomSpeech.roomName.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── Header ────────────────────────────
                Text("Room scan")
                    .font(.system(size: 22,
                                  weight: .semibold))
                    .frame(maxWidth: .infinity,
                           alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                // ── LiDAR status ──────────────────────
                HStack(spacing: 8) {
                    Circle()
                        .fill(lidar.isRunning
                              ? Color.cyan : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(lidar.isRunning
                         ? "LiDAR active"
                         : "LiDAR off — turn on for depth data")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)

                Divider()

                if !scan.isScanning {

                    // ── Room name (demo hardcode or voice) ──────────
                    VStack(alignment: .leading,
                           spacing: 10) {

                        Text("Room name")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        if ScanDemoConfig.useHardcodedRoomName {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 14))
                                Text(ScanDemoConfig.hardcodedRoomName)
                                    .font(.system(
                                        size: 15,
                                        weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            Text("Hackathon demo — change string in ScanDemoConfig.swift")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                        }

                        // show recognised text
                        if !ScanDemoConfig.useHardcodedRoomName
                            && !roomSpeech.roomName.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName:
                                    "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                Text(roomSpeech.roomName)
                                    .font(.system(
                                        size: 15,
                                        weight: .medium))
                                    .foregroundColor(.primary)
                                if roomSpeech.isRoomNameLocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .accessibilityLabel("Locked")
                                }
                                Spacer()
                                Button {
                                    roomSpeech.clearRoomName()
                                } label: {
                                    Image(systemName:
                                        "xmark.circle.fill")
                                        .foregroundColor(
                                            .secondary)
                                        .font(.system(
                                            size: 16))
                                }
                                .accessibilityLabel("Clear room name")
                            }
                            .padding(.horizontal, 20)
                        }

                        if !ScanDemoConfig.useHardcodedRoomName {
                            // mic button
                            Button {
                                if roomSpeech.isListening {
                                    roomSpeech.stopListening()
                                } else {
                                    roomSpeech.startListening()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName:
                                        roomSpeech.isListening
                                        ? "stop.circle.fill"
                                        : "mic.circle.fill")
                                        .font(.system(size: 18))
                                    Text(roomSpeech.isListening
                                         ? "Listening... tap to stop"
                                         : roomSpeech.roomName.isEmpty
                                           ? "Tap to speak room name"
                                         : roomSpeech.isRoomNameLocked
                                           ? "Tap to record a new name"
                                           : "Tap to change room name")
                                        .font(.system(
                                            size: 15,
                                            weight: .medium))
                                }
                                .foregroundColor(
                                    roomSpeech.isListening ? .red : .blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    roomSpeech.isListening
                                    ? Color.red.opacity(0.1)
                                    : Color.blue.opacity(0.1)
                                )
                                .cornerRadius(12)
                            }
                            .padding(.horizontal, 20)
                            .accessibilityLabel(
                                roomSpeech.isListening
                                ? "Stop listening"
                                : "Speak room name")

                            if !roomSpeech.speechError.isEmpty {
                                Text(roomSpeech.speechError)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 20)
                            }
                        }
                    }

                    // ── Start button ───────────────────
                    Button {
                        guard canStartScan else {
                            VoiceService.shared.speak(
                                "Please speak the room name first.")
                            return
                        }
                        scan.startScan(roomName: effectiveRoomName)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName:
                                    "record.circle.fill")
                                .font(.system(size: 16))
                            Text("Start scan")
                                .font(.system(
                                    size: 16,
                                    weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canStartScan
                                    ? Color.green
                                    : Color.gray)
                        .cornerRadius(12)
                    }
                    .disabled(!canStartScan)
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Start room scan")

                } else {

                    // ── Scanning stats ─────────────────
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 10
                    ) {
                        statCard("Points",
                                 "\(scan.pointCount)",
                                 color: .blue)
                        statCard("Keyframes",
                                 "\(scan.keyframeCount)",
                                 color: .orange)
                        statCard("Landmarks",
                                 "\(scan.landmarkCount)",
                                 color: .green)
                    }
                    .padding(.horizontal, 20)

                    // ── Add landmark ───────────────────
                    Button {
                        showLandmarkSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName:
                                    "mappin.and.ellipse")
                                .font(.system(size: 14))
                            Text("Mark landmark here")
                                .font(.system(
                                    size: 14,
                                    weight: .medium))
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Color.blue.opacity(0.1))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityLabel(
                        "Add landmark at current position")

                    // ── Stop button ────────────────────
                    Button {
                        scan.stopScan()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName:
                                    "stop.circle.fill")
                                .font(.system(size: 16))
                            Text("Stop and upload")
                                .font(.system(
                                    size: 16,
                                    weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityLabel(
                        "Stop scan and upload")
                }

                // ── Upload status ──────────────────────
                if !scan.uploadStatus.isEmpty {
                    HStack(spacing: 8) {
                        if scan.isUploading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName:
                                scan.uploadStatus
                                    .contains("complete")
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle")
                                .foregroundColor(
                                    scan.uploadStatus
                                        .contains("complete")
                                    ? .green : .orange)
                        }
                        Text(scan.uploadStatus)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)

                    if !scan.backendScanId.isEmpty {
                        Text("Scan ID: \(scan.backendScanId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if scan.aiDetectionsCount > 0 {
                        Text("AI detections: \(scan.aiDetectionsCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !scan.backendMapId.isEmpty {
                        Text("Map ID: \(scan.backendMapId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !scan.backendRouteId.isEmpty {
                        Text("Route ID: \(scan.backendRouteId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !scan.backendMapId.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Map review")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button {
                                    scan.refreshMapLandmarks()
                                } label: {
                                    Text("Refresh landmarks")
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(8)
                                }

                                Button {
                                    scan.submitContribution(notes: contributionNotes)
                                    contributionNotes = ""
                                } label: {
                                    Text("Submit contribution")
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(8)
                                }
                            }

                            TextField("Contribution notes", text: $contributionNotes)
                                .font(.system(size: 12))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)

                            if !scan.mapActionStatus.isEmpty {
                                Text(scan.mapActionStatus)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            ForEach(scan.mapLandmarks.prefix(5)) { landmark in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(landmark.label) [\(landmark.type)]")
                                        .font(.system(size: 12, weight: .semibold))

                                    Text(
                                        "status: \(landmark.status)" +
                                            (landmark.confidence != nil
                                             ? ", confidence: \(String(format: "%.2f", landmark.confidence!))"
                                             : "")
                                    )
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)

                                    HStack(spacing: 8) {
                                        Button {
                                            scan.verifyLandmark(
                                                landmarkId: landmark.id,
                                                approve: true,
                                                notes: "Verified from iOS map review"
                                            )
                                        } label: {
                                            Text("Verify")
                                                .font(.system(size: 12, weight: .medium))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(Color.green.opacity(0.15))
                                                .cornerRadius(8)
                                        }

                                        Button {
                                            scan.verifyLandmark(
                                                landmarkId: landmark.id,
                                                approve: false,
                                                notes: "Rejected from iOS map review"
                                            )
                                        } label: {
                                            Text("Reject")
                                                .font(.system(size: 12, weight: .medium))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(Color.red.opacity(0.15))
                                                .cornerRadius(8)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                Divider()

                // ── How it works ──────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("How scanning works")
                        .font(.system(size: 13,
                                      weight: .medium))
                        .foregroundColor(.secondary)

                    infoRow(ScanDemoConfig.useHardcodedRoomName
                            ? "Room name is set for demo"
                            : "Speak the room name")
                    infoRow("Walk slowly through the room")
                    infoRow("Path points sampled about every 0.5s")
                    infoRow("LiDAR captures depth every 1s")
                    infoRow("Camera captures frames every 2s")
                    infoRow("ARKit may add door/wall landmarks from mesh")
                    infoRow("Mark doors, stairs and hazards")
                    infoRow("Stop when done — auto uploads")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }

        // ── Landmark sheet ────────────────────────────
        .sheet(isPresented: $showLandmarkSheet) {
            VStack(spacing: 16) {

                Text("Add landmark")
                    .font(.system(size: 18,
                                  weight: .semibold))
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Type")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Picker("Type",
                           selection: $landmarkType) {
                        ForEach(landmarkTypes,
                                id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Label (optional)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    TextField("e.g. Main door",
                              text: $landmarkLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                }
                .padding(.horizontal, 20)

                Button {
                    let label = landmarkLabel.isEmpty
                        ? landmarkType
                        : landmarkLabel
                    scan.addLandmark(
                        type:  landmarkType,
                        label: label)
                    landmarkLabel     = ""
                    showLandmarkSheet = false
                    VoiceService.shared.speak(
                        "\(landmarkType) marked.")
                } label: {
                    Text("Add landmark")
                        .font(.system(size: 16,
                                      weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)

                Button("Cancel") {
                    showLandmarkSheet = false
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
        }
    }

    // ── Helpers ───────────────────────────────────────
    func statCard(_ label: String,
                  _ value: String,
                  color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20,
                              weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    func infoRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.blue.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
