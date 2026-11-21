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
    func nudge(_ intensity: NudgeIntensity) { send(.nudge(intensity: intensity), reliable: false) }
    func calibrate(_ position: SleepPosition) { send(.startCalibration(position: position), reliable: false) }
    func send(profile: CalibrationProfile) {
        // applicationContext overleeft herstarts: de watch heeft altijd het laatste profiel.
        guard let s = session, s.activationState == .activated,
              let data = try? WatchMessage.calibrationProfile(profile).encoded() else { return }
        try? s.updateApplicationContext(["profile": data])
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
