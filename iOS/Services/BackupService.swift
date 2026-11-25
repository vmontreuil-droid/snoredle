import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Back-up van al je nachten als één bestand (bewaar in iCloud Drive / Bestanden) en terugzetten.
/// Opnames (geluid) zitten er niet in, alleen de metingen.
@MainActor
enum BackupService {

    struct Backup: Codable {
        var version = 1
        var created = Date()
        var sessions: [S]
    }
    struct S: Codable {
        var id: UUID; var start: Date; var end: Date?; var note: String; var rating: Int?
        var factors: [String]; var remedies: [String]; var pauses: [Double]
        var events: [E]; var loudness: [L]; var positions: [P]; var vitals: [V]; var sounds: [N]; var stages: [T]
        var outOfBed: [O]? = nil
        var apnea: Int? = nil; var wearable: String? = nil; var alarmNote: String? = nil
    }
    struct E: Codable { var start: Date; var end: Date; var intensity: Int; var peak: Double; var conf: Double; var pos: String; var nudged: Bool; var partner: Bool }
    struct L: Codable { var at: Date; var db: Double; var p: Double }
    struct P: Codable { var at: Date; var pos: String; var conf: Double; var src: String }
    struct V: Codable { var at: Date; var kind: String; var value: Double }
    struct N: Codable { var start: Date; var end: Date; var kind: String; var conf: Double; var transcript: String? }
    struct T: Codable { var start: Date; var end: Date; var stage: Int }
    struct O: Codable { var start: Date; var end: Date; var steps: Int; var alerted: Bool }

    static func export(context: ModelContext) throws -> URL {
        let all = try context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.start)]))
        let b = Backup(sessions: all.filter { $0.end != nil }.map { s in
            S(id: s.id, start: s.start, end: s.end, note: s.note, rating: s.rating,
              factors: s.factorsRaw, remedies: s.remediesRaw, pauses: s.pausesRaw,
              events: s.events.map { E(start: $0.start, end: $0.end, intensity: $0.intensityRaw, peak: $0.peakDecibel,
                                       conf: $0.confidence, pos: $0.positionRaw, nudged: $0.wasNudged, partner: $0.isPartner) },
              loudness: s.loudness.map { L(at: $0.at, db: $0.decibel, p: $0.snoreProbability) },
              positions: s.positions.map { P(at: $0.at, pos: $0.positionRaw, conf: $0.confidence, src: $0.source) },
              vitals: s.vitals.map { V(at: $0.at, kind: $0.kindRaw, value: $0.value) },
              sounds: s.nightSounds.map { N(start: $0.start, end: $0.end, kind: $0.kindRaw, conf: $0.confidence, transcript: $0.transcript) },
              stages: s.stages.map { T(start: $0.start, end: $0.end, stage: $0.stageRaw) },
              outOfBed: s.outOfBed.map { O(start: $0.start, end: $0.end, steps: $0.steps, alerted: $0.alerted) },
              apnea: s.possibleApneaEvents, wearable: s.wearableName, alarmNote: s.alarmNote)
        })
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let name = "Snoredle-backup-\(Date().formatted(.iso8601.year().month().day())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try enc.encode(b).write(to: url)
        return url
    }

    /// Zet nachten terug; nachten die al bestaan worden overgeslagen. Geeft het aantal terug.
    static func restore(from url: URL, context: ModelContext) throws -> Int {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let b = try dec.decode(Backup.self, from: Data(contentsOf: url))
        let existing = Set(try context.fetch(FetchDescriptor<SleepSession>()).map(\.id))
        var n = 0
        for x in b.sessions where !existing.contains(x.id) {
            let s = SleepSession(start: x.start)
            s.id = x.id; s.end = x.end; s.note = x.note; s.rating = x.rating
            s.factorsRaw = x.factors; s.remediesRaw = x.remedies; s.pausesRaw = x.pauses
            s.possibleApneaEvents = x.apnea ?? 0; s.wearableName = x.wearable; s.alarmNote = x.alarmNote
            s.healthSynced = true          // niet opnieuw naar Gezondheid schrijven
            context.insert(s)
            for e in x.events {
                let ev = SnoreEvent(start: e.start, end: e.end, intensity: SnoreIntensity(rawValue: e.intensity) ?? .light,
                                    peakDecibel: e.peak, confidence: e.conf,
                                    position: SleepPosition(rawValue: e.pos) ?? .unknown, clipFileName: nil)
                ev.wasNudged = e.nudged; ev.isPartner = e.partner
                s.events.append(ev)
            }
            s.loudness = x.loudness.map { LoudnessSample(at: $0.at, decibel: $0.db, snoreProbability: $0.p) }
            s.positions = x.positions.map { PositionSample(at: $0.at, position: SleepPosition(rawValue: $0.pos) ?? .unknown,
                                                           confidence: $0.conf, source: $0.src) }
            s.vitals = x.vitals.map { VitalSample(at: $0.at, kind: VitalKind(rawValue: $0.kind) ?? .heartRate, value: $0.value) }
            s.nightSounds = x.sounds.map {
                let n = NightSoundEvent(start: $0.start, end: $0.end, kind: NightSoundKind(rawValue: $0.kind) ?? .talking,
                                        confidence: $0.conf, clipFileName: nil)
                n.transcript = $0.transcript
                return n
            }
            s.stages = x.stages.map { SleepStageSample(start: $0.start, end: $0.end, stage: SleepStage(rawValue: $0.stage) ?? .asleep) }
            s.outOfBed = (x.outOfBed ?? []).map { OutOfBedEvent(start: $0.start, end: $0.end, steps: $0.steps, alerted: $0.alerted) }
            SnoreAnalysis.summarize(s)
            n += 1
        }
        try context.save()
        return n
    }
}

/// Instellingenonderdeel voor back-up.
struct BackupSection: View {
    @Environment(\.modelContext) private var context
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Section {
            Button {
                exportURL = try? BackupService.export(context: context)
            } label: { Label("Back-up maken", systemImage: "externaldrive.badge.icloud") }
            if let url = exportURL {
                ShareLink(item: url) { Label("Bewaar de back-up (bv. in iCloud Drive)", systemImage: "square.and.arrow.up") }
            }
            Button { importing = true } label: { Label("Back-up terugzetten", systemImage: "arrow.counterclockwise.icloud") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Back-up") } footer: {
            Text("Bewaar de back-up in iCloud Drive via 'Bewaar in Bestanden'. Zo ben je niets kwijt bij een nieuwe telefoon. Geluidsfragmenten zitten er niet in.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do { let n = try BackupService.restore(from: url, context: context); message = "\(n) nachten teruggezet." }
                catch { message = "Terugzetten mislukt: \(error.localizedDescription)" }
            case .failure(let e): message = e.localizedDescription
            }
        }
    }
}
