import AVFoundation
import SwiftUI

/// Geluiden die Snoredle zelf genereert (geen audiobestanden nodig, geen licenties).
enum SynthSound: String, CaseIterable, Identifiable {
    case rain, ocean, fan, pink, brown, white, alarm
    var id: String { rawValue }
    static var sleepSounds: [SynthSound] { allCases.filter { $0 != .alarm } }

    var label: String {
        switch self {
        case .rain: "Regen"
        case .ocean: "Zee"
        case .fan: "Ventilator"
        case .pink: "Roze ruis"
        case .brown: "Bruine ruis"
        case .white: "Witte ruis"
        case .alarm: "Wekker"
        }
    }
    var symbol: String {
        switch self {
        case .rain: "cloud.rain.fill"
        case .ocean: "water.waves"
        case .fan: "fan.fill"
        case .pink: "waveform"
        case .brown: "waveform.path"
        case .white: "aqi.medium"
        case .alarm: "alarm.fill"
        }
    }
}

/// Toestand die de audiothread leest. Kleine races zijn hier onschuldig.
private final class SynthState {
    var sound: SynthSound = .pink
    var gain: Float = 0
    var target: Float = 0
    var step: Float = 0
    var sampleRate: Double = 44_100
    var t: Double = 0
    // filters
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var brown: Float = 0
    var lp: Float = 0
    var drop: Float = 0
    var dropDecay: Float = 0.999

    @inline(__always) func white() -> Float { Float.random(in: -1...1) }

    @inline(__always) func pink() -> Float {
        let w = white()
        b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
        let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return out * 0.11
    }

    @inline(__always) func brownNoise() -> Float {
        brown = (brown + 0.02 * white()) / 1.02
        return brown * 3.5
    }

    func sample() -> Float {
        let dt = 1 / sampleRate
        t += dt
        var v: Float
        switch sound {
        case .white: v = white() * 0.35
        case .pink: v = pink()
        case .brown: v = brownNoise()
        case .rain:
            if Float.random(in: 0...1) < 0.0006 { drop = Float.random(in: 0.2...0.6) }
            drop *= dropDecay
            v = pink() * 0.7 + white() * drop * 0.5
        case .ocean:
            let swell = Float(0.30 + 0.70 * pow(0.5 * (1 + sin(2 * .pi * 0.075 * t)), 2))
            v = brownNoise() * swell + pink() * 0.15 * swell
        case .fan:
            lp += 0.08 * (brownNoise() - lp)
            v = lp * 1.6 + Float(sin(2 * .pi * 110 * t)) * 0.015
        case .alarm:
            // Zachte gong: twee tonen, ritme 0,15 aan / 0,1 uit / 0,15 aan / 0,6 uit.
            let phase = t.truncatingRemainder(dividingBy: 1.0)
            let on = phase < 0.15 || (phase > 0.25 && phase < 0.40)
            let local = phase < 0.15 ? phase : phase - 0.25
            let env = on ? Float(exp(-local * 9)) : 0
            let f = phase < 0.15 ? 880.0 : 1320.0
            v = Float(sin(2 * .pi * f * t)) * env * 0.6
        }
        if gain != target {
            gain += step
            if (step > 0 && gain > target) || (step < 0 && gain < target) { gain = target }
        }
        return v * gain
    }
}

/// Kleine synthesizer op een eigen AVAudioEngine.
final class SoundSynth {
    private let engine = AVAudioEngine()
    private let state = SynthState()
    private var node: AVAudioSourceNode?
    private var stopWork: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.node != nil, !self.engine.isRunning else { return }
            try? self.engine.start()
        }
    }

    var isPlaying: Bool { node != nil && engine.isRunning }

    func play(_ sound: SynthSound, volume: Float, rampTo: Float? = nil, rampSeconds: Double = 1.5) {
        stopWork?.cancel()
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, options: [.mixWithOthers])
        }
        try? session.setActive(true)

        state.sound = sound
        if node == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            state.sampleRate = format.sampleRate
            let st = state
            let n = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(abl)
                guard let ptr = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<Int(frameCount) { ptr[i] = st.sample() }
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            node = n
            state.gain = 0
        }
        setVolume(rampTo ?? volume, over: rampTo == nil ? rampSeconds : rampSeconds, startingAt: rampTo == nil ? nil : volume)
        if !engine.isRunning { try? engine.start() }
    }

    func setVolume(_ v: Float, over seconds: Double = 0.3, startingAt start: Float? = nil) {
        if let start { state.gain = start }
        state.target = v
        let samples = Float(max(seconds, 0.01) * state.sampleRate)
        state.step = (v - state.gain) / samples
    }

    func stop(fade: Double = 2) {
        guard node != nil else { return }
        setVolume(0, over: fade)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let n = self.node else { return }
            self.engine.stop()
            self.engine.detach(n)
            self.node = nil
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.1, execute: work)
    }
}

/// Slaapgeluiden met timer, voor het inslapen.
@MainActor
final class SleepSoundController: ObservableObject {
    static let shared = SleepSoundController()
    @Published var sound: SynthSound = .rain
    @Published var volume: Double = 0.5 { didSet { if isPlaying { synth.setVolume(Float(volume)) } } }
    @Published var timerMinutes: Int = 30
    @Published private(set) var isPlaying = false
    @Published private(set) var endsAt: Date?

    private let synth = SoundSynth()
    private var timerTask: Task<Void, Never>?

    func play() {
        synth.play(sound, volume: Float(volume))
        isPlaying = true
        timerTask?.cancel()
        if timerMinutes > 0 {
            let end = Date().addingTimeInterval(Double(timerMinutes * 60))
            endsAt = end
            timerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double((self?.timerMinutes ?? 0) * 60)))
                guard !Task.isCancelled else { return }
                self?.stop(fade: 30)       // rustig uitfaden
            }
        } else {
            endsAt = nil
        }
    }

    func change(to s: SynthSound) {
        sound = s
        if isPlaying { synth.play(s, volume: Float(volume)) }
    }

    func stop(fade: Double = 2) {
        timerTask?.cancel()
        synth.stop(fade: fade)
        isPlaying = false
        endsAt = nil
    }
}

struct SleepSoundsSheet: View {
    @ObservedObject var c = SleepSoundController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(SynthSound.sleepSounds) { s in
                        let on = c.sound == s
                        Button { c.change(to: s) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: s.symbol).font(.title2)
                                    .symbolEffect(.variableColor.iterative, isActive: on && c.isPlaying)
                                Text(s.label).font(.footnote.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 92)
                            .foregroundStyle(on ? Theme.night : .primary)
                            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.06)),
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Volume", systemImage: "speaker.wave.2.fill").font(.subheadline.weight(.semibold))
                    Slider(value: $c.volume, in: 0.05...1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Stopt na", systemImage: "timer").font(.subheadline.weight(.semibold))
                    Picker("Timer", selection: $c.timerMinutes) {
                        Text("15 min").tag(15); Text("30 min").tag(30); Text("45 min").tag(45)
                        Text("1 uur").tag(60); Text("Nooit").tag(0)
                    }.pickerStyle(.segmented)
                    Text("Tijdens het geluid meet Snoredle geen snurken. Daarna faden de geluiden rustig uit en begint de meting.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    c.isPlaying ? c.stop() : c.play()
                } label: {
                    Label(c.isPlaying ? "Stop" : "Afspelen", systemImage: c.isPlaying ? "stop.fill" : "play.fill")
                        .font(.headline).foregroundStyle(Theme.night)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                Spacer()
            }
            .padding(20)
            .background(NightBackground())
            .navigationTitle("Slaapgeluiden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Klaar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
