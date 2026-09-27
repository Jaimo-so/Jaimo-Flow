#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
COMPATIBLE_SDK="$("$PROJECT_DIR/Scripts/swift-sdk-path.sh")"
DEBUG_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"

SDKROOT="$COMPATIBLE_SDK" swift build \
    --disable-sandbox \
    --triple arm64-apple-macosx13.0 \
    --package-path "$PROJECT_DIR" \
    --product ClipFlow

typeset -a app_objects
for object in "$DEBUG_DIR"/ClipFlow.build/*.o; do
    [[ "${object:t}" == "main.swift.o" ]] || app_objects+=("$object")
done

swiftc \
    -sdk "$COMPATIBLE_SDK" \
    -target arm64-apple-macosx13.0 \
    -I "$DEBUG_DIR/Modules" \
    -I "$PROJECT_DIR/Sources/CSQLite" \
    "$PROJECT_DIR/Tests/ClipFlowCredentialSelfTest/main.swift" \
    "${app_objects[@]}" \
    "$DEBUG_DIR"/ClipFlowKit.build/*.o \
    -o "$DEBUG_DIR/ClipFlowCredentialSelfTest"

"$DEBUG_DIR/ClipFlowCredentialSelfTest"
