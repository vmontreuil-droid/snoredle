import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            step(icon: "moon.zzz.fill", title: "Ontdek hoe je slaapt",
                 text: "Leg je iPhone naast je bed, aan de lader. Snoredle herkent snurken en laat je 's ochtends horen hoe je nacht was.",
                 button: "Verder") { page = 1 }.tag(0)

            step(icon: "mic.fill", title: "Microfoon",
                 text: "Alles wordt op je toestel geanalyseerd. Er gaat geen audio naar het internet.",
                 button: "Microfoon toestaan") {
                AVAudioApplication.requestRecordPermission { _ in DispatchQueue.main.async { page = 2 } }
            }.tag(1)

            step(icon: "applewatch", title: "Slaaphouding via je watch",
                 text: "Met de Apple Watch meet Snoredle of je op je rug of zij ligt, je hartslag, en geeft een zacht tikje als je op je rug snurkt. Andere watches kunnen hartslag en SpO₂ via Gezondheid of Bluetooth delen.",
                 button: "Gezondheid koppelen") {
                Task { try? await HealthKitService.shared.requestAuthorization(); page = 3 }
            }.tag(2)

            step(icon: "stethoscope", title: "Belangrijk",
                 text: "Snoredle is geen medisch hulpmiddel en stelt geen diagnose. Word je moe wakker, stopt je ademhaling 's nachts of zegt je partner dat je naar adem hapt? Praat erover met je huisarts.",
                 button: "Begrijpen, start") { settings.didOnboard = true }.tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(NightBackground())
    }

    private func step(icon: String, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon).font(.system(size: 72)).foregroundStyle(Theme.accent)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            Spacer().frame(height: 40)
        }.padding(32)
    }
}
