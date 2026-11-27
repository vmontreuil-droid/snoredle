import SwiftUI
import WatchKit
import WatchConnectivity
import HealthKit

@main
struct SnoredleWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @StateObject private var tracker = NightTracker.shared
    private let connector = WatchConnector.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView().environmentObject(tracker)
                .task {
                    let types: Set<HKObjectType> = [HKQuantityType(.heartRate)]
                    try? await HKHealthStore().requestAuthorization(toShare: [HKObjectType.workoutType()], read: types)
                }
        }
    }
}

/// Wordt gestart door de iPhone via `HKHealthStore.startWatchApp`.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Ook bij een start op de achtergrond (zonder scherm) meteen de verbinding opzetten.
    func applicationDidFinishLaunching() { _ = WatchConnector.shared }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        _ = WatchConnector.shared
        Task { @MainActor in
            if workoutConfiguration.activityType == .flexibility {
                // Kalibreren via de iPhone, geen nacht.
                NightTracker.shared.beginCalibrationMode()
            } else {
                // Begin meteen; de instellingen volgen via het startSession-bericht.
                NightTracker.shared.start(id: UUID(), settings: WatchSettings())
            }
        }
    }
}

/// Ontvangt berichten van de iPhone.
final class WatchConnector: NSObject, WCSessionDelegate {
    static let shared = WatchConnector()
    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    private func handle(_ data: Data) {
        guard let msg = try? WatchMessage.decode(data) else { return }
        Task { @MainActor in NightTracker.shared.handle(msg) }
    }
    func session(_ s: WCSession, didReceiveMessageData d: Data) { handle(d) }
    func session(_ s: WCSession, didReceiveMessageData d: Data, replyHandler: @escaping (Data) -> Void) {
        handle(d)
        replyHandler(Data("ok".utf8))
    }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) {
        if let d = info["msg"] as? Data { handle(d) }
    }
    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        if let d = ctx["profile"] as? Data { handle(d) }
        if let d = ctx["state"] as? Data { handle(d) }
    }
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let d = s.receivedApplicationContext["profile"] as? Data { handle(d) }
        if let d = s.receivedApplicationContext["state"] as? Data { handle(d) }
    }
}

struct WatchHomeView: View {
    @EnvironmentObject var t: NightTracker

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let a = t.alertText {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(a).font(.footnote).multilineTextAlignment(.center)
                    Button("OK") { t.alertText = nil }
                } else if let c = t.calibrating {
                    Text("Stil blijven liggen…").font(.headline)
                    Image(systemName: c.symbol).font(.largeTitle).foregroundStyle(.orange)
                    Text(c.label)
                } else if t.calibMode {
                    Image(systemName: "iphone.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.orange)
                    Text("Kalibreren").font(.headline)
                    Text("Volg de stem van je iPhone").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if t.phoneRecording || t.isTracking {
                    if let until = t.pausedUntil, until > .now {
                        Image(systemName: "pause.circle.fill").font(.largeTitle).foregroundStyle(.orange)
                        Text("Gepauzeerd").font(.headline)
                        Text("tot \(until.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                        Button("Hervat") { t.request(.resume) }.tint(.orange)
                    } else {
                        Image(systemName: t.position.symbol).font(.largeTitle).foregroundStyle(.orange)
                        Text(t.position.label).font(.headline)
                        if let hr = t.heartRate { Label("\(Int(hr))", systemImage: "heart.fill").foregroundStyle(.red) }
                        Button("Pauze 30 min") { t.request(.pause(minutes: 30)) }
                    }
                    Button("Stop de nacht", role: .destructive) { t.request(.stop); t.stop() }
                } else {
                    Image(systemName: "moon.zzz.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text("Snoredle").font(.headline)
                    Button("Start de nacht") { t.request(.start) }.tint(.orange)
                }
            }
        }
    }
}
