import Foundation
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Eén wekker uit de lijst.
struct AlarmItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var minutes: Int = 7 * 60
    var enabled = true
    var days: Set<Int> = []          // Calendar-weekdagen (1 = zondag … 7 = zaterdag); leeg = elke dag
    var label = ""
    var smart = false
    var smartWindow = 20             // minuten

    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }
    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    static let dayOrder = [2, 3, 4, 5, 6, 7, 1]                   // ma … zo
    static let shortNames = [1: "zo", 2: "ma", 3: "di", 4: "wo", 5: "do", 6: "vr", 7: "za"]

    var daysText: String {
        if days.isEmpty || days.count == 7 { return "Elke dag" }
        if days == [2, 3, 4, 5, 6] { return "Werkdagen" }
        if days == [1, 7] { return "Weekend" }
        return Self.dayOrder.filter { days.contains($0) }.compactMap { Self.shortNames[$0] }.joined(separator: " ")
    }

    /// Eerstvolgende keer dat deze wekker afgaat.
    func next(after now: Date = .now) -> Date? {
        guard enabled else { return nil }
        let cal = Calendar.current
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if t <= now.addingTimeInterval(30) { continue }
            if days.isEmpty || days.contains(cal.component(.weekday, from: t)) { return t }
        }
        return nil
    }
}

/// Wekkers die altijd afgaan.
/// - iOS 26+: Apple's AlarmKit — zoals de Klok-app: ook in stille modus, met Focus, op je Apple Watch,
///   en ook als Snoredle die nacht niet meet. Herhalende wekkers plant iOS zelf.
/// - Oudere iOS: meldingen + eigen alarmtoon tijdens een meting (stille knop wordt genegeerd).
/// Slimme wekker: tijdens een meting wekt Snoredle je binnen het venster zodra je beweegt.
@MainActor
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    @Published private(set) var alarms: [AlarmItem] = []
    @Published private(set) var armedFor: Date?            // eerstvolgende wekker tijdens de meting
    @Published private(set) var isRinging = false          // alleen bij de eigen alarmtoon
    @Published private(set) var lastWakeReason: String?
    @Published private(set) var permissionDenied = false

    /// Wordt aangeroepen als een wekker uitgezet is tijdens een meting (meting mag stoppen).
    var onDismissed: (() -> Void)?

    private let settings = AppSettings.shared
    private var fallbackTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var alerting = Set<UUID>()
    private var smartFired = false
    private var lastSignalLog = Date.distantPast
    private var sessionActive = false
    private let tone = SoundSynth()
    private static let storeKey = "alarms.v2"

    init() {
        load()
        observeAlarmKit()
    }

    // MARK: Lijst beheren

    private func load() {
        if let d = UserDefaults.standard.data(forKey: Self.storeKey),
           let a = try? JSONDecoder().decode([AlarmItem].self, from: d) {
            alarms = a
        } else if settings.alarmEnabled {
            // Overzetten van de oude enkele wekker.
            alarms = [AlarmItem(minutes: settings.alarmMinutes, enabled: true, smart: settings.smartWindowMinutes > 0,
                                smartWindow: max(10, settings.smartWindowMinutes))]
            save()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(alarms) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
        settings.alarmEnabled = alarms.contains(where: \.enabled)
    }

    func upsert(_ item: AlarmItem) {
        if let i = alarms.firstIndex(where: { $0.id == item.id }) { alarms[i] = item } else { alarms.append(item) }
        alarms.sort { $0.minutes < $1.minutes }
        save()
        Task { await sync() }
    }

    func delete(_ item: AlarmItem) {
        alarms.removeAll { $0.id == item.id }
        save()
        Task { await sync() }
    }

    func setEnabled(_ item: AlarmItem, _ on: Bool) {
        var x = item; x.enabled = on; upsert(x)
    }

    /// Eerstvolgende wekker (van alle actieve).
    var nextItem: (AlarmItem, Date)? {
        alarms.compactMap { a in a.next().map { (a, $0) } }.min { $0.1 < $1.1 }
    }
    func nextAlarmDate() -> Date? { nextItem?.1 }

    var windowStart: Date? {
        guard let (item, date) = nextItem, item.smart, sessionActive else { return nil }
        return date.addingTimeInterval(-Double(item.smartWindow * 60))
    }

    func requestPermission() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let ok = await AlarmKitBackend.authorize()
            permissionDenied = !ok
            return ok
        }
        #endif
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        permissionDenied = !granted
        return granted
    }

    // MARK: Plannen bij het systeem

    private var syncTask: Task<Void, Never>?

    /// Zet alle wekkers opnieuw klaar bij iOS. Veilig om vaak aan te roepen: oproepen lopen na elkaar,
    /// zodat twee gelijktijdige synchronisaties elkaars wekkers niet wissen.
    func sync() async {
        let previous = syncTask
        let task = Task { @MainActor in
            await previous?.value
            await self.performSync()
        }
        syncTask = task
        await task.value
    }

    private func performSync() async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard await AlarmKitBackend.authorize() else {
                permissionDenied = true
                DiagLog.shared.log("wekker", "GEEN toestemming voor wekkers (AlarmKit)")
                return
            }
            permissionDenied = false
            AlarmKitBackend.cancelAll()
            var skips = Self.loadSkips()
            skips = skips.filter { $0.value > .now }          // verlopen overslagen opruimen
            Self.saveSkips(skips)
            for a in alarms where a.enabled {
                if let skipUntil = skips[a.id] {
                    // Vandaag al slim gewekt: alleen de volgende keer plannen (herhaling komt bij de volgende sync terug).
                    if let next = a.next(after: skipUntil.addingTimeInterval(60)) {
                        _ = try? await AlarmKitBackend.scheduleOnce(at: next, title: a.label, id: a.id)
                    }
                } else {
                    do { try await AlarmKitBackend.scheduleRepeating(a) }
                    catch { DiagLog.shared.log("wekker", "plannen \(a.timeText) mislukt: \(error.localizedDescription)") }
                }
            }
            let planned = (try? AlarmManager.shared.alarms.count) ?? -1
            DiagLog.shared.log("wekker", "gesynchroniseerd: \(alarms.filter(\.enabled).count) actief, \(planned) bij iOS gepland, overslagen: \(skips.count)")
            return
        }
        #endif
        scheduleNotifications()
    }

    private func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ours = reqs.map(\.identifier).filter { $0.hasPrefix("snoredle.alarm") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
        for a in alarms where a.enabled {
            let content = UNMutableNotificationContent()
            content.title = a.label.isEmpty ? "Goedemorgen ☀️" : a.label
            content.body = "Tijd om op te staan. Tik om je nachtrapport te bekijken."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let days = a.days.isEmpty ? Set(1...7) : a.days
            for d in days {
                var c = DateComponents(); c.weekday = d; c.hour = a.hour; c.minute = a.minute
                center.add(UNNotificationRequest(identifier: "snoredle.alarm.\(a.id).\(d)", content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))
            }
        }
    }

    /// Toestemming in gewone woorden, voor het wekkerscherm.
    var permissionText: String {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return "Toegestaan ✓"
            case .denied: return "Geweigerd: wekkers kunnen niet afgaan"
            case .notDetermined: return "Nog niet gevraagd"
            @unknown default: return "Onbekend"
            }
        }
        #endif
        return "Via meldingen (iOS ouder dan 26)"
    }

    /// Testwekker binnen een minuut, om geluid en toestemming te controleren.
    func testAlarm() async -> String {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard await AlarmKitBackend.authorize() else {
                DiagLog.shared.log("wekker", "test: geen toestemming")
                return "Geen toestemming. Zet 'Wekkers' aan in Instellingen › Apps › Snoredle."
            }
            do {
                _ = try await AlarmKitBackend.scheduleOnce(at: .now.addingTimeInterval(60), title: "Test Snoredle", id: UUID())
                DiagLog.shared.log("wekker", "test gepland over 1 minuut")
                return "Testwekker gaat over 1 minuut af. Zet je iPhone gerust op stil om het te proberen."
            } catch {
                DiagLog.shared.log("wekker", "test mislukt: \(error.localizedDescription)")
                return "Plannen mislukt: \(error.localizedDescription)"
            }
        }
        #endif
        scheduleFallbackTone(at: .now.addingTimeInterval(60))
        return "Testwekker over 1 minuut (laat Snoredle open staan)."
    }

    // MARK: Tijdens een meting

    func arm() async {
        sessionActive = true
        smartFired = false
        lastWakeReason = nil
        await sync()
        armedFor = nextAlarmDate()
        // Op oudere iOS: eigen alarmtoon voor de eerstvolgende wekker.
        if #unavailable(iOS 26.0), let d = armedFor { scheduleFallbackTone(at: d) }
    }

    /// Meting gestopt. De wekkers zelf blijven staan (zoals in de Klok-app).
    func disarm() {
        sessionActive = false
        fallbackTask?.cancel(); fallbackTask = nil
        stopRinging()
        armedFor = nil
        if smartFired { Task { await sync() } }        // herhalende wekker na slim wekken terugzetten
    }

    /// Beweging van de watch: binnen het slimme venster → nu wekken.
    func signal(movement intensity: Double, at now: Date = .now) {
        guard sessionActive, !smartFired, !isRinging, let (item, end) = nextItem, item.smart else { return }
        let start = end.addingTimeInterval(-Double(item.smartWindow * 60))
        guard now >= start, now < end.addingTimeInterval(-30) else { return }
        if Date().timeIntervalSince(lastSignalLog) > 60 {
            lastSignalLog = .now
            DiagLog.shared.log("slim", "in venster, beweging \(String(format: "%.2f", intensity)) (drempel \(String(format: "%.2f", settings.smartWakeMovementThreshold)))")
        }
        guard intensity >= settings.smartWakeMovementThreshold else { return }
        smartFired = true
        DiagLog.shared.log("slim", "WEKKEN NU (gepland \(item.timeText))")
        lastWakeReason = "Gewekt om \(now.formatted(date: .omitted, time: .shortened)) tijdens lichte slaap (gepland \(item.timeText))"
        Task { await wakeNow(skipping: item) }
    }

    private func wakeNow(skipping item: AlarmItem) async {
        armedFor = .now
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            // De gewone wekker van vandaag overslaan; morgen staat hij er weer.
            var skips = Self.loadSkips()
            if let original = item.next(after: .now) { skips[item.id] = original }
            Self.saveSkips(skips)
            AlarmKitBackend.cancel(item.id)
            if let tomorrow = item.next(after: .now.addingTimeInterval(3600)) {
                _ = try? await AlarmKitBackend.scheduleOnce(at: tomorrow, title: item.label, id: item.id)
            }
            _ = try? await AlarmKitBackend.scheduleOnce(at: .now.addingTimeInterval(3), title: item.label, id: UUID())
            return
        }
        #endif
        startRinging()
    }

    private static func loadSkips() -> [UUID: Date] {
        guard let d = UserDefaults.standard.data(forKey: "alarms.skips"),
              let m = try? JSONDecoder().decode([UUID: Date].self, from: d) else { return [:] }
        return m
    }
    private static func saveSkips(_ m: [UUID: Date]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: "alarms.skips") }
    }

    // MARK: AlarmKit-opvolging

    private func observeAlarmKit() {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *) else { return }
        updatesTask = Task { [weak self] in
            for await list in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                let nowAlerting = Set(list.filter { $0.state == .alerting }.map(\.id))
                let started = nowAlerting.subtracting(self.alerting)
                let stopped = self.alerting.subtracting(nowAlerting)
                self.alerting = nowAlerting
                if !started.isEmpty { DiagLog.shared.log("wekker", "GAAT AF (meting loopt: \(self.sessionActive))") }
                if !stopped.isEmpty { DiagLog.shared.log("wekker", "uitgezet") }
                if !started.isEmpty, self.sessionActive, self.settings.alarmVibrateWatch { self.startWatchNudges() }
                if !stopped.isEmpty {
                    self.nudgeTask?.cancel()
                    if self.sessionActive { self.onDismissed?() }
                }
            }
        }
        #endif
    }

    // MARK: Eigen alarmtoon (iOS 17–25)

    private func scheduleFallbackTone(at date: Date) {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.startRinging() }
        }
    }

    private func startRinging() {
        isRinging = true
        tone.play(.alarm, volume: 0.15, rampTo: 1.0, rampSeconds: 45)
        if settings.alarmVibrateWatch { startWatchNudges() }
    }

    private func startWatchNudges() {
        nudgeTask?.cancel()
        nudgeTask = Task {
            for _ in 0..<20 {
                WearableHub.shared.nudge(.strong)
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
            }
        }
    }

    private func stopRinging() {
        tone.stop(fade: 0.3)
        nudgeTask?.cancel()
        isRinging = false
    }

    /// Knoppen op het eigen wekscherm (iOS 17–25).
    func dismiss() {
        stopRinging()
        fallbackTask?.cancel()
        onDismissed?()
    }

    func snooze() {
        stopRinging()
        scheduleFallbackTone(at: Date().addingTimeInterval(Double(settings.snoozeMinutes * 60)))
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct SnoredleAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
enum AlarmKitBackend {
    static func authorize() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .denied: return false
        case .notDetermined:
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        @unknown default: return false
        }
    }

    private static func attributes(_ title: String) -> AlarmAttributes<SnoredleAlarmMetadata> {
        let stop = AlarmButton(text: "Stop", textColor: .black, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title.isEmpty ? "Goedemorgen" : title),
                                            stopButton: stop)
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert), tintColor: Theme.accent)
    }

    static func scheduleRepeating(_ a: AlarmItem) async throws {
        let map: [Int: Locale.Weekday] = [1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday,
                                          5: .thursday, 6: .friday, 7: .saturday]
        let days = (a.days.isEmpty ? Array(1...7) : Array(a.days)).compactMap { map[$0] }
        let rel = Alarm.Schedule.Relative(time: .init(hour: a.hour, minute: a.minute), repeats: .weekly(days))
        let config = AlarmManager.AlarmConfiguration<SnoredleAlarmMetadata>.alarm(
            schedule: .relative(rel), attributes: attributes(a.label), stopIntent: nil, secondaryIntent: nil, sound: .default)
        _ = try await AlarmManager.shared.schedule(id: a.id, configuration: config)
    }

    static func scheduleOnce(at date: Date, title: String, id: UUID) async throws -> UUID {
        let config = AlarmManager.AlarmConfiguration<SnoredleAlarmMetadata>.alarm(
            schedule: .fixed(date), attributes: attributes(title), stopIntent: nil, secondaryIntent: nil, sound: .default)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        return id
    }

    static func cancel(_ id: UUID) { try? AlarmManager.shared.cancel(id: id) }

    static func cancelAll() {
        for a in (try? AlarmManager.shared.alarms) ?? [] { try? AlarmManager.shared.cancel(id: a.id) }
    }
}
#endif
