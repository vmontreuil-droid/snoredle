import AVFoundation
import SoundAnalysis
import Accelerate

/// Eén analyse-resultaat (± elke halve seconde).
struct AudioFrame: Sendable {
    let at: Date
    let decibel: Double            // geschatte dB(SPL), zie `calibrationOffset`
    let snoreConfidence: Double    // 0…1 van Apple's ingebouwde geluidsclassificatie
    let otherSounds: [String: Double] // bv. "speech", "cough", "dog" — voor ruisfilter
}

protocol SnoreDetectorDelegate: AnyObject {
    func detector(_ d: SnoreDetector, didProduce frame: AudioFrame)
    func detector(_ d: SnoreDetector, didFail error: Error)
}

/// Luistert via de microfoon en classificeert geluid met SoundAnalysis
/// (Apple's ingebouwde classifier kent het label "snoring"), en meet volume.
/// Draait de hele nacht in de achtergrond (UIBackgroundModes: audio).
final class SnoreDetector: NSObject {
    weak var delegate: SnoreDetectorDelegate?

    /// Rauwe audiobuffers, voor de clip-recorder.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// dBFS → benaderende dB(SPL). Kalibreerbaar in Instellingen.
    var calibrationOffset: Double = 94

    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "be.snoredle.analysis")
    private var lastDecibel: Double = 0
    private(set) var format: AVAudioFormat?

    /// Labels die op Apple's classifier lijken op ronken maar het niet zijn.
    static let interferingLabels = ["speech", "cough", "television", "music", "dog_bark", "cat_meow",
                                    "baby_crying", "fan", "air_conditioner", "rain", "vehicle"]

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        self.format = format

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.66
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.lastDecibel = self.decibel(of: buffer)
            self.onBuffer?(buffer, time)
            self.analysisQueue.async {
                analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }
        }
        engine.prepare()
        try engine.start()

        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer?.completeAnalysis()
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        NotificationCenter.default.removeObserver(self)
    }

    /// Telefoongesprek, Siri… → na afloop automatisch hervatten.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
    }

    private func decibel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        let dbfs = 20 * log10(Double(max(rms, 1e-7)))
        return max(0, dbfs + calibrationOffset)
    }
}

extension SnoreDetector: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let snore = result.classification(forIdentifier: "snoring")?.confidence ?? 0
        var others: [String: Double] = [:]
        for label in Self.interferingLabels {
            if let c = result.classification(forIdentifier: label)?.confidence, c > 0.3 { others[label] = c }
        }
        let frame = AudioFrame(at: .now, decibel: lastDecibel, snoreConfidence: snore, otherSounds: others)
        delegate?.detector(self, didProduce: frame)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        delegate?.detector(self, didFail: error)
    }
}
