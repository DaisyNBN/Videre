//
//  VoiceService.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//

import AVFoundation

class VoiceService: NSObject {

    static let shared = VoiceService()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken  = ""

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func speak(_ text: String, priority: Priority = .normal) {
        if priority == .high {
            synthesizer.stopSpeaking(at: .immediate)
        } else if synthesizer.isSpeaking {
            return
        }
        lastSpoken   = text
        let u        = AVSpeechUtterance(string: text)
        u.rate       = 0.52
        u.volume     = 1.0
        u.voice      = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(u)
    }

    func repeatLast() {
        guard !lastSpoken.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speak(lastSpoken)
    }

    enum Priority { case normal, high }
}
