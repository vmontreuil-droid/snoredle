import Foundation
import Speech
import AVFoundation
import Accelerate

/// Zet praten in je slaap om naar tekst, op het toestel zelf (niets gaat naar het internet als
/// je toestel dat ondersteunt).
@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    @Published private(set) var busy = Set<String>()        // clipnamen die nu verwerkt worden
    @Published var error: String?

    func authorize() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(_ e: NightSoundEvent) async {
        guard let clip = e.clipFileName, !busy.contains(clip) else { return }
        guard await authorize() else { error = "Geef Snoredle toegang tot spraakherkenning in Instellingen."; return }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "nl-BE")) ?? SFSpeechRecognizer(locale: Locale(identifier: "nl-NL")),
              rec.isAvailable else { error = "Spraakherkenning is nu niet beschikbaar."; return }
        busy.insert(clip)
        defer { busy.remove(clip) }

        // Stille opnames eerst luider maken, anders herkent iOS niets.
        let original = ClipRecorder.url(for: clip)
        guard FileManager.default.fileExists(atPath: original.path) else { error = "Het geluidsfragment bestaat niet meer."; return }
        let url = (try? Self.normalizedCopy(of: original)) ?? original
        defer { if url != original { try? FileManager.default.removeItem(at: url) } }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true

        let text: String = await withCheckedContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, err in
                guard !done else { return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
                else if err != nil { done = true; c.resume(returning: "") }
            }
        }
        e.transcript = text.isEmpty ? "(onverstaanbaar)" : text
    }

    func transcribeAll(_ events: [NightSoundEvent]) async {
        for e in events where e.kind == .talking && e.clipFileName != nil && e.transcript == nil {
            await transcribe(e)
        }
    }

    static func normalizedCopy(of url: URL) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return url }
        try file.read(into: buf)
        if let d = buf.floatChannelData {
            var peak: Float = 0
            vDSP_maxmgv(d[0], 1, &peak, vDSP_Length(buf.frameLength))
            if peak > 0.0001 {
                var g = min(40, 0.9 / peak)
                for ch in 0..<Int(buf.format.channelCount) { vDSP_vsmul(d[ch], 1, &g, d[ch], 1, vDSP_Length(buf.frameLength)) }
            }
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let w = try AVAudioFile(forWriting: out, settings: file.processingFormat.settings)
        try w.write(from: buf)
        return out
    }
}
