import SwiftUI
import LocalAuthentication

/// Vergrendelt Snoredle met Face ID / Touch ID (of de toegangscode als terugval),
/// zodat anderen op je telefoon je nachten en opnames niet kunnen zien.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @AppStorage("appLockEnabled") var enabled = false
    @AppStorage("appLockGraceSeconds") var graceSeconds = 0     // 0 = meteen opnieuw vergrendelen
    @Published private(set) var isLocked = false
    @Published var obscured = false                              // privacyscherm in de app-wisselaar
    private var backgroundedAt: Date?
    private var authenticating = false

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "toegangscode"
        }
    }

    var biometrySymbol: String {
        biometryName == "Touch ID" ? "touchid" : (biometryName == "toegangscode" ? "lock.fill" : "faceid")
    }

    func appLaunched() {
        if enabled { isLocked = true; Task { await unlock() } }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = .now
            if enabled { obscured = true }
        case .inactive:
            if enabled { obscured = true }
        case .active:
            obscured = false
            guard enabled, !authenticating else { return }
            if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(graceSeconds) {
                isLocked = true
            }
            backgroundedAt = nil
            if isLocked { Task { await unlock() } }
        @unknown default: break
        }
    }

    func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Annuleer"
        var error: NSError?
        // deviceOwnerAuthentication = Face ID, met toegangscode als terugval.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false     // geen toegangscode ingesteld: niet buitensluiten
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Ontgrendel Snoredle om je nachten te bekijken")
            if ok { withAnimation(.snappy) { isLocked = false } }
        } catch {
            // Geannuleerd: vergrendeld blijven, knop om opnieuw te proberen.
        }
    }

    /// Bij het aanzetten meteen bevestigen dat het werkt.
    func enable(_ on: Bool) async -> Bool {
        guard on else { enabled = false; return true }
        let ctx = LAContext()
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                localizedReason: "Bevestig om de vergrendeling aan te zetten")) ?? false
        enabled = ok
        return ok
    }
}

/// Scherm over de app zolang hij vergrendeld is (of in de app-wisselaar staat).
struct LockScreen: View {
    @ObservedObject var lock = AppLock.shared

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 22) {
                Spacer()
                MoonMark().frame(width: 84, height: 84)
                Text("Snoredle").font(.system(size: 34, weight: .bold, design: .rounded))
                if lock.isLocked {
                    Text("Vergrendeld").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label("Ontgrendel met \(lock.biometryName)", systemImage: lock.biometrySymbol)
                            .font(.headline).foregroundStyle(Theme.night)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(Theme.accent, in: Capsule())
                    }
                    .padding(.horizontal, 28)
                    Spacer().frame(height: 40)
                } else {
                    Spacer()
                }
            }
            .foregroundStyle(.white)
        }
        .transition(.opacity)
    }
}
