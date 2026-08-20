# Red-Team Corrections (2026-08-20) — Executable Plan

**Goal:** Implement all ten accepted corrections from the 2026-08-20 adversarial review.
**Repo:** `/Users/kamilkovac/Code/Working/websites/subscriptions-dashboard`. Web (`dashboard.py`, tested by `test_dashboard.py`, stdlib `unittest` — no pytest) is source of truth; the macOS app (`macos/UsageBar/`, tested by `macos/UsageBarTests/`) mirrors every behavioral change unless platform-specific.
**Commands:**
- Python: `python3 -m unittest test_dashboard -v` (single: `python3 -m unittest test_dashboard.<Class>.<test> -v`)
- Swift: `cd macos && xcodegen generate && xcodebuild -project UsageBar.xcodeproj -scheme UsageBar -destination 'platform=macOS' test`

**Constraints:** shortest working diff; no new dependencies; committing/pushing/releasing is out of scope (separate gate). Never run `macos/scripts/release.sh`, touch `macos/dist/`, create tags, or query remotes — the published v1.0.18 is read-only context. Never give the board window `.fullScreenPrimary`.

Each task: one failing check → implementation → verification.

---

## Task 1 — Refuse HTTP redirects (credential forwarding), item 1

`_http_json` (dashboard.py:412-428) uses `urllib.request.urlopen`, which follows 3xx and re-sends `Authorization`/`Cookie` to the `Location` target, cross-origin included. All vendor endpoints answer 200 directly.

- **Failing check:** new `test_dashboard.TestRedirects.test_cross_origin_redirect_refused` — start two loopback `ThreadingHTTPServer`s on distinct ports (two origins); A answers 302 → `http://127.0.0.1:<portB>/steal`; B records request headers. Call `dashboard.http_get_json("http://127.0.0.1:<portA>/u", {"Authorization": "Bearer secret"})` with the default opener. Assert `FetchError` with `category == "network"`, `"302"` in detail, and B recorded zero requests. Currently fails: B receives the Authorization header.
- **Implement:** in dashboard.py above `http_get_json`, add `_NoRedirect(urllib.request.HTTPRedirectHandler)` whose `redirect_request` returns `None` (parent then raises `HTTPError(3xx)` → existing catch maps to `FetchError("network", "HTTP 302")`), and module-level `_OPENER = urllib.request.build_opener(_NoRedirect())`. Change the default `opener=` of `http_get_json` and `http_post_json` to `_OPENER.open`. The injected-opener test contract `opener(req, timeout=…)` is unchanged.
- **Verify:** new test passes; full Python suite green (existing fake-opener tests unaffected).

## Task 2 — Close the test HTTPError leak, item 10

- **Failing check:** `python3 -W error::ResourceWarning -m unittest test_dashboard -v` surfaces the unclosed 404 body from `test_post_unknown_path_404` (test_dashboard.py:1071-1073) — the only caught-HTTPError site without a close.
- **Implement:** add `cm.exception.close()` after the 404 assertion, matching the three sibling tests.
- **Verify:** the `-W error::ResourceWarning` run is fully green.

## Task 3 — Reject finite-but-absurd numbers, raw AND derived, item 2

Swift `num()` (Core.swift:74-79) accepts finite `1e300`; `Int(pct.rounded())` then traps at render sites (Store.swift:248; BoardView.swift:471,509; UsageWidget.swift:168,195; UtilizationView.swift:49,66; Core.swift:332,335-336). Derived percentages (`(1.0 - remaining) * 1000` in `parseAntigravity`, `(100 - remaining) * 10` in `parseCopilot`) can also overflow from raw values that individually pass any raw bound.

- **Failing checks (CoreTests.swift):**
  1. `testAbsurdRawPercentRejected` — claude fixture with `weekly_all.percent = 1e300` → `parseClaude` throws (entry skipped, weekly_all missing).
  2. `testPresentButInvalidRemainingSkipsBucket` — antigravity payload, single bucket, `remainingFraction: -1e300` (rejected by raw bound) → bucket skipped, parser throws "no usable groups" — never rendered as 0% "untouched".
  3. `testDerivedPercentOverflowRejected` — antigravity bucket with `remainingFraction: -9e14` (passes raw bound; derived pct ≈ 9e17) → bucket skipped.
  4. `testMillisecondEpochsStillAccepted` — cursor fixture (`billingCycleStart` ≈ 1.8e12 ms) still parses.
- **Implement (Swift, Core.swift):** `num()` additionally requires `abs(d) < 1e15` (clears ms epochs, rejects absurdities). Add private `validPct(_ d: Double) -> Double?` (finite and `abs < 1e15`); route every *derived* percent through it at construction — `parseAntigravity` and `parseCopilot` skip the lane/bucket on nil. In `parseAntigravity`, a *present but unparseable/absurd* `remainingFraction` skips the bucket (only an *absent* key means "untouched" 1.0).
- **Implement (Python parity, dashboard.py:44-50):** `_num` raises on `f != f or abs(f) >= 1e15` (covers ±inf). New test `test_num_rejects_absurd_but_accepts_ms_epochs`: `_num(1e300)` and `_num(-1e15)` raise; `_num(1.8e12)` passes. Derived percents are validated too — an absurd derived value is absurd UI regardless of Python's big ints: reuse `_num` as the shared validator by routing the derived `pct` through it at construction in `parse_antigravity` and `parse_copilot` (e.g. `pct = _num(round((1.0 - remaining) * 1000) / 10)`); the resulting `ValueError` flows into each parser's existing except path (antigravity: whole-payload `FetchError("parse", …)`; copilot: the per-lane `continue`). New test `test_derived_percent_overflow_rejected_python`: antigravity payload with `remainingFraction: -9e14` (passes the raw `_num` bound; derived pct ≈ 9e17) → `parse_antigravity` raises `FetchError`; copilot payload with `percent_remaining: -9e14` → that lane skipped.
- **Verify:** both suites green.

## Task 4 — Queue refreshes that arrive during an in-flight poll, item 5

`Store.refresh` (Store.swift:145-189) drops any request while `polling` — a provider enabled mid-poll waits up to 20 min; a full refresh during a partial (`only:`) poll is also silently lost.

- **Failing checks:** new `macos/UsageBarTests/StoreTests.swift` (`@MainActor`), deterministic via continuation-gated injected fetchers and an actor-based call counter:
  1. `testEnableDuringFullPollQueuesMissingProvider` — enabled `{claude}`; start `refresh(force:true)` and hold the claude fetcher on a gate; enable codex, call `refresh(only: ["codex"])`, then `refresh(only: ["claude"])`; release gate. Assert codex fetched exactly once (queued, drained after poll) and claude exactly once (in flight → no duplicate).
  2. `testFullRefreshDuringPartialPollFetchesRest` — enabled `{claude, codex}`; start `refresh(only: ["claude"])` gated; call `refresh(force: true)` mid-flight; release. Assert codex fetched exactly once and claude exactly once.
- **Implement (Store.swift):** add `private var inFlight: Set<String>` and `private var pendingOnly: Set<String>`. In the `polling` branch compute `let requested = only ?? enabled` and `pendingOnly.formUnion(requested.intersection(enabled).subtracting(inFlight))`, then return — so full refreshes during partial polls queue the uncovered providers. Extract the current fetch/apply body (lines 152-188) into `private func performPoll(wanted:only:fetchers:)` which sets/clears `inFlight`; `refresh` runs it, then drains `pendingOnly` in a loop (re-entering `performPoll` with the queued set ∩ `enabled`). Add `fetchers:` parameter (default nil → real `Providers` map) and `init(startPolling: Bool = true)` (guards `pollTask` only) as the test seams; existing call sites unchanged.
- **Verify:** both new tests pass; existing suites green. (No web change: dashboard.py has no toggles; its generation sharing already covers concurrent callers.)

## Task 5 — Continuous 60-day retention, memory and disk, item 6

Both sides prune only at startup (`load_history` dashboard.py:1507-1532; `HistoryFile.load` Store.swift:295-309); long-running processes grow unbounded.

- **Failing check (Python):** `test_refresh_prunes_history_older_than_60_days` — seed `dashboard.HISTORY` and a temp `history_path` file with a snapshot 61 days old; run `refresh(force=True, now_fn=…, fetchers={one stub}, history_path=…)`; assert the old snapshot is gone from `HISTORY` **and** from the file, without any restart/reload. Currently fails (2 entries survive).
- **Implement (Python):** extract the atomic rewrite tail of `load_history` (tmp file + `replace`) into `write_history(path, snaps)`; `load_history` reuses it. In `refresh`'s `state_lock` block after `HISTORY.append(snap)`: compute cutoff `now - HISTORY_DAYS * 86400`; if the head is expired, filter `HISTORY` in place and `write_history` (compaction), else keep the cheap `append_history_line`.
- **Failing check (Swift):** `StoreTests.testRefreshPrunesHistoryOnDiskAndInMemory` — point `HistoryFile` at a temp URL (see seam below), seed the file with one 61-day-old line and seed `store.history` to match; run `refresh(force:true)` with a stub fetcher; assert `store.history` has no entry older than 60 days **and** the temp file no longer contains the old line. Must never touch the real `~/Library/Application Support/UsageBar/history.jsonl`.
- **Implement (Swift):** smallest URL seam: change `HistoryFile.url` from `static let` to `static var` initialized by the current closure; tests set it to a temp-dir URL in `setUp` and restore in `tearDown`. Extract the compaction write in `load()` into `HistoryFile.rewrite(_ snaps:)`; `load()` reuses it. In `performPoll` after `history.append(snap)`: if the head predates `ts - historyDays*86400`, `removeAll` expired and `HistoryFile.rewrite(history)`, else `HistoryFile.append(snap)`.
- **Verify:** both suites green; Python test confirms disk + memory prune in one poll.

## Task 6 — Global worst-pace-first lane order, item 4

Spec (docs/superpowers/specs/2026-07-15-merged-usage-board-design.md:104): lanes sorted **worst pace first (over → on → under), tiebreak soonest reset**, globally per cadence group. Both boards currently cluster by provider (web: dashboard.py:1070-1079 in `render()`; Swift: BoardView.swift:353-366 in `laneItems`). This knowingly reverses the v1.0.11 clustering; the once-per-provider caption logic is adjacency-based and needs no change.

- **Failing checks:**
  - Python (`TestHtmlPage.test_lanes_sorted_globally_worst_first`): `HTML_PAGE` contains the sort expression `(RANK[a.d.pace] - RANK[b.d.pace]) || (a.d.reset_epoch - b.d.reset_epoch)` and does **not** contain `worst[a.svc]`.
  - Swift (`CoreTests.testWorseLaneOrdersByPaceThenSoonestReset`): direct tests of the new comparator — over beats on beats under; equal pace → sooner reset first.
- **Implement:** add domain comparator `worseLane(_ a: (pace: Pace, reset: Double), _ b: …) -> Bool` in Core.swift (compares `(rank, reset)` — no generic abstraction). `laneItems` deletes the `worst` dictionary block and sorts with `worseLane` over each item's `(pace, limit.resetEpoch)`. Web: delete the `const worst = {}` block and replace `items.sort(…)` with the two-key comparator above; update the stale "Cluster lanes by provider" comments on both sides.
- **Verify:** both suites green.

## Task 7 — Background colour must keep 4.5:1 contrast, item 3

PRODUCT.md requires body text ≥ 4.5:1 in both themes; the v1.0.18 picker accepts any colour. **Decision: keep the feature** — one small pure WCAG rule per side; removal not proposed. Accept a background only if its WCAG 2.x contrast ratio against the theme ink (`#1c1c1e` light / `#f5f5f7` dark) is ≥ 4.5. macOS tints render at 0.55 opacity over material whose luminance also passes, so validating the raw tint is conservative.

- **Failing checks:**
  - Swift (`CoreTests.testBoardBackgroundContrastRule`): `bgContrastOK` accepts defaults `F1F1F4`(light)/`151517`(dark); rejects `000000` light, `FFFFFF` dark, `808080` in both, malformed input.
  - Swift (`StoreTests.testPersistedUnsafeBackgroundIsPurgedAtInit`): write unsafe hexes to `UserDefaults` keys `boardBgLight`/`boardBgDark`; `Store(startPolling: false)` must expose nil for both **and** remove the stored values (render sites never see them); safe stored values survive. **UserDefaults safety:** the hosted test process may share the real app's defaults domain, so `setUp` snapshots the exact pre-test values of both keys (`string(forKey:)`, capturing absence as nil) and `tearDown`/`defer` restores them exactly — set the snapshotted string back, or `removeObject(forKey:)` when the snapshot was nil. Never blanket-remove: plain cleanup can destroy the user's real settings.
  - Swift (`StoreTests.testSetBoardBgRejectsUnsafeHex`): `setBoardBg` with a failing hex is a no-op.
  - Python (extend `test_background_picker_on_both_pages`): both pages contain `function bgOK(`, the `4.5` threshold, an apply-time guard applying a stored value only when `bgOK(...)` passes (assert the guarded-apply needle), and an input-handler rejection that snaps the picker back.
- **Implement (Swift):** `bgContrastOK(_ hex: String, dark: Bool) -> Bool` in Core.swift (hex "RRGGBB"; WCAG relative luminance, ratio ≥ 4.5 vs the theme ink). `Store.setBoardBg` early-returns on a failing hex. `Store.init` sanitizes persisted values: any stored hex failing `bgContrastOK` is cleared from both the property and `UserDefaults` — covers values persisted before this rule existed. `SettingsView` caption notes the rule.
- **Implement (web, dashboard.py — both picker IIFEs, HTML_PAGE ~826 and HISTORY_PAGE ~1187, edit together):** add `bgOK(hex, dark)` (same math, hex "#rrggbb"); `apply()` applies a stored value only if `bgOK` passes, else removes the inline override (already-persisted unsafe localStorage values are thereby never applied); the `input` handler rejects failing picks by resetting the swatch to the stored/default value.
- **Verify:** both suites green.

## Task 8 — Atomic installer plists with restore-on-failure, item 7

`install.sh:19` renders straight into the live plist (truncating a working config before validation); a failed `bootstrap` leaves nothing loaded. Same shape in `install-canary.sh`.

- **Failing checks:** new `test_dashboard.TestInstallScripts`, running the real scripts hermetically with `HOME` set to a temp dir, `LAUNCHCTL` env override, and a PATH shim dir prepended when a tool must fail:
  1. `test_bash_syntax` — `bash -n` on install.sh, install-canary.sh, uninstall.sh.
  2. `test_clean_install_renders_valid_plist_no_debris` — `LAUNCHCTL=true`: exit 0; rendered plist exists and passes `plutil -lint`; LaunchAgents dir contains no `.new*`/`.bak` leftovers.
  3. `test_validation_failure_leaves_prior_plist_and_no_debris` — seed a sentinel plist; PATH shim makes `plutil` exit 1: script exits non-zero; sentinel content unchanged; no `.new*`/`.bak` files remain.
  4. `test_bootstrap_failure_restores_prior_plist` — seed sentinel; `LAUNCHCTL=false`: exit non-zero; sentinel restored byte-identical; stderr mentions restore; no debris. (Re-bootstrap of the restored plist is attempted — with `LAUNCHCTL=false` it fails tolerated.)
- **Implement (both scripts):** `LAUNCHCTL="${LAUNCHCTL:-launchctl}"`; render into `NEW="$(mktemp "$PLIST.new.XXXXXX")"` with `trap 'rm -f "$NEW"' EXIT` so any failure (render, `plutil -lint`, the install.sh python-pin grep) leaves no temp file; only after validation `cp` the existing plist to `"$PLIST.bak"` and `mv "$NEW" "$PLIST"` (atomic, same dir); `bootout` then `bootstrap` via `"$LAUNCHCTL"`; on bootstrap failure move `.bak` back into place, attempt to re-bootstrap the restored plist (failure tolerated), report, exit 1; on success remove `.bak`. Extend the trap to also remove a still-present `.bak` on failure exits so no debris survives any path.
- **Verify:** all four tests pass; scripts behave identically for real installs (`LAUNCHCTL` defaults to `launchctl`).

## Task 9 — Remove the retired gemini-cli provider, item 9

Keep Antigravity's Gemini *pool* vocabulary (`"gemini" in displayName → "Gemini"` pool in `parse_antigravity`/`parseAntigravity`, `"Weekly - Gemini"` labels/tests). Remove everything else.

- **Failing check:** `TestHtmlPage.test_gemini_provider_fully_retired` — `dashboard` has no attr `parse_gemini`/`fetch_gemini`; `"gemini"` not in `HTML_PAGE`; `"gemini"` not in `SERVICES`.
- **Implement — delete:** dashboard.py `DAY_SECONDS` (173, gemini-only), `parse_gemini` (176-195), `GEMINI_CLIENT_ID/SECRET` + `read_gemini_creds` + `refresh_gemini_token` + `fetch_gemini` (198-242), `STALE_FIX` gemini line (858), `"gemini"` in `limit_paths` (1381); rewrite the retirement comment (29-31) to "removed 2026-08-20, revive from git history". Core.swift Gemini section incl. `daySeconds` (218-243); Providers.swift Gemini section (152-203); SettingsView.swift:9 gemini entry; BoardView.swift:426 gemini STALE_FIX entry; Shared.swift:6-7 comment updated. Tests: drop `test_parse_gemini`, `test_parse_gemini_empty_buckets_raises`, `test_fetch_gemini_wires_refresh_and_parser`; in the non-finite test (~671-674) swap the gemini stanza for an antigravity-fixture equivalent (`remainingFraction: "NaN"` → `parse_antigravity` raises). CoreTests: drop `testParseGemini`/`testParseGeminiEmptyBuckets`; rename synthetic ids `"gemini.g-2.5-pro"` → `"antigravity.g-2.5-pro"` (dotted-label regression survives) and the `"gemini"` key in the error-map literal (line 60) → `"antigravity"`; KEEP the `"Weekly - Gemini"` assertions. Delete `fixtures/gemini_quota.json` (project.yml globs `../fixtures`).
- **Verify:** `grep -rn -i gemini dashboard.py test_dashboard.py macos/UsageBar macos/UsageBarTests fixtures` shows only Antigravity pool mapping/labels and history-pointer comments; both suites green.

## Task 10 — Correct provider/credential/endpoint/canary counts, item 8

- **Failing check:** new `TestDocs.test_docs_name_all_five_providers` — for `README.md`, `PRODUCT.md`, `macos/README.md`: each mentions Claude, Codex, Cursor, Antigravity, Copilot; none contains `Gemini` or `four providers`.
- **Implement:** README.md:3-4 headline provider list → the five; :19-21 credential list → Keychain, `~/.codex/auth.json`, Cursor's local DB, Antigravity's local language server, `~/.config/github-copilot/apps.json`; :53 Pages line → five providers; :74-85 security notes → credentials list adds Copilot `apps.json` + Antigravity's process-local token, endpoint list → `api.anthropic.com`, `chatgpt.com`, `cursor.com`, `api.github.com`, and the local Antigravity server on `127.0.0.1`, "Both usage endpoints" → "All five". PRODUCT.md:17 provider list → five. macos/README.md:10 credential list → adds Antigravity + Copilot; :47 "all four providers" → "all five providers". canary.py:16-17 comment drops the Gemini claim ("all five providers — exercises exactly the code the web app runs").
- **Verify:** `TestDocs` passes; full suite green.

## Task 11 — Local release-artifact verification gate (no release action)

Local-only proof that the release configuration still produces correct artifacts. No signing, no notarization, no `release.sh`, no tags, no `gh`/network queries; `macos/dist/` and the published v1.0.18 are read-only context.

1. Full suites: `python3 -W error::ResourceWarning -m unittest test_dashboard -v` and the xcodebuild test command — all green.
2. Unsigned Release build with sentinel versions into a **unique** derived-data directory: `DD="$(mktemp -d)"` (yields a fresh path under the per-user temp root, e.g. `/var/folders/…/T/tmp.XXXXXX`); retain the resolved explicit `$DD` for every later step. Then `cd macos && xcodegen generate && xcodebuild -project UsageBar.xcodeproj -scheme UsageBar -configuration Release build CODE_SIGNING_ALLOWED=NO MARKETING_VERSION=9.9.9 CURRENT_PROJECT_VERSION=999 -derivedDataPath "$DD"` — BUILD SUCCEEDED.
3. Inspect the produced app **and** widget plists under `"$DD"/Build/Products/Release/UsageBar.app`: `plutil -extract CFBundleShortVersionString raw Contents/Info.plist` → `9.9.9` and `plutil -extract CFBundleVersion raw …` → `999`, repeated for `Contents/PlugIns/UsageBarWidget.appex/Contents/Info.plist` (version placeholders are owned by project.yml — this catches a regression that once shipped a stale widget version).
4. Clean up **only** the validated temp directory: `[ -n "$DD" ] && [ -d "$DD/Build" ] && rm -rf "$DD"` — the guard confirms `$DD` is the mktemp-created build dir before deleting; never an unconditional `rm -rf` and never a fixed shared path. Then `git status --short` shows only the expected modified/added files plus untracked `.DS_Store` and `.architect-callback.md` (leave both alone).

---

## Decisions

1. Redirects refused outright (no origin/strip logic): every vendor answers 200 directly, so any 3xx is anomalous. Scope is dashboard.py per the accepted item; Swift `URLSession` redirect policy was not accepted for change.
2. Numeric bound 1e15 for raw values (above ms epochs ≈ 1.8e12) plus explicit derived-percent validation (`validPct`) at construction — raw bounds alone don't cap products.
3. Background feature kept: rejection + init-time purge of persisted unsafe values, on both platforms; clamping rejected as more code for worse intent-preservation.
4. Task 6 reverses v1.0.11 provider clustering per the accepted review and the merged-board spec; adjacency-based captions need no change.
5. Test seams are the smallest that reach the logic: `Store.init(startPolling:)`, injectable `fetchers`, `HistoryFile.url` as an overridable `static var`. No protocols, no mocks frameworks.
6. Installer tests execute the real scripts hermetically (temp `HOME`, `LAUNCHCTL` override, PATH shim for `plutil` failure) — full-fidelity shell checks with zero effect on live LaunchAgents.
