#!/bin/bash
set -euo pipefail
# Both agents install-canary.sh and install.sh may have created — remove both,
# so uninstall never leaves the canary polling APIs daily after the fact.
for LABEL in com.kamil.usage-dashboard com.kamil.usagebar-canary; do
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
done
echo "uninstalled — logs and history.jsonl left in place"
