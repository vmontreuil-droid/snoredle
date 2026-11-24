import SwiftUI

/// 4-7-8-ademhaling om in te slapen: 4 s in, 7 s vasthouden, 8 s uit, 4 keer.
struct BreathingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase = 0          // 0 in, 1 vast, 2 uit
    @State private var cycle = 1
    @State private var remaining = 4
    @State private var running = false
    @State private var scale: CGFloat = 0.55
    private let durations = [4, 7, 8]
    private let labels = ["Adem in", "Houd vast", "Adem uit"]
    private let cycles = 4

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 30) {
                Text("Ademhaling 4-7-8").font(.system(.title2, design: .rounded).weight(.semibold))
                Text(running ? "Ronde \(cycle) van \(cycles)" : "Ga comfortabel liggen. Adem door je neus in, door je mond uit.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.12)).frame(width: 260, height: 260)
                    Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.25)],
                                                 center: .center, startRadius: 5, endRadius: 140))
                        .frame(width: 260, height: 260).scaleEffect(scale)
                    VStack(spacing: 4) {
                        Text(running ? labels[phase] : "Klaar?").font(.title3.weight(.semibold))
                        if running { Text("\(remaining)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit() }
                    }
                    .foregroundStyle(Theme.night)
                }
                Button(running ? "Stop" : "Begin") { running ? stop() : start() }
                    .font(.headline).foregroundStyle(Theme.night)
                    .frame(width: 180, height: 52).background(Theme.accent, in: Capsule())
                Button("Sluiten") { stop(); dismiss() }.foregroundStyle(.secondary)
            }
            .padding(28)
            .foregroundStyle(.white)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: phase)
    }

    private func start() {
        running = true; cycle = 1
        Task { await loop() }
    }
    private func stop() { running = false; withAnimation(.easeInOut(duration: 1)) { scale = 0.55 } }

    @MainActor private func loop() async {
        while running && cycle <= cycles {
            for p in 0..<3 {
                guard running else { return }
                phase = p
                remaining = durations[p]
                withAnimation(.easeInOut(duration: Double(durations[p]))) {
                    scale = p == 0 ? 1.0 : (p == 1 ? 1.0 : 0.55)
                }
                while remaining > 0 && running {
                    try? await Task.sleep(for: .seconds(1))
                    remaining -= 1
                }
            }
            cycle += 1
        }
        running = false
    }
}
