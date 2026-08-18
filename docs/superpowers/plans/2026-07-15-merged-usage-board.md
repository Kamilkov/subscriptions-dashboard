# Merged Usage Board (`/`) Implementation Plan

Executed directly by the coder in this Herdr pane, task-by-task. Steps use
checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three per-service cards on `/` with one board grouping every
usage limit by window length (Rolling / Weekly / Monthly), calendar-anchored
within each group, and expose the discarded Codex account-level 5-hour rolling
window as exactly one lane.

**Architecture:** Pure server-side data changes in `dashboard.py` (one new picker,
two touched functions, one added `derived` field); the rest is a rewrite of the
`HTML_PAGE` template's CSS + `render()` JS. No new files, no module extraction, no
JS framework, no dependency. Pace/projection stay server-computed and already
tested; new JS is layout-only.

**Tech Stack:** Python 3.9+, stdlib only, `unittest`. No pip/npm. Tests:
`python3 test_dashboard.py -v`.

**Spec:** `docs/superpowers/specs/2026-07-15-merged-usage-board-design.md`

## File Structure

| File | Change |
|---|---|
| `dashboard.py` *(modify)* | `_pick_rolling_window` (new), `parse_codex`, `limit_paths`, `api_payload`, and the `HTML_PAGE` CSS/body/`render()` block. Nothing else (Handler, make_server, main, fetch/* untouched). |
| `test_dashboard.py` *(modify)* | New parser/path/payload tests; updated `TestHtmlPage` needles. |
| `docs/superpowers/plans/2026-07-15-merged-usage-board.md` *(this)* | — |
| `docs/superpowers/specs/2026-07-15-merged-usage-board-design.md` | already corrected; not edited here |

Nothing else in the repo is touched. No `launchd/`, `install.sh`, `README.md`,
or fixture changes.

## Global Constraints

- **Stdlib only; one-file/`dashboard.py` pattern.** Flat pure functions, module
  constants, `FetchError(category, detail)` for degradation, no classes beyond
  `Handler`. Match existing style.
- **No JS framework, no module extraction, no build step, no speculative
  abstraction.** New JS helpers are plain functions inside the existing
  `HTML_PAGE` string.
- **Rolling window is account-level only** — never per-model; never duplicated.
  Its absence must not raise.
- **Truthful trust states** — auth→service fix hint, network/parse→generic
  category message, no-data→category-aware (never unconditionally blame
  credentials).
- **Stale ≠ dimmed text.** Signal staleness with the chip (and/or border color)
  only. `TestHtmlPage` already forbids any `opacity:.`/`opacity: .`/`opacity:0.`
  substring in the page — the rewrite MUST keep that assertion green (do not use
  `opacity` for the stale treatment).
- Never render/log tokens; `"Bearer"` must not appear in the page.

---

## Task 1 — Failing parser/path/payload tests (TDD, write first)

Add to `test_dashboard.py`. All should FAIL before Task 2.

- [ ] **`test_parse_codex_extracts_rolling`** — `parse_codex(load_fixture("codex_usage.json"))["rolling"] == {"pct": 0.0, "reset_at": 1783893080.0, "window_seconds": 18000.0}`; assert `out["weekly"]["window_seconds"] == 604800.0` unchanged; assert no `models` entry has `window_seconds == 18000`.
- [ ] **`test_parse_codex_rolling_regardless_of_slot`** — deep-copy fixture, swap the 18000 window into `rate_limit["secondary_window"]` and the 604800 into `primary_window`; assert `out["rolling"]["window_seconds"] == 18000.0` and `out["weekly"]["window_seconds"] == 604800.0`.
- [ ] **`test_parse_codex_rolling_optional`** — remove/replace both account slots so no sub-6h window remains (keep a 604800 weekly present); assert `parse_codex(...)` succeeds and `"rolling" not in out`.
- [ ] **`test_limit_paths_codex_includes_rolling`** — for codex data containing `"rolling"`, `limit_paths("codex", data)[0] == ("rolling", ["rolling"])`; for data without it, no rolling path appears.
- [ ] **`test_derived_has_window_seconds`** — build an `api_payload()` (reuse the `TestMainOnce`/fixture mocking pattern) and assert every `derived[svc][label]` has `"window_seconds"` equal to `window_seconds_of(get_limit(...))`.
- [ ] **`test_codex_rolling_derived_window_seconds`** — in that payload, `derived["codex"]["rolling"]["window_seconds"] == 18000` and it is the only limit across all services with `window_seconds < 21600`.
- [ ] Run `python3 test_dashboard.py -v` → the six new tests fail, existing pass.

## Task 2 — Rolling parser + `window_seconds` (minimal impl)

Edit `dashboard.py`:

- [ ] **`_pick_rolling_window(rate_limit)`** — new function beside `_pick_weekly_window` (~`:847`). Scan only `rate_limit["primary_window"]` / `["secondary_window"]` (dict-guarded like `_pick_weekly_window`); return the window with the smallest `limit_window_seconds` that is `< 21600` (< 6h), else `None`. Do not scan `additional_rate_limits`.
- [ ] **`parse_codex`** (`:849`) — after `weekly` is resolved, add `roll = _pick_rolling_window(payload["rate_limit"])`; `if roll is not None: out["rolling"] = _codex_window(roll)`. Do not raise when `roll is None`. Weekly stays the only required window.
- [ ] **`limit_paths`** (`:749`, codex branch `:756`) — prepend `("rolling", ["rolling"])` when `"rolling" in data`, before weekly and per-model paths.
- [ ] **`api_payload`** (`:348`) — add `"window_seconds": window_seconds_of(limit),` to the `derived[service][label]` dict (`window_seconds_of` exists `:46`).
- [ ] Run `python3 test_dashboard.py -v` → all Task-1 tests pass; no regressions.

## Task 3 — `HTML_PAGE` CSS / body / `render()` rewrite

All within the `HTML_PAGE` string (`:375`–`:539`). Keep `:root` vars + dark
scheme + `--under/--on/--over`. Keep helpers `esc, fmtWhen, fmtReset, ageText,
verdict`. Keep `PACE`. Reuse existing `LABELS` strings (`weekly_scoped` →
"Weekly - Opus and above", cursor `monthly` → "Monthly - included usage") and add
codex `rolling` → "Rolling" to minimize churn.

- [ ] **CSS** — replace the `.grid`/`.card`/`.card.stale`/`.card h2`/`.limit`/`.bar*` rules with: `#board`, `.group`, `.group-h`, `.axisrow`, `.axis`/`.axis .tick`/`.axis .today`, `.lane`, `.lab`/`.chip`/pace-token, `.area`, `.win`+aria, `.win .fill.under/.on/.over`, `.area .nowl`, top-of-card `.errline`, bottom `.unavail`. Wide grid `140px 1fr 120px`. **No `opacity` anywhere.**
- [ ] **Responsive** — `@media (max-width: 420px)`: set `.lane`/`.axisrow` `grid-template-columns: 1fr` so cells restack to (label row) / (full-width `.area`) / (meta row). Percent-based `.win`/`.nowl` need no change.
- [ ] **Body** — replace `<main class="grid">…</main>` (`:425`–`:435`) with `<div id="board"></div>`. Keep the `<footer aria-live="polite">` and nav link.
- [ ] **JS remove** `bar()` (`:469`) and `spark()` (`:476`).
- [ ] **JS add** pure helpers: `bucketOf(windowSeconds)` (→ `"rolling"|"weekly"|"monthly"` at `172800`/`1728000` thresholds); `groupLayout(limits, now)` (computes `axis_start=min(reset-window)`, `axis_end=max(reset)`, and per-limit `left%/width%/now%/fill%` per spec math, clamped 0–100; single-window ⇒ `left=0,width=100,now%=elapsed_pct`); `axisLabels(bucket, axisStart, axisEnd, now)` (Rolling→relative `Xh ago`/`now`/`in Xh`; Weekly→`toLocaleDateString(weekday:"short")`+`today`; Monthly→`toLocaleDateString(month:"short",day:"numeric")`+`today`); `paceToken(pace)` (visible `🟢 under`/`🟡 on`/`🔴 over`); `errorLine(svc, err)` (auth→`STALE_FIX[svc]`, else `Can't reach <svc> (<category>)`).
- [ ] **Rewrite `render(data)`** — for each service build limit objects from `data.derived[svc]` (+ `window_seconds`, `pace`, `pct`, `elapsed_pct`, `reset_epoch`, `projection`) tagged with `status`/`error`; collect top-of-card error lines (services with `error`); collect bottom `unavail` lines (services with `data == null`, category-aware text); bucket remaining limits; render groups in fixed order Rolling→Weekly→Monthly, each group only if non-empty; within a group sort **worst pace first** (`over>on>under`, tiebreak soonest `reset_epoch`); render axis row + lanes. Each `.win` carries `role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="<pct>"` and an `aria-label` stating pct + pace word + elapsed%. `.nowl` is `aria-hidden`. Stale service ⇒ `stale <age>` chip via `ageText(data.server_time, st.fetched_at)`; text stays full opacity.
- [ ] Manually load the page logic mentally against the spec's worked example; no console errors expected (verified for real in Task 7).

## Task 4 — Update existing HTML assertions

Edit `TestHtmlPage.test_page_has_required_elements` (`:794`):

- [ ] **Remove** obsolete needles: `'max-width: 700px'`, `'stale-chip'`, `'id="cursor"'`, `'data as of '`, `'page refreshed '` (drop any that no longer appear after the rewrite).
- [ ] **Add** needles: `'id="board"'`, `'max-width: 420px'`, `'aria-valuenow'`, `'aria-hidden'`, a pace-token substring (e.g. `'under'`), and an error-copy substring proving category-truthfulness (e.g. `"Can't reach"`).
- [ ] **Keep** unchanged: `'<!DOCTYPE html>'`, `'lang="en"'`, `'viewport'`, `'prefers-color-scheme: dark'`, `'role="progressbar"'`, `'aria-live="polite"'`, `'/api/usage'`, `'5 * 60 * 1000'`, `'grid-template-columns'` (board still uses it), the two retained `LABELS` strings, `assertNotIn("Bearer")`, and **all three `opacity` absence assertions**.

## Task 5 — Focused test run

- [ ] `python3 test_dashboard.py -v` → `OK`, all new + updated tests green.

## Task 6 — Full warning-clean suite + diff checks

- [ ] `python3 -W error -c "import dashboard"` → no import-time warning.
- [ ] `python3 -W error test_dashboard.py -v` → `OK`.
- [ ] `git diff --stat` → only `dashboard.py`, `test_dashboard.py` (+ these docs). No other files.
- [ ] `git diff` review → no debug prints, no tokens, no `scratchpad` path references, no `opacity` in `HTML_PAGE`.

## Task 7 — candidate preflight + launchd restart + runtime verification

**Preflight on an alternate loopback port first** (proves the new code serves
before touching the installed agent; leaves the live 8787 agent running):

- [ ] Start the candidate foreground on a spare port: `python3 dashboard.py --port 8788` (background it or use a second shell). Confirm it logs `serving on http://127.0.0.1:8788`.
- [ ] Endpoint/API checks against `:8788`: `curl -sf http://127.0.0.1:8788/ >/dev/null`; `curl -s http://127.0.0.1:8788/api/usage | python3 -c "import sys,json; d=json.load(sys.stdin)['derived']; roll=[(s,l) for s,ls in d.items() for l,v in ls.items() if v.get('window_seconds',0)<21600]; assert roll==[('codex','rolling')], roll; print('ok', roll)"`.
- [ ] **Stop the candidate cleanly** — SIGINT/SIGTERM the foreground process (Ctrl-C or `kill` its pid); confirm port 8788 is released (`lsof -nP -iTCP:8788 -sTCP:LISTEN` → empty). Only then restart the installed agent below.

Restart the installed agent to pick up the new `dashboard.py`:

- [ ] `launchctl kickstart -k gui/$(id -u)/com.kamil.usage-dashboard`
- [ ] `launchctl print gui/$(id -u)/com.kamil.usage-dashboard | grep -E "state|pid"` → running with a fresh pid.
- [ ] **Loopback listener** — `lsof -nP -iTCP:8787 -sTCP:LISTEN` → bound to `127.0.0.1:8787` only (never `*`/`0.0.0.0`).
- [ ] **GET headers** — `curl -sD - -o /dev/null http://127.0.0.1:8787/` (and `/api/usage`) → `200`, `Content-Type` correct, `Content-Length` present, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`.
- [ ] **Live `/api/usage` shape / exactly one rolling** —
  `curl -s http://127.0.0.1:8787/api/usage | python3 -c "import sys,json; d=json.load(sys.stdin)['derived']; roll=[(s,l) for s,ls in d.items() for l,v in ls.items() if v.get('window_seconds',0)<21600]; assert roll==[('codex','rolling')], roll; print('ok', roll)"`
  (also spot-check `derived['codex']['rolling']['window_seconds']==18000`).
- [ ] **Browser, live fresh** — open `http://127.0.0.1:8787/`, DevTools console clean (no errors/warnings); board shows Rolling/Weekly/Monthly groups, one Codex rolling lane, now-line, pace tokens; screenshot at desktop width and at ~390px (device toolbar) confirming the 420px restack.
- [ ] **Synthetic trust states without real credentials** — in the console, call the global `render(payload)` with hand-built payloads mirroring `api_payload()` shape (`{claude,codex,cursor:{status,error,fetched_at,data}, derived, history, server_time}`). **One desktop screenshot per state** (the live fresh state already proved the ~390px restack; repeat a synthetic state at ~390px only if the shared mobile structure reveals a state-specific problem — no full screenshot matrix):
  - **stale** — a service with `status:"stale"`, real-looking `derived`, older `fetched_at` → `stale <age>` chip, text readable, no fade.
  - **auth** — `error:{category:"auth"}` → service-specific `STALE_FIX` line at top of card.
  - **network** — `error:{category:"network"}` → generic `Can't reach … (network)` line, NOT a credential hint.
  - **no-data** — `data:null`, no error → bottom `… no data yet` line; with `error.category:"auth"` → fix hint instead. Never unconditionally blames credentials.
  (No real token is read; `render()` is driven directly with synthetic objects.)

## Task 8 — Recovery (if Task 7 restart or health check fails) — preserve the diff

The uncommitted working-tree changes are the deliverable; **never** discard them.
No `git stash`, `git checkout`, `git restore`, or any worktree replacement.

- [ ] Inspect `~/Library/Logs/usage-dashboard/err.log` for the traceback (KeepAlive=true ⇒ a crashing process crash-loops; act promptly).
- [ ] **Separate code from launchd registration** — run the current (edited) code foreground on the alternate port: `python3 dashboard.py --port 8788`, then `curl -sf http://127.0.0.1:8788/api/usage >/dev/null`.
  - **Serves cleanly on 8788** ⇒ the code is fine; the fault is launchd registration/path. Stop the 8788 process, then rerun the idempotent installer: `./install.sh` (it re-pins the interpreter and does `bootout` + `bootstrap`). Re-verify health on 8787.
  - **Fails on 8788 too** ⇒ the fault is in the diff. Read the traceback, **patch the root cause in place** (keep all other edits), rerun Tasks 5–6, then kickstart 8787 again.
- [ ] Confirm `curl -sf http://127.0.0.1:8787/api/usage >/dev/null` before finishing. Never leave the agent in a crash loop.

---

## Done when

All tasks checked: six new tests + updated HTML assertions green under `-W error`;
diff limited to `dashboard.py` + `test_dashboard.py` (+ docs); live board serves
one Codex rolling lane with correct headers on the loopback;
console clean; live-fresh screenshots at desktop and ~390px, and one desktop
screenshot per synthetic stale/auth/network/no-data state (a ~390px repeat only
if a state-specific mobile problem appears); agent running on a fresh pid.
