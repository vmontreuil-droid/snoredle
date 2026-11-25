import Foundation
import SwiftData
import Combine
import UIKit
import AVFoundation

/// Stuurt één nacht aan: microfoon, snurkepisodes, clips, watch, tikjes, opslag.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()
    enum State: Equatable { case idle, waiting(until: Date), recording, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: SleepSession?
    @Published private(set) var liveDecibel: Double = 0
    @Published private(set) var liveSnoreProbability: Double = 0
    @Published private(set) var isSnoring = false
    @Published private(set) var eventCount = 0
    @Published var lastError: String?
    @Published private(set) var pausedUntil: Date?
    private var pauseStart: Date?
    private var resumeTask: Task<Void, Never>?

    private let settings = AppSettings.shared
    private let hub = WearableHub.shared
    private let detector = SnoreDetector()
    private let clips = ClipRecorder()
    private var context: ModelContext?
    private var bag = Set<AnyCancellable>()
    private var delayTask: Task<Void, Never>?
    /// Waakhond: komt er geen audio meer binnen, dan de microfoon herstarten.
    private var micWatchdog: Timer?

    // Episode-toestand
    private var snoreStreak = 0
    private var lastSnoreFrame: Date?
    private var episodeStart: Date?
    private var episodePeak = 0.0
    private var episodeConfidence: [Double] = []
    private var episodeClip: String?
    private var episodeNudged = false
    private var episodeSkipLogged = false
    /// Aantal geluiden/tikjes in deze snurkperiode (voor luider worden).
    private var episodeNudges = 0
    /// Onrust via de microfoon (voor slim wekken zonder watch).
    private var restlessStreak = 0
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

    private var knownPosition: SleepPosition = .unknown
    private var positionAt = Date.distantPast
    /// Houding is maar geldig als de watch ze recent doorgaf (die stuurt minstens om de 5 min).
    private var currentPosition: SleepPosition {
        Date().timeIntervalSince(positionAt) < 12 * 60 ? knownPosition : .unknown
    }

    // Uit bed (toilet / slaapwandelen)
    private var recentSteps: [(Date, Int)] = []
    private var uprightNow = false
    private var outStart: Date?
    private var outLastActive = Date.distantPast
    private var outSteps = 0
    private var outAlerted = false

    // Andere nachtgeluiden
    private struct SoundTrack { var start: Date; var last: Date; var conf: [Double]; var clip: String? }
    private var soundTracks: [NightSoundKind: SoundTrack] = [:]
    @Published private(set) var nightSoundCount = 0

    init() {
        detector.delegate = self
        let clips = self.clips          // audiothread: niet via MainActor-self gaan
        detector.onBuffer = { buffer, _ in clips.append(buffer) }
        detector.onRestart = { [weak self] msg in
            DiagLog.shared.log("microfoon", msg)
            Task { @MainActor in self?.closeEpisode(at: .now); self?.clips.reset() }
        }
        hub.events
            .sink { [weak self] source, event in self?.handleWearable(event, source: source) }
            .store(in: &bag)
        AlarmService.shared.onDismissed = { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        AlarmService.shared.onAlarmStarted = { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        context = AppData.container.mainContext
        recoverUnfinishedNights()
    }

    /// Werd de app 's nachts afgesloten (geheugen, update, herstart), dan blijft er een nacht zonder
    /// einde over. Die sluiten we af op het laatste meetpunt, zodat hij in je lijst verschijnt.
    private func recoverUnfinishedNights() {
        guard let ctx = context,
              let open = try? ctx.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate<SleepSession> { $0.end == nil })) else { return }
        for s in open where s.id != current?.id {
            let lastSample = s.loudness.map(\.at).max() ?? s.events.map(\.end).max() ?? s.start
            if lastSample.timeIntervalSince(s.start) < 600 { ctx.delete(s); continue }   // te kort, weg ermee
            s.end = lastSample
            s.note = s.note.isEmpty ? "Meting werd onderbroken (app afgesloten)." : s.note
            SnoreAnalysis.summarize(s)
        }
        try? ctx.save()
    }

    // MARK: Bediening van buitenaf (watch, Siri, Opdrachten)

    func handle(_ command: WatchCommand) {
        switch command {
        case .start: startFromShortcut()
        case .stop: Task { await stop() }
        case .pause(let m): pause(minutes: m)
        case .resume: resume()
        }
    }

    /// Start met de middelen van de vorige keer (die gebruik je meestal meerdere nachten).
    func startFromShortcut() {
        guard state == .idle else { return }
        let raw = UserDefaults.standard.string(forKey: "lastRemedies") ?? ""
        let remedies = raw.split(separator: ",").compactMap { Remedy(rawValue: String($0)) }
        start(factors: [], remedies: remedies)
        if state == .idle {
            NotificationService.shared.notify(title: "Snoredle kon niet starten",
                                              body: "Open Snoredle op je iPhone om de nacht te starten.")
        }
    }

    // MARK: Pauze

    var isPaused: Bool { pausedUntil != nil }

    /// Privémoment: even niets opnemen of meten.
    func pause(minutes: Int) {
        guard current != nil, state != .idle else { return }
        closeEpisode(at: .now)
        for kind in Array(soundTracks.keys) { closeSound(kind) }
        clips.endClip()
        if pauseStart == nil { pauseStart = .now }
        DiagLog.shared.log("nacht", "pauze \(minutes) min")
        let until = Date().addingTimeInterval(Double(minutes * 60))
        pausedUntil = until
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.resume() }
        }
        broadcastState()
    }

    func resume() {
        resumeTask?.cancel()
        if let ps = pauseStart, let s = current {
            s.pausesRaw += [ps.timeIntervalSince1970, Date().timeIntervalSince1970]
        }
        pauseStart = nil
        pausedUntil = nil
        broadcastState()
    }

    func broadcastState() {
        hub.sendState(recording: state != .idle, pausedUntil: pausedUntil)
    }

    func attach(_ context: ModelContext) { self.context = context }

    // MARK: Start / stop

    func start(factors: [SleepFactor], remedies: [Remedy]) {
        guard state == .idle, let context else { return }
        if AVAudioApplication.shared.recordPermission == .denied {
            lastError = "Snoredle heeft geen toegang tot de microfoon. Zet het aan in Instellingen › Apps › Snoredle."
            return
        }
        lastError = nil
        let session = SleepSession()
        session.factorsRaw = factors.map(\.rawValue)
        session.remediesRaw = remedies.map(\.rawValue)
        session.wearableName = hub.active.map(\.name).joined(separator: ", ")
        context.insert(session)
        current = session
        resetEpisode(); clipsThisNight = 0; eventCount = 0
        // Niets van de vorige nacht meenemen.
        knownPosition = .unknown; positionAt = .distantPast
        lastNudge = .distantPast; episodeNudges = 0; silentSince = nil; restlessStreak = 0; lastSnoreFrame = nil
        soundTracks = [:]; nightSoundCount = 0
        recentSteps = []; uprightNow = false; outStart = nil; outSteps = 0; outAlerted = false
        // Minuut-teller opnieuw starten, anders krijgt het eerste meetpunt een oud tijdstip.
        minuteDb = []; minuteSnore = []; minuteStart = .now
        recentDb = []; noiseFloor = 30
        UIApplication.shared.isIdleTimerDisabled = false   // scherm mag uit; audio loopt door

        // Eerst de nieuwe status klaarzetten, dan pas de watch starten (anders leest die een oude "gestopt").
        hub.sendState(recording: true, pausedUntil: nil)
        hub.start(id: session.id, settings: settings.watchSettings)

        detector.calibrationOffset = settings.calibrationOffset
        do { try detector.start() } catch {
            lastError = "Microfoon kon niet starten: \(error.localizedDescription)"
            DiagLog.shared.log("nacht", "microfoon start mislukt: \(error.localizedDescription)")
            hub.stop(id: session.id)
            context.delete(session); current = nil; broadcastState(); return
        }

        micWatchdog?.invalidate()
        micWatchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.current != nil, self.state != .finishing else { return }
                let quiet = Date().timeIntervalSince(self.detector.lastBufferAt)
                if quiet > 20 { self.detector.restart(reason: "\(Int(quiet)) s geen audio") }
            }
        }

        Task { await AlarmService.shared.arm() }
        pausedUntil = nil; pauseStart = nil
        DiagLog.shared.resetCounters()
        DiagLog.shared.log("nacht", "geluid bij snurken: \(NudgeSound(rawValue: settings.nudgeSoundRaw)?.label ?? "?") op \(Int(settings.nudgeSoundVolume * 100))% · mediavolume iPhone \(Int(NudgeSoundPlayer.systemVolume * 100))%")
        DiagLog.shared.log("nacht", "START · watch actief: \(hub.active.map(\.name)) · tikjes \(settings.nudgeEnabled ? "aan" : "uit") (alleen rug: \(settings.nudgeOnlyOnBack), na \(Int(settings.nudgeAfterSeconds)) s, eerste \(settings.nudgeQuietFirstMinutes) min niet) · volgende wekker: \(AlarmService.shared.nextItem.map { "\($0.0.timeText) slim=\($0.0.smart)" } ?? "geen")")
        defer { broadcastState() }
        LiveActivityService.shared.start(session: session, alarm: nil)

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
        // Niet twee keer tegelijk stoppen (bv. wekker gaat af én wordt meteen uitgezet).
        guard let session = current, state != .finishing else { return }
        if isPaused { resume() }
        DiagLog.shared.log("nacht", "STOP · \(DiagLog.shared.summary) · episodes \(eventCount)")
        state = .finishing
        delayTask?.cancel()
        closeEpisode(at: .now)
        for kind in Array(soundTracks.keys) { closeSound(kind) }
        closeOutOfBed(force: true)
        flushMinute()
        micWatchdog?.invalidate(); micWatchdog = nil
        detector.stop()
        AlarmService.shared.disarm()
        SleepSoundController.shared.stop(fade: 0.5)
        hub.stop(id: session.id)
        session.end = .now

        // Gezondheid is niet leesbaar als de iPhone vergrendeld is (bv. stop door de wekker);
        // en de watch zet slaapfasen er pas na het ontwaken in. Dan later aanvullen (backfillHealth).
        if settings.useHealthKit, UIApplication.shared.isProtectedDataAvailable {
            await syncHealth(session)
        }
        session.alarmNote = AlarmService.shared.lastWakeReason
        SnoreAnalysis.summarize(session)
        try? context?.save()
        LiveActivityService.shared.end(score: session.snoreScore)
        if let ctx = context { WidgetBridge.publish(context: ctx); NotificationService.shared.refreshWeekly(context: ctx) }

        let favorites = Set((try? context?.fetch(FetchDescriptor<SnoreEvent>(predicate: #Predicate<SnoreEvent> { $0.isFavorite })))?
            .compactMap(\.clipFileName) ?? [])
        ClipRecorder.purge(olderThan: settings.keepClipsDays, keeping: favorites)

        current = nil
        state = .idle
        broadcastState()
    }

    /// Haalt Gezondheid-gegevens op voor één nacht (één keer, of opnieuw als er nog geen slaapfasen waren).
    private func syncHealth(_ session: SleepSession) async {
        let end = session.end ?? .now
        let hk = HealthKitService.shared
        if !session.healthSynced {
            let live = session.vitals.filter { $0.kind == .heartRate }.map(\.at)
            for (kind, value, at, _) in await hk.vitals(from: session.start, to: end) {
                if kind == .heartRate, live.contains(where: { abs($0.timeIntervalSince(at)) < 60 }) { continue }
                session.vitals.append(VitalSample(at: at, kind: kind, value: value))
            }
            await hk.saveSleep(start: session.start, end: end)
            session.healthSynced = true
        }
        // Echte slaapfasen (niet enkel "in bed") komen soms pas later: dan opnieuw ophalen en vervangen.
        if !session.stages.contains(where: { $0.stage != .inBed }) {
            let fetched = await hk.stages(from: session.start.addingTimeInterval(-1800), to: end.addingTimeInterval(1800))
            if fetched.contains(where: { $0.0 != .inBed }) || session.stages.isEmpty {
                session.stages.forEach { context?.delete($0) }
                session.stages = fetched.map { SleepStageSample(start: $0.1, end: $0.2, stage: $0.0) }
            }
        }
    }

    /// Bij het openen van de app: recente nachten aanvullen met Gezondheid.
    func backfillHealth() async {
        guard settings.useHealthKit, state == .idle, let ctx = context,
              UIApplication.shared.isProtectedDataAvailable else { return }
        let since = Date().addingTimeInterval(-48 * 3600)
        let recent = (try? ctx.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate<SleepSession> { $0.start > since }))) ?? []
        var changed = false
        for s in recent where s.end != nil && (!s.healthSynced || !s.stages.contains(where: { $0.stage != .inBed })) {
            let before = (s.vitals.count, s.stages.count, s.healthSynced)
            await syncHealth(s)
            if (s.vitals.count, s.stages.count, s.healthSynced) != before { changed = true }
        }
        if changed { try? ctx.save(); DiagLog.shared.log("gezondheid", "nachten aangevuld met Gezondheid") }
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
        if let until = pausedUntil {
            if f.at >= until { resume() } else { liveDecibel = 0; liveSnoreProbability = 0; return }
        }
        liveDecibel = f.decibel
        liveSnoreProbability = f.snoreConfidence
        updateNoiseFloor(f.decibel)
        minuteDb.append(f.decibel); minuteSnore.append(f.snoreConfidence)
        if f.at.timeIntervalSince(minuteStart) >= 60 { flushMinute() }
        guard state == .recording else { return }
        checkAutoStop()
        // Tijdens slaapgeluiden niet meten: de microfoon hoort dan vooral de speaker.
        // Maar nooit langer dan een uur (bij "Nooit" zou anders de hele nacht niet gemeten worden).
        if SleepSoundController.shared.isPlaying, SleepSoundController.shared.playingFor < 3600 { return }
        // Ons eigen geluid (belletje, stem "Draai je even om") niet als praten/geluid in je slaap tellen.
        let ownSound = f.at.timeIntervalSince(lastNudge) < 12
        if settings.detectNightSounds, !ownSound { trackNightSounds(f) }

        let interfering = settings.ignoreSpeech && (f.otherSounds["speech"] ?? 0) > f.snoreConfidence
        let loudEnough = f.decibel > noiseFloor + 3
        let snoring = f.snoreConfidence >= settings.snoreThreshold && loudEnough && !interfering

        // Slim wekken zonder watch: woelen/ritselen (luid, maar geen snurken of praten) telt als beweging.
        if !hub.watchLive {
            let restless = f.at.timeIntervalSince(lastNudge) > 10 && f.decibel > noiseFloor + 10 && f.snoreConfidence < 0.3 && (f.otherSounds["speech"] ?? 0) < 0.5
            restlessStreak = restless ? restlessStreak + 1 : 0
            if restlessStreak >= 3 {
                restlessStreak = 0
                AlarmService.shared.signal(movement: settings.smartWakeMovementThreshold, source: "geluid (woelen, +\(Int(f.decibel - noiseFloor)) dB)")
            }
        }

        trackBreathingPause(f, snoring: snoring)

        if snoring {
            snoreStreak += 1
            lastSnoreFrame = f.at
            if episodeStart == nil, snoreStreak >= 2 { openEpisode(at: f.at) }
            if episodeStart != nil {
                episodePeak = max(episodePeak, f.decibel)
                episodeConfidence.append(f.snoreConfidence)
                maybeNudge(now: f.at)
            }
        } else {
            snoreStreak = 0
            if episodeStart != nil, let last = lastSnoreFrame, f.at.timeIntervalSince(last) > 6 {
                closeEpisode(at: last)
            }
        }
    }

    private func openEpisode(at t: Date) {
        // Loopt er nog een praat-fragment? Eerst afsluiten.
        if soundTracks.values.contains(where: { $0.clip != nil }) { clips.endClip()
            for k in soundTracks.keys { soundTracks[k]?.clip = nil } }
        episodeStart = t.addingTimeInterval(-1.5)
        episodePeak = 0; episodeConfidence = []; episodeNudged = false; episodeSkipLogged = false
        isSnoring = true
        LiveActivityService.shared.update(snoreEvents: eventCount, isSnoring: true,
                                          position: currentPosition, nightSounds: nightSoundCount)
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
            LiveActivityService.shared.update(snoreEvents: eventCount, isSnoring: false,
                                              position: currentPosition, nightSounds: nightSoundCount)
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

    // MARK: Nachtgeluiden

    private func trackNightSounds(_ f: AudioFrame) {
        for kind in NightSoundKind.allCases {
            let conf = kind.classifierLabels.compactMap { f.otherSounds[$0] }.max() ?? 0
            if conf >= 0.6, f.snoreConfidence < conf {
                if var t = soundTracks[kind] {
                    t.last = f.at; t.conf.append(conf); soundTracks[kind] = t
                } else {
                    var clip: String?
                    if kind != .gasp, settings.saveTalkClips, episodeStart == nil,
                       !soundTracks.values.contains(where: { $0.clip != nil }),
                       clipsThisNight < settings.maxClipsPerNight, let fmt = detector.format {
                        clip = clips.beginClip(format: fmt)
                        if clip != nil { clipsThisNight += 1 }
                    }
                    soundTracks[kind] = SoundTrack(start: f.at.addingTimeInterval(-1), last: f.at, conf: [conf], clip: clip)
                }
            } else if let t = soundTracks[kind], f.at.timeIntervalSince(t.last) > 3 {
                closeSound(kind)
            }
        }
    }

    private func closeSound(_ kind: NightSoundKind) {
        guard let t = soundTracks.removeValue(forKey: kind), let session = current else { return }
        if t.clip != nil { clips.endClip() }
        let duration = t.last.timeIntervalSince(t.start)
        // Eén kuch of nies telt; praten pas vanaf 2 s.
        if duration >= (kind == .talking ? 2 : 0.5) {
            let conf = t.conf.reduce(0, +) / Double(t.conf.count)
            session.nightSounds.append(NightSoundEvent(start: t.start, end: t.last.addingTimeInterval(1),
                                                       kind: kind, confidence: conf, clipFileName: t.clip))
            nightSoundCount += 1
        } else if let c = t.clip {
            try? FileManager.default.removeItem(at: ClipRecorder.url(for: c))
            clipsThisNight -= 1
        }
    }

    /// Snurken → stilte ≥ drempel → snurken gaat verder: mogelijke ademstop. GEEN diagnose.
    /// Los van de snurkperiodes, want die worden na 6 s stilte al afgesloten.
    private func trackBreathingPause(_ f: AudioFrame, snoring: Bool) {
        guard settings.pauseDetection, let session = current else { return }
        if snoring {
            if let q = silentSince {
                let gap = f.at.timeIntervalSince(q)
                if gap >= settings.pauseThresholdSeconds && gap <= 90 {
                    session.possibleApneaEvents += 1
                    DiagLog.shared.log("adem", "mogelijke ademstop: \(Int(gap)) s stil tussen snurken (#\(session.possibleApneaEvents))")
                }
            }
            silentSince = nil
        } else if f.decibel < noiseFloor + 2 {
            // Stilte telt alleen als ze vlak na snurken begint.
            if silentSince == nil, let last = lastSnoreFrame, f.at.timeIntervalSince(last) < 3 { silentSince = f.at }
        } else if f.snoreConfidence < 0.2 {
            silentSince = nil           // ander geluid (bewegen, praten): geen stilte
        }
        if let q = silentSince, f.at.timeIntervalSince(q) > 90 { silentSince = nil }   // gewoon stil geworden
    }

    private func maybeNudge(now: Date) {
        let soundOn = settings.nudgeSoundRaw != NudgeSound.none.rawValue
        guard settings.nudgeEnabled || soundOn, let start = episodeStart, let session = current else { return }
        guard now.timeIntervalSince(start) >= settings.nudgeAfterSeconds else { return }
        guard now.timeIntervalSince(lastNudge) >= settings.nudgeCooldownMinutes * 60 else { return }
        // Waarom niet? Eén keer per episode noteren.
        func skip(_ reason: String) {
            if !episodeSkipLogged { DiagLog.shared.log("tikje", "niet gevraagd: \(reason)"); episodeSkipLogged = true }
        }
        let watchOn = settings.nudgeEnabled && hub.hasHaptics
        guard watchOn || soundOn else { return skip("geen watch actief en geen geluid gekozen") }
        guard now.timeIntervalSince(session.start) > Double(settings.nudgeQuietFirstMinutes * 60) else { return skip("eerste \(settings.nudgeQuietFirstMinutes) min") }
        if settings.nudgeOnlyOnBack, currentPosition != .back, currentPosition != .unknown { return skip("houding \(currentPosition.label)") }
        if watchOn { hub.nudge(settings.nudgeIntensity) }
        // Luider worden zolang je blijft snurken (ook als het geluid zelf de snurkperiode even onderbreekt).
        if now.timeIntervalSince(lastNudge) > settings.nudgeCooldownMinutes * 60 + 180 { episodeNudges = 0 }
        if soundOn {
            let r = NudgeSoundPlayer.shared.play(level: episodeNudges)
            DiagLog.shared.log("tikje", "geluid (niveau \(episodeNudges + 1)): \(r)")
            if !r.hasPrefix("FOUT") { episodeNudged = true }     // telt mee als "gewekt" in het rapport
        }
        episodeNudges += 1
        DiagLog.shared.nudgeRequested("houding \(currentPosition.label), snurkt \(Int(now.timeIntervalSince(start))) s")
        lastNudge = now
    }

    /// De watch heeft echt getikt.
    private func nudgeDelivered() {
        DiagLog.shared.nudgeDelivered()
        if episodeStart != nil { episodeNudged = true }
        else if let last = current?.events.max(by: { $0.start < $1.start }) { last.wasNudged = true }
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

    // MARK: Uit bed

    private func evaluateOutOfBed(at now: Date) {
        guard settings.trackOutOfBed, state == .recording, !isPaused, let session = current else { return }
        recentSteps.removeAll { now.timeIntervalSince($0.0) > 30 }
        let steps30 = recentSteps.map(\.1).reduce(0, +)
        let isUp = (uprightNow && steps30 >= 2) || steps30 >= 6

        if isUp {
            if outStart == nil {
                outStart = now; outSteps = 0; outAlerted = false
                DiagLog.shared.log("uitbed", "opgestaan (\(steps30) stappen, rechtop: \(uprightNow))")
            }
            outLastActive = now
            outSteps += recentSteps.last.map { $0.0 == now ? $0.1 : 0 } ?? 0
            // Slaapwandelmodus: na x seconden op, niet in het eerste halfuur.
            if settings.sleepwalkMode, !outAlerted, let s = outStart,
               now.timeIntervalSince(s) >= settings.sleepwalkAfterSeconds,
               now.timeIntervalSince(session.start) > 30 * 60 {
                outAlerted = true
                DiagLog.shared.log("uitbed", "SLAAPWANDELALARM")
                Task { await AlarmService.shared.sleepwalkAlert(loud: settings.sleepwalkLoudAlarm) }
            }
        } else {
            closeOutOfBed(force: false, now: now)
        }
    }

    /// Terug in bed: 90 s geen stappen en niet meer rechtop.
    private func closeOutOfBed(force: Bool, now: Date = .now) {
        guard let s = outStart, let session = current else { return }
        guard force || (now.timeIntervalSince(outLastActive) > 90 && !uprightNow) else { return }
        let end = outLastActive
        if end.timeIntervalSince(s) >= 30 || outSteps >= 10 || outAlerted {
            session.outOfBed.append(OutOfBedEvent(start: s, end: max(end, s.addingTimeInterval(30)), steps: outSteps, alerted: outAlerted))
            DiagLog.shared.log("uitbed", "terug in bed na \(Int(end.timeIntervalSince(s))) s, \(outSteps) stappen")
        }
        outStart = nil; outSteps = 0
    }

    // MARK: Wearables

    private func handleWearable(_ e: WearableEvent, source: String) {
        guard let session = current else { return }
        switch e {
        case .position(let p):
            if p.position != currentPosition, p.at >= positionAt {
                LiveActivityService.shared.update(snoreEvents: eventCount, isSnoring: isSnoring,
                                                  position: p.position, nightSounds: nightSoundCount)
            }
            // Late (gebufferde) metingen niet als "nu" laten gelden.
            if p.at >= positionAt { knownPosition = p.position; positionAt = p.at }
            session.positions.append(PositionSample(at: p.at, position: p.position,
                                                    confidence: p.confidence, source: source))
        case .nudgeDelivered:
            nudgeDelivered()
        case .steps(let n, let at):
            recentSteps.append((at, n))
            evaluateOutOfBed(at: at)
        case .upright(let up, let at):
            uprightNow = up
            evaluateOutOfBed(at: at)
        case .vital(let kind, let v, let at):
            session.vitals.append(VitalSample(at: at, kind: kind, value: v))
            if kind == .movement {
                AlarmService.shared.signal(movement: v, at: at)
                SleepSoundController.shared.noteMovement(v)
            }
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
