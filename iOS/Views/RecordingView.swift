import SwiftUI

/// Nachtscherm: donker, groot uur, live meter. Stoppen = lang indrukken.
struct RecordingView: View {
    @EnvironmentObject var manager: SessionManager
    @EnvironmentObject var hub: WearableHub
    @State private var dimmed = false
    @State private var stopProgress = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 28) {
                Spacer()
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 84, weight: .thin, design: .rounded)).monospacedDigit()

                switch manager.state {
                case .waiting(let until):
                    Text("Start met meten om \(until.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                case .finishing:
                    ProgressView("Nacht analyseren…")
                default:
                    if let s = manager.current {
                        Text("Bezig sinds \(s.start.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }

                if !dimmed { liveMeters }
                Spacer()

                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 4)
                    Circle().trim(from: 0, to: stopProgress).stroke(Theme.accent, lineWidth: 4).rotationEffect(.degrees(-90))
                    Text("Houd ingedrukt\nom te stoppen").font(.caption).multilineTextAlignment(.center)
                }
                .frame(width: 110, height: 110)
                .onLongPressGesture(minimumDuration: 1.5, pressing: { pressing in
                    withAnimation(.linear(duration: pressing ? 1.5 : 0.2)) { stopProgress = pressing ? 1 : 0 }
                }) {
                    Task { await manager.stop() }
                }
                .opacity(dimmed ? 0.3 : 1)
                Spacer().frame(height: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(dimmed ? Color(white: 0.35) : .white)
            .background(Color.black.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { dimmed.toggle() }
        }
        .statusBarHidden()
        .task { try? await Task.sleep(for: .seconds(30)); dimmed = true }
    }

    private var liveMeters: some View {
        VStack(spacing: 16) {
            HStack(spacing: 28) {
                meter("Volume", "\(Int(manager.liveDecibel)) dB", icon: "waveform")
                meter("Episodes", "\(manager.eventCount)", icon: "zzz")
                if let p = hub.lastPosition {
                    meter("Houding", p.position.label, icon: p.position.symbol)
                }
                if let hr = hub.lastHeartRate {
                    meter("Hartslag", "\(Int(hr))", icon: "heart.fill")
                }
            }
            if manager.isSnoring {
                Label("Snurken gedetecteerd", systemImage: "waveform.path")
                    .foregroundStyle(Theme.accent).transition(.opacity)
            }
        }
    }

    private func meter(_ title: String, _ value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
