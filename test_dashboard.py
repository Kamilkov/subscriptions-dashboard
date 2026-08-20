#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def load_fixture(name):
    return json.loads((FIXTURES / name).read_text())


class TestFixtures(unittest.TestCase):
    def test_claude_fixture_shape(self):
        p = load_fixture("claude_usage.json")
        kinds = {e["kind"] for e in p["limits"]}
        self.assertIn("session", kinds)
        self.assertIn("weekly_all", kinds)
        self.assertIn("weekly_scoped", kinds)

    def test_codex_fixture_shape(self):
        p = load_fixture("codex_usage.json")
        self.assertEqual(p["rate_limit"]["secondary_window"]["limit_window_seconds"], 604800)
        self.assertEqual(p["additional_rate_limits"][0]["limit_name"], "GPT-5.3-Codex-Spark")

    def test_dashboard_module_imports(self):
        import dashboard  # noqa: F401


class TestParsers(unittest.TestCase):
    def test_parse_claude(self):
        import dashboard
        out = dashboard.parse_claude(load_fixture("claude_usage.json"))
        self.assertEqual(out["session"], {"pct": 23.0,
                                          "resets_at": "2026-07-12T20:30:00.009044+00:00",
                                          "window_seconds": 18000, "blocked": False})
        self.assertEqual(out["weekly_all"], {"pct": 32.0,
                                             "resets_at": "2026-07-16T07:00:00.009069+00:00",
                                             "blocked": False})
        self.assertEqual(out["weekly_scoped"]["pct"], 46.0)
        # Vendor display name carried through from the scope object.
        self.assertEqual(out["weekly_scoped"]["name"], "Weekly - Fable")

    def test_parse_claude_scope_string_or_missing_has_no_name(self):
        # Older payloads sent scope as a bare string ("opus") or null; the
        # parser must fall back to no name (UI uses its static label).
        import dashboard
        for scope in ("opus", None, {"model": None}, {"model": {"display_name": None}}):
            p = load_fixture("claude_usage.json")
            for e in p["limits"]:
                if e["kind"] == "weekly_scoped": e["scope"] = scope
            self.assertNotIn("name", dashboard.parse_claude(p)["weekly_scoped"])

    def test_parse_claude_blocked_from_severity(self):
        # A hard severity flags a limit as blocked; a soft one (or "normal") does not.
        import dashboard
        p = load_fixture("claude_usage.json")
        self.assertFalse(any(v["blocked"] for v in dashboard.parse_claude(p).values()))
        for e in p["limits"]:
            if e["kind"] == "weekly_all": e["severity"] = "critical"
            if e["kind"] == "session": e["severity"] = "warning"
        out = dashboard.parse_claude(p)
        self.assertTrue(out["weekly_all"]["blocked"])
        self.assertFalse(out["session"]["blocked"])

    def test_parse_claude_without_session(self):
        import dashboard
        p = load_fixture("claude_usage.json")
        p["limits"] = [e for e in p["limits"] if e["kind"] != "session"]
        out = dashboard.parse_claude(p)
        self.assertNotIn("session", out)

    def test_parse_claude_ignores_session_between_windows(self):
        import dashboard
        p = load_fixture("claude_usage.json")
        next(e for e in p["limits"] if e["kind"] == "session")["resets_at"] = None
        self.assertNotIn("session", dashboard.parse_claude(p))

    def test_parse_claude_ignores_scoped_between_windows(self):
        import dashboard
        p = load_fixture("claude_usage.json")
        next(e for e in p["limits"] if e["kind"] == "weekly_scoped")["resets_at"] = None
        out = dashboard.parse_claude(p)
        self.assertNotIn("weekly_scoped", out)

    def test_parse_claude_missing_weekly_raises_parse_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_claude({"limits": []})
        self.assertEqual(cm.exception.category, "parse")

    def test_parse_claude_garbage_raises_parse_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_claude({"nope": True})
        self.assertEqual(cm.exception.category, "parse")

    def test_parse_codex(self):
        import dashboard
        out = dashboard.parse_codex(load_fixture("codex_usage.json"))
        self.assertEqual(out["weekly"], {"pct": 28.0, "reset_at": 1784359050.0,
                                         "window_seconds": 604800.0, "blocked": False})
        self.assertEqual(out["models"]["GPT-5.3-Codex-Spark"]["pct"], 0.0)

    def test_parse_codex_blocked_on_exhausted_window(self):
        # limit_reached pins "blocked" to the window that is actually exhausted,
        # not to every window under the account.
        import dashboard
        p = load_fixture("codex_usage.json")
        rl = p["rate_limit"]
        rl["limit_reached"] = True
        rl["secondary_window"]["used_percent"] = 100   # weekly exhausted
        rl["primary_window"]["used_percent"] = 40      # rolling not exhausted
        out = dashboard.parse_codex(p)
        self.assertTrue(out["weekly"]["blocked"])
        self.assertFalse(out["rolling"]["blocked"])
        rl["limit_reached"] = False  # no vendor flag -> a full window is not "blocked"
        self.assertFalse(dashboard.parse_codex(p)["weekly"]["blocked"])

    def test_parse_codex_no_additional_limits(self):
        import dashboard
        p = load_fixture("codex_usage.json")
        p["additional_rate_limits"] = None
        self.assertEqual(dashboard.parse_codex(p)["models"], {})

    def test_parse_codex_garbage_raises_parse_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_codex({"rate_limit": None})
        self.assertEqual(cm.exception.category, "parse")

    def test_parse_codex_weekly_in_primary_window(self):
        # Live shape observed 2026-07-12 evening: secondary_window is null and
        # the weekly (604800 s) window sits in primary_window. Windows must be
        # identified by limit_window_seconds, never by slot name.
        import dashboard
        p = load_fixture("codex_usage.json")
        weekly = p["rate_limit"]["secondary_window"]
        p["rate_limit"]["primary_window"] = weekly
        p["rate_limit"]["secondary_window"] = None
        for extra in p["additional_rate_limits"]:
            extra["rate_limit"]["primary_window"] = extra["rate_limit"]["secondary_window"]
            extra["rate_limit"]["secondary_window"] = None
        out = dashboard.parse_codex(p)
        self.assertEqual(out["weekly"], {"pct": 28.0, "reset_at": 1784359050.0,
                                         "window_seconds": 604800.0, "blocked": False})
        self.assertIn("GPT-5.3-Codex-Spark", out["models"])

    def test_parse_codex_no_weekly_window_raises(self):
        import dashboard
        p = load_fixture("codex_usage.json")
        p["rate_limit"]["secondary_window"] = None  # only the 5h primary remains
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_codex(p)
        self.assertEqual(cm.exception.category, "parse")

    def test_parse_codex_extracts_rolling(self):
        # The account-level 5h (18000 s) primary window is exposed as one rolling
        # limit; weekly is unchanged and no per-model window is a rolling one.
        import dashboard
        out = dashboard.parse_codex(load_fixture("codex_usage.json"))
        self.assertEqual(out["rolling"], {"pct": 0.0, "reset_at": 1783893080.0,
                                          "window_seconds": 18000.0, "blocked": False})
        self.assertEqual(out["weekly"]["window_seconds"], 604800.0)
        for m in out["models"].values():
            self.assertNotEqual(m["window_seconds"], 18000.0)

    def test_parse_codex_rolling_regardless_of_slot(self):
        # Slots churn within a day — identify the rolling window by seconds, not
        # by primary/secondary position.
        import dashboard
        p = load_fixture("codex_usage.json")
        rolling, weekly = p["rate_limit"]["primary_window"], p["rate_limit"]["secondary_window"]
        p["rate_limit"]["primary_window"] = weekly    # 604800 now in primary
        p["rate_limit"]["secondary_window"] = rolling  # 18000 now in secondary
        out = dashboard.parse_codex(p)
        self.assertEqual(out["rolling"]["window_seconds"], 18000.0)
        self.assertEqual(out["weekly"]["window_seconds"], 604800.0)

    def test_parse_codex_rolling_optional(self):
        import dashboard
        p = load_fixture("codex_usage.json")
        p["rate_limit"]["primary_window"] = None  # drop the 5h; weekly stays in secondary
        out = dashboard.parse_codex(p)
        self.assertNotIn("rolling", out)
        self.assertEqual(out["weekly"]["window_seconds"], 604800.0)

    def test_parse_codex_rolling_ignores_empty_slot(self):
        # An account slot dict with no limit_window_seconds is not a rolling
        # window — it must be ignored, not defaulted to 0 s (which KeyErrored).
        import dashboard
        p = load_fixture("codex_usage.json")
        p["rate_limit"]["primary_window"] = {}  # empty slot: no duration
        out = dashboard.parse_codex(p)
        self.assertNotIn("rolling", out)
        self.assertEqual(out["weekly"]["window_seconds"], 604800.0)

    def test_parse_cursor(self):
        import dashboard
        # The two meters Cursor's own dashboard shows — NOT totalSpend/limit,
        # which includes free bonusSpend (fixture would read 210% blocked).
        out = dashboard.parse_cursor(load_fixture("cursor_usage.json"))
        self.assertEqual(out["monthly_auto"], {"pct": 7.4, "reset_at": 1785318336.0,
                                               "window_seconds": 2592000.0, "blocked": False})
        self.assertEqual(out["monthly_api"], {"pct": 44.3, "reset_at": 1785318336.0,
                                              "window_seconds": 2592000.0, "blocked": False})

    def test_parse_cursor_blocked(self):
        import dashboard
        p = load_fixture("cursor_usage.json")
        p["planUsage"]["apiPercentUsed"] = 100.0
        out = dashboard.parse_cursor(p)
        self.assertTrue(out["monthly_api"]["blocked"])
        self.assertFalse(out["monthly_auto"]["blocked"])

    def test_parse_cursor_bad_cycle_or_garbage_raises(self):
        import dashboard
        p = load_fixture("cursor_usage.json")
        p["billingCycleEnd"] = p["billingCycleStart"]
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_cursor(p)
        self.assertEqual(cm.exception.category, "parse")
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_cursor({"planUsage": None})
        self.assertEqual(cm.exception.category, "parse")


class TestWindowMath(unittest.TestCase):
    CLAUDE_LIMIT = {"pct": 32.0, "resets_at": "2026-07-16T07:00:00.009069+00:00"}
    CODEX_LIMIT = {"pct": 28.0, "reset_at": 1784359050.0, "window_seconds": 604800.0}

    def test_iso_epoch_roundtrip(self):
        import dashboard
        self.assertEqual(dashboard.epoch_to_iso(1784359050.0), "2026-07-18T07:17:30Z")
        self.assertAlmostEqual(dashboard.iso_to_epoch("2026-07-18T07:17:30Z"), 1784359050.0)

    def test_reset_epoch_both_vendors(self):
        import dashboard
        self.assertAlmostEqual(dashboard.reset_epoch(self.CODEX_LIMIT), 1784359050.0)
        self.assertAlmostEqual(dashboard.reset_epoch(self.CLAUDE_LIMIT),
                               dashboard.iso_to_epoch("2026-07-16T07:00:00.009069+00:00"))

    def test_window_start_uses_own_reset(self):
        import dashboard
        self.assertAlmostEqual(dashboard.window_start(self.CODEX_LIMIT), 1784359050.0 - 604800.0)
        self.assertAlmostEqual(dashboard.window_start(self.CLAUDE_LIMIT),
                               dashboard.reset_epoch(self.CLAUDE_LIMIT) - dashboard.WEEK_SECONDS)

    def test_elapsed_pct_midwindow_and_clamped(self):
        import dashboard
        start = dashboard.window_start(self.CODEX_LIMIT)
        self.assertAlmostEqual(dashboard.elapsed_pct(self.CODEX_LIMIT, start + 302400), 50.0)
        self.assertEqual(dashboard.elapsed_pct(self.CODEX_LIMIT, start - 100), 0.0)
        self.assertEqual(dashboard.elapsed_pct(self.CODEX_LIMIT, start + 999999999), 100.0)

    def test_pace_badge_bands(self):
        import dashboard
        self.assertEqual(dashboard.pace_badge(10.0, 50.0), "under")  # 0.20x
        self.assertEqual(dashboard.pace_badge(47.0, 50.0), "on")  # 0.94x
        self.assertEqual(dashboard.pace_badge(53.0, 50.0), "on")  # 1.06x
        self.assertEqual(dashboard.pace_badge(60.0, 50.0), "over")  # 1.20x

    def test_pace_badge_is_ratio_not_points(self):
        import dashboard
        # 2pp gap early in the window is a 1.3x burn — over pace, not "on".
        self.assertEqual(dashboard.pace_badge(9.0, 7.0), "over")
        # The same 2pp gap late in the window is a 1.02x burn — genuinely on pace.
        self.assertEqual(dashboard.pace_badge(92.0, 90.0), "on")

    def test_pace_badge_early_window_guard(self):
        import dashboard
        # Below 2% elapsed the ratio is noise (and 0 elapsed would divide by zero).
        self.assertEqual(dashboard.pace_badge(5.0, 0.0), "on")
        self.assertEqual(dashboard.pace_badge(5.0, 1.9), "on")


import tempfile
import time as _time


class TestHistoryIO(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "history.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def snap(self, ts_epoch):
        import dashboard
        return {"ts": dashboard.epoch_to_iso(ts_epoch), "ts_epoch": ts_epoch,
                "claude": {"weekly_all": {"pct": 30.0, "resets_at": "2026-07-16T07:00:00+00:00"}},
                "codex": None}

    def test_append_then_load_roundtrip(self):
        import dashboard
        now = _time.time()
        dashboard.append_history_line(self.path, self.snap(now))
        recs = dashboard.load_history(self.path, now_fn=lambda: now)
        self.assertEqual(len(recs), 1)
        self.assertAlmostEqual(recs[0]["ts_epoch"], now, delta=1)
        self.assertNotIn("ts_epoch", self.path.read_text())  # not persisted

    def test_load_skips_garbage_and_prunes_old(self):
        import dashboard
        now = _time.time()
        dashboard.append_history_line(self.path, self.snap(now - dashboard.HISTORY_DAYS * 86400 - 60))
        with open(self.path, "a") as f:
            f.write("{corrupt\n\n")
        dashboard.append_history_line(self.path, self.snap(now))
        recs = dashboard.load_history(self.path, now_fn=lambda: now)
        self.assertEqual(len(recs), 1)
        self.assertEqual(len(self.path.read_text().splitlines()), 1)  # rewritten pruned

    def test_load_missing_file(self):
        import dashboard
        self.assertEqual(dashboard.load_history(self.path), [])


class TestProjection(unittest.TestCase):
    LIMIT = {"pct": 50.0, "reset_at": 1000000.0, "window_seconds": 604800.0}
    # window_start = 395200.0

    def hist(self, points):
        import dashboard
        return [{"ts": dashboard.epoch_to_iso(t), "ts_epoch": t,
                 "codex": {"weekly": {"pct": p, "reset_at": 1000000.0, "window_seconds": 604800.0}},
                 "claude": None} for t, p in points]

    def test_get_limit_and_paths(self):
        import dashboard
        data = dashboard.parse_codex(load_fixture("codex_usage.json"))
        self.assertEqual(dashboard.get_limit(data, ["weekly"])["pct"], 28.0)
        self.assertEqual(dashboard.get_limit(data, ["models", "nope"]), None)
        self.assertEqual(dashboard.limit_paths("codex", data),
                         [("rolling", ["rolling"]),
                          ("weekly", ["weekly"]),
                          ("GPT-5.3-Codex-Spark", ["models", "GPT-5.3-Codex-Spark"])])
        cdata = dashboard.parse_claude(load_fixture("claude_usage.json"))
        self.assertEqual(dashboard.limit_paths("claude", cdata),
                         [("session", ["session"]), ("weekly_all", ["weekly_all"]),
                          ("weekly_scoped", ["weekly_scoped"])])
        self.assertEqual(dashboard.limit_paths("claude", None), [])
        udata = dashboard.parse_cursor(load_fixture("cursor_usage.json"))
        self.assertEqual(dashboard.limit_paths("cursor", udata),
                         [("monthly_auto", ["monthly_auto"]), ("monthly_api", ["monthly_api"])])
        # stale pre-2026-08 snapshot still renders its single lane
        self.assertEqual(dashboard.limit_paths("cursor", {"monthly": {}}),
                         [("monthly", ["monthly"])])

    def test_limit_paths_codex_includes_rolling(self):
        import dashboard
        data = dashboard.parse_codex(load_fixture("codex_usage.json"))
        self.assertEqual(dashboard.limit_paths("codex", data)[0], ("rolling", ["rolling"]))
        del data["rolling"]
        self.assertNotIn(("rolling", ["rolling"]), dashboard.limit_paths("codex", data))

    def test_select_respects_own_window_boundary(self):
        import dashboard
        now = 500000.0
        h = self.hist([(395100.0, 1.0), (395300.0, 2.0), (450000.0, 25.0)])
        pts = dashboard.select_window_points(h, "codex", ["weekly"], self.LIMIT, now)
        self.assertEqual([p[0] for p in pts], [395300.0, 450000.0])  # pre-window point dropped

    def test_select_trailing_cap_and_null_service(self):
        import dashboard
        now = 500000.0
        h = self.hist([(400000.0, 5.0), (480000.0, 40.0)])
        h.append({"ts": dashboard.epoch_to_iso(490000.0), "ts_epoch": 490000.0,
                  "codex": None, "claude": None})
        pts = dashboard.select_window_points(h, "codex", ["weekly"], self.LIMIT, now, trailing=86400.0)
        self.assertEqual(pts, [(480000.0, 40.0)])  # 400000 outside trailing 24h; null skipped

    def test_project_slope_hits_100_before_reset(self):
        import dashboard
        now = 500000.0
        pts = [(490000.0, 30.0), (495000.0, 40.0), (500000.0, 50.0)]  # +10 pct / 5000 s
        out = dashboard.project(pts, self.LIMIT, now)
        self.assertEqual(out["method"], "slope")
        self.assertAlmostEqual(out["exhaust_epoch"], 525000.0, delta=1.0)  # 50 pts left / (10/5000)

    def test_project_lasts_past_reset(self):
        import dashboard
        pts = [(490000.0, 49.9), (495000.0, 49.95), (500000.0, 50.0)]
        out = dashboard.project(pts, self.LIMIT, 500000.0)
        self.assertIsNone(out["exhaust_epoch"])

    def test_project_linear_fallback_under_3_points(self):
        import dashboard
        out = dashboard.project([(500000.0, 50.0)], self.LIMIT, 500000.0)
        self.assertEqual(out["method"], "linear")
        # 50% used in 104800 s elapsed -> 100% at start + 209600 = 604800 -> before reset
        self.assertAlmostEqual(out["exhaust_epoch"], 395200.0 + 209600.0, delta=5.0)

    def test_project_flat_usage_never_exhausts(self):
        import dashboard
        limit = dict(self.LIMIT, pct=0.0)
        out = dashboard.project([], limit, 500000.0)
        self.assertIsNone(out["exhaust_epoch"])

    def test_project_exactly_100_reports_now(self):
        import dashboard
        limit = dict(self.LIMIT, pct=100.0)
        pts = [(490000.0, 80.0), (495000.0, 90.0), (500000.0, 100.0)]
        out = dashboard.project(pts, limit, 500000.0)
        self.assertAlmostEqual(out["exhaust_epoch"], 500000.0, delta=1.0)

    def test_project_above_100_clamps_never_in_the_past(self):
        import dashboard
        limit = dict(self.LIMIT, pct=104.0)
        out_slope = dashboard.project([(490000.0, 84.0), (495000.0, 94.0), (500000.0, 104.0)],
                                      limit, 500000.0)
        self.assertGreaterEqual(out_slope["exhaust_epoch"], 500000.0)  # slope path
        out_linear = dashboard.project([], limit, 500000.0)
        self.assertGreaterEqual(out_linear["exhaust_epoch"], 500000.0)  # linear path


import io
import urllib.error


class FakeCompleted:
    def __init__(self, returncode, stdout):
        self.returncode, self.stdout = returncode, stdout


class TestCredentialsAndFetch(unittest.TestCase):
    def test_read_claude_token_ok(self):
        import dashboard
        raw = json.dumps({"claudeAiOauth": {"accessToken": "tok-abc"}})
        tok = dashboard.read_claude_token(run=lambda *a, **k: FakeCompleted(0, raw))
        self.assertEqual(tok, "tok-abc")

    def test_read_claude_token_missing_is_auth_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.read_claude_token(run=lambda *a, **k: FakeCompleted(44, ""))
        self.assertEqual(cm.exception.category, "auth")

    def test_read_codex_creds_from_temp_file(self):
        import dashboard
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "auth.json"
            p.write_text(json.dumps({"tokens": {"access_token": "ct", "account_id": "acc"}}))
            self.assertEqual(dashboard.read_codex_creds(path=p), ("ct", "acc"))

    def test_read_codex_creds_missing_file_is_auth_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.read_codex_creds(path=Path("/nonexistent/auth.json"))
        self.assertEqual(cm.exception.category, "auth")

    def test_read_codex_creds_missing_or_empty_account_id_is_auth_error(self):
        import dashboard
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "auth.json"
            for tokens in ({"access_token": "ct", "account_id": ""},
                           {"access_token": "ct"},
                           {"access_token": "", "account_id": "acc"}):
                p.write_text(json.dumps({"tokens": tokens}))
                with self.assertRaises(dashboard.FetchError) as cm:
                    dashboard.read_codex_creds(path=p)
                self.assertEqual(cm.exception.category, "auth")

    def test_http_categories(self):
        import dashboard

        def opener_401(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 401, "unauthorized", {}, io.BytesIO(b""))

        def opener_500(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 500, "boom", {}, io.BytesIO(b""))

        def opener_badjson(req, timeout):
            class R(io.BytesIO):
                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False
            return R(b"not json")

        for opener, cat in ((opener_401, "auth"), (opener_500, "network"), (opener_badjson, "parse")):
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.http_get_json("https://x.invalid/y", {}, opener=opener)
            self.assertEqual(cm.exception.category, cat)

    def test_http_get_json_closes_httperror(self):
        # The HTTPError carries a file-like response; the production catch path
        # must close it explicitly (recurring 401/5xx must not pile up FDs
        # waiting for GC).
        import dashboard
        closed = {"n": 0}

        class TrackingError(urllib.error.HTTPError):
            def close(self):
                closed["n"] += 1
                super().close()

        def opener(req, timeout):
            raise TrackingError(req.full_url, 500, "boom", {}, io.BytesIO(b""))

        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.http_get_json("https://x.invalid/y", {}, opener=opener)
        self.assertEqual(cm.exception.category, "network")
        self.assertGreaterEqual(closed["n"], 1)

    def test_fetch_claude_wires_token_and_parser(self):
        import dashboard
        seen = {}

        def fake_get(url, headers, opener=None):
            seen["url"], seen["headers"] = url, headers
            return load_fixture("claude_usage.json")

        out = dashboard.fetch_claude(read_token=lambda: "tok-abc", get=fake_get)
        self.assertEqual(out["weekly_all"]["pct"], 32.0)
        self.assertEqual(seen["url"], "https://api.anthropic.com/api/oauth/usage")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer tok-abc")
        self.assertEqual(seen["headers"]["anthropic-beta"], "oauth-2025-04-20")

    def test_parse_copilot(self):
        import dashboard
        out = dashboard.parse_copilot(load_fixture("copilot_user.json"))
        # has_quota=False lanes (premium on the free tier) are excluded
        self.assertEqual(sorted(out), ["chat", "completions"])
        self.assertEqual(out["chat"]["pct"], 35.0)          # 100 - 65 remaining
        self.assertEqual(out["chat"]["name"], "Chat")
        self.assertEqual(out["chat"]["window_seconds"], 30 * 86400.0)
        self.assertEqual(out["chat"]["resets_at"], "2026-09-01T00:00:00Z")
        self.assertEqual(out["completions"]["pct"], 100.0)   # 0 remaining
        self.assertTrue(out["completions"]["blocked"])
        self.assertFalse(out["chat"]["blocked"])

    def test_parse_copilot_no_metered_quotas_raises(self):
        import dashboard
        for payload in ({"quota_reset_date": "2026-09-01", "quota_snapshots": {}},
                        {"quota_snapshots": {"chat": {"has_quota": True, "percent_remaining": 50}}},
                        {"quota_reset_date": "2026-09-01",
                         "quota_snapshots": {"x": {"has_quota": False}}}):
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.parse_copilot(payload)
            self.assertEqual(cm.exception.category, "parse")

    def test_parse_antigravity(self):
        import dashboard
        out = dashboard.parse_antigravity(load_fixture("antigravity_quota.json"))
        self.assertEqual(out["Weekly - Gemini"]["pct"], 65.0)
        self.assertEqual(out["Weekly - Gemini"]["window_seconds"], 7 * 86400.0)
        # remainingFraction omitted = untouched, NOT 0% remaining
        self.assertEqual(out["5-hour - Gemini"]["pct"], 0.0)
        self.assertEqual(out["5-hour - Gemini"]["window_seconds"], 5 * 3600.0)
        self.assertTrue(out["Weekly - Claude and GPT"]["blocked"])
        self.assertEqual(out["Weekly - Claude and GPT"]["pct"], 100.0)
        self.assertFalse(out["5-hour - Claude and GPT"]["blocked"])
        # unknown windows (future buckets) are skipped, not lanes
        self.assertEqual(len(out), 4)

    def test_parse_antigravity_no_groups_raises(self):
        import dashboard
        for payload in ({"response": {"groups": []}}, {"response": {}}, {},
                        {"response": {"groups": [{"displayName": "Gemini Models",
                                                  "buckets": [{"window": "5h"}]}]}}):
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.parse_antigravity(payload)
            self.assertEqual(cm.exception.category, "parse")

    def test_fetch_antigravity_cross_probes_ports_and_tokens(self):
        import dashboard
        seen = []

        def fake_post(url, headers, body, opener=None):
            seen.append((url, headers.get("X-Codeium-Csrf-Token")))
            if ":4002/" in url and headers.get("X-Codeium-Csrf-Token") == "tok-b":
                return load_fixture("antigravity_quota.json")
            raise dashboard.FetchError("auth", "HTTP 401")

        out = dashboard.fetch_antigravity(
            discover=lambda: ([4001, 4002], ["tok-a", "tok-b"]), post=fake_post)
        self.assertEqual(out["Weekly - Gemini"]["pct"], 65.0)
        # probed 4001×(a,b,None) then 4002×(a,b) — first 200 wins, no None probe
        self.assertEqual(len(seen), 5)
        self.assertIn("/exa.language_server_pb.LanguageServerService"
                      "/RetrieveUserQuotaSummary", seen[0][0])

    def test_fetch_antigravity_not_running_is_auth_error(self):
        import dashboard

        def not_running():
            raise dashboard.FetchError("auth", "antigravity not running")

        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.fetch_antigravity(discover=not_running,
                                        post=lambda *a, **k: {})
        self.assertEqual(cm.exception.category, "auth")

    def test_weekly_utilization_peaks_per_window(self):
        import dashboard
        wk = 7 * 86400
        # Two reset windows a week apart; reset epoch jitters sub-second between
        # polls but must collapse to one window. Peak is the max within each.
        r1, r2 = 1_780_000_000.0, 1_780_000_000.0 + wk
        hist = [
            {"claude": {"weekly_all": {"pct": 20.0, "resets_at": dashboard.epoch_to_iso(r1)},
                        "session": {"pct": 99.0, "reset_at": r1, "window_seconds": 18000}}},
            {"claude": {"weekly_all": {"pct": 46.0, "resets_at": dashboard.epoch_to_iso(r1 + 0.4)}}},
            {"claude": {"weekly_all": {"pct": 30.0, "resets_at": dashboard.epoch_to_iso(r1 + 0.9)}}},
            {"claude": {"weekly_all": {"pct": 7.0, "resets_at": dashboard.epoch_to_iso(r2)}}},
        ]
        out = dashboard.weekly_utilization(history=hist)
        lane = next(l for l in out if l["label"] == "weekly_all")
        self.assertEqual(lane["count"], 2)               # two windows, jitter collapsed
        self.assertEqual(lane["windows"][0]["peak"], 46.0)  # peak, not last, within window 1
        self.assertEqual(lane["windows"][1]["peak"], 7.0)
        self.assertEqual(lane["max"], 46.0)
        self.assertEqual(lane["avg"], 26.5)
        # the 5-hour session lane is rolling → excluded from the subscription view
        self.assertFalse(any(l["label"] == "session" for l in out))

    def test_non_finite_vendor_numbers_are_parse_errors(self):
        # float("NaN")/"inf" succeed, then break JSON serialization of /api and
        # render as garbage; every parser must reject them at the boundary.
        import dashboard
        p = load_fixture("claude_usage.json")
        for e in p["limits"]:
            if e["kind"] == "weekly_all": e["percent"] = "NaN"
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.parse_claude(p)
        self.assertEqual(cm.exception.category, "parse")
        c = load_fixture("cursor_usage.json")
        c["planUsage"]["autoPercentUsed"] = "Infinity"
        with self.assertRaises(dashboard.FetchError):
            dashboard.parse_cursor(c)
        a = load_fixture("antigravity_quota.json")
        a["response"]["groups"][0]["buckets"][0]["remainingFraction"] = "NaN"
        with self.assertRaises(dashboard.FetchError):
            dashboard.parse_antigravity(a)

    def test_num_rejects_absurd_but_accepts_ms_epochs(self):
        # A finite 1e300 percent traps the Swift port's Int() render sites and
        # renders as garbage here — same boundary rejects it. Millisecond
        # billing epochs (~1.8e12) must still pass.
        import dashboard
        with self.assertRaises(ValueError):
            dashboard._num(1e300)
        with self.assertRaises(ValueError):
            dashboard._num(-1e15)
        self.assertEqual(dashboard._num(1.8e12), 1.8e12)

    def test_derived_percent_overflow_rejected_python(self):
        # -9e14 passes the raw bound but derives an absurd percent — the
        # derived value is re-validated at construction.
        import dashboard
        payload = {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
            {"window": "weekly", "resetTime": "2026-08-24T09:00:00Z",
             "remainingFraction": -9e14}]}]}}
        with self.assertRaises(dashboard.FetchError):
            dashboard.parse_antigravity(payload)
        cp = load_fixture("copilot_user.json")
        lane = next(iter(cp["quota_snapshots"]))
        # Raw value passes the 1e15 bound; derived 100 - remaining crosses it.
        cp["quota_snapshots"][lane]["percent_remaining"] = -(1e15 - 50)
        out = dashboard.parse_copilot(cp)  # that lane skipped, or none at all
        self.assertNotIn(lane, out)

    def _cursor_db(self, dirpath, token="not set"):
        import base64, sqlite3
        if token == "not set":
            payload = base64.urlsafe_b64encode(
                json.dumps({"sub": "auth0|user_cursor123"}).encode()).rstrip(b"=").decode()
            token = f"eyJhbGciOiJSUzI1NiJ9.{payload}.sig"
        db = Path(dirpath) / "state.vscdb"
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
        if token is not None:
            con.execute("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", (token,))
        con.commit()
        con.close()
        return db

    def test_read_cursor_session_ok(self):
        import dashboard
        with tempfile.TemporaryDirectory() as d:
            uid, tok = dashboard.read_cursor_session(db_path=self._cursor_db(d))
            self.assertEqual(uid, "user_cursor123")
            self.assertEqual(tok.count("."), 2)

    def test_read_cursor_session_missing_db_or_key_is_auth_error(self):
        import dashboard
        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.read_cursor_session(db_path=Path("/nonexistent/state.vscdb"))
        self.assertEqual(cm.exception.category, "auth")
        with tempfile.TemporaryDirectory() as d:
            db = self._cursor_db(d, token=None)  # table exists, no token row
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.read_cursor_session(db_path=db)
            self.assertEqual(cm.exception.category, "auth")

    def test_read_cursor_session_non_jwt_is_auth_error(self):
        import dashboard
        with tempfile.TemporaryDirectory() as d:
            db = self._cursor_db(d, token="garbage-token")
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.read_cursor_session(db_path=db)
            self.assertEqual(cm.exception.category, "auth")

    def test_fetch_cursor_wires_cookie_and_parser(self):
        import dashboard
        seen = {}

        def fake_post(url, headers, body, opener=None):
            seen["url"], seen["headers"], seen["body"] = url, headers, body
            return load_fixture("cursor_usage.json")

        out = dashboard.fetch_cursor(read_session=lambda: ("user_cursor123", "tok.abc.def"),
                                     post=fake_post)
        self.assertEqual(out["monthly_auto"]["pct"], 7.4)
        self.assertEqual(seen["url"], "https://cursor.com/api/dashboard/get-current-period-usage")
        self.assertEqual(seen["headers"]["Cookie"],
                         "WorkosCursorSessionToken=user_cursor123%3A%3Atok.abc.def")
        self.assertEqual(seen["body"], {})

    def test_fetch_codex_wires_creds_and_parser(self):
        import dashboard
        seen = {}

        def fake_get(url, headers, opener=None):
            seen["url"], seen["headers"] = url, headers
            return load_fixture("codex_usage.json")

        out = dashboard.fetch_codex(read_creds=lambda: ("ct", "acc"), get=fake_get)
        self.assertEqual(out["weekly"]["pct"], 28.0)
        self.assertEqual(seen["url"], "https://chatgpt.com/backend-api/codex/usage")
        self.assertEqual(seen["headers"]["chatgpt-account-id"], "acc")
        self.assertEqual(seen["headers"]["User-Agent"], "codex-cli")


import threading


class SignalingLock:
    """Drop-in replacement for dashboard.fetch_lock in tests.

    Delegates to a real lock but releases one semaphore permit per acquisition
    ATTEMPT (before blocking). Because refresh() captures its generation before
    attempting fetch_lock, each permit proves the corresponding caller already
    holds a pre-poll generation. Production code is unchanged: refresh() uses
    plain `with fetch_lock:` and this object supports the context protocol.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._attempts = threading.Semaphore(0)

    def wait_for_attempts(self, n, timeout=10):
        return all(self._attempts.acquire(timeout=timeout) for _ in range(n))

    def __enter__(self):
        self._attempts.release()  # signal the attempt, then block like a Lock
        self._lock.acquire()
        return self

    def __exit__(self, *exc):
        self._lock.release()
        return False


class TestRefresh(unittest.TestCase):
    def setUp(self):
        import dashboard
        dashboard.reset_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.hpath = Path(self.tmp.name) / "history.jsonl"

    def tearDown(self):
        import dashboard
        dashboard.reset_state()
        self.tmp.cleanup()

    def test_refresh_prunes_history_older_than_60_days(self):
        # Retention must hold continuously (memory AND disk), not only across
        # restarts via load_history.
        import dashboard
        now = 1_800_000_000.0
        old_ts = now - 61 * 86400
        old = {"ts": dashboard.epoch_to_iso(old_ts), "ts_epoch": old_ts}
        self.hpath.write_text(json.dumps({"ts": old["ts"]}) + "\n")
        dashboard.HISTORY.append(old)
        dashboard.refresh(force=True, now_fn=lambda: now,
                          fetchers={"claude": lambda: dashboard.parse_claude(
                              load_fixture("claude_usage.json"))},
                          history_path=self.hpath)
        self.assertEqual(len(dashboard.HISTORY), 1)  # only the new snapshot
        self.assertTrue(all(s["ts_epoch"] >= now - 60 * 86400
                            for s in dashboard.HISTORY))
        lines = self.hpath.read_text().splitlines()
        self.assertEqual(len(lines), 1)              # old line gone from disk
        self.assertNotIn(old["ts"], lines[0])

    def fetchers(self, claude_result="ok", codex_result="ok", counter=None):
        import dashboard

        def make(name, result):
            def f():
                if counter is not None:
                    counter[name] = counter.get(name, 0) + 1
                if result == "ok":
                    if name == "claude":
                        return dashboard.parse_claude(load_fixture("claude_usage.json"))
                    return dashboard.parse_codex(load_fixture("codex_usage.json"))
                raise dashboard.FetchError(result, "injected failure")
            return f

        return {"claude": make("claude", claude_result), "codex": make("codex", codex_result)}

    def test_success_updates_state_and_appends_once(self):
        import dashboard
        dashboard.refresh(force=True, fetchers=self.fetchers(), history_path=self.hpath)
        self.assertEqual(dashboard.STATE["claude"]["status"], "fresh")
        self.assertEqual(dashboard.STATE["codex"]["data"]["weekly"]["pct"], 28.0)
        self.assertEqual(len(self.hpath.read_text().splitlines()), 1)
        self.assertEqual(len(dashboard.HISTORY), 1)

    def test_cache_served_refresh_appends_nothing(self):
        import dashboard
        dashboard.refresh(force=True, fetchers=self.fetchers(), history_path=self.hpath)
        dashboard.refresh(force=False, fetchers=self.fetchers(), history_path=self.hpath)
        self.assertEqual(len(self.hpath.read_text().splitlines()), 1)

    def test_auth_failure_marks_stale_keeps_other_service(self):
        import dashboard
        dashboard.refresh(force=True, fetchers=self.fetchers(), history_path=self.hpath)
        dashboard.refresh(force=True, fetchers=self.fetchers(codex_result="auth"),
                          history_path=self.hpath)
        codex = dashboard.STATE["codex"]
        self.assertEqual(codex["status"], "stale")
        self.assertEqual(codex["error"]["category"], "auth")
        self.assertEqual(codex["data"]["weekly"]["pct"], 28.0)  # last-known kept
        self.assertEqual(dashboard.STATE["claude"]["status"], "fresh")
        lines = self.hpath.read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIsNone(json.loads(lines[1])["codex"])  # failed service recorded as null

    def test_failure_with_no_prior_data_is_never(self):
        import dashboard
        dashboard.refresh(force=True, fetchers=self.fetchers(codex_result="network"),
                          history_path=self.hpath)
        self.assertEqual(dashboard.STATE["codex"]["status"], "never")
        self.assertIsNone(dashboard.STATE["codex"]["data"])

    def test_single_flight_in_flight_poll_shared_by_forced_and_unforced(self):
        # Deterministic: t1 forces a poll and is held in-flight; an instrumented
        # lock (patched in as dashboard.fetch_lock) signals every acquisition
        # ATTEMPT. refresh() captures its generation strictly before attempting
        # fetch_lock, so once t2 (force=True) and t3 (force=False) have each
        # signaled an attempt while t1 still holds the lock, both provably hold
        # a pre-poll generation. Releasing t1 must then coalesce all three into
        # ONE poll. No reliance on now_fn(): a forced sharer may never call it.
        import dashboard
        from unittest import mock
        counter = {}
        in_flight = threading.Event()
        release = threading.Event()
        lock = SignalingLock()

        def make(name, parse, fixture):
            def f():
                counter[name] = counter.get(name, 0) + 1
                if name == "claude":
                    in_flight.set()
                    assert release.wait(10)
                return parse(load_fixture(fixture))
            return f

        fetchers = {"claude": make("claude", dashboard.parse_claude, "claude_usage.json"),
                    "codex": make("codex", dashboard.parse_codex, "codex_usage.json")}
        threads = []
        try:
            with mock.patch.object(dashboard, "fetch_lock", lock):
                t1 = threading.Thread(target=dashboard.refresh, daemon=True,
                                      kwargs=dict(force=True, fetchers=fetchers,
                                                  history_path=self.hpath))
                t1.start()
                threads.append(t1)
                self.assertTrue(lock.wait_for_attempts(1))   # t1 reached the lock...
                self.assertTrue(in_flight.wait(10))          # ...and now holds it, mid-poll
                t2 = threading.Thread(target=dashboard.refresh, daemon=True,
                                      kwargs=dict(force=True, fetchers=fetchers,
                                                  history_path=self.hpath))
                t3 = threading.Thread(target=dashboard.refresh, daemon=True,
                                      kwargs=dict(force=False, fetchers=fetchers,
                                                  history_path=self.hpath))
                t2.start()
                t3.start()
                threads.extend([t2, t3])
                # Both waiters confirmed queued at fetch_lock (generations captured).
                self.assertTrue(lock.wait_for_attempts(2))
                release.set()
                for t in threads:
                    t.join(10)
                    self.assertFalse(t.is_alive())
        finally:
            # Failure-safe cleanup: a failed assertion above must never strand
            # the daemon threads on the held lock.
            release.set()
            for t in threads:
                t.join(5)
        self.assertEqual(counter["claude"], 1)   # t2 and t3 shared t1's poll
        self.assertEqual(counter["codex"], 1)
        self.assertEqual(len(self.hpath.read_text().splitlines()), 1)

    def test_later_independent_force_polls_again(self):
        import dashboard
        counter = {}
        fetchers = self.fetchers(counter=counter)
        dashboard.refresh(force=True, fetchers=fetchers, history_path=self.hpath)
        dashboard.refresh(force=True, fetchers=fetchers, history_path=self.hpath)
        self.assertEqual(counter["claude"], 2)   # sequential forces are independent polls
        self.assertEqual(len(self.hpath.read_text().splitlines()), 2)

    def test_seed_state_from_history(self):
        import dashboard
        dashboard.HISTORY.extend([
            {"ts": "2026-07-12T10:00:00Z", "ts_epoch": 1.0,
             "claude": {"weekly_all": {"pct": 30.0, "resets_at": "2026-07-16T07:00:00+00:00"}},
             "codex": None},
        ])
        dashboard.seed_state_from_history()
        self.assertEqual(dashboard.STATE["claude"]["status"], "stale")
        self.assertEqual(dashboard.STATE["codex"]["status"], "never")


class TestApiPayload(unittest.TestCase):
    def setUp(self):
        import dashboard
        dashboard.reset_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.hpath = Path(self.tmp.name) / "history.jsonl"

    def tearDown(self):
        import dashboard
        dashboard.reset_state()
        self.tmp.cleanup()

    def test_payload_shape_and_derived(self):
        import dashboard
        fetchers = {"claude": lambda: dashboard.parse_claude(load_fixture("claude_usage.json")),
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json")),
                    "cursor": lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))}
        now = 1783900000.0  # inside all fixture windows (resets 1784359050 / 2026-07-16 / 2026-07-29)
        dashboard.refresh(force=True, now_fn=lambda: now, fetchers=fetchers,
                          history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: now)
        self.assertEqual(sorted(p.keys()),
                         ["antigravity", "claude", "codex", "copilot", "cursor",
                          "derived", "history", "server_time"])
        self.assertEqual(p["claude"]["status"], "fresh")
        self.assertIsNone(p["claude"]["error"])
        d = p["derived"]["codex"]["weekly"]
        self.assertEqual(d["pct"], 28.0)
        self.assertIn(d["pace"], ("under", "on", "over"))
        self.assertAlmostEqual(d["reset_epoch"], 1784359050.0)
        self.assertIn("exhaust_epoch", d["projection"])
        self.assertEqual(len(p["history"]["codex"]["weekly"]), 1)
        self.assertIn("weekly_scoped", p["derived"]["claude"])
        cu = p["derived"]["cursor"]["monthly_api"]
        self.assertEqual(cu["pct"], 44.3)
        self.assertAlmostEqual(cu["reset_epoch"], 1785318336.0)
        self.assertIn("monthly_auto", p["derived"]["cursor"])
        self.assertTrue(json.dumps(p))  # JSON-serializable

    def test_derived_has_window_seconds(self):
        import dashboard
        fetchers = {"claude": lambda: dashboard.parse_claude(load_fixture("claude_usage.json")),
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json")),
                    "cursor": lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))}
        now = 1783890000.0  # inside the 5h rolling window (resets 1783893080) and all others
        dashboard.refresh(force=True, now_fn=lambda: now, fetchers=fetchers,
                          history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: now)
        sub6h = 0
        for svc in ("claude", "codex", "cursor"):
            data = p[svc]["data"]
            for label, path in dashboard.limit_paths(svc, data):
                ws = p["derived"][svc][label]["window_seconds"]
                self.assertEqual(ws, dashboard.window_seconds_of(dashboard.get_limit(data, path)))
                if ws < 21600:
                    sub6h += 1
        self.assertEqual(sub6h, 2)  # one Claude + one Codex rolling limit

    def test_codex_rolling_derived_window_seconds(self):
        import dashboard
        fetchers = {"claude": lambda: dashboard.parse_claude(load_fixture("claude_usage.json")),
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json")),
                    "cursor": lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))}
        now = 1783890000.0
        dashboard.refresh(force=True, now_fn=lambda: now, fetchers=fetchers,
                          history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: now)
        self.assertEqual(p["derived"]["codex"]["rolling"]["window_seconds"], 18000.0)

    def test_derived_carries_blocked_and_remaining(self):
        import dashboard
        fetchers = {"claude": lambda: dashboard.parse_claude(load_fixture("claude_usage.json")),
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json")),
                    "cursor": lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))}
        now = 1783890000.0
        dashboard.refresh(force=True, now_fn=lambda: now, fetchers=fetchers,
                          history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: now)
        for svc in ("claude", "codex", "cursor"):
            for v in p["derived"][svc].values():
                self.assertIsInstance(v["blocked"], bool)
                self.assertIn("remaining", v)
        self.assertIsNone(p["derived"]["cursor"]["monthly_api"]["remaining"])
        self.assertIsNone(p["derived"]["codex"]["weekly"]["remaining"])

    def test_payload_never_state(self):
        import dashboard
        p = dashboard.api_payload(now_fn=lambda: 1783900000.0)
        for svc in ("claude", "codex", "cursor"):
            self.assertEqual(p[svc]["status"], "never")
            self.assertIsNone(p[svc]["data"])
            self.assertEqual(p["derived"][svc], {})

    def test_partial_fetchers_leave_other_services_untouched(self):
        import dashboard
        fetchers = {"claude": lambda: dashboard.parse_claude(load_fixture("claude_usage.json")),
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))}
        dashboard.refresh(force=True, fetchers=fetchers, history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: 1783900000.0)
        self.assertEqual(p["claude"]["status"], "fresh")
        self.assertEqual(p["cursor"]["status"], "never")  # not in fetchers: untouched
        self.assertNotIn("cursor", json.loads(self.hpath.read_text().splitlines()[0]))


from unittest import mock
import urllib.request as _urlreq


class TestServerIntegration(unittest.TestCase):
    def setUp(self):
        import dashboard
        dashboard.reset_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.hpath = Path(self.tmp.name) / "history.jsonl"

    def tearDown(self):
        import dashboard
        dashboard.reset_state()
        self.tmp.cleanup()

    def _serve(self):
        import dashboard
        srv = dashboard.make_server(0)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        self.addCleanup(srv.shutdown)
        self.addCleanup(srv.server_close)
        return srv.server_address[1]

    def test_binds_loopback_only(self):
        import dashboard
        srv = dashboard.make_server(0)
        self.assertEqual(srv.server_address[0], "127.0.0.1")
        srv.server_close()

    def test_open_antigravity_endpoint(self):
        import dashboard
        with mock.patch.object(dashboard.subprocess, "Popen") as popen:
            port = self._serve()
            req = _urlreq.Request(f"http://127.0.0.1:{port}/api/open-antigravity",
                                  data=b"", method="POST")
            with _urlreq.urlopen(req, timeout=10) as r:
                self.assertEqual(r.status, 200)
        popen.assert_called_once_with(["open", "-a", "Antigravity IDE"])

    def test_post_unknown_path_404(self):
        port = self._serve()
        req = _urlreq.Request(f"http://127.0.0.1:{port}/api/usage", data=b"", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            _urlreq.urlopen(req, timeout=10)
        self.assertEqual(cm.exception.code, 404)
        cm.exception.close()  # deterministic: don't leave the 404 body to GC

    def test_degraded_codex_auth_other_service_survives(self):
        import dashboard

        def failing_codex():
            raise dashboard.FetchError("auth", "injected: token expired")

        ok_claude = lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))
        with mock.patch.object(dashboard, "fetch_claude", ok_claude), \
             mock.patch.object(dashboard, "fetch_codex", failing_codex), \
             mock.patch.object(dashboard, "fetch_cursor",
                               lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))), \
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            with _urlreq.urlopen(f"http://127.0.0.1:{port}/api/usage", timeout=10) as r:
                body = r.read()
        p = json.loads(body)
        self.assertEqual(p["claude"]["status"], "fresh")
        self.assertEqual(p["claude"]["data"]["weekly_all"]["pct"], 32.0)
        self.assertEqual(p["codex"]["status"], "never")
        self.assertEqual(p["codex"]["error"]["category"], "auth")
        self.assertEqual(len(self.hpath.read_text().splitlines()), 1)

    def test_root_serves_html_and_unknown_404(self):
        import dashboard
        with mock.patch.object(dashboard, "fetch_claude",
                               lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))), \
             mock.patch.object(dashboard, "fetch_codex",
                               lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))), \
             mock.patch.object(dashboard, "fetch_cursor",
                               lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))), \
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            with _urlreq.urlopen(f"http://127.0.0.1:{port}/", timeout=10) as r:
                html = r.read().decode()
            self.assertIn("<!DOCTYPE html>", html)
            with self.assertRaises(urllib.error.HTTPError) as cm:
                _urlreq.urlopen(f"http://127.0.0.1:{port}/nope", timeout=10)
            self.assertEqual(cm.exception.code, 404)
            cm.exception.close()  # deterministic: don't leave the 404 body to GC

    def test_rejects_spoofed_host_and_cross_site(self):
        # DNS-rebinding defense: a rebound page carries Host: attacker.com, and
        # a cross-site fetch carries Sec-Fetch-Site: cross-site. Both → 403.
        import dashboard
        with mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            for headers in ({"Host": "attacker.com"},
                            {"Host": f"127.0.0.1:{port}", "Sec-Fetch-Site": "cross-site"}):
                req = _urlreq.Request(f"http://127.0.0.1:{port}/api/history", headers=headers)
                with self.assertRaises(urllib.error.HTTPError) as cm:
                    _urlreq.urlopen(req, timeout=10)
                self.assertEqual(cm.exception.code, 403)
                cm.exception.close()
            # A same-origin loopback Host still passes to the normal handler.
            ok = _urlreq.Request(f"http://127.0.0.1:{port}/",
                                 headers={"Host": f"127.0.0.1:{port}"})
            with _urlreq.urlopen(ok, timeout=10) as r:
                self.assertEqual(r.status, 200)

    def test_security_headers_on_every_response(self):
        import dashboard
        with mock.patch.object(dashboard, "fetch_claude",
                               lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))), \
             mock.patch.object(dashboard, "fetch_codex",
                               lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))), \
             mock.patch.object(dashboard, "fetch_cursor",
                               lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))), \
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            for path in ("/", "/api/usage"):
                with _urlreq.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
                    self.assertEqual(r.headers["Cache-Control"], "no-store", path)
                    self.assertEqual(r.headers["X-Content-Type-Options"], "nosniff", path)
            with self.assertRaises(urllib.error.HTTPError) as cm:
                _urlreq.urlopen(f"http://127.0.0.1:{port}/nope", timeout=10)
            self.assertEqual(cm.exception.headers["Cache-Control"], "no-store")
            self.assertEqual(cm.exception.headers["X-Content-Type-Options"], "nosniff")
            cm.exception.close()  # deterministic: don't leave the 404 body to GC


class TestHtmlPage(unittest.TestCase):
    def test_weekly_bars_have_six_subtle_day_ticks(self):
        import dashboard
        self.assertIn('.win.weekly::after', dashboard.HTML_PAGE)
        self.assertIn('inset:0 calc(100% / 7) 0 0', dashboard.HTML_PAGE)
        self.assertIn('color-mix(in srgb, var(--faint) 35%, transparent)', dashboard.HTML_PAGE)
        self.assertIn('calc(100% / 6)', dashboard.HTML_PAGE)
        self.assertIn('" weekly"', dashboard.HTML_PAGE)
        self.assertIn('key === "monthly" ? "today"', dashboard.HTML_PAGE)
        # Rolling's now-marker carries the clock time ("18:42").
        self.assertIn('key === "rolling" ? new Date().toLocaleTimeString', dashboard.HTML_PAGE)

    def test_page_has_required_elements(self):
        import dashboard
        page = dashboard.HTML_PAGE
        for needle in ('<!DOCTYPE html>', 'lang="en"', 'viewport',
                       'prefers-color-scheme: dark', 'role="progressbar"',
                       'aria-valuenow', 'aria-hidden', 'aria-live="polite"',
                       '/api/usage', '5 * 60 * 1000',
                       'grid-template-columns', 'max-width: 420px',
                       'id="board"', 'function ageText', 'page refreshed ',
                       "Can't reach", 'Weekly - Opus and above',
                       'Monthly - included usage'):
            self.assertIn(needle, page, needle)
        self.assertNotIn("Bearer", page)
        # stale content must remain readable: no whole-card/banner opacity fade
        self.assertNotIn("opacity:.", page)
        self.assertNotIn("opacity: .", page)
        self.assertNotIn("opacity:0.", page)

    def test_background_picker_on_both_pages(self):
        # Per-scheme user background, shared localStorage keys, edit both together.
        import dashboard
        for page in (dashboard.HTML_PAGE, dashboard.HISTORY_PAGE):
            for needle in ('id="bgl"', 'id="bgd"', 'id="bgreset"',
                           '"bgDark" : "bgLight"',
                           'setProperty("--page"', 'removeProperty("--page")',
                           # PRODUCT.md contrast rule: stored values only apply
                           # when bgOK passes; failing picks snap back.
                           'function bgOK(', '>= 4.5',
                           'if (c && bgOK(c, m === "dark"))',
                           'if (!bgOK(pick[m].value, m === "dark"))'):
                self.assertIn(needle, page, needle)


class TestDocs(unittest.TestCase):
    def test_docs_name_all_five_providers(self):
        # Docs must describe the five-provider reality — no retired Gemini,
        # no stale "four providers" counts.
        root = Path(__file__).resolve().parent
        for rel in ("README.md", "PRODUCT.md", "macos/README.md"):
            text = (root / rel).read_text()
            for name in ("Claude", "Codex", "Cursor", "Antigravity", "Copilot"):
                self.assertIn(name, text, rel)
            self.assertNotIn("Gemini", text, rel)
            self.assertNotIn("four providers", text, rel)


class TestGeminiRetired(unittest.TestCase):
    def test_gemini_provider_fully_retired(self):
        # gemini-cli was removed 2026-08-20; only Antigravity's Gemini POOL
        # label may remain. Revive the provider from git history if ever needed.
        import dashboard
        self.assertFalse(hasattr(dashboard, "parse_gemini"))
        self.assertFalse(hasattr(dashboard, "fetch_gemini"))
        self.assertNotIn("gemini", dashboard.HTML_PAGE)
        self.assertNotIn("gemini", dashboard.SERVICES)


class TestLaneOrder(unittest.TestCase):
    def test_lanes_sorted_globally_worst_first(self):
        # Merged-board spec line 104: worst pace first (over → on → under),
        # tiebreak soonest reset — GLOBAL order, no provider clustering.
        import dashboard
        self.assertIn("(RANK[a.d.pace] - RANK[b.d.pace]) || (a.d.reset_epoch - b.d.reset_epoch)",
                      dashboard.HTML_PAGE)
        self.assertNotIn("worst[a.svc]", dashboard.HTML_PAGE)


class TestMainOnce(unittest.TestCase):
    def test_once_prints_payload_and_seeds_history(self):
        import dashboard
        dashboard.reset_state()
        with tempfile.TemporaryDirectory() as d:
            hpath = Path(d) / "history.jsonl"
            with mock.patch.object(dashboard, "HISTORY_PATH", hpath), \
                 mock.patch.object(dashboard, "fetch_claude",
                                   lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))), \
                 mock.patch.object(dashboard, "fetch_codex",
                                   lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))), \
                 mock.patch.object(dashboard, "fetch_cursor",
                                   lambda: dashboard.parse_cursor(load_fixture("cursor_usage.json"))), \
                 mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                rc = dashboard.main(["--once"])
            self.assertEqual(rc, 0)
            payload = json.loads(out.getvalue())
            self.assertEqual(payload["claude"]["status"], "fresh")
            self.assertEqual(len(hpath.read_text().splitlines()), 1)
        dashboard.reset_state()

    def test_poll_loop_survives_exceptions(self):
        import dashboard
        stop = threading.Event()
        calls = {"n": 0}

        def boom(**kwargs):
            calls["n"] += 1
            if calls["n"] >= 3:
                stop.set()
            raise RuntimeError("injected")

        with mock.patch.object(dashboard, "refresh", boom), \
             mock.patch.object(dashboard, "POLL_SECONDS", 0.01):
            dashboard.poll_loop(stop)
        self.assertGreaterEqual(calls["n"], 3)  # kept looping despite exceptions


class TestInstallScripts(unittest.TestCase):
    """Run the real installer scripts hermetically: HOME in a temp dir,
    launchctl replaced via the LAUNCHCTL env override (true/false), plutil
    optionally shimmed via PATH. Nothing touches the live LaunchAgents."""
    ROOT = Path(__file__).resolve().parent

    def _run(self, script, home, launchctl, path_prefix=None):
        import os
        import subprocess
        env = {**os.environ, "HOME": str(home), "LAUNCHCTL": launchctl}
        if path_prefix:
            env["PATH"] = f"{path_prefix}:{env['PATH']}"
        return subprocess.run(["bash", str(self.ROOT / script)],
                              capture_output=True, text=True, cwd=self.ROOT, env=env)

    def test_bash_syntax(self):
        import subprocess
        for s in ("install.sh", "install-canary.sh", "uninstall.sh"):
            cp = subprocess.run(["bash", "-n", str(self.ROOT / s)],
                                capture_output=True, text=True)
            self.assertEqual(cp.returncode, 0, f"{s}: {cp.stderr}")

    def test_clean_install_renders_valid_plist_no_debris(self):
        import subprocess
        for script, label in (("install.sh", "com.kamil.usage-dashboard"),
                              ("install-canary.sh", "com.kamil.usagebar-canary")):
            with tempfile.TemporaryDirectory() as d:
                cp = self._run(script, d, "true")  # launchctl stubbed out
                self.assertEqual(cp.returncode, 0, f"{script}: {cp.stderr}")
                agents = Path(d) / "Library/LaunchAgents"
                plist = agents / f"{label}.plist"
                self.assertTrue(plist.exists(), script)
                self.assertEqual(subprocess.run(["plutil", "-lint", str(plist)],
                                                capture_output=True).returncode, 0)
                leftovers = [p.name for p in agents.iterdir() if p.name != plist.name]
                self.assertEqual(leftovers, [], script)

    def test_validation_failure_leaves_prior_plist_and_no_debris(self):
        import os
        with tempfile.TemporaryDirectory() as d:
            agents = Path(d) / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            plist = agents / "com.kamil.usage-dashboard.plist"
            plist.write_text("PRIOR-WORKING-PLIST")
            shim = Path(d) / "bin"
            shim.mkdir()
            fake = shim / "plutil"
            fake.write_text("#!/bin/sh\nexit 1\n")
            os.chmod(fake, 0o755)
            cp = self._run("install.sh", d, "true", path_prefix=shim)
            self.assertNotEqual(cp.returncode, 0)
            self.assertEqual(plist.read_text(), "PRIOR-WORKING-PLIST")
            leftovers = [p.name for p in agents.iterdir() if p.name != plist.name]
            self.assertEqual(leftovers, [])

    def test_replacement_mv_failure_leaves_prior_plist_and_no_debris(self):
        # Force the validated NEW -> PLIST mv to fail AFTER the backup was
        # created: the sentinel live plist must survive untouched and no
        # .new*/.bak debris may remain (any-failure/no-debris guarantee).
        import os
        for script, label in (("install.sh", "com.kamil.usage-dashboard"),
                              ("install-canary.sh", "com.kamil.usagebar-canary")):
            with tempfile.TemporaryDirectory() as d:
                agents = Path(d) / "Library/LaunchAgents"
                agents.mkdir(parents=True)
                plist = agents / f"{label}.plist"
                plist.write_text("PRIOR-WORKING-PLIST")
                shim = Path(d) / "bin"
                shim.mkdir()
                fake = shim / "mv"
                fake.write_text("#!/bin/sh\nexit 1\n")
                os.chmod(fake, 0o755)
                cp = self._run(script, d, "true", path_prefix=shim)
                self.assertNotEqual(cp.returncode, 0, script)
                self.assertEqual(plist.read_text(), "PRIOR-WORKING-PLIST", script)
                leftovers = [p.name for p in agents.iterdir() if p.name != plist.name]
                self.assertEqual(leftovers, [], script)

    def test_bootstrap_failure_restores_prior_plist(self):
        with tempfile.TemporaryDirectory() as d:
            agents = Path(d) / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            plist = agents / "com.kamil.usage-dashboard.plist"
            plist.write_text("PRIOR-WORKING-PLIST")
            cp = self._run("install.sh", d, "false")  # every launchctl fails
            self.assertNotEqual(cp.returncode, 0)
            self.assertEqual(plist.read_text(), "PRIOR-WORKING-PLIST",
                             "prior plist must be restored byte-identical")
            self.assertIn("restored", cp.stderr)
            leftovers = [p.name for p in agents.iterdir() if p.name != plist.name]
            self.assertEqual(leftovers, [])


class TestRedirects(unittest.TestCase):
    def test_cross_origin_redirect_refused(self):
        # A 302 from origin A to origin B must NOT be followed: urllib would
        # re-send the Authorization header to B. The fetch fails as "network"
        # and B never sees a single request.
        import dashboard
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        hits = []

        class B(BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(dict(self.headers))
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *a):
                pass

        srv_b = ThreadingHTTPServer(("127.0.0.1", 0), B)
        port_b = srv_b.server_address[1]

        class A(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{port_b}/steal")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *a):
                pass

        srv_a = ThreadingHTTPServer(("127.0.0.1", 0), A)
        port_a = srv_a.server_address[1]
        for srv in (srv_a, srv_b):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.server_close)
            self.addCleanup(srv.shutdown)

        with self.assertRaises(dashboard.FetchError) as cm:
            dashboard.http_get_json(f"http://127.0.0.1:{port_a}/usage",
                                    {"Authorization": "Bearer secret-token"})
        self.assertEqual(cm.exception.category, "network")
        self.assertIn("302", cm.exception.detail)
        self.assertEqual(hits, [])  # the credential never left origin A


if __name__ == "__main__":
    unittest.main(verbosity=2)
