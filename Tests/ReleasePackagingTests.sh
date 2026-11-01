#!/bin/bash
# Acceptance checks for a distributable produced by package-release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: ReleasePackagingTests.sh vVERSION ARCH [DIST_DIR]}"
ARCH="${2:?expected architecture is required}"
DIST="${3:-$ROOT/dist}"
NAME="Pinboard-${TAG#v}-macos-$ARCH.dmg"

test -f "$DIST/$NAME" || { echo "Missing release DMG: $DIST/$NAME" >&2; exit 1; }
(cd "$DIST" && shasum -a 256 -c "$NAME.sha256")
hdiutil verify "$DIST/$NAME"

WORK="$(mktemp -d)"
VOLUME="$WORK/volume"
MOUNTED=false
cleanup() {
    RESULT=$?
    trap - EXIT
    if [[ "$MOUNTED" == true ]]; then
        if ! hdiutil detach "$VOLUME" -quiet; then
            echo "Could not detach test volume: $VOLUME" >&2
            exit 1
        fi
    fi
    rm -rf "$WORK"
    exit "$RESULT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil imageinfo -plist "$DIST/$NAME" > "$WORK/image-info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :Format' "$WORK/image-info.plist")" = UDZO
mkdir -p "$VOLUME"
hdiutil attach -readonly -nobrowse -mountpoint "$VOLUME" "$DIST/$NAME" -quiet
MOUNTED=true
test -L "$VOLUME/Applications"
test "$(readlink "$VOLUME/Applications")" = /Applications
codesign --verify --deep --strict "$VOLUME/Pinboard.app"

# Exercise the install copy without replacing the user's installed app.
APP="$WORK/installed/Pinboard.app"
ditto "$VOLUME/Pinboard.app" "$APP"
test -x "$APP/Contents/MacOS/Pinboard"
test -s "$APP/Contents/Resources/ThirdPartyNotices.txt"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "${TAG#v}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.shiro.pinboard"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
test -s "$APP/Contents/Resources/${ICON_FILE%.icns}.icns"
iconutil --convert iconset --output "$WORK/AppIcon.iconset" "$APP/Contents/Resources/${ICON_FILE%.icns}.icns"
test -s "$WORK/AppIcon.iconset/icon_16x16.png"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist")" = AppIcon
# actool stores the full-resolution renditions in Assets.car; its compatibility
# ICNS deliberately contains only a subset of the catalog's sizes.
xcrun assetutil --info "$APP/Contents/Resources/Assets.car" > "$WORK/assets.json"
python3 - "$WORK/assets.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    assets = json.load(source)
sizes = {asset.get("PixelWidth") for asset in assets
         if asset.get("Name") == "AppIcon"
         and asset.get("PixelWidth") == asset.get("PixelHeight")}
assert {16, 32, 64, 128, 256, 512, 1024} <= sizes, sizes
PY
test "$(lipo -archs "$APP/Contents/MacOS/Pinboard")" = "$ARCH"
codesign --verify --deep --strict "$APP"
hdiutil detach "$VOLUME" -quiet
MOUNTED=false

# Invalid tags must fail at the version boundary, not during a later build.
for INVALID in '' v999.999.999 v01.0.0 v0.1 0.1.0 v0.1.0-beta '../invalid'; do
    if "$ROOT/scripts/package-release.sh" "$INVALID" > "$WORK/invalid.log" 2>&1; then
        echo "Invalid release tag was accepted: $INVALID" >&2
        exit 1
    fi
    grep -q 'error: release tag' "$WORK/invalid.log"
done

echo "DMG mount, install copy, metadata, signature, architecture, and tag rejection checks passed: $NAME"
