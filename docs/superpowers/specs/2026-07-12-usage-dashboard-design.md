# Usage Dashboard — Design

**Date:** 2026-07-12 (revised same day: architect correction gate)
**Status:** Approved
**Goal:** A local web dashboard showing Claude Code and Codex subscription usage side by side — time elapsed in each limit window vs. quota consumed — focused on the weekly limits.

## Scope

Tracked limits:

- **Claude weekly (all models)** — `weekly_all` from the OAuth usage API
- **Claude weekly scoped (Opus-class)** — `weekly_scoped` from the same response
- **Codex weekly** — `secondary_window` (604800 s window) from the Codex usage API
- **Codex per-model weekly limits** — entries in `additional_rate_limits` (e.g. GPT-5.3-Codex-Spark), secondary window only
- **Burn-rate projection** per weekly limit

Explicitly out of scope: 5-hour session limits, extra-usage credits, the claude.ai and chatgpt.com web pages (not scraped — the APIs below carry the same data).

## Architecture

One self-contained file, `dashboard.py`, Python 3 stdlib only (no pip/venv/npm). It:

1. Serves the dashboard UI on **`127.0.0.1:8787` (loopback only — the socket binds explicitly to `127.0.0.1`, never `0.0.0.0` or `::`)** as a single embedded HTML/CSS/JS page.
2. Exposes `GET /api/usage` returning the current per-service state (see *API state model*) plus the history needed for sparklines and projection.
3. Runs a background thread that performs a **combined poll** (both vendors) every 20 minutes and appends the result to `history.jsonl` next to the script.

Deployed as a launchd agent (see *Deployment*), so it survives crashes and reboots.

### Refresh model (single path, reconciled)

There is exactly one upstream-fetch path, `refresh()`, used by both the 20-minute poll thread and HTTP requests:

- The browser page calls `GET /api/usage` on load and then every 5 minutes from JS. It never has a separate "fresh fetch" mechanism.
- `GET /api/usage` calls `refresh()` first. `refresh()` performs a live upstream fetch only if the cached combined snapshot is older than 60 s; otherwise it returns the cache untouched. So a page load shows data at most 60 s old, and the 5-minute JS refresh simply re-runs the same rate-limited path.
- The poll thread calls `refresh(force=True)` every 20 minutes, bypassing the 60 s freshness check but not the single-flight lock below.

### Concurrency contract

One module-level `threading.Lock` (`state_lock`) plus a single-flight guard govern all shared state:

- **Single-flight:** at most one upstream combined fetch runs at any moment. A caller that finds a fetch already in progress waits for that fetch's result instead of starting a second one (poll thread and any number of concurrent HTTP requests included). The 20-minute poll and a page-triggered refresh can therefore never overlap.
- **State safety:** the cached combined snapshot, per-service state objects, and the in-memory history list are read and written only while holding `state_lock`. HTTP handlers copy what they need under the lock and render outside it.
- **History append:** exactly one JSONL line is appended per **completed combined poll** (a `refresh()` that actually hit upstream — whether both, one, or neither service succeeded). The line is fully serialized first and written with a single `write()` + flush while holding `state_lock`, so no partial or interleaved lines are possible. Cache-served `refresh()` calls append nothing.

## Data sources (both verified working 2026-07-12)

| | Claude | Codex |
|---|---|---|
| Credential | macOS Keychain item `Claude Code-credentials` → `claudeAiOauth.accessToken` | `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id` |
| Endpoint | `GET https://api.anthropic.com/api/oauth/usage` | `GET https://chatgpt.com/backend-api/codex/usage` |
| Headers | `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` | `Authorization: Bearer <token>`, `chatgpt-account-id: <id>`, `User-Agent: codex-cli` |
| Fields used | `limits[]` entries with `group == "weekly"` (`kind`: `weekly_all`, `weekly_scoped`): `percent`, `resets_at` (ISO 8601) | `rate_limit.secondary_window` and each `additional_rate_limits[].rate_limit.secondary_window`: `used_percent`, `limit_window_seconds`, `reset_at` (epoch) |

Rules:

- Tokens are read fresh from Keychain / `auth.json` at every poll. Never cached to disk, never logged, never included in `/api/usage` responses or `history.jsonl`, never sent anywhere except the vendor's own endpoint.
- The CLIs themselves keep these tokens refreshed through normal use; the dashboard performs no token refresh of its own.
- Field mapping is defensive: a missing `weekly_scoped` or empty `additional_rate_limits` simply hides that bar, it is not an error.

## API state model

`GET /api/usage` returns one state object **per service**, so one service degrading never discards or hides the other:

```json
{
  "claude": {
    "status": "fresh",              // "fresh" | "stale" | "never"
    "fetched_at": "2026-07-12T17:40:02Z",   // when the shown data was actually obtained
    "error": null,                   // null | {"category": "auth"|"network"|"parse", "at": "...", "detail": "HTTP 401"}
    "data": { "weekly_all": {...}, "weekly_scoped": {...} }
  },
  "codex": { ... same shape ... },
  "history": { ... trimmed series for sparklines/projection ... },
  "server_time": "2026-07-12T17:40:05Z"
}
```

- `status: "fresh"` — `data` came from the most recent successful upstream fetch.
- `status: "stale"` — the latest fetch for this service failed; `data` is the last-known-good snapshot (from memory, or seeded from the newest valid `history.jsonl` entry on startup), `fetched_at` is its original acquisition time (so the UI can show age), and `error` carries the category and time of the most recent failure. `category: "auth"` (HTTP 401/403, missing credential) drives the "token stale — run the CLI once" banner; `"network"` (timeouts, 5xx, DNS) and `"parse"` (unexpected payload shape) drive a generic "can't reach / unexpected response" banner.
- `status: "never"` — no successful fetch ever and nothing in history; `data` is `null` and the column renders an empty state.

## Derived values

- **Window start** = reset time − window length (7 days for weekly). **Time elapsed %** = `(now − window_start) / window_length`.
- **Pace badge** per limit: burn rate = usage % ÷ elapsed %, i.e. usage relative to the rate that exactly consumes the window. Under pace (< 0.85×) 🟢, on pace (0.85×–1.15×) 🟡, over pace (> 1.15×) 🔴. Below 2 % elapsed the badge is forced to "on pace" — a single session skews the ratio, and elapsed = 0 has no defined rate. (Amended 2026-07-13: was a fixed ±5-point band, which read "on pace" at 7 % elapsed / 9 % used — a 1.3× burn that exhausts the window by day 5 of 7. Percentage points are too forgiving early in a window and too strict late; the ratio is scale-free.)
- **Burn-rate projection**: computed **per limit**. Selected history = snapshots from the trailing 24 h whose timestamp is ≥ that limit's own current window start (derived from **that limit's** reset timestamp: `resets_at − 7 d` for Claude, `reset_at − limit_window_seconds` for Codex). Different limits reset at different times, so each limit filters history against its own boundary; snapshots from before that limit's window began are discarded for that limit only. Projected exhaustion = time at which the fitted slope crosses 100 %. Displayed as "runs out ~Wed 18:00" if before that limit's reset, else "lasts past reset". Fallback when fewer than 3 in-window snapshots: linear rate from window start (usage % ÷ elapsed time).

## UI

Two columns: Claude (left), Codex (right). Per limit, a paired horizontal bar: time-elapsed bar above usage bar, same scale, with the pace badge, "resets in 3d 12h (Thu 09:00 local)" countdown, and the burn-rate verdict. Below each column: a sparkline of the current window's usage curve from history. Stale columns render greyed out with the banner matching the error category and a "data from N min/h ago" stamp. Footer: "last updated N min ago". The page re-requests `/api/usage` every 5 minutes (see *Refresh model*). Colors follow `prefers-color-scheme`.

## History file

`history.jsonl`, one line per completed combined poll:

```json
{"ts": "2026-07-12T17:40:00Z", "claude": {"weekly_all": {"pct": 32, "resets_at": "..."}, "weekly_scoped": {"pct": 46, "resets_at": "..."}}, "codex": {"weekly": {"pct": 28, "reset_at": 1784359050}, "models": {"GPT-5.3-Codex-Spark": {"pct": 0, "reset_at": 1784479880}}}}
```

A failed fetch for one service records `null` for that service (the other's data still lands in the same line). On startup, lines older than 60 days are pruned; unparseable lines are skipped when reading and removed during the prune rewrite. `history.jsonl` is gitignored.

## Deployment (launchd)

Tracked, reproducible artifacts in the repo:

- `launchd/com.kamil.usage-dashboard.plist.template` — the agent definition with a `__PROJECT_DIR__` placeholder; `RunAtLoad` + `KeepAlive`; `StandardOutPath`/`StandardErrorPath` pointing into `~/Library/Logs/usage-dashboard/`.
- `install.sh` — idempotent; run from the project root:
  1. `mkdir -p "$HOME/Library/Logs/usage-dashboard"`
  2. Render the template: substitute `__PROJECT_DIR__` with the absolute project path (`$(pwd)`) and `$HOME` where needed, writing `$HOME/Library/LaunchAgents/com.kamil.usage-dashboard.plist`.
  3. `launchctl bootout "gui/$(id -u)/com.kamil.usage-dashboard" 2>/dev/null || true` (clean reinstall)
  4. `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.kamil.usage-dashboard.plist"`
- `uninstall.sh` — `launchctl bootout "gui/$(id -u)/com.kamil.usage-dashboard"`, then removes the generated plist. Logs and `history.jsonl` are left in place.

The **generated** plist (which contains user-specific absolute paths) is never committed — only the template and scripts are tracked. All paths inside the rendered plist are absolute (python3 interpreter, `dashboard.py`, working directory, log files); launchd agents get no shell environment, so nothing may rely on `PATH` or `~` expansion.

## Error handling

- **Stale/expired token** (HTTP 401/403, missing credential) → `error.category = "auth"`; column renders last-known data greyed out with "Claude token stale — open Claude Code once" / "Codex token stale — run codex once". The other service is fetched, rendered, and recorded normally.
- **Network / 5xx errors** → `error.category = "network"`; keep last snapshot, show its age; retry at next poll. No backoff logic beyond the 20-minute cadence.
- **Unexpected payload shape** → `error.category = "parse"`; treated like a network error in the UI.
- No exception may kill the server: the poll loop and request handlers wrap work in try/except and log to stderr (captured by launchd into `~/Library/Logs/usage-dashboard/`). Log lines never contain tokens.

## Testing

Pure functions — payload parsing (both vendors), window/elapsed math, pace badge, per-limit history selection, projection slope — unit-tested in `test_dashboard.py` against the real payload shapes captured 2026-07-12 (sanitized fixtures, no tokens).

## Acceptance criteria

The implementation is done when all of the following hold:

1. **Tests:** `python3 test_dashboard.py` passes (parsing, window math, pace badge, per-limit reset-boundary history selection, projection, single-flight/append contract where testable without network).
2. **Loopback reachability:** `curl -s http://127.0.0.1:8787/api/usage` returns the documented JSON shape, and the server is **not** reachable on any non-loopback interface (`lsof`/`netstat` shows the listener bound to `127.0.0.1` only).
3. **Live-source comparison:** weekly percentages shown for Claude and Codex match `/usage` in Claude Code and `codex` status (or the vendor web pages) within ±2 points at the time of comparison.
4. **History persistence:** after ≥2 poll cycles, `history.jsonl` contains one complete, parseable JSON line per completed combined poll; after killing and restarting the server, sparkline/projection still use the pre-restart history.
5. **Degraded one-service behavior:** with one credential made unavailable (e.g. `auth.json` temporarily renamed in a test run), that column shows stale/never state with the correct error category while the other service continues to fetch, render, and append normally.
6. **launchd lifecycle:** `install.sh` loads the agent and the dashboard is reachable after it runs; `kill` of the process results in launchd restarting it (reachable again without manual action); `uninstall.sh` stops it and removes the generated plist.
7. **No credential leakage:** tokens appear nowhere in `history.jsonl`, server logs, `/api/usage` responses, or committed files (verified by grepping logs/history/repo for token substrings after a run).

## Amendment 2026-07-12: Cursor column

User-approved third column for Cursor Pro included usage.

- **Credential:** Cursor app state DB `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (SQLite, opened strictly read-only via URI `mode=ro`), key `cursorAuth/accessToken` (raw WorkOS JWT). The user id is the `sub` claim's last `|`-segment. DB unreadable/locked/missing key → auth error.
- **Endpoint:** `POST https://cursor.com/api/dashboard/get-current-period-usage` (body `{}`) with cookie `WorkosCursorSessionToken=<uid>%3A%3A<jwt>`. Verified live 2026-07-12.
- **Fields:** `billingCycleStart`/`billingCycleEnd` (epoch **ms**) define the window (monthly, not weekly — existing per-limit window math handles it); usage % = `planUsage.totalSpend / planUsage.limit × 100` (cents), which matches the dashboard's "You've used N% of your included usage" message. `planUsage.totalPercentUsed` is NOT used (different denominator). `limit ≤ 0` or non-positive window → parse error.
- **Integration:** third service `cursor` everywhere (state, refresh, history snapshots, API payload, UI card, banners: "Token stale — open Cursor once"). Single limit labeled "Monthly - included usage". Old history lines without a `cursor` key are naturally skipped by the per-limit selector.
- All existing contracts (loopback, single-flight, exactly-once append, per-service degradation, no credential leakage) apply unchanged to the third service.

## Risks

- **Unofficial endpoints.** Both APIs are the vendors' internal CLI endpoints and can change shape without notice. Mitigation: defensive parsing, stale-data banners instead of crashes, fixtures make breakage obvious in tests.
- **Token expiry when a CLI is unused for long periods** — accepted; the banner tells the user the one-step fix.
