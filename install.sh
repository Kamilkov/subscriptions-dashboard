#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
LABEL="com.kamil.usage-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Resolve and validate the interpreter that will run the agent. launchd gets no
# shell PATH, so the absolute path found here is baked into the plist.
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
