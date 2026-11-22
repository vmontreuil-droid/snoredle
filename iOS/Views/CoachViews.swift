import SwiftUI
import SwiftData
import Charts

// MARK: - Coach

/// Persoonlijke tips + programma van 14 dagen om op je zij te leren slapen.
struct CoachView: View {
    @Query(sort: \SleepSession.start) private var sessions: [SleepSession]
    @AppStorage("coachStart") private var coachStart: Double = 0
    @EnvironmentObject var settings: AppSettings

    private var done: [SleepSession] { sessions.filter { $0.end != nil && $0.duration > 2 * 3600 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                programCard
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tips voor jou").font(.system(.title3, design: .rounded).weight(.semibold))
                    ForEach(tips, id: \.title) { t in
                        GlassCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: t.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.title).font(.subheadline.weight(.semibold))
                                    Text(t.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(NightBackground())
        .navigationTitle("Coach")
    }

    // MARK: Programma

    private var programDays: [(day: Int, date: Date, status: DayStatus)] {
        guard coachStart > 0 else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: coachStart))
        return (0..<14).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            let night = done.first { cal.isDate($0.end ?? $0.start, inSameDayAs: cal.date(byAdding: .day, value: 1, to: d)!) }
            let target = i < 7 ? 0.30 : 0.15
            let status: DayStatus
            if d > .now { status = .future }
            else if let n = night {
                let st = SnoreAnalysis.positionStats(n)
                let total = st.map(\.minutes).reduce(0, +)
                let back = total > 0 ? (st.first { $0.position == .back }?.minutes ?? 0) / total : 1
                status = (total > 0 && back <= target) ? .success : .tried
            } else { status = .missed }
            return (i + 1, d, status)
        }
    }

    enum DayStatus { case success, tried, missed, future }

    private var programCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "figure.mind.and.body").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("14 dagen zijslaper").font(.headline)
                        Text("Je watch geeft een tikje als je op je rug snurkt. Week 1: minder dan 30% op je rug. Week 2: minder dan 15%.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if coachStart == 0 {
                    Button {
                        coachStart = Date().timeIntervalSince1970
                        settings.nudgeEnabled = true
                        settings.nudgeOnlyOnBack = true
                    } label: {
                        Text("Start het programma").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.night)
                            .frame(maxWidth: .infinity).frame(height: 44).background(Theme.accent, in: Capsule())
                    }
                } else {
                    let days = programDays
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                        ForEach(days, id: \.day) { d in
                            ZStack {
                                Circle().fill(color(d.status))
                                Text("\(d.day)").font(.caption.weight(.semibold))
                                    .foregroundStyle(d.status == .success ? Theme.night : .primary)
                            }
                            .frame(height: 34)
                        }
                    }
                    let ok = days.filter { $0.status == .success }.count
                    Text("\(ok) van de 14 dagen gehaald").font(.footnote).foregroundStyle(.secondary)
                    Button("Opnieuw beginnen", role: .destructive) { coachStart = Date().timeIntervalSince1970 }
                        .font(.caption)
                }
            }
        }
    }

    private func color(_ s: DayStatus) -> Color {
        switch s {
        case .success: Theme.accent
        case .tried: .orange.opacity(0.35)
        case .missed: .white.opacity(0.08)
        case .future: .white.opacity(0.03)
        }
    }

    // MARK: Tips

    struct Tip { let title: String; let detail: String; let symbol: String }

    private var tips: [Tip] {
        var out: [Tip] = []
        let back = done.flatMap(SnoreAnalysis.positionStats).filter { $0.position == .back }
        let all = done.flatMap(SnoreAnalysis.positionStats)
        let backShare = back.map(\.snoreMinutes).reduce(0, +) / max(1, all.map(\.snoreMinutes).reduce(0, +))
        if backShare > 0.4 {
            out.append(Tip(title: "Je snurkt vooral op je rug",
                           detail: "\(Int(backShare * 100))% van je snurken gebeurt op je rug. Zet de tikjes aan en probeer het 14-dagenprogramma. Een kussen in je rug kan ook helpen.",
                           symbol: "arrow.turn.up.right"))
        }
        for i in SnoreAnalysis.insights(done).prefix(3) {
            out.append(Tip(title: i.title, detail: i.detail, symbol: i.effect > 0 ? "exclamationmark.circle" : "checkmark.circle"))
        }
        let avgHours = done.isEmpty ? 0 : done.map(\.sleepDuration).reduce(0, +) / Double(done.count) / 3600
        if !done.isEmpty, avgHours < settings.sleepGoalHours - 0.5 {
            out.append(Tip(title: "Je slaapt korter dan je doel",
                           detail: String(format: "Gemiddeld %.1f u, je doel is %.1f u. Vermoeidheid maakt snurken erger.", avgHours, settings.sleepGoalHours),
                           symbol: "bed.double.fill"))
        }
        let apnea = done.map(\.possibleApneaEvents).reduce(0, +)
        if apnea >= 10 {
            out.append(Tip(title: "Bespreek dit met je huisarts",
                           detail: "Er werden \(apnea) lange stiltes tijdens het snurken gemeten. Doe de slaapapneu-check en neem het PDF-rapport mee.",
                           symbol: "stethoscope"))
        }
        out += [
            Tip(title: "Geen alcohol in de 3 uur voor het slapen",
                detail: "Alcohol ontspant de spieren in je keel, waardoor je luider snurkt.", symbol: "wineglass"),
            Tip(title: "Verstopte neus? Pak die eerst aan",
                detail: "Een neusspoeling of neusspray (kort gebruiken) of een neuspleister kan helpen bij verkoudheid of allergie.", symbol: "wind"),
            Tip(title: "Hoofdeinde iets hoger",
                detail: "Een paar centimeter hoger liggen houdt je luchtweg vaak beter open.", symbol: "arrow.up.to.line"),
            Tip(title: "Vaste slaaptijden",
                detail: "Erg moe gaan slapen geeft diepere en luidere snurknachten. Een vast ritme helpt.", symbol: "clock"),
        ]
        return out
    }
}

// MARK: - Slaapapneu-check (STOP-BANG)

/// Erkende vragenlijst die het risico op obstructieve slaapapneu inschat. Geen diagnose.
struct ApneaCheckView: View {
    @AppStorage("stopbang.answers") private var raw = ""
    @Query(sort: \SleepSession.start) private var sessions: [SleepSession]

    static let questions: [(String, String)] = [
        ("S", "Snurk je luid (luider dan praten, of hoorbaar door een gesloten deur)?"),
        ("T", "Ben je overdag vaak moe, slaperig of uitgeput?"),
        ("O", "Heeft iemand gezien dat je ademhaling stopt of dat je naar adem hapt in je slaap?"),
        ("P", "Heb je een hoge bloeddruk, of word je ervoor behandeld?"),
        ("B", "Is je BMI hoger dan 35?"),
        ("A", "Ben je ouder dan 50 jaar?"),
        ("N", "Is je nekomtrek groter dan 40 cm?"),
        ("G", "Ben je een man?"),
    ]

    private var answers: [Bool] {
        let parts = raw.split(separator: ",").map { $0 == "1" }
        return parts.count == 8 ? parts : Array(repeating: false, count: 8)
    }
    private func set(_ i: Int, _ v: Bool) {
        var a = answers; a[i] = v
        raw = a.map { $0 ? "1" : "0" }.joined(separator: ",")
    }

    static func result(score: Int) -> (String, Color) {
        switch score {
        case 0...2: ("Laag risico", .green)
        case 3...4: ("Gemiddeld risico", .yellow)
        default: ("Hoog risico", .orange)
        }
    }

    var body: some View {
        let score = answers.filter { $0 }.count
        let (label, color) = Self.result(score: score)
        Form {
            Section {
                HStack {
                    Text("\(score)/8").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(color)
                    VStack(alignment: .leading) {
                        Text(label).font(.headline)
                        Text("STOP-BANG-vragenlijst").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Vragen") {
                ForEach(Array(Self.questions.enumerated()), id: \.offset) { i, q in
                    Toggle(isOn: Binding(get: { answers[i] }, set: { set(i, $0) })) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(q.0).font(.headline).foregroundStyle(Theme.accent).frame(width: 18)
                            Text(q.1).font(.subheadline)
                        }
                    }
                    .tint(Theme.accent)
                }
            }
            if let hint = snoringHint {
                Section { Label(hint, systemImage: "lightbulb.fill").font(.footnote) }
            }
            Section {
                Text("Deze vragenlijst stelt geen diagnose. Bij gemiddeld of hoog risico: bespreek het met je huisarts. Een slaaponderzoek kan slaapapneu bevestigen of uitsluiten. Je score staat ook in het PDF-rapport.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Slaapapneu-check")
    }

    /// Hulp bij vraag S op basis van je metingen.
    private var snoringHint: String? {
        let done = sessions.filter { $0.end != nil }
        guard done.count >= 3 else { return nil }
        let epic = done.map(\.epicSnoreMinutes).reduce(0, +) / Double(done.count)
        return epic >= 5 ? "Volgens je metingen snurk je gemiddeld \(Int(epic)) min per nacht episch luid: vraag S is dan waarschijnlijk 'ja'." : nil
    }

    static var savedScore: Int? {
        let raw = UserDefaults.standard.string(forKey: "stopbang.answers") ?? ""
        let parts = raw.split(separator: ",")
        return parts.count == 8 ? parts.filter { $0 == "1" }.count : nil
    }
}

// MARK: - Nachten vergelijken

struct CompareView: View {
    @Query(sort: \SleepSession.start, order: .reverse) private var sessions: [SleepSession]
    @State private var a: SleepSession?
    @State private var b: SleepSession?

    private var done: [SleepSession] { sessions.filter { $0.end != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    picker("Nacht A", selection: $a, color: Theme.accent)
                    picker("Nacht B", selection: $b, color: .cyan)
                }
                if let a, let b {
                    GlassCard {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("")
                                Text(a.start.formatted(.dateTime.day().month())).foregroundStyle(Theme.accent).font(.caption.weight(.semibold))
                                Text(b.start.formatted(.dateTime.day().month())).foregroundStyle(.cyan).font(.caption.weight(.semibold))
                            }
                            row("Score", "\(a.snoreScore)", "\(b.snoreScore)")
                            row("Geslapen", String(format: "%.1f u", a.sleepDuration / 3600), String(format: "%.1f u", b.sleepDuration / 3600))
                            row("Gesnurkt", "\(Int(a.snoreMinutes)) min", "\(Int(b.snoreMinutes)) min")
                            row("Episch", "\(Int(a.epicSnoreMinutes)) min", "\(Int(b.epicSnoreMinutes)) min")
                            row("Piek", "\(Int(a.peakDecibel)) dB", "\(Int(b.peakDecibel)) dB")
                            row("Op je rug", backText(a), backText(b))
                            row("Tikjes", "\(a.nudgeCount)", "\(b.nudgeCount)")
                            row("Factoren", a.factors.map(\.label).joined(separator: ", "), b.factors.map(\.label).joined(separator: ", "))
                            row("Middelen", a.remedies.map(\.label).joined(separator: ", "), b.remedies.map(\.label).joined(separator: ", "))
                        }
                        .font(.subheadline)
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Volume per uur van de nacht").font(.subheadline.weight(.semibold))
                            Chart {
                                ForEach(a.loudness) { s in
                                    LineMark(x: .value("Uur", s.at.timeIntervalSince(a.start) / 3600), y: .value("dB", s.decibel),
                                             series: .value("Nacht", "A"))
                                        .foregroundStyle(Theme.accent)
                                }
                                ForEach(b.loudness) { s in
                                    LineMark(x: .value("Uur", s.at.timeIntervalSince(b.start) / 3600), y: .value("dB", s.decibel),
                                             series: .value("Nacht", "B"))
                                        .foregroundStyle(.cyan)
                                }
                            }
                            .chartXAxisLabel("uren na het slapengaan")
                            .frame(height: 180)
                        }
                    }
                } else {
                    Text("Kies twee nachten om ze naast elkaar te zien, bijvoorbeeld met en zonder neusspray.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(NightBackground())
        .navigationTitle("Vergelijken")
        .onAppear {
            if a == nil { a = done.first }
            if b == nil { b = done.dropFirst().first }
        }
    }

    private func picker(_ title: String, selection: Binding<SleepSession?>, color: Color) -> some View {
        Menu {
            ForEach(done) { s in
                Button("\(s.start.formatted(.dateTime.weekday().day().month())) · score \(s.snoreScore)") { selection.wrappedValue = s }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(selection.wrappedValue?.start.formatted(.dateTime.weekday().day().month()) ?? "Kies…")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func row(_ l: String, _ x: String, _ y: String) -> some View {
        GridRow {
            Text(l).foregroundStyle(.secondary)
            Text(x.isEmpty ? "—" : x)
            Text(y.isEmpty ? "—" : y)
        }
    }

    private func backText(_ s: SleepSession) -> String {
        let st = SnoreAnalysis.positionStats(s)
        let total = st.map(\.minutes).reduce(0, +)
        guard total > 0 else { return "—" }
        return "\(Int((st.first { $0.position == .back }?.minutes ?? 0) / total * 100))%"
    }
}
