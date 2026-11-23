import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \SleepSession.start, order: .reverse) private var sessions: [SleepSession]
    @EnvironmentObject var store: StoreManager
    @Environment(\.modelContext) private var context

    var visible: [SleepSession] {
        let done = sessions.filter { $0.end != nil }
        if store.isPlus { return done }
        let limit = Date().addingTimeInterval(-7 * 86_400)
        return done.filter { $0.start > limit }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visible) { s in
                    NavigationLink { SessionDetailView(session: s) } label: {
                        HStack(spacing: 14) {
                            ScoreRing(score: s.snoreScore).frame(width: 44, height: 44).font(.caption)
                            VStack(alignment: .leading) {
                                Text(s.nightTitle).font(.headline)
                                Text("\(Int(s.snoreMinutes)) min snurken · \(String(format: "%.1f", s.duration / 3600)) u · \(s.factors.map(\.emoji).joined())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let r = s.rating { Text(["😫", "🙁", "😐", "🙂", "😄"][r - 1]) }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        let s = visible[i]
                        s.events.compactMap(\.clipFileName).forEach {
                            try? FileManager.default.removeItem(at: ClipRecorder.url(for: $0))
                        }
                        context.delete(s)
                    }
                }
                if !store.isPlus, sessions.count > visible.count {
                    NavigationLink("Oudere nachten bekijken met Snoredle Plus") { PaywallView() }
                }
            }
            .overlay { if visible.isEmpty { ContentUnavailableView("Nog geen nachten", systemImage: "moon.zzz", description: Text("Start je eerste meting op het tabblad Vannacht.")) } }
            .navigationTitle("Nachten")
        }
    }
}

struct TrendsView: View {
    @Query(sort: \SleepSession.start) private var sessions: [SleepSession]
    @EnvironmentObject var store: StoreManager
    @State private var range = 30
    @State private var reportURL: URL?
    @State private var csvURL: URL?

    var done: [SleepSession] {
        let limit = Date().addingTimeInterval(-Double(range) * 86_400)
        return sessions.filter { $0.end != nil && $0.start > limit }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Periode", selection: $range) {
                        Text("7 d").tag(7); Text("30 d").tag(30); Text("90 d").tag(90); Text("Alles").tag(36500)
                    }.pickerStyle(.segmented)

                    box("Snurkscore") {
                        Chart(done) { s in
                            BarMark(x: .value("Nacht", s.start, unit: .day), y: .value("Score", s.snoreScore))
                                .foregroundStyle(s.snoreScore < 10 ? .green : s.snoreScore < 25 ? .yellow : s.snoreScore < 50 ? .orange : .red)
                        }.frame(height: 180)
                        let avg = done.isEmpty ? 0 : done.map(\.snoreScore).reduce(0, +) / done.count
                        Text("Gemiddeld \(avg) · \(done.count) nachten").font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        NavigationLink { CoachView() } label: {
                            toolRow("Coach", "Persoonlijke tips en het 14-dagenprogramma", "figure.mind.and.body")
                        }
                        NavigationLink { CompareView() } label: {
                            toolRow("Nachten vergelijken", "Twee nachten naast elkaar", "rectangle.split.2x1")
                        }
                        NavigationLink { ApneaCheckView() } label: {
                            toolRow("Slaapapneu-check", ApneaCheckView.savedScore.map { "Score \($0)/8 · \(ApneaCheckView.result(score: $0).0)" } ?? "Korte vragenlijst (STOP-BANG)", "stethoscope")
                        }
                    }
                    .buttonStyle(.plain)

                    box("Uitdagingen") {
                        let streak = Achievements.streak(sessions.filter { $0.end != nil })
                        HStack(spacing: 10) {
                            Image(systemName: "flame.fill").font(.title2).foregroundStyle(streak > 0 ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(streak) \(streak == 1 ? "nacht" : "nachten") op rij").font(.headline)
                                Text("Meet elke nacht om je reeks te houden").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                            ForEach(Achievements.badges(sessions)) { b in
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle().stroke(.white.opacity(0.08), lineWidth: 4)
                                        Circle().trim(from: 0, to: b.progress)
                                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                        Image(systemName: b.symbol).font(.title3)
                                            .foregroundStyle(b.done ? Theme.accent : .secondary)
                                    }
                                    .frame(width: 56, height: 56)
                                    .opacity(b.done ? 1 : 0.75)
                                    Text(b.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                                    Text(b.detail).font(.caption2).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center).lineLimit(2)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    box("Wat beïnvloedt je snurken?") {
                        if store.isPlus {
                            let ins = SnoreAnalysis.insights(done)
                            if ins.isEmpty {
                                Text("Meet minstens 4 nachten en vul factoren in. Dan zie je hier wat helpt.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(ins) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i.title).font(.subheadline.bold())
                                    Text(i.detail).font(.caption).foregroundStyle(i.effect > 0 ? .orange : .green)
                                }
                            }
                        } else {
                            NavigationLink("Ontgrendel inzichten met Snoredle Plus") { PaywallView() }
                        }
                    }

                    box("Delen en exporteren") {
                        HStack {
                            if store.isPlus {
                                if let pdf = reportURL {
                                    ShareLink(item: pdf) { Label("Rapport voor arts (PDF)", systemImage: "doc.richtext") }
                                } else { ProgressView() }
                                Spacer()
                                if let csv = csvURL { ShareLink(item: csv) { Label("CSV", systemImage: "tablecells") } }
                            } else {
                                NavigationLink("Export met Snoredle Plus") { PaywallView() }
                            }
                        }.font(.subheadline)
                    }
                }.padding()
            }
            .background(NightBackground())
            .navigationTitle("Inzichten")
            .task(id: "\(range)-\(done.count)") {
                reportURL = ExportService.pdf(done)
                csvURL = ExportService.csv(done)
            }
        }
    }

    private func toolRow(_ t: String, _ s: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.subheadline.weight(.semibold))
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func box<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(t).font(.headline); c() }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
