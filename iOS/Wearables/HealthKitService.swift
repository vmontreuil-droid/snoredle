import Foundation
import HealthKit

/// Leest nachtelijke metingen uit Apple Gezondheid. Zo werkt Snoredle ook met watches
/// en ringen die naar Gezondheid synchroniseren (Garmin, Withings, Oura, Polar,
/// Ultrahuman, Amazfit/Zepp…), zonder eigen integratie.
final class HealthKitService {
    static let shared = HealthKitService()
    private let store = HKHealthStore()

    private let types: [VitalKind: HKQuantityTypeIdentifier] = [
        .heartRate: .heartRate,
        .oxygenSaturation: .oxygenSaturation,
        .respiratoryRate: .respiratoryRate,
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        var read = Set<HKObjectType>(types.values.compactMap { HKQuantityType.quantityType(forIdentifier: $0) })
        read.insert(HKCategoryType(.sleepAnalysis))
        let share: Set<HKSampleType> = [HKCategoryType(.sleepAnalysis)]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    /// Haalt alle metingen tussen start en eind op, met de bron (welk toestel).
    func vitals(from start: Date, to end: Date) async -> [(VitalKind, Double, Date, String)] {
        var out: [(VitalKind, Double, Date, String)] = []
        for (kind, id) in types {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            let unit: HKUnit = switch kind {
                case .heartRate, .respiratoryRate: .count().unitDivided(by: .minute())
                case .oxygenSaturation: .percent()
                case .movement: .count()
            }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                     sortDescriptors: [SortDescriptor(\.startDate)])
            if let samples = try? await descriptor.result(for: store) {
                for s in samples {
                    var v = s.quantity.doubleValue(for: unit)
                    if kind == .oxygenSaturation { v *= 100 }
                    out.append((kind, v, s.startDate, s.sourceRevision.source.name))
                }
            }
        }
        return out
    }

    /// Slaapfasen van andere apps/watches (in bed, kern, diep, REM, wakker).
    func sleepStages(from start: Date, to end: Date) async -> [(HKCategoryValueSleepAnalysis, DateInterval)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        return samples.compactMap { s in
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return nil }
            return (v, DateInterval(start: s.startDate, end: s.endDate))
        }
    }
}
