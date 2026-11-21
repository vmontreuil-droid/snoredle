import WidgetKit
import SwiftUI
import ActivityKit

private let amber = Color(red: 1.0, green: 0.72, blue: 0.35)
private let night = Color(red: 0.05, green: 0.07, blue: 0.16)

@main
struct SnoredleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScoreWidget()
        SnoreLiveActivity()
    }
}

// MARK: - Score-widget (beginscherm + vergrendelscherm)

struct ScoreEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?
}

struct ScoreProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScoreEntry { ScoreEntry(date: .now, summary: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (ScoreEntry) -> Void) {
        completion(ScoreEntry(date: .now, summary: WidgetSummary.load() ?? .placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoreEntry>) -> Void) {
        let entry = ScoreEntry(date: .now, summary: WidgetSummary.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3 * 3600))))
    }
}

struct ScoreWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SnoredleScore", provider: ScoreProvider()) { entry in
            ScoreWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.20), night],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Snurkscore")
        .description("Je score van vorige nacht en je week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ScoreWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ScoreEntry

    var body: some View {
        if let s = entry.summary {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(min(s.score, 80)), in: 0...80) {
                    Image(systemName: "moon.zzz.fill")
                } currentValueLabel: { Text("\(s.score)") }
                .gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Snoredle", systemImage: "moon.zzz.fill").font(.caption2.weight(.semibold))
                    Text("Score \(s.score) · \(s.label)").font(.headline)
                    Text("\(s.snoreMinutes) min snurken").font(.caption2)
                }
            case .accessoryInline:
                Label("Snurkscore \(s.score) · \(s.label)", systemImage: "moon.zzz.fill")
            case .systemMedium:
                HStack(spacing: 16) {
                    scoreRing(s).frame(width: 88, height: 88)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("VORIGE NACHT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(s.label).font(.title3.weight(.bold))
                        Text("\(s.snoreMinutes) min · \(String(format: "%.1f", s.hours)) u").font(.caption).foregroundStyle(.secondary)
                        weekBars(s).frame(height: 28)
                        if s.streak > 1 {
                            Label("\(s.streak) nachten op rij", systemImage: "flame.fill").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(amber)
                        Spacer()
                        if s.streak > 1 { Label("\(s.streak)", systemImage: "flame.fill").font(.caption2).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Text("\(s.score)").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(amber)
                    Text("\(s.snoreMinutes) min snurken").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill").font(.title).foregroundStyle(amber)
                Text("Start je eerste nacht").font(.caption).multilineTextAlignment(.center).foregroundStyle(.white)
            }
        }
    }

    private func scoreRing(_ s: WidgetSummary) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 8)
            Circle().trim(from: 0, to: max(0.02, min(1, Double(s.score) / 80)))
                .stroke(amber, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(s.score)").font(.system(size: 28, weight: .bold, design: .rounded))
        }
    }

    private func weekBars(_ s: WidgetSummary) -> some View {
        let maxV = max(1, s.weekScores.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(s.weekScores.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == s.weekScores.count - 1 ? amber : .white.opacity(0.35))
                    .frame(width: 8, height: max(3, 28 * CGFloat(v) / CGFloat(maxV)))
            }
        }
    }
}

// MARK: - Live Activity (vergrendelscherm, Dynamic Island, StandBy)

struct SnoreLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SnoreActivityAttributes.self) { ctx in
            LockScreenView(ctx: ctx)
                .activityBackgroundTint(night.opacity(0.85))
                .activitySystemActionForegroundColor(amber)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(ctx.attributes.start, style: .timer).monospacedDigit()
                    } icon: { Image(systemName: "moon.zzz.fill").foregroundStyle(amber) }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let a = ctx.state.alarm {
                        Label(a.formatted(date: .omitted, time: .shortened), systemImage: "alarm.fill")
                            .font(.headline).foregroundStyle(amber)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        stat("\(ctx.state.snoreEvents)", "snurken", "waveform")
                        stat(ctx.state.position, "houding", "figure.mind.and.body")
                        stat("\(ctx.state.nightSounds)", "geluiden", "bubble.left.fill")
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.state.isSnoring ? "waveform" : "moon.zzz.fill")
                    .foregroundStyle(amber)
            } compactTrailing: {
                Text("\(ctx.state.snoreEvents)").monospacedDigit().foregroundStyle(amber)
            } minimal: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(amber)
            }
            .keylineTint(amber)
        }
    }

    private func stat(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(amber)
            Text(v).font(.headline).lineLimit(1)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct LockScreenView: View {
    let ctx: ActivityViewContext<SnoreActivityAttributes>
    var body: some View {
        if let score = ctx.state.finishedScore {
            HStack {
                Image(systemName: "sun.horizon.fill").font(.title).foregroundStyle(amber)
                VStack(alignment: .leading) {
                    Text("Goedemorgen").font(.headline)
                    Text("Snurkscore \(score) — tik voor je nachtrapport").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .foregroundStyle(.white)
        } else {
            HStack(spacing: 14) {
                Image(systemName: ctx.state.isSnoring ? "waveform" : "moon.zzz.fill")
                    .font(.title2).foregroundStyle(amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snoredle luistert").font(.headline)
                    HStack(spacing: 4) {
                        Text("sinds")
                        Text(ctx.attributes.start, style: .time)
                        Text("·")
                        Text(ctx.attributes.start, style: .timer).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(ctx.state.snoreEvents) ×").font(.title3.weight(.bold)).foregroundStyle(amber)
                    if let a = ctx.state.alarm {
                        Label(a.formatted(date: .omitted, time: .shortened), systemImage: "alarm.fill").font(.caption)
                    }
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
    }
}
