# Snoredle — snurk-app voor iPhone + Apple Watch

Naam: **Snoredle**. Hernoemen: `APP_NAME` en `bundleIdPrefix` in `project.yml`.

## Opstarten

1. Mac met Xcode 15.4 of nieuwer, en een Apple Developer-account (€99/jaar).
2. `brew install xcodegen`
3. In deze map: `xcodegen generate` → open `Snoredle.xcodeproj`
4. Vul je Team ID in (`DEVELOPMENT_TEAM` in `project.yml` of in Xcode → Signing).
5. Run het schema **Snoredle** op je iPhone; de watch-app wordt mee geïnstalleerd.
6. Testen van aankopen: maak in Xcode een StoreKit Configuration File met de 3 product-ID's uit `StoreManager.swift`.

> De code is geschreven maar nog niet gecompileerd (dat kan alleen op een Mac). Reken op een handvol kleine compilerfouten bij de eerste build.

## Wat zit erin

| Onderdeel | Bestand |
|---|---|
| Snurkdetectie (Apple SoundAnalysis, label "snoring") + dB-meting | `iOS/Audio/SnoreDetector.swift` |
| Fragmenten met 4 s voorloop, max. per nacht, auto-opruimen | `iOS/Audio/ClipRecorder.swift` |
| Nacht-logica: episodes, intensiteit, tikjes, mogelijke ademstops | `iOS/Services/SessionManager.swift` |
| Snurkscore, houding-statistiek, inzichten (factoren/middelen) | `iOS/Analysis/SnoreAnalysis.swift` |
| Alle instelbare parameters | `iOS/Services/AppSettings.swift` |
| Watch-abstractie (meerdere watches tegelijk) | `iOS/Wearables/WearableProvider.swift` |
| Apple Watch-koppeling | `iOS/Wearables/AppleWatchProvider.swift` |
| Andere watches via Apple Gezondheid | `iOS/Wearables/HealthKitService.swift` |
| Andere watches via Bluetooth-hartslag (0x180D) | `iOS/Wearables/BluetoothHeartRateProvider.swift` |
| Watch: houding, hartslag, beweging, tikjes, kalibratie | `Watch/NightTracker.swift` |
| Abonnementen (StoreKit 2) | `iOS/Services/StoreManager.swift` |
| CSV + PDF-rapport voor de arts | `iOS/Services/ExportService.swift` |
| Schermen | `iOS/Views/` |

## Hoe de slaaphouding werkt

De watch meet de richting van de zwaartekracht. Bij kalibratie lig je 10 s in elke houding (rug, links, rechts, buik); daarna wordt elke meting vergeleken met die 4 referenties (kleinste hoek wint). Zonder kalibratie geldt een standaardprofiel.
Let op: een pols is geen romp — als je arm anders ligt dan bij kalibratie, kan de houding verkeerd zijn. Kalibratie per persoon maakt het veel beter; het betrouwbaarheidscijfer (`confidence`) wordt meebewaard.

## Bekende aandachtspunten

- **Watch 's nachts actief houden** gebeurt via een `HKWorkoutSession` (die wordt niet bewaard). Apple aanvaardt dit bij slaap-apps, maar leg het uit in de review-notities.
- **Batterij**: ± 15–25% op de watch per nacht; iPhone moet aan de lader.
- **Medische claims**: zeg nooit dat de app slaapapneu detecteert of diagnosticeert. Dan wordt het een medisch hulpmiddel (EU MDR) en heb je CE-certificatie nodig. "Mogelijke ademstops" staat er bewust met disclaimer.
