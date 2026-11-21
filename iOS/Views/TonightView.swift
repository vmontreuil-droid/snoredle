import SwiftUI
import SwiftData

/// Startscherm: factoren/middelen aanvinken en de nacht starten.
struct TonightView: View {
    @EnvironmentObject var manager: SessionManager
    @EnvironmentObject var hub: WearableHub
    @EnvironmentObject var settings: AppSettings
    @Query(sort: \SleepSession.start, order: .reverse) private var sessions: [SleepSession]

    @AppStorage("lastFactors") private var lastFactorsRaw = ""
    @AppStorage("lastRemedies") private var lastRemediesRaw = ""
    @State private var factors: Set<SleepFactor> = []
    @State private var remedies: Set<Remedy> = []
    @State private var showCalibration = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let last = sessions.first(where: { $0.end != nil }) {
                        NavigationLink { SessionDetailView(session: last) } label: { LastNightCard(session: last) }
                            .buttonStyle(.plain)
                    }

                    WearableCard(showCalibration: $showCalibration)

                    section("Vandaag") {
                        ChipGrid(items: SleepFactor.allCases, selected: $factors) { "\($0.emoji) \($0.label)" }
                    }
                    section("Ik probeer vannacht") {
                        ChipGrid(items: Remedy.allCases, selected: $remedies) { $0.label }
                    }

                    Button {
                        lastRemediesRaw = remedies.map(\.rawValue).joined(separator: ",")
                        manager.start(factors: Array(factors), remedies: Array(remedies))
                    } label: {
                        Label("Start de nacht", systemImage: "moon.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    if let err = manager.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    Text("Tip: leg je telefoon met het scherm naar beneden op het nachtkastje, aan de lader, binnen 1 m van je hoofd.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Theme.night.ignoresSafeArea())
            .navigationTitle("Vannacht")
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .onAppear {
                // Middelen onthouden (die gebruik je vaak meerdere nachten).
                remedies = Set(lastRemediesRaw.split(separator: ",").compactMap { Remedy(rawValue: String($0)) })
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct LastNightCard: View {
    let session: SleepSession
    var body: some View {
        HStack(spacing: 16) {
            ScoreRing(score: session.snoreScore).frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Vorige nacht").font(.caption).foregroundStyle(.secondary)
                Text(SnoreAnalysis.scoreLabel(session.snoreScore)).font(.title3.bold())
                Text("\(Int(session.snoreMinutes)) min snurken · \(String(format: "%.1f", session.duration / 3600)) u")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ScoreRing: View {
    let score: Int
    var body: some View {
        let p = min(1, Double(score) / 80)
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 8)
            Circle().trim(from: 0, to: p)
                .stroke(p < 0.15 ? .green : p < 0.35 ? .yellow : p < 0.6 ? .orange : .red,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.title2.bold().monospacedDigit())
        }
    }
}

struct WearableCard: View {
    @EnvironmentObject var hub: WearableHub
    @Binding var showCalibration: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "applewatch").foregroundStyle(Theme.accent)
                Text(hub.active.isEmpty ? "Geen watch verbonden" : hub.active.map(\.name).joined(separator: " + "))
                    .font(.headline)
                Spacer()
                if let b = hub.watchStatus?.batteryLevel, b >= 0 {
                    Label("\(Int(b * 100))%", systemImage: b < 0.3 ? "battery.25" : "battery.75")
                        .font(.caption).foregroundStyle(b < 0.3 ? .red : .secondary)
                }
            }
            if hub.hasPositionSource {
                if hub.profile.isComplete {
                    Text("Houding gekalibreerd ✓").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Button("Kalibreer je slaaphoudingen (1 min)") { showCalibration = true }.font(.subheadline)
                }
                if let b = hub.watchStatus?.batteryLevel, b >= 0, b < 0.3 {
                    Text("Laad je watch eerst op: een hele nacht meten kost ± 15–25%.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Zonder watch meet Snoredle alleen geluid. Open de Snoredle-app op je Apple Watch om houding te meten.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ChipGrid<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selected: Set<T>
    let label: (T) -> String
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let on = selected.contains(item)
                Button {
                    if on { selected.remove(item) } else { selected.insert(item) }
                } label: {
                    Text(label(item)).font(.subheadline).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? Theme.accent.opacity(0.25) : Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(on ? Theme.accent : .clear))
                }.buttonStyle(.plain)
            }
        }
    }
}
