import Foundation
import CoreMotion
import HealthKit
import WatchKit
import WatchConnectivity
import AVFoundation

/// Draait de hele nacht op de Apple Watch:
/// - houding via zwaartekrachtvector (CoreMotion) + kalibratieprofiel
/// - hartslag via een HKWorkoutSession (die ook de app wakker houdt in de achtergrond)
/// - beweging/onrust via versnelling
/// - tikjes (haptiek) op verzoek van de iPhone
@MainActor
final class NightTracker: NSObject, ObservableObject {
    static let shared = NightTracker()

    @Published private(set) var isTracking = false
    @Published private(set) var position: SleepPosition = .unknown
    @Published private(set) var heartRate: Double?
    @Published private(set) var calibrating: SleepPosition?
    @Published var profile = CalibrationProfile()
    @Published private(set) var phoneRecording = false
    @Published private(set) var pausedUntil: Date?

    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private var stepTotal = 0
    private var stepsReported = 0
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var settings = WatchSettings()
    private var sessionID: UUID?
    private var trackingSince = Date()

    private var gravityBuffer: [Vector3] = []
    private var accelBuffer: [Double] = []
    private var sampleTimer: Timer?
    private var pending: [Data] = []               // berichten als de iPhone onbereikbaar is
    private var lastSentPosition: SleepPosition?
    private var lastSentAt = Date.distantPast

    // MARK: Sessie

    func start(id: UUID, settings: WatchSettings) {
        guard !isTracking else { return }
        self.settings = settings
        sessionID = id
        isTracking = true
        trackingSince = .now
        startWorkout()
        startMotion()
        stepTotal = 0; stepsReported = 0
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: .now) { [weak self] data, _ in
                guard let n = data?.numberOfSteps.intValue else { return }
                Task { @MainActor in self?.stepTotal = n }
            }
        }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: settings.sampleIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitSample() }
        }
        sendStatus()
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        sampleTimer?.invalidate(); sampleTimer = nil
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        workout?.end()
        // Workout niet bewaren: het is geen training en mag je activiteitsringen niet beïnvloeden.
        let b = builder
        b?.endCollection(withEnd: .now) { _, _ in b?.discardWorkout() }
        workout = nil; builder = nil
        flushPending(force: true)
        sendStatus()
    }

    // MARK: Workout (achtergrond + hartslag)

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        do {
            let w = try HKWorkoutSession(healthStore: health, configuration: config)
            let b = w.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            b.delegate = self
            w.startActivity(with: .now)
            b.beginCollection(withStart: .now) { _, _ in }
            workout = w; builder = b
        } catch {
            // Zonder workout loopt motion enkel zolang de app op de voorgrond is.
        }
    }

    // MARK: Beweging

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = Vector3(x: m.gravity.x, y: m.gravity.y, z: m.gravity.z)
            let a = m.userAcceleration
            Task { @MainActor in
                self.gravityBuffer.append(g)
                self.accelBuffer.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
                if self.gravityBuffer.count > 120 { self.gravityBuffer.removeFirst() }
                if self.accelBuffer.count > 120 { self.accelBuffer.removeFirst() }
            }
        }
    }

    private func averageGravity(last n: Int) -> Vector3? {
        let slice = gravityBuffer.suffix(n)
        guard !slice.isEmpty else { return nil }
        let c = Double(slice.count)
        return Vector3(x: slice.map(\.x).reduce(0, +) / c,
                       y: slice.map(\.y).reduce(0, +) / c,
                       z: slice.map(\.z).reduce(0, +) / c)
    }

    private func emitSample() {
        // Veiligheid: nooit langer dan 14 uur meten (bv. als de iPhone-app afgesloten werd).
        if Date().timeIntervalSince(trackingSince) > 14 * 3600 { stop(); phoneRecording = false; return }
        let n = Int(settings.sampleIntervalSeconds)
        guard let g = averageGravity(last: n) else { return }
        let (pos, conf) = profile.classify(g)
        position = pos

        // Beweging genormaliseerd naar "per 10 seconden", los van het meetinterval.
        let recent = accelBuffer.suffix(n)
        let movement = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count) * 10
        accelBuffer.removeAll(keepingCapacity: true)
        let sample = PositionSamplePayload(position: pos, confidence: conf, gravity: g, at: .now)
        let newSteps = max(0, stepTotal - stepsReported)
        stepsReported = stepTotal
        sendHeartbeat(Heartbeat(sample: sample, movement: movement, heartRate: heartRate, steps: newSteps))
    }

    /// Seintje naar de iPhone; het antwoord kan een tikje bevatten. De watch→iPhone-richting werkt
    /// ook als de iPhone-app op de achtergrond staat (iOS maakt hem wakker).
    private func sendHeartbeat(_ hb: Heartbeat) {
        guard let data = try? WatchMessage.heartbeat(hb).encoded() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else {
            // iPhone even weg: houding en beweging bewaren voor later.
            if hb.sample.position != lastSentPosition || Date().timeIntervalSince(lastSentAt) > 300 {
                send(.positionSample(hb.sample)); lastSentPosition = hb.sample.position; lastSentAt = .now
            }
            if hb.movement > 0.5 { send(.movement(intensity: hb.movement, at: hb.sample.at)) }
            return
        }
        s.sendMessageData(data, replyHandler: { reply in
            guard !reply.isEmpty, let msg = try? WatchMessage.decode(reply) else { return }
            Task { @MainActor in
                if case .nudge(let i) = msg {
                    NightTracker.shared.nudge(i)
                    NightTracker.shared.sendReliable(.nudgeDone(at: .now))
                }
            }
        }, errorHandler: nil)
        lastSentPosition = hb.sample.position; lastSentAt = .now
    }

    // MARK: Kalibratie

    func calibrate(_ p: SleepPosition) {
        calibrating = p
        if !motion.isDeviceMotionActive { startMotion() }
        gravityBuffer.removeAll()
        Task {
            try? await Task.sleep(for: .seconds(5))
            if let g = averageGravity(last: 5) {
                profile.vectors[p] = g.normalized
                sendReliable(.calibrationCaptured(position: p, gravity: g.normalized))
                WKInterfaceDevice.current().play(.success)
            }
            calibrating = nil
            if !isTracking && guidedStep == nil { motion.stopDeviceMotionUpdates() }
        }
    }

    // MARK: Tikjes

    func nudge(_ intensity: NudgeIntensity) {
        let device = WKInterfaceDevice.current()
        switch intensity {
        case .gentle: device.play(.click)
        case .medium: device.play(.directionUp)
        case .strong:
            Task {
                for _ in 0..<3 { device.play(.notification); try? await Task.sleep(for: .milliseconds(700)) }
            }
        }
    }

    // MARK: Communicatie

    /// Komt altijd aan, ook als de iPhone-app even niet open is.
    func sendReliable(_ msg: WatchMessage) {
        guard let data = try? msg.encoded(), WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable { WCSession.default.sendMessageData(data, replyHandler: nil) { _ in
            WCSession.default.transferUserInfo(["msg": data]) } }
        else { WCSession.default.transferUserInfo(["msg": data]) }
    }

    /// Kalibratie volledig op de watch: 4 houdingen, telkens 10 s met trillingen als signaal.
    @Published private(set) var guidedStep: SleepPosition?
    @Published private(set) var guidedCountdown = 0

    func runGuidedCalibration() {
        guard guidedStep == nil else { return }
        // Houdt de app actief met het scherm uit (anders pauzeert watchOS de meting).
        let ownSession = !isTracking
        if ownSession { startWorkout() }
        if !motion.isDeviceMotionActive { startMotion() }
        Task {
            defer {
                if ownSession && !isTracking {
                    workout?.end()
                    let b = builder
                    b?.endCollection(withEnd: .now) { _, _ in b?.discardWorkout() }
                    workout = nil; builder = nil
                    motion.stopDeviceMotionUpdates()
                }
            }
            for p in SleepPosition.calibratable {
                guidedStep = p
                say("Lig nu \(p.instruction)")
                for _ in 0..<2 { WKInterfaceDevice.current().play(.notification); try? await Task.sleep(for: .milliseconds(600)) }
                for i in stride(from: 10, to: 0, by: -1) {
                    guidedCountdown = i
                    if i == 5 { calibrate(p) }
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guidedStep = nil
            guidedCountdown = 0
            WKInterfaceDevice.current().play(.success)
            say("Klaar. Je houdingen zijn gekalibreerd.")
        }
    }

    private let speech = AVSpeechSynthesizer()
    /// Gesproken instructie via de luidspreker van de watch.
    private func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "nl-BE") ?? AVSpeechSynthesisVoice(language: "nl-NL")
        u.rate = 0.48
        speech.speak(u)
    }

    func send(_ msg: WatchMessage) {
        guard let data = try? msg.encoded() else { return }
        let s = WCSession.default
        if s.activationState == .activated, s.isReachable {
            flushPending(force: false)
            s.sendMessageData(data, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.pending.append(data) }
            }
        } else {
            pending.append(data)
            if pending.count >= 30 { flushPending(force: true) }
        }
    }

    private func flushPending(force: Bool) {
        guard !pending.isEmpty, WCSession.default.activationState == .activated else { return }
        if force || WCSession.default.isReachable {
            WCSession.default.transferUserInfo(["batch": pending])
            pending.removeAll()
        }
    }

    /// Vraag de iPhone iets te doen (start/stop/pauze).
    func request(_ c: WatchCommand) {
        sendReliable(.request(c))
        WKInterfaceDevice.current().play(.click)
        // Meteen tonen; de iPhone bevestigt via sessionState.
        switch c {
        case .pause(let m): pausedUntil = Date().addingTimeInterval(Double(m * 60))
        case .resume: pausedUntil = nil
        default: break
        }
    }

    func sendStatus() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        send(.watchStatus(WatchStatus(isTracking: isTracking,
                                      batteryLevel: Double(WKInterfaceDevice.current().batteryLevel),
                                      isCalibrated: profile.isComplete)))
    }

    func handle(_ msg: WatchMessage) {
        switch msg {
        case .startSession(let id, let s):
            if isTracking {
                // Al gestart via de iPhone (workout): instellingen en meetinterval bijwerken.
                settings = s; sessionID = id
                sampleTimer?.invalidate()
                sampleTimer = Timer.scheduledTimer(withTimeInterval: s.sampleIntervalSeconds, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.emitSample() }
                }
                phoneRecording = true
                sendStatus()
            } else { start(id: id, settings: s); phoneRecording = true }
        case .stopSession: stop()
        case .nudge(let i):
            nudge(i)
        case .startCalibration(let p): calibrate(p)
        case .calibrationProfile(let p): profile = p
        case .sessionState(let rec, let until):
            // Net gestart? Dan kan dit een oude status zijn (van gisteren, via applicationContext)
            // die toevallig na de start binnenkomt — niet stoppen. Een echte stop komt via stopSession.
            if !rec && isTracking && Date().timeIntervalSince(trackingSince) < 180 { return }
            phoneRecording = rec
            pausedUntil = until
            if !rec && isTracking { stop() }
        default: break
        }
    }
}

extension NightTracker: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate), types.contains(hrType),
              let q = b.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: .count().unitDivided(by: .minute()))
        Task { @MainActor in
            self.heartRate = bpm
            self.send(.heartRate(bpm: bpm, at: .now))
        }
    }
}
