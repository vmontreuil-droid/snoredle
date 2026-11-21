import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var hub: WearableHub
    @EnvironmentObject var store: StoreManager
    @State private var showCalibration = false
    @State private var nudgeResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isPlus { Label("Snoredle Plus actief", systemImage: "checkmark.seal.fill") }
                    else { NavigationLink("Snoredle Plus") { PaywallView() } }
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

                Section("Opnames") {
                    Toggle("Snurkfragmenten bewaren", isOn: $s.saveClips)
                    Stepper("Max. \(s.maxClipsPerNight) per nacht", value: $s.maxClipsPerNight, in: 5...200, step: 5)
                    Stepper("Bewaar \(s.keepClipsDays) dagen", value: $s.keepClipsDays, in: 3...365, step: 1)
                    Text("Favorieten worden nooit automatisch verwijderd.").font(.caption).foregroundStyle(.secondary)
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

                Section("Over") {
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

    var position: SleepPosition? { step < SleepPosition.calibratable.count ? SleepPosition.calibratable[step] : nil }

    var body: some View {
        VStack(spacing: 24) {
            Text("Kalibratie").font(.largeTitle.bold())
            if let p = position {
                Image(systemName: p.symbol).font(.system(size: 64)).foregroundStyle(Theme.accent)
                Text("Ga op je \(p.label.lowercased()) liggen, zoals je slaapt, met je watch om.")
                    .multilineTextAlignment(.center)
                if countdown > 0 {
                    Text("\(countdown)").font(.system(size: 60, weight: .bold)).monospacedDigit()
                } else {
                    Button("Ik lig klaar") { run(p) }.buttonStyle(.borderedProminent)
                }
                if hub.profile.vectors[p] != nil { Text("✓ gemeten").foregroundStyle(.green) }
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text("Klaar! Je watch herkent nu je slaaphoudingen.")
                Button("Sluiten") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .presentationDetents([.medium])
    }

    private func run(_ p: SleepPosition) {
        countdown = 10
        // De watch meet de laatste 5 s van de 10 s; zo kan je eerst stil gaan liggen.
        Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
                if countdown == 5 { hub.calibrate(p) }
            }
            try? await Task.sleep(for: .seconds(1))
            step += 1
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
