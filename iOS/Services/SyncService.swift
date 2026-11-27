import Foundation
import SwiftData
import Security
import UIKit

/// Instellingen van het portaal. De "anon key" van Supabase is openbaar bedoeld:
/// de beveiliging zit in de database (elke gebruiker ziet enkel zijn eigen rijen).
enum SyncConfig {
    static let supabaseURL = "https://YOUR-PROJECT.supabase.co"
    static let anonKey = "YOUR-ANON-KEY"
    static let portalURL = URL(string: "https://snoredle.netlify.app")!
    static var isConfigured: Bool { !supabaseURL.contains("YOUR-PROJECT") && !anonKey.contains("YOUR-") }
}

/// Synchroniseert nachten naar het Snoredle-portaal (Supabase). Zonder SDK: gewone REST-oproepen.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    struct Session: Codable { var accessToken: String; var refreshToken: String; var expiresAt: Date; var userID: String; var email: String }

    @Published private(set) var session: Session?
    @Published private(set) var busy = false
    @Published var status: String?
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "sync.last") as? Date
    /// Uitdrukkelijke toestemming voor het verwerken van gezondheidsgegevens (AVG art. 9).
    @Published var consent: Bool = UserDefaults.standard.bool(forKey: "sync.consent") {
        didSet { UserDefaults.standard.set(consent, forKey: "sync.consent") }
    }

    var isSignedIn: Bool { session != nil }
    var enabled: Bool { SyncConfig.isConfigured && isSignedIn && consent }

    private init() { session = Keychain.load() }

    // MARK: Aanmelden met code per e-mail

    func sendCode(to email: String) async -> Bool {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard mail.contains("@") else { status = "Geef een geldig e-mailadres."; return false }
        busy = true; defer { busy = false }
        let ok = await post("/auth/v1/otp", ["email": mail, "create_user": true], auth: false) != nil
        status = ok ? "We stuurden een code naar \(mail)." : "Code versturen mislukt. Probeer later opnieuw."
        return ok
    }

    func verify(email: String, code: String) async -> Bool {
        busy = true; defer { busy = false }
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard let json = await post("/auth/v1/verify", ["type": "email", "email": mail, "token": code.trimmingCharacters(in: .whitespaces)], auth: false),
              let s = parseSession(json, email: mail) else {
            status = "Code klopt niet of is verlopen."; return false
        }
        session = s; Keychain.save(s)
        status = "Aangemeld als \(mail)."
        DiagLog.shared.log("portaal", "aangemeld")
        if consent { await saveConsent() }
        return true
    }

    func signOut() {
        session = nil; Keychain.clear()
        status = "Afgemeld. Je gegevens in het portaal blijven bewaard."
    }

    func saveConsent() async {
        guard let s = session else { return }
        _ = await request("POST", "/rest/v1/profiles", body: [["user_id": s.userID, "consent_at": ISO8601DateFormatter().string(from: .now)]],
                          headers: ["Prefer": "resolution=merge-duplicates"])
    }

    // MARK: Synchroniseren

    /// Stuurt nachten door die nog niet (of gewijzigd) in het portaal staan.
    func syncPending(context: ModelContext, force: Bool = false) async {
        guard enabled, !busy else { return }
        let all = (try? context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let recentLimit = Date().addingTimeInterval(-3 * 86_400)
        let todo = all.filter { s in
            guard let end = s.end else { return false }
            if force { return true }
            guard let synced = s.syncedAt else { return true }
            return end > recentLimit && synced < Date().addingTimeInterval(-600)   // recente nachten: bewerkingen meenemen
        }
        guard !todo.isEmpty else { return }
        busy = true; defer { busy = false }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "sync")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        var sent = 0
        for chunk in stride(from: 0, to: todo.count, by: 5).map({ Array(todo[$0..<min($0 + 5, todo.count)]) }) {
            let rows = chunk.map(Self.row)
            if await request("POST", "/rest/v1/nights", body: rows, headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]) != nil {
                for s in chunk { s.syncedAt = .now }
                sent += chunk.count
            } else {
                status = "Synchroniseren mislukt (geen internet?). Wordt later opnieuw geprobeerd."
                break
            }
        }
        try? context.save()
        if sent > 0 {
            lastSync = .now; UserDefaults.standard.set(lastSync, forKey: "sync.last")
            status = "\(sent) \(sent == 1 ? "nacht" : "nachten") naar het portaal gestuurd."
            DiagLog.shared.log("portaal", "\(sent) nacht(en) gesynchroniseerd")
        }
    }

    /// Wist alle nachten in het portaal (de app houdt ze).
    func deleteCloudData(context: ModelContext) async -> Bool {
        guard let s = session else { return false }
        busy = true; defer { busy = false }
        let ok = await request("DELETE", "/rest/v1/nights?user_id=eq.\(s.userID)", body: nil) != nil
        if ok {
            for n in (try? context.fetch(FetchDescriptor<SleepSession>())) ?? [] { n.syncedAt = nil }
            try? context.save()
            consent = false
            status = "Al je gegevens in het portaal zijn gewist."
        }
        return ok
    }

    /// Wist het account en alles in het portaal (recht op vergetelheid).
    func deleteAccount(context: ModelContext) async -> Bool {
        busy = true; defer { busy = false }
        guard await request("POST", "/rest/v1/rpc/delete_my_account", body: [String: String]()) != nil else {
            status = "Account wissen mislukt."; return false
        }
        for n in (try? context.fetch(FetchDescriptor<SleepSession>())) ?? [] { n.syncedAt = nil }
        try? context.save()
        consent = false
        signOut()
        status = "Je account en alle gegevens in het portaal zijn gewist."
        return true
    }

    // MARK: Gegevens van één nacht

    static func row(_ s: SleepSession) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func t(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }       // ms, compact
        // Hartslag e.d.: hoogstens één waarde per minuut per soort.
        var vit: [String: (Double, Int, Date)] = [:]
        for v in s.vitals {
            let k = "\(v.kind.rawValue)-\(Int(v.at.timeIntervalSince1970 / 60))"
            if let o = vit[k] { vit[k] = (o.0 + v.value, o.1 + 1, o.2) } else { vit[k] = (v.value, 1, v.at) }
        }
        var vitals: [String: [[Double]]] = [:]
        for (k, v) in vit {
            let kind = String(k.split(separator: "-").first ?? "")
            vitals[kind, default: []].append([t(v.2), (v.0 / Double(v.1) * 10).rounded() / 10])
        }
        for k in vitals.keys { vitals[k]?.sort { $0[0] < $1[0] } }

        let summary: [String: Any] = [
            "score": s.snoreScore,
            "sleepMin": Int(s.sleepDuration / 60),
            "snoreMin": Int(s.snoreMinutes), "snorePct": (s.snorePercentage * 1000).rounded() / 10,
            "loudMin": Int(s.loudSnoreMinutes), "epicMin": Int(s.epicSnoreMinutes),
            "episodes": s.events.count, "nudges": s.nudgeCount, "apnea": s.possibleApneaEvents,
            "avgDb": Int(s.averageDecibel), "peakDb": Int(s.peakDecibel),
            "outOfBed": s.outOfBed.count, "sounds": s.nightSounds.count,
            "factors": s.factorsRaw, "remedies": s.remediesRaw,
            "rating": s.rating as Any, "note": s.note, "alarmNote": s.alarmNote as Any,
            "wearable": s.wearableName as Any, "title": s.nightTitle,
            "positions": SnoreAnalysis.positionStats(s).map { ["p": $0.position.rawValue, "min": Int($0.minutes), "snoreMin": Int($0.snoreMinutes)] },
        ]
        let detail: [String: Any] = [
            "loudness": s.nightLoudness.sorted { $0.at < $1.at }.map { [t($0.at), ($0.decibel * 10).rounded() / 10] },
            "events": s.events.sorted { $0.start < $1.start }.map {
                ["s": t($0.start), "e": t($0.end), "i": $0.intensity.rawValue, "db": Int($0.peakDecibel),
                 "p": $0.position.rawValue, "n": $0.wasNudged, "partner": $0.isPartner] as [String: Any] },
            "positions": s.positions.sorted { $0.at < $1.at }.map { [t($0.at), $0.position.rawValue] as [Any] },
            "vitals": vitals,
            "stages": s.stages.sorted { $0.start < $1.start }.map { ["s": t($0.start), "e": t($0.end), "st": $0.stage.rawValue] as [String: Any] },
            "sounds": s.nightSounds.sorted { $0.start < $1.start }.map {
                ["s": t($0.start), "e": t($0.end), "k": $0.kind.rawValue, "tx": $0.transcript as Any] as [String: Any] },
            "outOfBed": s.outOfBed.map { ["s": t($0.start), "e": t($0.end), "steps": $0.steps, "alert": $0.alerted] as [String: Any] },
            "pauses": s.pauses.map { [t($0.start), t($0.end)] },
        ]
        var row: [String: Any] = [
            "id": s.id.uuidString.lowercased(),
            "start_at": iso.string(from: s.start),
            "summary": summary, "detail": detail,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        ]
        if let e = s.end { row["end_at"] = iso.string(from: e) }
        return row
    }

    // MARK: HTTP

    private func parseSession(_ json: [String: Any], email: String) -> Session? {
        guard let at = json["access_token"] as? String, let rt = json["refresh_token"] as? String,
              let exp = json["expires_in"] as? Double,
              let user = json["user"] as? [String: Any], let id = user["id"] as? String else { return nil }
        return Session(accessToken: at, refreshToken: rt, expiresAt: Date().addingTimeInterval(exp - 60), userID: id,
                       email: (user["email"] as? String) ?? email)
    }

    private func validToken() async -> String? {
        guard var s = session else { return nil }
        if s.expiresAt > .now { return s.accessToken }
        guard let json = await post("/auth/v1/token?grant_type=refresh_token", ["refresh_token": s.refreshToken], auth: false),
              let n = parseSession(json, email: s.email) else {
            DiagLog.shared.log("portaal", "aanmelding verlopen → opnieuw aanmelden nodig")
            status = "Je aanmelding is verlopen. Meld je opnieuw aan."
            session = nil; Keychain.clear(); return nil
        }
        s = n; session = s; Keychain.save(s)
        return s.accessToken
    }

    private func post(_ path: String, _ body: [String: Any], auth: Bool) async -> [String: Any]? {
        guard let data = await request("POST", path, body: body, needsAuth: auth) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Geeft de antwoorddata terug (leeg bij 204), of nil bij een fout.
    @discardableResult
    private func request(_ method: String, _ path: String, body: Any?, headers: [String: String] = [:], needsAuth: Bool = true) async -> Data? {
        guard SyncConfig.isConfigured, let url = URL(string: SyncConfig.supabaseURL + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue(SyncConfig.anonKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if needsAuth {
            guard let token = await validToken() else { return nil }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                DiagLog.shared.log("portaal", "\(method) \(path.prefix(40)) → \(code) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
                return nil
            }
            return data
        } catch {
            DiagLog.shared.log("portaal", "\(method) \(path.prefix(40)) mislukt: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Aanmelding veilig bewaren in de sleutelhanger (blijft na herstart, ook als het toestel vergrendeld is).
private enum Keychain {
    static let key = "be.snoredle.portal.session"
    static func save(_ s: SyncService.Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        clear()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> SyncService.Session? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(SyncService.Session.self, from: d)
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }
}
