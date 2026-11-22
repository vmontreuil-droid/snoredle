import Foundation
import SwiftData
import ActivityKit
import WidgetKit
import UserNotifications

/// Start/actualiseert de Live Activity van de nacht.
@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()
    private var activity: Activity<SnoreActivityAttributes>?
    private var state = SnoreActivityAttributes.ContentState(snoreEvents: 0, isSnoring: false, position: "—",
                                                            nightSounds: 0, alarm: nil, finishedScore: nil)
    private var lastPush = Date.distantPast

    func start(session: SleepSession, alarm: Date?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = .init(snoreEvents: 0, isSnoring: false, position: "—", nightSounds: 0,
                      alarm: AlarmService.shared.armedFor ?? (AppSettings.shared.alarmEnabled ? AlarmService.shared.nextAlarmDate() : nil),
                      finishedScore: nil)
        activity = try? Activity.request(attributes: SnoreActivityAttributes(start: session.start),
                                         content: .init(state: state, staleDate: nil))
    }

    func update(snoreEvents: Int, isSnoring: Bool, position: SleepPosition, nightSounds: Int) {
        guard let activity else { return }
        state.snoreEvents = snoreEvents
        state.isSnoring = isSnoring
        state.position = position == .unknown ? "—" : position.label
        state.nightSounds = nightSounds
        state.alarm = AlarmService.shared.armedFor
        // Niet vaker dan om de 15 s (batterij en limieten van iOS).
        guard Date().timeIntervalSince(lastPush) > 15 else { return }
        lastPush = .now
        let s = state
        Task { await activity.update(.init(state: s, staleDate: nil)) }
    }

    func end(score: Int?) {
        guard let activity else { return }
        var s = state
        s.finishedScore = score
        s.isSnoring = false
        self.activity = nil
        Task { await activity.end(.init(state: s, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(15 * 60))) }
    }

    /// Ruimt weergaven op die van een vorige (afgebroken) nacht zijn blijven hangen.
    func cleanupStale(isRecording: Bool) {
        guard !isRecording else { return }
        activity = nil
        for a in Activity<SnoreActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

/// Schrijft de samenvatting voor de widgets.
@MainActor
enum WidgetBridge {
    static func publish(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let done = all.filter { $0.end != nil }
        guard let last = done.last else { return }
        let summary = WidgetSummary(
            date: last.start, score: last.snoreScore, label: SnoreAnalysis.scoreLabel(last.snoreScore),
            snoreMinutes: Int(last.snoreMinutes), hours: last.duration / 3600,
            weekScores: done.suffix(7).map(\.snoreScore),
            streak: Achievements.streak(done),
            alarm: AppSettings.shared.alarmEnabled ? AlarmService.shared.nextAlarmDate() : nil,
            goalHours: AppSettings.shared.sleepGoalHours,
            snorePercent: last.snorePercentage,
            heartRate: {
                let hr = last.vitals.filter { $0.kind == .heartRate }.map(\.value)
                return hr.isEmpty ? nil : Int(hr.reduce(0, +) / Double(hr.count))
            }())
        summary.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Bedtijdherinnering en weekrapport.
@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let settings = AppSettings.shared

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func refreshBedtime() {
        center.removePendingNotificationRequests(withIdentifiers: ["snoredle.bedtime"])
        guard settings.bedtimeReminder else { return }
        Task { await requestAuthorization() }
        let content = UNMutableNotificationContent()
        content.title = "Bijna bedtijd 🌙"
        content.body = "Vergeet Snoredle niet te starten. Zet je telefoon aan de lader naast je bed."
        content.sound = .default
        var comps = DateComponents()
        let remind = (settings.bedtimeMinutes - 15 + 1440) % 1440       // 15 min op voorhand
        comps.hour = remind / 60; comps.minute = remind % 60
        center.add(UNNotificationRequest(identifier: "snoredle.bedtime", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
    }

    /// Plant het weekrapport voor maandagochtend met de cijfers van de afgelopen 7 nachten.
    func refreshWeekly(context: ModelContext) {
        center.removePendingNotificationRequests(withIdentifiers: ["snoredle.weekly"])
        guard settings.weeklyReport else { return }
        let all = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let week = all.filter { $0.end != nil && $0.start > Date().addingTimeInterval(-7 * 86_400) }
        guard !week.isEmpty else { return }
        let prev = all.filter { $0.end != nil && $0.start <= Date().addingTimeInterval(-7 * 86_400)
                                && $0.start > Date().addingTimeInterval(-14 * 86_400) }
        let avg = week.map(\.snoreScore).reduce(0, +) / week.count
        let content = UNMutableNotificationContent()
        content.title = "Je week met Snoredle"
        var body = "\(week.count) nachten gemeten, gemiddelde score \(avg) (\(SnoreAnalysis.scoreLabel(avg).lowercased()))."
        if !prev.isEmpty {
            let pAvg = prev.map(\.snoreScore).reduce(0, +) / prev.count
            if pAvg > 0 {
                let diff = Int((Double(avg - pAvg) / Double(pAvg) * 100).rounded())
                body += diff <= 0 ? " Dat is \(-diff)% beter dan vorige week 🎉" : " Dat is \(diff)% meer dan vorige week."
            }
        }
        content.body = body
        content.sound = .default
        var comps = DateComponents(); comps.weekday = 2; comps.hour = 9; comps.minute = 7
        center.add(UNNotificationRequest(identifier: "snoredle.weekly", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}
