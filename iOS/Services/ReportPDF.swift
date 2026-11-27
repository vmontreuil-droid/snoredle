import SwiftUI
import Charts

/// Volledige PDF-rapporten in de stijl van de app (donkere nacht, amber, houdingskleuren).
/// Meerdere A4-pagina's; elke pagina is een SwiftUI-view die apart gerenderd wordt.
@MainActor
enum ReportPDF {
    static let pageSize = CGSize(width: 595, height: 842)      // A4 in punten

    /// Rapport van één nacht (5 pagina's).
    static func night(_ s: SleepSession) -> URL {
        let name = "Snoredle-nacht-\(s.start.formatted(.iso8601.year().month().day())).pdf"
        let pages: [AnyView] = [
            AnyView(NightOverviewPage(s: s)),
            AnyView(NightSoundPositionPage(s: s)),
            AnyView(NightBodyPage(s: s, part: 1)),
            AnyView(NightBodyPage(s: s, part: 2)),
            AnyView(NightEventsPage(s: s)),
        ]
        return render(pages, title: "Nachtrapport", file: name)
    }

    /// Rapport over meerdere nachten (overzicht, trends, tabel, inzichten).
    static func overview(_ sessions: [SleepSession]) -> URL {
        let done = sessions.filter { $0.end != nil }.sorted { $0.start < $1.start }
        var pages: [AnyView] = [AnyView(PeriodSummaryPage(nights: done))]
        // Tabel: 22 nachten per pagina, hoogstens 4 pagina's.
        let chunks = stride(from: 0, to: min(done.count, 88), by: 22).map { Array(done.reversed()[$0..<min($0 + 22, done.count)]) }
        for c in chunks { pages.append(AnyView(PeriodTablePage(nights: c))) }
        pages.append(AnyView(PeriodInsightsPage(nights: done)))
        return render(pages, title: "Snurkrapport", file: "Snoredle-rapport.pdf")
    }

    private static func render(_ pages: [AnyView], title: String, file: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        for (i, page) in pages.enumerated() {
            let view = ReportPage(title: title, number: i + 1, total: pages.count) { page }
                .frame(width: pageSize.width, height: pageSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "nl_BE"))
            let r = ImageRenderer(content: view)
            r.proposedSize = .init(pageSize)
            r.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return url
    }
}

// MARK: - Pagina-opmaak

private enum R {
    static let bg = LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.13),
                                            Color(red: 0.07, green: 0.08, blue: 0.20),
                                            Color(red: 0.05, green: 0.06, blue: 0.15)],
                                   startPoint: .top, endPoint: .bottom)
    static let card = Color.white.opacity(0.07)
    static let line = Color.white.opacity(0.10)
    static func stage(_ s: SleepStage) -> Color {
        switch s { case .awake: .orange; case .rem: .cyan; case .core, .asleep: .blue; case .deep: .indigo; case .inBed: .gray }
    }
    static let nl = Locale(identifier: "nl_BE")
    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(nl)) }
    static func mins(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) u \(m % 60) min" : "\(m) min"
    }
}

private struct ReportPage<Content: View>: View {
    let title: String
    let number: Int
    let total: Int
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            R.bg
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill").foregroundStyle(Theme.accent)
                    Text("Snoredle").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("· \(title)").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Pagina \(number)/\(total)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                content
                Spacer(minLength: 0)
                Text("Snoredle meet geluid en beweging; dit is geen medische diagnose. Bespreek twijfels (bv. ademstops of slaperigheid overdag) met je huisarts.")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .padding(30)
            .foregroundStyle(.white)
        }
    }
}

private struct Card<C: View>: View {
    var title: String? = nil
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(R.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Tile: View {
    let value: String
    let label: String
    var color: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(R.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PDFScoreRing: View {
    let score: Int
    var body: some View {
        let p = min(1, Double(score) / 80)
        let color: Color = p < 0.15 ? .green : p < 0.35 ? .yellow : p < 0.6 ? .orange : .red
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 10)
            Circle().trim(from: 0, to: max(p, 0.02)).stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("snurkscore").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let symbol: String
    var color: Color = Theme.accent
    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Eenvoudige terugloop-rij voor chips (geen Layout-protocol nodig).
private struct ChipRows: View {
    let items: [(String, String)]
    var color: Color = Theme.accent
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 5) { ForEach(rows[r], id: \.0) { Pill(text: $0.0, symbol: $0.1, color: color) } }
            }
        }
    }
}

// MARK: - Nacht · pagina 1: overzicht

private struct NightOverviewPage: View {
    let s: SleepSession
    var body: some View {
        let end = s.end ?? .now
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nachtrapport").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(s.nightTitle.capitalized + " · \(R.time(s.start)) – \(R.time(end))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 18) {
                PDFScoreRing(score: s.snoreScore).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(SnoreAnalysis.scoreLabel(s.snoreScore)) gesnurkt")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Hoe lager de snurkscore, hoe beter. 0–9 rustig · 10–24 matig · 25–49 veel · 50+ zeer veel.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    if let r = s.rating, (1...5).contains(r) {
                        Text("Ochtendgevoel: " + ["😫", "🙁", "😐", "🙂", "😄"][r - 1]).font(.system(size: 11))
                    }
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            LazyVGrid(columns: cols, spacing: 8) {
                Tile(value: R.mins(s.sleepDuration), label: "geslapen (zonder pauzes)")
                Tile(value: "\(Int(s.snoreMinutes)) min", label: "gesnurkt · \(Int(s.snorePercentage * 100))% van de nacht", color: Theme.accent)
                Tile(value: "\(Int(s.loudSnoreMinutes)) min", label: "luid snurken", color: Theme.color(.loud))
                Tile(value: "\(Int(s.epicSnoreMinutes)) min", label: "episch snurken", color: Theme.color(.epic))
                Tile(value: "\(s.events.count)", label: "snurkperiodes")
                Tile(value: "\(s.nudgeCount)", label: "keer gewekt (tik of geluid)")
                Tile(value: "\(s.possibleApneaEvents)", label: "mogelijke ademstops", color: s.possibleApneaEvents > 5 ? .red : .white)
                Tile(value: "\(s.outOfBed.count)", label: "keer uit bed")
                Tile(value: "\(Int(s.averageDecibel)) dB", label: "gemiddeld volume")
                Tile(value: "\(Int(s.peakDecibel)) dB", label: "luidste moment")
                Tile(value: "\(s.nightSounds.count)", label: "andere geluiden (praten, hoesten…)")
                Tile(value: s.wearableName?.isEmpty == false ? s.wearableName! : "–", label: "gemeten met")
            }
            if !s.factors.isEmpty {
                Card(title: "Factoren die avond") { ChipRows(items: s.factors.map { ($0.label, $0.symbol) }, color: .orange) }
            }
            if !s.remedies.isEmpty {
                Card(title: "Gebruikte middelen") { ChipRows(items: s.remedies.map { ($0.label, $0.symbol) }, color: .green) }
            }
            let extra: [(String, String)] = [
                s.pauses.isEmpty ? nil : ("Pauzes (niet gemeten)", s.pauses.map { "\(R.time($0.start))–\(R.time($0.end))" }.joined(separator: " · ")),
                (s.alarmNote?.isEmpty == false) ? ("Wekker", s.alarmNote!) : nil,
                s.note.isEmpty ? nil : ("Notitie", s.note),
            ].compactMap { $0 }
            if !extra.isEmpty {
                Card(title: "Verder") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(extra, id: \.0) { k, v in
                            HStack(alignment: .top) {
                                Text(k).font(.system(size: 10, weight: .semibold)).frame(width: 120, alignment: .leading)
                                Text(v).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Nacht · pagina 2: geluid en houding

private struct NightSoundPositionPage: View {
    let s: SleepSession
    var body: some View {
        let end = s.end ?? .now
        let positions = s.positions.sorted { $0.at < $1.at }
        let stats = SnoreAnalysis.positionStats(s).filter { $0.minutes >= 1 }
        let totalMin = max(1, stats.map(\.minutes).reduce(0, +))
        VStack(alignment: .leading, spacing: 14) {
            Text("Geluid en houding").font(.system(size: 22, weight: .bold, design: .rounded))
            Card(title: "Volume en snurken") {
                Chart {
                    ForEach(s.nightLoudness) { l in
                        AreaMark(x: .value("Tijd", l.at), y: .value("dB", l.decibel)).foregroundStyle(.white.opacity(0.18))
                    }
                    ForEach(s.events) { e in
                        RectangleMark(xStart: .value("Start", e.start), xEnd: .value("Einde", max(e.end, e.start.addingTimeInterval(30))),
                                      yStart: .value("", 0), yEnd: .value("", e.peakDecibel))
                            .foregroundStyle(Theme.color(e.intensity))
                    }
                    ForEach(Array(s.pauses.enumerated()), id: \.offset) { _, p in
                        RectangleMark(xStart: .value("Van", p.start), xEnd: .value("Tot", p.end)).foregroundStyle(.white.opacity(0.06))
                    }
                }
                .chartXScale(domain: s.start...end)
                .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisGridLine().foregroundStyle(R.line); AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).locale(R.nl)) } }
                .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
                .frame(height: 170)
                HStack(spacing: 10) {
                    ForEach([SnoreIntensity.light, .loud, .epic], id: \.self) { i in
                        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Theme.color(i)).frame(width: 10, height: 8); Text(i.label).font(.system(size: 9)) }
                    }
                    Spacer()
                    Text("grijs vlak = volume").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if !positions.isEmpty {
                Card(title: "Houding door de nacht") {
                    Chart {
                        ForEach(Array(positions.enumerated()), id: \.offset) { i, p in
                            let next = min(i + 1 < positions.count ? positions[i + 1].at : end, p.at.addingTimeInterval(600))
                            BarMark(xStart: .value("Start", p.at), xEnd: .value("Einde", next), y: .value("", "Houding"))
                                .foregroundStyle(Theme.color(p.position))
                        }
                    }
                    .chartXScale(domain: s.start...end)
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).locale(R.nl)) } }
                    .frame(height: 50)
                }
                Card(title: "Per houding") {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Houding").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Tijd").frame(width: 70, alignment: .trailing)
                            Text("Deel").frame(width: 45, alignment: .trailing)
                            Text("Gesnurkt").frame(width: 60, alignment: .trailing)
                            Text("Snurkt").frame(width: 50, alignment: .trailing)
                        }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(stats, id: \.position) { st in
                            HStack {
                                HStack(spacing: 6) { Circle().fill(Theme.color(st.position)).frame(width: 9, height: 9); Text(st.position.label) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(R.mins(st.minutes * 60)).frame(width: 70, alignment: .trailing)
                                Text("\(Int(st.minutes / totalMin * 100))%").frame(width: 45, alignment: .trailing)
                                Text("\(Int(st.snoreMinutes)) min").frame(width: 60, alignment: .trailing)
                                Text("\(st.minutes > 0 ? Int(min(1, st.snoreMinutes / st.minutes) * 100) : 0)%").frame(width: 50, alignment: .trailing)
                                    .foregroundStyle(st.minutes > 0 && st.snoreMinutes / st.minutes > 0.3 ? .red : .white)
                            }
                            .font(.system(size: 10))
                        }
                    }
                    if let best = stats.filter({ $0.minutes >= 20 && $0.position.isLying }).min(by: { $0.snoreMinutes / $0.minutes < $1.snoreMinutes / $1.minutes }),
                       let worst = stats.filter({ $0.minutes >= 20 && $0.position.isLying }).max(by: { $0.snoreMinutes / $0.minutes < $1.snoreMinutes / $1.minutes }),
                       best.position != worst.position {
                        Text("Je snurkte het minst op \(best.position.label.lowercased()) en het meest op \(worst.position.label.lowercased()).")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

// MARK: - Nacht · pagina 3: lichaam

private struct NightBodyPage: View {
    let s: SleepSession
    let part: Int            // 1 = slaapfasen + hartslag, 2 = zuurstof + ademhaling + beweging
    var body: some View {
        let end = s.end ?? .now
        let stages = s.stages.filter { $0.stage != .inBed }.sorted { $0.start < $1.start }
        let hr = s.vitals.filter { $0.kind == .heartRate }.sorted { $0.at < $1.at }
        let ox = s.vitals.filter { $0.kind == .oxygenSaturation }.sorted { $0.at < $1.at }
        let resp = s.vitals.filter { $0.kind == .respiratoryRate }.sorted { $0.at < $1.at }
        let move = s.vitals.filter { $0.kind == .movement }.sorted { $0.at < $1.at }
        VStack(alignment: .leading, spacing: 14) {
            Text(part == 1 ? "Slaap en hartslag" : "Zuurstof en ademhaling").font(.system(size: 22, weight: .bold, design: .rounded))
            if part == 2 {
                if !ox.isEmpty { vitalCard("Zuurstof (SpO₂)", ox, unit: "%", color: .cyan, start: s.start, end: end, rule: 90) }
                else { Card(title: "Zuurstof") { Text("Geen zuurstofmetingen voor deze nacht.").font(.system(size: 10)).foregroundStyle(.secondary) } }
                if !resp.isEmpty { vitalCard("Ademhaling", resp, unit: "/min", color: .mint, start: s.start, end: end) }
                if !move.isEmpty { vitalCard("Beweging (watch)", move, unit: "", color: .orange, start: s.start, end: end) }
                Card(title: "Hoe lees je dit?") {
                    Text("Zuurstof (SpO₂) ligt in je slaap meestal tussen 94 en 99%. Regelmatig onder 90%, samen met veel snurken of mogelijke ademstops, is een reden om met je huisarts te praten. De watch meet niet continu: losse lage waarden kunnen ook door een losse band komen.")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            } else if !stages.isEmpty {
                Card(title: "Slaapfasen (Apple Watch via Gezondheid)") {
                    Chart(stages, id: \.start) { x in
                        BarMark(xStart: .value("Start", x.start), xEnd: .value("Einde", x.end), y: .value("Fase", x.stage.label))
                            .foregroundStyle(R.stage(x.stage))
                    }
                    .chartXScale(domain: min(s.start, stages.first!.start)...max(end, stages.last!.end))
                    .chartYScale(domain: ["Wakker", "REM", "Kern", "Diep"])
                    .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisGridLine().foregroundStyle(R.line); AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).locale(R.nl)) } }
                    .frame(height: 120)
                    HStack(spacing: 8) {
                        ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { st in
                            let sec = stages.filter { $0.stage == st || (st == .core && $0.stage == .asleep) }.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +)
                            Tile(value: R.mins(sec), label: st.label, color: R.stage(st))
                        }
                    }
                }
            } else {
                Card(title: "Slaapfasen") { Text("Geen slaapfasen gevonden in Gezondheid voor deze nacht.").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if part == 1 {
                if !hr.isEmpty { vitalCard("Hartslag", hr, unit: "bpm", color: .pink, start: s.start, end: end) }
                else { Card(title: "Hartslag") { Text("Geen hartslag gemeten.").font(.system(size: 10)).foregroundStyle(.secondary) } }
            }
        }
    }

    private func vitalCard(_ title: String, _ xs: [VitalSample], unit: String, color: Color, start: Date, end: Date, rule: Double? = nil) -> some View {
        let vals = xs.map(\.value)
        let avg = vals.reduce(0, +) / Double(vals.count)
        return Card(title: title) {
            Chart {
                ForEach(xs) { v in
                    LineMark(x: .value("Tijd", v.at), y: .value(title, v.value)).foregroundStyle(color).interpolationMethod(.monotone)
                }
                if let rule { RuleMark(y: .value("Grens", rule)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisGridLine().foregroundStyle(R.line); AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).locale(R.nl)) } }
            .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
            .frame(height: 120)
            HStack(spacing: 8) {
                Tile(value: "\(Int(vals.min()!)) \(unit)", label: "laagste")
                Tile(value: "\(Int(avg.rounded())) \(unit)", label: "gemiddeld")
                Tile(value: "\(Int(vals.max()!)) \(unit)", label: "hoogste")
                if let rule {
                    let below = xs.filter { $0.value < rule }.count
                    Tile(value: "\(below)×", label: "onder \(Int(rule))\(unit)", color: below > 0 ? .red : .white)
                }
            }
        }
    }
}

// MARK: - Nacht · pagina 4: gebeurtenissen

private struct NightEventsPage: View {
    let s: SleepSession
    var body: some View {
        let loudest = s.events.sorted { $0.peakDecibel > $1.peakDecibel }.prefix(16).sorted { $0.start < $1.start }
        VStack(alignment: .leading, spacing: 14) {
            Text("Gebeurtenissen").font(.system(size: 22, weight: .bold, design: .rounded))
            Card(title: "Luidste snurkperiodes (\(loudest.count) van \(s.events.count))") {
                if loudest.isEmpty {
                    Text("Geen snurken gemeten.").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Tijd").frame(width: 50, alignment: .leading)
                            Text("Duur").frame(width: 50, alignment: .trailing)
                            Text("Piek").frame(width: 50, alignment: .trailing)
                            Text("Sterkte").frame(width: 60, alignment: .leading).padding(.leading, 10)
                            Text("Houding").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Gewekt").frame(width: 50, alignment: .trailing)
                        }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(loudest)) { e in
                            HStack {
                                Text(R.time(e.start)).frame(width: 50, alignment: .leading)
                                Text("\(Int(e.duration)) s").frame(width: 50, alignment: .trailing)
                                Text("\(Int(e.peakDecibel)) dB").frame(width: 50, alignment: .trailing)
                                HStack(spacing: 4) { Circle().fill(Theme.color(e.intensity)).frame(width: 7, height: 7); Text(e.intensity.label) }
                                    .frame(width: 60, alignment: .leading).padding(.leading, 10)
                                HStack(spacing: 4) { Circle().fill(Theme.color(e.position)).frame(width: 7, height: 7); Text(e.position.label + (e.isPartner ? " (partner)" : "")) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(e.wasNudged ? "✓" : "").frame(width: 50, alignment: .trailing)
                            }
                            .font(.system(size: 9.5))
                        }
                    }
                }
            }
            let sounds = s.nightSounds.sorted { $0.start < $1.start }.prefix(10)
            if !sounds.isEmpty {
                Card(title: "Andere geluiden") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(sounds)) { n in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: n.kind.symbol).foregroundStyle(Theme.accent).frame(width: 14)
                                Text(R.time(n.start)).frame(width: 40, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(n.kind.label) · \(max(1, Int(n.duration))) s")
                                    if let t = n.transcript, !t.isEmpty { Text("“\(t)”").italic().foregroundStyle(.secondary) }
                                }
                            }
                            .font(.system(size: 9.5))
                        }
                    }
                }
            }
            if !s.outOfBed.isEmpty {
                Card(title: "Uit bed") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.outOfBed.sorted { $0.start < $1.start }, id: \.start) { o in
                            Text("\(R.time(o.start))–\(R.time(o.end)) · \(Int(o.end.timeIntervalSince(o.start) / 60)) min · \(o.steps) stappen\(o.alerted ? " · slaapwandelalarm" : "")")
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Meerdere nachten

private struct PeriodSummaryPage: View {
    let nights: [SleepSession]
    var body: some View {
        let n = max(1, nights.count)
        let avgScore = nights.map(\.snoreScore).reduce(0, +) / n
        let avgPct = nights.map(\.snorePercentage).reduce(0, +) / Double(n)
        let avgSleep = nights.map(\.sleepDuration).reduce(0, +) / Double(n)
        let apnea = nights.map(\.possibleApneaEvents).reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Snurkrapport").font(.system(size: 26, weight: .bold, design: .rounded))
                if let f = nights.first, let l = nights.last {
                    Text("\(f.start.formatted(date: .long, time: .omitted)) – \(l.start.formatted(date: .long, time: .omitted)) · \(nights.count) \(nights.count == 1 ? "nacht" : "nachten")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 18) {
                PDFScoreRing(score: avgScore).frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gemiddeld: \(SnoreAnalysis.scoreLabel(avgScore).lowercased()) gesnurkt").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Gemiddelde snurkscore over de periode (lager = beter).").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            LazyVGrid(columns: cols, spacing: 8) {
                Tile(value: R.mins(avgSleep), label: "gem. geslapen")
                Tile(value: "\(Int(avgPct * 100))%", label: "gem. snurktijd", color: Theme.accent)
                Tile(value: "\(apnea)", label: "mogelijke ademstops (totaal)", color: apnea > 10 ? .red : .white)
                Tile(value: "\(nights.map(\.nudgeCount).reduce(0, +))", label: "keer gewekt (totaal)")
            }
            Card(title: "Snurkscore per nacht") {
                Chart(nights, id: \.id) { s in
                    BarMark(x: .value("Nacht", s.start, unit: .day), y: .value("Score", s.snoreScore))
                        .foregroundStyle(s.snoreScore < 10 ? .green : s.snoreScore < 25 ? .yellow : s.snoreScore < 50 ? .orange : .red)
                }
                .chartXAxis { AxisMarks { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
                .frame(height: 115)
            }
            Card(title: "Snurktijd per nacht (% van je slaap)") {
                Chart(nights, id: \.id) { s in
                    AreaMark(x: .value("Nacht", s.start, unit: .day), y: .value("%", s.snorePercentage * 100))
                        .foregroundStyle(Theme.accent.opacity(0.25)).interpolationMethod(.monotone)
                    LineMark(x: .value("Nacht", s.start, unit: .day), y: .value("%", s.snorePercentage * 100))
                        .foregroundStyle(Theme.accent).symbol(.circle).interpolationMethod(.monotone)
                }
                .chartXAxis { AxisMarks { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
                .frame(height: 90)
            }
            Card(title: "Geslapen per nacht (uren)") {
                Chart(nights, id: \.id) { s in
                    BarMark(x: .value("Nacht", s.start, unit: .day), y: .value("u", s.sleepDuration / 3600))
                        .foregroundStyle(Color.cyan.opacity(0.8))
                }
                .chartXAxis { AxisMarks { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
                .frame(height: 75)
            }
        }
    }
}

private struct PeriodTablePage: View {
    let nights: [SleepSession]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alle nachten").font(.system(size: 22, weight: .bold, design: .rounded))
            Card {
                VStack(spacing: 5) {
                    HStack {
                        Text("Nacht").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Slaap").frame(width: 55, alignment: .trailing)
                        Text("Score").frame(width: 40, alignment: .trailing)
                        Text("Snurk").frame(width: 40, alignment: .trailing)
                        Text("Luid").frame(width: 40, alignment: .trailing)
                        Text("Adem").frame(width: 35, alignment: .trailing)
                        Text("Factoren / middelen").frame(width: 150, alignment: .leading).padding(.leading, 8)
                    }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(nights, id: \.id) { s in
                        HStack {
                            Text(s.nightTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(R.mins(s.sleepDuration)).frame(width: 55, alignment: .trailing)
                            Text("\(s.snoreScore)").frame(width: 40, alignment: .trailing)
                                .foregroundStyle(s.snoreScore < 10 ? .green : s.snoreScore < 25 ? .yellow : s.snoreScore < 50 ? .orange : .red)
                            Text("\(Int(s.snorePercentage * 100))%").frame(width: 40, alignment: .trailing)
                            Text("\(Int(s.loudSnoreMinutes + s.epicSnoreMinutes))'").frame(width: 40, alignment: .trailing)
                            Text("\(s.possibleApneaEvents)").frame(width: 35, alignment: .trailing)
                            Text((s.factors.map(\.emoji) + s.remedies.map { "+" + $0.label }).joined(separator: " "))
                                .lineLimit(1).frame(width: 150, alignment: .leading).padding(.leading, 8)
                        }
                        .font(.system(size: 9.5))
                        Divider().overlay(R.line)
                    }
                }
            }
            Text("Score: snurkscore (lager = beter) · Snurk: deel van de nacht · Luid: minuten luid + episch · Adem: mogelijke ademstops")
                .font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}

private struct PeriodInsightsPage: View {
    let nights: [SleepSession]
    var body: some View {
        let insights = SnoreAnalysis.insights(nights)
        var perPos: [SleepPosition: (Double, Double)] = [:]
        for s in nights { for st in SnoreAnalysis.positionStats(s) {
            let o = perPos[st.position] ?? (0, 0); perPos[st.position] = (o.0 + st.minutes, o.1 + st.snoreMinutes)
        } }
        let pos = perPos.filter { $0.value.0 >= 10 }.sorted { $0.value.0 > $1.value.0 }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Inzichten").font(.system(size: 22, weight: .bold, design: .rounded))
            Card(title: "Wat maakt het verschil?") {
                if insights.isEmpty {
                    Text("Nog te weinig nachten met en zonder dezelfde factoren om te vergelijken. Vul bij het starten je factoren en middelen in.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(insights.prefix(10)) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: i.effect > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(i.effect > 0 ? .red : .green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(i.title).font(.system(size: 11, weight: .semibold))
                                    Text(i.detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !pos.isEmpty {
                Card(title: "Houding over alle nachten") {
                    Chart(pos, id: \.key) { p in
                        BarMark(x: .value("Snurkt %", p.value.0 > 0 ? min(1, p.value.1 / p.value.0) * 100 : 0), y: .value("Houding", p.key.label))
                            .foregroundStyle(Theme.color(p.key))
                            .annotation(position: .trailing) {
                                Text("\(Int(p.value.0 / 60)) u").font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(R.line); AxisValueLabel() } }
                    .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
                    .chartXAxisLabel("% van de tijd in die houding gesnurkt")
                    .frame(height: CGFloat(30 * pos.count + 30))
                }
            }
        }
    }
}
