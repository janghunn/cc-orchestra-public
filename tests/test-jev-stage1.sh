#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE1_TMP="$(mktemp -d /tmp/jev-stage1.XXXXXXXX)"
trap 'rm -rf "$STAGE1_TMP"' EXIT
export CC_ORCH_STATE_DIR="$STAGE1_TMP"
export PYTHONDONTWRITEBYTECODE=1
bash -n "${BASH_SOURCE[0]}"
python3 "$ROOT/tests/test-jev-stage1.py" "$STAGE1_TMP"
