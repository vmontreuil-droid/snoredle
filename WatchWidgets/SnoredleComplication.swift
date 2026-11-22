import WidgetKit
import SwiftUI

/// Complicatie op de wijzerplaat: één tik opent Snoredle op je watch (start de nacht, pauze, kalibratie).
@main
struct SnoredleComplications: WidgetBundle {
    var body: some Widget { SnoredleComplication() }
}

struct ComplicationEntry: TimelineEntry { let date: Date }

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) { completion(.init(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now)], policy: .never))
    }
}

struct SnoredleComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SnoredleComplication", provider: ComplicationProvider()) { _ in
            ComplicationView().containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Snoredle")
        .description("Start je nacht met één tik.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) var family
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.35)

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "moon.zzz.fill").font(.title3).foregroundStyle(amber)
                .widgetLabel { Text("Snoredle") }
        case .accessoryInline:
            Label("Snoredle", systemImage: "moon.zzz.fill")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(amber)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Snoredle").font(.headline)
                    Text("Tik om de nacht te starten").font(.caption2).foregroundStyle(.secondary)
                }
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(amber)
            }
        }
    }
}
