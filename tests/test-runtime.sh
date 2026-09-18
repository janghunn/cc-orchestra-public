#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0 # Fake providers: no network or package mutation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has() { printf '%s' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_not_has() { ! printf '%s' "$1" | grep -qF -- "$2" || fail "unexpected '$2' ($3)"; }

for script in \
  "$ROOT/install.sh" "$ROOT/build-roster-runtime.sh" "$ROOT/bin/cc-orch-runtime" \
  "$ROOT/bin/cc-orch-session" "$ROOT/bin/codex-run-runtime" \
  "$ROOT/bin/orch-model-guard-runtime" "$ROOT/bin/orch-policy-rev" \
  "$ROOT/hooks/orch-runtime-context.sh" "$ROOT/hooks/orch-statusline.sh" \
  "$ROOT/lib/codex-catalog.sh"
do
  bash -n "$script"
done
ok "runtime shell syntax"

HARNESS="$TMP/harness"
mkdir -p "$HARNESS/bin" "$HARNESS/hooks" "$HARNESS/lib" "$TMP/state" "$TMP/home/.claude"
cp "$ROOT/bin/cc-orch-runtime" "$ROOT/bin/cc-orch-session" "$ROOT/bin/orch-cli-update" "$ROOT/bin/codex-run-runtime" \
   "$ROOT/bin/orch-model-guard-runtime" "$HARNESS/bin/"
cp "$ROOT/hooks/orch-runtime-context.sh" "$ROOT/hooks/orch-statusline.sh" "$HARNESS/hooks/"
cp "$ROOT/budget-policy.conf" "$ROOT/build-roster-runtime.sh" "$HARNESS/"
cp "$ROOT/lib/"*.sh "$HARNESS/lib/"
chmod +x "$HARNESS/build-roster-runtime.sh" "$HARNESS/bin/"* "$HARNESS/hooks/"*
mkdir -p "$HARNESS/templates"
cat > "$HARNESS/build-roster.sh" <<'CORE'
#!/usr/bin/env bash
mkdir -p "${CC_ORCH_AGENTS_DIR:?}"
CORE
chmod +x "$HARNESS/build-roster.sh"
cat > "$HARNESS/templates/lead.md.tpl" <<'TPL'
---
name: __AGENT_NAME__
model: __MODEL__
effort: __EFFORT__
---
You are lead-__SLOT__, profile __PROFILE__.
TPL

cat > "$HARNESS/model-policy.conf" <<'POLICY'
PRIMARY_MODEL="sonnet[1m]"
FALLBACK_MODEL="opus[1m]"
ORCH_EFFORT="high"
LEAD_LIGHT_MODEL="sonnet[1m]"; LEAD_LIGHT_EFFORT="medium"
LEAD_NORMAL_MODEL="opus[1m]"; LEAD_NORMAL_EFFORT="high"
LEAD_CRITICAL_MODEL="fable[1m]"; LEAD_CRITICAL_EFFORT="high"
LEAD_DEEP_MODEL="fable[1m]"; LEAD_DEEP_EFFORT="xhigh"
CODEX_IMPL_MODEL="gpt-5.6-sol"; CODEX_IMPL_EFFORT="xhigh"
CODEX_INVESTIGATE_MODEL="gpt-5.6-sol"; CODEX_INVESTIGATE_EFFORT="high"
CODEX_INTAKE_MODEL="gpt-5.6-terra"; CODEX_INTAKE_EFFORT="high"
CODEX_REVIEW_MODEL="gpt-5.6-sol"; CODEX_REVIEW_EFFORT="high"
CODEX_VERIFY_MODEL="gpt-5.6-terra"; CODEX_VERIFY_EFFORT="high"
POLICY

ROUTE_AGENTS="$TMP/route-agents"
CC_ORCH_AGENTS_DIR="$ROUTE_AGENTS" "$HARNESS/build-roster-runtime.sh" >/dev/null
assert_eq "$(find "$ROUTE_AGENTS" -maxdepth 1 -name 'route-lead-*.md' | wc -l)" "16" "immutable route roster count"
assert_has "$(cat "$ROUTE_AGENTS/route-lead-alpha-critical.md")" "model: fable[1m]" "immutable Fable route"
ok "immutable Claude lead route roster"

cat > "$HARNESS/bin/orch-model-guard" <<'CORE'
#!/usr/bin/env bash
state="${CC_ORCH_STATE_DIR:?}/state"; mkdir -p "$(dirname "$state")"
case "${1:-}" in
  check)
    cat > "$state" <<EOF2
active=sonnet[1m]
pinned=0
fable_pct=20
all_pct=30
session_pct=20
checked_at=$(date -Is)
changed_at=$(date -Is)
reason=test
EOF2
    ;;
  active) sed -n 's/^active=//p' "$state" 2>/dev/null || echo 'sonnet[1m]' ;;
  status) echo legacy-status ;;
  install|uninstall) : ;;
  set) echo set ;;
esac
CORE
chmod +x "$HARNESS/bin/orch-model-guard"

NOW=1800000000
claude_json="$(printf '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":%s},"seven_day":{"used_percentage":80,"resets_at":%s}}}' "$((NOW+9000))" "$((NOW+518400))")"
printf '%s' "$claude_json" | HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" "$HARNESS/bin/orch-model-guard-runtime" ingest-claude
budget="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  "$HARNESS/bin/orch-model-guard-runtime" budget)"
assert_has "$budget" "claude  tight" "aggressive weekly pace pressure"
route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  "$HARNESS/bin/orch-model-guard-runtime" route lead critical alpha)"
assert_has "$route" "agent_type=route-lead-alpha-normal" "exact immutable agent type"
assert_has "$route" "model=opus[1m]" "critical lead fallback model"
ok "Claude 5h/7d reset-aware lead routing"

CODEX_HOME_DIR="$TMP/codex"
DAY="$(date -d "@$NOW" +%Y/%m/%d)"
mkdir -p "$CODEX_HOME_DIR/sessions/$DAY"
cat > "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl" <<EOF2
{"event":{"rate_limits":{"primary":{"used_percent":90,"window_minutes":10080,"resets_at":$((NOW+518400))}}}}
EOF2
touch -d "@$NOW" "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl"
# Claude is healthy because the high percentages reset soon.
claude_json="$(printf '{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":%s},"seven_day":{"used_percentage":80,"resets_at":%s}}}' "$((NOW+300))" "$((NOW+86400))")"
printf '%s' "$claude_json" | HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" "$HARNESS/bin/orch-model-guard-runtime" ingest-claude
lanes="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" lanes)"
assert_has "$lanes" "dispatch=codex-first" "Codex stays first through tight pressure"
route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" route codex implement)"
assert_has "$route" "allow=1" "tight Codex implementation remains available"
assert_has "$route" "model=gpt-5.6-terra" "tight implementation model"
assert_not_has "$route" "gpt-6-astra" "tight implementation route unchanged"
route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" route codex review)"
assert_has "$route" "model=gpt-5.6-terra" "tight gate model"
ok "Codex weekly reset-aware provider and model routing"

cat > "$HARNESS/bin/codex-run" <<'CORE'
#!/usr/bin/env bash
printf '%s\n' "$*" "route=${CC_ORCH_CODEX_ROUTE:-}" > "${TEST_ARGS:?}"
CORE
chmod +x "$HARNESS/bin/codex-run"
TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" CODEX_HOME="$CODEX_HOME_DIR" \
  "$HARNESS/bin/codex-run-runtime" implement "$TMP" "$TMP" --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--model gpt-5.6-terra --effort high" "auto-routed tight implementation"
assert_has "$args_out" "--fast-mode" "Fast mode default on auto implementation"
assert_not_has "$args_out" "gpt-6-astra" "tight facade route unchanged"
TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" CODEX_HOME="$CODEX_HOME_DIR" \
  "$HARNESS/bin/codex-run-runtime" review "$TMP" "$TMP" --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--model gpt-5.6-terra --effort high" "auto-routed Codex review args"
assert_has "$args_out" "--fast-mode" "Fast mode default on auto review"
TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_CODEX_ROUTE= \
  "$HARNESS/bin/codex-run-runtime" review "$TMP" "$TMP" --model sol --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--model sol" "explicit Codex model wins"
assert_has "$args_out" "--fast-mode" "Fast mode layers onto explicit Sol"
TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  "$HARNESS/bin/codex-run-runtime" implement "$TMP" "$TMP" --mech --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--mech" "explicit Luna-compatible mechanical path preserved"
if printf '%s' "$args_out" | grep -q -- '--fast-mode'; then fail "--mech must not receive incompatible Fast mode"; fi
ok "codex-run facade keeps Fast mode on compatible calls"

# At the actual critical boundary provider-level sparing and non-gate withholding still protect
# the final independent review/verify reserve.
NOW2=$((NOW+120))
cat > "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl" <<EOF2
{"event":{"rate_limits":{"primary":{"used_percent":95,"window_minutes":10080,"resets_at":$((NOW+518400))}}}}
EOF2
touch -d "@$NOW2" "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl"
lanes="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW2" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" lanes)"
assert_has "$lanes" "dispatch=codex-sparing" "critical Codex pressure activates reserve"
route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW2" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" route codex implement)"
assert_has "$route" "allow=0" "critical implementation withheld"
ok "critical Codex reserve remains intact"

# Advancing past the refresh interval and lowering usage exercises the new healthy Astra rung.
NOW3=$((NOW2+120))
cat > "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl" <<EOF2
{"event":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":$((NOW+518400))}}}}
EOF2
touch -d "@$NOW3" "$CODEX_HOME_DIR/sessions/$DAY/rollout-test.jsonl"

for mode in implement investigate intake review plan-review verify; do
  route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW3" \
    CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" route codex "$mode")"
  assert_has "$route" "model=gpt-6-astra" "healthy $mode route model"
  if [ "$mode" = implement ]; then effort="xhigh"; else effort="high"; fi
  assert_has "$route" "effort=$effort" "healthy $mode route effort"

  case "$mode" in
    implement) args=(implement "$TMP" "$TMP" --dry-run) ;;
    investigate) args=(investigate "$TMP" "$TMP" "q" --dry-run) ;;
    intake) args=(intake "$TMP" "$TMP" "g" --dry-run) ;;
    review) args=(review "$TMP" "$TMP" --dry-run) ;;
    plan-review) args=(plan-review "$TMP" "$TMP" --dry-run) ;;
    verify) args=(verify "$TMP" "$TMP" --dry-run) ;;
  esac
  TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
    CC_ORCH_NOW_EPOCH="$NOW3" CODEX_HOME="$CODEX_HOME_DIR" \
    "$HARNESS/bin/codex-run-runtime" "${args[@]}"
  args_out="$(cat "$TMP/codex-args")"
  assert_has "$args_out" "--model gpt-6-astra --effort $effort" "healthy $mode facade args"
  assert_has "$args_out" "--fast-mode" "healthy $mode Fast default"
  assert_has "$args_out" "route=healthy:gpt-6-astra@$effort+fast-mode" "healthy $mode route marker"
done

TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW3" CODEX_HOME="$CODEX_HOME_DIR" \
  CC_ORCH_CODEX_ROUTE=healthy:gpt-6-astra@xhigh \
  "$HARNESS/bin/codex-run-runtime" review "$TMP" "$TMP" --model sol --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--model sol" "explicit healthy Codex model wins"
assert_has "$args_out" "--fast-mode" "explicit healthy Sol gets Fast default"
assert_eq "$(tail -1 "$TMP/codex-args")" "route=" "explicit path has no auto marker"

TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW3" CODEX_HOME="$CODEX_HOME_DIR" CC_ORCH_CODEX_ROUTE= \
  "$HARNESS/bin/codex-run-runtime" implement "$TMP" "$TMP" --mech --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_not_has "$args_out" "--fast-mode" "healthy mechanical path has no Fast mode"
assert_not_has "$args_out" "gpt-6-astra" "healthy mechanical path has no Astra"
ok "healthy Codex Astra routing and explicit marker isolation"

cat > "$HARNESS/bin/cc-orch" <<'CORE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_ARGS:?}"
CORE
chmod +x "$HARNESS/bin/cc-orch"
TEST_ARGS="$TMP/cc-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  "$HARNESS/bin/cc-orch-runtime" --profile critical demo "$TMP"
assert_eq "$(cat "$TMP/cc-args")" "--profile critical demo $TMP" "direct launcher compatibility"
ok "cc-orch facade preserves launcher semantics"

cat > "$TMP/home/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"printf old","padding":2}}
JSON
HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_SETTINGS="$TMP/home/.claude/settings.json" \
  "$HARNESS/bin/orch-model-guard-runtime" install >/dev/null
assert_has "$(cat "$TMP/home/.claude/settings.json")" "orch-statusline.sh" "status-line tap registration"
assert_has "$(cat "$TMP/state/statusline.previous.json")" "printf old" "status-line preservation"
HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_SETTINGS="$TMP/home/.claude/settings.json" \
  "$HARNESS/bin/orch-model-guard-runtime" uninstall >/dev/null
assert_has "$(cat "$TMP/home/.claude/settings.json")" "printf old" "status-line restore"
ok "Claude reset tap preserves existing status line"

context="$(printf '{"prompt_id":"runtime-test"}' | HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" CODEX_HOME="$CODEX_HOME_DIR" CC_ORCH_PROJECT=demo \
  "$HARNESS/hooks/orch-runtime-context.sh")"
printf '%s' "$context" | python3 -c 'import json,sys; json.load(sys.stdin)'
assert_has "$context" "no cc-orch reload is needed" "live routing hook context"
assert_has "$context" "route lead" "lead dispatch instruction"
ok "running sessions receive live policy without reload"

FAKEBIN="$TMP/fakebin"; TMUX_STATE="$TMP/tmux"; mkdir -p "$FAKEBIN" "$TMUX_STATE"
cat > "$FAKEBIN/tmux" <<'TMUX'
#!/usr/bin/env bash
set -u
root="${FAKE_TMUX_STATE:?}"; mkdir -p "$root"
cmd="$1"; shift
case "$cmd" in
  has-session)
    name=""; while [ $# -gt 0 ]; do [ "$1" = -t ] && { shift; name="$1"; }; shift || true; done
    [ -f "$root/$name" ] ;;
  new-session)
    name=""; cwd=""; command=""
    while [ $# -gt 0 ]; do
      case "$1" in -s) shift; name="$1" ;; -c) shift; cwd="$1" ;; -d) ;; *) command="$1" ;; esac
      shift || true
    done
    printf 'cwd=%s\ncmd=%s\n' "$cwd" "$command" > "$root/$name" ;;
  attach-session|switch-client|send-keys|list-windows|new-window|select-window) exit 0 ;;
  kill-session)
    name=""; while [ $# -gt 0 ]; do [ "$1" = -t ] && { shift; name="$1"; }; shift || true; done
    rm -f "$root/$name" ;;
  *) exit 2 ;;
esac
TMUX
chmod +x "$FAKEBIN/tmux"
PROJECT="$TMP/project"; mkdir "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name test
echo baseline > "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" commit -qm baseline
PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" "$HARNESS/bin/cc-orch-session" \
  new demo "$PROJECT" --no-attach --no-rc >/dev/null
list="$(PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" "$HARNESS/bin/cc-orch-session" list)"
assert_has "$list" "demo" "session registry"
assert_has "$list" "running" "tmux state detection"
PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" CC_ORCH_STOP_GRACE_SECONDS=0 \
  "$HARNESS/bin/cc-orch-session" stop demo >/dev/null
PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" "$HARNESS/bin/cc-orch-session" restart demo --no-attach >/dev/null
assert_has "$(cat "$TMUX_STATE/ccorch-demo")" "-c" "restarted launcher resumes Claude context"
PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" CC_ORCH_STOP_GRACE_SECONDS=0 \
  "$HARNESS/bin/cc-orch-session" stop demo >/dev/null
PATH="$FAKEBIN:$PATH" FAKE_TMUX_STATE="$TMUX_STATE" HOME="$TMP/home" \
  CC_ORCH_STATE_DIR="$TMP/session-state" "$HARNESS/bin/cc-orch-session" remove demo >/dev/null
[ ! -d "$TMP/session-state/worktrees/project/demo" ] || fail "worktree not removed"
git -C "$PROJECT" show-ref --verify --quiet refs/heads/orch/demo || fail "task branch should be kept"
ok "persistent tmux/worktree session lifecycle"

echo "PASS: $pass runtime test groups"
