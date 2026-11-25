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
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    func speak(_ text: String, volume: Float) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "nl-BE") ?? AVSpeechSynthesisVoice(language: "nl-NL")
        u.volume = volume
        u.rate = 0.47
        speech.speak(u)
    }

    /// Mediavolume van de iPhone (0…1). Ons volume is een percentage hiervan.
    static var systemVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    /// `level` 0 = eerste keer; bij elk volgend geluid in dezelfde snurkperiode luider en langer.
    /// Geeft een korte beschrijving terug voor het logboek.
    @discardableResult
    func play(_ sound: NudgeSound? = nil, volume: Double? = nil, level: Int = 0) -> String {
        let s = sound ?? NudgeSound(rawValue: AppSettings.shared.nudgeSoundRaw) ?? .none
        let base = Float(volume ?? AppSettings.shared.nudgeSoundVolume)
        let vol = min(1, base * (1 + 0.25 * Float(level)))
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? session.setCategory(.playback, options: [.mixWithOthers]) }
        try? session.setActive(true)
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let info = "volume \(Int(vol * 100))% van mediavolume \(Int(Self.systemVolume * 100))%, uitgang \(route)"
        switch s {
        case .none: return "geen geluid gekozen"
        case .voice:
            speak(level >= 2 ? "Draai je even om. Je snurkt." : "Draai je even om.", volume: vol)
            return "stem · " + info
        default:
            let kind: SynthSound = s == .chime ? .chime : (s == .beep ? .beep : .whistle)
            guard let url = SoundSynth.renderFile(kind, seconds: 2.4) else { return "FOUT: geluid kon niet aangemaakt worden" }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = vol
                p.numberOfLoops = min(level, 2)          // bij herhaling 2× of 3× na elkaar
                p.prepareToPlay()
                let ok = p.play()
                player = p
                return (ok ? "\(s.label) · " : "FOUT: afspelen geweigerd · ") + info
            } catch {
                return "FOUT: \(error.localizedDescription)"
            }
        }
    }
}
