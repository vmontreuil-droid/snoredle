import AVFoundation
import Accelerate

/// Bewaart audiofragmenten van snurkepisodes, inclusief enkele seconden vóór de start
/// (pre-roll), zodat je 's ochtends kunt terugluisteren.
final class ClipRecorder {
    var preRollSeconds: Double = 4
    var maxClipSeconds: Double = 45

    private var ring: [AVAudioPCMBuffer] = []
    private var ringDuration: Double = 0
    private var file: AVAudioFile?
    private var writtenSeconds: Double = 0
    private var currentName: String?
    private let lock = NSLock()

    /// De microfoon neemt op zonder automatische versterking (voor correcte dB-metingen),
    /// waardoor fragmenten erg stil zijn. Voor het fragment versterken we ×8 met zachte begrenzing.
    static var clipGain: Float = 8

    static func amplified(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let i = src.floatChannelData, let o = out.floatChannelData else { return src }
        out.frameLength = src.frameLength
        let n = Int(src.frameLength)
        for ch in 0..<Int(src.format.channelCount) {
            var g = clipGain
            vDSP_vsmul(i[ch], 1, &g, o[ch], 1, vDSP_Length(n))
            var count = Int32(n)
            vvtanhf(o[ch], o[ch], &count)          // zachte begrenzing, geen vervorming bij luide snurken
        }
        return out
    }

    static var clipsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for name: String) -> URL { clipsDirectory.appendingPathComponent(name) }

    /// Aangeroepen voor elke microfoonbuffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        if let file {
            if writtenSeconds < maxClipSeconds {
                try? file.write(from: Self.amplified(buffer))
                writtenSeconds += seconds
            }
        } else {
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            ring.append(copy)
            ringDuration += seconds
            while ringDuration > preRollSeconds, let first = ring.first {
                ringDuration -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
    }

    /// Start een nieuwe clip. Geeft de bestandsnaam terug.
    func beginClip(format: AVAudioFormat) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard file == nil else { return currentName }
        // Unieke naam: twee fragmenten in dezelfde seconde mogen elkaar niet overschrijven.
        let name = "snore-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).m4a"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let f = try AVAudioFile(forWriting: Self.url(for: name), settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            for b in ring { try f.write(from: Self.amplified(b)) }
            writtenSeconds = ringDuration
            ring.removeAll(); ringDuration = 0
            file = f; currentName = name
            return name
        } catch {
            return nil
        }
    }

    func endClip() {
        lock.lock(); defer { lock.unlock() }
        file = nil          // AVAudioFile sluit bij deinit
        currentName = nil
        writtenSeconds = 0
    }

    /// Verwijdert clips ouder dan `days` die niet als favoriet gemarkeerd zijn.
    static func purge(olderThan days: Int, keeping favorites: Set<String>) {
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: clipsDirectory,
                                                      includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in files where !favorites.contains(url.lastPathComponent) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
            if created < limit { try? fm.removeItem(at: url) }
        }
    }
}
