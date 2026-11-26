#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_TARGET="${1:-}"
TEST_SOURCE="$PROJECT_DIR/Tests/$TEST_TARGET/main.swift"

if [[ -z "$TEST_TARGET" || "$TEST_TARGET" == *"/"* || ! -f "$TEST_SOURCE" ]]; then
    print -u2 -- "用法：${0:t} <TestTargetDir> [测试参数...]"
    exit 2
fi
shift

COMPATIBLE_SDK="$("$PROJECT_DIR/Scripts/swift-sdk-path.sh")"
DEBUG_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

if [[ "${CLIPFLOW_SKIP_APP_BUILD:-0}" != 1 ]]; then
    SDKROOT="$COMPATIBLE_SDK" swift build \
        --disable-sandbox \
        --triple arm64-apple-macosx13.0 \
        --package-path "$PROJECT_DIR" \
        --product ClipFlow
fi

# Use SwiftPM's current link inputs so moved or removed sources leave no stale
# objects in the test link. Replace only the app's event-loop entry point.
LINK_FILE_LIST="$DEBUG_DIR/ClipFlow.product/Objects.LinkFileList"
typeset -a app_objects entry_point_flags
while IFS= read -r quoted_object; do
    object="${(Q)quoted_object}"
    [[ "${object:t}" == "main.swift.o" ]] || app_objects+=("$object")
done < "$LINK_FILE_LIST"
if [[ "$TEST_TARGET" == "ClipFlowVibeHubAgentSelfTest" ]]; then
    entry_point_flags+=(-parse-as-library)
fi

swiftc \
    "${entry_point_flags[@]}" \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$COMPATIBLE_SDK" \
    -target arm64-apple-macosx13.0 \
    -I "$DEBUG_DIR/Modules" \
    -I "$PROJECT_DIR/Sources/CSQLite" \
    -I "$DEBUG_DIR/CTerminal.build" \
    "$TEST_SOURCE" \
    "${app_objects[@]}" \
    -o "$DEBUG_DIR/$TEST_TARGET"

exec "$DEBUG_DIR/$TEST_TARGET" "$@"
