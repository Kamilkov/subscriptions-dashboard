# UsageBar

**Free macOS menu-bar app showing your AI subscription usage vs. time — Claude
Code, Codex, Cursor, and Gemini on one board.**

Every lane answers one question: am I burning my quota faster than the window
is elapsing? Fill = usage, tick = time elapsed, pace badge (UNDER / ON PACE /
OVER), reset countdown, and a burn-rate projection ("runs out ~Tue 18 Aug").
Three surfaces: the menu bar (worst lane's %), a resizable board window for a
dedicated display, and a desktop widget.

**[Download the latest release](https://github.com/Kamilkov/subscriptions-dashboard/releases/latest)** —
open the DMG, drag to Applications. Auto-updates via Sparkle. macOS 15+.

One of the [machros.app](https://machros.app/) family of small, careful apps.

- Reads the tokens your existing CLIs/apps already store (Keychain,
  `~/.codex/auth.json`, Cursor's local DB, `~/.gemini`) at fetch time — tokens
  are never stored, logged, or sent anywhere except to each vendor's own API.
- These are unofficial vendor endpoints; when one changes shape, the affected
  lane degrades to "stale" (never a wrong number) and a fix ships via
  auto-update. See `macos/README.md` for architecture and build instructions.

---

## The original web dashboard

The `dashboard.py` in this repo is the local web version UsageBar grew out of —
% of window elapsed vs. % of quota used, per limit, served on
`127.0.0.1:8787`. It remains the reference implementation and test spec.

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

## Pages

- <http://127.0.0.1:8787> — AI subscription quota vs. time (Claude, Codex, Cursor)
- <http://127.0.0.1:8787/history> — weekly utilization (peak usage per reset window)

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
  (Observed in practice: the Codex weekly window switched slots within a single
  day — the parser identifies windows by length, not position.)
