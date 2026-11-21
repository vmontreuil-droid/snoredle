import Foundation
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Wekker die altijd afgaat.
/// - iOS 26+: Apple's AlarmKit — gaat af zoals de Klok-app, ook in stille modus en Focus,
///   op het vergrendelscherm en op je Apple Watch.
/// - Oudere iOS: eigen alarmtoon via de lopende audiosessie (stille knop wordt genegeerd)
///   + melding + trillen op de watch.
/// Slimme wekker: binnen het venster vóór de wektijd wekt Snoredle je zodra je beweegt
/// (licht slapen), anders op de ingestelde tijd.
@MainActor
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    @Published private(set) var armedFor: Date?
    @Published private(set) var isRinging = false          // alleen bij de eigen alarmtoon
    @Published private(set) var lastWakeReason: String?

    /// Wordt aangeroepen als de wekker uitgezet is (meting mag stoppen).
    var onDismissed: (() -> Void)?

    private let settings = AppSettings.shared
    private var fallbackTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var alarmID: UUID?
    private var sawAlerting = false
    private var updatesTask: Task<Void, Never>?
    private let tone = SoundSynth()

    // MARK: Plannen

    /// Volgende keer dat de ingestelde wektijd valt.
    func nextAlarmDate(from now: Date = .now) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = settings.alarmMinutes / 60
        comps.minute = settings.alarmMinutes % 60
        let today = cal.date(from: comps) ?? now
        return today > now.addingTimeInterval(60) ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }

    var windowStart: Date? {
        guard let a = armedFor, settings.smartWindowMinutes > 0 else { return nil }
        return a.addingTimeInterval(-Double(settings.smartWindowMinutes * 60))
    }

    func requestPermission() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return await AlarmKitBackend.authorize() }
        #endif
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    func arm() async {
        guard settings.alarmEnabled else { return }
        let date = nextAlarmDate()
        armedFor = date
        lastWakeReason = nil
        sawAlerting = false
        await schedule(at: date)
    }

    func disarm() {
        cancelScheduled()
        stopRinging()
        armedFor = nil
    }

    private func schedule(at date: Date) async {
        cancelScheduled()
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), await AlarmKitBackend.authorize() {
            alarmID = try? await AlarmKitBackend.schedule(at: date, title: "Goedemorgen")
            if alarmID != nil { observeAlarmKit(); return }
        }
        #endif
        scheduleFallback(at: date)
    }

    private func cancelScheduled() {
        fallbackTask?.cancel(); fallbackTask = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["snoredle.alarm"])
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let id = alarmID { AlarmKitBackend.cancel(id) }
        #endif
        alarmID = nil
    }

    // MARK: Slimme wekker

    /// Signaal van de watch (beweging) of de microfoon (onrust). Binnen het venster → nu wekken.
    func signal(movement intensity: Double, at now: Date = .now) {
        guard let start = windowStart, let end = armedFor, !isRinging, alarmID != nil || fallbackTask != nil else { return }
        guard now >= start, now < end.addingTimeInterval(-30) else { return }
        guard intensity >= settings.smartWakeMovementThreshold else { return }
        lastWakeReason = "Gewekt om \(now.formatted(date: .omitted, time: .shortened)) tijdens lichte slaap (beweging)"
        Task { await wakeNow() }
    }

    func wakeNow() async {
        let soon = Date().addingTimeInterval(3)
        armedFor = soon
        await schedule(at: soon)
    }

    // MARK: AlarmKit-opvolging

    private func observeAlarmKit() {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *) else { return }
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                let mine = alarms.first { $0.id == self.alarmID }
                if mine?.state == .alerting {
                    if !self.sawAlerting, self.settings.alarmVibrateWatch { self.startWatchNudges() }
                    self.sawAlerting = true
                }
                if mine == nil, self.sawAlerting {
                    // Uitgezet via het systeem-alarm.
                    self.sawAlerting = false
                    self.alarmID = nil
                    self.armedFor = nil
                    self.nudgeTask?.cancel()
                    self.onDismissed?()
                }
            }
        }
        #endif
    }

    // MARK: Eigen alarmtoon (iOS 17–25)

    private func scheduleFallback(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Goedemorgen ☀️"
        content.body = "Tijd om op te staan. Tik om je nachtrapport te bekijken."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "snoredle.alarm", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))

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

    /// Knoppen op het eigen wekscherm.
    func dismiss() {
        stopRinging()
        cancelScheduled()
        armedFor = nil
        onDismissed?()
    }

    func snooze() {
        stopRinging()
        let next = Date().addingTimeInterval(Double(settings.snoozeMinutes * 60))
        armedFor = next
        scheduleFallback(at: next)
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

    static func schedule(at date: Date, title: LocalizedStringResource) async throws -> UUID {
        let id = UUID()
        let stop = AlarmButton(text: "Stop", textColor: .black, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: title, stopButton: stop)
        let attributes = AlarmAttributes<SnoredleAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: Theme.accent)
        let config = AlarmManager.AlarmConfiguration<SnoredleAlarmMetadata>.alarm(
            schedule: .fixed(date), attributes: attributes, stopIntent: nil, secondaryIntent: nil, sound: .default)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        return id
    }

    static func cancel(_ id: UUID) { try? AlarmManager.shared.cancel(id: id) }
}
#endif
