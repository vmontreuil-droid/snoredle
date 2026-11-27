import XCTest
import SwiftData
import SwiftUI
@testable import Snoredle

/// Rendert het PDF-rapport met een voorbeeldnacht naar /tmp, zodat CI er afbeeldingen van kan maken.
@MainActor
final class ReportPreviewTests: XCTestCase {

    func testRenderNightReport() throws {
        let schema = Schema([SleepSession.self, SnoreEvent.self, LoudnessSample.self, PositionSample.self,
                             VitalSample.self, NightSoundEvent.self, SleepStageSample.self, OutOfBedEvent.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        var nights: [SleepSession] = []
        for n in 0..<6 {
            let s = Self.sampleNight(daysAgo: n, ctx: ctx)
            nights.append(s)
        }
        try ctx.save()
        let night = ReportPDF.night(nights[0])
        let overview = ReportPDF.overview(nights)
        let dir = URL(fileURLWithPath: "/tmp/snoredle-preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (u, name) in [(night, "nacht.pdf"), (overview, "periode.pdf")] {
            let dst = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: u, to: dst)
            let size = (try FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 5000, "\(name) is leeg")
        }
    }

    static func sampleNight(daysAgo: Int, ctx: ModelContext) -> SleepSession {
        var cal = Calendar.current; cal.timeZone = .current
        let day = cal.startOfDay(for: Date().addingTimeInterval(Double(-daysAgo) * 86_400))
        let start = day.addingTimeInterval(-2 * 3600 + Double(daysAgo * 600))       // ±22:00
        let end = start.addingTimeInterval(8 * 3600)
        let s = SleepSession(start: start)
        ctx.insert(s)
        s.end = end
        s.factorsRaw = daysAgo % 2 == 0 ? ["alcohol", "tired"] : ["sport"]
        s.remediesRaw = daysAgo % 3 == 0 ? ["nasalStrip", "watchNudge"] : ["watchNudge"]
        s.rating = 1 + daysAgo % 5
        s.note = daysAgo == 0 ? "Voorbeeldnacht voor het rapport." : ""
        s.alarmNote = "Slim gewekt om 05:52 (wekker 06:00)"
        s.wearableName = "Apple Watch"
        var rng = SystemRandomNumberGenerator()
        for m in 0..<(8 * 60) {
            let t = start.addingTimeInterval(Double(m) * 60)
            let snoring = (m / 25) % 3 == 1
            s.loudness.append(LoudnessSample(at: t, decibel: snoring ? Double.random(in: 30...55, using: &rng) : Double.random(in: 5...18, using: &rng), snoreProbability: snoring ? 0.8 : 0.05))
        }
        let posCycle: [SleepPosition] = [.back, .left, .stomachRight, .right, .back, .stomachLeft, .upright, .unknown]
        for i in 0..<(8 * 12) {
            let t = start.addingTimeInterval(Double(i) * 300)
            s.positions.append(PositionSample(at: t, position: posCycle[(i / 6) % posCycle.count], confidence: 0.9, source: "Apple Watch"))
        }
        for e in 0..<(30 - daysAgo * 3) {
            let t = start.addingTimeInterval(Double(e) * 900 + 120)
            let ev = SnoreEvent(start: t, end: t.addingTimeInterval(Double(20 + e * 7 % 140)), intensity: SnoreIntensity(rawValue: 1 + e % 3)!,
                                peakDecibel: Double(35 + e * 3 % 30), confidence: 0.8, position: posCycle[e % 5], clipFileName: nil)
            ev.wasNudged = e % 4 == 0
            s.events.append(ev)
        }
        for i in 0..<(8 * 60) {
            let t = start.addingTimeInterval(Double(i) * 60)
            s.vitals.append(VitalSample(at: t, kind: .heartRate, value: 58 + 10 * sin(Double(i) / 40) + Double.random(in: -3...3, using: &rng)))
            if i % 10 == 0 { s.vitals.append(VitalSample(at: t, kind: .oxygenSaturation, value: Double.random(in: 88...99, using: &rng))) }
            if i % 15 == 0 { s.vitals.append(VitalSample(at: t, kind: .respiratoryRate, value: Double.random(in: 12...17, using: &rng))) }
        }
        let cycle: [SleepStage] = [.core, .deep, .core, .rem, .awake]
        var t = start.addingTimeInterval(600)
        var k = 0
        while t < end {
            let len = Double([25, 40, 30, 20, 5][k % 5]) * 60
            s.stages.append(SleepStageSample(start: t, end: min(end, t + len), stage: cycle[k % 5]))
            t += len; k += 1
        }
        let talk = NightSoundEvent(start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(3 * 3600 + 6), kind: .talking, confidence: 0.8, clipFileName: nil)
        talk.transcript = "ik moet nog de sleutels halen"
        s.nightSounds.append(talk)
        s.nightSounds.append(NightSoundEvent(start: start.addingTimeInterval(5 * 3600), end: start.addingTimeInterval(5 * 3600 + 2), kind: .cough, confidence: 0.9, clipFileName: nil))
        s.outOfBed.append(OutOfBedEvent(start: start.addingTimeInterval(4 * 3600), end: start.addingTimeInterval(4 * 3600 + 300), steps: 42, alerted: false))
        s.pausesRaw = [start.addingTimeInterval(2 * 3600).timeIntervalSince1970, start.addingTimeInterval(2 * 3600 + 900).timeIntervalSince1970]
        SnoreAnalysis.summarize(s)
        return s
    }
}
