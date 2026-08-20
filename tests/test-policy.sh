#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $((++pass)) - $*"; }
field() { sed -n "s/^$2: //p" "$1" | head -1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { printf '%s' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }

for script in "$ROOT/build-roster.sh" "$ROOT/install.sh" "$ROOT/bin/cc-orch" "$ROOT/bin/codex-run" "$ROOT/bin/orch-model-guard" "$ROOT/bin/orch-summary-check" "$ROOT/bin/orch-usage-report" "$ROOT/hooks/orch-model-notice.sh"
do
  bash -n "$script"
done
ok "shell syntax"

STATE="$TMP/state"
AGENTS="$TMP/agents"
mkdir -p "$STATE" "$AGENTS"
CC_ORCH_STATE_DIR="$STATE" CC_ORCH_AGENTS_DIR="$AGENTS" "$ROOT/build-roster.sh" >/dev/null

count="$(find "$AGENTS" -maxdepth 1 -type f \( -name 'lead-*.md' -o -name 'dev-*.md' \) | wc -l)"
assert_eq "$count" "22" "generated profile count"
assert_eq "$(field "$AGENTS/lead-alpha-light.md" model)" "sonnet[1m]" "light model"
assert_eq "$(field "$AGENTS/lead-alpha-light.md" effort)" "medium" "light effort"
assert_eq "$(field "$AGENTS/lead-alpha.md" model)" "opus[1m]" "normal lead model"
assert_eq "$(field "$AGENTS/lead-alpha.md" effort)" "high" "normal lead effort"
assert_eq "$(field "$AGENTS/lead-alpha-critical.md" model)" "fable[1m]" "critical model"
assert_eq "$(field "$AGENTS/lead-alpha-critical.md" effort)" "high" "critical effort"
assert_eq "$(field "$AGENTS/lead-alpha-critical-xhigh.md" model)" "fable[1m]" "deep model"
assert_eq "$(field "$AGENTS/lead-alpha-critical-xhigh.md" effort)" "xhigh" "deep effort"
assert_eq "$(field "$AGENTS/dev-1.md" model)" "sonnet[1m]" "Claude exception model"
assert_eq "$(field "$AGENTS/dev-opus-1.md" model)" "opus[1m]" "fresh-eyes model"
ok "primary roster models and efforts"

CC_ORCH_STATE_DIR="$STATE" CC_ORCH_AGENTS_DIR="$AGENTS" "$ROOT/bin/orch-model-guard" set fallback >/dev/null
while IFS= read -r lead; do
  assert_eq "$(field "$lead" model)" "opus[1m]" "fallback $(basename "$lead")"
done < <(find "$AGENTS" -maxdepth 1 -type f -name 'lead-*.md' | sort)
assert_eq "$(sed -n 's/^active=//p' "$STATE/state")" "opus[1m]" "fallback state"

CC_ORCH_STATE_DIR="$STATE" CC_ORCH_AGENTS_DIR="$AGENTS" "$ROOT/bin/orch-model-guard" set primary >/dev/null
assert_eq "$(field "$AGENTS/lead-alpha-light.md" model)" "sonnet[1m]" "restored light"
assert_eq "$(field "$AGENTS/lead-alpha.md" model)" "opus[1m]" "restored normal"
assert_eq "$(field "$AGENTS/lead-alpha-critical.md" model)" "fable[1m]" "restored critical"
ok "Fable fallback and role-specific restore"

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Current session: 10% used' 'Current week (all models): 40% used' 'Current week (Fable): 99% used'
EOF
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"

CLAUDE_BIN="$FAKEBIN/claude" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_AGENTS_DIR="$AGENTS" CODEX_HOME="$TMP/no-codex-home" "$ROOT/bin/orch-model-guard" set auto >/dev/null
CLAUDE_BIN="$FAKEBIN/claude" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_AGENTS_DIR="$AGENTS" CODEX_HOME="$TMP/no-codex-home" "$ROOT/bin/orch-model-guard" check
assert_eq "$(sed -n 's/^active=//p' "$STATE/state")" "opus[1m]" "automatic Fable fallback"
assert_eq "$(field "$AGENTS/lead-delta-critical-xhigh.md" model)" "opus[1m]" "automatic deep fallback"
lanes="$(CLAUDE_BIN="$FAKEBIN/claude" CC_ORCH_STATE_DIR="$STATE" CODEX_HOME="$TMP/no-codex-home" "$ROOT/bin/orch-model-guard" lanes)"
assert_has "$lanes" "dispatch=codex-first" "default dispatch"
ok "automatic quota switch and Codex-first default"

WORK="$TMP/work"
TASK="$WORK/.orchestra/01-test"
mkdir -p "$TASK"
cat > "$TASK/brief.md" <<'EOF'
# Test
RISK: normal
Verification: true
EOF
cat > "$TASK/plan.md" <<'EOF'
# Plan
Run true.
EOF

run_dry() {
  PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/codex-run" "$@" --dry-run 2>&1
}

out="$(run_dry intake "$WORK" "$TASK" "map the task")"
assert_has "$out" "gpt-5.6-terra" "intake model"
assert_has "$out" "model_reasoning_effort=high" "intake effort"
assert_has "$out" "--sandbox read-only" "intake sandbox"

out="$(run_dry investigate "$WORK" "$TASK" "find the owner")"
assert_has "$out" "gpt-5.6-sol" "investigate model"
assert_has "$out" "model_reasoning_effort=high" "investigate effort"

out="$(run_dry investigate "$WORK" "$TASK" "find the owner" --fast-mode)"
assert_has "$out" "gpt-5.6-sol" "Fast mode preserves investigate model"
assert_has "$out" "service_tier=" "Fast mode service tier"
assert_has "$out" "features.fast_mode=true" "Fast mode feature"

out="$(run_dry investigate "$WORK" "$TASK" "find the owner" --fast)"
assert_has "$out" "gpt-5.6-luna" "legacy fast switches model"
assert_has "$out" "model_reasoning_effort=high" "legacy fast effort"

out="$(run_dry implement "$WORK" "$TASK")"
assert_has "$out" "gpt-5.6-sol" "implement model"
assert_has "$out" "model_reasoning_effort=xhigh" "implement effort"
assert_has "$out" "--sandbox workspace-write" "implement sandbox"

out="$(run_dry verify "$WORK" "$TASK")"
assert_has "$out" "gpt-5.6-terra" "verify model"
assert_has "$out" "model_reasoning_effort=high" "verify effort"

out="$(run_dry review "$WORK" "$TASK" --base main --critical)"
assert_has "$out" "gpt-5.6-sol" "critical review model"
assert_has "$out" "model_reasoning_effort=xhigh" "critical review effort"

out="$(run_dry verify "$WORK" "$TASK" --critical --fast-mode)"
assert_has "$out" "gpt-5.6-terra" "critical Fast mode preserves verify model"
assert_has "$out" "model_reasoning_effort=xhigh" "critical Fast mode effort"
assert_has "$out" "service_tier=" "critical Fast mode service tier"

if run_dry review "$WORK" "$TASK" --base main --fast --critical >/dev/null 2>&1; then
  fail "--fast --critical should be rejected"
fi
if run_dry investigate "$WORK" "$TASK" "find the owner" --fast --fast-mode >/dev/null 2>&1; then
  fail "--fast --fast-mode should be rejected"
fi
if run_dry investigate "$WORK" "$TASK" "find the owner" --model luna --fast-mode >/dev/null 2>&1; then
  fail "--fast-mode with Luna should be rejected"
fi
ok "Codex mode model, effort, sandbox, and flag policy"

cat > "$TASK/summary.md" <<'EOF'
[lead-alpha] STATUS: PASS
CLAUDE PROFILE: normal opus@high
PROMOTIONS: none
GATES: codex-verify PASS · codex-review CLEAR · claude-verifier not-required
ROUNDS: 1
DISPATCH: codex-first
INVESTIGATION: codex (1 call)
LANES: codex gpt-5.6-sol@xhigh
EOF
"$ROOT/bin/orch-summary-check" --strict "$TASK" >/dev/null

sed -i 's/LANES:.*/LANES: dev-1/' "$TASK/summary.md"
if "$ROOT/bin/orch-summary-check" --strict "$TASK" >/dev/null 2>&1; then
  fail "untagged Claude lane should fail"
fi
sed -i 's/LANES:.*/LANES: dev-1 (exception: fallback)/' "$TASK/summary.md"
sed -i 's/ROUNDS: 1/ROUNDS: 3/' "$TASK/summary.md"
if "$ROOT/bin/orch-summary-check" --strict "$TASK" >/dev/null 2>&1; then
  fail "normal round cap should fail"
fi
sed -i 's/ROUNDS: 3/ROUNDS: 2/' "$TASK/summary.md"
"$ROOT/bin/orch-summary-check" --strict "$TASK" >/dev/null
ok "strict artifact and gate policy"

report="$(CC_ORCH_CLAUDE_PROJECTS="$TMP/empty-claude" CC_ORCH_CODEX_LOG="$TMP/no-codex.log" "$ROOT/bin/orch-usage-report" --days 1)"
assert_has "$report" "LOCAL USAGE REPORT" "usage heading"
assert_has "$report" "Codex wrapper runs" "Codex usage heading"
ok "empty local usage report"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.claude/agents" "$HOME_DIR/.local/bin"
ln -s "$ROOT" "$HOME_DIR/.claude/orchestra"
ln -s "$ROOT/agents/orchestrator.md" "$HOME_DIR/.claude/agents/orchestrator.md"
cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/claude-args"
EOF
chmod +x "$FAKEBIN/claude"

cat > "$STATE/state" <<'EOF'
active=sonnet[1m]
pinned=0
reason=test
EOF
(
  cd "$WORK"
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc --profile deep policytest "$WORK"
)
args="$(cat "$TMP/claude-args")"
assert_has "$args" "--model fable[1m]" "deep launch model"
assert_has "$args" "--effort xhigh" "deep launch effort"

(
  cd "$TMP"
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc --reload policytest
)
args="$(cat "$TMP/claude-args")"
assert_has "$args" "--model fable[1m]" "reload preserved profile"
assert_has "$args" "--effort xhigh" "reload preserved effort"
assert_has "$args" "-c" "reload continues conversation"

(
  cd "$WORK"
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc --model opus[1m] --effort medium custom "$WORK"
)
(
  cd "$TMP"
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc --reload custom
)
args="$(cat "$TMP/claude-args")"
assert_has "$args" "--model opus[1m]" "reload preserved model override"
assert_has "$args" "--effort medium" "reload preserved effort override"

sed -i 's/^active=.*/active=opus[1m]/' "$STATE/state"
(
  cd "$WORK"
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc --profile critical --model fable[1m] fallback "$WORK"
)
args="$(cat "$TMP/claude-args")"
assert_has "$args" "--model opus[1m]" "critical fallback model"
assert_has "$args" "--effort high" "critical fallback effort"
ok "launcher profile preservation and global Opus fallback"

rev="$(sha256sum "$ROOT/model-policy.conf" "$ROOT/templates/lead.md.tpl" "$ROOT/templates/dev.md.tpl" "$ROOT/agents/orchestrator.md" "$ROOT/agents/verifier.md" "$ROOT/agents/verifier-normal.md" | sha256sum | cut -d' ' -f1)"
cat > "$STATE/state" <<'EOF'
active=sonnet[1m]
pinned=0
reason=test
EOF
quiet="$(printf '{}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='sonnet[1m]' CC_ORCH_EFFORT=high CC_ORCH_PROFILE=normal CC_ORCH_POLICY_REV="$rev" "$ROOT/hooks/orch-model-notice.sh")"
assert_eq "$quiet" "" "current-policy hook silence"
quiet="$(printf '{}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='opus[1m]' CC_ORCH_EFFORT=medium CC_ORCH_PROFILE=normal CC_ORCH_MODEL_OVERRIDE=1 CC_ORCH_EFFORT_OVERRIDE=1 CC_ORCH_POLICY_REV="$rev" "$ROOT/hooks/orch-model-notice.sh")"
assert_eq "$quiet" "" "explicit override hook silence"

notice="$(printf '{"prompt_id":"policy-test"}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='fable[1m]' CC_ORCH_EFFORT=xhigh CC_ORCH_PROFILE=normal CC_ORCH_PROJECT=dsv CC_ORCH_POLICY_REV=old "$ROOT/hooks/orch-model-notice.sh")"
printf '%s' "$notice" | python3 -c 'import json,sys; json.load(sys.stdin)'
assert_has "$notice" "cc-orch --reload dsv" "reload notice"
ok "stale-policy hook"

echo "PASS: $pass policy test groups"
