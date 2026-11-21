import Foundation
import SwiftData

/// Eén nacht.
@Model
final class SleepSession {
    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date?
    var note: String
    var rating: Int?                        // ochtendgevoel 1…5
    var factorsRaw: [String]                // SleepFactor.rawValue
    var remediesRaw: [String]               // Remedy.rawValue
    var wearableName: String?

    // Berekende samenvatting (gevuld bij stoppen)
    var snoreScore: Int = 0
    var snoreMinutes: Double = 0
    var loudSnoreMinutes: Double = 0
    var epicSnoreMinutes: Double = 0
    var averageDecibel: Double = 0
    var peakDecibel: Double = 0
    var nudgeCount: Int = 0
    var possibleApneaEvents: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \SnoreEvent.session) var events: [SnoreEvent] = []
    @Relationship(deleteRule: .cascade, inverse: \LoudnessSample.session) var loudness: [LoudnessSample] = []
    @Relationship(deleteRule: .cascade, inverse: \PositionSample.session) var positions: [PositionSample] = []
    @Relationship(deleteRule: .cascade, inverse: \VitalSample.session) var vitals: [VitalSample] = []

    init(start: Date = .now) {
        self.id = UUID()
        self.start = start
        self.note = ""
        self.factorsRaw = []
        self.remediesRaw = []
    }

    var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
    var factors: [SleepFactor] { factorsRaw.compactMap(SleepFactor.init(rawValue:)) }
    var remedies: [Remedy] { remediesRaw.compactMap(Remedy.init(rawValue:)) }
    var snorePercentage: Double { duration > 0 ? min(1, snoreMinutes * 60 / duration) : 0 }
}

enum SnoreIntensity: Int, Codable, CaseIterable {
    case quiet = 0, light = 1, loud = 2, epic = 3
    var label: String { ["Stil", "Licht", "Luid", "Episch"][rawValue] }
}

/// Een aaneengesloten snurkepisode, met optioneel audiofragment.
@Model
final class SnoreEvent {
    var start: Date
    var end: Date
    var intensityRaw: Int
    var peakDecibel: Double
    var confidence: Double
    var positionRaw: String
    var clipFileName: String?               // in Documents/Clips
    var isFavorite: Bool = false
    var wasNudged: Bool = false
    var session: SleepSession?

    init(start: Date, end: Date, intensity: SnoreIntensity, peakDecibel: Double,
         confidence: Double, position: SleepPosition, clipFileName: String?) {
        self.start = start; self.end = end
        self.intensityRaw = intensity.rawValue
        self.peakDecibel = peakDecibel
        self.confidence = confidence
        self.positionRaw = position.rawValue
        self.clipFileName = clipFileName
    }
    var intensity: SnoreIntensity { SnoreIntensity(rawValue: intensityRaw) ?? .light }
    var position: SleepPosition { SleepPosition(rawValue: positionRaw) ?? .unknown }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Gemiddeld volume per minuut (voor de nachtgrafiek).
@Model
final class LoudnessSample {
    var at: Date
    var decibel: Double
    var snoreProbability: Double
    var session: SleepSession?
    init(at: Date, decibel: Double, snoreProbability: Double) {
        self.at = at; self.decibel = decibel; self.snoreProbability = snoreProbability
    }
}

@Model
final class PositionSample {
    var at: Date
    var positionRaw: String
    var confidence: Double
    var source: String                      // "Apple Watch", "Wear OS", "iPhone"…
    var session: SleepSession?
    init(at: Date, position: SleepPosition, confidence: Double, source: String) {
        self.at = at; self.positionRaw = position.rawValue; self.confidence = confidence; self.source = source
    }
    var position: SleepPosition { SleepPosition(rawValue: positionRaw) ?? .unknown }
}

enum VitalKind: String, Codable, CaseIterable {
    case heartRate, oxygenSaturation, respiratoryRate, movement
    var label: String {
        switch self {
        case .heartRate: "Hartslag"
        case .oxygenSaturation: "Zuurstof (SpO₂)"
        case .respiratoryRate: "Ademhaling"
        case .movement: "Beweging"
        }
    }
    var unit: String {
        switch self {
        case .heartRate: "bpm"
        case .oxygenSaturation: "%"
        case .respiratoryRate: "/min"
        case .movement: ""
        }
    }
}

@Model
final class VitalSample {
    var at: Date
    var kindRaw: String
    var value: Double
    var session: SleepSession?
    init(at: Date, kind: VitalKind, value: Double) {
        self.at = at; self.kindRaw = kind.rawValue; self.value = value
    }
    var kind: VitalKind { VitalKind(rawValue: kindRaw) ?? .heartRate }
}

/// Factoren die snurken kunnen beïnvloeden (in te vullen voor het slapengaan).
enum SleepFactor: String, CaseIterable, Identifiable, Codable {
    case alcohol, lateMeal, cold, allergy, tired, sleepingPill, smoking, caffeine,
         sport, stress, newPillow, sharedBed, menstruation, heatwave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alcohol: "Alcohol"
        case .lateMeal: "Laat gegeten"
        case .cold: "Verkouden"
        case .allergy: "Allergie / hooikoorts"
        case .tired: "Erg moe"
        case .sleepingPill: "Slaapmiddel"
        case .smoking: "Gerookt"
        case .caffeine: "Cafeïne"
        case .sport: "Gesport"
        case .stress: "Stress"
        case .newPillow: "Ander kussen"
        case .sharedBed: "Partner in bed"
        case .menstruation: "Menstruatie"
        case .heatwave: "Warme nacht"
        }
    }
    var symbol: String {
        switch self {
        case .alcohol: "wineglass.fill"
        case .lateMeal: "fork.knife"
        case .cold: "facemask.fill"
        case .allergy: "allergens.fill"
        case .tired: "battery.25percent"
        case .sleepingPill: "pills.fill"
        case .smoking: "smoke.fill"
        case .caffeine: "cup.and.saucer.fill"
        case .sport: "figure.run"
        case .stress: "brain.head.profile"
        case .newPillow: "bed.double.fill"
        case .sharedBed: "person.2.fill"
        case .menstruation: "drop.fill"
        case .heatwave: "thermometer.sun.fill"
        }
    }
    var emoji: String {
        switch self {
        case .alcohol: "🍷"; case .lateMeal: "🍝"; case .cold: "🤧"; case .allergy: "🌼"
        case .tired: "🥱"; case .sleepingPill: "💊"; case .smoking: "🚬"; case .caffeine: "☕️"
        case .sport: "🏃"; case .stress: "😣"; case .newPillow: "🛏️"; case .sharedBed: "👫"
        case .menstruation: "🩸"; case .heatwave: "🌡️"
        }
    }
}

/// Middeltjes die je uitprobeert (de app meet of ze werken).
enum Remedy: String, CaseIterable, Identifiable, Codable {
    case sideSleeping, watchNudge, nasalStrip, nasalSpray, mouthTape, mandibularDevice,
         chinStrap, raisedHead, cpap, throatExercises, noAlcohol, humidifier
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sideSleeping: "Op de zij slapen"
        case .watchNudge: "Tikje via watch"
        case .nasalStrip: "Neuspleister"
        case .nasalSpray: "Neusspray"
        case .mouthTape: "Mondtape"
        case .mandibularDevice: "Snurkbeugel (MRA)"
        case .chinStrap: "Kinband"
        case .raisedHead: "Hoofdeinde hoger"
        case .cpap: "CPAP"
        case .throatExercises: "Keeloefeningen"
        case .noAlcohol: "Geen alcohol"
        case .humidifier: "Luchtbevochtiger"
        }
    }
    var symbol: String {
        switch self {
        case .sideSleeping: "arrow.turn.up.right"
        case .watchNudge: "applewatch.radiowaves.left.and.right"
        case .nasalStrip: "bandage.fill"
        case .nasalSpray: "wind"
        case .mouthTape: "mouth.fill"
        case .mandibularDevice: "mouth"
        case .chinStrap: "face.smiling"
        case .raisedHead: "arrow.up.to.line"
        case .cpap: "lungs.fill"
        case .throatExercises: "music.mic"
        case .noAlcohol: "nosign"
        case .humidifier: "humidifier.fill"
        }
    }
}
