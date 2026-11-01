#!/bin/bash
# Builds Pinboard.app from the SwiftPM executable target.
#   ./scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# SwiftPM needs a full Xcode toolchain; the CommandLineTools one cannot link
# the package manifest against PackageDescription here.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    if [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi

APP="$ROOT/.build/Pinboard.app"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

swift build -c "$CONFIG" --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pinboard" "$APP/Contents/MacOS/Pinboard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.txt" "$APP/Contents/Resources/ThirdPartyNotices.txt"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICON_INFO="$ROOT/.build/app-icon-info.plist"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
xcrun actool "$ROOT/Resources/Assets.xcassets" \
    --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target "$MINIMUM_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$ICON_INFO"
/usr/libexec/PlistBuddy -c "Merge '$ICON_INFO'" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"

# Register the bundle so LaunchServices resolves pinboard:// to this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
