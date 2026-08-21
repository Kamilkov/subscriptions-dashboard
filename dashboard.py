#!/usr/bin/env python3
"""Local dashboard: Claude Code + Codex weekly subscription usage, side by side.

Spec: docs/superpowers/specs/2026-07-12-usage-dashboard-design.md
Stdlib only. Serves 127.0.0.1:8787. Tokens are never stored or logged.
"""
import argparse
import base64
import json
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WEEK_SECONDS = 7 * 24 * 3600
DEFAULT_PORT = 8787
POLL_SECONDS = 20 * 60      # background poll cadence
FRESH_SECONDS = POLL_SECONDS  # page-triggered refresh must not outpace the poll
HISTORY_DAYS = 60           # retention
BASE_DIR = Path(__file__).resolve().parent
HISTORY_PATH = BASE_DIR / "history.jsonl"
# "gemini" (gemini-cli quota) retired 2026-08, implementation removed
# 2026-08-20 — revive from git history if gemini-cli ever comes back.
# (Antigravity's "Gemini" POOL label is unrelated and stays.)
SERVICES = ("claude", "codex", "cursor", "antigravity", "copilot")
CURSOR_DB = Path.home() / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"


def iso_to_epoch(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def epoch_to_iso(e):
    return datetime.fromtimestamp(e, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _num(v):
    """float() that rejects non-finite or absurd values: float("NaN")/"inf"
    succeed, a NaN percent renders as garbage, and a finite 1e300 would trap
    the Swift port's Int() render sites — reject both at the boundary. Derived
    percentages are re-validated through this too (raw bounds don't cap
    products). 1e15 clears real epochs (Cursor's ms epochs ~1.8e12)."""
    f = float(v)
    if f != f or abs(f) >= 1e15:
        raise ValueError("non-finite or absurd number")
    return f


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
    # Burn rate relative to the rate that exactly consumes the window. A fixed
    # percentage-point band reads "on pace" at 7% elapsed / 9% used — a 1.3x
    # burn that exhausts the week by day 5.
    if elapsed < 2.0:  # first ~3h of a week: one session skews the ratio
        return "on"
    rate = usage_pct / elapsed
    if rate < 0.85:
        return "under"
    if rate > 1.15:
        return "over"
    return "on"


class FetchError(Exception):
    """A categorized failure fetching or interpreting a vendor payload."""

    def __init__(self, category, detail):
        super().__init__(f"{category}: {detail}")
        self.category = category  # "auth" | "network" | "parse"
        self.detail = detail


# Claude severity values that mean the limit is actually enforced, not just warned.
_HARD_SEVERITY = {"critical", "exceeded", "blocked", "over_limit", "limit_reached", "throttled"}


def _severity_blocked(entry):
    return str(entry.get("severity") or "").lower() in _HARD_SEVERITY


def parse_claude(payload):
    """Extract the 5-hour session and weekly limits from Claude usage."""
    out = {}
    try:
        for entry in payload["limits"]:
            if (entry.get("group") == "session" and entry.get("kind") == "session"
                    and entry.get("resets_at")):
                out["session"] = {"pct": _num(entry["percent"]),
                                  "resets_at": entry["resets_at"],
                                  "window_seconds": 5 * 3600,
                                  "blocked": _severity_blocked(entry)}
                continue
            if entry.get("group") != "weekly":
                continue
            kind = entry.get("kind")
            if kind in ("weekly_all", "weekly_scoped") and entry.get("resets_at"):
                out[kind] = {"pct": _num(entry["percent"]),
                             "resets_at": entry["resets_at"],
                             "blocked": _severity_blocked(entry)}
                # Vendor-provided lane name when present ("Fable"); scope has
                # been a bare string ("opus") and an object — tolerate both,
                # fall back to our static label when absent.
                scope = entry.get("scope")
                if isinstance(scope, dict):
                    name = (scope.get("model") or {}).get("display_name")
                    if name:
                        out[kind]["name"] = f"Weekly - {name}"
    except (KeyError, TypeError, ValueError) as e:
        raise FetchError("parse", f"claude payload: {e.__class__.__name__}")
    if "weekly_all" not in out:
        raise FetchError("parse", "claude payload: no weekly_all limit")
    return out


def _codex_window(w, rl_blocked=False):
    # "blocked" only when the vendor flags the rate limit AND this window is the
    # one actually exhausted — so a full 5h window doesn't blame the weekly lane.
    return {"pct": _num(w["used_percent"]),
            "reset_at": _num(w["reset_at"]),
            "window_seconds": _num(w["limit_window_seconds"]),
            "blocked": bool(rl_blocked) and _num(w["used_percent"]) >= 100.0}


def _rl_blocked(rate_limit):
    return bool(rate_limit.get("limit_reached")) or rate_limit.get("allowed") is False


def parse_cursor(payload):
    """Extract the two monthly meters Cursor's own dashboard shows:
    autoPercentUsed (Cursor models) and apiPercentUsed (other models).

    totalSpend/limit is NOT a usage meter — totalSpend includes free
    bonusSpend, so spend/limit overstates (e.g. 210% while genuinely at
    7%/44%); it and totalPercentUsed are deliberately ignored."""
    try:
        plan = payload["planUsage"]
        start = _num(payload["billingCycleStart"]) / 1000.0
        end = _num(payload["billingCycleEnd"]) / 1000.0
        auto = _num(plan["autoPercentUsed"])
        api = _num(plan["apiPercentUsed"])
    except (KeyError, TypeError, ValueError) as e:
        raise FetchError("parse", f"cursor payload: {e.__class__.__name__}")
    if end <= start:
        raise FetchError("parse", "cursor payload: bad billing cycle")
    def meter(pct):
        return {"pct": round(pct, 1), "reset_at": end, "window_seconds": end - start,
                "blocked": pct >= 100.0}
    return {"monthly_auto": meter(auto), "monthly_api": meter(api)}


def parse_antigravity(payload):
    """Per-group weekly + 5-hour pools from Antigravity's local language
    server (RetrieveUserQuotaSummary). Quota is metered per model *group*
    (Gemini pool; Claude/GPT pool) — individual models are not tracked, so
    e.g. Gemini Flash and Pro share one pool (docs/antigravity-usage-research.md)."""
    windows = {"weekly": ("Weekly", 7 * 86400.0), "5h": ("5-hour", 5 * 3600.0)}
    out = {}
    try:
        for g in payload["response"]["groups"]:
            name = g.get("displayName") or ""
            pool = "Gemini" if "gemini" in name.lower() else "Claude and GPT"
            for b in g.get("buckets", []):
                win, resets = b.get("window"), b.get("resetTime")
                if win not in windows or not resets:
                    continue
                label, secs = windows[win]
                remaining = _num(b["remainingFraction"]) if "remainingFraction" in b else 1.0
                out[f"{label} - {pool}"] = {
                    "pct": _num(round((1.0 - remaining) * 1000) / 10),  # derived re-validated
                    "resets_at": resets, "window_seconds": secs,
                    "blocked": remaining <= 0}
    except (KeyError, TypeError, ValueError) as e:
        raise FetchError("parse", f"antigravity payload: {e.__class__.__name__}")
    if not out:
        raise FetchError("parse", "antigravity payload: no usable groups")
    return out


def discover_antigravity_servers(run=None):
    """(ports, tokens) of running Antigravity language servers. Ports and
    tokens change every app launch, and a token from one PID can validate
    against another PID's port — so return them unpaired for cross-probing.

    `ps -x` (no `-a`) lists only THIS user's processes, so a rogue
    `language_server_macos` owned by another local user can't lure us into
    posting a real token to its port."""
    run = run or subprocess.run
    try:
        ps = run(["ps", "-xo", "pid=,args="], capture_output=True, text=True,
                 timeout=10).stdout
    except Exception as e:
        raise FetchError("parse", f"antigravity ps failed: {e.__class__.__name__}")
    pids, tokens = [], []
    for line in ps.splitlines():
        if "language_server_macos" not in line:
            continue
        parts = line.split()
        pids.append(parts[0])
        if "--csrf_token" in parts:
            i = parts.index("--csrf_token")
            if i + 1 < len(parts):
                tokens.append(parts[i + 1])
    if not pids:
        raise FetchError("auth", "antigravity not running")
    ports = set()
    for pid in pids:
        try:
            out = run(["lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN"],
                      capture_output=True, text=True, timeout=10).stdout
        except Exception:
            continue
        for ln in out.splitlines():
            if "LISTEN" not in ln:
                continue
            addr = ln.split()[-2]  # "127.0.0.1:54321"
            port = addr.rsplit(":", 1)[-1]
            if port.isdigit():
                ports.add(int(port))
    if not ports:
        raise FetchError("auth", "antigravity not running")
    return sorted(ports), tokens


ANTIGRAVITY_RPC = ("/exa.language_server_pb.LanguageServerService"
                   "/RetrieveUserQuotaSummary")


def fetch_antigravity(discover=None, post=None):
    discover = discover or discover_antigravity_servers
    post = post or http_post_json
    ports, tokens = discover()
    last_err = None
    for port in ports:
        for token in tokens + [None]:  # None: the agy CLI server takes no token
            headers = {"Connect-Protocol-Version": "1"}
            if token:
                headers["X-Codeium-Csrf-Token"] = token
            try:
                payload = post(f"http://127.0.0.1:{port}{ANTIGRAVITY_RPC}",
                               headers, {})
            except FetchError as e:
                last_err = e
                continue
            return parse_antigravity(payload)
    raise last_err or FetchError("auth", "antigravity: no server answered")


def read_cursor_session(db_path=None):
    """(user_id, jwt) from Cursor's state DB, opened strictly read-only."""
    if db_path is None:
        db_path = CURSOR_DB
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
        try:
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'").fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        raise FetchError("auth", "cursor state.vscdb unreadable")
    if not row or not row[0]:
        raise FetchError("auth", "cursor access token missing")
    tok = row[0].decode() if isinstance(row[0], bytes) else row[0]
    tok = tok.strip('"')
    try:
        part = tok.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        uid = claims["sub"].split("|")[-1]
    except Exception:
        raise FetchError("auth", "cursor token is not a decodable JWT")
    if not uid:
        raise FetchError("auth", "cursor token has no subject")
    return uid, tok


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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse ALL redirects: urllib re-sends the original headers (Authorization,
    Cookie) to the Location target, cross-origin included. Every vendor endpoint
    answers 200 directly, so any 3xx is unexpected and fails as network."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # parent handler then raises HTTPError(3xx)


_OPENER = urllib.request.build_opener(_NoRedirect())


def http_get_json(url, headers, opener=_OPENER.open):
    return _http_json(url, headers, None, opener)


def http_post_json(url, headers, body, opener=_OPENER.open):
    headers = dict(headers)
    headers.setdefault("Content-Type", "application/json")
    return _http_json(url, headers, json.dumps(body).encode(), opener)


def _http_json(url, headers, data, opener):
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with opener(req, timeout=20) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        code = e.code
        e.close()  # the error carries a file-like response; never leave it to GC
        raise FetchError("auth" if code in (401, 403) else "network", f"HTTP {code}")
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


MONTH_SECONDS = 30 * 86400.0
COPILOT_NAMES = {"chat": "Chat", "completions": "Completions",
                 "premium_interactions": "Premium requests"}


def read_copilot_token(path=None):
    """The gho_ token the Copilot editor plugins store on disk. apps.json maps
    host -> {oauth_token, ...}; the quota is per user, so any entry works."""
    path = path or (Path.home() / ".config/github-copilot/apps.json")
    try:
        apps = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise FetchError("auth", "copilot apps.json missing — sign into Copilot once")
    for v in apps.values():
        if isinstance(v, dict) and v.get("oauth_token"):
            return v["oauth_token"]
    raise FetchError("auth", "copilot token missing — sign into Copilot once")


def parse_copilot(payload):
    """Monthly quota lanes from GitHub Copilot's copilot_internal/user.
    quota_snapshots gives percent_remaining per lane; skip lanes the plan
    doesn't meter (has_quota False — e.g. premium requests on the free tier)."""
    reset = payload.get("quota_reset_date")  # "YYYY-MM-DD" (resets 1st of month)
    if not reset:
        raise FetchError("parse", "copilot payload: no quota_reset_date")
    out = {}
    for lane, q in (payload.get("quota_snapshots") or {}).items():
        if not isinstance(q, dict) or not q.get("has_quota"):
            continue
        try:
            remaining = _num(q["percent_remaining"])
            pct = _num(round(100 - remaining, 1))  # derived re-validated
        except (KeyError, TypeError, ValueError):
            continue
        out[lane] = {"pct": pct,
                     "resets_at": f"{reset}T00:00:00Z",
                     "window_seconds": MONTH_SECONDS,
                     "name": COPILOT_NAMES.get(lane, lane),
                     "blocked": _num(q.get("remaining", 1)) <= 0}
    if not out:
        raise FetchError("parse", "copilot payload: no metered quotas")
    return out


def fetch_copilot(read_token=None, get=None):
    read_token = read_token or read_copilot_token
    get = get or http_get_json
    tok = read_token()
    payload = get("https://api.github.com/copilot_internal/user",
                  {"Authorization": f"token {tok}", "Editor-Version": "vscode/1.0",
                   "User-Agent": "usage-dashboard"})
    return parse_copilot(payload)


def fetch_codex(read_creds=None, get=None):
    read_creds = read_creds or read_codex_creds
    get = get or http_get_json
    tok, acct = read_creds()
    payload = get("https://chatgpt.com/backend-api/codex/usage",
                  {"Authorization": f"Bearer {tok}", "chatgpt-account-id": acct,
                   "User-Agent": "codex-cli"})
    return parse_codex(payload)


def fetch_cursor(read_session=None, post=None):
    read_session = read_session or read_cursor_session
    post = post or http_post_json
    uid, tok = read_session()
    payload = post("https://cursor.com/api/dashboard/get-current-period-usage",
                   {"Cookie": f"WorkosCursorSessionToken={uid}%3A%3A{tok}",
                    "Origin": "https://cursor.com", "User-Agent": "Mozilla/5.0"},
                   body={})
    return parse_cursor(payload)


def new_service_state():
    return {"status": "never", "fetched_at": None, "error": None, "data": None}


STATE = {s: new_service_state() for s in SERVICES}
HISTORY = []
LAST_POLL_EPOCH = 0.0
_POLL_GENERATION = 0  # completed combined polls; guarded by state_lock
state_lock = threading.Lock()
fetch_lock = threading.Lock()


def reset_state():
    global LAST_POLL_EPOCH, _POLL_GENERATION
    with state_lock:
        for s in SERVICES:
            STATE[s] = new_service_state()
        HISTORY.clear()
        LAST_POLL_EPOCH = 0.0
        _POLL_GENERATION = 0


def refresh(force=False, now_fn=time.time, fetchers=None, history_path=None):
    """The single upstream-fetch path (spec: Refresh model + Concurrency contract).

    Generation semantics: callers that captured their generation while a poll
    was in flight (forced or not) share that poll's result; a force=True call
    that begins after the previous poll completed performs a new poll.
    """
    global LAST_POLL_EPOCH, _POLL_GENERATION
    if fetchers is None:
        fetchers = {"claude": fetch_claude, "codex": fetch_codex,
                    "cursor": fetch_cursor, "antigravity": fetch_antigravity,
                    "copilot": fetch_copilot}
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
        for name in fetchers:  # snapshot covers exactly the polled services
            try:
                results[name] = ("ok", fetchers[name]())
            except FetchError as e:
                results[name] = ("err", e)
            except Exception as e:  # never let one service kill the poll
                results[name] = ("err", FetchError("parse", e.__class__.__name__))
        now = now_fn()
        snap = {"ts": epoch_to_iso(now), "ts_epoch": now}
        with state_lock:
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
            # Retention holds continuously, not just at startup: drop expired
            # snapshots each poll, compacting the file only when something fell off.
            cutoff = now - HISTORY_DAYS * 86400
            pruned = HISTORY[0]["ts_epoch"] < cutoff
            if pruned:
                HISTORY[:] = [s for s in HISTORY if s["ts_epoch"] >= cutoff]
            try:
                if pruned:
                    write_history(history_path, HISTORY)
                else:
                    append_history_line(history_path, snap)
            except OSError as e:
                print(f"history append failed: {e.__class__.__name__}", file=sys.stderr)


def public_state(st):
    return {"status": st["status"],
            "fetched_at": epoch_to_iso(st["fetched_at"]) if st["fetched_at"] else None,
            "error": st["error"],
            "data": st["data"]}


def api_payload(now_fn=time.time):
    now = now_fn()
    with state_lock:
        states = {s: dict(STATE[s]) for s in SERVICES}
        history_copy = list(HISTORY)
    derived, series = {}, {}
    for service in SERVICES:
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
                "window_seconds": window_seconds_of(limit),
                "blocked": bool(limit.get("blocked", False)),
                "remaining": limit.get("remaining"),
                "name": limit.get("name"),
                "projection": project(proj_pts, limit, now),
            }
            series[service][label] = [[round(t), p] for t, p in
                                      select_window_points(history_copy, service, path,
                                                           limit, now)]
    return {**{s: public_state(states[s]) for s in SERVICES},
            "history": series,
            "derived": derived,
            "server_time": epoch_to_iso(now)}


def seed_state_from_history():
    with state_lock:
        for snap in reversed(HISTORY):
            for service in SERVICES:
                st = STATE[service]
                if st["data"] is None and snap.get(service):
                    st["data"] = snap[service]
                    st["status"] = "stale"
                    st["fetched_at"] = snap["ts_epoch"]


HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Usage Dashboard</title>
<style>
:root {
  color-scheme: light dark;
  --page:#f1f1f4; --panel:#ffffff; --ink:#1c1c1e; --muted:#6b6b70; --faint:#98989d;
  --line:#e4e4e9; --track:#e9e9ee; --use:#0071e3;
  --under:#a65a00; --on:#1f9d4d; --over:#d70015;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root { --page:#151517; --panel:#1e1e20; --ink:#f5f5f7; --muted:#9a9aa0; --faint:#6f6f75;
          --line:#2c2c2f; --track:#2a2a2e;
          --under:#ff9f0a; --on:#30d158; --over:#ff453a; }
}
* { box-sizing:border-box; margin:0; }
body { background:var(--page); color:var(--ink); padding:32px 20px;
       font:14px/1.5 -apple-system, system-ui, sans-serif;
       -webkit-font-smoothing:antialiased; }
.wrap { width:100%; }
header { display:flex; justify-content:space-between; align-items:baseline; gap:16px;
         margin-bottom:18px; }
h1 { font-size:17px; font-weight:650; letter-spacing:-.012em; }
h1 .dim { color:var(--muted); font-weight:400; }
.nav a { color:var(--muted); text-decoration:none; font-size:12px; white-space:nowrap; }
.nav a:hover { color:var(--ink); }
.nav button { background:none; border:1px solid var(--line); border-radius:6px; cursor:pointer;
              color:var(--muted); font:inherit; font-size:12px; padding:3px 8px; margin-right:12px; }
.nav button:hover { color:var(--ink); }
.nav input[type=color] { width:22px; height:20px; padding:1px; border:1px solid var(--line);
                         border-radius:5px; background:none; cursor:pointer; vertical-align:middle; }
.openbtn { background:none; border:1px solid var(--line); border-radius:6px; cursor:pointer;
  color:var(--muted); font-size:11px; padding:1px 8px; margin-left:8px; }
.openbtn:hover { color:var(--ink); }

.group { background:var(--panel); border:1px solid var(--line); border-radius:12px;
         padding:14px 20px 16px; }
.group + .group { margin-top:16px; }
.group-h { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:12px; }
.group-h .t { font:600 11px/1 var(--mono); letter-spacing:.14em; text-transform:uppercase;
              color:var(--ink); }
.group-h .hint { font-size:11px; color:var(--muted); }

.axisrow, .lane { display:grid; grid-template-columns:150px 1fr 190px; gap:16px; align-items:center; }
.axis { position:relative; height:14px; border-bottom:1px solid var(--line); }
.axis .tick { position:absolute; top:0; font:10px/1 var(--mono); letter-spacing:.02em; color:var(--muted); }
.axis .tick.l { left:0; } .axis .tick.r { right:0; }
.axis .day { position:absolute; top:0; font:10px/1 var(--mono); letter-spacing:.02em;
             color:var(--muted); transform:translateX(-50%); white-space:nowrap; }
.axis .today { position:absolute; top:0; font:600 10px/1 var(--mono); color:var(--ink);
               transform:translateX(-50%); white-space:nowrap; }
.axis .today::after { content:""; position:absolute; left:50%; bottom:-7px; transform:translateX(-50%);
                      border:3px solid transparent; border-top-color:var(--ink); }

.lane { padding:8px 0; }
/* Continuation lane of the same provider: caption omitted, tighter gap, so
   the printed-once caption reads as the cluster's header. */
.lane.cont { padding-top:0; }
.lab { min-width:0; }
/* Provider caption is the cluster header (printed once per cluster), so it
   carries the weight; lane names are row labels and stay regular. */
.lab .svc { display:block; font:700 12px/1.2 var(--mono); letter-spacing:.08em;
            text-transform:uppercase; color:var(--ink); margin-bottom:2px; }
.lab .nm { font-size:13px; font-weight:400; color:var(--ink); }
.lab .tag { font:600 10px/1 var(--mono); letter-spacing:.05em; color:var(--muted); margin-left:7px;
            white-space:nowrap; }
.lab .tag::before { content:""; display:inline-block; width:6px; height:6px; border-radius:50%;
                    margin-right:4px; vertical-align:middle; background:var(--muted); }
.lab .tag.under::before { background:var(--under); }
.lab .tag.on::before { background:var(--on); }
.lab .tag.over::before { background:var(--over); }
.chip { display:inline-block; font:600 10px/1.4 var(--mono); color:var(--panel); background:var(--on);
        border-radius:4px; padding:0 5px; margin-left:6px; white-space:nowrap; }

.area { position:relative; height:22px; }
.win { position:absolute; top:2px; height:18px; border-radius:4px; background:var(--track);
       overflow:hidden; }
.win .fill { position:absolute; left:0; top:0; bottom:0; border-radius:4px 0 0 4px;
             transform-origin:left center; animation:fillin .5s cubic-bezier(.22,1,.36,1); }
.win.weekly::after { content:""; position:absolute; inset:0 calc(100% / 7) 0 0;
                     z-index:2; pointer-events:none;
                     background:linear-gradient(to right, transparent calc(100% - 1px),
                                color-mix(in srgb, var(--faint) 35%, transparent) 0)
                                0 0 / calc(100% / 6) 100% repeat-x; }
.win .fill.under { background:var(--under); }
.win .fill.on { background:var(--on); }
.win .fill.over { background:var(--over); }
.area .nowl { position:absolute; top:-2px; bottom:-2px; width:2px; background:var(--ink); z-index:3;
              border-radius:1px; }
.lane.stale .win { box-shadow:inset 0 0 0 1.5px var(--on); }
.lane.idle .nm, .lane.idle .meta .pct { color:var(--muted); }
body.grid-midnight .win.weekly::after { content:none; }
.area .dayl { position:absolute; top:-2px; bottom:-2px; width:1px; z-index:1;
              background:color-mix(in srgb, var(--faint) 35%, transparent); }
.lab .tag.blocked { color:var(--over); }
.lab .tag.blocked::before { background:var(--over); }
.lane.blocked .win { box-shadow:inset 0 0 0 1.5px var(--over); }

.meta { text-align:right; font-variant-numeric:tabular-nums; }
.meta .pct { font:650 15px/1 var(--mono); letter-spacing:-.01em; color:var(--ink); }
.meta .pct.under { color:var(--under); }
.meta .pct.on { color:var(--on); }
.meta .pct.over { color:var(--over); }
.meta .cd { font:11px/1 var(--mono); color:var(--muted); }
.meta .rem { display:block; margin-top:4px; font:11px/1.3 var(--mono); color:var(--ink); }
.meta .sub { display:block; margin-top:2px; font:11px/1.3 var(--mono); color:var(--muted); }

.errline { display:flex; gap:8px; align-items:center; font-size:12.5px; color:var(--ink);
           margin:8px 0 4px; padding:8px 11px; border:1px solid var(--line); border-radius:8px; }
.errline::before { content:""; flex:none; width:7px; height:7px; border-radius:50%; background:var(--on); }
.unavail { font-size:12.5px; color:var(--muted); margin-top:14px; padding-top:12px;
           border-top:1px solid var(--line); }
footer { margin-top:14px; font:11px/1.4 var(--mono); color:var(--faint); }
.legend { margin-top:18px; font-size:12.5px; color:var(--muted); }
.legend summary { cursor:pointer; font:11px/1.4 var(--mono); color:var(--faint); }
.legend summary:hover { color:var(--muted); }
.legend dl { margin:10px 0 0; padding:12px 14px; border:1px solid var(--line); border-radius:8px; }
.legend dt { font-weight:600; color:var(--ink); margin-top:8px; }
.legend dt:first-child { margin-top:0; }
.legend dd { margin:2px 0 0; line-height:1.45; }

@keyframes fillin { from { transform:scaleX(.55); } to { transform:scaleX(1); } }
@media (prefers-reduced-motion: reduce) { .win .fill { animation:none; } }
@media (max-width: 420px) {
  body { padding:20px 14px; }
  header { flex-direction:column; gap:4px; }
  .axisrow, .lane { grid-template-columns:1fr; gap:7px; }
  .axisrow > :first-child, .axisrow > :last-child { display:none; }
  .meta { text-align:left; display:flex; flex-wrap:wrap; align-items:baseline; gap:4px 10px; }
  .meta .rem, .meta .sub { margin-top:0; }
}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>AI subscriptions <span class="dim">&middot; usage vs. time</span></h1>
  <nav class="nav">
    <input type="color" id="bgl" title="Background — light mode">
    <input type="color" id="bgd" title="Background — dark mode">
    <button id="bgreset" type="button" title="Reset background colours">&#8634;</button>
    <button id="gridtoggle" type="button"></button>
    <a href="/history">weekly utilization &rarr;</a></nav>
</header>
<main><div id="board"><p class="unavail">Loading&hellip;</p></div></main>
<!-- Same wording as the macOS app's Options > Numbers tab; edit both together. -->
<details class="legend">
  <summary>&#9432; How these numbers are computed</summary>
  <dl>
    <dt>The bar</dt><dd>Fill is % of quota used; the tick is % of the window elapsed.
      The whole board is that one comparison: am I burning faster than time is passing?</dd>
    <dt>Pace badge</dt><dd>Usage &divide; elapsed. UNDER below 0.85&times;, OVER above 1.15&times;,
      ON PACE between. The first ~2% of a window always reads ON PACE so one session can't skew the ratio.</dd>
    <dt>runs out ~&hellip;</dt><dd>A trend fitted over the last 24 hours only, extrapolated forward.
      A lane can be UNDER for the week yet still warn &mdash; the badge looks back, the projection
      looks forward. If the trend lasts past the reset, it says so instead.</dd>
    <dt>BLOCKED</dt><dd>Shown only when the vendor reports the limit actually enforced, not merely
      warned. Remaining budget is shown when the vendor provides it.</dd>
    <dt>grid: midnights / window &divide;7</dt><dd>Two ways to slice weekly bars: gridlines at local
      midnights on the shared axis, or each bar divided into seven equal sevenths of its own window.</dd>
    <dt>Stale lanes</dt><dd>A lane that can't be fetched keeps its last good numbers and is marked
      stale with their age &mdash; never a guessed value.</dd>
  </dl>
</details>
<footer id="footer" aria-live="polite"></footer>
</div>
<script>
"use strict";
// User-selectable page background, one colour per scheme, persisted in
// localStorage (same origin, so / and /history share it). No stored value =
// remove the inline override so the stylesheet default rules again.
(function () {
  const DEF = {light: "#f1f1f4", dark: "#151517"};   // mirror the :root --page values
  const mq = matchMedia("(prefers-color-scheme: dark)");
  const pick = {light: document.getElementById("bgl"), dark: document.getElementById("bgd")};
  const key = (m) => m === "dark" ? "bgDark" : "bgLight";
  // PRODUCT.md: body text ≥ 4.5:1 in both themes — accept a background only if
  // it keeps that ratio against the theme's ink. WCAG 2.x relative luminance.
  function bgOK(hex, dark) {
    const lum = h => {
      const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255)
        .map(v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    };
    const l = lum(hex), ink = lum(dark ? "#f5f5f7" : "#1c1c1e");
    return (Math.max(l, ink) + 0.05) / (Math.min(l, ink) + 0.05) >= 4.5;
  }
  function apply() {
    const m = mq.matches ? "dark" : "light";
    const c = localStorage.getItem(key(m));
    // A stored value that fails the rule (persisted before it existed) is
    // never applied — the stylesheet default rules instead.
    if (c && bgOK(c, m === "dark")) document.documentElement.style.setProperty("--page", c);
    else document.documentElement.style.removeProperty("--page");
  }
  for (const m of ["light", "dark"]) {
    pick[m].value = localStorage.getItem(key(m)) || DEF[m];
    pick[m].addEventListener("input", () => {
      if (!bgOK(pick[m].value, m === "dark")) {          // reject: snap back
        pick[m].value = localStorage.getItem(key(m)) || DEF[m];
        return;
      }
      localStorage.setItem(key(m), pick[m].value); apply();
    });
  }
  document.getElementById("bgreset").addEventListener("click", () => {
    for (const m of ["light", "dark"]) { localStorage.removeItem(key(m)); pick[m].value = DEF[m]; }
    apply();
  });
  mq.addEventListener("change", apply);
  apply();
})();
const PACE = {under: "UNDER", on: "ON PACE", over: "OVER"};
const LABELS = {session: "5-hour session", weekly_scoped: "Weekly - Opus and above", rolling: "Rolling",
                monthly: "Monthly - included usage",
                monthly_auto: "Monthly - Cursor models", monthly_api: "Monthly - other models"};
const GROUPS = [["rolling", "Rolling", "5-hour window"],
                ["weekly", "Weekly", "7-day windows"],
                ["monthly", "Monthly", "billing cycle"]];
const RANK = {over: 0, on: 1, under: 2};
const STALE_FIX = {claude: "Token stale — open Claude Code once",
                   codex: "Token stale — run codex once",
                   cursor: "Token stale — open Cursor once",
                   antigravity: "Antigravity not running — open it to see usage",
                   copilot: "Token stale — sign into Copilot once"};

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
}
function clampPct(x) { return Math.max(0, Math.min(100, x)); }
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
  return "runs out ~" + fmtReset(proj.exhaust_epoch);
}
function fmtReset(epoch) {
  return new Date(epoch * 1000).toLocaleString(undefined,
    {weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit"});
}
function countdown(epoch) {
  const s = Math.max(0, epoch * 1000 - Date.now()) / 1000;
  if (s >= 86400) return Math.round(s / 86400) + "d";
  if (s >= 3600) return Math.round(s / 3600) + "h";
  return Math.max(1, Math.round(s / 60)) + "m";
}
function relLabel(sec) {
  const a = Math.abs(sec), v = a < 3600 ? Math.round(a / 60) + "m" : Math.round(a / 3600) + "h";
  return sec < 0 ? v + " ago" : "in " + v;
}
function bucketOf(ws) { return ws < 172800 ? "rolling" : ws < 1728000 ? "weekly" : "monthly"; }
function edgeLabel(key, epoch) {
  const d = new Date(epoch * 1000);
  if (key === "rolling") return relLabel(epoch - Date.now() / 1000);
  if (key === "monthly") return d.toLocaleDateString(undefined, {month: "short", day: "numeric"});
  return d.toLocaleDateString(undefined, {weekday: "short"});
}
// Place each window on the group's shared date axis; returns axis extent + now%.
function groupLayout(items, nowSec) {
  let start = Infinity, end = -Infinity;
  for (const it of items) {
    start = Math.min(start, it.d.reset_epoch - it.d.window_seconds);
    end = Math.max(end, it.d.reset_epoch);
  }
  const span = (end - start) || 1;
  for (const it of items) {
    const ws = it.d.window_seconds, s = it.d.reset_epoch - ws;
    it.left = clampPct((s - start) / span * 100);
    it.width = clampPct(ws / span * 100);
    it.nowPct = clampPct((nowSec - start) / span * 100);
    it.fill = clampPct(it.d.pct);
  }
  return {start: start, end: end, nowPct: clampPct((nowSec - start) / span * 100)};
}
function openBtn(svc, err) {  // "not running" is fixable with one click
  if (svc !== "antigravity" || !err || err.category !== "auth") return "";
  return ' <button type="button" class="openbtn" ' +
         'onclick="fetch(\'/api/open-antigravity\',{method:\'POST\'})">Open Antigravity</button>';
}
function errorLine(svc, err) {  // service has data but is stale/errored
  const msg = err.category === "auth" ? STALE_FIX[svc]
            : "Can't reach " + svc + " (" + err.category + ")";
  return '<p class="errline" role="alert">' + esc(msg) + openBtn(svc, err) + '</p>';
}
function unavailLine(svc, err) {  // service has no data at all
  const msg = (err && err.category === "auth") ? STALE_FIX[svc]
            : svc + " — no data yet" + (err ? " (" + err.category + ")" : "");
  return '<p class="unavail">' + esc(msg) + openBtn(svc, err) + '</p>';
}
function axisRow(key, m) {
  // Rolling is hours-scale, so the marker carries the actual clock time.
  const mark = key === "monthly" ? "today"
             : key === "rolling" ? new Date().toLocaleTimeString(undefined,
                 {hour: "2-digit", minute: "2-digit"})
             : "now";
  let inner;
  if (key === "weekly") {
    // A name over each calendar day instead of edge labels (mirrors the
    // macOS board): skip sliver segments and anything under the now-marker.
    inner = dayLabels(m).map(d =>
      '<span class="day" style="left:' + d.pct.toFixed(1) + '%">' + esc(d.name) + '</span>').join('');
  } else {
    // Drop an edge tick when the now-marker sits close enough to collide with it.
    inner = (m.nowPct > 16 ? '<span class="tick l">' + esc(edgeLabel(key, m.start)) + '</span>' : '') +
            (m.nowPct < 84 ? '<span class="tick r">' + esc(edgeLabel(key, m.end)) + '</span>' : '');
  }
  return '<div class="axisrow"><div></div><div class="axis">' + inner +
    '<span class="today" style="left:' + m.nowPct.toFixed(1) + '%">' + mark + '</span>' +
    '</div><div></div></div>';
}
// One label per calendar day, centered over the day's segment on the shared axis.
function dayLabels(m) {
  const span = (m.end - m.start) || 1, out = [];
  const bounds = [m.start], d = new Date(m.start * 1000);
  d.setHours(24, 0, 0, 0);  // first midnight after axis start
  // Cap iterations: a corrupted far-future reset epoch (e.g. vendor sends ms
  // for seconds) would otherwise spin for hundreds of thousands of days.
  let guard = 0;
  while (d.getTime() / 1000 < m.end && guard++ < 400) {
    bounds.push(d.getTime() / 1000);
    d.setDate(d.getDate() + 1);
    d.setHours(0, 0, 0, 0);
  }
  bounds.push(m.end);
  for (let i = 0; i < bounds.length - 1; i++) {
    const a = bounds[i], b = bounds[i + 1];
    if ((b - a) / span < 0.05) continue;
    const pct = ((a + b) / 2 - m.start) / span * 100;
    if (Math.abs(pct - m.nowPct) < 5.5) continue;
    out.push({pct: pct, name: new Date((a + b) / 2 * 1000)
      .toLocaleDateString(undefined, {weekday: "short"})});
  }
  return out;
}
// Local-midnight gridlines on the group's shared axis (grid=midnight mode).
function midnightLines(m) {
  let out = "";
  const span = (m.end - m.start) || 1, d = new Date(m.start * 1000);
  d.setHours(24, 0, 0, 0);  // first midnight after axis start; setDate below is DST-safe
  let guard = 0;  // same far-future-epoch guard as dayLabels
  while (d.getTime() / 1000 < m.end && guard++ < 400) {
    out += '<div class="dayl" style="left:' +
      ((d.getTime() / 1000 - m.start) / span * 100).toFixed(2) + '%" aria-hidden="true"></div>';
    d.setDate(d.getDate() + 1);
    d.setHours(0, 0, 0, 0);
  }
  return out;
}
function lane(it, days, cont) {  // cont: same provider as the lane above —
                                 // caption printed once per cluster, tighter gap
  const d = it.d, pace = d.pace, pct = Math.round(d.pct), blocked = !!d.blocked;
  const weekly = bucketOf(d.window_seconds) === "weekly" ? " weekly" : "";
  const aria = it.svc + " " + it.name + " — " + pct + "% used, " +
               (blocked ? "limit reached, " : "") + pace + " pace, " +
               Math.round(d.elapsed_pct) + "% of window elapsed";
  const tag = blocked ? '<span class="tag blocked">LIMIT REACHED</span>'
                      : '<span class="tag ' + pace + '">' + PACE[pace] + '</span>';
  const chip = it.stale ? '<span class="chip">stale ' + esc(it.age) + '</span>' : '';
  const rem = d.remaining != null
    ? '<span class="rem">$' + Number(d.remaining).toFixed(2) + ' left</span>' : '';
  return '<div class="lane' + (it.stale ? ' stale' : '') + (blocked ? ' blocked' : '') +
      (cont ? ' cont' : '') + '">' +
    '<div class="lab">' + (cont ? '' : '<span class="svc">' + esc(it.svc) + '</span>') +
      '<span class="nm">' + esc(it.name) + '</span>' + tag + chip + '</div>' +
    '<div class="area">' +
      '<div class="win' + weekly + '" style="left:' + it.left.toFixed(1) + '%;width:' + it.width.toFixed(1) + '%"' +
        ' role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + pct + '"' +
        ' aria-label="' + esc(aria) + '">' +
        '<div class="fill ' + pace + '" style="width:' + it.fill.toFixed(1) + '%"></div></div>' +
      (days || '') +
      '<div class="nowl" style="left:' + it.nowPct.toFixed(1) + '%" aria-hidden="true"></div>' +
    '</div>' +
    '<div class="meta"><span class="pct ' + pace + '">' + pct + '%</span>' +
      ' <span class="cd">· ' + esc(countdown(d.reset_epoch)) + '</span>' +
      '<span class="sub">resets ' + esc(fmtReset(d.reset_epoch)) + '</span>' +
      rem + '<span class="sub">' + esc(verdict(d.projection)) + '</span></div></div>';
}
let gridMode = localStorage.getItem("gridMode") || "window";
let lastData = null;
function applyGridMode() {
  document.body.classList.toggle("grid-midnight", gridMode === "midnight");
  document.getElementById("gridtoggle").textContent =
    gridMode === "midnight" ? "grid: midnights" : "grid: window /7";
}
document.getElementById("gridtoggle").addEventListener("click", () => {
  gridMode = gridMode === "midnight" ? "window" : "midnight";
  localStorage.setItem("gridMode", gridMode);
  applyGridMode();
  if (lastData) render(lastData);
});
applyGridMode();
function idleLane() {
  return '<div class="lane idle">' +
    '<div class="lab"><span class="svc">claude</span><span class="nm">5-hour session</span>' +
      '<span class="tag">IDLE</span></div>' +
    '<div class="area"><div class="win" role="progressbar" aria-valuemin="0" aria-valuemax="100"' +
      ' aria-valuenow="0" aria-label="claude 5-hour session — no active session"' +
      ' style="left:0;width:100%"></div></div>' +
    '<div class="meta"><span class="pct">0%</span>' +
      '<span class="sub">no active session</span></div></div>';
}
function render(data) {
  lastData = data;
  const nowSec = Date.now() / 1000;
  let top = "", bottom = "";
  const limits = [];
  for (const svc of ["claude", "codex", "cursor", "antigravity", "copilot"]) {
    const st = data[svc];
    if (!st.data) { bottom += unavailLine(svc, st.error); continue; }
    if (st.error) top += errorLine(svc, st.error);
    const stale = st.status !== "fresh";
    const age = stale && st.fetched_at ? ageText(data.server_time, st.fetched_at) : "";
    const derived = data.derived[svc] || {};
    for (const [label, d] of Object.entries(derived)) {
      limits.push({svc: svc, name: d.name || LABELS[label] || label.replace(/_/g, " "),
                   d: d, stale: stale, age: age});
    }
  }
  let html = top;
  // Claude reports session as percent 0 / resets_at null between sessions;
  // keep the rolling group visible with a placeholder instead of vanishing.
  const sessionIdle = data.claude && data.claude.data && !data.claude.data.session;
  for (const [key, title, hint] of GROUPS) {
    const items = limits.filter(it => bucketOf(it.d.window_seconds) === key);
    const idle = key === "rolling" && sessionIdle ? idleLane() : "";
    if (!items.length && !idle) continue;
    // Merged-board spec: worst pace first (over → on → under), tiebreak
    // soonest reset — global order within the group, no provider clustering.
    items.sort((a, b) => (RANK[a.d.pace] - RANK[b.d.pace]) || (a.d.reset_epoch - b.d.reset_epoch));
    html += '<div class="group"><div class="group-h"><span class="t">' + title +
      '</span><span class="hint">' + hint + '</span></div>';
    if (items.length) {
      const m = groupLayout(items, nowSec);
      const days = gridMode === "midnight" && key === "weekly" ? midnightLines(m) : "";
      html += axisRow(key, m);
      for (let i = 0; i < items.length; i++)
        html += lane(items[i], days, i > 0 && items[i].svc === items[i - 1].svc);
    }
    html += idle + '</div>';
  }
  html += bottom;
  document.getElementById("board").innerHTML = html || '<p class="unavail">No data yet.</p>';
  document.getElementById("footer").textContent =
    "page refreshed " + new Date().toLocaleTimeString() + " (auto every 5 min)";
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


HISTORY_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Weekly utilization</title>
<style>
:root {
  color-scheme: light dark;
  --page:#f1f1f4; --panel:#ffffff; --ink:#1c1c1e; --muted:#6b6b70; --faint:#98989d;
  --line:#e4e4e9; --track:#e9e9ee; --use:#0071e3;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root { --page:#151517; --panel:#1e1e20; --ink:#f5f5f7; --muted:#9a9aa0; --faint:#6f6f75;
          --line:#2c2c2f; --track:#2a2a2e; --use:#0a84ff; }
}
* { box-sizing:border-box; margin:0; }
body { background:var(--page); color:var(--ink); font:14px/1.5 -apple-system, system-ui, sans-serif;
       padding:28px 20px; max-width:760px; margin:0 auto; }
header { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:6px; }
h1 { font-size:18px; font-weight:700; }
a { color:var(--use); text-decoration:none; font:12px/1 var(--mono); }
.nav { display:flex; align-items:center; gap:8px; }
.nav input[type=color] { width:22px; height:20px; padding:1px; border:1px solid var(--line);
                         border-radius:5px; background:none; cursor:pointer; }
.nav button { background:none; border:1px solid var(--line); border-radius:6px; cursor:pointer;
              color:var(--muted); font:inherit; font-size:12px; padding:2px 7px; }
.nav button:hover { color:var(--ink); }
.intro { color:var(--muted); margin-bottom:22px; }
.card { background:var(--panel); border:1px solid var(--line); border-radius:12px;
        padding:16px 18px; margin-bottom:14px; }
.card-h { display:flex; justify-content:space-between; align-items:baseline; gap:12px;
          margin-bottom:14px; }
.svc { font:700 11px/1.2 var(--mono); letter-spacing:.08em; text-transform:uppercase; }
.nm { font-size:13px; color:var(--muted); margin-left:8px; }
.summ { font:12px/1 var(--mono); color:var(--muted); white-space:nowrap; }
.summ b { color:var(--ink); }
/* Column chart: each week a bar, height = peak% of the window's allowance. */
.chart { display:flex; align-items:flex-end; gap:6px; height:130px;
         border-bottom:1px solid var(--line); padding-bottom:0; }
.col { flex:1; min-width:0; display:flex; flex-direction:column; justify-content:flex-end;
       align-items:center; height:100%; position:relative; }
.col .track { position:absolute; inset:0 0 0 0; background:var(--track); border-radius:3px;
              opacity:.5; }
.col .fill { width:100%; background:var(--use); border-radius:3px 3px 0 0; position:relative;
             min-height:2px; }
.col.now .fill { background:repeating-linear-gradient(45deg, var(--use), var(--use) 4px,
                 transparent 4px, transparent 7px), var(--use); opacity:.85; }
.col .v { position:absolute; top:-16px; width:100%; text-align:center;
          font:600 10px/1 var(--mono); color:var(--ink); }
.dates { display:flex; gap:6px; margin-top:6px; }
.dates span { flex:1; text-align:center; font:9px/1.2 var(--mono); color:var(--faint); }
.avgline { border-top:1px dashed var(--faint); position:relative; }
.empty { color:var(--muted); }
footer { color:var(--faint); font:11px/1.4 var(--mono); margin-top:18px; }
</style>
</head>
<body>
<header>
  <h1>Weekly utilization</h1>
  <nav class="nav">
    <input type="color" id="bgl" title="Background — light mode">
    <input type="color" id="bgd" title="Background — dark mode">
    <button id="bgreset" type="button" title="Reset background colours">&#8634;</button>
    <a href="/">&larr; live board</a>
  </nav>
</header>
<p class="intro">Peak usage reached in each reset window — how much of what you pay for you
actually use. Short bars week after week mean headroom you're not touching.</p>
<div id="root"><p class="empty">Loading…</p></div>
<footer id="foot"></footer>
<script>
"use strict";
// Same background-picker wiring as the live board; the localStorage keys are
// shared across both pages. Edit both together.
(function () {
  const DEF = {light: "#f1f1f4", dark: "#151517"};   // mirror the :root --page values
  const mq = matchMedia("(prefers-color-scheme: dark)");
  const pick = {light: document.getElementById("bgl"), dark: document.getElementById("bgd")};
  const key = (m) => m === "dark" ? "bgDark" : "bgLight";
  // PRODUCT.md: body text ≥ 4.5:1 in both themes — accept a background only if
  // it keeps that ratio against the theme's ink. WCAG 2.x relative luminance.
  function bgOK(hex, dark) {
    const lum = h => {
      const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255)
        .map(v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    };
    const l = lum(hex), ink = lum(dark ? "#f5f5f7" : "#1c1c1e");
    return (Math.max(l, ink) + 0.05) / (Math.min(l, ink) + 0.05) >= 4.5;
  }
  function apply() {
    const m = mq.matches ? "dark" : "light";
    const c = localStorage.getItem(key(m));
    // A stored value that fails the rule (persisted before it existed) is
    // never applied — the stylesheet default rules instead.
    if (c && bgOK(c, m === "dark")) document.documentElement.style.setProperty("--page", c);
    else document.documentElement.style.removeProperty("--page");
  }
  for (const m of ["light", "dark"]) {
    pick[m].value = localStorage.getItem(key(m)) || DEF[m];
    pick[m].addEventListener("input", () => {
      if (!bgOK(pick[m].value, m === "dark")) {          // reject: snap back
        pick[m].value = localStorage.getItem(key(m)) || DEF[m];
        return;
      }
      localStorage.setItem(key(m), pick[m].value); apply();
    });
  }
  document.getElementById("bgreset").addEventListener("click", () => {
    for (const m of ["light", "dark"]) { localStorage.removeItem(key(m)); pick[m].value = DEF[m]; }
    apply();
  });
  mq.addEventListener("change", apply);
  apply();
})();
const NAMES = {weekly_all:"Weekly - all models", monthly_auto:"Monthly - Cursor models",
               monthly_api:"Monthly - other models", monthly:"Monthly - included usage"};
function esc(s){return String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}
function shortDate(ep){return new Date(ep*1000).toLocaleDateString(undefined,{day:"numeric",month:"short"});}
function card(l, now){
  const name = NAMES[l.label] || l.name;
  let cols = "", dates = "";
  for (const w of l.windows){
    const open = w.reset > now;                       // still-running window: partial peak
    const h = Math.max(2, Math.min(100, w.peak));
    cols += '<div class="col'+(open?' now':'')+'"><div class="track"></div>' +
            '<div class="fill" style="height:'+h+'%"><span class="v">'+Math.round(w.peak)+'</span></div></div>';
    dates += '<span>'+esc(shortDate(w.reset))+(open?'*':'')+'</span>';
  }
  return '<div class="card"><div class="card-h"><div>' +
    '<span class="svc">'+esc(l.svc)+'</span><span class="nm">'+esc(name)+'</span></div>' +
    '<span class="summ">avg <b>'+l.avg+'%</b> &middot; peak <b>'+l.max+'%</b> &middot; '+l.count+' wk</span>' +
    '</div><div class="chart">'+cols+'</div><div class="dates">'+dates+'</div></div>';
}
async function load(){
  let d;
  try { d = await (await fetch("/api/history")).json(); }
  catch(e){ document.getElementById("root").innerHTML='<p class="empty">Could not load history.</p>'; return; }
  const now = Date.now()/1000;
  const lanes = d.lanes || [];
  if (!lanes.length){ document.getElementById("root").innerHTML='<p class="empty">No weekly history yet.</p>'; return; }
  document.getElementById("root").innerHTML = lanes.map(l=>card(l, now)).join("");
  document.getElementById("foot").textContent =
    "* current window is still open — its bar is a partial peak. Weekly + monthly lanes only.";
}
load();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "usage-dashboard"

    def _host_ok(self):
        # DNS-rebinding defense: a rebound attacker page sends Host: attacker.com,
        # so pin Host to loopback on the port we actually bound. Cross-site fetch
        # metadata is a second gate (older browsers omit it — Host is the floor).
        port = self.server.server_address[1]
        host = (self.headers.get("Host") or "").lower()
        if host not in (f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}"):
            return False
        if self.headers.get("Sec-Fetch-Site") == "cross-site":
            return False
        return True

    def do_GET(self):
        try:
            if not self._host_ok():
                self._send(403, "text/plain; charset=utf-8", b"forbidden")
                return
            if self.path in ("/", "/index.html"):
                self._send(200, "text/html; charset=utf-8", HTML_PAGE.encode())
            elif self.path == "/api/usage":
                try:
                    refresh()
                except Exception as e:
                    print(f"refresh error: {e.__class__.__name__}", file=sys.stderr)
                self._send(200, "application/json", json.dumps(api_payload()).encode())
            elif self.path == "/history":
                self._send(200, "text/html; charset=utf-8", HISTORY_PAGE.encode())
            elif self.path == "/api/history":
                self._send(200, "application/json", json.dumps(
                    {"lanes": weekly_utilization(), "server_time": epoch_to_iso(time.time())}).encode())
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

    def do_POST(self):
        try:
            if not self._host_ok():
                self._send(403, "text/plain; charset=utf-8", b"forbidden")
                return
            if self.path == "/api/open-antigravity":
                # Fixed action, no parameters — the endpoint can only ever do
                # exactly what the button says. POST-only so a hostile page
                # can't trigger it with an <img>/link GET.
                # "Antigravity IDE", not "Antigravity" — two apps exist and
                # only the IDE runs the language server we read usage from.
                subprocess.Popen(["open", "-a", "Antigravity IDE"])
                self._send(200, "text/plain; charset=utf-8", b"ok")
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
        return [(k, [k]) for k in ("session", "weekly_all", "weekly_scoped") if k in data]
    if service == "cursor":
        # "monthly" kept so stale pre-2026-08 snapshots still render
        return [(k, [k]) for k in ("monthly_auto", "monthly_api", "monthly") if k in data]
    if service in ("antigravity", "copilot"):
        return [(k, [k]) for k in sorted(data)]  # one lane per pool / quota
    paths = [("rolling", ["rolling"])] if "rolling" in data else []
    paths += [("weekly", ["weekly"])] if "weekly" in data else []
    paths += [(name, ["models", name]) for name in sorted(data.get("models") or {})]
    return paths


def bucket_of(window_seconds):
    if window_seconds < 2 * 86400:
        return "rolling"
    if window_seconds < 20 * 86400:
        return "weekly"
    return "monthly"


def weekly_utilization(history=None):
    """Peak usage % reached within each reset window, per non-rolling lane —
    the "am I using my subscription enough?" view. Reset timestamps jitter by
    sub-seconds between polls, so windows are keyed by reset DAY (weekly and
    monthly resets are days apart and never collide). Rolling/5-hour lanes are
    excluded: they reset too often to say anything about subscription value."""
    if history is None:
        with state_lock:
            history = list(HISTORY)
    lanes = {}  # (svc, label) -> {reset_day -> {peak, reset, name}}
    for snap in history:
        for svc in SERVICES:
            data = snap.get(svc)
            if not data:
                continue
            for label, path in limit_paths(svc, data):
                # Skip Cursor's legacy "monthly" lane: totalPercentUsed
                # overstates (can exceed 100%) — monthly_auto/api are the real
                # meters. Same reasoning as parse_cursor.
                if svc == "cursor" and label == "monthly":
                    continue
                limit = get_limit(data, path)
                if not limit:
                    continue
                try:
                    ws = window_seconds_of(limit)
                    if bucket_of(ws) == "rolling":
                        continue
                    reset = reset_epoch(limit)
                    pct = float(limit.get("pct", 0))
                except (KeyError, TypeError, ValueError, AttributeError):
                    continue  # e.g. a snapshot with resets_at: null
                win = lanes.setdefault((svc, label), {})
                day = int(reset // 86400)
                if day not in win or pct > win[day]["peak"]:
                    win[day] = {"peak": pct, "reset": reset, "ws": ws,
                                "name": limit.get("name") or label,
                                "bucket": bucket_of(ws)}
    out = []
    for (svc, label), win in lanes.items():
        windows = [win[d] for d in sorted(win)]
        # Only fixed-schedule resets belong here (Claude weekly snaps to a
        # weekday, Cursor to a billing date). A sliding reset (Codex's rolling
        # now+7d) fragments into far more windows than the timespan can hold —
        # drop a lane whose window count is >2x what its period allows.
        span = windows[-1]["reset"] - windows[0]["reset"]
        period = windows[-1]["ws"]
        expected = span / period + 1 if period else len(windows)
        if len(windows) > 2 * expected + 1:
            continue
        peaks = [w["peak"] for w in windows]
        out.append({
            "svc": svc, "label": label, "name": windows[-1]["name"],
            "bucket": windows[-1]["bucket"],
            "windows": [{"reset": round(w["reset"]), "peak": round(w["peak"], 1)}
                        for w in windows],
            "avg": round(sum(peaks) / len(peaks), 1),
            "max": round(max(peaks), 1), "count": len(peaks)})
    rank = {"weekly": 0, "monthly": 1}
    out.sort(key=lambda x: (rank.get(x["bucket"], 2), x["svc"], x["label"]))
    return out


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


def append_history_line(path, snap):
    rec = {k: v for k, v in snap.items() if k != "ts_epoch"}
    line = json.dumps(rec, separators=(",", ":")) + "\n"
    with open(path, "a") as f:
        f.write(line)
        f.flush()


def write_history(path, snaps):
    """Atomically rewrite the whole history file (tmp + rename)."""
    p = Path(path)
    tmp = p.with_name(p.name + ".tmp")
    with open(tmp, "w") as f:
        for rec in snaps:
            f.write(json.dumps({k: v for k, v in rec.items() if k != "ts_epoch"},
                               separators=(",", ":")) + "\n")
    tmp.replace(p)


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
    write_history(p, kept)
    return kept


def _pick_weekly_window(rate_limit):
    """Find the 7-day window regardless of slot: the backend has been observed
    serving it as secondary_window (afternoon 2026-07-12) and as primary_window
    with secondary null (evening same day). Identify by limit_window_seconds."""
    wins = [w for w in (rate_limit.get("primary_window"),
                        rate_limit.get("secondary_window")) if isinstance(w, dict)]
    for w in wins:
        if float(w.get("limit_window_seconds", 0)) == 604800.0:
            return w
    longish = [w for w in wins if float(w.get("limit_window_seconds", 0)) >= 6 * 86400]
    return max(longish, key=lambda w: float(w["limit_window_seconds"])) if longish else None


def _pick_rolling_window(rate_limit):
    """Find the account-level rolling window (5h / 18000 s) regardless of slot.
    Like the weekly picker, identify by limit_window_seconds not by slot name.
    Account-level only: per-model rolling windows are deliberately ignored."""
    wins = [w for w in (rate_limit.get("primary_window"),
                        rate_limit.get("secondary_window")) if isinstance(w, dict)]
    # A missing or non-positive duration is not a rolling window — ignore it (a
    # malformed nonnumeric duration still raises and surfaces as a parse error).
    sub = [w for w in wins if w.get("limit_window_seconds") is not None
           and 0 < float(w["limit_window_seconds"]) < 21600]
    return min(sub, key=lambda w: float(w["limit_window_seconds"])) if sub else None


def parse_codex(payload):
    """Extract the rolling + weekly + per-model weekly windows from the Codex usage payload."""
    try:
        rl = payload["rate_limit"]
        weekly = _pick_weekly_window(rl)
        if weekly is None:
            raise FetchError("parse", "codex payload: no weekly window")
        acct_blocked = _rl_blocked(rl)
        out = {"weekly": _codex_window(weekly, acct_blocked), "models": {}}
        rolling = _pick_rolling_window(rl)
        if rolling is not None:
            out["rolling"] = _codex_window(rolling, acct_blocked)
        for extra in payload.get("additional_rate_limits") or []:
            erl = extra.get("rate_limit") or {}
            mw = _pick_weekly_window(erl)
            if mw:
                out["models"][extra.get("limit_name") or "unnamed"] = _codex_window(mw, _rl_blocked(erl))
    except FetchError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        raise FetchError("parse", f"codex payload: {e.__class__.__name__}")
    return out


if __name__ == "__main__":
    sys.exit(main())
