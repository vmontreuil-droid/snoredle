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
                                Text(s.start.formatted(.dateTime.weekday(.wide).day().month())).font(.headline)
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
    @State private var exportURL: URL?

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
                                ShareLink(item: ExportService.pdf(done)) { Label("Rapport voor arts (PDF)", systemImage: "doc.richtext") }
                                Spacer()
                                ShareLink(item: ExportService.csv(done)) { Label("CSV", systemImage: "tablecells") }
                            } else {
                                NavigationLink("Export met Snoredle Plus") { PaywallView() }
                            }
                        }.font(.subheadline)
                    }
                }.padding()
            }
            .background(NightBackground())
            .navigationTitle("Inzichten")
        }
    }

    private func box<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(t).font(.headline); c() }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
