#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has() { printf '%s' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }

bash -n "$ROOT/bin/cc-orch" "$ROOT/bin/cc-orch-runtime"

HOME_DIR="$TMP/home"
STATE="$TMP/state"
PROJECT="$TMP/project"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/.claude/agents" "$STATE" "$PROJECT" "$FAKEBIN"
ln -s "$ROOT" "$HOME_DIR/.claude/orchestra"
ln -s "$ROOT/agents/orchestrator.md" "$HOME_DIR/.claude/agents/orchestrator.md"
cat > "$STATE/state" <<'STATE'
active=opus[1m]
pinned=0
fable_pct=98
all_pct=92
session_pct=0
reason=test legacy fallback
STATE
cat > "$FAKEBIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_ARGS:?}"
CLAUDE
chmod +x "$FAKEBIN/claude"

run_capture() {
  local outfile="$1"; shift
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" TEST_ARGS="$outfile" "$@"
  cat "$outfile"
}

out="$(run_capture "$TMP/normal" "$ROOT/bin/cc-orch-runtime" --no-rc demo "$PROJECT")"
assert_has "$out" "--model sonnet[1m] --effort high" "runtime normal ignores legacy Opus fallback"

out="$(run_capture "$TMP/critical" "$ROOT/bin/cc-orch-runtime" --no-rc --profile critical crit "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" "runtime critical keeps Fable exhaustion protection"

out="$(run_capture "$TMP/direct" "$ROOT/bin/cc-orch" --no-rc legacy "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" "direct core preserves legacy behavior"

out="$(run_capture "$TMP/override" "$ROOT/bin/cc-orch-runtime" --no-rc --model 'opus[1m]' custom "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" "explicit normal model override wins"

echo "PASS: runtime Tier-1 routing regression suite"
