import AVFoundation

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
                try? file.write(from: buffer)
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
        let name = "snore-\(Int(Date().timeIntervalSince1970)).m4a"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let f = try AVAudioFile(forWriting: Self.url(for: name), settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            for b in ring { try f.write(from: b) }
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
