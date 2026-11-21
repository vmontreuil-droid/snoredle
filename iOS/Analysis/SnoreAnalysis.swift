import Foundation

enum SnoreAnalysis {

    /// Snurkscore 0…100+: gewogen snurkminuten per uur slaap.
    /// licht ×1, luid ×2, episch ×3. 0–10 rustig, 10–25 matig, 25–50 veel, >50 zeer veel.
    static func score(light: Double, loud: Double, epic: Double, hours: Double) -> Int {
        guard hours > 0.25 else { return 0 }
        return Int(((light + 2 * loud + 3 * epic) / hours * 1.5).rounded())
    }

    static func scoreLabel(_ s: Int) -> String {
        switch s {
        case ..<10: "Rustig"
        case ..<25: "Matig"
        case ..<50: "Veel"
        default: "Zeer veel"
        }
    }

    /// Indeling op basis van hoeveel luider dan de achtergrond.
    static func intensity(peak: Double, noiseFloor: Double) -> SnoreIntensity {
        switch peak - noiseFloor {
        case ..<8: .light
        case ..<18: .loud
        default: .epic
        }
    }

    /// Vult de samenvatting van een sessie in.
    static func summarize(_ s: SleepSession) {
        var light = 0.0, loud = 0.0, epic = 0.0
        for e in s.events {
            let m = e.duration / 60
            switch e.intensity {
            case .light, .quiet: light += m
            case .loud: loud += m
            case .epic: epic += m
            }
        }
        s.snoreMinutes = light + loud + epic
        s.loudSnoreMinutes = loud
        s.epicSnoreMinutes = epic
        s.snoreScore = score(light: light, loud: loud, epic: epic, hours: s.duration / 3600)
        let dbs = s.loudness.map(\.decibel)
        s.averageDecibel = dbs.isEmpty ? 0 : dbs.reduce(0, +) / Double(dbs.count)
        s.peakDecibel = s.events.map(\.peakDecibel).max() ?? dbs.max() ?? 0
        s.nudgeCount = s.events.filter(\.wasNudged).count
    }

    // MARK: Houding

    struct PositionStat: Identifiable {
        let position: SleepPosition
        let minutes: Double          // tijd in deze houding
        let snoreMinutes: Double     // waarvan snurkend
        var id: String { position.rawValue }
        var snoreShare: Double { minutes > 0 ? snoreMinutes / minutes : 0 }
    }

    static func positionStats(_ s: SleepSession) -> [PositionStat] {
        let samples = s.positions.sorted { $0.at < $1.at }
        guard !samples.isEmpty else { return [] }
        var time: [SleepPosition: Double] = [:]
        for (i, p) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].at : (s.end ?? .now)
            time[p.position, default: 0] += min(next.timeIntervalSince(p.at), 600) / 60
        }
        var snore: [SleepPosition: Double] = [:]
        for e in s.events { snore[e.position, default: 0] += e.duration / 60 }
        return time.keys.map { PositionStat(position: $0, minutes: time[$0] ?? 0, snoreMinutes: snore[$0] ?? 0) }
            .sorted { $0.minutes > $1.minutes }
    }

    // MARK: Inzichten over meerdere nachten

    struct Insight: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let effect: Double            // + = meer snurken, − = minder
    }

    /// Vergelijkt de gemiddelde score van nachten mét een factor/middel met nachten zonder.
    static func insights(_ sessions: [SleepSession], minNights: Int = 2) -> [Insight] {
        let done = sessions.filter { $0.end != nil && $0.duration > 3 * 3600 }
        guard done.count >= 4 else { return [] }
        func avg(_ xs: [SleepSession]) -> Double { xs.isEmpty ? 0 : Double(xs.map(\.snoreScore).reduce(0, +)) / Double(xs.count) }
        var out: [Insight] = []

        for f in SleepFactor.allCases {
            let with = done.filter { $0.factorsRaw.contains(f.rawValue) }
            let without = done.filter { !$0.factorsRaw.contains(f.rawValue) }
            guard with.count >= minNights, without.count >= minNights else { continue }
            let a = avg(with), b = avg(without)
            guard b > 0 || a > 0 else { continue }
            let pct = b > 0 ? (a - b) / b : 1
            if abs(pct) >= 0.2 {
                out.append(Insight(title: "\(f.emoji) \(f.label)",
                                   detail: "Je score is gemiddeld \(Int(abs(pct) * 100))% \(pct > 0 ? "hoger" : "lager") na \(f.label.lowercased()) (\(with.count) nachten).",
                                   effect: pct))
            }
        }
        for r in Remedy.allCases {
            let with = done.filter { $0.remediesRaw.contains(r.rawValue) }
            let without = done.filter { !$0.remediesRaw.contains(r.rawValue) }
            guard with.count >= minNights, without.count >= minNights else { continue }
            let a = avg(with), b = avg(without)
            guard b > 0 else { continue }
            let pct = (a - b) / b
            if abs(pct) >= 0.15 {
                out.append(Insight(title: "🛠️ \(r.label)",
                                   detail: pct < 0 ? "Lijkt te helpen: \(Int(-pct * 100))% minder snurken (\(with.count) nachten)."
                                                   : "Geen verbetering gemeten: \(Int(pct * 100))% meer snurken.",
                                   effect: pct))
            }
        }
        // Rugligging
        let back = done.flatMap(positionStats).filter { $0.position == .back }
        let side = done.flatMap(positionStats).filter { $0.position == .left || $0.position == .right }
        let backShare = back.map(\.snoreMinutes).reduce(0, +) / max(1, back.map(\.minutes).reduce(0, +))
        let sideShare = side.map(\.snoreMinutes).reduce(0, +) / max(1, side.map(\.minutes).reduce(0, +))
        if backShare > 0, sideShare > 0, backShare / sideShare > 1.5 {
            out.append(Insight(title: "🛌 Rugligging",
                               detail: "Op je rug snurk je \(String(format: "%.1f", backShare / sideShare))× zoveel als op je zij. Zet de watch-tikjes aan.",
                               effect: backShare / sideShare - 1))
        }
        return out.sorted { abs($0.effect) > abs($1.effect) }
    }
}
