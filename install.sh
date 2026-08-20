#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
LABEL="com.kamil.usage-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"   # tests stub this (true/false)

# Resolve and validate the interpreter that will run the agent. launchd gets no
# shell PATH, so the absolute path found here is baked into the plist.
PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { echo "error: python3 not found on PATH" >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || { echo "error: $PYTHON is older than 3.9" >&2; exit 1; }

mkdir -p "$HOME/Library/Logs/usage-dashboard" "$HOME/Library/LaunchAgents"

# Atomic swap: render into a temp file, validate it, and only then replace the
# live plist — a working config is never truncated by a failed render, and any
# failure exit leaves no .new/.bak debris behind (trap).
NEW="$(mktemp "$PLIST.new.XXXXXX")"
# Any exit removes the temp render; the backup is removed only when the live
# plist is byte-identical to it (rollback not needed) — a .bak that still
# holds the only good config is never deleted.
trap 'rm -f "$NEW"; if [ -f "$PLIST.bak" ] && cmp -s "$PLIST" "$PLIST.bak"; then rm -f "$PLIST.bak"; fi' EXIT

# Render the template with XML-escaped absolute paths. No sed: paths may contain
# characters that break sed replacement (&, |) or XML (&, <).
"$PYTHON" - "$PROJECT_DIR" "$HOME" "$PYTHON" > "$NEW" <<'EOF'
import pathlib, sys
from xml.sax.saxutils import escape
proj, home, py = (escape(a) for a in sys.argv[1:4])
t = pathlib.Path("launchd/com.kamil.usage-dashboard.plist.template").read_text()
sys.stdout.write(t.replace("__PROJECT_DIR__", proj)
                  .replace("__HOME__", home)
                  .replace("__PYTHON__", py))
EOF
plutil -lint "$NEW" >/dev/null || { echo "error: rendered plist is invalid" >&2; exit 1; }
grep -Fq "<string>$PYTHON</string>" "$NEW" \
    || { echo "error: rendered plist does not pin $PYTHON" >&2; exit 1; }

# The prior working plist survives as .bak until the new agent bootstraps.
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
echo "installed — dashboard at http://127.0.0.1:8787 (python: $PYTHON)"
echo "logs: $HOME/Library/Logs/usage-dashboard/"
