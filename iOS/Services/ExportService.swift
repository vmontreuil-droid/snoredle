import SwiftUI

/// Export voor eigen gebruik of voor de huisarts / NKO-arts / slaapkliniek.
@MainActor
enum ExportService {

    static func csv(_ sessions: [SleepSession]) -> URL {
        var rows = ["datum;start;einde;duur_u;score;snurk_min;luid_min;episch_min;gem_dB;piek_dB;tikjes;mogelijke_ademstops;rug_%;factoren;middelen;gevoel"]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let stats = SnoreAnalysis.positionStats(s)
            let total = stats.map(\.minutes).reduce(0, +)
            let back = total > 0 ? (stats.first { $0.position == .back }?.minutes ?? 0) / total * 100 : 0
            rows.append([
                df.string(from: s.start), tf.string(from: s.start), s.end.map(tf.string) ?? "",
                String(format: "%.1f", s.duration / 3600), "\(s.snoreScore)",
                String(format: "%.0f", s.snoreMinutes), String(format: "%.0f", s.loudSnoreMinutes),
                String(format: "%.0f", s.epicSnoreMinutes), String(format: "%.0f", s.averageDecibel),
                String(format: "%.0f", s.peakDecibel), "\(s.nudgeCount)", "\(s.possibleApneaEvents)",
                String(format: "%.0f", back),
                s.factors.map(\.label).joined(separator: ","), s.remedies.map(\.label).joined(separator: ","),
                s.rating.map(String.init) ?? "",
            ].joined(separator: ";"))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Snoredle-export.csv")
        try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pdf(_ sessions: [SleepSession]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Snoredle-rapport.pdf")
        let renderer = ImageRenderer(content: DoctorReportView(sessions: sessions).frame(width: 595))
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: CGSize(width: 595, height: max(842, size.height)))
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        return url
    }
}

/// Eén A4-overzicht voor een arts.
struct DoctorReportView: View {
    let sessions: [SleepSession]
    var done: [SleepSession] { sessions.filter { $0.end != nil }.sorted { $0.start < $1.start } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snurkrapport").font(.largeTitle.bold())
            if let f = done.first, let l = done.last {
                Text("\(f.start.formatted(date: .abbreviated, time: .omitted)) – \(l.start.formatted(date: .abbreviated, time: .omitted)) · \(done.count) nachten")
                    .foregroundStyle(.secondary)
            }
            let avg = done.isEmpty ? 0 : done.map(\.snoreScore).reduce(0, +) / done.count
            let snore = done.isEmpty ? 0 : done.map(\.snorePercentage).reduce(0, +) / Double(done.count)
            let apnea = done.map(\.possibleApneaEvents).reduce(0, +)
            HStack(spacing: 24) {
                stat("Gem. score", "\(avg)")
                stat("Snurktijd", "\(Int(snore * 100))%")
                stat("Mogelijke ademstops", "\(apnea)")
            }
            Divider()
            ForEach(done) { s in
                HStack {
                    Text(s.start.formatted(date: .numeric, time: .omitted)).frame(width: 90, alignment: .leading)
                    Text(String(format: "%.1f u", s.duration / 3600)).frame(width: 50)
                    Text("score \(s.snoreScore)").frame(width: 70)
                    Text("\(Int(s.snoreMinutes)) min").frame(width: 60)
                    Text(s.factors.map(\.emoji).joined()).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
            Divider()
            Text("Snoredle is geen medisch hulpmiddel en stelt geen diagnose. 'Mogelijke ademstops' zijn stiltes van ≥10 s tijdens snurken, gemeten met de microfoon. Bespreek dit rapport met je arts; een slaaponderzoek (polysomnografie) is nodig voor een diagnose van slaapapneu.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(32)
        .background(.white)
        .foregroundStyle(.black)
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading) { Text(v).font(.title2.bold()); Text(t).font(.caption) }
    }
}
