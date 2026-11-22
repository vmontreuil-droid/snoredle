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
        read.insert(HKQuantityType(.dietaryCaffeine))
        read.insert(HKQuantityType(.numberOfAlcoholicBeverages))
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

    func stages(from start: Date, to end: Date) async -> [(SleepStage, Date, Date)] {
        await sleepStages(from: start, to: end).compactMap { v, iv in
            let st: SleepStage
            switch v {
            case .awake: st = .awake
            case .asleepREM: st = .rem
            case .asleepCore: st = .core
            case .asleepDeep: st = .deep
            case .inBed: st = .inBed
            case .asleepUnspecified: st = .asleep
            @unknown default: return nil
            }
            return (st, iv.start, iv.end)
        }
    }

    /// Factoren die je vandaag in Gezondheid registreerde (cafeïne na 14 u, alcohol).
    func factorsToday() async -> [SleepFactor] {
        guard isAvailable else { return [] }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: .now)
        let afternoon = cal.date(bySettingHour: 14, minute: 0, second: 0, of: .now) ?? dayStart
        var out: [SleepFactor] = []
        if await sum(.dietaryCaffeine, unit: .gramUnit(with: .milli), from: afternoon) > 40 { out.append(.caffeine) }
        if await sum(.numberOfAlcoholicBeverages, unit: .count(), from: dayStart) >= 1 { out.append(.alcohol) }
        return out
    }

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date) async -> Double {
        let type = HKQuantityType(id)
        let pred = HKQuery.predicateForSamples(withStart: from, end: .now)
        let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: pred), options: .cumulativeSum)
        return (try? await d.result(for: store))?.sumQuantity()?.doubleValue(for: unit) ?? 0
    }

    /// Schrijft de nacht als "in bed" naar Gezondheid.
    func saveSleep(start: Date, end: Date) async {
        guard isAvailable, end.timeIntervalSince(start) > 1800 else { return }
        let sample = HKCategorySample(type: HKCategoryType(.sleepAnalysis),
                                      value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                      start: start, end: end,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try? await store.save(sample)
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
