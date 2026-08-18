// Domain logic ported 1:1 from dashboard.py — window math, pace, parsers,
// projection. Pure functions, no I/O; verified by UsageBarTests against the
// same fixtures that drive test_dashboard.py.
import Foundation

let weekSeconds: Double = 7 * 24 * 3600

enum FetchError: Error, Sendable {
    case auth(String), network(String), parse(String)

    var category: String {
        switch self {
        case .auth: "auth"
        case .network: "network"
        case .parse: "parse"
        }
    }

    var detail: String {
        switch self {
        case .auth(let d), .network(let d), .parse(let d): d
        }
    }
}

enum Pace: String, Sendable {
    case under, on, over
    // Sort order for the board: worst first.
    var rank: Int { self == .over ? 0 : self == .on ? 1 : 2 }
}

struct Limit: Equatable, Sendable {
    var pct: Double
    var resetEpoch: Double
    var windowSeconds: Double
    var blocked: Bool
    var name: String? = nil  // vendor-provided lane name; nil -> laneName(label)

    var windowStart: Double { resetEpoch - windowSeconds }

    func elapsedPct(now: Double) -> Double {
        max(0, min(100, (now - windowStart) / windowSeconds * 100))
    }
}

func paceBadge(usagePct: Double, elapsed: Double) -> Pace {
    // Burn rate relative to the rate that exactly consumes the window.
    if elapsed < 2.0 { return .on }  // first ~3h of a week: one session skews the ratio
    let rate = usagePct / elapsed
    if rate < 0.85 { return .under }
    if rate > 1.15 { return .over }
    return .on
}

func isoToEpoch(_ s: String) -> Double? {
    // Vendor timestamps carry 6-digit fractional seconds ("…00.009044+00:00"),
    // which ISO8601DateFormatter rejects; drop the fraction (second precision
    // is plenty for reset times).
    var str = s
    if let dot = str.firstIndex(of: ".") {
        let rest = str[str.index(after: dot)...]
        if let tz = rest.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            str = String(str[..<dot]) + String(str[tz...])
        } else {
            str = String(str[..<dot]) + "Z"
        }
    }
    let fmt = ISO8601DateFormatter()
    return fmt.date(from: str)?.timeIntervalSince1970
}

// MARK: - loose-JSON helpers (vendor payloads mix Int/Double/String for numbers)

private func num(_ v: Any?) -> Double? {
    // isFinite: Double("NaN")/"inf" parse successfully, and a non-finite pct
    // traps later in Int(pct.rounded()) — reject at the boundary instead.
    let d: Double? = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    return d?.isFinite == true ? d : nil
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FetchError.parse("response is not a JSON object")
    }
    return obj
}

// MARK: - Claude

// Severity values that mean the limit is actually enforced, not just warned.
private let hardSeverity: Set<String> = ["critical", "exceeded", "blocked", "over_limit", "limit_reached", "throttled"]

private func severityBlocked(_ entry: [String: Any]) -> Bool {
    hardSeverity.contains(((entry["severity"] as? String) ?? "").lowercased())
}

func parseClaude(_ data: Data) throws -> [String: Limit] {
    let payload = try jsonObject(data)
    guard let limits = payload["limits"] as? [[String: Any]] else {
        throw FetchError.parse("claude payload: no limits array")
    }
    var out: [String: Limit] = [:]
    for entry in limits {
        let group = entry["group"] as? String
        let kind = entry["kind"] as? String
        guard let pct = num(entry["percent"]) else { continue }
        if group == "session", kind == "session",
           let resets = entry["resets_at"] as? String, let epoch = isoToEpoch(resets) {
            out["session"] = Limit(pct: pct, resetEpoch: epoch, windowSeconds: 5 * 3600,
                                   blocked: severityBlocked(entry))
            continue
        }
        guard group == "weekly", let k = kind, k == "weekly_all" || k == "weekly_scoped",
              let resets = entry["resets_at"] as? String, let epoch = isoToEpoch(resets) else { continue }
        // Vendor lane name when present ("Fable"); scope has been a bare
        // string ("opus") and an object — tolerate both, nil -> static label.
        var name: String? = nil
        if let scope = entry["scope"] as? [String: Any],
           let dn = (scope["model"] as? [String: Any])?["display_name"] as? String, !dn.isEmpty {
            name = "Weekly - \(dn)"
        }
        out[k] = Limit(pct: pct, resetEpoch: epoch, windowSeconds: weekSeconds,
                       blocked: severityBlocked(entry), name: name)
    }
    guard out["weekly_all"] != nil else {
        throw FetchError.parse("claude payload: no weekly_all limit")
    }
    return out
}

// MARK: - Codex

private func codexWindow(_ w: [String: Any], rlBlocked: Bool) throws -> Limit {
    guard let pct = num(w["used_percent"]), let reset = num(w["reset_at"]),
          let ws = num(w["limit_window_seconds"]) else {
        throw FetchError.parse("codex payload: malformed window")
    }
    // "blocked" only when the vendor flags the rate limit AND this window is
    // the one actually exhausted — so a full 5h window doesn't blame the weekly lane.
    return Limit(pct: pct, resetEpoch: reset, windowSeconds: ws,
                 blocked: rlBlocked && pct >= 100.0)
}

private func rlBlocked(_ rateLimit: [String: Any]) -> Bool {
    if let reached = rateLimit["limit_reached"] as? Bool, reached { return true }
    if let allowed = rateLimit["allowed"] as? Bool, !allowed { return true }
    return false
}

private func windows(of rateLimit: [String: Any]) -> [[String: Any]] {
    [rateLimit["primary_window"], rateLimit["secondary_window"]].compactMap { $0 as? [String: Any] }
}

// The backend has been observed serving the 7-day window as either slot;
// identify by limit_window_seconds, never by slot name.
private func pickWeeklyWindow(_ rateLimit: [String: Any]) -> [String: Any]? {
    let wins = windows(of: rateLimit)
    if let exact = wins.first(where: { num($0["limit_window_seconds"]) == 604800 }) { return exact }
    let longish = wins.filter { (num($0["limit_window_seconds"]) ?? 0) >= 6 * 86400 }
    return longish.max { (num($0["limit_window_seconds"]) ?? 0) < (num($1["limit_window_seconds"]) ?? 0) }
}

// Account-level rolling window (5h). Per-model rolling windows are ignored.
private func pickRollingWindow(_ rateLimit: [String: Any]) -> [String: Any]? {
    let sub = windows(of: rateLimit).filter {
        if let ws = num($0["limit_window_seconds"]) { return ws > 0 && ws < 21600 }
        return false
    }
    return sub.min { (num($0["limit_window_seconds"]) ?? 0) < (num($1["limit_window_seconds"]) ?? 0) }
}

func parseCodex(_ data: Data) throws -> [String: Limit] {
    let payload = try jsonObject(data)
    guard let rl = payload["rate_limit"] as? [String: Any] else {
        throw FetchError.parse("codex payload: no rate_limit")
    }
    guard let weekly = pickWeeklyWindow(rl) else {
        throw FetchError.parse("codex payload: no weekly window")
    }
    let acctBlocked = rlBlocked(rl)
    var out = ["weekly": try codexWindow(weekly, rlBlocked: acctBlocked)]
    if let rolling = pickRollingWindow(rl) {
        out["rolling"] = try codexWindow(rolling, rlBlocked: acctBlocked)
    }
    for extra in (payload["additional_rate_limits"] as? [[String: Any]]) ?? [] {
        let erl = (extra["rate_limit"] as? [String: Any]) ?? [:]
        if let mw = pickWeeklyWindow(erl) {
            let name = (extra["limit_name"] as? String) ?? "unnamed"
            out["model:\(name)"] = try codexWindow(mw, rlBlocked: rlBlocked(erl))
        }
    }
    return out
}

// MARK: - Cursor

func parseCursor(_ data: Data) throws -> [String: Limit] {
    // The two monthly meters Cursor's own dashboard shows. totalSpend/limit is
    // NOT a usage meter — totalSpend includes free bonusSpend, so spend/limit
    // overstates; it and totalPercentUsed are deliberately ignored.
    let payload = try jsonObject(data)
    guard let plan = payload["planUsage"] as? [String: Any],
          let startMs = num(payload["billingCycleStart"]),
          let endMs = num(payload["billingCycleEnd"]),
          let auto = num(plan["autoPercentUsed"]),
          let api = num(plan["apiPercentUsed"]) else {
        throw FetchError.parse("cursor payload: missing fields")
    }
    let start = startMs / 1000, end = endMs / 1000
    guard end > start else { throw FetchError.parse("cursor payload: bad billing cycle") }
    func meter(_ pct: Double) -> Limit {
        Limit(pct: (pct * 10).rounded() / 10, resetEpoch: end, windowSeconds: end - start,
              blocked: pct >= 100.0)
    }
    return ["monthly_auto": meter(auto), "monthly_api": meter(api)]
}

// MARK: - Gemini

let daySeconds: Double = 86400

func parseGemini(_ data: Data) throws -> [String: Limit] {
    // Per-model daily request quotas from cloudcode-pa retrieveUserQuota.
    // remainingAmount (and sometimes remainingFraction) is omitted when the
    // quota is untouched — a missing fraction means 100% remaining, not 0.
    let payload = try jsonObject(data)
    guard let buckets = payload["buckets"] as? [[String: Any]] else {
        throw FetchError.parse("gemini payload: no buckets")
    }
    var out: [String: Limit] = [:]
    for b in buckets {
        guard let model = b["modelId"] as? String,
              let resets = b["resetTime"] as? String, let epoch = isoToEpoch(resets) else { continue }
        let remaining = num(b["remainingFraction"]) ?? 1.0
        let pct = ((1.0 - remaining) * 1000).rounded() / 10
        out[model] = Limit(pct: pct, resetEpoch: epoch, windowSeconds: daySeconds,
                           blocked: remaining <= 0)
    }
    guard !out.isEmpty else {
        throw FetchError.parse("gemini payload: no usable buckets")
    }
    return out
}

// MARK: - Copilot

let monthSeconds: Double = 30 * 86400
let copilotNames = ["chat": "Chat", "completions": "Completions",
                    "premium_interactions": "Premium requests"]

func parseCopilot(_ data: Data) throws -> [String: Limit] {
    // Monthly quota lanes from GitHub Copilot's copilot_internal/user.
    // quota_snapshots gives percent_remaining per lane; skip lanes the plan
    // doesn't meter (has_quota false — e.g. premium requests on the free tier).
    let payload = try jsonObject(data)
    guard let reset = payload["quota_reset_date"] as? String,
          let epoch = isoToEpoch("\(reset)T00:00:00Z") else {
        throw FetchError.parse("copilot payload: no quota_reset_date")
    }
    var out: [String: Limit] = [:]
    for (lane, raw) in (payload["quota_snapshots"] as? [String: [String: Any]]) ?? [:] {
        guard (raw["has_quota"] as? Bool) == true,
              let remaining = num(raw["percent_remaining"]) else { continue }
        out[lane] = Limit(pct: ((100 - remaining) * 10).rounded() / 10,
                          resetEpoch: epoch, windowSeconds: monthSeconds,
                          blocked: (num(raw["remaining"]) ?? 1) <= 0,
                          name: copilotNames[lane] ?? lane)
    }
    guard !out.isEmpty else { throw FetchError.parse("copilot payload: no metered quotas") }
    return out
}

// MARK: - Antigravity

func parseAntigravity(_ data: Data) throws -> [String: Limit] {
    // Per-group weekly + 5-hour pools from Antigravity's local language
    // server (RetrieveUserQuotaSummary). Quota is metered per model *group*
    // (Gemini pool; Claude/GPT pool) — individual models are not tracked
    // (docs/antigravity-usage-research.md).
    let windows: [String: (label: String, seconds: Double)] =
        ["weekly": ("Weekly", 7 * 86400), "5h": ("5-hour", 5 * 3600)]
    let payload = try jsonObject(data)
    guard let response = payload["response"] as? [String: Any],
          let groups = response["groups"] as? [[String: Any]] else {
        throw FetchError.parse("antigravity payload: no groups")
    }
    var out: [String: Limit] = [:]
    for g in groups {
        let name = (g["displayName"] as? String) ?? ""
        let pool = name.lowercased().contains("gemini") ? "Gemini" : "Claude and GPT"
        for b in (g["buckets"] as? [[String: Any]]) ?? [] {
            guard let win = b["window"] as? String, let w = windows[win],
                  let resets = b["resetTime"] as? String,
                  let epoch = isoToEpoch(resets) else { continue }
            let remaining = num(b["remainingFraction"]) ?? 1.0  // omitted = untouched
            out["\(w.label) - \(pool)"] = Limit(
                pct: ((1.0 - remaining) * 1000).rounded() / 10,
                resetEpoch: epoch, windowSeconds: w.seconds,
                blocked: remaining <= 0)
        }
    }
    guard !out.isEmpty else {
        throw FetchError.parse("antigravity payload: no usable groups")
    }
    return out
}

// MARK: - Limit alerts

// Edge-triggered so a poll cadence of 20 min can never spam: an alert fires
// only when a lane CROSSES into a worse state between two polls (blocked,
// OVER pace, or the 90% line). A lane first seen in a bad state stays quiet —
// prev is unknown, and relaunch would otherwise replay old alerts.
struct LaneAlert: Equatable {
    let svc: String, label: String, message: String
}

func alertTransitions(svc: String, old: [String: Limit], new: [String: Limit],
                      now: Double) -> [LaneAlert] {
    var out: [LaneAlert] = []
    for (label, n) in new {
        guard let o = old[label] else { continue }
        let name = laneDisplay(label, n)
        let resets = "resets \(Date(timeIntervalSince1970: n.resetEpoch).formatted(.dateTime.weekday().hour().minute()))"
        let oPace = paceBadge(usagePct: o.pct, elapsed: o.elapsedPct(now: now))
        let nPace = paceBadge(usagePct: n.pct, elapsed: n.elapsedPct(now: now))
        if n.blocked, !o.blocked {
            out.append(LaneAlert(svc: svc, label: label,
                                 message: "\(name): limit reached — \(resets)"))
        } else if n.pct >= 90, o.pct < 90 {
            out.append(LaneAlert(svc: svc, label: label,
                                 message: "\(name) at \(Int(n.pct.rounded()))% — \(resets)"))
        } else if nPace == .over, oPace != .over {
            out.append(LaneAlert(svc: svc, label: label,
                                 message: "\(name) is OVER pace — \(Int(n.pct.rounded()))% used, "
                                     + "\(Int(n.elapsedPct(now: now).rounded()))% of window elapsed"))
        }
    }
    return out.sorted { $0.label < $1.label }
}

// MARK: - Projection

// Least-squares slope over recent points; linear from window start when sparse.
func projectExhaustion(points: [(ts: Double, pct: Double)], limit: Limit, now: Double) -> Double? {
    let slope: Double
    if points.count >= 3 {
        let t0 = points[0].ts
        let xs = points.map { $0.ts - t0 }
        let ys = points.map(\.pct)
        let n = Double(points.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        slope = denom != 0 ? (n * sxy - sx * sy) / denom : 0
    } else {
        let elapsed = now - limit.windowStart
        slope = elapsed > 0 ? limit.pct / elapsed : 0
    }
    guard slope > 0 else { return nil }
    let exhaust = now + max(0, 100 - limit.pct) / slope
    return exhaust < limit.resetEpoch ? exhaust : nil
}

// MARK: - Title lane selection

// The single number for the menu bar / small widget: the pinned lane when it
// is currently visible, else the worst visible lane. Falling back (rather than
// freezing or blanking) covers every disappearance: provider toggled off,
// bucket filtered, vendor dropped the lane.
// Worst = blocked, then over-pace, then highest usage. "On pace" must NOT
// outrank "under" — a freshly reset daily window reads "on" via the
// early-window guard, and ranking it above real usage shows a 0% lane.
func pickTitleLane(pinned: String?, lanes: [(id: String, limit: Limit)], now: Double)
    -> (id: String, limit: Limit)? {
    if let pinned, let hit = lanes.first(where: { $0.id == pinned }) { return hit }
    func severity(_ l: Limit) -> Int {
        if l.blocked { return 0 }
        return paceBadge(usagePct: l.pct, elapsed: l.elapsedPct(now: now)) == .over ? 1 : 2
    }
    return lanes.min {
        let (a, b) = (severity($0.limit), severity($1.limit))
        return a != b ? a < b : $0.limit.pct > $1.limit.pct
    }
}

func pickTitleLimit(pinned: String?, lanes: [(id: String, limit: Limit)], now: Double) -> Limit? {
    pickTitleLane(pinned: pinned, lanes: lanes, now: now)?.limit
}

// MARK: - Grouping

enum Bucket: String, CaseIterable, Sendable {
    case rolling, weekly, monthly

    init(windowSeconds: Double) {
        self = windowSeconds < 172_800 ? .rolling : windowSeconds < 1_728_000 ? .weekly : .monthly
    }

    var title: String {
        switch self {
        case .rolling: "Rolling"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    var hint: String {
        switch self {
        case .rolling: "hours-scale windows"
        case .weekly: "7-day windows"
        case .monthly: "billing cycle"
        }
    }
}

let laneNames: [String: String] = [
    "session": "5-hour session",
    "weekly_all": "Weekly - all models",
    "weekly_scoped": "Weekly - Opus and above",
    "rolling": "Rolling",
    "weekly": "Weekly",
    "monthly_auto": "Monthly - Cursor models",
    "monthly_api": "Monthly - other models",
]

func laneName(_ label: String) -> String {
    if let n = laneNames[label] { return n }
    if label.hasPrefix("model:") { return String(label.dropFirst(6)) }
    return label.replacingOccurrences(of: "_", with: " ")
}

// Vendor-provided name wins; our static label is the fallback.
func laneDisplay(_ label: String, _ limit: Limit) -> String {
    limit.name ?? laneName(label)
}

// MARK: - Weekly utilization ("am I using my subscription enough?")

struct UtilWindow: Sendable, Equatable { let reset: Double; let peak: Double }

struct LaneUtil: Sendable, Equatable, Identifiable {
    let svc: String, label: String, name: String, bucket: Bucket
    let windows: [UtilWindow]
    let avg: Double, max: Double, count: Int
    var id: String { "\(svc).\(label)" }
}

// Port of dashboard.py weekly_utilization(): the peak % each fixed-schedule
// lane reached within each reset window. Windows are keyed by reset DAY
// (weekly/monthly resets are days apart, so sub-second jitter collapses).
// Excludes rolling lanes, Cursor's overstating legacy "monthly" lane, and
// sliding-reset lanes (Codex's rolling now+7d fragments into daily noise —
// dropped when the window count exceeds 2x what the timespan can hold).
func weeklyUtilization(_ history: [HistorySnapshot]) -> [LaneUtil] {
    struct Cell { var peak: Double; var reset: Double; var ws: Double; var name: String; var bucket: Bucket }
    var lanes: [String: [Int: Cell]] = [:]  // "svc\tlabel" -> resetDay -> Cell
    for snap in history {
        for (svc, laneMap) in snap.lanes {
            for (label, limit) in laneMap {
                if svc == "cursor" && label == "monthly" { continue }
                let bucket = Bucket(windowSeconds: limit.windowSeconds)
                if bucket == .rolling { continue }
                let key = "\(svc)\t\(label)", day = Int(limit.resetEpoch / 86400)
                var win = lanes[key] ?? [:]
                if win[day] == nil || limit.pct > win[day]!.peak {
                    win[day] = Cell(peak: limit.pct, reset: limit.resetEpoch, ws: limit.windowSeconds,
                                    name: limit.name ?? laneName(label), bucket: bucket)
                }
                lanes[key] = win
            }
        }
    }
    var out: [LaneUtil] = []
    for (key, win) in lanes {
        let cells = win.keys.sorted().map { win[$0]! }
        let span = cells.last!.reset - cells.first!.reset
        let period = cells.last!.ws
        let expected = period > 0 ? span / period + 1 : Double(cells.count)
        if Double(cells.count) > 2 * expected + 1 { continue }  // sliding reset
        let peaks = cells.map(\.peak)
        let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
        out.append(LaneUtil(
            svc: parts[0], label: parts[1], name: cells.last!.name, bucket: cells.last!.bucket,
            windows: cells.map { UtilWindow(reset: $0.reset.rounded(), peak: ($0.peak * 10).rounded() / 10) },
            avg: (peaks.reduce(0, +) / Double(peaks.count) * 10).rounded() / 10,
            max: (peaks.max()! * 10).rounded() / 10, count: peaks.count))
    }
    let rank: [Bucket: Int] = [.weekly: 0, .monthly: 1]
    out.sort { (rank[$0.bucket] ?? 2, $0.svc, $0.label) < (rank[$1.bucket] ?? 2, $1.svc, $1.label) }
    return out
}
