#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PYTHONPYCACHEPREFIX="$TMP/pycache"
export HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_JEV_POLICY="$TMP/policy"
export CC_ORCH_JEV_TEMPLATES="$ROOT/templates/jev"
unset TYPESAFE_API_KEY CC_ORCH_BACKEND http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
mkdir -p "$HOME" "$CC_ORCH_STATE_DIR"
cp "$ROOT/jev-policy.conf" "$CC_ORCH_JEV_POLICY"
python3 "$ROOT/tests/test-jev-local.py"
