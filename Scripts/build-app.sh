#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Jaimo Flow.app"
ARM_MODULE_CACHE="$PROJECT_DIR/.build/module-cache-arm64"
ARM_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/ClipFlow"
UPDATER_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/ClipFlowUpdater"
SIGN_IDENTITY="${CLIPFLOW_SIGN_IDENTITY:--}"
COMPATIBLE_SDK="${SDKROOT:-$("$PROJECT_DIR/Scripts/swift-sdk-path.sh")}"

mkdir -p "$ARM_MODULE_CACHE"
SDKROOT="$COMPATIBLE_SDK" \
CLANG_MODULE_CACHE_PATH="$ARM_MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$ARM_MODULE_CACHE" \
swift build \
    --disable-sandbox \
    -c release \
    --triple arm64-apple-macosx13.0 \
    --package-path "$PROJECT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$ARM_BINARY" "$APP_DIR/Contents/MacOS/Jaimo Flow"
cp "$UPDATER_BINARY" "$APP_DIR/Contents/Helpers/ClipFlowUpdater"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$APP_DIR/Contents/Helpers/ClipFlowUpdater"
    /usr/bin/codesign --force --sign - "$APP_DIR"
else
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR/Contents/Helpers/ClipFlowUpdater"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/Jaimo Flow"
echo "$APP_DIR"
