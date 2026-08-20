// App state: one poll loop, per-service status, JSONL history (60-day
// retention) in ~/Library/Application Support/UsageBar/.
import AppKit
import Foundation
import Observation
import UserNotifications
import WidgetKit

let pollSeconds: Double = 20 * 60
let freshSeconds: Double = 60
let historyDays = 60

struct ServiceState: Sendable {
    var status = "never"          // never | fresh | stale
    var fetchedAt: Double?
    var error: FetchError?
    var lanes: [String: Limit] = [:]
}

@MainActor
@Observable
final class Store {
    var states: [String: ServiceState] = Dictionary(uniqueKeysWithValues: services.map { ($0, ServiceState()) })
    var history: [HistorySnapshot] = []
    var lastPoll: Double = 0
    private var polling = false
    private var inFlight: Set<String> = []    // services the current poll covers
    private var pendingOnly: Set<String> = []  // requested mid-poll, not covered
    private var pollTask: Task<Void, Never>?

    // Regular-app mode (Dock, Cmd-Tab, window chrome) is on while ANY content
    // window is open; back to menu-bar accessory only when the last one closes.
    // Counted, so closing one of two open windows doesn't drop the other.
    private var openWindows = 0
    func enterRegular() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func leaveRegular() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    private static let enabledKey = "enabledServices"
    var enabled: Set<String> = {
        UserDefaults.standard.stringArray(forKey: enabledKey).map(Set.init) ?? Set(services)
    }()

    func setEnabled(_ svc: String, _ on: Bool) {
        if on { enabled.insert(svc) } else { enabled.remove(svc) }
        UserDefaults.standard.set(Array(enabled), forKey: Self.enabledKey)
        if on {
            Task { await refresh(only: [svc]) }  // fetch just the new provider
        } else {
            publishShared()  // hide it everywhere without refetching anything
        }
    }

    var enabledServices: [String] { services.filter(enabled.contains) }

    private static let bucketsKey = "enabledBuckets"
    var enabledBuckets: Set<String> = {
        UserDefaults.standard.stringArray(forKey: bucketsKey).map(Set.init)
            ?? Set(Bucket.allCases.map(\.rawValue))
    }()

    func setBucket(_ bucket: Bucket, _ on: Bool) {
        if on { enabledBuckets.insert(bucket.rawValue) } else { enabledBuckets.remove(bucket.rawValue) }
        UserDefaults.standard.set(Array(enabledBuckets), forKey: Self.bucketsKey)
        publishShared()  // display-only filter; nothing to fetch
    }

    func bucketEnabled(_ limit: Limit) -> Bool {
        enabledBuckets.contains(Bucket(windowSeconds: limit.windowSeconds).rawValue)
    }

    // Which lane's percentage the menu bar and small widget show; nil = the
    // automatic worst-lane rule. Format "svc.label", e.g. "claude.weekly_all".
    var pinnedLane: String? = UserDefaults.standard.string(forKey: "pinnedLane")

    func setPinnedLane(_ id: String?) {
        pinnedLane = id
        if let id { UserDefaults.standard.set(id, forKey: "pinnedLane") }
        else { UserDefaults.standard.removeObject(forKey: "pinnedLane") }
        publishShared()  // the small widget follows the same selection
    }

    // User text-size multiplier (A− / A+ in the header); scales every size in
    // the board, popover and window alike.
    var fontScale: Double = {
        let v = UserDefaults.standard.double(forKey: "fontScale")
        return v == 0 ? 1.0 : v
    }()

    func adjustFontScale(_ delta: Double) {
        fontScale = min(1.8, max(0.7, ((fontScale + delta) * 10).rounded() / 10))
        UserDefaults.standard.set(fontScale, forKey: "fontScale")
    }

    // Board background tint over the window material, one colour per
    // appearance; hex "RRGGBB", nil = plain material (default). Mirrors the
    // web board's bgLight/bgDark localStorage setting. Values persisted before
    // the contrast rule existed are purged at init, not just rejected on set.
    var boardBgLight: String? = Store.sanitizedBg(key: "boardBgLight", dark: false)
    var boardBgDark: String? = Store.sanitizedBg(key: "boardBgDark", dark: true)

    private static func sanitizedBg(key: String, dark: Bool) -> String? {
        guard let hex = UserDefaults.standard.string(forKey: key) else { return nil }
        guard bgContrastOK(hex, dark: dark) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return hex
    }

    func setBoardBg(dark: Bool, hex: String?) {
        if let hex, !bgContrastOK(hex, dark: dark) { return }  // picker snaps back
        let key = dark ? "boardBgDark" : "boardBgLight"
        if dark { boardBgDark = hex } else { boardBgLight = hex }
        if let hex { UserDefaults.standard.set(hex, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // Weekly-lane grid: "window" = sevenths of the window, "midnight" = local
    // midnights (same modes and persistence key as the web board).
    var gridMode: String = UserDefaults.standard.string(forKey: "gridMode") ?? "window"

    func toggleGridMode() {
        gridMode = gridMode == "midnight" ? "window" : "midnight"
        UserDefaults.standard.set(gridMode, forKey: "gridMode")
    }

    init(startPolling: Bool = true) {
        history = HistoryFile.load()
        seedFromHistory()
        if startPolling {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(force: true)
                    try? await Task.sleep(for: .seconds(pollSeconds))
                }
            }
        }
    }

    // On relaunch, show the last known numbers (marked stale) instead of a blank board.
    private func seedFromHistory() {
        for snap in history.reversed() {
            for svc in services {
                if states[svc]!.lanes.isEmpty, let lanes = snap.lanes[svc], !lanes.isEmpty {
                    states[svc]!.lanes = lanes
                    states[svc]!.status = "stale"
                    states[svc]!.fetchedAt = snap.tsEpoch
                }
            }
        }
    }

    func refresh(force: Bool = false, only: Set<String>? = nil,
                 fetchers: [String: @Sendable () async throws -> [String: Limit]]? = nil) async {
        if polling {
            // Single-flight: the in-flight poll's results serve everyone. Queue
            // only what it is NOT already fetching (a provider enabled mid-poll,
            // or the rest of a full refresh during a partial poll); drained below.
            let requested = only ?? enabled
            pendingOnly.formUnion(requested.intersection(enabled).subtracting(inFlight))
            return
        }
        let now = Date().timeIntervalSince1970
        if only == nil, !force, lastPoll > 0, now - lastPoll < freshSeconds { return }
        polling = true
        await performPoll(wanted: only.map { $0.intersection(enabled) } ?? enabled,
                          only: only, fetchers: fetchers)
        polling = false
        while !pendingOnly.isEmpty {  // requests that arrived while polling
            let queued = pendingOnly
            pendingOnly = []
            polling = true
            await performPoll(wanted: queued.intersection(enabled), only: queued,
                              fetchers: fetchers)
            polling = false
        }
    }

    private func performPoll(wanted: Set<String>, only: Set<String>?,
                             fetchers fetchersIn: [String: @Sendable () async throws -> [String: Limit]]?) async {
        inFlight = wanted
        defer { inFlight = [] }
        let fetchers = fetchersIn ?? [
            "claude": Providers.fetchClaude, "codex": Providers.fetchCodex,
            "cursor": Providers.fetchCursor,
            "antigravity": Providers.fetchAntigravity,
            "copilot": Providers.fetchCopilot,
        ]
        let results = await withTaskGroup(
            of: (String, Result<[String: Limit], FetchError>).self,
            returning: [String: Result<[String: Limit], FetchError>].self
        ) { group in
            for (name, fetch) in fetchers where wanted.contains(name) {
                group.addTask { (name, await attempt(fetch)) }
            }
            var out: [String: Result<[String: Limit], FetchError>] = [:]
            for await (name, r) in group { out[name] = r }
            return out
        }

        let ts = Date().timeIntervalSince1970
        if only == nil { lastPoll = ts }
        var snap = HistorySnapshot(tsEpoch: ts, lanes: [:])
        for (svc, result) in results {
            switch result {
            case .success(let lanes):
                postAlerts(alertTransitions(svc: svc, old: states[svc]!.lanes,
                                            new: lanes, now: ts))
                states[svc] = ServiceState(status: "fresh", fetchedAt: ts, error: nil, lanes: lanes)
                snap.lanes[svc] = lanes
            case .failure(let err):
                states[svc]!.error = err
                states[svc]!.status = states[svc]!.lanes.isEmpty ? "never" : "stale"
            }
        }
        history.append(snap)
        // Retention holds continuously, not just at startup: drop expired
        // snapshots each poll, compacting the file only when something fell off.
        let cutoff = ts - Double(historyDays) * 86400
        if history.first.map({ $0.tsEpoch < cutoff }) == true {
            history.removeAll { $0.tsEpoch < cutoff }
            HistoryFile.rewrite(history)
        } else {
            HistoryFile.append(snap)
        }
        publishShared()
    }

    // Widget hand-off built from current state, so provider toggles update the
    // widget without any refetch (a Claude fetch means a Keychain prompt).
    private func publishShared() {
        // Stamp with the OLDEST fetchedAt among included services, not lastPoll:
        // a failed provider keeps its old lanes, and the widget's "as of" must
        // never vouch for data older than it says.
        var snap = HistorySnapshot(tsEpoch: 0, lanes: [:])
        var oldest = Double.infinity
        for svc in enabledServices {
            let lanes = states[svc]!.lanes.filter { bucketEnabled($0.value) }
            if !lanes.isEmpty {
                snap.lanes[svc] = lanes
                let fetched = states[svc]!.fetchedAt ?? 0
                snap.fetchedAt[svc] = fetched
                oldest = min(oldest, fetched)
            }
            if let err = states[svc]!.error { snap.errors[svc] = err.category }
        }
        snap.tsEpoch = oldest.isFinite ? oldest : Date().timeIntervalSince1970
        snap.pinned = pinnedLane
        Snapshot.writeShared(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Points inside the limit's current window (last 24h for projections).
    func windowPoints(service: String, label: String, limit: Limit,
                      now: Double, trailing: Double? = nil) -> [(ts: Double, pct: Double)] {
        var start = limit.windowStart
        if let trailing { start = max(start, now - trailing) }
        return history.compactMap { snap in
            guard snap.tsEpoch >= start, snap.tsEpoch <= now,
                  let pct = snap.lanes[service]?[label]?.pct else { return nil }
            return (snap.tsEpoch, pct)
        }
    }

    // Every lane the user can currently see, as ("svc.label", limit) —
    // filtered by provider and bucket toggles, in stable display order.
    func visibleLanes() -> [(id: String, limit: Limit)] {
        enabledServices.flatMap { svc in
            states[svc]!.lanes.filter { bucketEnabled($0.value) }
                .sorted { $0.key < $1.key }
                .map { ("\(svc).\($0.key)", $0.value) }
        }
    }

    // "icon" (gauge + %), "ai" ("AI 39%"), "provider" ("claude 39%").
    var menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle") ?? "icon"

    func setMenuBarStyle(_ style: String) {
        menuBarStyle = style
        UserDefaults.standard.set(style, forKey: "menuBarStyle")
    }

    var menuTitle: String {
        guard let lane = pickTitleLane(pinned: pinnedLane, lanes: visibleLanes(),
                                       now: Date().timeIntervalSince1970) else { return "–" }
        let pct = "\(Int(lane.limit.pct.rounded()))%"
        switch menuBarStyle {
        case "ai": return "AI \(pct)"
        case "provider": return "\(lane.id.split(separator: ".", maxSplits: 1)[0]) \(pct)"
        default: return pct
        }
    }
}

private func attempt(_ op: @Sendable () async throws -> [String: Limit])
    async -> Result<[String: Limit], FetchError> {
    do { return .success(try await op()) }
    catch let e as FetchError { return .failure(e) }
    catch { return .failure(.parse(String(describing: type(of: error)))) }
}

// MARK: - limit alerts

// Deliberately macOS-only (no web-parity counterpart): the app is the always-
// running process, and a browser page can't notify reliably.
private func postAlerts(_ alerts: [LaneAlert]) {
    guard !alerts.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    // No-op after the first grant/denial; denial just means silent alerts.
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }
        for a in alerts {
            let content = UNMutableNotificationContent()
            content.title = a.svc.uppercased()
            content.body = a.message
            center.add(UNNotificationRequest(
                identifier: "\(a.svc).\(a.label).\(Date().timeIntervalSince1970)",
                content: content, trigger: nil))
        }
    }
}

// MARK: - history file

@MainActor
enum HistoryFile {
    // var, not let: tests point this at a temp file so retention checks never
    // touch the user's real Application Support history. MainActor-isolated
    // (only the MainActor Store touches it) so the mutable static is safe.
    static var url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }()

    static func load() -> [HistorySnapshot] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Double(historyDays) * 86400
        let kept = text.split(separator: "\n").compactMap { line -> HistorySnapshot? in
            guard let data = line.data(using: .utf8),
                  let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let snap = Snapshot.decode(rec), snap.tsEpoch >= cutoff else { return nil }
            return snap
        }
        // Rewrite compacted (drops expired + malformed lines).
        rewrite(kept)
        return kept
    }

    static func rewrite(_ snaps: [HistorySnapshot]) {
        let lines = snaps.compactMap { try? JSONSerialization.data(withJSONObject: Snapshot.encode($0)) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ snap: HistorySnapshot) {
        guard let data = try? JSONSerialization.data(withJSONObject: Snapshot.encode(snap)),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
