#!/bin/bash
# Acceptance checks for a distributable produced by package-release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: ReleasePackagingTests.sh vVERSION ARCH [DIST_DIR]}"
ARCH="${2:?expected architecture is required}"
DIST="${3:-$ROOT/dist}"
NAME="Pinboard-${TAG#v}-macos-$ARCH.zip"

test -f "$DIST/$NAME" || { echo "Missing release archive: $DIST/$NAME" >&2; exit 1; }
(cd "$DIST" && shasum -a 256 -c "$NAME.sha256")

EXTRACTED="$(mktemp -d)"
trap 'rm -rf "$EXTRACTED"' EXIT
ditto -x -k "$DIST/$NAME" "$EXTRACTED"
APP="$EXTRACTED/Pinboard.app"
test -x "$APP/Contents/MacOS/Pinboard"
test -s "$APP/Contents/Resources/ThirdPartyNotices.txt"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "${TAG#v}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.shiro.pinboard"
test "$(lipo -archs "$APP/Contents/MacOS/Pinboard")" = "$ARCH"
codesign --verify --deep --strict "$APP"

# Invalid tags must fail at the version boundary, not during a later build.
for INVALID in '' v999.999.999 v01.0.0 v0.1 0.1.0 v0.1.0-beta '../invalid'; do
    if "$ROOT/scripts/package-release.sh" "$INVALID" > "$EXTRACTED/invalid.log" 2>&1; then
        echo "Invalid release tag was accepted: $INVALID" >&2
        exit 1
    fi
    grep -q 'error: release tag' "$EXTRACTED/invalid.log"
done

echo "Release archive, metadata, signature, architecture, and tag rejection checks passed: $NAME"
