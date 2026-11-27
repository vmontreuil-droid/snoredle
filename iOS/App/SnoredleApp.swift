import SwiftUI
import SwiftData

/// Eén gedeelde databank, ook bruikbaar als de app op de achtergrond start (watch, Siri).
@MainActor
enum AppData {
    static let container: ModelContainer = {
        let schema = Schema([SleepSession.self, SnoreEvent.self, LoudnessSample.self,
                             PositionSample.self, VitalSample.self,
                             NightSoundEvent.self, SleepStageSample.self, OutOfBedEvent.self])
        return try! ModelContainer(for: schema)
    }()
}

@main
struct SnoredleApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var hub = WearableHub.shared
    @StateObject private var store = StoreManager.shared
    @StateObject private var manager = SessionManager.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var container: ModelContainer { AppData.container }

    init() {
        CrashReporter.shared.start()
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
                    Task { await AlarmService.shared.sync() }
                    if settings.didOnboard { Task { await NotificationService.shared.requestAuthorization() } }
                    LiveActivityService.shared.cleanupStale(isRecording: manager.state != .idle)
                    WidgetBridge.publish(context: container.mainContext)
                    NotificationService.shared.refreshWeekly(context: container.mainContext)
                }
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, p in
                    lock.scenePhaseChanged(p)
                    if p == .active {
                        Task {
                            await manager.backfillHealth()
                            await SyncService.shared.syncPending(context: AppData.container.mainContext)
                        }
                    }
                }
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
        case .back: Color(red: 1.00, green: 0.38, blue: 0.42)     // rood
        case .left: Color(red: 0.30, green: 0.85, blue: 0.45)     // groen
        case .right: Color(red: 0.32, green: 0.55, blue: 1.00)    // blauw
        case .stomach: Color(red: 0.75, green: 0.40, blue: 0.95)  // paars
        case .stomachLeft: Color(red: 0.75, green: 0.40, blue: 0.95)   // paars
        case .stomachRight: Color(red: 1.00, green: 0.82, blue: 0.25)  // geel
        case .upright: .gray
        case .unknown: .secondary
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
