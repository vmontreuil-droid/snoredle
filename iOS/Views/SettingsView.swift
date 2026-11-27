import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var hub: WearableHub
    @EnvironmentObject var store: StoreManager
    @State private var showCalibration = false
    @ObservedObject private var lock = AppLock.shared
    @State private var nudgeResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isPlus { Label("Snoredle Plus actief", systemImage: "checkmark.seal.fill") }
                    else { NavigationLink("Snoredle Plus") { PaywallView() } }
                    NavigationLink { PortalView() } label: {
                        Label("Portaal (al je nachten op de computer)", systemImage: "globe")
                    }
                }

                Section("Detectie") {
                    VStack(alignment: .leading) {
                        Text("Gevoeligheid: \(Int(s.sensitivity * 100))%")
                        Slider(value: $s.sensitivity, in: 0...1)
                        Text("Hoger = meer snurken herkend, maar ook meer valse meldingen.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Spraak en tv negeren", isOn: $s.ignoreSpeech)
                    Stepper("Start na \(s.startDelayMinutes) min", value: $s.startDelayMinutes, in: 0...90, step: 5)
                    Picker("Automatisch stoppen", selection: $s.autoStopHour) {
                        Text("Uit").tag(0)
                        ForEach(5...12, id: \.self) { Text("om \($0):00").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("dB-kalibratie: \(Int(s.calibrationOffset))")
                        Slider(value: $s.calibrationOffset, in: 70...120, step: 1)
                        Text("Vergelijk met een geluidsmeter en pas aan tot de waarden overeenkomen.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { lock.enabled }, set: { on in Task { _ = await lock.enable(on) } })) {
                        Label("Vergrendel met \(lock.biometryName)", systemImage: lock.biometrySymbol)
                    }
                    if lock.enabled {
                        Picker("Opnieuw vergrendelen", selection: $lock.graceSeconds) {
                            Text("Meteen").tag(0); Text("Na 1 minuut").tag(60)
                            Text("Na 5 minuten").tag(300); Text("Na 15 minuten").tag(900)
                        }
                    }
                } header: { Text("Privacy") } footer: {
                    Text("Anderen die je telefoon gebruiken, zien je nachten en opnames niet. In de app-wisselaar wordt de inhoud verborgen.")
                }

                Section {
                    NavigationLink {
                        AlarmsView()
                    } label: {
                        HStack {
                            Label("Wekkers", systemImage: "alarm.fill")
                            Spacer()
                            Text("\(AlarmService.shared.alarms.filter(\.enabled).count) actief").foregroundStyle(.secondary)
                        }
                    }
                    Stepper("Sluimeren \(s.snoozeMinutes) min", value: $s.snoozeMinutes, in: 3...30)
                    Toggle("Ook trillen op watch", isOn: $s.alarmVibrateWatch)
                    VStack(alignment: .leading) {
                        Text("Gevoeligheid slimme wekker")
                        Slider(value: $s.smartWakeMovementThreshold, in: 0.5...4) {
                            Text("Gevoeligheid")
                        } minimumValueLabel: { Text("hoog").font(.caption2) } maximumValueLabel: { Text("laag").font(.caption2) }
                    }
                } header: { Text("Wekker") } footer: {
                    Text("Op iOS 26 gaan je wekkers af zoals de Klok-app: ook in stille modus, met Focus aan, op je Apple Watch en ook als je die nacht niet meet. De meting stopt vanzelf als je een wekker uitzet.")
                }

                Section("Slaapdoel en meldingen") {
                    Stepper(String(format: "Slaapdoel %.1f u", s.sleepGoalHours), value: $s.sleepGoalHours, in: 5...10, step: 0.5)
                    Toggle("Bedtijdherinnering", isOn: $s.bedtimeReminder)
                        .onChange(of: s.bedtimeReminder) { NotificationService.shared.refreshBedtime() }
                    if s.bedtimeReminder {
                        DatePicker("Bedtijd", selection: Binding(
                            get: { Calendar.current.date(bySettingHour: s.bedtimeMinutes / 60, minute: s.bedtimeMinutes % 60, second: 0, of: .now) ?? .now },
                            set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                s.bedtimeMinutes = (c.hour ?? 22) * 60 + (c.minute ?? 30)
                                NotificationService.shared.refreshBedtime()
                            }), displayedComponents: .hourAndMinute)
                    }
                    Toggle("Weekrapport op maandag", isOn: $s.weeklyReport)
                }

                Section {
                    Toggle("Uit bed bijhouden (toilet…)", isOn: $s.trackOutOfBed)
                    Toggle("Slaapwandelmodus", isOn: $s.sleepwalkMode)
                    if s.sleepwalkMode {
                        Toggle("Luid alarm (ook in stille modus)", isOn: $s.sleepwalkLoudAlarm)
                        Stepper("Na \(Int(s.sleepwalkAfterSeconds)) s rechtop of stappen", value: $s.sleepwalkAfterSeconds, in: 5...120, step: 5)
                        Button("Test slaapwandelalarm") {
                            Task { await AlarmService.shared.sleepwalkAlert(loud: s.sleepwalkLoudAlarm) }
                        }
                    }
                } header: { Text("Uit bed en slaapwandelen") } footer: {
                    Text("Met je watch om ziet Snoredle wanneer je opstaat en hoe lang je uit bed bent. In slaapwandelmodus gaat er een alarm af en trilt je watch als je opstaat (niet in het eerste halfuur). Een tweede persoon wekken kan nog niet.")
                }

                Section {
                    Toggle("Andere geluiden herkennen", isOn: $s.detectNightSounds)
                    if s.detectNightSounds {
                        Toggle("Opnemen (praten, lachen, hoesten…)", isOn: $s.saveTalkClips)
                    }
                } header: { Text("Nachtgeluiden") } footer: {
                    Text("Praten, hoesten, niezen, lachen en naar adem happen.")
                }

                Section("Opnames") {
                    Toggle("Snurkfragmenten bewaren", isOn: $s.saveClips)
                    Stepper("Max. \(s.maxClipsPerNight) per nacht", value: $s.maxClipsPerNight, in: 5...200, step: 5)
                    Stepper("Bewaar \(s.keepClipsDays) dagen", value: $s.keepClipsDays, in: 3...365, step: 1)
                    Text("Favorieten worden nooit automatisch verwijderd.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Geluid", selection: $s.nudgeSoundRaw) {
                        ForEach(NudgeSound.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    if s.nudgeSoundRaw != NudgeSound.none.rawValue {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $s.nudgeSoundVolume, in: 0.1...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        Button("Test geluid") { NudgeSoundPlayer.shared.play() }
                        Button("Test geluid (3e keer, luider)") { NudgeSoundPlayer.shared.play(level: 2) }
                    }
                } header: { Text("Geluid bij snurken") } footer: {
                    Text("Je iPhone speelt dit geluid als je snurkt (met dezelfde regels als de tikjes: na x seconden, alleen op je rug als je watch dat weet). Werkt ook zonder watch. Blijf je snurken, dan wordt het telkens luider en langer. Het volume hier is een percentage van het mediavolume van je iPhone: zet dat 's avonds hoog genoeg (de stille modus speelt geen rol).")
                }

                Section("Watch en tikjes") {
                    Toggle("Tikje geven bij snurken", isOn: $s.nudgeEnabled)
                    if s.nudgeEnabled {
                        Toggle("Alleen als ik op mijn rug lig", isOn: $s.nudgeOnlyOnBack)
                        Picker("Sterkte", selection: Binding(get: { s.nudgeIntensity }, set: { s.nudgeIntensity = $0 })) {
                            ForEach(NudgeIntensity.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Stepper("Na \(Int(s.nudgeAfterSeconds)) s snurken", value: $s.nudgeAfterSeconds, in: 5...120, step: 5)
                        Stepper("Pauze \(Int(s.nudgeCooldownMinutes)) min tussen tikjes", value: $s.nudgeCooldownMinutes, in: 1...30)
                        Stepper("Eerste \(s.nudgeQuietFirstMinutes) min geen tikjes", value: $s.nudgeQuietFirstMinutes, in: 0...90, step: 5)
                        Button {
                            testing = true
                            Task { nudgeResult = await hub.testNudge(s.nudgeIntensity); testing = false }
                        } label: {
                            HStack { Text("Test tikje"); if testing { Spacer(); ProgressView() } }
                        }
                        if let nudgeResult {
                            Text(nudgeResult).font(.footnote)
                                .foregroundStyle(nudgeResult.hasSuffix("✓") ? .green : .orange)
                        }
                    }
                    Stepper("Houding meten elke \(Int(s.positionIntervalSeconds)) s", value: $s.positionIntervalSeconds, in: 5...60, step: 5)
                    Button(hub.profile.isComplete ? "Opnieuw kalibreren" : "Houdingen kalibreren") { showCalibration = true }
                    if hub.profile.isComplete { Button("Kalibratie wissen", role: .destructive) { hub.resetCalibration() } }
                }

                Section {
                    Toggle("Gegevens uit Gezondheid", isOn: $s.useHealthKit)
                    Toggle("Bluetooth-hartslag (Garmin, Polar…)", isOn: $s.useBluetoothHR)
                    Toggle("Mogelijke ademstops markeren", isOn: $s.pauseDetection)
                    if s.pauseDetection {
                        Stepper("Stilte ≥ \(Int(s.pauseThresholdSeconds)) s", value: $s.pauseThresholdSeconds, in: 8...30)
                    }
                } header: { Text("Andere toestellen en gezondheid") } footer: {
                    Text("Via Gezondheid werken o.a. Garmin, Withings, Oura, Polar en Zepp mee (hartslag, SpO₂, ademhaling). Bluetooth-hartslag wordt actief na herstart van de app.")
                }

                BackupSection()

                Section("Over") {
                    NavigationLink { DiagnoseView() } label: { Label("Diagnose en versie", systemImage: "stethoscope") }
                    Text("Snoredle is geen medisch hulpmiddel. Alle audio blijft op je toestel.").font(.footnote)
                    Link("Privacybeleid", destination: URL(string: "https://example.com/privacy")!)
                    Link("Gebruiksvoorwaarden", destination: URL(string: "https://example.com/terms")!)
                }
            }
            .navigationTitle("Instellingen")
            .sheet(isPresented: $showCalibration) { CalibrationView() }
        }
    }
}

/// Je ligt elke houding 10 s in bed met je watch om; de watch meet de zwaartekrachtrichting.
struct CalibrationView: View {
    @EnvironmentObject var hub: WearableHub
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var countdown = 0
    @State private var failed = false

    var position: SleepPosition? { step < SleepPosition.calibratable.count ? SleepPosition.calibratable[step] : nil }

    var body: some View {
        VStack(spacing: 20) {
            Text("Kalibratie").font(.system(.largeTitle, design: .rounded).bold())
            if let p = position {
                Text("Houding \(step + 1) van \(SleepPosition.calibratable.count)").font(.footnote).foregroundStyle(.secondary)
                Image(systemName: p.symbol).font(.system(size: 56)).foregroundStyle(Theme.accent)
                Text("Ga \(p.instruction) liggen, zoals je slaapt, met je watch om.")
                    .multilineTextAlignment(.center)
                if !hub.watchReachable {
                    Label("Doe je watch om en open Snoredle erop. Dan kan je beginnen.", systemImage: "applewatch.slash")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if countdown > 0 {
                    Text("\(countdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(countdown > 5 ? "Stil gaan liggen…" : "Meten…").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button(failed ? "Opnieuw proberen" : "Ik lig klaar") { run(p) }
                        .buttonStyle(.borderedProminent).disabled(!hub.watchReachable)
                }
                if failed {
                    Text("De meting kwam niet aan. Zit je watch om, ontgrendeld, en staat Snoredle erop open?")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Text("Tip: je kan ook op de watch zelf kalibreren: open Snoredle op je watch › Kalibreer.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Klaar! Je watch herkent nu je slaaphoudingen.")
                Button("Sluiten") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }

    private func run(_ p: SleepPosition) {
        failed = false
        let before = hub.profile.vectors[p]
        countdown = 10
        Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
                if countdown == 5 { hub.calibrate(p) }
            }
            // Wacht tot de watch de meting terugstuurt (max. 8 s).
            for _ in 0..<16 {
                if let v = hub.profile.vectors[p], v != before { step += 1; return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            failed = true
        }
    }
}

struct PaywallView: View {
    @EnvironmentObject var store: StoreManager
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(Theme.accent)
                Text("Snoredle Plus").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(StoreManager.plusFeatures, id: \.self) { Label($0, systemImage: "checkmark.circle.fill") }
                }
                ForEach(store.products, id: \.id) { p in
                    Button {
                        Task { do { try await store.buy(p) } catch { self.error = error.localizedDescription } }
                    } label: {
                        VStack { Text(p.displayName).bold(); Text(p.displayPrice).font(.caption) }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                }
                if store.products.isEmpty { ProgressView() }
                Button("Aankopen herstellen") { Task { await store.restore() } }.font(.footnote)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Abonnementen verlengen automatisch tenzij je ze minstens 24 u voor het einde opzegt in je Apple ID-instellingen.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24)
        }
        .background(NightBackground())
    }
}
