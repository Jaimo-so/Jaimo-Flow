#!/bin/zsh
set -euo pipefail

SCRIPTS_DIR="${0:A:h}"

CLIPFLOW_SKIP_APP_BUILD=0 "$SCRIPTS_DIR/run-credential-self-test.sh"
export CLIPFLOW_SKIP_APP_BUILD=1
"$SCRIPTS_DIR/run-memo-self-test.sh"
"$SCRIPTS_DIR/run-panel-self-test.sh"
"$SCRIPTS_DIR/run-recording-asr-self-test.sh"
"$SCRIPTS_DIR/run-vibehub-self-test.sh"
"$SCRIPTS_DIR/run-vibehub-agent-self-test.sh"
"$SCRIPTS_DIR/run-self-test.sh"
