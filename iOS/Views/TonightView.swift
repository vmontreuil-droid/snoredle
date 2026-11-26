import SwiftUI
import SwiftData

/// Startscherm: rustig, donker, met de startknop altijd bereikbaar onderaan.
struct TonightView: View {
    @EnvironmentObject var manager: SessionManager
    @EnvironmentObject var hub: WearableHub
    @EnvironmentObject var settings: AppSettings
    @Query(sort: \SleepSession.start, order: .reverse) private var sessions: [SleepSession]

    @AppStorage("lastRemedies") private var lastRemediesRaw = ""
    @State private var factors: Set<SleepFactor> = []
    @State private var remedies: Set<Remedy> = []
    @State private var showCalibration = false
    @State private var showAllFactors = false
    @State private var showSounds = false
    @State private var healthNote: String?
    @State private var showBreathing = false
    @ObservedObject private var sounds = SleepSoundController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if let s = manager.interrupted {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Je meting werd onderbroken", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline).foregroundStyle(.orange)
                                Text("Snoredle stopte onverwacht tijdens je nacht van \(s.start.formatted(date: .omitted, time: .shortened)). Meet verder in dezelfde nacht; het gat telt als pauze.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack {
                                    Button { manager.resumeInterrupted() } label: {
                                        Label("Verder meten", systemImage: "play.fill").frame(maxWidth: .infinity)
                                    }.buttonStyle(.borderedProminent)
                                    Button("Afsluiten") { manager.closeInterrupted() }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    if let last = sessions.first(where: { $0.end != nil }) {
                        NavigationLink { SessionDetailView(session: last) } label: { LastNightCard(session: last) }
                            .buttonStyle(.plain)
                    }

                    WatchStatusPill(showCalibration: $showCalibration)

                    AlarmCard()

                    Button { showSounds = true } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(.white.opacity(0.06))
                                Image(systemName: sounds.isPlaying ? sounds.sound.symbol : "music.note")
                                    .foregroundStyle(Theme.accent)
                                    .symbolEffect(.variableColor.iterative, isActive: sounds.isPlaying)
                            }.frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Slaapgeluiden").font(.subheadline.weight(.semibold))
                                Text(sounds.isPlaying ? "\(sounds.sound.label) speelt" : "Regen, zee, ruis… om in te slapen")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Button { showBreathing = true } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(.white.opacity(0.06))
                                Image(systemName: "wind").foregroundStyle(Theme.accent)
                            }.frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Ademhaling 4-7-8").font(.subheadline.weight(.semibold))
                                Text("Twee minuten om tot rust te komen").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    section(title: "Wat speelde er vandaag?",
                            subtitle: healthNote ?? (factors.isEmpty ? "Optioneel — zo leer je wat je snurken beïnvloedt" : "\(factors.count) geselecteerd")) {
                        let shown = showAllFactors ? SleepFactor.allCases : Array(SleepFactor.allCases.prefix(8))
                        FlowLayout(spacing: 8) {
                            ForEach(shown) { f in
                                Chip(label: f.label, symbol: f.symbol, isOn: factors.contains(f)) { toggle(&factors, f) }
                            }
                            if !showAllFactors {
                                Button { withAnimation(.snappy) { showAllFactors = true } } label: {
                                    Label("Meer", systemImage: "plus").font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    section(title: "Ik probeer vannacht",
                            subtitle: remedies.isEmpty ? "Snoredle meet of het helpt" : "\(remedies.count) geselecteerd") {
                        FlowLayout(spacing: 8) {
                            ForEach(Remedy.allCases) { r in
                                Chip(label: r.label, symbol: r.symbol, isOn: remedies.contains(r)) { toggle(&remedies, r) }
                            }
                        }
                    }

                    if let err = manager.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(NightBackground())
            .safeAreaInset(edge: .bottom) { startButton }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .sheet(isPresented: $showSounds) { SleepSoundsSheet() }
            .fullScreenCover(isPresented: $showBreathing) { BreathingView() }
            .onAppear {
                remedies = Set(lastRemediesRaw.split(separator: ",").compactMap { Remedy(rawValue: String($0)) })
            }
            .task {
                guard settings.useHealthKit else { return }
                try? await HealthKitService.shared.requestAuthorization()
                let fromHealth = await HealthKitService.shared.factorsToday()
                let new = fromHealth.filter { !factors.contains($0) }
                if !new.isEmpty {
                    factors.formUnion(new)
                    healthNote = "Uit Gezondheid: " + new.map(\.label).joined(separator: ", ")
                }
            }
            .sensoryFeedback(.selection, trigger: factors.count + remedies.count)
        }
    }

    // MARK: Onderdelen

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "nl_BE"))).capitalized)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            MoonMark().frame(width: 52, height: 52)
        }
        .padding(.top, 12)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Goedemorgen"
        case 12..<18: "Goedemiddag"
        default: "Goedenavond"
        }
    }

    private var startButton: some View {
        VStack(spacing: 8) {
            Button {
                lastRemediesRaw = remedies.map(\.rawValue).joined(separator: ",")
                manager.start(factors: Array(factors), remedies: Array(remedies))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill").font(.title3)
                    Text("Start de nacht").font(.system(.title3, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(Theme.night)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.80, blue: 0.48), Theme.accent],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule())
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 6)
            }
            .buttonStyle(PressableStyle())
            Text("Leg je iPhone aan de lader, naast je bed")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [Theme.night.opacity(0), Theme.night.opacity(0.92), Theme.night],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func section<C: View>(title: String, subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            content()
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ item: T) {
        withAnimation(.snappy(duration: 0.2)) {
            if set.contains(item) { set.remove(item) } else { set.insert(item) }
        }
    }
}

// MARK: - Herbruikbare stijlelementen

/// Nachtelijke achtergrond: diepblauw verloop met een zachte gloed en wat sterren.
struct NightBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.13),
                                    Color(red: 0.07, green: 0.08, blue: 0.20),
                                    Color(red: 0.05, green: 0.06, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 380)
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 7)
                for _ in 0..<70 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height * 0.6
                    let r = 0.4 + rng.next() * 1.1
                    ctx.opacity = 0.15 + rng.next() * 0.45
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
}

/// Het maan-logo, zoals het app-icoon.
struct MoonMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            var moon = Path()
            moon.addArc(center: CGPoint(x: 44 * s, y: 52 * s), radius: 30 * s,
                        startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            var bite = Path()
            bite.addArc(center: CGPoint(x: 58 * s, y: 40 * s), radius: 25 * s,
                        startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.fill(moon.subtracting(bite), with: .color(Theme.accent))
            for (i, r) in [10.0, 17.0].enumerated() {
                var wave = Path()
                wave.addArc(center: CGPoint(x: 62 * s, y: 38 * s), radius: r * s,
                            startAngle: .degrees(-75), endAngle: .degrees(5), clockwise: false)
                ctx.stroke(wave, with: .color(Theme.accent.opacity(i == 0 ? 1 : 0.55)),
                           style: StrokeStyle(lineWidth: 4.5 * s, lineCap: .round))
            }
        }
        .shadow(color: Theme.accent.opacity(0.45), radius: 14)
        .accessibilityHidden(true)
    }
}

/// Glazen kaart.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08)))
    }
}

struct Chip: View {
    let label: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark" : symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.night : Theme.accent.opacity(0.9))
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
                Text(label).font(.subheadline.weight(.medium))
                    .foregroundStyle(isOn ? Theme.night : .primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isOn { Capsule().fill(Theme.accent) }
                else { Capsule().fill(.white.opacity(0.06)) }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0 : 0.10)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Eenvoudige flow-layout: elementen lopen door naar de volgende regel.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Kaarten

struct LastNightCard: View {
    let session: SleepSession
    var body: some View {
        GlassCard {
            HStack(spacing: 18) {
                ScoreRing(score: session.snoreScore).frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VORIGE NACHT · \(session.nightTitle.uppercased())").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text("\(SnoreAnalysis.scoreLabel(session.snoreScore)) gesnurkt")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("Snurkscore \(session.snoreScore) · hoe lager, hoe beter").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Label("\(Int(session.snoreMinutes)) min (\(Int(session.snorePercentage * 100))%)", systemImage: "waveform")
                        Label(String(format: "%.1f u", session.sleepDuration / 3600), systemImage: "bed.double.fill")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ScoreRing: View {
    let score: Int
    var body: some View {
        let p = min(1, Double(score) / 80)
        let color: Color = p < 0.15 ? .green : p < 0.35 ? .yellow : p < 0.6 ? .orange : .red
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 7)
            Circle().trim(from: 0, to: max(p, 0.02))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
        }
    }
}

/// Compacte status van de watch; tikken opent kalibratie wanneer nodig.
struct WatchStatusPill: View {
    @EnvironmentObject var hub: WearableHub
    @Binding var showCalibration: Bool

    var body: some View {
        let connected = !hub.active.isEmpty
        let needsCalibration = hub.hasPositionSource && !hub.profile.isComplete
        Button {
            if needsCalibration { showCalibration = true }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(connected ? Theme.accent.opacity(0.18) : .white.opacity(0.06))
                    Image(systemName: connected ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                        .font(.callout)
                        .foregroundStyle(connected ? Theme.accent : .secondary)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connected ? hub.active.map(\.name).joined(separator: " + ") : "Geen watch verbonden")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle(connected: connected, needsCalibration: needsCalibration))
                        .font(.caption).foregroundStyle(needsCalibration ? Theme.accent : .secondary)
                }
                Spacer()
                if let b = hub.watchStatus?.batteryLevel, b >= 0 {
                    Label("\(Int(b * 100))%", systemImage: b < 0.3 ? "battery.25percent" : "battery.75percent")
                        .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
                        .foregroundStyle(b < 0.3 ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func subtitle(connected: Bool, needsCalibration: Bool) -> String {
        if !connected { return hub.watchHint.map { "\($0) · nu alleen geluid" } ?? "Alleen geluid wordt gemeten" }
        if needsCalibration { return "Tik om je slaaphoudingen te kalibreren" }
        if hub.profile.missesStomachSides { return "Nieuw: 2 buikhoudingen — kalibreer opnieuw (Instellingen)" }
        return "Houding, hartslag en tikjes actief"
    }
}
