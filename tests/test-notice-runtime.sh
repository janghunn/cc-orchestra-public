#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

cat > "$STATE/state" <<'STATE'
active=opus[1m]
pinned=0
fable_pct=98
all_pct=92
session_pct=0
reason=Fable 98%
STATE

REV="$("$ROOT/bin/orch-policy-rev" "$ROOT")"

run_notice() {
  printf '{}' | \
    CC_ORCH_STATE_DIR="$STATE" \
    CC_ORCH_MODEL="$1" \
    CC_ORCH_EFFORT="$2" \
    CC_ORCH_PROFILE="$3" \
    CC_ORCH_RUNTIME_ROUTING="$4" \
    CC_ORCH_MODEL_OVERRIDE="${5:-0}" \
    CC_ORCH_EFFORT_OVERRIDE="0" \
    CC_ORCH_POLICY_REV="$REV" \
    CC_ORCH_PROJECT=test \
    "$ROOT/hooks/orch-model-notice.sh"
}

out="$(run_notice 'sonnet[1m]' high normal 1)"
[ -z "$out" ] || { echo "FAIL: runtime normal Sonnet must not receive legacy Opus warning" >&2; echo "$out" >&2; exit 1; }

out="$(run_notice 'opus[1m]' high normal 1 1)"
[ -z "$out" ] || { echo "FAIL: explicit runtime normal model override must be accepted" >&2; echo "$out" >&2; exit 1; }

out="$(run_notice 'fable[1m]' high critical 1)"
printf '%s' "$out" | grep -qF 'critical orchestrator는 opus[1m]@xhigh' || {
  echo "FAIL: critical runtime must retain legacy Fable exhaustion fallback warning" >&2
  echo "$out" >&2
  exit 1
}

out="$(run_notice 'sonnet[1m]' high normal 0)"
printf '%s' "$out" | grep -qF 'normal orchestrator는 opus[1m]@high' || {
  echo "FAIL: direct legacy normal launch compatibility must remain unchanged" >&2
  echo "$out" >&2
  exit 1
}

echo "PASS: runtime policy notice alignment"
