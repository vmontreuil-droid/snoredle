import Foundation

/// Reeksen en uitdagingen, berekend uit de nachten (geen extra opslag nodig).
enum Achievements {

    struct Badge: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let progress: Double          // 0…1
        var done: Bool { progress >= 1 }
    }

    /// Aantal opeenvolgende nachten (tot vandaag/gisteren) met een meting.
    static func streak(_ sessions: [SleepSession]) -> Int {
        let cal = Calendar.current
        // Een nacht hoort bij de dag waarop je wakker wordt.
        let days = Set(sessions.compactMap { $0.end }.map { cal.startOfDay(for: $0) })
        var day = cal.startOfDay(for: .now)
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    @MainActor static func badges(_ all: [SleepSession]) -> [Badge] {
        let done = all.filter { $0.end != nil && $0.duration > 2 * 3600 }.sorted { $0.start < $1.start }
        let s = streak(done)
        let quiet = done.filter { $0.snoreScore < 10 }.count
        let sideNights = done.filter { night in
            let st = SnoreAnalysis.positionStats(night)
            let total = st.map(\.minutes).reduce(0, +)
            let back = st.first { $0.position == .back }?.minutes ?? 0
            return total > 60 && back / total < 0.2
        }.count
        let watchNights = done.filter { !$0.positions.isEmpty }.count
        let goal = AppSettings.shared.sleepGoalHours
        let goalNights = done.filter { $0.sleepDuration / 3600 >= goal }.count
        let remedyNights = done.filter { !$0.remediesRaw.isEmpty }.count

        // Verbetering: laatste 7 nachten vs. de 7 daarvoor
        var improvement = 0.0
        if done.count >= 14 {
            let last = done.suffix(7).map(\.snoreScore), prev = done.dropLast(7).suffix(7).map(\.snoreScore)
            let a = Double(last.reduce(0, +)) / 7, b = Double(prev.reduce(0, +)) / 7
            if b > 0 { improvement = max(0, (b - a) / b) }
        }

        func p(_ x: Int, _ goal: Int) -> Double { min(1, Double(x) / Double(goal)) }
        return [
            Badge(id: "first", title: "Eerste nacht", detail: "Meet je eerste nacht", symbol: "moon.fill", progress: p(done.count, 1)),
            Badge(id: "streak3", title: "Op dreef", detail: "3 nachten op rij", symbol: "flame.fill", progress: p(s, 3)),
            Badge(id: "streak7", title: "Een volle week", detail: "7 nachten op rij", symbol: "flame.circle.fill", progress: p(s, 7)),
            Badge(id: "streak30", title: "Maandkampioen", detail: "30 nachten op rij", symbol: "crown.fill", progress: p(s, 30)),
            Badge(id: "quiet", title: "Stille nacht", detail: "Een nacht met score onder 10", symbol: "speaker.slash.fill", progress: p(quiet, 1)),
            Badge(id: "quiet5", title: "Fluisterzacht", detail: "5 rustige nachten", symbol: "leaf.fill", progress: p(quiet, 5)),
            Badge(id: "side", title: "Zijslaper", detail: "7 nachten minder dan 20% op je rug", symbol: "arrow.turn.up.right", progress: p(sideNights, 7)),
            Badge(id: "watch", title: "Watch-pro", detail: "10 nachten met je watch", symbol: "applewatch", progress: p(watchNights, 10)),
            Badge(id: "goal", title: "Uitgeslapen", detail: "7 nachten je slaapdoel gehaald", symbol: "bed.double.fill", progress: p(goalNights, 7)),
            Badge(id: "tester", title: "Onderzoeker", detail: "10 nachten een middel getest", symbol: "flask.fill", progress: p(remedyNights, 10)),
            Badge(id: "better", title: "Stiller dan vorige week", detail: "Weekscore 20% lager dan de week ervoor", symbol: "chart.line.downtrend.xyaxis", progress: min(1, improvement / 0.2)),
        ]
    }
}
