# UsageBar — macOS menu-bar app

Native Swift port of `dashboard.py`, covering the same five providers (Claude
Code, Codex, Cursor, Antigravity, GitHub Copilot). Lives in the menu bar, shows the worst
lane's usage %; click for the full board (rolling / weekly / monthly lanes,
pace badges, projections). "Open Window" in the popover opens the same board
as a resizable standalone window that scales with its size — meant for a
dedicated/secondary display. Polls every 20 min, history in
`~/Library/Application Support/UsageBar/history.jsonl` (60-day retention).
Tokens are read at fetch time from the same places the CLIs keep them
(Keychain, `~/.codex/auth.json`, Cursor's `state.vscdb`, Antigravity's local
language server, Copilot's `~/.config/github-copilot/apps.json`) and never
stored.

A widget (small/medium/large) shows the board on the desktop / Notification
Center: the app writes each poll's snapshot to the App Group container
(`~/Library/Group Containers/JXGJ4K9KR9.group.com.kamilkovac.usagebar/latest.json`)
and the sandboxed widget extension renders it — the widget itself never touches
credentials or the network, and goes stale (with an "as of" stamp) if the app
isn't running. Add it via right-click on the desktop → Edit Widgets → UsageBar.

## Build & run

```sh
brew install xcodegen          # once
cd macos
xcodegen generate
xcodebuild -project UsageBar.xcodeproj -scheme UsageBar -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/UsageBar-*/Build/Products/Release/UsageBar.app
```

First launch: macOS asks once to allow Keychain access for the Claude token
("Always Allow" stops the prompt recurring).

Tests (fixture-driven, same fixtures as `test_dashboard.py`):

```sh
xcodebuild -project UsageBar.xcodeproj -scheme UsageBar test -destination 'platform=macOS'
```

## Updates & drift defense

- **Auto-updates (Sparkle):** the app checks
  `github.com/Kamilkov/subscriptions-dashboard/releases/latest/download/appcast.xml`;
  Options has a manual "Check for Updates…". Release with
  `scripts/release.sh <version> [--notarize <profile>]`, then
  `gh release create v<version> dist/UsageBar-<version>.zip dist/appcast.xml`.
  The EdDSA private key lives in the login Keychain ("Private key for signing
  Sparkle updates"); the public key is in the app's Info.plist.
- **Canary:** `../canary.py` probes all five providers daily at 09:30
  (`../install-canary.sh` installs the launchd agent) and fires a macOS
  notification on payload drift, so parser breakage is known before users
  report it.

## Release (Developer ID, outside the App Store)

The Mac App Store is out: the sandbox forbids reading other apps' credentials,
which is this app's whole mechanism. Ship notarized instead:

1. In `project.yml`, replace the ad-hoc signing with your team:
   `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: <TEAMID>` (hardened
   runtime is already on), then `xcodegen generate`.
2. `xcodebuild -scheme UsageBar -configuration Release build`
3. `ditto -c -k --keepParent UsageBar.app UsageBar.zip`
4. `xcrun notarytool submit UsageBar.zip --keychain-profile <profile> --wait`
5. `xcrun stapler staple UsageBar.app`, then wrap in a DMG.
