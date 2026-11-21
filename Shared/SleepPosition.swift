import Foundation

/// Slaaphouding zoals bepaald door een wearable (Apple Watch, later Wear OS, Garmin…).
public enum SleepPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case back      // rug
    case left      // linkerzij
    case right     // rechterzij
    case stomach   // buik
    case upright   // rechtop / wakker
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .back: return "Rug"
        case .left: return "Linkerzij"
        case .right: return "Rechterzij"
        case .stomach: return "Buik"
        case .upright: return "Rechtop"
        case .unknown: return "Onbekend"
        }
    }

    public var symbol: String {
        switch self {
        case .back: return "figure.mind.and.body"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .stomach: return "bed.double"
        case .upright: return "figure.stand"
        case .unknown: return "questionmark"
        }
    }

    /// Posities die je kalibreert bij de eerste nacht.
    public static let calibratable: [SleepPosition] = [.back, .left, .right, .stomach]
}

/// Eenvoudige 3D-vector (zwaartekracht) die op beide platformen bestaat.
public struct Vector3: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vector3 {
        let l = max(length, 1e-9)
        return Vector3(x: x / l, y: y / l, z: z / l)
    }
    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    /// Hoek in graden tussen twee vectoren.
    public func angle(to o: Vector3) -> Double {
        let c = min(1, max(-1, normalized.dot(o.normalized)))
        return acos(c) * 180 / .pi
    }
}
