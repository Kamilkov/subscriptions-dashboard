// Parser + math tests against the same fixtures that drive test_dashboard.py,
// so the Swift port is verified against real vendor payloads.
import XCTest
@testable import UsageBar

final class CoreTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: CoreTests.self).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url, "missing fixture \(name).json"))
    }

    // MARK: - parsers vs fixtures

    func testParseClaude() throws {
        let out = try parseClaude(fixture("claude_usage"))
        XCTAssertEqual(out["session"]?.pct, 23)
        XCTAssertEqual(out["session"]?.windowSeconds, 5 * 3600)
        XCTAssertEqual(out["weekly_all"]?.pct, 32)
        XCTAssertEqual(out["weekly_all"]?.windowSeconds, weekSeconds)
        XCTAssertEqual(out["weekly_scoped"]?.pct, 46)
        XCTAssertEqual(out["weekly_scoped"]?.name, "Weekly - Fable")  // vendor display name
        XCTAssertNil(out["weekly_all"]?.name)
        XCTAssertEqual(out["session"]?.blocked, false)
        // resets_at 2026-07-16T07:00:00.009069+00:00 → epoch check (fraction dropped)
        XCTAssertEqual(out["weekly_all"]!.resetEpoch, 1784185200, accuracy: 1)
    }

    func testParseClaudeRequiresWeeklyAll() {
        let payload = #"{"limits": [{"kind":"session","group":"session","percent":5,"resets_at":"2026-07-12T20:30:00Z"}]}"#
        XCTAssertThrowsError(try parseClaude(Data(payload.utf8))) {
            guard case FetchError.parse = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testPickTitleLimit() {
        let now: Double = 1_000_000
        let quiet = Limit(pct: 10, resetEpoch: now + 1000, windowSeconds: 18000, blocked: false)
        let busy = Limit(pct: 80, resetEpoch: now + 1000, windowSeconds: 18000, blocked: false)
        let blocked = Limit(pct: 60, resetEpoch: now + 1000, windowSeconds: 18000, blocked: true)
        let lanes = [("claude.session", quiet), ("codex.weekly", busy), ("antigravity.g-2.5-pro", blocked)]
        // nil -> automatic: blocked outranks higher usage
        XCTAssertEqual(pickTitleLimit(pinned: nil, lanes: lanes, now: now), blocked)
        // pinned and visible -> that lane, even if quiet (dotted label survives)
        XCTAssertEqual(pickTitleLimit(pinned: "claude.session", lanes: lanes, now: now), quiet)
        XCTAssertEqual(pickTitleLimit(pinned: "antigravity.g-2.5-pro", lanes: lanes, now: now), blocked)
        // pinned but vanished -> automatic fallback, never frozen/blank
        XCTAssertEqual(pickTitleLimit(pinned: "cursor.monthly_api", lanes: lanes, now: now), blocked)
        XCTAssertNil(pickTitleLimit(pinned: nil, lanes: [], now: now))
        // pickTitleLane carries the id so the menu bar can name the provider,
        // splitting on the FIRST dot only (lane labels may contain dots).
        let lane = pickTitleLane(pinned: "antigravity.g-2.5-pro", lanes: lanes, now: now)
        XCTAssertEqual(lane?.id, "antigravity.g-2.5-pro")
        XCTAssertEqual(lane.map { String($0.id.split(separator: ".", maxSplits: 1)[0]) }, "antigravity")
    }

    func testErrorSummaryNamesEveryProvider() throws {
        XCTAssertNil(errorSummary([:]))
        let s = try XCTUnwrap(errorSummary(
            ["codex": "auth", "claude": "network", "cursor": "auth",
             "antigravity": "auth", "copilot": "auth"]))
        for svc in services { XCTAssertTrue(s.contains(svc), "missing \(svc) in \(s)") }
        XCTAssertTrue(s.hasPrefix("⚠ antigravity auth"))  // sorted → deterministic
    }

    func testSnapshotCodecCarriesFreshnessMetadata() throws {
        let snap = HistorySnapshot(
            tsEpoch: 100,
            lanes: ["claude": ["session": Limit(pct: 5, resetEpoch: 200, windowSeconds: 50,
                                                blocked: false, name: "Weekly - Fable")]],
            fetchedAt: ["claude": 90], errors: ["codex": "auth"], pinned: "claude.session")
        let back = try XCTUnwrap(Snapshot.decode(Snapshot.encode(snap)))
        XCTAssertEqual(back.lanes["claude"]?["session"]?.name, "Weekly - Fable")
        XCTAssertEqual(back.fetchedAt["claude"], 90)
        XCTAssertEqual(back.errors["codex"], "auth")
        XCTAssertEqual(back.pinned, "claude.session")
        // History records predate the maps; decode must tolerate their absence.
        XCTAssertEqual(Snapshot.decode(["ts": 1.0])?.fetchedAt, [:])
        XCTAssertNil(Snapshot.decode(["ts": 1.0])?.pinned)
    }

    func testNonFiniteNumbersRejected() {
        // Double("NaN")/"inf" parse; Int(pct.rounded()) traps on them at render.
        // The parser boundary must drop such entries, not pass them through.
        let payload = #"{"limits": [{"kind":"weekly_all","group":"weekly","percent":"NaN","resets_at":"2026-07-16T07:00:00Z"}]}"#
        XCTAssertThrowsError(try parseClaude(Data(payload.utf8)))  // its only lane is dropped
        let codex = #"{"rate_limit":{"primary_window":{"used_percent":"Infinity","reset_at":1784185200,"limit_window_seconds":604800}}}"#
        XCTAssertThrowsError(try parseCodex(Data(codex.utf8)))
    }

    func testClaudeScopeStringOrMissingFallsBackToStaticLabel() throws {
        // Older payloads sent scope as a bare string ("opus") or null.
        let payload = #"{"limits": [{"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"2026-07-16T07:00:00Z"},{"kind":"weekly_scoped","group":"weekly","percent":20,"scope":"opus","resets_at":"2026-07-16T07:00:00Z"}]}"#
        let out = try parseClaude(Data(payload.utf8))
        XCTAssertNil(out["weekly_scoped"]?.name)
        XCTAssertEqual(laneDisplay("weekly_scoped", out["weekly_scoped"]!), "Weekly - Opus and above")
    }

    func testParseClaudeBlockedSeverity() throws {
        let payload = #"{"limits": [{"kind":"weekly_all","group":"weekly","percent":100,"severity":"exceeded","resets_at":"2026-07-16T07:00:00Z"}]}"#
        let out = try parseClaude(Data(payload.utf8))
        XCTAssertEqual(out["weekly_all"]?.blocked, true)
    }

    func testParseCodex() throws {
        let out = try parseCodex(fixture("codex_usage"))
        // Weekly identified by window length (604800), not slot name.
        XCTAssertEqual(out["weekly"]?.pct, 28)
        XCTAssertEqual(out["weekly"]?.resetEpoch, 1784359050)
        XCTAssertEqual(out["rolling"]?.pct, 0)
        XCTAssertEqual(out["rolling"]?.windowSeconds, 18000)
        XCTAssertEqual(out["model:GPT-5.3-Codex-Spark"]?.pct, 0)
        XCTAssertEqual(out["weekly"]?.blocked, false)
    }

    func testCodexBlockedOnlyOnExhaustedWindow() throws {
        // limit_reached, weekly at 100 but rolling at 40: only weekly is blocked.
        let payload = #"{"rate_limit": {"limit_reached": true, "primary_window": {"used_percent": 40, "limit_window_seconds": 18000, "reset_at": 1}, "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_at": 2}}}"#
        let out = try parseCodex(Data(payload.utf8))
        XCTAssertEqual(out["weekly"]?.blocked, true)
        XCTAssertEqual(out["rolling"]?.blocked, false)
    }

    func testParseCursor() throws {
        let out = try parseCursor(fixture("cursor_usage"))
        // autoPercentUsed / apiPercentUsed, NOT totalSpend/limit (bonus-inflated).
        XCTAssertEqual(out["monthly_auto"]?.pct, 7.4)
        XCTAssertEqual(out["monthly_api"]?.pct, 44.3)
        XCTAssertEqual(out["monthly_auto"]!.resetEpoch, 1785318336, accuracy: 1)
        XCTAssertEqual(out["monthly_auto"]!.windowSeconds, 1785318336 - 1782726336, accuracy: 1)
        XCTAssertEqual(out.count, 2)
    }

    func testParseCursorBadCycle() {
        let payload = #"{"billingCycleStart": "2000", "billingCycleEnd": "1000", "planUsage": {"autoPercentUsed": 1, "apiPercentUsed": 2}}"#
        XCTAssertThrowsError(try parseCursor(Data(payload.utf8)))
    }

    func testParseCopilot() throws {
        let out = try parseCopilot(fixture("copilot_user"))
        XCTAssertEqual(Set(out.keys), ["chat", "completions"])  // has_quota=false skipped
        XCTAssertEqual(out["chat"]?.pct, 35.0)                  // 100 - 65 remaining
        XCTAssertEqual(out["chat"]?.name, "Chat")
        XCTAssertEqual(out["chat"]?.windowSeconds, 30 * 86400)
        XCTAssertEqual(out["completions"]?.pct, 100.0)
        XCTAssertEqual(out["completions"]?.blocked, true)
        XCTAssertEqual(out["chat"]?.blocked, false)
    }

    func testParseCopilotNoMeteredQuotas() {
        XCTAssertThrowsError(try parseCopilot(
            Data(#"{"quota_reset_date":"2026-09-01","quota_snapshots":{}}"#.utf8)))
        XCTAssertThrowsError(try parseCopilot(  // no reset date
            Data(#"{"quota_snapshots":{"chat":{"has_quota":true,"percent_remaining":50}}}"#.utf8)))
    }

    func testParseAntigravity() throws {
        let out = try parseAntigravity(fixture("antigravity_quota"))
        XCTAssertEqual(out.count, 4)  // the unknown "monthly" bucket is skipped
        XCTAssertEqual(out["Weekly - Gemini"]?.pct, 65.0)         // 1 - 0.35 remaining
        XCTAssertEqual(out["Weekly - Gemini"]?.windowSeconds, 7 * 86400)
        XCTAssertEqual(out["5-hour - Gemini"]?.pct, 0)            // fraction omitted = untouched
        XCTAssertEqual(out["5-hour - Gemini"]?.windowSeconds, 5 * 3600)
        XCTAssertEqual(out["Weekly - Claude and GPT"]?.blocked, true)
        XCTAssertEqual(out["Weekly - Claude and GPT"]?.pct, 100)
        XCTAssertEqual(out["5-hour - Claude and GPT"]?.blocked, false)
    }

    func testParseAntigravityNoGroups() {
        XCTAssertThrowsError(try parseAntigravity(Data(#"{"response": {"groups": []}}"#.utf8)))
        XCTAssertThrowsError(try parseAntigravity(Data(#"{}"#.utf8)))
    }

    func testAlertTransitionsAreEdgeTriggered() {
        // Window: 0..100k s, now 50k → 50% elapsed. pct 80 @ 50% elapsed = OVER.
        func lim(_ pct: Double, blocked: Bool = false) -> Limit {
            Limit(pct: pct, resetEpoch: 100_000, windowSeconds: 100_000, blocked: blocked)
        }
        let now = 50_000.0
        // Crossing into OVER fires once; staying OVER stays quiet.
        let over = alertTransitions(svc: "claude", old: ["w": lim(40)],
                                    new: ["w": lim(80)], now: now)
        XCTAssertEqual(over.count, 1)
        XCTAssertTrue(over[0].message.contains("OVER pace"))
        XCTAssertTrue(alertTransitions(svc: "claude", old: ["w": lim(80)],
                                       new: ["w": lim(85)], now: now).isEmpty)
        // Blocked edge beats the other messages.
        let blocked = alertTransitions(svc: "claude", old: ["w": lim(95)],
                                       new: ["w": lim(100, blocked: true)], now: now)
        XCTAssertEqual(blocked.count, 1)
        XCTAssertTrue(blocked[0].message.contains("limit reached"))
        // 90% crossing fires; a lane first seen (no previous) never fires.
        let ninety = alertTransitions(svc: "claude", old: ["w": lim(88)],
                                      new: ["w": lim(91)], now: now)
        XCTAssertEqual(ninety.count, 1)
        XCTAssertTrue(ninety[0].message.contains("91%"))
        XCTAssertTrue(alertTransitions(svc: "claude", old: [:],
                                       new: ["w": lim(100, blocked: true)], now: now).isEmpty)
    }

    func testWeeklyUtilizationPeaksPerWindow() {
        let wk = 7.0 * 86400
        let r1 = 1_780_000_000.0, r2 = r1 + wk
        func snap(_ pct: Double, reset: Double, session: Bool = false) -> HistorySnapshot {
            var lanes: [String: Limit] = ["weekly_all": Limit(pct: pct, resetEpoch: reset,
                                                              windowSeconds: wk, blocked: false)]
            if session { lanes["session"] = Limit(pct: 99, resetEpoch: reset,
                                                  windowSeconds: 18000, blocked: false) }
            return HistorySnapshot(tsEpoch: reset, lanes: ["claude": lanes])
        }
        let hist = [snap(20, reset: r1, session: true), snap(46, reset: r1 + 0.4),
                    snap(30, reset: r1 + 0.9), snap(7, reset: r2)]
        let out = weeklyUtilization(hist)
        let lane = try! XCTUnwrap(out.first { $0.label == "weekly_all" })
        XCTAssertEqual(lane.count, 2)                 // jitter collapsed to two windows
        XCTAssertEqual(lane.windows[0].peak, 46)      // peak within window 1, not last
        XCTAssertEqual(lane.windows[1].peak, 7)
        XCTAssertEqual(lane.max, 46)
        XCTAssertEqual(lane.avg, 26.5)
        XCTAssertFalse(out.contains { $0.label == "session" })  // rolling excluded
    }

    // MARK: - pace

    func testPaceBadge() {
        XCTAssertEqual(paceBadge(usagePct: 9, elapsed: 1.5), .on)     // early-window guard
        XCTAssertEqual(paceBadge(usagePct: 10, elapsed: 50), .under)  // rate 0.2
        XCTAssertEqual(paceBadge(usagePct: 50, elapsed: 50), .on)     // rate 1.0
        XCTAssertEqual(paceBadge(usagePct: 9, elapsed: 7), .over)     // rate 1.29
    }

    func testElapsedPctClamps() {
        let l = Limit(pct: 0, resetEpoch: 1000, windowSeconds: 100, blocked: false)
        XCTAssertEqual(l.elapsedPct(now: 800), 0)     // before window
        XCTAssertEqual(l.elapsedPct(now: 950), 50)
        XCTAssertEqual(l.elapsedPct(now: 2000), 100)  // past reset
    }

    // MARK: - projection

    func testProjectionLinearWhenSparse() {
        // 50% used at half-window on a steady burn → exhausts exactly at reset → nil.
        let l = Limit(pct: 50, resetEpoch: 2000, windowSeconds: 2000, blocked: false)
        XCTAssertNil(projectExhaustion(points: [], limit: l, now: 1000))
    }

    func testProjectionSlopeExhaustsEarly() {
        // 1%/s over recent points, 80% used → exhausts in ~20s, well before reset.
        let l = Limit(pct: 80, resetEpoch: 10000, windowSeconds: 10000, blocked: false)
        let pts: [(ts: Double, pct: Double)] = [(100, 60), (110, 70), (120, 80)]
        let exhaust = try! XCTUnwrap(projectExhaustion(points: pts, limit: l, now: 120))
        XCTAssertEqual(exhaust, 140, accuracy: 0.5)
    }

    func testProjectionFlatUsageNeverExhausts() {
        let l = Limit(pct: 30, resetEpoch: 10000, windowSeconds: 10000, blocked: false)
        let pts: [(ts: Double, pct: Double)] = [(100, 30), (110, 30), (120, 30)]
        XCTAssertNil(projectExhaustion(points: pts, limit: l, now: 120))
    }

    // MARK: - misc

    func testIsoToEpochHandlesMicrosecondsAndZ() {
        XCTAssertEqual(isoToEpoch("2026-07-16T07:00:00.009069+00:00")!, 1784185200, accuracy: 1)
        XCTAssertEqual(isoToEpoch("2026-07-16T07:00:00Z")!, 1784185200, accuracy: 1)
        XCTAssertNil(isoToEpoch("not a date"))
    }

    func testBucketThresholds() {
        XCTAssertEqual(Bucket(windowSeconds: 18000), .rolling)
        XCTAssertEqual(Bucket(windowSeconds: 604800), .weekly)
        XCTAssertEqual(Bucket(windowSeconds: 2_592_000), .monthly)
    }

    // MARK: - board background contrast (PRODUCT.md: ≥ 4.5:1 in both themes)

    func testBoardBackgroundContrastRule() {
        XCTAssertTrue(bgContrastOK("F1F1F4", dark: false))   // default light
        XCTAssertTrue(bgContrastOK("151517", dark: true))    // default dark
        XCTAssertFalse(bgContrastOK("000000", dark: false))  // black page, near-black ink
        XCTAssertFalse(bgContrastOK("FFFFFF", dark: true))   // white page, near-white ink
        XCTAssertFalse(bgContrastOK("808080", dark: false))  // mid-grey fails both
        XCTAssertFalse(bgContrastOK("808080", dark: true))
        XCTAssertFalse(bgContrastOK("nope", dark: false))    // malformed = rejected
        // Scanner accepts a valid prefix ("FF000Z" scans as 0xFF000) — the
        // whole string must parse, in both validators.
        XCTAssertFalse(bgContrastOK("FF000Z", dark: false))
        XCTAssertNil(colorFromHex("FF000Z"))
    }

    // MARK: - lane ordering (merged-board spec: global worst first)

    func testWorseLaneOrdersByPaceThenSoonestReset() {
        XCTAssertTrue(worseLane((.over, 400), (.on, 100)))    // pace dominates
        XCTAssertTrue(worseLane((.on, 400), (.under, 100)))
        XCTAssertFalse(worseLane((.under, 100), (.over, 400)))
        XCTAssertTrue(worseLane((.over, 100), (.over, 400)))  // equal pace: sooner reset first
        XCTAssertFalse(worseLane((.over, 400), (.over, 100)))
    }

    // MARK: - finite-but-absurd values (would trap in Int() at render sites)

    func testAbsurdRawPercentRejected() throws {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("claude_usage")) as? [String: Any])
        var limits = try XCTUnwrap(payload["limits"] as? [[String: Any]])
        for i in limits.indices where (limits[i]["kind"] as? String) == "weekly_all" {
            limits[i]["percent"] = 1e300  // finite, but Int(1e300.rounded()) traps
        }
        payload["limits"] = limits
        let data = try JSONSerialization.data(withJSONObject: payload)
        // weekly_all's percent is rejected -> entry skipped -> parser throws.
        XCTAssertThrowsError(try parseClaude(data))
    }

    func testPresentButInvalidRemainingSkipsBucket() {
        // remainingFraction -1e300 fails the raw bound; the bucket must be
        // skipped, not silently rendered as 0% "untouched".
        let json = #"{"response": {"groups": [{"displayName": "Gemini Models", "buckets": "#
            + #"[{"window": "weekly", "resetTime": "2026-08-24T09:00:00Z", "remainingFraction": -1e300}]}]}}"#
        XCTAssertThrowsError(try parseAntigravity(Data(json.utf8)))
    }

    func testDerivedPercentOverflowRejected() {
        // -9e14 passes the raw bound but derives pct ≈ 9e17 — reject at
        // construction, never hand it to an Int() render site.
        let json = #"{"response": {"groups": [{"displayName": "Gemini Models", "buckets": "#
            + #"[{"window": "weekly", "resetTime": "2026-08-24T09:00:00Z", "remainingFraction": -9e14}]}]}}"#
        XCTAssertThrowsError(try parseAntigravity(Data(json.utf8)))
    }

    func testMillisecondEpochsStillAccepted() throws {
        // Cursor billing-cycle epochs are milliseconds (~1.8e12) — the
        // absurdity bound must not reject them.
        let out = try parseCursor(fixture("cursor_usage"))
        XCTAssertNotNil(out["monthly_auto"])
    }
}
