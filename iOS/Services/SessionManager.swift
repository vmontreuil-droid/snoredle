import Foundation
import SwiftData
import Combine
import UIKit

/// Stuurt één nacht aan: microfoon, snurkepisodes, clips, watch, tikjes, opslag.
@MainActor
final class SessionManager: ObservableObject {
    enum State: Equatable { case idle, waiting(until: Date), recording, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: SleepSession?
    @Published private(set) var liveDecibel: Double = 0
    @Published private(set) var liveSnoreProbability: Double = 0
    @Published private(set) var isSnoring = false
    @Published private(set) var eventCount = 0
    @Published var lastError: String?

    private let settings = AppSettings.shared
    private let hub = WearableHub.shared
    private let detector = SnoreDetector()
    private let clips = ClipRecorder()
    private var context: ModelContext?
    private var bag = Set<AnyCancellable>()
    private var delayTask: Task<Void, Never>?

    // Episode-toestand
    private var snoreStreak = 0
    private var lastSnoreFrame: Date?
    private var episodeStart: Date?
    private var episodePeak = 0.0
    private var episodeConfidence: [Double] = []
    private var episodeClip: String?
    private var episodeNudged = false
    private var lastNudge: Date = .distantPast
    private var clipsThisNight = 0

    // Achtergrondniveau (voortschrijdend 10e percentiel)
    private var recentDb: [Double] = []
    private var noiseFloor = 30.0

    // Minuut-aggregatie
    private var minuteDb: [Double] = []
    private var minuteSnore: [Double] = []
    private var minuteStart = Date()

    // Ademstop-heuristiek
    private var silentSince: Date?

    private var currentPosition: SleepPosition = .unknown

    init() {
        detector.delegate = self
        let clips = self.clips          // audiothread: niet via MainActor-self gaan
        detector.onBuffer = { buffer, _ in clips.append(buffer) }
        hub.events
            .sink { [weak self] source, event in self?.handleWearable(event, source: source) }
            .store(in: &bag)
    }

    func attach(_ context: ModelContext) { self.context = context }

    // MARK: Start / stop

    func start(factors: [SleepFactor], remedies: [Remedy]) {
        guard state == .idle, let context else { return }
        let session = SleepSession()
        session.factorsRaw = factors.map(\.rawValue)
        session.remediesRaw = remedies.map(\.rawValue)
        session.wearableName = hub.active.map(\.name).joined(separator: ", ")
        context.insert(session)
        current = session
        resetEpisode(); clipsThisNight = 0; eventCount = 0
        UIApplication.shared.isIdleTimerDisabled = false   // scherm mag uit; audio loopt door

        hub.start(id: session.id, settings: settings.watchSettings)

        detector.calibrationOffset = settings.calibrationOffset
        do { try detector.start() } catch {
            lastError = "Microfoon kon niet starten: \(error.localizedDescription)"
            context.delete(session); current = nil; return
        }

        let delay = TimeInterval(settings.startDelayMinutes * 60)
        if delay > 0 {
            let until = Date().addingTimeInterval(delay)
            state = .waiting(until: until)
            delayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run { if case .waiting = self?.state { self?.state = .recording } }
            }
        } else {
            state = .recording
        }
    }

    func stop() async {
        guard let session = current else { return }
        state = .finishing
        delayTask?.cancel()
        closeEpisode(at: .now)
        flushMinute()
        detector.stop()
        hub.stop(id: session.id)
        session.end = .now

        if settings.useHealthKit {
            for (kind, value, at, _) in await HealthKitService.shared.vitals(from: session.start, to: .now) {
                session.vitals.append(VitalSample(at: at, kind: kind, value: value))
            }
        }
        SnoreAnalysis.summarize(session)
        try? context?.save()

        let favorites = Set((try? context?.fetch(FetchDescriptor<SnoreEvent>(predicate: #Predicate<SnoreEvent> { $0.isFavorite })))?
            .compactMap(\.clipFileName) ?? [])
        ClipRecorder.purge(olderThan: settings.keepClipsDays, keeping: favorites)

        current = nil
        state = .idle
    }

    /// Automatisch stoppen op het ingestelde uur.
    func checkAutoStop() {
        guard state == .recording, settings.autoStopHour > 0, let s = current else { return }
        let hour = Calendar.current.component(.hour, from: .now)
        if hour == settings.autoStopHour, Date().timeIntervalSince(s.start) > 3 * 3600 {
            Task { await stop() }
        }
    }

    // MARK: Frames verwerken

    fileprivate func process(_ f: AudioFrame) {
        liveDecibel = f.decibel
        liveSnoreProbability = f.snoreConfidence
        updateNoiseFloor(f.decibel)
        minuteDb.append(f.decibel); minuteSnore.append(f.snoreConfidence)
        if f.at.timeIntervalSince(minuteStart) >= 60 { flushMinute() }
        guard state == .recording else { return }
        checkAutoStop()

        let interfering = settings.ignoreSpeech && (f.otherSounds["speech"] ?? 0) > f.snoreConfidence
        let loudEnough = f.decibel > noiseFloor + 3
        let snoring = f.snoreConfidence >= settings.snoreThreshold && loudEnough && !interfering

        if snoring {
            snoreStreak += 1
            lastSnoreFrame = f.at
            silentSince = nil
            if episodeStart == nil, snoreStreak >= 2 { openEpisode(at: f.at) }
            if episodeStart != nil {
                episodePeak = max(episodePeak, f.decibel)
                episodeConfidence.append(f.snoreConfidence)
                maybeNudge(now: f.at)
            }
        } else {
            snoreStreak = 0
            if episodeStart != nil {
                if f.decibel < noiseFloor + 2 { silentSince = silentSince ?? f.at }
                if let last = lastSnoreFrame, f.at.timeIntervalSince(last) > 6 {
                    detectPause(now: f.at)
                    closeEpisode(at: last)
                }
            }
        }
    }

    private func openEpisode(at t: Date) {
        episodeStart = t.addingTimeInterval(-1.5)
        episodePeak = 0; episodeConfidence = []; episodeNudged = false
        isSnoring = true
        if settings.saveClips, clipsThisNight < settings.maxClipsPerNight, let fmt = detector.format {
            episodeClip = clips.beginClip(format: fmt)
            if episodeClip != nil { clipsThisNight += 1 }
        }
    }

    private func closeEpisode(at end: Date) {
        guard let start = episodeStart, let session = current else { resetEpisode(); return }
        clips.endClip()
        // Korte tikjes (<4 s) negeren — vaak een kuch of omdraaien.
        if end.timeIntervalSince(start) >= 4 {
            let conf = episodeConfidence.isEmpty ? 0 : episodeConfidence.reduce(0, +) / Double(episodeConfidence.count)
            let e = SnoreEvent(start: start, end: end,
                               intensity: SnoreAnalysis.intensity(peak: episodePeak, noiseFloor: noiseFloor),
                               peakDecibel: episodePeak, confidence: conf,
                               position: currentPosition, clipFileName: episodeClip)
            e.wasNudged = episodeNudged
            session.events.append(e)
            eventCount += 1
        } else if let clip = episodeClip {
            try? FileManager.default.removeItem(at: ClipRecorder.url(for: clip))
            clipsThisNight -= 1
        }
        resetEpisode()
    }

    private func resetEpisode() {
        episodeStart = nil; episodeClip = nil; episodePeak = 0
        episodeConfidence = []; snoreStreak = 0; isSnoring = false
    }

    /// Snurken → stilte ≥ drempel → markeer mogelijke ademstop. GEEN diagnose.
    private func detectPause(now: Date) {
        guard settings.pauseDetection, let s = silentSince, let session = current else { return }
        if now.timeIntervalSince(s) >= settings.pauseThresholdSeconds { session.possibleApneaEvents += 1 }
        silentSince = nil
    }

    private func maybeNudge(now: Date) {
        guard settings.nudgeEnabled, hub.hasHaptics, let start = episodeStart, let session = current else { return }
        guard now.timeIntervalSince(session.start) > Double(settings.nudgeQuietFirstMinutes * 60) else { return }
        guard now.timeIntervalSince(start) >= settings.nudgeAfterSeconds else { return }
        guard now.timeIntervalSince(lastNudge) >= settings.nudgeCooldownMinutes * 60 else { return }
        if settings.nudgeOnlyOnBack, currentPosition != .back, currentPosition != .unknown { return }
        hub.nudge(settings.nudgeIntensity)
        lastNudge = now
        episodeNudged = true
    }

    private func updateNoiseFloor(_ db: Double) {
        recentDb.append(db)
        if recentDb.count > 600 { recentDb.removeFirst(recentDb.count - 600) }   // ± 5 min
        if recentDb.count % 20 == 0 {
            let sorted = recentDb.sorted()
            noiseFloor = sorted[Int(Double(sorted.count) * 0.1)]
        }
    }

    private func flushMinute() {
        defer { minuteDb = []; minuteSnore = []; minuteStart = .now }
        guard let session = current, !minuteDb.isEmpty, state != .idle else { return }
        let db = minuteDb.reduce(0, +) / Double(minuteDb.count)
        let sn = minuteSnore.max() ?? 0
        session.loudness.append(LoudnessSample(at: minuteStart, decibel: db, snoreProbability: sn))
        if session.loudness.count % 15 == 0 { try? context?.save() }   // tussentijds bewaren
    }

    // MARK: Wearables

    private func handleWearable(_ e: WearableEvent, source: String) {
        guard let session = current else { return }
        switch e {
        case .position(let p):
            currentPosition = p.position
            session.positions.append(PositionSample(at: p.at, position: p.position,
                                                    confidence: p.confidence, source: source))
        case .vital(let kind, let v, let at):
            session.vitals.append(VitalSample(at: at, kind: kind, value: v))
        default: break
        }
    }
}

extension SessionManager: SnoreDetectorDelegate {
    nonisolated func detector(_ d: SnoreDetector, didProduce frame: AudioFrame) {
        Task { @MainActor in self.process(frame) }
    }
    nonisolated func detector(_ d: SnoreDetector, didFail error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
