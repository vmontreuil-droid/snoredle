import Foundation
import CoreMotion
import HealthKit
import WatchKit
import WatchConnectivity

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

    private let motion = CMMotionManager()
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var settings = WatchSettings()
    private var sessionID: UUID?

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
        startWorkout()
        startMotion()
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
        let n = Int(settings.sampleIntervalSeconds)
        guard let g = averageGravity(last: n) else { return }
        let (pos, conf) = profile.classify(g)
        position = pos

        let movement = accelBuffer.suffix(n).reduce(0, +)
        accelBuffer.removeAll(keepingCapacity: true)
        if movement > 0.5 { send(.movement(intensity: movement, at: .now)) }

        // Alleen versturen bij verandering of elke 5 min — spaart batterij.
        if pos != lastSentPosition || Date().timeIntervalSince(lastSentAt) > 300 {
            send(.positionSample(PositionSamplePayload(position: pos, confidence: conf, gravity: g, at: .now)))
            lastSentPosition = pos; lastSentAt = .now
        }
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
            if !isTracking { motion.stopDeviceMotionUpdates() }
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
        Task {
            for p in SleepPosition.calibratable {
                guidedStep = p
                WKInterfaceDevice.current().play(.start)
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
        }
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

    func sendStatus() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        send(.watchStatus(WatchStatus(isTracking: isTracking,
                                      batteryLevel: Double(WKInterfaceDevice.current().batteryLevel),
                                      isCalibrated: profile.isComplete)))
    }

    func handle(_ msg: WatchMessage) {
        switch msg {
        case .startSession(let id, let s):
            if isTracking { settings = s; sessionID = id; sendStatus() } else { start(id: id, settings: s) }
        case .stopSession: stop()
        case .nudge(let i):
            if !settings.nudgeOnlyOnBack || position == .back || position == .unknown { nudge(i) }
        case .startCalibration(let p): calibrate(p)
        case .calibrationProfile(let p): profile = p
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
