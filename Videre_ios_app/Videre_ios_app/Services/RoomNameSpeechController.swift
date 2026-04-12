import AVFoundation
import Combine
import Foundation
import Speech

/// Owns `AVAudioEngine` / speech recognition. `View` structs cannot call
/// `mutating` methods from `Button` actions; this reference type fixes that.
final class RoomNameSpeechController: NSObject, ObservableObject {

    @Published var roomName         = ""
    @Published var isListening      = false
    @Published var speechError      = ""
    /// After a capture finishes, ignore further recognition until user
    /// explicitly starts again (avoids drift / late callbacks).
    @Published var isRoomNameLocked = false

    private let speechRecognizer = SFSpeechRecognizer(
        locale: Locale(identifier: "en-US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.speechError =
                        "Speech permission denied. Check Settings."
                    return
                }
                self.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        performStopCapture(lockName: false)
        isRoomNameLocked = false
        isListening      = true
        speechError      = ""

        VoiceService.shared.speak("Speak the room name.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            do {
                try self.startAudioEngine()
            } catch {
                self.performStopCapture(lockName: false)
                self.speechError =
                    "Microphone error: \(error.localizedDescription)"
            }
        }
    }

    private func startAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let node = audioEngine.inputNode
        var format = node.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            format = node.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "RoomNameSpeech",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Microphone format not ready. Check mic permission."])
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }

        request.shouldReportPartialResults = true

        recognitionTask = speechRecognizer?
            .recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        // Ignore late callbacks after capture ended / locked.
                        guard self.isListening else { return }
                        if !spoken.isEmpty {
                            self.roomName = spoken
                        }
                        if result.isFinal {
                            self.speechError = ""
                            self.performStopCapture(lockName: true)
                            if !spoken.isEmpty {
                                VoiceService.shared.speak(
                                    "Room name set to \(spoken).")
                            }
                        }
                    }
                }

                if let error {
                    DispatchQueue.main.async {
                        self.performStopCapture(
                            lockName: !self.roomName.isEmpty)
                        // Cancelled task often reports an error after a good
                        // final result — do not overwrite a locked name UX.
                        guard !self.isRoomNameLocked else { return }
                        self.speechError =
                            "Error: \(error.localizedDescription)"
                    }
                }
            }

        node.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            guard self.isListening else { return }
            self.speechError = ""
            self.performStopCapture(lockName: true)
            if !self.roomName.isEmpty {
                VoiceService.shared.speak(
                    "Room name set to \(self.roomName).")
            } else {
                VoiceService.shared.speak(
                    "No room name heard. Try again.")
            }
        }
    }

    /// User tapped stop, or stopping before a new capture.
    func stopListening() {
        performStopCapture(lockName: true)
    }

    /// Tear down audio + recognition. When `lockName` is true and
    /// `roomName` is non-empty, further recognition cannot change it
    /// until the user starts a new capture (`beginRecognition` unlocks).
    private func performStopCapture(lockName: Bool) {
        let finish = { [weak self] in
            guard let self else { return }
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            if self.tapInstalled {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.recognitionRequest?.endAudio()
            self.recognitionRequest = nil
            self.recognitionTask?.cancel()
            self.recognitionTask    = nil
            self.isListening = false
            if lockName, !self.roomName.isEmpty {
                self.isRoomNameLocked = true
            }
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    func clearRoomName() {
        roomName         = ""
        isRoomNameLocked = false
    }
}
