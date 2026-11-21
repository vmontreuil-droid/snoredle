import Foundation
import Combine

/// Gemeenschappelijke interface voor elke wearable. Apple Watch is de eerste
/// implementatie; Wear OS (via eigen companion + backend-relay), Garmin (Connect IQ),
/// Bluetooth-hartslagsensoren en HealthKit-bronnen volgen hetzelfde contract.
protocol WearableProvider: AnyObject {
    var name: String { get }
    var capabilities: WearableCapabilities { get }
    var isAvailable: Bool { get }
    var events: AnyPublisher<WearableEvent, Never> { get }

    func startSession(id: UUID, settings: WatchSettings)
    func stopSession(id: UUID)
    func nudge(_ intensity: NudgeIntensity)
    func calibrate(_ position: SleepPosition)
    func send(profile: CalibrationProfile)
}

struct WearableCapabilities: OptionSet {
    let rawValue: Int
    static let position   = WearableCapabilities(rawValue: 1 << 0)
    static let heartRate  = WearableCapabilities(rawValue: 1 << 1)
    static let oxygen     = WearableCapabilities(rawValue: 1 << 2)
    static let movement   = WearableCapabilities(rawValue: 1 << 3)
    static let haptics    = WearableCapabilities(rawValue: 1 << 4)
    static let calibration = WearableCapabilities(rawValue: 1 << 5)
}

enum WearableEvent {
    case position(PositionSamplePayload)
    case vital(VitalKind, Double, Date)
    case calibrated(SleepPosition, Vector3)
    case status(WatchStatus)
}

/// Lege standaardimplementaties voor providers die iets niet kunnen.
extension WearableProvider {
    func nudge(_ intensity: NudgeIntensity) {}
    func calibrate(_ position: SleepPosition) {}
    func send(profile: CalibrationProfile) {}
}

/// Beheert alle gekoppelde wearables tegelijk en bundelt hun data.
@MainActor
final class WearableHub: ObservableObject {
    static let shared = WearableHub()

    @Published private(set) var providers: [WearableProvider] = []
    @Published var lastPosition: PositionSamplePayload?
    @Published var lastHeartRate: Double?
    @Published var watchStatus: WatchStatus?
    @Published var profile: CalibrationProfile = WearableHub.loadProfile()

    let events = PassthroughSubject<(String, WearableEvent), Never>()
    private var bag = Set<AnyCancellable>()

    func register(_ p: WearableProvider) {
        guard !providers.contains(where: { $0.name == p.name }) else { return }
        providers.append(p)
        p.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] e in self?.handle(e, from: p.name) }
            .store(in: &bag)
        if p.capabilities.contains(.calibration) { p.send(profile: profile) }
    }

    var active: [WearableProvider] { providers.filter(\.isAvailable) }
    var hasPositionSource: Bool { active.contains { $0.capabilities.contains(.position) } }
    var hasHaptics: Bool { active.contains { $0.capabilities.contains(.haptics) } }

    // Start/stop gaat naar álle providers: sommige (Bluetooth) worden pas beschikbaar na verbinden.
    func start(id: UUID, settings: WatchSettings) { providers.forEach { $0.startSession(id: id, settings: settings) } }
    func stop(id: UUID) { providers.forEach { $0.stopSession(id: id) } }
    func nudge(_ i: NudgeIntensity) { active.filter { $0.capabilities.contains(.haptics) }.forEach { $0.nudge(i) } }
    func calibrate(_ pos: SleepPosition) { active.forEach { $0.calibrate(pos) } }

    private func handle(_ e: WearableEvent, from source: String) {
        switch e {
        case .position(let p): lastPosition = p
        case .vital(.heartRate, let v, _): lastHeartRate = v
        case .calibrated(let pos, let g):
            profile.vectors[pos] = g
            Self.save(profile)
            active.forEach { $0.send(profile: profile) }
        case .status(let s): watchStatus = s
        default: break
        }
        events.send((source, e))
    }

    private static func loadProfile() -> CalibrationProfile {
        guard let d = UserDefaults.standard.data(forKey: "calibrationProfile"),
              let p = try? JSONDecoder.snoredle.decode(CalibrationProfile.self, from: d) else { return .init() }
        return p
    }
    private static func save(_ p: CalibrationProfile) {
        if let d = try? JSONEncoder.snoredle.encode(p) { UserDefaults.standard.set(d, forKey: "calibrationProfile") }
    }
    func resetCalibration() { profile = .init(); Self.save(profile); active.forEach { $0.send(profile: profile) } }
}
