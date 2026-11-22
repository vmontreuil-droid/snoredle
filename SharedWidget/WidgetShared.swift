import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Gedeeld tussen de iPhone-app en de widget-extensie (App Group).
enum AppGroup {
    static let id = "group.be.snoredle"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// Wat de widgets tonen.
struct WidgetSummary: Codable {
    var date: Date
    var score: Int
    var label: String
    var snoreMinutes: Int
    var hours: Double
    var weekScores: [Int]          // oudste → nieuwste, max 7
    var streak: Int
    var alarm: Date?
    var goalHours: Double? = 7.5
    var snorePercent: Double? = 0       // 0…1 van de nacht
    var heartRate: Int? = nil

    static let placeholder = WidgetSummary(date: .now, score: 12, label: "Matig", snoreMinutes: 34,
                                           hours: 7.4, weekScores: [22, 18, 30, 15, 12, 9, 12], streak: 5, alarm: nil,
                                           goalHours: 7.5, snorePercent: 0.08, heartRate: 56)

    static func load() -> WidgetSummary? {
        guard let d = AppGroup.defaults.data(forKey: "summary") else { return nil }
        return try? JSONDecoder().decode(WidgetSummary.self, from: d)
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: "summary") }
    }
}

#if canImport(ActivityKit) && os(iOS)
/// Live Activity tijdens de nacht: vergrendelscherm, Dynamic Island en StandBy.
struct SnoreActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var snoreEvents: Int
        var isSnoring: Bool
        var position: String          // SleepPosition.label
        var nightSounds: Int
        var alarm: Date?
        var finishedScore: Int?
    }
    var start: Date
}
#endif
