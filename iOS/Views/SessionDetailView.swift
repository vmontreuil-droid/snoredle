import SwiftUI
import SwiftData
import Charts
import AVFoundation
import Accelerate

struct SessionDetailView: View {
    @Bindable var session: SleepSession
    @EnvironmentObject var store: StoreManager
    @StateObject private var player = ClipPlayer()
    @State private var showOnlyFavorites = false
    @FocusState private var noteFocused: Bool
    @State private var showExplorer = false
    @State private var picked: Date?
    @State private var editFactors = false
    @State private var soundFilter: NightSoundKind?
    @Query(sort: \SleepSession.start) private var allSessions: [SleepSession]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                card("Wat speelde er") { factorsSection }
                if let note = session.alarmNote {
                    Label(note, systemImage: "alarm.fill").font(.footnote).foregroundStyle(Theme.accent)
                }
                if let h = highlight { card("Hoogtepunt van de nacht") { highlightRow(h) } }
                card("Volume en snurken") {
                    loudnessChart
                    pickedRow
                    Button { showExplorer = true } label: {
                        Label("Inzoomen en alle details", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                if !session.stages.isEmpty { card("Slaapfasen") { stagesChart } }
                if !session.nightSounds.isEmpty { card("Andere geluiden (\(session.nightSounds.count))") { nightSoundsList } }
                if !session.positions.isEmpty { card("Slaaphouding") { positionSection } }
                if !session.vitals.isEmpty { card("Lichaam") { vitalsSection } }
                card("Snurkfragmenten (\(session.events.count))") { eventsList }
                card("Hoe voel je je?") { morningSection }
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
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $editFactors) { FactorEditor(session: session) }
        .fullScreenCover(isPresented: $showExplorer) { NightExplorerView(session: session, player: player) }
        .alert("Fragment", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(player.error ?? "") }
        .onDisappear { player.stop() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: NightShareCard.image(for: session),
                              preview: SharePreview("Mijn nacht met Snoredle", image: NightShareCard.image(for: session))) {
                        Label("Als afbeelding", systemImage: "photo")
                    }
                    ShareLink(item: ExportService.pdf([session])) {
                        Label("Rapport (PDF)", systemImage: "doc.richtext")
                    }
                    if let h = highlight {
                        ShareLink(item: ClipRecorder.url(for: h.clip),
                                  message: Text("Zo klonk ik vannacht 😴 — gemeten met Snoredle")) {
                            Label("Luidste snurk (geluid)", systemImage: "waveform")
                        }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Klaar") { noteFocused = false }.fontWeight(.semibold)
            }
        }
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
            if let p = picked {
                RuleMark(x: .value("Gekozen", p)).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxisLabel("dB")
        .chartXSelection(value: $picked)
        .chartOverlay { _ in EmptyView() }
        .overlay(alignment: .topLeading) {
            if picked == nil {
                Text("Tik op de grafiek").font(.caption2).foregroundStyle(.tertiary).padding(4)
            }
        }
        .frame(height: 180)
    }

    /// Info over het aangeduide moment, met afspeelknop.
    @ViewBuilder private var pickedRow: some View {
        if let t = picked {
            let e = session.events.min { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }
            let near = e.map { abs($0.start.timeIntervalSince(t)) < 300 || ($0.start...$0.end).contains(t) } ?? false
            HStack(spacing: 12) {
                if near, let e, let c = e.clipFileName {
                    Button { player.toggle(ClipRecorder.url(for: c)) } label: {
                        Image(systemName: player.playingURL?.lastPathComponent == c ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34)).foregroundStyle(Theme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.formatted(date: .omitted, time: .shortened)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    if near, let e {
                        Text("Snurken om \(e.start.formatted(date: .omitted, time: .shortened)) · \(e.intensity.label) · \(Int(e.peakDecibel)) dB · \(e.position.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Geen snurken rond dit moment").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        }
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

    // MARK: Factoren

    @ViewBuilder private var factorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.factors.isEmpty && session.remedies.isEmpty {
                Text("Niets aangevinkt voor deze nacht.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(session.factors) { f in tag(f.label, f.symbol, Theme.accent) }
                    ForEach(session.remedies) { r in tag(r.label, r.symbol, .cyan) }
                }
            }
            if let cmp = comparison {
                Text(cmp).font(.footnote).foregroundStyle(.secondary)
            }
            Button(session.factors.isEmpty && session.remedies.isEmpty ? "Achteraf aanvinken" : "Aanpassen") { editFactors = true }
                .font(.footnote.weight(.semibold))
        }
    }

    private func tag(_ label: String, _ symbol: String, _ color: Color) -> some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    /// Vergelijking met je gemiddelde van de andere nachten.
    private var comparison: String? {
        let others = allSessions.filter { $0.id != session.id && $0.end != nil && $0.duration > 3 * 3600 }
        guard others.count >= 2, session.duration > 3 * 3600 else {
            return "Na een paar nachten zie je hier hoe deze nacht zich verhoudt tot je gemiddelde."
        }
        let avg = Double(others.map(\.snoreScore).reduce(0, +)) / Double(others.count)
        guard avg > 0 else { return nil }
        let pct = Int(((Double(session.snoreScore) - avg) / avg * 100).rounded())
        if abs(pct) < 10 { return "Je score lag rond je gemiddelde (\(Int(avg)))." }
        return "Je score was \(abs(pct))% \(pct > 0 ? "hoger" : "lager") dan je gemiddelde (\(Int(avg)))."
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
                    let on = soundFilter == k
                    Button { withAnimation(.snappy) { soundFilter = on ? nil : k } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: k.symbol).foregroundStyle(on ? Theme.night : Theme.accent)
                            Text("\(byKind[k]?.count ?? 0)").font(.headline)
                            Text(k.label).font(.caption2).multilineTextAlignment(.center)
                                .foregroundStyle(on ? Theme.night : .secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.04)),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(on ? Theme.night : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(session.nightSounds.filter { soundFilter == nil || $0.kind == soundFilter }
                        .sorted { $0.start < $1.start }.prefix(store.isPlus ? 500 : 5)) { n in
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
                .lineLimit(2...6)
                .padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($noteFocused)
                .submitLabel(.done)
                .onChange(of: session.note) { _, new in
                    // Enter = klaar (geen nieuwe regel).
                    if new.hasSuffix("\n") { session.note = String(new.dropLast()); noteFocused = false }
                }
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
final class ClipPlayer: NSObject, ObservableObject {
    @Published var playingURL: URL?
    @Published var error: String?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var attached = false
    private var token = 0

    /// Speelt een fragment af en normaliseert het volume (oude fragmenten zijn erg stil opgenomen).
    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "Dit fragment is niet meer beschikbaar (automatisch opgeruimd of niet bewaard)."
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                error = "Dit fragment is leeg."; return
            }
            try file.read(into: buffer)
            Self.normalize(buffer)

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            if !attached { engine.attach(node); attached = true }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            if !engine.isRunning { try engine.start() }

            token += 1
            let my = token
            node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                Task { @MainActor in if self?.token == my { self?.playingURL = nil } }
            }
            node.play()
            playingURL = url
        } catch {
            self.error = "Afspelen lukt niet: \(error.localizedDescription)"
        }
    }

    func stop() {
        token += 1
        node.stop()
        playingURL = nil
    }

    private static func normalize(_ b: AVAudioPCMBuffer) {
        guard let d = b.floatChannelData else { return }
        let n = vDSP_Length(b.frameLength)
        var peak: Float = 0
        for ch in 0..<Int(b.format.channelCount) {
            var m: Float = 0
            vDSP_maxmgv(d[ch], 1, &m, n)
            peak = max(peak, m)
        }
        guard peak > 0.0001 else { return }
        var gain = min(40, 0.9 / peak)
        for ch in 0..<Int(b.format.channelCount) { vDSP_vsmul(d[ch], 1, &gain, d[ch], 1, n) }
    }
}

/// Factoren en middelen achteraf aanpassen.
struct FactorEditor: View {
    @Bindable var session: SleepSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Wat speelde er?").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(SleepFactor.allCases) { f in
                            Chip(label: f.label, symbol: f.symbol, isOn: session.factorsRaw.contains(f.rawValue)) {
                                toggle(&session.factorsRaw, f.rawValue)
                            }
                        }
                    }
                    Text("Wat probeerde je?").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(Remedy.allCases) { r in
                            Chip(label: r.label, symbol: r.symbol, isOn: session.remediesRaw.contains(r.rawValue)) {
                                toggle(&session.remediesRaw, r.rawValue)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(NightBackground())
            .navigationTitle("Aanpassen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Klaar") { try? context.save(); dismiss() } } }
        }
    }

    private func toggle(_ list: inout [String], _ v: String) {
        if let i = list.firstIndex(of: v) { list.remove(at: i) } else { list.append(v) }
    }
}
