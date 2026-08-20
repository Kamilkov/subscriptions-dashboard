// Snapshot model + codec + App Group hand-off, compiled into both the app and
// the widget extension. The app (unsandboxed) polls and writes latest.json;
// the widget (always sandboxed, no credential access) only reads it.
import Foundation

// "gemini" (gemini-cli quota) retired 2026-08, implementation removed
// 2026-08-20 — revive from git history if gemini-cli ever comes back.
let services = ["claude", "codex", "cursor", "antigravity", "copilot"]
let appGroupID = "JXGJ4K9KR9.group.com.kamilkovac.usagebar"

struct HistorySnapshot: Sendable {
    var tsEpoch: Double
    var lanes: [String: [String: Limit]]  // service -> label -> limit
    // Shared-snapshot-only freshness metadata (empty in history records): the
    // widget must show WHICH provider is stale and why, not just an aggregate age.
    var fetchedAt: [String: Double] = [:]  // service -> epoch of last successful fetch
    var errors: [String: String] = [:]     // service -> FetchError.category of last failure
    var pinned: String? = nil              // user-pinned "svc.label" for the single-number displays
}

// Deterministic (sorted) failure summary; names EVERY failing provider — the
// widget wraps it rather than dropping providers off the end.
func errorSummary(_ errors: [String: String]) -> String? {
    errors.isEmpty ? nil :
        "⚠ " + errors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
}

enum Snapshot {
    static func encode(_ snap: HistorySnapshot) -> [String: Any] {
        var rec: [String: Any] = ["ts": snap.tsEpoch]
        if !snap.fetchedAt.isEmpty { rec["fetched"] = snap.fetchedAt }
        if !snap.errors.isEmpty { rec["errors"] = snap.errors }
        if let pinned = snap.pinned { rec["pinned"] = pinned }
        for (svc, lanes) in snap.lanes {
            rec[svc] = lanes.mapValues { l in
                var d: [String: Any] = ["pct": l.pct, "reset_at": l.resetEpoch,
                                        "window_seconds": l.windowSeconds, "blocked": l.blocked]
                if let name = l.name { d["name"] = name }
                return d
            }
        }
        return rec
    }

    static func decode(_ rec: [String: Any]) -> HistorySnapshot? {
        guard let ts = (rec["ts"] as? NSNumber)?.doubleValue else { return nil }
        var lanes: [String: [String: Limit]] = [:]
        for svc in services {
            guard let raw = rec[svc] as? [String: [String: Any]] else { continue }
            var out: [String: Limit] = [:]
            for (label, l) in raw {
                guard let pct = (l["pct"] as? NSNumber)?.doubleValue,
                      let reset = (l["reset_at"] as? NSNumber)?.doubleValue,
                      let ws = (l["window_seconds"] as? NSNumber)?.doubleValue else { continue }
                out[label] = Limit(pct: pct, resetEpoch: reset, windowSeconds: ws,
                                   blocked: (l["blocked"] as? Bool) ?? false,
                                   name: l["name"] as? String)
            }
            if !out.isEmpty { lanes[svc] = out }
        }
        let fetched = (rec["fetched"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        let errors = (rec["errors"] as? [String: String]) ?? [:]
        return HistorySnapshot(tsEpoch: ts, lanes: lanes, fetchedAt: fetched, errors: errors,
                               pinned: rec["pinned"] as? String)
    }

    // containerURL needs the app-group entitlement; the unsandboxed app can
    // fall back to the literal Group Containers path.
    // Stored (not computed) so tests can point it into a temp dir — every
    // Store.refresh ends in writeShared, which must never touch the user's
    // real App Group latest.json from a test. nonisolated(unsafe): the widget
    // target only reads it, and only tests ever reassign (on the main actor).
    nonisolated(unsafe) static var sharedURL: URL = {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(appGroupID)")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent("latest.json")
    }()

    static func writeShared(_ snap: HistorySnapshot) {
        guard let data = try? JSONSerialization.data(withJSONObject: encode(snap)) else { return }
        try? data.write(to: sharedURL, options: .atomic)
    }

    static func readShared() -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: sharedURL),
              let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return decode(rec)
    }
}
