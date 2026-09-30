#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
COMPATIBLE_SDK="$("$PROJECT_DIR/Scripts/swift-sdk-path.sh")"
DEBUG_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

SDKROOT="$COMPATIBLE_SDK" swift build \
    --disable-sandbox \
    --triple arm64-apple-macosx13.0 \
    --package-path "$PROJECT_DIR" \
    --product ClipFlow

# Link the real app model and views, replacing only the event-loop entry point.
typeset -a app_objects
for object in "$DEBUG_DIR"/ClipFlow.build/*.o; do
    [[ "${object:t}" == "main.swift.o" ]] || app_objects+=("$object")
done

swiftc \
    -parse-as-library \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$COMPATIBLE_SDK" \
    -target arm64-apple-macosx13.0 \
    -I "$DEBUG_DIR/Modules" \
    -I "$PROJECT_DIR/Sources/CSQLite" \
    "$PROJECT_DIR/Tests/ClipFlowVibeHubAgentSelfTest/main.swift" \
    "${app_objects[@]}" \
    "$DEBUG_DIR"/ClipFlowKit.build/*.o \
    -o "$DEBUG_DIR/ClipFlowVibeHubAgentSelfTest"

"$DEBUG_DIR/ClipFlowVibeHubAgentSelfTest" "$@"
