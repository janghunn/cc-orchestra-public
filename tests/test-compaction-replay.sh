#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PYTHONPYCACHEPREFIX="$TMP/pycache"
export CC_ORCH_STATE_DIR="$TMP/state"
export TEST_ROOT="$ROOT" TEST_TMP="$TMP"
export CC_ORCH_CLI_AUTO_UPDATE=0
while IFS= read -r name; do
  case "${name,,}" in *_proxy|proxy) unset "$name" ;; esac
done < <(compgen -e)
bash -n "${BASH_SOURCE[0]}"
python3 -m py_compile "$ROOT"/eval/compaction-replay/*.py
python3 "$ROOT/tests/test-compaction-replay.py"
