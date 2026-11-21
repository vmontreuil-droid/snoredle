import SwiftUI

/// Alle instelbare parameters op één plek.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Detectie
    @AppStorage("sensitivity") var sensitivity: Double = 0.5          // 0 = streng, 1 = gevoelig
    @AppStorage("calibrationOffset") var calibrationOffset: Double = 94
    @AppStorage("ignoreSpeech") var ignoreSpeech: Bool = true
    @AppStorage("startDelayMinutes") var startDelayMinutes: Int = 0     // pas na x min. beginnen
    @AppStorage("autoStopHour") var autoStopHour: Int = 9               // stop automatisch (0 = uit)

    // Opnames
    @AppStorage("saveClips") var saveClips: Bool = true
    @AppStorage("maxClipsPerNight") var maxClipsPerNight: Int = 40
    @AppStorage("keepClipsDays") var keepClipsDays: Int = 30

    // Watch / tikjes
    @AppStorage("nudgeEnabled") var nudgeEnabled: Bool = true
    @AppStorage("nudgeOnlyOnBack") var nudgeOnlyOnBack: Bool = true
    @AppStorage("nudgeIntensity") var nudgeIntensityRaw: String = NudgeIntensity.medium.rawValue
    @AppStorage("nudgeAfterSeconds") var nudgeAfterSeconds: Double = 20  // na x sec. aanhoudend snurken
    @AppStorage("nudgeCooldownMinutes") var nudgeCooldownMinutes: Double = 3
    @AppStorage("nudgeQuietFirstMinutes") var nudgeQuietFirstMinutes: Int = 20 // eerst inslapen
    @AppStorage("positionIntervalSeconds") var positionIntervalSeconds: Double = 10

    // Gezondheid
    @AppStorage("useHealthKit") var useHealthKit: Bool = true
    @AppStorage("useBluetoothHR") var useBluetoothHR: Bool = false
    @AppStorage("pauseDetection") var pauseDetection: Bool = true      // mogelijke ademstops markeren
    @AppStorage("pauseThresholdSeconds") var pauseThresholdSeconds: Double = 10

    // Algemeen
    @AppStorage("didOnboard") var didOnboard: Bool = false
    @AppStorage("bedtimeReminder") var bedtimeReminder: Bool = false
    @AppStorage("bedtimeMinutes") var bedtimeMinutes: Int = 22 * 60 + 30

    var nudgeIntensity: NudgeIntensity {
        get { NudgeIntensity(rawValue: nudgeIntensityRaw) ?? .medium }
        set { nudgeIntensityRaw = newValue.rawValue }
    }

    /// Drempel voor de snurk-classifier afgeleid van de gevoeligheid.
    var snoreThreshold: Double { 0.75 - sensitivity * 0.45 }     // 0.75 … 0.30

    var watchSettings: WatchSettings {
        WatchSettings(nudgeEnabled: nudgeEnabled, nudgeOnlyOnBack: nudgeOnlyOnBack,
                      sampleIntervalSeconds: positionIntervalSeconds)
    }
}
