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

    private var running = false
    /// Laatste keer dat er audio binnenkwam (voor de waakhond in SessionManager).
    private(set) var lastBufferAt = Date()
    /// Wordt opgeroepen als de detector zichzelf herstart heeft (reden voor het logboek).
    var onRestart: ((String) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .default i.p.v. .measurement: in meetmodus speelt de speaker veel stiller af.
        // Geen .allowBluetooth: anders neemt een headset (AirPods) de microfoon over.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        try startEngine()
        running = true

        let nc = NotificationCenter.default
        nc.removeObserver(self)
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleConfigChange(_:)),
                       name: .AVAudioEngineConfigurationChange, object: engine)
        nc.addObserver(self, selector: #selector(handleMediaReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    /// Tap + analyse (opnieuw) opzetten met het huidige formaat van de microfoon.
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Snoredle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Geen microfoon beschikbaar"])
        }
        self.format = format

        analyzer?.completeAnalysis()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.66
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.lastBufferAt = Date()
            self.lastDecibel = self.decibel(of: buffer)
            self.onBuffer?(buffer, time)
            self.analysisQueue.async {
                analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }
        }
        engine.prepare()
        try engine.start()
        lastBufferAt = Date()
    }

    /// Volledig herstarten (na onderbreking, routewissel, of als de waakhond niets meer hoort).
    private var lastRestart = Date.distantPast
    func restart(reason: String) {
        guard running, Date().timeIntervalSince(lastRestart) > 3 else { return }
        lastRestart = Date()
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            onRestart?("\(reason) → herstart gelukt")
        } catch {
            onRestart?("\(reason) → herstart MISLUKT: \(error.localizedDescription)")
        }
    }

    /// Microfoon los, maar de audiosessie actief houden (anders pauzeert iOS de app op de achtergrond).
    func releaseMicrophone() {
        running = false
        NotificationCenter.default.removeObserver(self)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer?.completeAnalysis()
        analyzer = nil
    }

    func stop() {
        running = false
        NotificationCenter.default.removeObserver(self)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer?.completeAnalysis()
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Telefoongesprek, Siri, wekker… → na afloop automatisch hervatten.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            let why: String = switch reason {
            case .appWasSuspended: "app werd stilgezet door iOS"
            case .builtInMicMuted: "microfoon gedempt"
            case .routeDisconnected: "audioroute weg"
            default: "andere app, oproep, Siri of wekker"
            }
            onRestart?("ONDERBROKEN: \(why)")
        }
        if type == .ended { DispatchQueue.main.async { self.restart(reason: "onderbreking voorbij") } }
    }

    /// Andere audioroute (koptelefoon, Bluetooth, ander formaat): tap opnieuw installeren.
    @objc private func handleConfigChange(_ note: Notification) {
        DispatchQueue.main.async { self.restart(reason: "audioroute gewijzigd") }
    }

    @objc private func handleMediaReset(_ note: Notification) {
        DispatchQueue.main.async {
            guard self.running else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                             options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            self.restart(reason: "audiosysteem herstart")
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
        for label in Self.interferingLabels + NightSoundKind.allClassifierLabels {
            if let c = result.classification(forIdentifier: label)?.confidence, c > 0.3 { others[label] = c }
        }
        let frame = AudioFrame(at: .now, decibel: lastDecibel, snoreConfidence: snore, otherSounds: others)
        delegate?.detector(self, didProduce: frame)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        delegate?.detector(self, didFail: error)
    }
}
