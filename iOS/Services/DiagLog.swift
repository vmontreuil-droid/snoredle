import Foundation
import SwiftUI

/// Diagnoselogboek: noteert wat er 's nachts gebeurt (watch-seintjes, tikjes, wekker, slim wekken),
/// zodat we achteraf kunnen zien waar iets misloopt. Blijft op het toestel; delen kan via Instellingen.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()
    private let queue = DispatchQueue(label: "be.snoredle.diaglog")
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    // Tellers voor de samenvatting per nacht
    private(set) var heartbeats = 0
    private(set) var nudgesRequested = 0
    private(set) var nudgesDelivered = 0
    private var lastHeartbeatLog = Date.distantPast

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnose.log")
    }

    func log(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: .now)) [\(category)] \(message)\n"
        queue.async {
            let u = self.url
            if let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int), size > 2_000_000 {
                // Oude helft weggooien
                if let d = try? Data(contentsOf: u) { try? d.suffix(1_000_000).write(to: u) }
            }
            // Moderne (throwing) API's: de oude seekToEndOfFile/write laten de app crashen bij een schrijffout.
            if let h = try? FileHandle(forWritingTo: u) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: u)
            }
        }
    }

    func resetCounters() { heartbeats = 0; nudgesRequested = 0; nudgesDelivered = 0 }

    func heartbeat(position: String, movement: Double) {
        heartbeats += 1
        // Niet elk seintje loggen: één keer per minuut is genoeg om te zien dat ze binnenkomen.
        if Date().timeIntervalSince(lastHeartbeatLog) > 60 {
            lastHeartbeatLog = .now
            log("watch", "seintje #\(heartbeats) houding=\(position) beweging=\(String(format: "%.2f", movement))")
        }
    }
    func nudgeRequested(_ how: String) { nudgesRequested += 1; log("tikje", "gevraagd (\(how)) #\(nudgesRequested)") }
    func nudgeDelivered() { nudgesDelivered += 1; log("tikje", "BEVESTIGD door watch #\(nudgesDelivered)") }

    var summary: String {
        "Seintjes van watch: \(heartbeats) · tikjes gevraagd: \(nudgesRequested) · bevestigd: \(nudgesDelivered)"
    }

    func clear() { queue.async { try? FileManager.default.removeItem(at: self.url) } }

    func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "(leeg)" }
}

/// Diagnose-scherm in Instellingen.
struct DiagnoseView: View {
    @State private var content = ""
    @State private var watchText = ""
    @State private var launchResult: String?
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    var body: some View {
        List {
            Section("Versie") { Text(version).monospacedDigit() }
            Section("Deze/vorige nacht") { Text(DiagLog.shared.summary).font(.footnote) }
            Section {
                Text(watchText).font(.footnote)
                Button("Test: start Snoredle op watch") {
                    Task {
                        launchResult = await WearableHub.shared.appleWatch?.testLaunch() ?? "Geen Apple Watch-verbinding"
                        watchText = WearableHub.shared.appleWatch?.diagnosticsText ?? ""
                    }
                }
                if let launchResult { Text(launchResult).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Apple Watch") } footer: {
                Text("Mediavolume iPhone nu: \(Int(NudgeSoundPlayer.systemVolume * 100))%")
            }
            Section {
                ShareLink(item: DiagLog.shared.url) { Label("Logboek delen", systemImage: "square.and.arrow.up") }
                Button("Logboek wissen", role: .destructive) { DiagLog.shared.clear(); content = "(leeg)" }
            } footer: {
                Text("Deel het logboek met de ontwikkelaar om problemen met tikjes, watch of wekker te vinden. Er staan geen opnames in, alleen tijdstippen en meldingen.")
            }
            Section("Laatste regels") {
                Text(content.split(separator: "\n").suffix(150).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnose")
        .onAppear {
            content = DiagLog.shared.text()
            watchText = WearableHub.shared.appleWatch?.diagnosticsText ?? "Geen Apple Watch-verbinding"
        }
    }
}
