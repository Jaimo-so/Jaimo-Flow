#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/Jaimo Flow.app"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
DMG_PATH="$DIST_DIR/Jaimo-Flow-${VERSION}-macOS-Apple-Silicon.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
STAGING_DIR="$(/usr/bin/mktemp -d /tmp/jaimo-flow-dmg.XXXXXX)"

cleanup() {
    if [[ "$STAGING_DIR" == /tmp/jaimo-flow-dmg.* && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

"$PROJECT_DIR/Scripts/build-app.sh"

mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/Jaimo Flow.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
    -volname "Jaimo Flow" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
/usr/bin/shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
