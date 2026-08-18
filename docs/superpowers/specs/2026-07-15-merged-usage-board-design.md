# Merged usage board (`/`) — design

**Date:** 2026-07-15
**Status:** approved (spec-correction pass applied), not yet implemented
**Touches:** `dashboard.py` (parser, `limit_paths`, `api_payload`, the `/` HTML
template + its `render()` JS) and `test_dashboard.py` (new parser/path/payload
assertions).

## Purpose

Replace the three separate service cards on `/` (Claude, Codex, Cursor) with a
single board that shows every usage limit together, grouped by window length and
anchored to a real date axis within each group. One glance answers "what's
burning too fast" and "when does each reset".


## Why grouped-by-cadence, not one axis

The limits span wildly different window lengths: Claude and Codex rolling **5 h**,
weekly **7 d**, Cursor monthly **~30 d**. On a single shared date axis a 5-hour
window is an invisible sliver next to a 30-day one. So the board groups limits by
window length and gives **each group its own date axis**. Within a group all
windows are the same length, so a shared axis is honest and offset windows (e.g.
Claude's week resets Sat, Codex's Thu) legitimately start at different x-positions
— which was the whole point.

Cross-group position is *not* comparable (a pixel in Weekly ≠ a pixel in
Monthly). That is inherent to grouping and accepted.

## Exposing the rolling windows (parser change — prerequisite)

The live Claude response and fixture contain a `group: "session"`, `kind:
"session"` 5-hour limit, but `parse_claude` previously discarded every non-weekly
entry. The board also needs exactly one account-level Codex 5-hour lane when that
optional window is present. `parse_codex` previously kept only the 604800 s
weekly window (via `_pick_weekly_window`) plus per-model weekly windows; the
account-level `primary_window` (5 h / `18000` s, present in
`fixtures/codex_usage.json`) is dropped, and `limit_paths` (`dashboard.py:749`)
never emits it.

**This redesign supersedes the "5-hour session limits — out of scope" rule** in
`2026-07-12-usage-dashboard-design.md:17` for Claude's session limit and Codex's
single **account-level** rolling window. Per-model Codex rolling windows remain
out of scope; we must not duplicate one rolling lane per model.

Minimal changes:

1. **`parse_claude`:** retain the optional `session` entry as
   `{"pct": ..., "resets_at": ..., "window_seconds": 18000}` and emit it first from
   `limit_paths(service="claude")`. Its absence must not affect the required
   weekly limit.
2. **Add `_pick_rolling_window(rate_limit)`** — mirrors `_pick_weekly_window`'s
   "identify by `limit_window_seconds`, never by slot" discipline (slots churn
   within a day — see `_pick_weekly_window` doc and the Codex-usage memory).
   Scan only the account `rate_limit`'s `primary_window`/`secondary_window`,
   return the shortest window whose `limit_window_seconds` is **present and
   positive** and `< 21600` (< 6 h), else `None`. A missing or non-positive
   duration is not a rolling window and is ignored; a malformed **nonnumeric**
   duration still raises and surfaces as a parse error at the trust boundary. Do
   **not** scan `additional_rate_limits` (those are per-model).
3. **`parse_codex`:** after obtaining `weekly`, add
   `roll = _pick_rolling_window(payload["rate_limit"])`; if `roll` is not `None`,
   set `out["rolling"] = _codex_window(roll)`. The rolling window is **optional**:
   its absence must not raise (weekly stays the only required window). Resulting
   data shape: `{"rolling": {...}?, "weekly": {...}, "models": {...}}`.
4. **`limit_paths(service="codex")`:** prepend `("rolling", ["rolling"])` when
   `"rolling" in data`, before weekly and the per-model paths.

No `get_limit` change. No history-file schema change: `select_window_points`
resolves the new `["rolling"]` path against snapshots automatically; older
snapshots simply lack it (no rolling history until new snapshots accrue, which is
fine — the sparkline is dropped anyway). `api_payload` iterates `limit_paths`, so
the rolling lane automatically gains a `derived` entry (`pct`, `elapsed_pct`,
`pace`, `reset_epoch`, `projection`, and the new `window_seconds` below).

## Layout

One `.card` on `/`, containing up to three cadence groups in fixed order:
**Rolling → Weekly → Monthly**. A group renders only if it has ≥1 limit.

Bucket by `window_seconds`:

| Bucket  | Condition                        | Members              |
|---------|----------------------------------|----------------------|
| Rolling | `< 2 days`   (`< 172800`)        | Claude + Codex 5 h   |
| Weekly  | `< 20 days`  (`< 1728000`)       | Claude ×2, Codex 7 d |
| Monthly | otherwise                        | Cursor cycle         |

Thresholds are deliberately loose so a nearby cadence (e.g. a 14-day window) lands
in the closest sensible bucket. Revisit only if a genuinely new cadence appears.

### Group anatomy

- **Header:** cadence name + a hint (`Weekly · 7-day windows`).
- **Date axis row:** left-edge label, right-edge label, and a `today`/`now`
  marker at the now-position. Shown even for single-window groups, for reset-date
  context and visual consistency. Label formats:
  - **Rolling:** relative times computed from the axis, e.g. left `3h ago`,
    marker `now`, right `in 2h` (hours/minutes relative to `Date.now()`).
  - **Weekly:** local weekday via `toLocaleDateString(undefined,{weekday:"short"})`
    (e.g. `Thu` … `Sat`), marker `today`.
  - **Monthly:** local date via `toLocaleDateString(undefined,{month:"short",day:"numeric"})`
    (e.g. `Jul 1` … `Jul 31`), marker `today`.
- **Lanes:** one per limit, sorted **worst pace first** (over → on → under),
  tiebreak soonest reset.

### Lane anatomy

Three columns (wide screens): `label | axis-area | meta`.

- **label:** service (small, uppercase) + limit name + a **visible pace token**
  (emoji + word: `🟢 under` / `🟡 on` / `🔴 over`) so pace is never conveyed by
  fill color alone. Plus a `stale <age>` chip when the service is not fresh.
- **axis-area:** spans the group's full date range. Inside it:
  - the **window bar** positioned by date (math below), grey background;
  - a **fill** inside the bar, width = `pct` (quota used), colored by `pace`,
    with the `pct` number at its right;
  - a **now line** (vertical, 2 px, foreground color) at the group now-position.
    All lanes in a group share the same now-position, so the lines align into one
    continuous vertical. The now line is decorative (`aria-hidden`); its meaning
    is carried in the progressbar label.
  - Read: **fill reaching past the now line = over pace.**
- **meta:** reset countdown (`2d · Sat`) + projection line (`runs out ~Fri` or
  `lasts past reset`). Kept as text because projection is not readable from
  geometry.

### Accessibility

- The window bar carries `role="progressbar"`, `aria-valuemin="0"`,
  `aria-valuemax="100"`, `aria-valuenow="<pct>"`, and an `aria-label` that states
  the numbers and the pace in words, e.g. `"Claude Weekly · Opus — 78% used, over
  pace, 64% of window elapsed"`. Pace and elapsed are therefore available to
  screen readers and not color-dependent.
- The visible pace token (above) covers sighted colorblind users.

### Position math (per group, client-side)

For each limit: `window_start = reset_epoch − window_seconds`.

```
axis_start = min(window_start) over the group's limits
axis_end   = max(reset_epoch)  over the group's limits
span       = axis_end − axis_start
left%   = clamp((window_start − axis_start) / span * 100, 0, 100)
width%  = window_seconds / span * 100
now%    = clamp((now − axis_start) / span * 100, 0, 100)
fill%   = clamp(pct, 0, 100)          # relative to the bar, not the axis
```

Single-window group ⇒ `left=0, width=100, now%=elapsed_pct`, i.e. it fills the
axis (nothing to offset against). `now` is the browser clock; `axis_end`/reset
dates come from `reset_epoch`.

## Staleness & errors (preserved — trust boundary)

Behavior must stay truthful and mirror the existing `banner()` categories
(`dashboard.py:490`). Per service, from the payload (`status`, `error`,
`fetched_at`, `server_time`):

- **Stale but has data** (`status != "fresh"`): its lanes still render with a
  `stale <age>` chip on the label (`<age>` from the existing `ageText()`). Lane
  and meta **text stay full-opacity and readable** — do **not** dim whole-lane
  text. Staleness is signaled by the chip alone (optionally a muted window-border
  treatment); the pace fill color must remain distinguishable.
- **Errored** (`error` present): one muted line at the **top of the card** per
  errored service, message chosen by category:
  - `auth` → the service-specific fix hint from `STALE_FIX`
    (`open Claude Code once` / `run codex once` / `open Cursor once`).
  - `network` / `parse` (or other) → a generic
    `Can't reach <service> (<category>)` message. **Never** the credential hint
    for a non-auth error.
- **No data at all** (`data` null): the service has no windows to place, so it
  appears as one muted line at the **bottom of the card**. Its text is
  **category-aware**, reusing the same rule as above (auth → fix hint; otherwise
  `<service> — no data yet (<category>)`). It must **not** unconditionally blame
  credentials.

## Backend changes (summary)

1. `parse_claude`, `_pick_rolling_window`, `parse_codex`, and `limit_paths` as in
   the parser section.
2. In `api_payload`, add to each `derived[service][label]` entry:
   `"window_seconds": window_seconds_of(limit)` (`window_seconds_of` already
   exists at `dashboard.py:46`).

**Pace and projection stay server-computed** (already tested); the new JS is
layout-only.

## Removed

- The per-limit **sparkline** (`spark()` and its calls) is dropped from the board.
- History recording and the `history` field in the payload are **left as-is**
  (out of scope to remove; harmless if unused).

## Markup & CSS (self-contained)

Replace `<main class="grid">` + its three `<section>` cards with a single
`<div id="board">` that `render()` fills. Rewrite `render()` to build the grouped
board from `data.derived` (+ `window_seconds`) and per-service `status`/`error`.

CSS structure to implement (a throwaway brainstorming mockup was used only as
visual inspiration and is **not a required artifact**; this section is sufficient
to build from):

- `#board .group` — a cadence group; `.group-h` header row (flex, space-between).
- `.axisrow` and `.lane` share the wide-screen grid `140px 1fr 120px` (gap ~14px).
- `.axis` — `position:relative`; tick labels absolutely positioned by percent
  (`left`, `translateX(-50%)`); `today`/`now` marker likewise.
- `.area` — `position:relative`, the group-width axis space.
- `.win` — `position:absolute`, `left`/`width` in axis-%, grey background,
  `overflow:hidden`, `role="progressbar"` + aria attrs.
- `.win .fill` — `position:absolute; left:0`, `width` = `fill%`, background by
  pace class (`.under`/`.on`/`.over`, matching the existing `--under/--on/--over`
  CSS vars).
- `.area .nowl` — `position:absolute`, `left` = `now%`, 2 px, foreground color,
  `aria-hidden`.
- `.stale` chip and pace token as small inline spans in the label cell.

### Responsive (~390 px)

The wide-screen `140px + 1fr + 120px` grid collapses on phones. At
`@media (max-width: 420px)`, restack each `.lane` (and the `.axisrow`) to a single
column:

1. label row (service · name · pace token · stale chip),
2. full-width `.area` (bar + now line keep working unchanged — they are
   percent-based),
3. meta row (countdown · projection), aligned left.

Set `grid-template-columns: 1fr` on `.lane`/`.axisrow` in the media query and let
the three cells wrap to rows. The top-of-card error lines and bottom no-data line
are already full-width and need no change.

## Testing (`test_dashboard.py` additions)

Parser / path / payload — matching the existing fixture-driven style:

1. **`parse_claude` extracts its optional session:** on `claude_usage.json`,
   `out["session"]` carries `pct`, `resets_at`, and `window_seconds == 18000`;
   removing that entry leaves weekly parsing unchanged.
2. **`parse_codex` extracts one rolling window:** on `codex_usage.json`,
   `out["rolling"] == {"pct": 0.0, "reset_at": 1783893080.0,
   "window_seconds": 18000.0}`; `out["weekly"]` unchanged (still 604800); no
   `models` entry gains a rolling window.
3. **Rolling identified regardless of slot:** move the 18000 window into
   `secondary_window` (weekly into `primary_window`) → rolling still found.
4. **Rolling is optional:** a payload whose account slots contain no sub-6 h
   window → `parse_codex` succeeds with no `"rolling"` key (weekly still
   required).
5. **Empty account slot ignored:** a slot dict with no `limit_window_seconds` is
   not a rolling window and is ignored (no KeyError); `parse_codex` still returns
   `weekly` without `rolling`.
6. **`limit_paths`** includes Claude `session` and Codex `rolling` when present.
7. **`api_payload`** puts `window_seconds` on every derived entry equal to
   `window_seconds_of(limit)`; specifically
   both Claude `session` and Codex `rolling` have `window_seconds == 18000` in
   fixture-backed tests.

JS layout math is verified visually; not automated. *ponytail: no JS test harness
in this repo; the layout math is presentational (a positioning bug is visually
obvious, not a silent data error). Upgrade path: extract `bucketOf()` / `layout()`
into a module + add a node test runner if the board grows.*

## Out of scope

- Removing history/sparkline backend.
- **Per-model** Codex rolling windows (only the account-level rolling lane is in
  scope; see parser section).
- Any change to fetching, or the `/api/usage` shape beyond the added
  `window_seconds` field and the Claude `session` / Codex `rolling` paths.
- Cross-group comparison or a global single axis.
