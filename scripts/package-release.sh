#!/bin/bash
# Build a native release archive, or validate a tag without building.
# Usage: ./scripts/package-release.sh [--validate-only] [vMAJOR.MINOR.PATCH]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE_ONLY=false
if [[ "${1:-}" == --validate-only ]]; then
    VALIDATE_ONLY=true
    shift
fi
if [[ $# -gt 1 ]]; then
    echo 'usage: package-release.sh [--validate-only] [vMAJOR.MINOR.PATCH]' >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
TAG="${1-v$VERSION}"
if [[ ! "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: release tag must be vMAJOR.MINOR.PATCH: $TAG" >&2
    exit 1
fi
if [[ "${TAG#v}" != "$VERSION" ]]; then
    echo "error: release tag $TAG does not match bundle version $VERSION" >&2
    exit 1
fi
if [[ "$VALIDATE_ONLY" == true ]]; then
    exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported release architecture: $ARCH" >&2; exit 1 ;;
esac

"$ROOT/scripts/build-app.sh" release
APP="$ROOT/.build/Pinboard.app"
codesign --verify --deep --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/Pinboard")" = "$ARCH"

NAME="Pinboard-$VERSION-macos-$ARCH.zip"
STAGING="$(mktemp -d "$ROOT/.build/release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$STAGING/$NAME"
(cd "$STAGING" && shasum -a 256 "$NAME" > "$NAME.sha256")
mkdir -p "$ROOT/dist"
mv "$STAGING/$NAME" "$STAGING/$NAME.sha256" "$ROOT/dist/"
echo "Packaged: $ROOT/dist/$NAME"
