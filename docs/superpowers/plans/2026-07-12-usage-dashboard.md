# Usage Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the local Claude/Codex weekly-usage dashboard defined in `docs/superpowers/specs/2026-07-12-usage-dashboard-design.md` (accepted at commit `8e04800`).

**Architecture:** One self-contained `dashboard.py` (Python 3 stdlib only) serving an embedded HTML page on `127.0.0.1:8787`, with a 20-minute poll thread, single-flight refresh, JSONL history, and per-service stale state. Deployed via a tracked launchd plist template + install/uninstall scripts.

**Tech Stack:** Python 3 stdlib (`http.server`, `threading`, `urllib`, `json`, `unittest`), bash, launchd. No pip/npm dependencies.

## Global Constraints

- Python 3 **stdlib only** — no pip installs, no venv; tests run with `python3 test_dashboard.py -v`.
- Server binds **exactly** `("127.0.0.1", port)` — never `0.0.0.0`, `""`, or `::`. Default port `8787`.
- Tokens are read fresh per poll; **never** written to disk, logs, `/api/usage`, `history.jsonl`, or committed files.
- Tests and all verification steps must **NEVER rename, modify, or delete** the real `~/.codex/auth.json` or the `Claude Code-credentials` Keychain item. Degraded-auth behavior is exercised only through injected fakes and temp paths.
- Exactly one JSONL line appended per completed combined poll (upstream actually hit); cache-served refreshes append nothing.
- Per-limit window math derives each limit's window start from **that limit's own** reset timestamp.
- Generated user-specific plist is never committed; only `launchd/*.template`, `install.sh`, `uninstall.sh` are tracked.
- Commit after every task with the trailer lines used in this repo's prior commits (Co-Authored-By + Claude-Session).

**File map (final state):**

| Path | Responsibility |
|---|---|
| `dashboard.py` | The entire app: parsers, math, state, refresh, history IO, HTTP server, embedded UI, poll loop, `main()` |
| `test_dashboard.py` | All unit + integration tests (stdlib `unittest`) |
| `fixtures/claude_usage.json` | Sanitized real Claude OAuth usage payload (captured 2026-07-12) |
| `fixtures/codex_usage.json` | Sanitized real Codex usage payload (captured 2026-07-12) |
| `launchd/com.kamil.usage-dashboard.plist.template` | launchd agent template with `__PROJECT_DIR__`/`__HOME__`/`__PYTHON__` placeholders |
| `install.sh` / `uninstall.sh` | Render template → `~/Library/LaunchAgents`, bootstrap/bootout |
| `README.md` | Operations manual |

---

### Task 1: Scaffolding + sanitized fixtures

**Files:**
- Create: `fixtures/claude_usage.json`, `fixtures/codex_usage.json`, `test_dashboard.py`, `dashboard.py`

**Interfaces:**
- Produces: fixture files whose shapes are byte-for-byte structurally identical to the real payloads captured 2026-07-12 (values sanitized); `load_fixture(name)` test helper.

- [ ] **Step 1: Write fixtures** (sanitized from the real captures — same keys, fake identifiers)

`fixtures/claude_usage.json`:
```json
{
  "five_hour": {"utilization": 23.0, "resets_at": "2026-07-12T20:30:00.009044+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
  "seven_day": {"utilization": 32.0, "resets_at": "2026-07-16T07:00:00.009069+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "monthly_limit": 10000, "used_credits": 0.0, "utilization": 0.0, "currency": "USD", "decimal_places": 2, "disabled_reason": "out_of_credits", "daily": null, "weekly": null},
  "limits": [
    {"kind": "session", "group": "session", "percent": 23, "severity": "normal", "resets_at": "2026-07-12T20:30:00.009044+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all", "group": "weekly", "percent": 32, "severity": "normal", "resets_at": "2026-07-16T07:00:00.009069+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 46, "severity": "normal", "resets_at": "2026-07-16T07:00:00.009069+00:00", "scope": "opus", "is_active": false}
  ]
}
```

`fixtures/codex_usage.json`:
```json
{
  "user_id": "user-SANITIZED",
  "account_id": "user-SANITIZED",
  "email": "sanitized@example.com",
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1783893080},
    "secondary_window": {"used_percent": 28, "limit_window_seconds": 604800, "reset_after_seconds": 483971, "reset_at": 1784359050}
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
     "rate_limit": {"allowed": true, "limit_reached": false,
       "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1783893080},
       "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604800, "reset_at": 1784479880}}}
  ],
  "credits": {"has_credits": false}
}
```

- [ ] **Step 2: Write the failing test skeleton**

`test_dashboard.py`:
```python
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
        self.assertIn("weekly_all", kinds)
        self.assertIn("weekly_scoped", kinds)

    def test_codex_fixture_shape(self):
        p = load_fixture("codex_usage.json")
        self.assertEqual(p["rate_limit"]["secondary_window"]["limit_window_seconds"], 604800)
        self.assertEqual(p["additional_rate_limits"][0]["limit_name"], "GPT-5.3-Codex-Spark")

    def test_dashboard_module_imports(self):
        import dashboard  # noqa: F401


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 3: Run tests — expect ONE failure** (`test_dashboard_module_imports`, `ModuleNotFoundError: dashboard`)

Run: `python3 test_dashboard.py -v`

- [ ] **Step 4: Create the module skeleton**

`dashboard.py`:
```python
#!/usr/bin/env python3
"""Local dashboard: Claude Code + Codex weekly subscription usage, side by side.

Spec: docs/superpowers/specs/2026-07-12-usage-dashboard-design.md
Stdlib only. Serves 127.0.0.1:8787. Tokens are never stored or logged.
"""
import argparse
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WEEK_SECONDS = 7 * 24 * 3600
DEFAULT_PORT = 8787
FRESH_SECONDS = 60          # cache freshness for page-triggered refresh
POLL_SECONDS = 20 * 60      # background poll cadence
HISTORY_DAYS = 60           # retention
BASE_DIR = Path(__file__).resolve().parent
HISTORY_PATH = BASE_DIR / "history.jsonl"
```

- [ ] **Step 5: Run tests — all 3 pass.** Run: `python3 test_dashboard.py -v` → `OK`

- [ ] **Step 6: Commit**
```bash
git add fixtures test_dashboard.py dashboard.py
git commit -m "feat: scaffolding and sanitized API fixtures"
```

---

### Task 2: Payload parsers

**Files:**
- Modify: `dashboard.py` (append after constants)
- Test: `test_dashboard.py` (append)

**Interfaces:**
- Produces:
  - `class FetchError(Exception)` with `.category` (`"auth"|"network"|"parse"`) and `.detail` (str)
  - `parse_claude(payload) -> dict` → `{"weekly_all": {"pct": float, "resets_at": str}, "weekly_scoped": {...}}` (`weekly_scoped` absent if not reported)
  - `parse_codex(payload) -> dict` → `{"weekly": {"pct": float, "reset_at": float, "window_seconds": float}, "models": {name: same-shape}}`

- [ ] **Step 1: Write failing tests** (append to `test_dashboard.py`, above the `__main__` block; all later test additions go there too)

```python
class TestParsers(unittest.TestCase):
    def test_parse_claude(self):
        import dashboard
        out = dashboard.parse_claude(load_fixture("claude_usage.json"))
        self.assertEqual(out["weekly_all"], {"pct": 32.0, "resets_at": "2026-07-16T07:00:00.009069+00:00"})
        self.assertEqual(out["weekly_scoped"]["pct"], 46.0)

    def test_parse_claude_without_scoped(self):
        import dashboard
        p = load_fixture("claude_usage.json")
        p["limits"] = [e for e in p["limits"] if e["kind"] != "weekly_scoped"]
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
        self.assertEqual(out["weekly"], {"pct": 28.0, "reset_at": 1784359050.0, "window_seconds": 604800.0})
        self.assertEqual(out["models"]["GPT-5.3-Codex-Spark"]["pct"], 0.0)

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
```

- [ ] **Step 2: Run — expect 7 failures/errors.** `python3 test_dashboard.py -v`

- [ ] **Step 3: Implement** (append to `dashboard.py`)

```python
class FetchError(Exception):
    """A categorized failure fetching or interpreting a vendor payload."""

    def __init__(self, category, detail):
        super().__init__(f"{category}: {detail}")
        self.category = category  # "auth" | "network" | "parse"
        self.detail = detail


def parse_claude(payload):
    """Extract weekly limits from the Claude OAuth usage payload."""
    out = {}
    try:
        for entry in payload["limits"]:
            if entry.get("group") != "weekly":
                continue
            kind = entry.get("kind")
            if kind in ("weekly_all", "weekly_scoped"):
                out[kind] = {"pct": float(entry["percent"]),
                             "resets_at": entry["resets_at"]}
    except (KeyError, TypeError, ValueError) as e:
        raise FetchError("parse", f"claude payload: {e.__class__.__name__}")
    if "weekly_all" not in out:
        raise FetchError("parse", "claude payload: no weekly_all limit")
    return out


def _codex_window(w):
    return {"pct": float(w["used_percent"]),
            "reset_at": float(w["reset_at"]),
            "window_seconds": float(w["limit_window_seconds"])}


def parse_codex(payload):
    """Extract the weekly window + per-model weekly windows from the Codex usage payload."""
    try:
        out = {"weekly": _codex_window(payload["rate_limit"]["secondary_window"]),
               "models": {}}
        for extra in payload.get("additional_rate_limits") or []:
            sw = (extra.get("rate_limit") or {}).get("secondary_window")
            if sw:
                out["models"][extra.get("limit_name") or "unnamed"] = _codex_window(sw)
    except (KeyError, TypeError, ValueError) as e:
        raise FetchError("parse", f"codex payload: {e.__class__.__name__}")
    return out
```

- [ ] **Step 4: Run — all pass.** `python3 test_dashboard.py -v` → `OK`

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: payload parsers with categorized parse errors"`

---

### Task 3: Window math, pace badge, time helpers

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces (all pure): `iso_to_epoch(s) -> float`, `epoch_to_iso(e) -> str` (UTC, `Z` suffix), `reset_epoch(limit) -> float` (handles both `resets_at` ISO and `reset_at` epoch), `window_seconds_of(limit) -> float` (defaults `WEEK_SECONDS`), `window_start(limit) -> float`, `elapsed_pct(limit, now) -> float` (clamped 0–100), `pace_badge(usage_pct, elapsed) -> "under"|"on"|"over"` (±5-point band per spec).

- [ ] **Step 1: Failing tests**

```python
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
        self.assertEqual(dashboard.pace_badge(10.0, 50.0), "under")
        self.assertEqual(dashboard.pace_badge(47.0, 50.0), "on")
        self.assertEqual(dashboard.pace_badge(53.0, 50.0), "on")
        self.assertEqual(dashboard.pace_badge(56.0, 50.0), "over")
```

- [ ] **Step 2: Run — 5 failures.** `python3 test_dashboard.py -v`

- [ ] **Step 3: Implement**

```python
def iso_to_epoch(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def epoch_to_iso(e):
    return datetime.fromtimestamp(e, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def reset_epoch(limit):
    if "reset_at" in limit:
        return float(limit["reset_at"])
    return iso_to_epoch(limit["resets_at"])


def window_seconds_of(limit):
    return float(limit.get("window_seconds", WEEK_SECONDS))


def window_start(limit):
    return reset_epoch(limit) - window_seconds_of(limit)


def elapsed_pct(limit, now):
    frac = (now - window_start(limit)) / window_seconds_of(limit)
    return max(0.0, min(100.0, frac * 100.0))


def pace_badge(usage_pct, elapsed):
    if usage_pct < elapsed - 5.0:
        return "under"
    if usage_pct > elapsed + 5.0:
        return "over"
    return "on"
```

- [ ] **Step 4: Run — all pass.** → `OK`
- [ ] **Step 5: Commit** — `git commit -am "feat: window math, pace badge, time helpers"`

---

### Task 4: History file IO (append / load / prune)

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `append_history_line(path, snap)` — writes `snap` minus its `ts_epoch` key as one compact JSON line + `\n`, single `write()` + flush.
  - `load_history(path, now_fn=time.time) -> list` — returns kept records each with `ts_epoch` added; skips unparseable lines and lines older than `HISTORY_DAYS`; atomically rewrites the pruned file (`.tmp` + `replace`). Missing file → `[]`.

- [ ] **Step 1: Failing tests** (uses `tempfile` — never the real history)

```python
import tempfile, time as _time


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
```

- [ ] **Step 2: Run — 3 failures.**
- [ ] **Step 3: Implement**

```python
def append_history_line(path, snap):
    rec = {k: v for k, v in snap.items() if k != "ts_epoch"}
    line = json.dumps(rec, separators=(",", ":")) + "\n"
    with open(path, "a") as f:
        f.write(line)
        f.flush()


def load_history(path, now_fn=time.time):
    p = Path(path)
    if not p.exists():
        return []
    cutoff = now_fn() - HISTORY_DAYS * 86400
    kept = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            ts = iso_to_epoch(rec["ts"])
        except (ValueError, KeyError, TypeError):
            continue
        if ts < cutoff:
            continue
        rec["ts_epoch"] = ts
        kept.append(rec)
    tmp = p.with_name(p.name + ".tmp")
    with open(tmp, "w") as f:
        for rec in kept:
            f.write(json.dumps({k: v for k, v in rec.items() if k != "ts_epoch"},
                               separators=(",", ":")) + "\n")
    tmp.replace(p)
    return kept
```

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat: JSONL history append/load/prune"`

---

### Task 5: Per-limit history selection + reset-aware projection

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `get_limit(service_data, path) -> dict|None` — walk nested keys, e.g. `["weekly_all"]`, `["models","GPT-5.3-Codex-Spark"]`.
  - `limit_paths(service, data) -> list[(label, path)]` — `claude` → `weekly_all`/`weekly_scoped` present in data; `codex` → `weekly` + sorted model names.
  - `select_window_points(history, service, path, limit, now, trailing=None) -> list[(ts, pct)]` — points within the limit's **own** current window (`window_start(limit)`), optionally further capped to trailing seconds; snapshots where the service is `null` are skipped.
  - `project(points, limit, now) -> {"method": "slope"|"linear", "exhaust_epoch": float|None}` — least-squares slope when ≥3 points (t-values shifted by the first point for float stability); else linear-from-window-start; `exhaust_epoch` is `None` when the limit lasts past its own reset or slope ≤ 0.

- [ ] **Step 1: Failing tests**

```python
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
                         [("weekly", ["weekly"]),
                          ("GPT-5.3-Codex-Spark", ["models", "GPT-5.3-Codex-Spark"])])
        cdata = dashboard.parse_claude(load_fixture("claude_usage.json"))
        self.assertEqual(dashboard.limit_paths("claude", cdata),
                         [("weekly_all", ["weekly_all"]), ("weekly_scoped", ["weekly_scoped"])])
        self.assertEqual(dashboard.limit_paths("claude", None), [])

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
```

- [ ] **Step 2: Run — failures for all new tests.**
- [ ] **Step 3: Implement**

```python
def get_limit(service_data, path):
    cur = service_data
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def limit_paths(service, data):
    if not data:
        return []
    if service == "claude":
        return [(k, [k]) for k in ("weekly_all", "weekly_scoped") if k in data]
    paths = [("weekly", ["weekly"])] if "weekly" in data else []
    paths += [(name, ["models", name]) for name in sorted(data.get("models") or {})]
    return paths


def select_window_points(history, service, path, limit, now, trailing=None):
    start = window_start(limit)
    if trailing is not None:
        start = max(start, now - trailing)
    pts = []
    for snap in history:
        ts = snap.get("ts_epoch")
        if ts is None or ts < start or ts > now:
            continue
        entry = get_limit(snap.get(service) or {}, path)
        if entry is not None:
            pts.append((ts, float(entry["pct"])))
    return pts


def project(points, limit, now):
    reset = reset_epoch(limit)
    pct_now = float(limit["pct"])
    if len(points) >= 3:
        t0 = points[0][0]
        xs = [t - t0 for t, _ in points]
        ys = [p for _, p in points]
        n = len(points)
        sx, sy = sum(xs), sum(ys)
        sxx = sum(x * x for x in xs)
        sxy = sum(x * y for x, y in zip(xs, ys))
        denom = n * sxx - sx * sx
        slope = (n * sxy - sx * sy) / denom if denom else 0.0
        method = "slope"
    else:
        elapsed = now - window_start(limit)
        slope = pct_now / elapsed if elapsed > 0 else 0.0
        method = "linear"
    if slope <= 0.0:
        return {"method": method, "exhaust_epoch": None}
    exhaust = now + max(0.0, 100.0 - pct_now) / slope
    return {"method": method, "exhaust_epoch": exhaust if exhaust < reset else None}
```

  **Note:** the `max(0.0, ...)` clamp is required — vendors can report >100 % usage, and without it the exhaustion timestamp lands in the past. At pct ≥ 100 with a positive slope the limit reports exhaustion at `now`, never earlier. The single `if slope <= 0.0` guard is the only early return.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat: per-limit reset-aware history selection and projection"`

---

### Task 6: Credential readers, HTTP GET, fetchers (injectable seams)

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `read_claude_token(run=subprocess.run) -> str` — Keychain via `security`; failures → `FetchError("auth", ...)`. Token value never logged.
  - `read_codex_creds(path=None) -> (token, account_id)` — default path `Path.home()/".codex"/"auth.json"` resolved **at call time**; failures → `FetchError("auth", ...)`. A missing or empty `access_token` **or** `account_id` is an auth error — `chatgpt-account-id` is a required header and must never be sent empty.
  - `http_get_json(url, headers, opener=urllib.request.urlopen) -> dict` — 401/403 → `auth`, other HTTP/socket errors → `network`, bad JSON → `parse`.
  - `fetch_claude(read_token=None, get=None) -> dict` (parsed via `parse_claude`); `fetch_codex(read_creds=None, get=None) -> dict` — `None` defaults resolve to the module functions at call time (patchable seams).
- Consumes: `parse_claude`, `parse_codex`, `FetchError` (Task 2).

**Isolation rule:** every test below uses fakes or temp paths only. No test may touch `~/.codex/auth.json` or the Keychain.

- [ ] **Step 1: Failing tests**

```python
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
                def __enter__(self): return self
                def __exit__(self, *a): return False
            return R(b"not json")

        for opener, cat in ((opener_401, "auth"), (opener_500, "network"), (opener_badjson, "parse")):
            with self.assertRaises(dashboard.FetchError) as cm:
                dashboard.http_get_json("https://x.invalid/y", {}, opener=opener)
            self.assertEqual(cm.exception.category, cat)

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
```

- [ ] **Step 2: Run — failures for all new tests.**
- [ ] **Step 3: Implement**

```python
def read_claude_token(run=subprocess.run):
    try:
        cp = run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                 capture_output=True, text=True, timeout=10)
    except Exception as e:
        raise FetchError("auth", f"keychain read failed: {e.__class__.__name__}")
    if getattr(cp, "returncode", 1) != 0 or not (cp.stdout or "").strip():
        raise FetchError("auth", "keychain item missing")
    try:
        tok = json.loads(cp.stdout)["claudeAiOauth"]["accessToken"]
    except (ValueError, KeyError, TypeError):
        raise FetchError("auth", "keychain item malformed")
    if not tok:
        raise FetchError("auth", "empty token")
    return tok


def read_codex_creds(path=None):
    if path is None:
        path = Path.home() / ".codex" / "auth.json"
    try:
        tokens = json.loads(Path(path).read_text())["tokens"]
        token, acct = tokens["access_token"], tokens.get("account_id")
    except FileNotFoundError:
        raise FetchError("auth", "auth.json missing")
    except (ValueError, KeyError, TypeError, OSError):
        raise FetchError("auth", "auth.json unreadable or malformed")
    if not token or not acct:
        raise FetchError("auth", "auth.json missing access_token or account_id")
    return token, acct


def http_get_json(url, headers, opener=urllib.request.urlopen):
    req = urllib.request.Request(url, headers=headers)
    try:
        with opener(req, timeout=20) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        raise FetchError("auth" if e.code in (401, 403) else "network", f"HTTP {e.code}")
    except FetchError:
        raise
    except Exception as e:
        raise FetchError("network", e.__class__.__name__)
    try:
        return json.loads(body)
    except ValueError:
        raise FetchError("parse", "response is not valid JSON")


def fetch_claude(read_token=None, get=None):
    read_token = read_token or read_claude_token
    get = get or http_get_json
    tok = read_token()
    payload = get("https://api.anthropic.com/api/oauth/usage",
                  {"Authorization": f"Bearer {tok}", "anthropic-beta": "oauth-2025-04-20"})
    return parse_claude(payload)


def fetch_codex(read_creds=None, get=None):
    read_creds = read_creds or read_codex_creds
    get = get or http_get_json
    tok, acct = read_creds()
    payload = get("https://chatgpt.com/backend-api/codex/usage",
                  {"Authorization": f"Bearer {tok}", "chatgpt-account-id": acct,
                   "User-Agent": "codex-cli"})
    return parse_codex(payload)
```

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat: credential readers and fetchers with injectable seams"`

---

### Task 7: State, refresh(), single-flight, exactly-once history append

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - Module globals: `STATE = {"claude": ..., "codex": ...}` (each `{"status": "never", "fetched_at": None, "error": None, "data": None}`), `HISTORY = []`, `LAST_POLL_EPOCH = 0.0`, `_POLL_GENERATION = 0` (count of completed combined polls), `state_lock = threading.Lock()`, `fetch_lock = threading.Lock()`.
  - `new_service_state() -> dict`, `reset_state()` (test helper, also used at startup).
  - `refresh(force=False, now_fn=time.time, fetchers=None, history_path=None)` — the ONLY upstream path. Contract (spec §Concurrency), **generation/in-flight semantics**:
    1. Under `state_lock`, capture `gen_before = _POLL_GENERATION` (and `LAST_POLL_EPOCH`) — strictly BEFORE attempting `fetch_lock`. The sharing guarantee rests on this order, and the concurrency test's instrumented lock (which signals acquisition attempts) is sound only because of it. Note a forced sharer may never call `now_fn()` at all — nothing may synchronize on `now_fn`.
    2. Non-force with a fresh cache (<`FRESH_SECONDS`) returns immediately.
    3. Acquire `fetch_lock` (single-flight: at most one upstream fetch ever runs). After acquiring, under `state_lock`: if `_POLL_GENERATION > gen_before`, a poll completed while this caller was queued → return and share that result. This applies to **forced and non-forced** callers alike — a `force=True` caller that arrived while a poll was in flight shares it and does NOT poll again.
    4. A non-force caller additionally re-checks freshness and returns on a fresh cache.
    5. Otherwise fetch both services (per-service try/except → fresh data or stale+error), then under `state_lock`: set `LAST_POLL_EPOCH`, increment `_POLL_GENERATION`, update `STATE`, append to `HISTORY`, and make ONE `append_history_line` call (failures logged to stderr, never raised).
    Consequence: a `force=True` call that *begins after* the previous poll completed (its `gen_before` equals the current generation) always performs a new poll — sequential forces are independent; concurrent ones coalesce.
  - `seed_state_from_history()` — newest history entry per service → `status="stale"`, `fetched_at=ts`, `error=None`.

- [ ] **Step 1: Failing tests**

```python
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
```

Add `import threading` to the test file's imports.

- [ ] **Step 2: Run — failures for all new tests.**
- [ ] **Step 3: Implement**

```python
def new_service_state():
    return {"status": "never", "fetched_at": None, "error": None, "data": None}


STATE = {"claude": new_service_state(), "codex": new_service_state()}
HISTORY = []
LAST_POLL_EPOCH = 0.0
_POLL_GENERATION = 0  # completed combined polls; guarded by state_lock
state_lock = threading.Lock()
fetch_lock = threading.Lock()


def reset_state():
    global LAST_POLL_EPOCH, _POLL_GENERATION
    with state_lock:
        STATE["claude"] = new_service_state()
        STATE["codex"] = new_service_state()
        HISTORY.clear()
        LAST_POLL_EPOCH = 0.0
        _POLL_GENERATION = 0


def refresh(force=False, now_fn=time.time, fetchers=None, history_path=None):
    """The single upstream-fetch path (spec: Refresh model + Concurrency contract).

    Generation semantics: callers that captured their generation while a poll
    was in flight (forced or not) share that poll's result; a force=True call
    that begins after the previous poll completed performs a new poll.
    """
    if fetchers is None:
        fetchers = {"claude": fetch_claude, "codex": fetch_codex}
    if history_path is None:
        history_path = HISTORY_PATH
    with state_lock:
        gen_before = _POLL_GENERATION
        last = LAST_POLL_EPOCH
    # gen_before is captured strictly BEFORE attempting fetch_lock: any caller
    # that reaches the lock already holds a pre-poll generation, which is what
    # makes the sharing check below (and its instrumented-lock test) sound.
    if not force and last > 0 and now_fn() - last < FRESH_SECONDS:
        return
    with fetch_lock:  # single-flight: at most one upstream fetch at any moment
        with state_lock:
            if _POLL_GENERATION > gen_before:
                return  # a poll completed while we were queued: share its result
            last = LAST_POLL_EPOCH
        if not force and last > 0 and now_fn() - last < FRESH_SECONDS:
            return
        results = {}
        for name in ("claude", "codex"):
            try:
                results[name] = ("ok", fetchers[name]())
            except FetchError as e:
                results[name] = ("err", e)
            except Exception as e:  # never let one service kill the poll
                results[name] = ("err", FetchError("parse", e.__class__.__name__))
        now = now_fn()
        snap = {"ts": epoch_to_iso(now), "ts_epoch": now}
        with state_lock:
            global LAST_POLL_EPOCH, _POLL_GENERATION
            LAST_POLL_EPOCH = now
            _POLL_GENERATION += 1
            for name, (kind, val) in results.items():
                st = STATE[name]
                if kind == "ok":
                    st["status"] = "fresh"
                    st["fetched_at"] = now
                    st["error"] = None
                    st["data"] = val
                    snap[name] = val
                else:
                    snap[name] = None
                    st["error"] = {"category": val.category, "at": epoch_to_iso(now),
                                   "detail": val.detail}
                    st["status"] = "stale" if st["data"] is not None else "never"
            HISTORY.append(snap)
            try:
                append_history_line(history_path, snap)
            except OSError as e:
                print(f"history append failed: {e.__class__.__name__}", file=sys.stderr)


def seed_state_from_history():
    with state_lock:
        for snap in reversed(HISTORY):
            for service in ("claude", "codex"):
                st = STATE[service]
                if st["data"] is None and snap.get(service):
                    st["data"] = snap[service]
                    st["status"] = "stale"
                    st["fetched_at"] = snap["ts_epoch"]
```

- [ ] **Step 4: Run — all pass.** The single-flight test is event-based (no sleeps, no timing assertions); still confirm stability with `for i in 1 2 3; do python3 test_dashboard.py TestRefresh || break; done` — three consecutive `OK`s.
- [ ] **Step 5: Commit** — `git commit -am "feat: refresh with single-flight lock and exactly-once history append"`

---

### Task 8: API payload assembly (`/api/usage` body)

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `public_state(st) -> dict` — `fetched_at` epoch → ISO, otherwise spec's per-service shape.
  - `api_payload(now_fn=time.time) -> dict` with keys exactly: `claude`, `codex` (per-service state objects), `history` (`{service: {label: [[ts, pct], ...]}}`, full current window per limit), `derived` (`{service: {label: {"pct","elapsed_pct","pace","reset_epoch","projection"}}}`, projection over trailing 24 h), `server_time` (ISO). Copies state under `state_lock`; computes outside it.
- Consumes: `STATE`, `HISTORY`, `limit_paths`, `get_limit`, `select_window_points`, `elapsed_pct`, `pace_badge`, `project`, `reset_epoch` (Tasks 3, 5, 7).

- [ ] **Step 1: Failing tests**

```python
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
                    "codex": lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))}
        now = 1783900000.0  # inside both fixture windows (resets 1784359050 / 2026-07-16)
        dashboard.refresh(force=True, now_fn=lambda: now, fetchers=fetchers,
                          history_path=self.hpath)
        p = dashboard.api_payload(now_fn=lambda: now)
        self.assertEqual(sorted(p.keys()), ["claude", "codex", "derived", "history", "server_time"])
        self.assertEqual(p["claude"]["status"], "fresh")
        self.assertIsNone(p["claude"]["error"])
        d = p["derived"]["codex"]["weekly"]
        self.assertEqual(d["pct"], 28.0)
        self.assertIn(d["pace"], ("under", "on", "over"))
        self.assertAlmostEqual(d["reset_epoch"], 1784359050.0)
        self.assertIn("exhaust_epoch", d["projection"])
        self.assertEqual(len(p["history"]["codex"]["weekly"]), 1)
        self.assertIn("weekly_scoped", p["derived"]["claude"])
        self.assertTrue(json.dumps(p))  # JSON-serializable

    def test_payload_never_state(self):
        import dashboard
        p = dashboard.api_payload(now_fn=lambda: 1783900000.0)
        self.assertEqual(p["claude"]["status"], "never")
        self.assertIsNone(p["claude"]["data"])
        self.assertEqual(p["derived"]["claude"], {})
```

- [ ] **Step 2: Run — 2 failures.**
- [ ] **Step 3: Implement**

```python
def public_state(st):
    return {"status": st["status"],
            "fetched_at": epoch_to_iso(st["fetched_at"]) if st["fetched_at"] else None,
            "error": st["error"],
            "data": st["data"]}


def api_payload(now_fn=time.time):
    now = now_fn()
    with state_lock:
        states = {s: dict(STATE[s]) for s in ("claude", "codex")}
        history_copy = list(HISTORY)
    derived, series = {}, {}
    for service in ("claude", "codex"):
        derived[service], series[service] = {}, {}
        data = states[service]["data"]
        for label, path in limit_paths(service, data):
            limit = get_limit(data, path)
            proj_pts = select_window_points(history_copy, service, path, limit, now,
                                            trailing=86400.0)
            el = elapsed_pct(limit, now)
            derived[service][label] = {
                "pct": limit["pct"],
                "elapsed_pct": round(el, 1),
                "pace": pace_badge(limit["pct"], el),
                "reset_epoch": reset_epoch(limit),
                "projection": project(proj_pts, limit, now),
            }
            series[service][label] = [[round(t), p] for t, p in
                                      select_window_points(history_copy, service, path,
                                                           limit, now)]
    return {"claude": public_state(states["claude"]),
            "codex": public_state(states["codex"]),
            "history": series,
            "derived": derived,
            "server_time": epoch_to_iso(now)}
```

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat: /api/usage payload assembly with derived pace and projection"`

---

### Task 9: Loopback-only HTTP server + degraded-auth integration test

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `HTML_PAGE = "<placeholder page>"` module string (replaced in Task 10; this task defines it as a minimal valid page: `"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Usage Dashboard</title></head><body>loading</body></html>"`).
  - `class Handler(BaseHTTPRequestHandler)` — `GET /` → HTML; `GET /api/usage` → `refresh()` (exceptions logged, never propagated) then `api_payload()` JSON; else 404. `log_message` silenced; handler wraps everything in try/except (spec: no exception may kill the server). **Every** response (200/404/500 alike, via the single `_send` helper) carries `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
  - `make_server(port) -> ThreadingHTTPServer` — binds **`("127.0.0.1", port)`** literally.
- Consumes: `refresh`, `api_payload` (Tasks 7–8).

**Isolation rule:** the integration test binds port `0` (ephemeral), injects failing fetchers by patching module attributes, and points `HISTORY_PATH` at a temp file. Real credentials are never touched.

- [ ] **Step 1: Failing tests**

```python
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

    def test_degraded_codex_auth_other_service_survives(self):
        import dashboard

        def failing_codex():
            raise dashboard.FetchError("auth", "injected: token expired")

        ok_claude = lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))
        with mock.patch.object(dashboard, "fetch_claude", ok_claude), \
             mock.patch.object(dashboard, "fetch_codex", failing_codex), \
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            body = _urlreq.urlopen(f"http://127.0.0.1:{port}/api/usage", timeout=10).read()
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
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            html = _urlreq.urlopen(f"http://127.0.0.1:{port}/", timeout=10).read().decode()
            self.assertIn("<!DOCTYPE html>", html)
            with self.assertRaises(urllib.error.HTTPError) as cm:
                _urlreq.urlopen(f"http://127.0.0.1:{port}/nope", timeout=10)
            self.assertEqual(cm.exception.code, 404)

    def test_security_headers_on_every_response(self):
        import dashboard
        with mock.patch.object(dashboard, "fetch_claude",
                               lambda: dashboard.parse_claude(load_fixture("claude_usage.json"))), \
             mock.patch.object(dashboard, "fetch_codex",
                               lambda: dashboard.parse_codex(load_fixture("codex_usage.json"))), \
             mock.patch.object(dashboard, "HISTORY_PATH", self.hpath):
            port = self._serve()
            for path in ("/", "/api/usage"):
                r = _urlreq.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10)
                self.assertEqual(r.headers["Cache-Control"], "no-store", path)
                self.assertEqual(r.headers["X-Content-Type-Options"], "nosniff", path)
            with self.assertRaises(urllib.error.HTTPError) as cm:
                _urlreq.urlopen(f"http://127.0.0.1:{port}/nope", timeout=10)
            self.assertEqual(cm.exception.headers["Cache-Control"], "no-store")
            self.assertEqual(cm.exception.headers["X-Content-Type-Options"], "nosniff")
```

- [ ] **Step 2: Run — failures (no `make_server`/`Handler`).**
- [ ] **Step 3: Implement**

```python
HTML_PAGE = ("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
             "<title>Usage Dashboard</title></head><body>loading</body></html>")


class Handler(BaseHTTPRequestHandler):
    server_version = "usage-dashboard"

    def do_GET(self):
        try:
            if self.path in ("/", "/index.html"):
                self._send(200, "text/html; charset=utf-8", HTML_PAGE.encode())
            elif self.path == "/api/usage":
                try:
                    refresh()
                except Exception as e:
                    print(f"refresh error: {e.__class__.__name__}", file=sys.stderr)
                self._send(200, "application/json", json.dumps(api_payload()).encode())
            else:
                self._send(404, "text/plain; charset=utf-8", b"not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            print(f"handler error: {e.__class__.__name__}: {e}", file=sys.stderr)
            try:
                self._send(500, "text/plain; charset=utf-8", b"internal error")
            except Exception:
                pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # quiet; errors go to stderr explicitly


def make_server(port):
    return ThreadingHTTPServer(("127.0.0.1", port), Handler)
```

  Note: `refresh()` inside the handler uses default arguments, which resolve `dashboard.fetch_claude` / `dashboard.fetch_codex` / `dashboard.HISTORY_PATH` **at call time** — that is what makes the `mock.patch.object` seams work and keeps production behavior identical.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat: loopback-only HTTP server with degraded-auth integration test"`

---

### Task 10: Embedded UI (accessible, responsive, dark/light)

**Files:**
- Modify: `dashboard.py` (replace the placeholder `HTML_PAGE`)
- Test: `test_dashboard.py`

**Interfaces:**
- Consumes: the `/api/usage` JSON shape from Task 8 (keys `claude`, `codex`, `history`, `derived`, `server_time`).
- Accessibility/responsive requirements: bars are `role="progressbar"` with `aria-valuemin/max/now` and `aria-label`; sparkline SVG has `role="img"` + `aria-label`; footer is `aria-live="polite"`; layout is CSS grid, 2 columns collapsing to 1 below 700 px; colors via CSS variables with a `prefers-color-scheme: dark` override; JS re-fetches every 5 minutes (spec: Refresh model).
- **Age semantics (two distinct clocks, never conflated):** each card shows *service data age* — `"data as of <relative>"` computed by `ageText(server_time, fetched_at)` from the **payload's own** timestamps (never the browser clock, so client clock skew cannot lie about data age). The footer shows *page refresh time* only ("page refreshed HH:MM:SS"). A non-fresh service additionally gets a `stale-chip` label showing its status.
- **Stale rendering stays readable:** no whole-card or banner opacity fade. Stale state is conveyed by a border, the chip, and the banner — bars, numbers, and text keep full contrast.

- [ ] **Step 1: Failing tests** (static checks on the page string — the JS itself is exercised in the browser step of Task 13)

```python
class TestHtmlPage(unittest.TestCase):
    def test_page_has_required_elements(self):
        import dashboard
        page = dashboard.HTML_PAGE
        for needle in ('<!DOCTYPE html>', 'lang="en"', 'viewport',
                       'prefers-color-scheme: dark', 'role="progressbar"',
                       'aria-live="polite"', '/api/usage', '5 * 60 * 1000',
                       'grid-template-columns', 'max-width: 700px',
                       'function ageText', 'data as of ', 'page refreshed ',
                       'stale-chip'):
            self.assertIn(needle, page, needle)
        self.assertNotIn("Bearer", page)
        # stale content must remain readable: no whole-card/banner opacity fade
        self.assertNotIn("opacity:.", page)
        self.assertNotIn("opacity: .", page)
        self.assertNotIn("opacity:0.", page)
```

- [ ] **Step 2: Run — fails on several needles (placeholder page).**
- [ ] **Step 3: Replace `HTML_PAGE`** with the full page:

```python
HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Usage Dashboard</title>
<style>
:root { --bg:#f5f5f7; --card:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --bar-bg:#e3e3e8;
        --time:#8e8e93; --use:#0071e3; --under:#1f9d4d; --on:#b25b00; --over:#d70015; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#1c1c1e; --card:#2c2c2e; --fg:#f5f5f7; --muted:#98989d; --bar-bg:#3a3a3c;
          --under:#30d158; --on:#ff9f0a; --over:#ff453a; }
}
* { box-sizing:border-box; margin:0; }
body { background:var(--bg); color:var(--fg); padding:24px;
       font:15px/1.45 -apple-system, system-ui, sans-serif; }
h1 { font-size:20px; margin-bottom:16px; }
.grid { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
@media (max-width: 700px) { .grid { grid-template-columns:1fr; } }
.card { background:var(--card); border-radius:12px; padding:20px;
        border:1px solid transparent; }
.card.stale { border-color:var(--on); }
.stale-chip { display:inline-block; padding:1px 8px; margin-right:6px; border-radius:8px;
              background:var(--on); color:#fff; font-size:11px; font-weight:600;
              text-transform:uppercase; vertical-align:middle; }
.card h2 { font-size:17px; margin-bottom:12px; }
.banner { background:var(--over); color:#fff; border-radius:8px; padding:8px 12px;
          margin-bottom:12px; font-size:13px; }
.limit { margin-bottom:18px; }
.row { display:flex; justify-content:space-between; gap:8px; font-size:13px;
       color:var(--muted); margin-bottom:4px; }
.row strong { color:var(--fg); }
.bar { height:8px; border-radius:4px; background:var(--bar-bg); overflow:hidden;
       margin-bottom:4px; }
.bar > span { display:block; height:100%; }
.bar.time > span { background:var(--time); }
.bar.use > span { background:var(--use); }
.badge { font-weight:600; }
.badge.under { color:var(--under); } .badge.on { color:var(--on); }
.badge.over { color:var(--over); }
.meta { font-size:12px; color:var(--muted); }
svg.spark { width:100%; height:40px; margin-top:8px; color:var(--use); }
footer { margin-top:16px; font-size:12px; color:var(--muted); }
</style>
</head>
<body>
<h1>Claude &amp; Codex — weekly usage</h1>
<main class="grid">
  <section class="card" id="claude" aria-labelledby="claude-h">
    <h2 id="claude-h">Claude</h2><div class="body"><p class="meta">Loading…</p></div>
  </section>
  <section class="card" id="codex" aria-labelledby="codex-h">
    <h2 id="codex-h">Codex</h2><div class="body"><p class="meta">Loading…</p></div>
  </section>
</main>
<footer id="footer" aria-live="polite"></footer>
<script>
"use strict";
const PACE = {under: "\u{1F7E2} under pace", on: "\u{1F7E1} on pace", over: "\u{1F534} over pace"};

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
}
function fmtWhen(epoch) {
  return new Date(epoch * 1000).toLocaleString(undefined,
    {weekday: "short", hour: "2-digit", minute: "2-digit"});
}
function fmtReset(epoch) {
  const s = Math.max(0, epoch * 1000 - Date.now()) / 1000;
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  return "resets in " + d + "d " + h + "h (" + fmtWhen(epoch) + ")";
}
function ageText(serverIso, fetchedIso) {
  // Service data age from the payload's own clocks — independent of the
  // browser clock and of when the page last refreshed.
  const s = Math.max(0, (Date.parse(serverIso) - Date.parse(fetchedIso)) / 1000);
  if (s < 90) return "just now";
  if (s < 90 * 60) return Math.round(s / 60) + " min ago";
  if (s < 36 * 3600) return Math.round(s / 3600) + " h ago";
  return Math.round(s / 86400) + " d ago";
}
function verdict(proj) {
  if (!proj) return "";
  if (proj.exhaust_epoch === null) return "lasts past reset";
  return "at this pace runs out ~" + fmtWhen(proj.exhaust_epoch);
}
function bar(cls, label, pct) {
  const w = Math.min(100, Math.max(0, pct));
  return '<div class="row"><span>' + esc(label) + '</span><span>' + pct.toFixed(0) +
    '%</span></div><div class="bar ' + cls + '" role="progressbar" aria-label="' + esc(label) +
    '" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + pct.toFixed(0) +
    '"><span style="width:' + w + '%"></span></div>';
}
function spark(series) {
  if (!series || series.length < 2) return "";
  const xs = series.map(p => p[0]);
  const x0 = Math.min(...xs), x1 = Math.max(...xs);
  const pts = series.map(p =>
    (((p[0] - x0) / (x1 - x0 || 1)) * 100).toFixed(1) + "," +
    (40 - (p[1] / 100) * 40).toFixed(1)).join(" ");
  return '<svg class="spark" viewBox="0 0 100 40" preserveAspectRatio="none" role="img"' +
    ' aria-label="usage over current window"><polyline fill="none" stroke="currentColor"' +
    ' stroke-width="1.5" points="' + pts + '"/></svg>';
}
function banner(svc, err) {
  if (!err) return "";
  const msg = err.category === "auth"
    ? (svc === "claude" ? "Token stale — open Claude Code once"
                        : "Token stale — run codex once")
    : "Can’t reach service (" + esc(err.category) + ")";
  return '<div class="banner" role="alert">' + msg + '</div>';
}
function render(data) {
  for (const svc of ["claude", "codex"]) {
    const st = data[svc];
    const card = document.getElementById(svc);
    card.classList.toggle("stale", st.status !== "fresh");
    let html = banner(svc, st.error);
    if (st.fetched_at) {
      html += '<p class="meta">' +
        (st.status !== "fresh" ? '<span class="stale-chip">' + esc(st.status) + '</span>' : '') +
        'data as of ' + ageText(data.server_time, st.fetched_at) + '</p>';
    }
    if (!st.data) {
      card.querySelector(".body").innerHTML = html + '<p class="meta">No data yet.</p>';
      continue;
    }
    const derived = data.derived[svc] || {};
    const hist = data.history[svc] || {};
    for (const [label, d] of Object.entries(derived)) {
      html += '<div class="limit"><div class="row"><strong>' + esc(label.replace(/_/g, " ")) +
        '</strong><span class="badge ' + d.pace + '">' + PACE[d.pace] + '</span></div>' +
        bar("time", "time elapsed", d.elapsed_pct) + bar("use", "quota used", d.pct) +
        '<div class="meta">' + fmtReset(d.reset_epoch) + ' · ' + verdict(d.projection) +
        '</div>' + spark(hist[label]) + '</div>';
    }
    card.querySelector(".body").innerHTML = html;
  }
  document.getElementById("footer").textContent =
    "page refreshed " + new Date().toLocaleTimeString() +
    " (auto every 5 min) — service data age shown per card";
}
async function tick() {
  try {
    const r = await fetch("/api/usage");
    render(await r.json());
  } catch (e) {
    document.getElementById("footer").textContent = "fetch failed — will retry";
  }
}
tick();
setInterval(tick, 5 * 60 * 1000);
</script>
</body>
</html>"""
```

  Place this ABOVE the `Handler` class (replacing the Task 9 placeholder assignment).

- [ ] **Step 4: Run — full suite passes** (including Task 9's `test_root_serves_html_and_unknown_404`).
- [ ] **Step 5: Commit** — `git commit -am "feat: embedded accessible responsive dashboard UI"`

---

### Task 11: `main()`, poll thread, startup seeding, `--once`

**Files:**
- Modify: `dashboard.py`; Test: `test_dashboard.py`

**Interfaces:**
- Produces:
  - `poll_loop(stop_event)` — `refresh(force=True)` then `stop_event.wait(POLL_SECONDS)`, forever; every exception caught and logged to stderr.
  - `main(argv=None) -> int` — argparse (`--port` int default `DEFAULT_PORT`, `--once` flag); loads history from `HISTORY_PATH` into `HISTORY`; `seed_state_from_history()`; `--once` → `refresh(force=True)` + print `json.dumps(api_payload(), indent=2)` + return 0; otherwise start daemon poll thread, `make_server(args.port).serve_forever()` with KeyboardInterrupt handling and `finally: stop.set(); srv.server_close()`.
  - Entry: `if __name__ == "__main__": sys.exit(main())`.

- [ ] **Step 1: Failing tests**

```python
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
```

- [ ] **Step 2: Run — failures (no `main`/`poll_loop`).**
- [ ] **Step 3: Implement**

```python
def poll_loop(stop_event):
    while not stop_event.is_set():
        try:
            refresh(force=True)
        except Exception as e:
            print(f"poll error: {e.__class__.__name__}: {e}", file=sys.stderr)
        stop_event.wait(POLL_SECONDS)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Claude Code + Codex weekly usage dashboard")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--once", action="store_true",
                    help="fetch once, print the API payload as JSON, exit")
    args = ap.parse_args(argv)
    HISTORY.extend(load_history(HISTORY_PATH))
    seed_state_from_history()
    if args.once:
        refresh(force=True)
        print(json.dumps(api_payload(), indent=2))
        return 0
    stop = threading.Event()
    threading.Thread(target=poll_loop, args=(stop,), daemon=True).start()
    srv = make_server(args.port)
    print(f"usage-dashboard serving on http://127.0.0.1:{args.port}", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

  Note: `poll_loop` calls `refresh(force=True)` with defaults, so `mock.patch.object(dashboard, "refresh", ...)` works because `poll_loop` looks up `refresh` as a module global — implementer must NOT capture `refresh` in a default argument or local alias.

- [ ] **Step 4: Run full suite — all pass.** `python3 test_dashboard.py -v` → `OK`
- [ ] **Step 5: Live smoke (first real network use, read-only):** `python3 dashboard.py --once | python3 -c "import json,sys; p=json.load(sys.stdin); print(p['claude']['status'], p['codex']['status'])"` → expect `fresh fresh` (or a categorized stale — investigate before continuing). Then `rm -f history.jsonl` (this smoke line is dev noise; the real daemon rebuilds it).
- [ ] **Step 6: Commit** — `git commit -am "feat: main entrypoint, poll thread, --once mode"`

---

### Task 12: launchd template, install/uninstall scripts, README

**Files:**
- Create: `launchd/com.kamil.usage-dashboard.plist.template`, `install.sh`, `uninstall.sh`, `README.md`

**Interfaces:**
- Consumes: `dashboard.py` CLI from Task 11.
- Produces: idempotent `./install.sh` and `./uninstall.sh`; the rendered plist lands at `~/Library/LaunchAgents/com.kamil.usage-dashboard.plist` and is **never** committed. The template carries three placeholders — `__PROJECT_DIR__`, `__HOME__`, `__PYTHON__` — all substituted at install time with XML-escaped absolute paths; `__PYTHON__` is `command -v python3` after validating it is executable and ≥ 3.9.

- [ ] **Step 1: Write `launchd/com.kamil.usage-dashboard.plist.template`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.kamil.usage-dashboard</string>
    <key>ProgramArguments</key>
    <array>
        <string>__PYTHON__</string>
        <string>__PROJECT_DIR__/dashboard.py</string>
    </array>
    <key>WorkingDirectory</key><string>__PROJECT_DIR__</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>__HOME__/Library/Logs/usage-dashboard/out.log</string>
    <key>StandardErrorPath</key><string>__HOME__/Library/Logs/usage-dashboard/err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `install.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
LABEL="com.kamil.usage-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Resolve and validate the interpreter that will run the agent. launchd gets no
# shell PATH, so the absolute path found here is baked into the plist. On this
# machine `command -v python3` is /opt/homebrew/bin/python3 (3.14) — the same
# runtime the tests run under; /usr/bin/python3 must NOT be hardcoded.
PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { echo "error: python3 not found on PATH" >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || { echo "error: $PYTHON is older than 3.9" >&2; exit 1; }

mkdir -p "$HOME/Library/Logs/usage-dashboard" "$HOME/Library/LaunchAgents"

# Render the template with XML-escaped absolute paths. No sed: paths may contain
# characters that break sed replacement (&, |) or XML (&, <).
"$PYTHON" - "$PROJECT_DIR" "$HOME" "$PYTHON" > "$PLIST" <<'EOF'
import pathlib, sys
from xml.sax.saxutils import escape
proj, home, py = (escape(a) for a in sys.argv[1:4])
t = pathlib.Path("launchd/com.kamil.usage-dashboard.plist.template").read_text()
sys.stdout.write(t.replace("__PROJECT_DIR__", proj)
                  .replace("__HOME__", home)
                  .replace("__PYTHON__", py))
EOF
plutil -lint "$PLIST" >/dev/null
grep -Fq "<string>$PYTHON</string>" "$PLIST" \
    || { echo "error: rendered plist does not pin $PYTHON" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed — dashboard at http://127.0.0.1:8787 (python: $PYTHON)"
echo "logs: $HOME/Library/Logs/usage-dashboard/"
```

- [ ] **Step 3: Write `uninstall.sh`**

```bash
#!/bin/bash
set -euo pipefail
LABEL="com.kamil.usage-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "uninstalled — logs and history.jsonl left in place"
```

- [ ] **Step 4: Write `README.md`**

```markdown
# subscriptions-dashboard

Local dashboard showing Claude Code and Codex weekly subscription usage side by
side — % of the window elapsed vs. % of quota used, pace badge, reset countdown,
burn-rate projection, and a sparkline per limit. Runs entirely on this Mac,
bound to `127.0.0.1:8787` only.

Spec: `docs/superpowers/specs/2026-07-12-usage-dashboard-design.md`.

## Install (launchd, survives reboot and crashes)

    ./install.sh

Then open <http://127.0.0.1:8787>.

## Uninstall

    ./uninstall.sh          # stops the agent, removes the generated plist
                            # history.jsonl and logs are left in place

## Run in the foreground (debugging)

    python3 dashboard.py            # serve on 8787
    python3 dashboard.py --port 9999
    python3 dashboard.py --once     # one fetch, print JSON payload, exit

## Tests

    python3 test_dashboard.py -v

## Operations

- **Logs:** `~/Library/Logs/usage-dashboard/{out,err}.log`
- **History:** `history.jsonl` in this directory (one line per poll, 60-day
  retention, gitignored). Delete it to start the charts over — nothing else
  depends on it.
- **Restart:** `launchctl kickstart -k gui/$(id -u)/com.kamil.usage-dashboard`
- **Python:** the agent pins whichever `python3` was first on PATH at install
  time (validated ≥ 3.9 by `install.sh`). After upgrading or moving Python,
  re-run `./install.sh` to re-pin it.
- **"Token stale" banner:** the dashboard reuses the CLIs' own credentials.
  Claude: open Claude Code once. Codex: run `codex` once. The next poll
  (≤20 min, or reload the page) picks the refreshed token up.

## Security notes

- Credentials are read at poll time from the macOS Keychain
  (`Claude Code-credentials`) and `~/.codex/auth.json`; they are never
  written to disk, logs, or API responses, and never sent anywhere except
  `api.anthropic.com` / `chatgpt.com`.
- The server rejects non-loopback connections by construction (it binds
  `127.0.0.1` only).
- Both usage endpoints are the vendors' internal CLI endpoints and may change
  without notice; the dashboard degrades to stale banners rather than crashing.
```

- [ ] **Step 5: Make scripts executable, verify by rendering only (no bootstrap yet)**

```bash
chmod +x install.sh uninstall.sh
bash -n install.sh && bash -n uninstall.sh && echo "syntax OK"
PY="$(command -v python3)"   # on this machine: /opt/homebrew/bin/python3
render() {
  "$PY" - "$PWD" "$HOME" "$PY" <<'EOF'
import pathlib, sys
from xml.sax.saxutils import escape
proj, home, py = (escape(a) for a in sys.argv[1:4])
t = pathlib.Path("launchd/com.kamil.usage-dashboard.plist.template").read_text()
sys.stdout.write(t.replace("__PROJECT_DIR__", proj)
                  .replace("__HOME__", home)
                  .replace("__PYTHON__", py))
EOF
}
render | plutil -lint -
render | grep -F "<string>$PY</string>"
```
Expected: `syntax OK`, `stdin: OK`, and the grep prints the ProgramArguments line pinning the exact interpreter path (`<string>/opt/homebrew/bin/python3</string>` on this machine) — proving the rendered plist uses the resolved python3, not a hardcoded one.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: launchd template, install/uninstall scripts, README"`

---

### Task 13: Acceptance verification (spec §Acceptance criteria) + rollback

**Files:** none created (verification only; fix-forward commits allowed if a criterion fails).

Run in order; each criterion maps to spec acceptance #1–#7.

- [ ] **AC1 — Tests:** `python3 test_dashboard.py -v` → `OK`, zero failures.

- [ ] **AC6a — launchd install:** `./install.sh` → prints installed message. Then `launchctl print "gui/$(id -u)/com.kamil.usage-dashboard" | grep -E "state|pid"` → `state = running`.

- [ ] **AC2 — Loopback reachability and ONLY loopback:**
```bash
curl -sS http://127.0.0.1:8787/api/usage | python3 -c "import json,sys; p=json.load(sys.stdin); assert set(p) == {'claude','codex','history','derived','server_time'}, p.keys(); print('shape OK:', p['claude']['status'], p['codex']['status'])"
lsof -nP -iTCP:8787 -sTCP:LISTEN
curl -sS -D - -o /dev/null http://127.0.0.1:8787/api/usage | grep -icE "^(cache-control: no-store|x-content-type-options: nosniff)"
```
Expected: `shape OK: fresh fresh`; lsof shows exactly one listener on `127.0.0.1:8787` (no `*:8787`, no `[::]`); the header grep prints `2`. (Must be a GET with dumped headers — `curl -I` sends HEAD, which `Handler` does not implement, so it would exercise `BaseHTTPRequestHandler`'s 501 path instead of `_send`.) Additionally, if the Mac has a LAN address: `curl --max-time 3 "http://$(ipconfig getifaddr en0):8787/" ; echo "exit=$?"` → non-zero exit (connection refused).

- [ ] **AC3 — Live-source comparison (±2 points):** run this comparison script — it calls the vendor endpoints directly (same as the dashboard does) and diffs against the dashboard's numbers. Tokens stay in process memory; nothing secret is printed.
```bash
python3 - <<'EOF'
import json, subprocess, pathlib, urllib.request

dash = json.load(urllib.request.urlopen("http://127.0.0.1:8787/api/usage", timeout=15))

raw = subprocess.run(["security","find-generic-password","-s","Claude Code-credentials","-w"],
                     capture_output=True, text=True).stdout
ct = json.loads(raw)["claudeAiOauth"]["accessToken"]
req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage",
    headers={"Authorization": f"Bearer {ct}", "anthropic-beta": "oauth-2025-04-20"})
claude_live = {e["kind"]: e["percent"] for e in json.load(urllib.request.urlopen(req, timeout=15))["limits"]
               if e.get("group") == "weekly"}

auth = json.loads((pathlib.Path.home()/".codex/auth.json").read_text())
req = urllib.request.Request("https://chatgpt.com/backend-api/codex/usage",
    headers={"Authorization": f"Bearer {auth['tokens']['access_token']}",
             "chatgpt-account-id": auth["tokens"].get("account_id",""), "User-Agent": "codex-cli"})
codex_live = json.load(urllib.request.urlopen(req, timeout=15))["rate_limit"]["secondary_window"]["used_percent"]

checks = [("claude weekly_all", dash["derived"]["claude"]["weekly_all"]["pct"], claude_live["weekly_all"]),
          ("codex weekly", dash["derived"]["codex"]["weekly"]["pct"], codex_live)]
if "weekly_scoped" in dash["derived"]["claude"]:
    checks.append(("claude weekly_scoped", dash["derived"]["claude"]["weekly_scoped"]["pct"],
                   claude_live.get("weekly_scoped")))
bad = [(n, d, l) for n, d, l in checks if l is None or abs(d - l) > 2]
for n, d, l in checks:
    print(f"{n}: dashboard={d} live={l}")
print("COMPARISON:", "FAIL " + repr(bad) if bad else "PASS")
raise SystemExit(1 if bad else 0)
EOF
```
Expected: `COMPARISON: PASS`.

- [ ] **AC4 — History persistence across restart:** wait for ≥2 poll cycles (or trigger extra polls by reloading the page after >60 s gaps), then:
```bash
wc -l history.jsonl
python3 -c "import json; [json.loads(l) for l in open('history.jsonl')]; print('all lines parse')"
launchctl kickstart -k "gui/$(id -u)/com.kamil.usage-dashboard" && sleep 3
curl -sS http://127.0.0.1:8787/api/usage | python3 -c "import json,sys; p=json.load(sys.stdin); n=len(p['history']['claude'].get('weekly_all',[])); print('series points after restart:', n); raise SystemExit(0 if n >= 2 else 1)"
```
Expected: ≥2 lines, `all lines parse`, `series points after restart: >=2` (pre-restart history survived).

- [ ] **AC5 — Degraded one-service behavior:** already proven by the isolated integration test `TestServerIntegration.test_degraded_codex_auth_other_service_survives` (injected failing fetcher; real `~/.codex/auth.json` and Keychain untouched, per the global constraint). Evidence: `python3 test_dashboard.py TestServerIntegration -v` → `OK`. Do NOT simulate degradation against the running production instance.

- [ ] **AC6b — Crash restart:** 
```bash
PID=$(lsof -tnP -iTCP:8787 -sTCP:LISTEN); kill -9 "$PID"; sleep 5
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8787/
```
Expected: `200` (launchd `KeepAlive` restarted it; new PID differs: re-run the `lsof` to confirm).

- [ ] **Browser + console verification:** open `http://127.0.0.1:8787` in Chrome (via claude-in-chrome tools if available: `tabs_create_mcp` → navigate → screenshot → `read_console_messages`). Expected: two cards render with paired bars, pace badges, reset countdowns, verdicts; zero console errors/warnings from the page's own script. Resize below 700 px width → columns stack. Toggle macOS dark mode → page follows without reload artifacts.

- [ ] **AC7 — Credential-leakage check (prints only PASS/FAIL, never secrets):**
```bash
python3 - <<'EOF'
import json, pathlib, subprocess, urllib.request

raw = subprocess.run(["security","find-generic-password","-s","Claude Code-credentials","-w"],
                     capture_output=True, text=True).stdout
secrets = [json.loads(raw)["claudeAiOauth"]["accessToken"]]
secrets.append(json.loads((pathlib.Path.home()/".codex/auth.json").read_text())["tokens"]["access_token"])

texts = {"api": urllib.request.urlopen("http://127.0.0.1:8787/api/usage", timeout=15).read().decode()}
for p in [pathlib.Path("history.jsonl"),
          *(pathlib.Path.home()/"Library/Logs/usage-dashboard").glob("*.log")]:
    if p.exists():
        texts[p.name] = p.read_text(errors="replace")
tracked = subprocess.run(["git","ls-files"], capture_output=True, text=True).stdout.split()
for f in tracked:
    texts["repo:"+f] = pathlib.Path(f).read_text(errors="replace")

leaks = [name for name, text in texts.items()
         for s in secrets if s and s in text]
print("LEAK CHECK:", "FAIL in " + repr(leaks) if leaks else "PASS")
raise SystemExit(1 if leaks else 0)
EOF
```
Expected: `LEAK CHECK: PASS`.

- [ ] **AC6c — Uninstall works, then reinstall:**
```bash
./uninstall.sh
sleep 2; curl -sS --max-time 3 -o /dev/null http://127.0.0.1:8787/ ; echo "exit=$? (want non-zero)"
test ! -f "$HOME/Library/LaunchAgents/com.kamil.usage-dashboard.plist" && echo "plist removed"
./install.sh   # leave the dashboard installed and running as the final state
```

- [ ] **Final:** `git status` must be clean except `history.jsonl` (gitignored). Commit nothing unless fixes were needed.

**Rollback / cleanup (if the project must be removed):** `./uninstall.sh`, then `rm -rf ~/Library/Logs/usage-dashboard`, then delete or `git revert` the repo commits. `history.jsonl` contains no secrets and can be deleted freely. Nothing else on the system is modified by this project.

---

## Self-review notes (performed at plan-writing time)

- **Spec coverage:** every spec section maps to a task — parsers (T2), window math/pace (T3), history file (T4), per-limit reset-aware projection (T5), credential seams (T6), single-flight + exactly-once append (T7), API state model incl. `never` (T7/T8), UI incl. banners/stale/sparkline/5-min refresh (T10), loopback server (T9), poll cadence + seeding (T11), deployment artifacts + README (T12), all seven acceptance criteria + browser/console + leakage checks (T13).
- **Sequencing:** pure functions before I/O before threading before server before UI before deployment; the first real network call happens only at T11 Step 5 (read-only `--once`).
- **Type consistency check done:** `limit` dicts always carry `pct` + (`resets_at` | `reset_at`+`window_seconds`); `reset_epoch`/`window_seconds_of` are the only readers of those variants; `refresh` seams (`fetchers`, `history_path`) match the tests in T7 and the patch-based tests in T9/T11.
- **Isolation:** no test or verification step renames/edits real credentials; degraded auth is injected fakes only (T6, T9), and T13/AC5 explicitly forbids simulating degradation on the production instance.

**Correction gate 2026-07-12 18:31 (fixed inline):**
- Single-flight rebuilt on `_POLL_GENERATION`: concurrent forced AND non-forced callers that captured their generation during an in-flight poll share its result; sequential forces still poll independently. Deterministic instrumented-lock test replaces the old timing-based one (see correction 2 below for the mechanism).
- `project()` clamps remaining quota to `max(0, 100 − pct)`; exactly-100 and above-100 tested on both slope and linear paths.
- UI separates the two clocks: per-card "data as of <relative>" from `server_time − fetched_at` (payload clocks, immune to browser clock skew) vs. footer "page refreshed HH:MM:SS"; stale cards use border + chip + banner instead of an opacity fade, enforced by static `assertNotIn("opacity:.")` checks.
- launchd interpreter is a `__PYTHON__` placeholder rendered at install time from `command -v python3` (this checkout: `/opt/homebrew/bin/python3`, 3.14 — same runtime as the tests), XML-escaped via `xml.sax.saxutils.escape` (no sed), validated executable + ≥3.9, `plutil -lint`-ed, and grep-verified in the rendered plist; T12 Step 5 render-lints with the exact live path.
- Missing/empty Codex `account_id` (or `access_token`) now raises `FetchError("auth", ...)` before any request is built — tested for all three degenerate shapes.
- `Cache-Control: no-store` + `X-Content-Type-Options: nosniff` on every response via the single `_send` helper; tested on 200 (both routes) and 404, and added to AC2's header check.
- Consistency re-check: `refresh` seams unchanged (`fetchers`, `history_path`, `now_fn`) so T9/T11 patch-based tests still hold; `reset_state()` now also zeroes `_POLL_GENERATION`; no remaining reference to `/usr/bin/python3`, `_is_fresh`, or the removed `delay` test parameter.

**Correction gate 2 2026-07-12 18:50 (fixed inline):**
- The previous concurrency test would DEADLOCK: a `force=True` caller short-circuits `not force and ... now_fn()`, so its first `now_fn()` call happens (if ever) only after acquiring `fetch_lock` — the test waited on that signal while t1 still held the lock. Replaced with `SignalingLock`, patched in for `dashboard.fetch_lock`: it releases a semaphore permit on every acquisition *attempt* (before blocking). Since `refresh()` captures `gen_before` strictly before attempting the lock, a signaled attempt while t1 provably holds the lock (`in_flight` set, `release` unset) proves a pre-poll generation. The test consumes t1's own attempt permit first, waits for exactly two more (t2 forced + t3 unforced), then releases t1. Threads are daemons and a `finally` block re-sets `release` and joins, so a failed assertion cannot strand them. Production semantics untouched — `refresh()` still uses plain `with fetch_lock:`; only the module global is patched in the test.
- AC2's header check used `curl -sSI` (HEAD), which `Handler` doesn't implement — it would have asserted against `BaseHTTPRequestHandler`'s 501 response, not `_send`. Now `curl -sS -D - -o /dev/null` (GET, dumped headers), expected count still `2`; rationale noted inline so nobody "simplifies" it back to `-I`.
- Re-checked remaining snippets for the same classes of bug: the T9 `test_security_headers_on_every_response` uses GET via `urlopen` (sound); no other test synchronizes on `now_fn`; no other acceptance command uses HEAD.
