#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0 # Fake providers: no network or package mutation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has() { printf '%s' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }

bash -n "$ROOT/bin/cc-orch" "$ROOT/bin/cc-orch-runtime"
# install.sh normalizes executable bits for bin/*; mirror that installed environment in CI.
chmod +x "$ROOT/bin/cc-orch" "$ROOT/bin/cc-orch-runtime"

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
{
  printf '%s\n' "$*"
  printf 'routing=%s\n' "${CC_ORCH_RUNTIME_ROUTING:-unset}"
  printf 'launch_marker=%s\n' "${CC_ORCH_RUNTIME_ROUTING_LAUNCH:-unset}"
} > "${TEST_ARGS:?}"
CLAUDE
chmod +x "$FAKEBIN/claude"

run_capture() {
  local outfile="$1"; shift
  # Prevent ambient state inherited from a nested cc-orch-runtime session from leaking into the test.
  unset CC_ORCH_RUNTIME_ROUTING CC_ORCH_MODEL CC_ORCH_EFFORT CC_ORCH_PROFILE CC_ORCH_MODEL_OVERRIDE CC_ORCH_EFFORT_OVERRIDE CC_ORCH_POLICY_REV CC_ORCH_PROJECT
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" TEST_ARGS="$outfile" "$@"
  cat "$outfile"
}

out="$(run_capture "$TMP/normal" "$ROOT/bin/cc-orch-runtime" --no-rc demo "$PROJECT")"
assert_has "$out" "--model sonnet[1m] --effort high" "runtime normal ignores legacy Opus fallback"
assert_has "$out" "routing=1"        "facade publishes runtime provenance to the session"
assert_has "$out" "launch_marker=unset" "one-shot launch marker never reaches the session"

out="$(run_capture "$TMP/critical" "$ROOT/bin/cc-orch-runtime" --no-rc --profile critical crit "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort xhigh" "runtime critical keeps Fable exhaustion protection"

out="$(run_capture "$TMP/direct" "$ROOT/bin/cc-orch" --no-rc legacy "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" "direct core preserves legacy behavior"
assert_has "$out" "routing=0"        "direct launch publishes non-runtime provenance"

out="$(run_capture "$TMP/direct-inherited" env CC_ORCH_RUNTIME_ROUTING=1 \
  "$ROOT/bin/cc-orch" --no-rc legacyenv "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" \
  "direct core ignores an inherited runtime routing marker"
assert_has "$out" "routing=0" "direct core overrides an inherited provenance value"

out="$(run_capture "$TMP/override" "$ROOT/bin/cc-orch-runtime" --no-rc --model 'opus[1m]' custom "$PROJECT")"
assert_has "$out" "--model opus[1m] --effort high" "explicit normal model override wins"

echo "PASS: runtime Tier-1 routing regression suite"
