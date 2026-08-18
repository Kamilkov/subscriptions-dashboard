#!/bin/bash
# Build, zip, EdDSA-sign, and appcast a UsageBar release.
#
#   scripts/release.sh 0.2.0 [--notarize <keychain-profile>]
#
# Then publish (feed URL points at the latest release's assets):
#   gh release create v0.2.0 dist/UsageBar-0.2.0.dmg dist/UsageBar-0.2.0.zip dist/appcast.xml
#
# The DMG is the human download (drag-to-Applications); the ZIP stays the
# Sparkle enclosure — Sparkle prefers zips (atomic install, no mount step).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [--notarize <profile>]}"
NOTARIZE_PROFILE=""
[ "${2:-}" = "--notarize" ] && NOTARIZE_PROFILE="${3:?--notarize needs a keychain profile}"

rm -rf dist && mkdir -p dist
xcodegen generate
# Sparkle compares CFBundleVersion numerically, and the original 0.1.0 shipped
# with build "1" — which outranks any "0.x.y" string, so those installs saw
# every release as a downgrade. Encode the version as a monotonic integer
# (0.1.2 -> 102, 1.0.0 -> 10000) so ordering is correct against build "1" too.
IFS=. read -r MAJ MIN PAT <<<"$VERSION"
BUILD=$((MAJ * 10000 + MIN * 100 + PAT))
xcodebuild -project UsageBar.xcodeproj -scheme UsageBar -configuration Release \
    -derivedDataPath dist/dd MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error|BUILD"

APP="dist/dd/Build/Products/Release/UsageBar.app"
ZIP="dist/UsageBar-$VERSION.zip"

# Notarization-grade re-sign, inside out. Direct (non-archive) xcodebuild
# leaves three gaps Apple rejects: no secure timestamps, the debug
# get-task-allow entitlement, and Sparkle's nested binaries carrying
# Sparkle's own signature instead of ours.
IDENTITY="Developer ID Application"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
            "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    codesign -f --timestamp -o runtime -s "$IDENTITY" "$item"
done
codesign -f --timestamp -o runtime -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign -f --timestamp -o runtime -s "$IDENTITY" \
    --entitlements UsageBarWidget/UsageBarWidget.entitlements \
    "$APP/Contents/PlugIns/UsageBarWidget.appex"
codesign -f --timestamp -o runtime -s "$IDENTITY" \
    --entitlements UsageBar/UsageBar.entitlements "$APP"
codesign --verify --deep --strict "$APP"

if [ -n "$NOTARIZE_PROFILE" ]; then
    ditto -c -k --keepParent "$APP" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm dist/notarize.zip
fi

ditto -c -k --keepParent "$APP" "$ZIP"

# generate_appcast signs every zip in dist/ with the Keychain EdDSA key and
# writes dist/appcast.xml.
# This build's own SPM checkout first; global DerivedData only as fallback
# (a clean machine that never opened the project in Xcode has no global copy).
GA=$(find dist/dd/SourcePackages/artifacts \
     ~/Library/Developer/Xcode/DerivedData/UsageBar-*/SourcePackages/artifacts \
     -name generate_appcast -type f 2>/dev/null | head -1 || true)
[ -n "$GA" ] || { echo "generate_appcast not found" >&2; exit 1; }
"$GA" dist/

# Drag-to-Applications DMG for first-time downloads. Built AFTER
# generate_appcast so the appcast keeps pointing at the zip.
DMG="dist/UsageBar-$VERSION.dmg"
STAGE="dist/dmg-stage"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "UsageBar" -srcfolder "$STAGE" -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGE"
codesign --timestamp -s "$IDENTITY" "$DMG"
if [ -n "$NOTARIZE_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "release ready:"
echo "  gh release create v$VERSION $DMG $ZIP dist/appcast.xml"
