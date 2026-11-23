import Foundation
import WatchConnectivity
import HealthKit
import Combine

/// Verbinding met de Snoredle-app op de Apple Watch via WatchConnectivity.
final class AppleWatchProvider: NSObject, WearableProvider, WCSessionDelegate {
    let name = "Apple Watch"
    let capabilities: WearableCapabilities = [.position, .heartRate, .movement, .haptics, .calibration]
    private let subject = PassthroughSubject<WearableEvent, Never>()
    var events: AnyPublisher<WearableEvent, Never> { subject.eraseToAnyPublisher() }

    private var lastProfileData: Data?
    private var lastStateData: Data?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    var isAvailable: Bool {
        guard let s = session else { return false }
        return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
    }

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func startSession(id: UUID, settings: WatchSettings) {
        guard isAvailable else { return }
        // Start de watch-app (ook als die niet open staat) met een workoutsessie.
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        HKHealthStore().startWatchApp(with: config) { _, _ in }
        send(.startSession(sessionID: id, settings: settings), reliable: true)
    }
    func stopSession(id: UUID) { send(.stopSession(sessionID: id), reliable: true) }
    /// Tikje klaarzetten. De watch haalt het op bij zijn volgende seintje (werkt ook 's nachts
    /// met de iPhone-app op de achtergrond). Is de watch rechtstreeks bereikbaar, dan meteen.
    func nudge(_ intensity: NudgeIntensity) {
        lock.lock(); pendingNudge = (intensity, Date()); lock.unlock()
        guard let s = session, s.activationState == .activated, s.isReachable,
              let data = try? WatchMessage.nudge(intensity: intensity).encoded() else { return }
        s.sendMessageData(data, replyHandler: { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pendingNudge = nil; self.lock.unlock()
            self.subject.send(.nudgeDelivered(.now))
        }, errorHandler: nil)
    }

    private let lock = NSLock()
    private var pendingNudge: (NudgeIntensity, Date)?
    private var lastPositionSent: SleepPosition?
    private var lastPositionAt = Date.distantPast

    private func takePendingNudge() -> NudgeIntensity? {
        lock.lock(); defer { lock.unlock() }
        guard let (i, at) = pendingNudge else { return nil }
        pendingNudge = nil
        return Date().timeIntervalSince(at) < 90 ? i : nil      // te oud = niet meer tikken
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let msg = try? WatchMessage.decode(messageData) else { replyHandler(Data()); return }
        if case .heartbeat(let hb) = msg {
            // Houding alleen doorgeven bij verandering of elke 5 min.
            if hb.sample.position != lastPositionSent || Date().timeIntervalSince(lastPositionAt) > 300 {
                lastPositionSent = hb.sample.position; lastPositionAt = .now
                subject.send(.position(hb.sample))
            }
            if hb.movement > 0.3 { subject.send(.vital(.movement, hb.movement, hb.sample.at)) }
            if let i = takePendingNudge(), let d = try? WatchMessage.nudge(intensity: i).encoded() {
                replyHandler(d)
            } else {
                replyHandler(Data())
            }
        } else {
            handle(messageData)
            replyHandler(Data())
        }
    }
    func calibrate(_ position: SleepPosition) { send(.startCalibration(position: position), reliable: false) }
    func send(profile: CalibrationProfile) {
        // applicationContext overleeft herstarts: de watch heeft altijd het laatste profiel.
        guard let s = session, s.activationState == .activated,
              let data = try? WatchMessage.calibrationProfile(profile).encoded() else { return }
        lastProfileData = data
        var ctx: [String: Any] = ["profile": data]
        if let st = lastStateData { ctx["state"] = st }
        try? s.updateApplicationContext(ctx)
    }

    func sendState(recording: Bool, pausedUntil: Date?) {
        guard let s = session, s.activationState == .activated,
              let data = try? WatchMessage.sessionState(recording: recording, pausedUntil: pausedUntil).encoded() else { return }
        lastStateData = data
        var ctx: [String: Any] = ["state": data]
        if let p = lastProfileData { ctx["profile"] = p }
        try? s.updateApplicationContext(ctx)
        if s.isReachable { s.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
    }

    /// `reliable` = in de wachtrij zetten als de watch even onbereikbaar is.
    private func send(_ msg: WatchMessage, reliable: Bool) {
        guard let s = session, s.activationState == .activated, let data = try? msg.encoded() else { return }
        if s.isReachable {
            s.sendMessageData(data, replyHandler: nil) { _ in
                if reliable { s.transferUserInfo(["msg": data]) }
            }
        } else if reliable {
            s.transferUserInfo(["msg": data])
        }
    }

    /// Testtik met bevestiging van de watch. Geeft een Nederlandse statusmelding terug.
    func testNudge(_ intensity: NudgeIntensity) async -> String {
        guard let s = session else { return "Deze iPhone ondersteunt geen Apple Watch-verbinding." }
        if s.activationState != .activated { s.activate(); return "Verbinding met de watch wordt opgestart. Probeer over enkele seconden opnieuw." }
        if !s.isPaired { return "Er is geen Apple Watch gekoppeld met deze iPhone." }
        if !s.isWatchAppInstalled {
            return "De Snoredle-app staat nog niet op je watch. Open op je iPhone de Watch-app › Beschikbare apps › Snoredle › Installeer."
        }
        if !s.isReachable {
            return "Je watch is niet bereikbaar. Open Snoredle op je watch (scherm aan) en probeer opnieuw."
        }
        guard let data = try? WatchMessage.nudge(intensity: intensity).encoded() else { return "Interne fout." }
        return await withCheckedContinuation { cont in
            var done = false
            s.sendMessageData(data, replyHandler: { _ in
                if !done { done = true; cont.resume(returning: "Tikje gegeven ✓") }
            }, errorHandler: { error in
                if !done { done = true; cont.resume(returning: "Versturen mislukt: \(error.localizedDescription)") }
            })
        }
    }

    // MARK: ontvangen
    private func handle(_ data: Data) {
        guard let msg = try? WatchMessage.decode(data) else { return }
        switch msg {
        case .positionSample(let p): subject.send(.position(p))
        case .heartRate(let bpm, let at): subject.send(.vital(.heartRate, bpm, at))
        case .movement(let i, let at): subject.send(.vital(.movement, i, at))
        case .calibrationCaptured(let pos, let g): subject.send(.calibrated(pos, g))
        case .watchStatus(let s): subject.send(.status(s))
        case .request(let c): subject.send(.command(c))
        case .nudgeDone(let at): subject.send(.nudgeDelivered(at))
        case .heartbeat(let hb):
            subject.send(.position(hb.sample))
            if hb.movement > 0.3 { subject.send(.vital(.movement, hb.movement, hb.sample.at)) }
        default: break
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) { handle(messageData) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let d = userInfo["msg"] as? Data { handle(d) }
        // Batch van posities die offline verzameld werden
        if let batch = userInfo["batch"] as? [Data] { batch.forEach(handle) }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        subject.send(.availabilityChanged)
    }
    func sessionWatchStateDidChange(_ session: WCSession) { subject.send(.availabilityChanged) }
    func sessionReachabilityDidChange(_ session: WCSession) { subject.send(.availabilityChanged) }

    var isReachable: Bool { session?.isReachable ?? false }

    /// Korte uitleg voor op het startscherm.
    var statusHint: String? {
        guard let s = session else { return "Deze iPhone ondersteunt geen Apple Watch" }
        if s.activationState != .activated { return "Verbinding met je watch maken…" }
        if !s.isPaired { return "Geen Apple Watch gekoppeld" }
        if !s.isWatchAppInstalled { return "Installeer Snoredle op je watch via de Watch-app" }
        return nil
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
