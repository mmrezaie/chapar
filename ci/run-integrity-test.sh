#!/usr/bin/env bash
# Run integrity validation after a successful build+promote
set -euo pipefail

ENV_NAME="${1:?Usage: run-integrity-test.sh <env-name>}"
CHAPAR_ROOT="${CHAPAR_ROOT:-/opt/actions-runner/_work/chapar/chapar}"
cd "$CHAPAR_ROOT"

source ./etc/init.sh 2>/dev/null || true

case "$ENV_NAME" in
    vlad)   ENV_ROOT="/resources/chapar/vlad" ;;
    hpcsim) ENV_ROOT="/resources/chapar/hpcsim" ;;
    *)      echo "Unknown env: $ENV_NAME" >&2; exit 1 ;;
esac

OS_NAME="${OS_NAME:-rocky10}"
CURRENT_LINK="${ENV_ROOT}/${OS_NAME}/current"
if [ -L "$CURRENT_LINK" ]; then
    MODULE_PATH=$(readlink -f "$CURRENT_LINK")/modulefiles
    ARCH_DIR=$(ls "$MODULE_PATH" 2>/dev/null | grep "x86_64_v3" | head -1)
    if [ -n "$ARCH_DIR" ]; then
        MODULE_PATH="$MODULE_PATH/$ARCH_DIR"
    fi
else
    echo "No current symlink at $CURRENT_LINK — cannot run integrity test" >&2
    exit 0
fi

export ENV_NAME MODULE_PATH
exec bash validation/tests/integrity-test.sbatch
