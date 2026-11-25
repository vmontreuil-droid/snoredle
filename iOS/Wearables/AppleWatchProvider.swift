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
        guard let s = session, s.activationState == .activated, s.isPaired else { return false }
        // isWatchAppInstalled is soms even (onterecht) false: een recent seintje telt ook.
        return s.isWatchAppInstalled || isLive
    }
    /// De watch stuurde de laatste 3 minuten nog seintjes.
    var isLive: Bool { Date().timeIntervalSince(lastHeartbeat) < 180 }
    private(set) var lastHeartbeat = Date.distantPast

    private var currentSession: (UUID, WatchSettings)?
    private var watchdog: Timer?
    private var restarts = 0

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func startSession(id: UUID, settings: WatchSettings) {
        guard let s = session else { return }
        if s.activationState != .activated { s.activate() }
        // Niet meer afhankelijk van isWatchAppInstalled: dat stond vorige nacht onterecht op false,
        // waardoor de watch nooit gestart werd. Gekoppeld = proberen.
        guard s.isPaired || s.activationState != .activated else {
            DiagLog.shared.log("watch", "geen watch gekoppeld → niet gestart"); return
        }
        currentSession = (id, settings); restarts = 0
        launchWatch(id: id, settings: settings, reason: "start nacht")
        DispatchQueue.main.async {
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.checkWatchdog() }
        }
    }
    func stopSession(id: UUID) {
        currentSession = nil
        DispatchQueue.main.async { self.watchdog?.invalidate(); self.watchdog = nil }
        send(.stopSession(sessionID: id), reliable: true)
    }

    /// Start de watch-app (ook als die niet open staat) met een workoutsessie.
    private func launchWatch(id: UUID, settings: WatchSettings, reason: String) {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        HKHealthStore().startWatchApp(with: config) { ok, error in
            DiagLog.shared.log("watch", "watch-app starten (\(reason)): \(ok ? "gelukt" : "MISLUKT")\(error.map { " – \($0.localizedDescription)" } ?? "") · app op watch \(self.session?.isWatchAppInstalled ?? false)")
        }
        send(.startSession(sessionID: id, settings: settings), reliable: true)
    }

    /// Elke 2 min: geen seintjes meer? Dan de watch-app opnieuw starten.
    private func checkWatchdog() {
        guard let (id, settings) = currentSession else { return }
        guard Date().timeIntervalSince(lastHeartbeat) > 150 else { return }
        restarts += 1
        // Eerst vaak proberen, daarna om de 10 min.
        guard restarts <= 5 || restarts % 5 == 0 else { return }
        launchWatch(id: id, settings: settings, reason: "geen seintjes, poging \(restarts)")
    }
    /// Tikje klaarzetten. De watch haalt het op bij zijn volgende seintje (werkt ook 's nachts
    /// met de iPhone-app op de achtergrond). Is de watch rechtstreeks bereikbaar, dan meteen.
    func nudge(_ intensity: NudgeIntensity) {
        lock.lock(); pendingNudge = (intensity, Date()); lock.unlock()
        guard let s = session, s.activationState == .activated, s.isReachable,
              let data = try? WatchMessage.nudge(intensity: intensity).encoded() else {
            if isLive { DiagLog.shared.log("tikje", "watch niet rechtstreeks bereikbaar → wacht op volgend seintje") }
            else { DiagLog.shared.log("tikje", "watch stuurt geen seintjes → tikje kan niet geleverd worden") }
            return
        }
        // Rechtstreeks proberen; lukt het niet, dan blijft het klaarstaan voor het volgende seintje.
        lock.lock(); pendingNudge = nil; lock.unlock()
        s.sendMessageData(data, replyHandler: { [weak self] _ in
            self?.subject.send(.nudgeDelivered(.now))
        }, errorHandler: { [weak self] err in
            DiagLog.shared.log("tikje", "rechtstreeks mislukt: \(err.localizedDescription) → wacht op seintje")
            guard let self else { return }
            self.lock.lock(); if self.pendingNudge == nil { self.pendingNudge = (intensity, Date()) }; self.lock.unlock()
        })
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
            if !isLive { DiagLog.shared.log("watch", "seintjes komen binnen ✓"); DispatchQueue.main.async { self.subject.send(.availabilityChanged) } }
            lastHeartbeat = .now
            DiagLog.shared.heartbeat(position: hb.sample.position.label, movement: hb.movement)
            if let n = hb.steps, n > 0 { subject.send(.steps(n, hb.sample.at)) }
            subject.send(.upright(hb.sample.position == .upright, hb.sample.at))
            // Houding alleen doorgeven bij verandering of elke 5 min.
            if hb.sample.position != lastPositionSent || Date().timeIntervalSince(lastPositionAt) > 300 {
                lastPositionSent = hb.sample.position; lastPositionAt = .now
                subject.send(.position(hb.sample))
            }
            if hb.movement > 0.3 { subject.send(.vital(.movement, hb.movement, hb.sample.at)) }
            if let i = takePendingNudge(), let d = try? WatchMessage.nudge(intensity: i).encoded() {
                DiagLog.shared.log("tikje", "meegegeven in antwoord op seintje")
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
        case .positionSample, .heartRate, .movement, .heartbeat: lastHeartbeat = .now   // watch meet nog
        default: break
        }
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
        DiagLog.shared.log("watch", "verbinding geactiveerd: status \(state.rawValue), gekoppeld \(session.isPaired), app op watch \(session.isWatchAppInstalled)\(error.map { ", fout: \($0.localizedDescription)" } ?? "")")
        subject.send(.availabilityChanged)
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DiagLog.shared.log("watch", "watch-toestand gewijzigd: gekoppeld \(session.isPaired), app op watch \(session.isWatchAppInstalled)")
        subject.send(.availabilityChanged)
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DiagLog.shared.log("watch", "bereikbaar: \(session.isReachable)")
        subject.send(.availabilityChanged)
    }

    var isReachable: Bool { session?.isReachable ?? false }

    /// Korte uitleg voor op het startscherm.
    var statusHint: String? {
        guard let s = session else { return "Deze iPhone ondersteunt geen Apple Watch" }
        if s.activationState != .activated { return "Verbinding met je watch maken…" }
        if !s.isPaired { return "Geen Apple Watch gekoppeld" }
        if !s.isWatchAppInstalled && !isLive { return "Snoredle niet gevonden op je watch – open de app één keer op je watch" }
        return nil
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
