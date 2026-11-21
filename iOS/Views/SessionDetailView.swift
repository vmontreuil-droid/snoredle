import SwiftUI
import Charts
import AVFoundation

struct SessionDetailView: View {
    @Bindable var session: SleepSession
    @EnvironmentObject var store: StoreManager
    @StateObject private var player = ClipPlayer()
    @State private var showOnlyFavorites = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let note = session.alarmNote {
                    Label(note, systemImage: "alarm.fill").font(.footnote).foregroundStyle(Theme.accent)
                }
                if let h = highlight { card("Hoogtepunt van de nacht") { highlightRow(h) } }
                card("Volume en snurken") { loudnessChart }
                if !session.stages.isEmpty { card("Slaapfasen") { stagesChart } }
                if !session.nightSounds.isEmpty { card("Andere geluiden (\(session.nightSounds.count))") { nightSoundsList } }
                if !session.positions.isEmpty { card("Slaaphouding") { positionSection } }
                if !session.vitals.isEmpty { card("Lichaam") { vitalsSection } }
                card("Snurkfragmenten (\(session.events.count))") { eventsList }
                card("Hoe voel je je?") { morningSection }
                if !session.factors.isEmpty || !session.remedies.isEmpty {
                    card("Factoren en middelen") {
                        Text((session.factors.map { "\($0.emoji) \($0.label)" } + session.remedies.map { "🛠️ \($0.label)" })
                            .joined(separator: " · ")).font(.subheadline)
                    }
                }
                if session.possibleApneaEvents >= 5 {
                    Label("Er werden \(session.possibleApneaEvents) lange stiltes tijdens het snurken gemeten. Dat kan op ademstops wijzen. Snoredle stelt geen diagnose: bespreek dit met je huisarts.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding()
        }
        .background(NightBackground())
        .navigationTitle(session.start.formatted(.dateTime.weekday(.wide).day().month()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 20) {
            ScoreRing(score: session.snoreScore).frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(SnoreAnalysis.scoreLabel(session.snoreScore)).font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    row("Geslapen", String(format: "%.1f u", session.duration / 3600)
                        + (session.duration / 3600 >= AppSettings.shared.sleepGoalHours ? " ✓ doel" : ""))
                    row("Gesnurkt", "\(Int(session.snoreMinutes)) min (\(Int(session.snorePercentage * 100))%)")
                    row("Luid / episch", "\(Int(session.loudSnoreMinutes)) / \(Int(session.epicSnoreMinutes)) min")
                    row("Piek", "\(Int(session.peakDecibel)) dB")
                    if session.nudgeCount > 0 { row("Tikjes", "\(session.nudgeCount)") }
                }.font(.subheadline)
            }
        }
    }
    private func row(_ a: String, _ b: String) -> some View {
        GridRow { Text(a).foregroundStyle(.secondary); Text(b) }
    }

    private var loudnessChart: some View {
        Chart {
            ForEach(session.loudness.sorted { $0.at < $1.at }) { s in
                AreaMark(x: .value("Tijd", s.at), y: .value("dB", s.decibel))
                    .foregroundStyle(.white.opacity(0.15))
            }
            ForEach(session.events) { e in
                RectangleMark(xStart: .value("Start", e.start), xEnd: .value("Einde", e.end),
                              yStart: .value("", 0), yEnd: .value("", e.peakDecibel))
                    .foregroundStyle(Theme.color(e.intensity))
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxisLabel("dB")
        .frame(height: 180)
    }

    private var positionSection: some View {
        let stats = SnoreAnalysis.positionStats(session)
        let samples = session.positions.sorted { $0.at < $1.at }
        return VStack(alignment: .leading, spacing: 12) {
            Chart(Array(samples.enumerated()), id: \.offset) { i, p in
                let end = i + 1 < samples.count ? samples[i + 1].at : (session.end ?? .now)
                BarMark(xStart: .value("Start", p.at), xEnd: .value("Einde", end), y: .value("", "Houding"))
                    .foregroundStyle(Theme.color(p.position))
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 50)
            ForEach(stats) { s in
                HStack {
                    Circle().fill(Theme.color(s.position)).frame(width: 10)
                    Text(s.position.label)
                    Spacer()
                    Text("\(Int(s.minutes)) min").foregroundStyle(.secondary)
                    Text("snurkt \(Int(s.snoreShare * 100))%").frame(width: 100, alignment: .trailing)
                }.font(.subheadline)
            }
        }
    }

    // MARK: Nieuwe onderdelen

    private struct Highlight { let title: String; let detail: String; let clip: String }

    /// Luidste snurkfragment, of anders het langste praatmoment.
    private var highlight: Highlight? {
        if let e = session.events.filter({ $0.clipFileName != nil }).max(by: { $0.peakDecibel < $1.peakDecibel }),
           let c = e.clipFileName {
            return Highlight(title: "Luidste snurk", detail: "\(Int(e.peakDecibel)) dB om \(e.start.formatted(date: .omitted, time: .shortened))", clip: c)
        }
        if let t = session.nightSounds.filter({ $0.clipFileName != nil }).max(by: { $0.duration < $1.duration }),
           let c = t.clipFileName {
            return Highlight(title: "Je praatte in je slaap", detail: "\(Int(t.duration)) s om \(t.start.formatted(date: .omitted, time: .shortened))", clip: c)
        }
        return nil
    }

    private func highlightRow(_ h: Highlight) -> some View {
        HStack(spacing: 14) {
            Button { player.toggle(ClipRecorder.url(for: h.clip)) } label: {
                Image(systemName: player.playingURL?.lastPathComponent == h.clip ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).font(.headline)
                Text(h.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: ClipRecorder.url(for: h.clip),
                      message: Text("Zo klonk ik vannacht 😴 — gemeten met Snoredle")) {
                Image(systemName: "square.and.arrow.up").font(.title3)
            }
        }
    }

    private var stagesChart: some View {
        let st = session.stages.sorted { $0.start < $1.start }.filter { $0.stage != .inBed }
        let totals = Dictionary(grouping: st, by: { $0.stage == .asleep ? .core : $0.stage })
            .mapValues { $0.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +) / 60 }
        return VStack(alignment: .leading, spacing: 10) {
            Chart(st) { x in
                BarMark(xStart: .value("Start", x.start), xEnd: .value("Einde", x.end),
                        y: .value("Fase", (x.stage == .asleep ? SleepStage.core : x.stage).label))
                    .foregroundStyle(stageColor(x.stage))
            }
            .chartYScale(domain: [SleepStage.awake.label, SleepStage.rem.label, SleepStage.core.label, SleepStage.deep.label])
            .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 130)
            HStack(spacing: 14) {
                ForEach([SleepStage.deep, .core, .rem, .awake], id: \.rawValue) { k in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(totals[k] ?? 0)) min").font(.subheadline.weight(.semibold))
                        Text(k.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Gemeten door je watch via Apple Gezondheid.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func stageColor(_ s: SleepStage) -> Color {
        switch s {
        case .awake: .orange; case .rem: .cyan; case .core, .asleep: .blue; case .deep: .indigo; case .inBed: .gray
        }
    }

    private var nightSoundsList: some View {
        let byKind = Dictionary(grouping: session.nightSounds, by: \.kind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                ForEach(NightSoundKind.allCases.filter { byKind[$0] != nil }, id: \.self) { k in
                    VStack(spacing: 4) {
                        Image(systemName: k.symbol).foregroundStyle(Theme.accent)
                        Text("\(byKind[k]?.count ?? 0)").font(.headline)
                        Text(k.label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                }
            }
            ForEach(session.nightSounds.sorted { $0.start < $1.start }.prefix(store.isPlus ? 200 : 5)) { n in
                HStack {
                    Image(systemName: n.kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                    Text(n.start.formatted(date: .omitted, time: .shortened)).font(.subheadline.monospacedDigit())
                    Text("\(n.kind.label) · \(max(1, Int(n.duration))) s").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let c = n.clipFileName {
                        Button { player.toggle(ClipRecorder.url(for: c)) } label: {
                            Image(systemName: player.playingURL?.lastPathComponent == c ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title3)
                        }
                    }
                }
            }
            if session.nightSounds.contains(where: { $0.kind == .gasp }) {
                Text("Naar adem happen na snurken kan op ademstops wijzen. Bespreek het met je arts als het vaak voorkomt.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VitalKind.allCases.filter { k in session.vitals.contains { $0.kind == k } }, id: \.self) { kind in
                let vs = session.vitals.filter { $0.kind == kind }.sorted { $0.at < $1.at }
                let values = vs.map(\.value)
                HStack {
                    Text(kind.label).font(.subheadline.bold())
                    Spacer()
                    Text("gem. \(Int(values.reduce(0, +) / Double(values.count))) · min \(Int(values.min() ?? 0)) · max \(Int(values.max() ?? 0)) \(kind.unit)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(session.events) { e in
                        RectangleMark(xStart: .value("Start", e.start), xEnd: .value("Einde", e.end))
                            .foregroundStyle(Theme.accent.opacity(0.12))
                    }
                    ForEach(vs) { v in
                        LineMark(x: .value("Tijd", v.at), y: .value(kind.label, v.value))
                            .foregroundStyle(kind == .oxygenSaturation ? .cyan : .pink)
                        if kind == .oxygenSaturation, v.value < 90 {
                            PointMark(x: .value("Tijd", v.at), y: .value(kind.label, v.value))
                                .foregroundStyle(.red).symbolSize(30)
                        }
                    }
                    if kind == .oxygenSaturation {
                        RuleMark(y: .value("Grens", 90)).foregroundStyle(.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 80)
            }
        }
    }

    private var eventsList: some View {
        let events = session.events.sorted { $0.start < $1.start }.filter { !showOnlyFavorites || $0.isFavorite }
        return VStack(spacing: 8) {
            Toggle("Alleen favorieten", isOn: $showOnlyFavorites).font(.subheadline)
            ForEach(events.prefix(store.isPlus ? 500 : 5)) { e in
                HStack {
                    Button {
                        if let f = e.clipFileName { player.toggle(ClipRecorder.url(for: f)) }
                    } label: {
                        Image(systemName: player.playingURL?.lastPathComponent == e.clipFileName && e.clipFileName != nil
                              ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }.disabled(e.clipFileName == nil)
                    VStack(alignment: .leading) {
                        Text(e.start.formatted(date: .omitted, time: .shortened)).font(.subheadline.bold())
                        Text("\(Int(e.duration)) s · \(e.intensity.label) · \(Int(e.peakDecibel)) dB · \(e.position.label)\(e.wasNudged ? " · tikje" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(Theme.color(e.intensity)).frame(width: 10)
                    Button { e.isFavorite.toggle() } label: {
                        Image(systemName: e.isFavorite ? "star.fill" : "star")
                    }
                    if let f = e.clipFileName {
                        ShareLink(item: ClipRecorder.url(for: f)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            if !store.isPlus, session.events.count > 5 {
                NavigationLink("Alle \(session.events.count) fragmenten met Snoredle Plus") { PaywallView() }.font(.subheadline)
            }
        }
    }

    private var morningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(1...5, id: \.self) { i in
                    Button { session.rating = i } label: {
                        Text(["😫", "🙁", "😐", "🙂", "😄"][i - 1]).font(.largeTitle)
                            .opacity(session.rating == i ? 1 : 0.35)
                    }
                }
            }
            TextField("Notitie (bv. partner sliep in andere kamer)", text: $session.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            c()
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor
final class ClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingURL: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playingURL == url { player?.stop(); playingURL = nil; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.play()
        playingURL = player == nil ? nil : url
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in self.playingURL = nil }
    }
}
