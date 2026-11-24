import AVFoundation
import SwiftUI

/// Geluid dat de iPhone speelt als je snurkt (naast of zonder het tikje van de watch).
enum NudgeSound: String, CaseIterable, Identifiable {
    case none, chime, beep, whistle, voice
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Geen geluid"
        case .chime: "Belletje"
        case .beep: "Piep"
        case .whistle: "Fluitje"
        case .voice: "Stem: \u{201C}Draai je even om\u{201D}"
        }
    }
}

@MainActor
final class NudgeSoundPlayer {
    static let shared = NudgeSoundPlayer()
    private let synth = SoundSynth()
    private let speech = AVSpeechSynthesizer()

    func speak(_ text: String, volume: Float) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "nl-BE") ?? AVSpeechSynthesisVoice(language: "nl-NL")
        u.volume = volume
        u.rate = 0.47
        speech.speak(u)
    }

    func play(_ sound: NudgeSound? = nil, volume: Double? = nil) {
        let s = sound ?? NudgeSound(rawValue: AppSettings.shared.nudgeSoundRaw) ?? .none
        let vol = Float(volume ?? AppSettings.shared.nudgeSoundVolume)
        switch s {
        case .none: return
        case .voice:
            let u = AVSpeechUtterance(string: "Draai je even om.")
            u.voice = AVSpeechSynthesisVoice(language: "nl-BE") ?? AVSpeechSynthesisVoice(language: "nl-NL")
            u.volume = vol
            u.rate = 0.47
            speech.speak(u)
        default:
            let kind: SynthSound = s == .chime ? .chime : (s == .beep ? .beep : .whistle)
            synth.play(kind, volume: vol, rampSeconds: 0.05)
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                synth.stop(fade: 0.3)
            }
        }
    }
}
