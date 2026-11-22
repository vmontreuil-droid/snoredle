import AppIntents

/// Siri, Opdrachten en automatisaties (bv. "als Focus Slapen aangaat" of "als iPhone aan de lader gaat").
struct StartNightIntent: AppIntent {
    static var title: LocalizedStringResource = "Start de nacht"
    static var description = IntentDescription("Start de snurkmeting van Snoredle.")
    static var openAppWhenRun = true      // de microfoon mag alleen starten met de app open

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SessionManager.shared.startFromShortcut()
        return .result(dialog: SessionManager.shared.state == .idle ? "Snoredle kon niet starten." : "Slaap lekker. Snoredle luistert.")
    }
}

struct StopNightIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop de nacht"
    static var description = IntentDescription("Stopt de meting en maakt je nachtrapport.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SessionManager.shared.state != .idle else { return .result(dialog: "Er loopt geen meting.") }
        await SessionManager.shared.stop()
        return .result(dialog: "Goedemorgen. Je nachtrapport staat klaar.")
    }
}

struct PauseNightIntent: AppIntent {
    static var title: LocalizedStringResource = "Pauzeer Snoredle"
    static var description = IntentDescription("Neemt even niets op (privémoment).")

    @Parameter(title: "Minuten", default: 30, inclusiveRange: (5, 180))
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SessionManager.shared.state != .idle else { return .result(dialog: "Er loopt geen meting.") }
        SessionManager.shared.pause(minutes: minutes)
        return .result(dialog: "Gepauzeerd voor \(minutes) minuten.")
    }
}

struct ResumeNightIntent: AppIntent {
    static var title: LocalizedStringResource = "Hervat Snoredle"

    @MainActor
    func perform() async throws -> some IntentResult {
        SessionManager.shared.resume()
        return .result()
    }
}

struct SnoredleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartNightIntent(),
                    phrases: ["Start \(.applicationName)", "Start de nacht met \(.applicationName)",
                              "\(.applicationName) ik ga slapen"],
                    shortTitle: "Start de nacht", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: StopNightIntent(),
                    phrases: ["Stop \(.applicationName)", "\(.applicationName) ik ben wakker"],
                    shortTitle: "Stop de nacht", systemImageName: "sun.max.fill")
        AppShortcut(intent: PauseNightIntent(),
                    phrases: ["Pauzeer \(.applicationName)"],
                    shortTitle: "Pauze", systemImageName: "pause.fill")
    }
}
