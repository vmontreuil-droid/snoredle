import SwiftUI
import SwiftData

@main
struct SnoredleApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var hub = WearableHub.shared
    @StateObject private var store = StoreManager.shared
    @StateObject private var manager = SessionManager()
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer = {
        let schema = Schema([SleepSession.self, SnoreEvent.self, LoudnessSample.self,
                             PositionSample.self, VitalSample.self,
                             NightSoundEvent.self, SleepStageSample.self])
        return try! ModelContainer(for: schema)
    }()

    init() {
        WearableHub.shared.register(AppleWatchProvider())
        if AppSettings.shared.useBluetoothHR {
            WearableHub.shared.register(BluetoothHeartRateProvider())
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if lock.isLocked || lock.obscured { LockScreen().zIndex(10) }
            }
                .environmentObject(settings)
                .environmentObject(hub)
                .environmentObject(store)
                .environmentObject(manager)
                .onAppear {
                    manager.attach(container.mainContext)
                    lock.appLaunched()
                    WidgetBridge.publish(context: container.mainContext)
                    NotificationService.shared.refreshWeekly(context: container.mainContext)
                }
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, p in lock.scenePhaseChanged(p) }
        }
        .modelContainer(container)
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.72, blue: 0.35)       // warm amber
    static let night = Color(red: 0.05, green: 0.07, blue: 0.16)
    static let card = Color.white.opacity(0.06)
    static func color(_ i: SnoreIntensity) -> Color {
        switch i {
        case .quiet: .gray
        case .light: Color(red: 0.98, green: 0.85, blue: 0.4)
        case .loud: Color(red: 1.0, green: 0.55, blue: 0.25)
        case .epic: Color(red: 0.95, green: 0.25, blue: 0.3)
        }
    }
    static func color(_ p: SleepPosition) -> Color {
        switch p {
        case .back: .pink; case .left: .teal; case .right: .cyan
        case .stomach: .purple; case .upright: .gray; case .unknown: .secondary
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var manager: SessionManager

    var body: some View {
        if !settings.didOnboard {
            OnboardingView()
        } else if manager.state != .idle {
            RecordingView()
        } else {
            TabView {
                TonightView().tabItem { Label("Vannacht", systemImage: "moon.zzz.fill") }
                HistoryView().tabItem { Label("Nachten", systemImage: "calendar") }
                TrendsView().tabItem { Label("Inzichten", systemImage: "chart.xyaxis.line") }
                SettingsView().tabItem { Label("Instellingen", systemImage: "gearshape") }
            }
        }
    }
}
