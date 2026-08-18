#!/bin/bash
# Install the daily provider-drift canary (09:30, macOS notification on drift).
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
LABEL="com.kamil.usagebar-canary"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { echo "error: python3 not found on PATH" >&2; exit 1; }

mkdir -p "$HOME/Library/Logs/usage-dashboard" "$HOME/Library/LaunchAgents"

"$PYTHON" - "$PROJECT_DIR" "$HOME" "$PYTHON" > "$PLIST" <<'EOF'
import pathlib, sys
from xml.sax.saxutils import escape
proj, home, py = (escape(a) for a in sys.argv[1:4])
t = pathlib.Path("launchd/com.kamil.usagebar-canary.plist.template").read_text()
sys.stdout.write(t.replace("__PROJECT_DIR__", proj)
                  .replace("__HOME__", home)
                  .replace("__PYTHON__", py))
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed — canary runs daily 09:30, log: $HOME/Library/Logs/usage-dashboard/canary.log"
