import Foundation

/// Alle berichten tussen iPhone en watch. Eén Codable-enum houdt het protocol
/// platformonafhankelijk: een Wear OS- of Garmin-brug stuurt dezelfde JSON.
public enum WatchMessage: Codable, Sendable {
    /// iPhone → watch
    case startSession(sessionID: UUID, settings: WatchSettings)
    case stopSession(sessionID: UUID)
    case nudge(intensity: NudgeIntensity)            // tik bij snurken
    case startCalibration(position: SleepPosition)
    case calibrationProfile(CalibrationProfile)
    case sessionState(recording: Bool, pausedUntil: Date?)
    case calibrationMode(Bool)                       // kalibreren via de iPhone: watch blijft actief

    /// watch → iPhone
    case positionSample(PositionSamplePayload)
    case heartRate(bpm: Double, at: Date)
    case movement(intensity: Double, at: Date)       // onrust / bewegen
    case calibrationCaptured(position: SleepPosition, gravity: Vector3)
    case watchStatus(WatchStatus)
    case request(WatchCommand)                       // bediening vanaf de watch
    case heartbeat(Heartbeat)                        // elke paar seconden; antwoord kan een tikje bevatten
    case nudgeDone(at: Date)                         // watch bevestigt dat er getikt is
    case log(String)                                 // regel voor het diagnoselogboek van de iPhone
    case alert(String)                               // iPhone → watch: belangrijke melding (trillen + tekst)

    public func encoded() throws -> Data { try JSONEncoder.snoredle.encode(self) }
    public static func decode(_ data: Data) throws -> WatchMessage {
        try JSONDecoder.snoredle.decode(WatchMessage.self, from: data)
    }
}

/// Periodiek seintje van de watch tijdens de nacht.
public struct Heartbeat: Codable, Sendable, Hashable {
    public var sample: PositionSamplePayload
    public var movement: Double
    public var heartRate: Double?
    public var steps: Int?                 // stappen sinds het vorige seintje
    public init(sample: PositionSamplePayload, movement: Double, heartRate: Double?, steps: Int? = nil) {
        self.sample = sample; self.movement = movement; self.heartRate = heartRate; self.steps = steps
    }
}

/// Wat je vanaf de watch kan bedienen.
public enum WatchCommand: Codable, Sendable, Hashable {
    case start, stop, resume
    case pause(minutes: Int)
}

public struct WatchSettings: Codable, Sendable, Hashable {
    public var nudgeEnabled: Bool
    public var nudgeOnlyOnBack: Bool
    public var sampleIntervalSeconds: Double
    public init(nudgeEnabled: Bool = true, nudgeOnlyOnBack: Bool = true, sampleIntervalSeconds: Double = 10) {
        self.nudgeEnabled = nudgeEnabled
        self.nudgeOnlyOnBack = nudgeOnlyOnBack
        self.sampleIntervalSeconds = sampleIntervalSeconds
    }
}

public enum NudgeIntensity: String, Codable, CaseIterable, Sendable {
    case gentle, medium, strong
    public var label: String {
        switch self { case .gentle: "Zacht"; case .medium: "Normaal"; case .strong: "Sterk" }
    }
}

public struct PositionSamplePayload: Codable, Sendable, Hashable {
    public var position: SleepPosition
    public var confidence: Double          // 0…1
    public var gravity: Vector3
    public var at: Date
    public init(position: SleepPosition, confidence: Double, gravity: Vector3, at: Date) {
        self.position = position; self.confidence = confidence; self.gravity = gravity; self.at = at
    }
}

public struct WatchStatus: Codable, Sendable, Hashable {
    public var isTracking: Bool
    public var batteryLevel: Double
    public var isCalibrated: Bool
    public init(isTracking: Bool, batteryLevel: Double, isCalibrated: Bool) {
        self.isTracking = isTracking; self.batteryLevel = batteryLevel; self.isCalibrated = isCalibrated
    }
}

/// Zwaartekrachtvector per houding, gemeten tijdens kalibratie.
/// Wordt op de iPhone bewaard en naar de watch gesynchroniseerd.
public struct CalibrationProfile: Codable, Sendable, Hashable {
    public var vectors: [SleepPosition: Vector3]
    public init(vectors: [SleepPosition: Vector3] = [:]) { self.vectors = vectors }
    /// Volledig: rug, links, rechts en buik (oude kalibratie) of beide nieuwe buikhoudingen.
    public var isComplete: Bool {
        [SleepPosition.back, .left, .right].allSatisfy { vectors[$0] != nil }
            && (vectors[.stomach] != nil || (vectors[.stomachLeft] != nil && vectors[.stomachRight] != nil))
    }
    /// Oude kalibratie zonder de twee buikhoudingen met kant.
    public var missesStomachSides: Bool { vectors[.stomachLeft] == nil || vectors[.stomachRight] == nil }

    /// Standaardprofiel (pols, wijzerplaat naar boven bij rugligging) als er nog niet gekalibreerd is.
    public static let `default` = CalibrationProfile(vectors: [
        .back:    Vector3(x: 0, y: 0, z: -1),
        .stomach: Vector3(x: 0, y: 0, z: 1),
        .left:    Vector3(x: 1, y: 0, z: 0),
        .right:   Vector3(x: -1, y: 0, z: 0),
    ])

    /// Nearest-neighbour classificatie op basis van hoekafstand.
    public func classify(_ gravity: Vector3) -> (SleepPosition, Double) {
        // Arm verticaal (zwaartekracht langs y) → waarschijnlijk rechtop/wakker.
        if abs(gravity.normalized.y) > 0.85 { return (.upright, abs(gravity.normalized.y)) }
        // Gedeeltelijk gekalibreerd: eigen houdingen gebruiken, de rest aanvullen met standaardwaarden.
        let source = isComplete ? vectors : CalibrationProfile.default.vectors.merging(vectors) { _, own in own }
        let ranked = source.map { ($0.key, gravity.angle(to: $0.value)) }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return (.unknown, 0) }
        let second = ranked.dropFirst().first?.1 ?? 180
        // Vertrouwen: hoe groter het verschil met de tweede kandidaat, hoe zekerder.
        let confidence = min(1, max(0, (second - best.1) / 90)) * max(0, 1 - best.1 / 120)
        return best.1 > 75 ? (.unknown, confidence) : (best.0, confidence)
    }
}

extension JSONEncoder {
    public static let snoredle: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
extension JSONDecoder {
    public static let snoredle: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
