import SwiftUI
import Charts

/// Volledig scherm om de nacht in detail te bekijken:
/// knijpen om in/uit te zoomen, slepen om te verschuiven, tikken om een moment aan te duiden.
/// Alle grafieken (geluid, houding, hartslag, zuurstof) bewegen samen.
struct NightExplorerView: View {
    let session: SleepSession
    @ObservedObject var player: ClipPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var visible: Double = 0          // zichtbare duur in seconden
    @State private var baseVisible: Double = 0
    @State private var scrollX: Date = .now
    @State private var selected: Date?
    @State private var rangeMode = false
    @State private var rangeA: Date?
    @State private var rangeB: Date?
    private var range: ClosedRange<Date>? {
        guard let a = rangeA, let b = rangeB, abs(a.timeIntervalSince(b)) >= 30 else { return nil }
        return min(a, b)...max(a, b)
    }

    private var start: Date { session.start }
    private var end: Date { session.end ?? .now }
    private var total: Double { max(600, end.timeIntervalSince(start)) }

    private var loud: [LoudnessSample] { session.nightLoudness }
    private var events: [SnoreEvent] { session.events.sorted { $0.start < $1.start } }
    private var positions: [PositionSample] { session.positions.sorted { $0.at < $1.at } }
    private var hr: [VitalSample] { session.vitals.filter { $0.kind == .heartRate }.sorted { $0.at < $1.at } }
    private var spo2: [VitalSample] { session.vitals.filter { $0.kind == .oxygenSaturation }.sorted { $0.at < $1.at } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    zoomBar
                    modeBar
                    if rangeMode { rangeCard } else { selectionCard }
                    panel("Geluid", "dB") { soundChart.frame(height: 170) }
                    if !positions.isEmpty { panel("Houding", nil) { positionChart.frame(height: 70) } }
                    if !hr.isEmpty { panel("Hartslag", "bpm") { lineChart(hr, color: .pink).frame(height: 110) } }
                    if !spo2.isEmpty { panel("Zuurstof", "%") { lineChart(spo2, color: .cyan, rule: 90).frame(height: 100) } }
                    Text(rangeMode
                         ? "Sleep met één vinger over een grafiek om een periode aan te duiden. Knijp om in te zoomen."
                         : "Tik op een grafiek om een moment te kiezen. Knijp om in te zoomen, veeg om te verschuiven.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(NightBackground())
            .navigationTitle(session.nightTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Klaar") { player.stop(); dismiss() } } }
            .onAppear {
                visible = total; baseVisible = total; scrollX = start
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in visible = clamp(baseVisible / v.magnification) }
                    .onEnded { _ in baseVisible = visible }
            )
        }
    }

    // MARK: Zoom

    private func clamp(_ v: Double) -> Double { min(total, max(5 * 60, v)) }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            ForEach([(15.0, "15 min"), (60, "1 u"), (180, "3 u"), (0, "Alles")], id: \.1) { mins, label in
                let target = mins == 0 ? total : min(total, mins * 60)
                Button(label) {
                    withAnimation(.snappy) {
                        visible = target; baseVisible = target
                        if mins == 0 { scrollX = start }
                        else if let s = selected { scrollX = max(start, s.addingTimeInterval(-target / 2)) }
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(abs(visible - target) < 1 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)), in: Capsule())
                .foregroundStyle(abs(visible - target) < 1 ? Theme.night : .primary)
            }
            Spacer()
        }
    }

    // MARK: Moment of periode

    private var modeBar: some View {
        Picker("", selection: $rangeMode.animation(.snappy)) {
            Label("Moment", systemImage: "hand.tap").tag(false)
            Label("Periode", systemImage: "arrow.left.and.right").tag(true)
        }
        .pickerStyle(.segmented)
        .onChange(of: rangeMode) { _, on in if on { selected = nil } else { rangeA = nil; rangeB = nil } }
    }

    private func overlaps(_ a: Date, _ b: Date, _ r: ClosedRange<Date>) -> TimeInterval {
        max(0, min(b, r.upperBound).timeIntervalSince(max(a, r.lowerBound)))
    }

    @ViewBuilder private var rangeCard: some View {
        if let r = range {
            let dur = r.upperBound.timeIntervalSince(r.lowerBound)
            let ev = events.filter { overlaps($0.start, max($0.end, $0.start.addingTimeInterval(1)), r) > 0 }
            let snoreSec = ev.map { overlaps($0.start, $0.end, r) }.reduce(0, +)
            let dbs = loud.filter { r.contains($0.at) }.map(\.decibel)
            let hrs = hr.filter { r.contains($0.at) }.map(\.value)
            let ox = spo2.filter { r.contains($0.at) }.map(\.value)
            let sounds = session.nightSounds.filter { r.contains($0.start) }
            let pos = positionMinutes(in: r)
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(r.lowerBound.formatted(date: .omitted, time: .shortened)) – \(r.upperBound.formatted(date: .omitted, time: .shortened))")
                            .font(.title3.weight(.bold)).monospacedDigit()
                        Text("· \(Int(dur / 60)) min").foregroundStyle(.secondary)
                        Spacer()
                        Button { withAnimation(.snappy) { visible = max(300, dur * 1.1); baseVisible = visible; scrollX = max(start, r.lowerBound.addingTimeInterval(-dur * 0.05)) } } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        Button { rangeA = nil; rangeB = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 16) {
                        stat("\(Int(snoreSec / 60)) min", "gesnurkt (\(dur > 0 ? Int(snoreSec / dur * 100) : 0)%)", "waveform")
                        if let m = dbs.max() { stat("\(Int(dbs.reduce(0, +) / Double(dbs.count)))–\(Int(m)) dB", "gem.–max", "speaker.wave.2") }
                    }
                    HStack(spacing: 16) {
                        if !hrs.isEmpty { stat("\(Int(hrs.min()!))–\(Int(hrs.max()!))", "bpm (gem. \(Int(hrs.reduce(0, +) / Double(hrs.count))))", "heart.fill") }
                        if let o = ox.min() { stat("\(Int(o))%", "laagste SpO₂", "lungs.fill") }
                        if !sounds.isEmpty { stat("\(sounds.count)", "andere geluiden", "ear") }
                    }
                    if !pos.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Houding").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(pos, id: \.0) { p, mins in
                                HStack {
                                    Circle().fill(Theme.color(p)).frame(width: 8, height: 8)
                                    Text(p.label).font(.caption)
                                    Spacer()
                                    Text("\(Int(mins)) min").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    let top = ev.filter { $0.clipFileName != nil }.sorted { $0.peakDecibel > $1.peakDecibel }.prefix(5)
                    if !top.isEmpty {
                        Text("Luidste snurken in deze periode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(top)) { e in
                            clipRow(title: "\(e.start.formatted(date: .omitted, time: .shortened)) · \(e.intensity.label)",
                                    detail: "\(Int(e.duration)) s · \(Int(e.peakDecibel)) dB\(e.wasNudged ? " · gewekt" : "")",
                                    clip: e.clipFileName)
                        }
                    } else if ev.isEmpty {
                        Text("Geen snurken in deze periode.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .transition(.opacity)
        } else {
            GlassCard {
                Label("Sleep met je vinger over een grafiek om een periode te kiezen.", systemImage: "hand.draw")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Minuten per houding binnen een periode (elke meting telt tot de volgende, hoogstens 10 min).
    private func positionMinutes(in r: ClosedRange<Date>) -> [(SleepPosition, Double)] {
        var out: [SleepPosition: Double] = [:]
        for (i, p) in positions.enumerated() {
            let next = min(i + 1 < positions.count ? positions[i + 1].at : end, p.at.addingTimeInterval(600))
            let o = overlaps(p.at, next, r)
            if o > 0 { out[p.position, default: 0] += o / 60 }
        }
        return out.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Geselecteerd moment

    private var selectedEvent: SnoreEvent? {
        guard let t = selected else { return nil }
        return events.first { $0.start.addingTimeInterval(-20) <= t && t <= $0.end.addingTimeInterval(20) }
    }
    private var selectedSound: NightSoundEvent? {
        guard let t = selected else { return nil }
        return session.nightSounds.first { $0.start.addingTimeInterval(-20) <= t && t <= $0.end.addingTimeInterval(20) }
    }
    private func nearest<T>(_ xs: [T], _ at: (T) -> Date) -> T? {
        guard let t = selected else { return nil }
        return xs.min { abs(at($0).timeIntervalSince(t)) < abs(at($1).timeIntervalSince(t)) }
    }

    @ViewBuilder private var selectionCard: some View {
        if let t = selected {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(t.formatted(date: .omitted, time: .standard)).font(.title3.weight(.bold)).monospacedDigit()
                        Spacer()
                        Button { selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 16) {
                        if let l = nearest(loud, { $0.at }) { stat("\(Int(l.decibel)) dB", "volume", "waveform") }
                        if let p = nearest(positions, { $0.at }) { stat(p.position.label, "houding", p.position.symbol) }
                        if let h = nearest(hr, { $0.at }) { stat("\(Int(h.value))", "bpm", "heart.fill") }
                        if let o = nearest(spo2, { $0.at }) { stat("\(Int(o.value))%", "SpO₂", "lungs.fill") }
                    }
                    if let e = selectedEvent {
                        clipRow(title: "Snurken · \(e.intensity.label)",
                                detail: "\(Int(e.duration)) s · \(Int(e.peakDecibel)) dB\(e.wasNudged ? " · tikje" : "")",
                                clip: e.clipFileName)
                    }
                    if let n = selectedSound {
                        clipRow(title: n.kind.label, detail: "\(max(1, Int(n.duration))) s", clip: n.clipFileName)
                    }
                    if selectedEvent == nil && selectedSound == nil {
                        Text("Geen snurken of geluid op dit moment.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func clipRow(title: String, detail: String, clip: String?) -> some View {
        HStack(spacing: 12) {
            if let c = clip {
                Button { player.toggle(ClipRecorder.url(for: c)) } label: {
                    Image(systemName: player.playingURL?.lastPathComponent == c ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36)).foregroundStyle(Theme.accent)
                }
            }
            VStack(alignment: .leading) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let c = clip {
                ShareLink(item: ClipRecorder.url(for: c)) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private func stat(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(v, systemImage: icon).font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Grafieken

    private func panel<C: View>(_ title: String, _ unit: String?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer(); if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) } }
            c()
        }
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var axisStride: Calendar.Component { visible <= 45 * 60 ? .minute : .hour }
    // Max. ± 5 labels op de breedte van een gsm, anders lopen de uren in elkaar.
    private var axisCount: Int { visible <= 20 * 60 ? 5 : (visible <= 45 * 60 ? 10 : (visible <= 3 * 3600 ? 1 : (visible <= 6 * 3600 ? 2 : 3))) }

    /// Gemeenschappelijke instellingen: samen scrollen, zoomen en selecteren.
    private func timeline<C: View>(_ chart: C) -> some View {
        chart
            .chartXScale(domain: start...end)
            .chartScrollableAxes(rangeMode ? [] : .horizontal)     // in periode-modus sleep je om te kiezen
            .chartXVisibleDomain(length: max(300, visible))
            .chartScrollPosition(x: $scrollX)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let frame = proxy.plotFrame.map { geo[$0] } ?? .zero
                    let date: (CGFloat) -> Date? = { x in
                        proxy.value(atX: x - frame.minX, as: Date.self).map { min(end, max(start, $0)) }
                    }
                    if rangeMode {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if let a = date(v.startLocation.x), let b = date(v.location.x) { rangeA = a; rangeB = b }
                                }
                                .onEnded { v in
                                    // Gewoon getikt (niet gesleept): kwartier rond het tikpunt.
                                    guard abs(v.translation.width) < 8, let d = date(v.location.x) else { return }
                                    let a = max(start, d.addingTimeInterval(-450)), b = min(end, a.addingTimeInterval(900))
                                    withAnimation(.snappy) { rangeA = max(start, b.addingTimeInterval(-900)); rangeB = b }
                                })
                    } else {
                        // Alleen tikken opvangen; vegen blijft scrollen.
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { loc in
                                if let d = date(loc.x) { withAnimation(.snappy) { selected = d } }
                            }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: axisStride, count: axisCount)) {
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
    }

    private var soundChart: some View {
        timeline(Chart {
            ForEach(loud) { s in
                AreaMark(x: .value("Tijd", s.at), y: .value("dB", s.decibel))
                    .foregroundStyle(.white.opacity(0.15))
            }
            ForEach(events) { e in
                RectangleMark(xStart: .value("Start", e.start), xEnd: .value("Einde", max(e.end, e.start.addingTimeInterval(20))),
                              yStart: .value("", 0), yEnd: .value("", e.peakDecibel))
                    .foregroundStyle(Theme.color(e.intensity))
            }
            ForEach(session.nightSounds) { n in
                PointMark(x: .value("Tijd", n.start), y: .value("dB", 4))
                    .symbol { Image(systemName: n.kind.symbol).font(.system(size: 9)).foregroundStyle(.white) }
            }
            if let s = selected { RuleMark(x: .value("Gekozen", s)).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5)) }
            if let r = range { RectangleMark(xStart: .value("Van", r.lowerBound), xEnd: .value("Tot", r.upperBound)).foregroundStyle(Theme.accent.opacity(0.18)) }
        })
    }

    private var positionChart: some View {
        timeline(Chart {
            ForEach(Array(positions.enumerated()), id: \.offset) { i, p in
                let next = min(i + 1 < positions.count ? positions[i + 1].at : end, p.at.addingTimeInterval(600))
                BarMark(xStart: .value("Start", p.at), xEnd: .value("Einde", next), y: .value("", "Houding"))
                    .foregroundStyle(Theme.color(p.position))
            }
            if let s = selected { RuleMark(x: .value("Gekozen", s)).foregroundStyle(Theme.accent) }
            if let r = range { RectangleMark(xStart: .value("Van", r.lowerBound), xEnd: .value("Tot", r.upperBound)).foregroundStyle(Theme.accent.opacity(0.18)) }
        }
        .chartYAxis(.hidden))
    }

    private func lineChart(_ xs: [VitalSample], color: Color, rule: Double? = nil) -> some View {
        timeline(Chart {
            ForEach(xs) { v in
                LineMark(x: .value("Tijd", v.at), y: .value("Waarde", v.value)).foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            if let rule {
                RuleMark(y: .value("Grens", rule)).foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let s = selected { RuleMark(x: .value("Gekozen", s)).foregroundStyle(Theme.accent) }
            if let r = range { RectangleMark(xStart: .value("Van", r.lowerBound), xEnd: .value("Tot", r.upperBound)).foregroundStyle(Theme.accent.opacity(0.18)) }
        }
        .chartYScale(domain: .automatic(includesZero: false)))
    }
}

// MARK: - Deelkaart

/// Mooie afbeelding van je nacht om te delen (Instagram-formaat 4:5).
struct NightShareCard: View {
    let session: SleepSession

    var body: some View {
        let stats = SnoreAnalysis.positionStats(session)
        let total = max(1, stats.map(\.minutes).reduce(0, +))   // max: nooit delen door 0
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                MoonMark().frame(width: 56, height: 56)
                Text("snore").font(.system(size: 40, weight: .bold, design: .rounded))
                + Text("dle").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundColor(Theme.accent)
                Spacer()
            }
            Text(session.start.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                .font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 34) {
                ScoreRing(score: session.snoreScore).frame(width: 170, height: 170).scaleEffect(1.0)
                VStack(alignment: .leading, spacing: 10) {
                    Text(SnoreAnalysis.scoreLabel(session.snoreScore)).font(.system(size: 46, weight: .bold, design: .rounded))
                    Text(String(format: "%.1f uur geslapen", session.sleepDuration / 3600)).font(.system(size: 24))
                    Text("\(Int(session.snoreMinutes)) min gesnurkt").font(.system(size: 24))
                    if session.nudgeCount > 0 { Text("\(session.nudgeCount) tikjes van de watch").font(.system(size: 24)) }
                }
            }
            if !stats.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Slaaphouding").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(stats) { s in
                                Rectangle().fill(Theme.color(s.position)).frame(width: g.size.width * s.minutes / total)
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 22)
                    HStack(spacing: 18) {
                        ForEach(stats.prefix(4)) { s in
                            Label("\(s.position.label) \(Int(s.minutes / total * 100))%", systemImage: "circle.fill")
                                .font(.system(size: 18)).foregroundStyle(Theme.color(s.position))
                        }
                    }
                }
            }
            Spacer()
            Text("Gemeten met Snoredle").font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(60)
        .frame(width: 1080 / 2, height: 1350 / 2, alignment: .topLeading)
        .background(
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.22), Color(red: 0.04, green: 0.05, blue: 0.13)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
            }
        )
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @MainActor
    static func image(for session: SleepSession) -> Image {
        let r = ImageRenderer(content: NightShareCard(session: session))
        r.scale = 2
        return r.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "moon.zzz.fill")
    }
}
