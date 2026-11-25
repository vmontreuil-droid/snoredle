import StoreKit

/// Freemium: gratis basis, "Snoredle Plus" als abonnement of levenslang.
/// Maak deze product-ID's aan in App Store Connect (of in Snoredle.storekit om te testen).
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    static let productIDs = ["be.snoredle.plus.monthly", "be.snoredle.plus.yearly", "be.snoredle.plus.lifetime"]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPlus = StoreManager.isTestFlight   // meteen, niet pas na laden
    private var updates: Task<Void, Never>?

    /// Wat zit er in Plus?
    static let plusFeatures = [
        "Onbeperkte geschiedenis (gratis: 7 nachten)",
        "Alle snurkfragmenten bewaren en exporteren",
        "Slaaphouding en tikjes via je watch",
        "Inzichten: welke factoren en middelen werken",
        "Hartslag, SpO₂ en ademhaling uit Gezondheid",
        "PDF-rapport voor je arts",
    ]

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish(); await self?.refresh() }
            }
        }
        Task { await load(); await refresh() }
    }

    func load() async {
        products = (try? await Product.products(for: Self.productIDs))?.sorted { $0.price < $1.price } ?? []
    }

    /// TestFlight-versies krijgen alles gratis, zodat testers alles kunnen proberen.
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    func refresh() async {
        if Self.isTestFlight { isPlus = true; return }
        var plus = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil { plus = true }
        }
        isPlus = plus
    }

    func buy(_ p: Product) async throws {
        if case .success(.verified(let t)) = try await p.purchase() {
            await t.finish(); await refresh()
        }
    }

    func restore() async { try? await AppStore.sync(); await refresh() }
}
