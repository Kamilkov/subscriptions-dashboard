#!/bin/bash
# Install the daily provider-drift canary (09:30, macOS notification on drift).
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
LABEL="com.kamil.usagebar-canary"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"   # tests stub this (true/false)

PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { echo "error: python3 not found on PATH" >&2; exit 1; }

mkdir -p "$HOME/Library/Logs/usage-dashboard" "$HOME/Library/LaunchAgents"

# Atomic swap: render into a temp file, validate, then replace — a working
# config is never truncated by a failed render; the trap leaves no debris.
NEW="$(mktemp "$PLIST.new.XXXXXX")"
# Any exit removes the temp render; the backup is removed only when the live
# plist is byte-identical to it (rollback not needed) — a .bak that still
# holds the only good config is never deleted.
trap 'rm -f "$NEW"; if [ -f "$PLIST.bak" ] && cmp -s "$PLIST" "$PLIST.bak"; then rm -f "$PLIST.bak"; fi' EXIT

"$PYTHON" - "$PROJECT_DIR" "$HOME" "$PYTHON" > "$NEW" <<'EOF'
import pathlib, sys
from xml.sax.saxutils import escape
proj, home, py = (escape(a) for a in sys.argv[1:4])
t = pathlib.Path("launchd/com.kamil.usagebar-canary.plist.template").read_text()
sys.stdout.write(t.replace("__PROJECT_DIR__", proj)
                  .replace("__HOME__", home)
                  .replace("__PYTHON__", py))
EOF
plutil -lint "$NEW" >/dev/null || { echo "error: rendered plist is invalid" >&2; exit 1; }

if [ -f "$PLIST" ]; then cp "$PLIST" "$PLIST.bak"; fi
mv "$NEW" "$PLIST"

"$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if ! "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"; then
    if [ -f "$PLIST.bak" ]; then
        mv "$PLIST.bak" "$PLIST"
        "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
        echo "error: bootstrap failed — previous plist restored and re-bootstrapped" >&2
    else
        rm -f "$PLIST"
        echo "error: bootstrap failed — no prior plist to restore" >&2
    fi
    exit 1
fi
rm -f "$PLIST.bak"
echo "installed — canary runs daily 09:30, log: $HOME/Library/Logs/usage-dashboard/canary.log"
