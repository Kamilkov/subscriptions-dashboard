#!/usr/bin/env python3
"""Daily canary: run every provider fetcher against the live APIs and alarm
(macOS notification + exit 1) when a payload stops parsing — vendor drift
detection before users hit it.

Exit codes: 0 all good or only auth/network noise; 1 parse drift detected.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard
from dashboard import FetchError

# All fetchers live in dashboard.py (all five providers), so the canary
# exercises exactly the code the web app runs.
CHECKS = {s: getattr(dashboard, f"fetch_{s}") for s in dashboard.SERVICES}


def notify(message):
    # Pass the text as an argv item, never interpolated into the script body:
    # AppleScript's string parser is not JSON, so a stray quote/backslash could
    # break the script (today's callers pass only controlled text, but this
    # keeps it robust if a raw error string ever reaches here).
    script = ('on run argv\n'
              '  display notification (item 1 of argv) '
              'with title "UsageBar canary" sound name "Basso"\n'
              'end run')
    subprocess.run(["osascript", "-e", script, message], capture_output=True)


def main():
    failures = []
    for name, fn in CHECKS.items():
        try:
            fn()
            print(f"ok    {name}")
        except FetchError as e:
            failures.append((name, e.category, e.detail))
            print(f"FAIL  {name}: {e.category}: {e.detail}")
        except Exception as e:  # a crash in a fetcher is drift too
            failures.append((name, "parse", e.__class__.__name__))
            print(f"FAIL  {name}: crash: {e.__class__.__name__}")
    drift = [f for f in failures if f[1] == "parse"]
    if drift:
        notify("PAYLOAD DRIFT: " + ", ".join(f"{n} ({d})" for n, _, d in drift))
        return 1
    if failures:  # auth/network: worth a heads-up, not an alarm
        notify("degraded: " + ", ".join(f"{n} ({c})" for n, c, _ in failures))
    return 0


if __name__ == "__main__":
    sys.exit(main())
