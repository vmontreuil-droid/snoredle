import Foundation
import MetricKit

/// Vangt crashrapporten van iOS op (MetricKit levert ze bij de volgende start)
/// en zet de belangrijkste info in het diagnoselogboek: welk soort crash en waar in de code.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    func start() {
        MXMetricManager.shared.add(self)
        // Rapporten die al klaarstaan (van vorige crashes) meteen verwerken.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] { report(c) }
            for h in p.hangDiagnostics ?? [] {
                DiagLog.shared.log("CRASH", "app hing \(h.hangDuration) · versie \(h.metaData.applicationBuildVersion)")
            }
        }
    }

    private func report(_ c: MXCrashDiagnostic) {
        let m = c.metaData
        var parts = ["build \(m.applicationBuildVersion)"]
        if let t = c.exceptionType { parts.append("type \(t)") }
        if let s = c.signal { parts.append("signaal \(s)") }
        if let r = c.terminationReason { parts.append("reden: \(r)") }
        if let e = c.exceptionReason { parts.append("uitzondering: \(e.exceptionName) – \(e.composedMessage)") }
        DiagLog.shared.log("CRASH", parts.joined(separator: " · "))
        // Bovenste regels van de gecrashte thread (adressen in Snoredle, om te symboliseren).
        if let json = try? JSONSerialization.jsonObject(with: c.callStackTree.jsonRepresentation()) as? [String: Any],
           let stacks = json["callStacks"] as? [[String: Any]],
           let crashed = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first,
           let roots = crashed["callStackRootFrames"] as? [[String: Any]] {
            var frames: [String] = []
            var frame: [String: Any]? = roots.first
            while let f = frame, frames.count < 25 {
                let bin = f["binaryName"] as? String ?? "?"
                let off = f["offsetIntoBinaryTextSegment"] as? Int ?? 0
                let uuid = (f["binaryUUID"] as? String).map { String($0.prefix(8)) } ?? ""
                frames.append("\(bin)+\(off) [\(uuid)]")
                frame = (f["subFrames"] as? [[String: Any]])?.first
            }
            DiagLog.shared.log("CRASH", "stapel: " + frames.joined(separator: " ← "))
        }
    }
}
