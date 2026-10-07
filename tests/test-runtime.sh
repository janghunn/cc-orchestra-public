#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0 # Fake providers: no network or package mutation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' ($3)"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_not_has() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' ($3)"; }
route_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

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

# Resolve inherited PLAN_REVIEW values and check both policy rows in pressure order.
(
  source "$ROOT/budget-policy.conf"
  assert_eq "$CODEX_PRESSURE_PIN" healthy "shipped Codex pressure pin"
  assert_eq "$CODEX_PRESSURE_PIN_UNTIL" "" "shipped pin has no expiry"
  for review_mode in REVIEW PLAN_REVIEW; do
    previous_rank=6
    for pressure in HEALTHY WATCH TIGHT CRITICAL; do
      effort_var="CODEX_AUTO_${review_mode}_${pressure}_EFFORT"
      effort="${!effort_var}"
      case "$effort" in
        low) rank=0 ;;
        medium) rank=1 ;;
        high) rank=2 ;;
        xhigh) rank=3 ;;
        max) rank=4 ;;
        ultra) rank=5 ;;
        *) fail "unknown effort '$effort' ($effort_var)" ;;
      esac
      [ "$rank" -le "$previous_rank" ] || fail "$review_mode effort rises at $pressure ($effort)"
      previous_rank="$rank"
    done
  done
  assert_eq "$CODEX_AUTO_REVIEW_TIGHT_EFFORT" medium "tight review policy effort"
  assert_eq "$CODEX_AUTO_PLAN_REVIEW_TIGHT_EFFORT" medium "tight plan-review policy effort"
)
ok "review and plan-review effort never rises with Codex pressure"

HARNESS="$TMP/harness"
mkdir -p "$HARNESS/bin" "$HARNESS/hooks" "$HARNESS/lib" "$TMP/state" "$TMP/home/.claude"
cp "$ROOT/bin/cc-orch-runtime" "$ROOT/bin/cc-orch-session" "$ROOT/bin/orch-cli-update" "$ROOT/bin/codex-run-runtime" \
   "$ROOT/bin/orch-model-guard-runtime" "$HARNESS/bin/"
cp "$ROOT/hooks/orch-runtime-context.sh" "$ROOT/hooks/orch-statusline.sh" "$HARNESS/hooks/"
cp "$ROOT/budget-policy.conf" "$ROOT/build-roster-runtime.sh" "$HARNESS/"
# Existing fixtures must keep testing dynamic pressure even though the shipped pin is on.
cp "$HARNESS/budget-policy.conf" "$HARNESS/budget-policy.conf.repo"
set_codex_pin() {
  cp "$HARNESS/budget-policy.conf.repo" "$HARNESS/budget-policy.conf"
  printf '\nCODEX_PRESSURE_PIN=%q\nCODEX_PRESSURE_PIN_UNTIL=%q\n' "${1-}" "${2-}" >> "$HARNESS/budget-policy.conf"
}
set_codex_pin ""
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
CODEX_IMPL_MODEL="gpt-6.1-sol"; CODEX_IMPL_EFFORT="xhigh"
CODEX_INVESTIGATE_MODEL="gpt-6.1-sol"; CODEX_INVESTIGATE_EFFORT="high"
CODEX_INTAKE_MODEL="gpt-6.1-sol"; CODEX_INTAKE_EFFORT="high"
CODEX_REVIEW_MODEL="gpt-6.1-sol"; CODEX_REVIEW_EFFORT="high"
CODEX_VERIFY_MODEL="gpt-6.1-sol"; CODEX_VERIFY_EFFORT="high"
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

# A1 keeps the original Fable-backed critical fixture; B1 switches only that mapping to stock.
# Columns: case | pressure | Fable usage | active | pinned | kind | risk | deep | agent | model | effort.
while IFS='|' read -r case_id pressure fable active pinned kind risk deep expected_agent expected_model expected_effort; do
  if [ "$case_id" = B1 ]; then
    sed -i 's/^LEAD_CRITICAL_MODEL=.*/LEAD_CRITICAL_MODEL="opus[1m]"; LEAD_CRITICAL_EFFORT="xhigh"/' \
      "$HARNESS/model-policy.conf"
  fi
  case "$pressure" in
    healthy) five_pct=10; five_reset=$((NOW+9000)); week_pct=10; week_reset=$((NOW+86400)); limiting=five ;;
    watch) five_pct=70; five_reset=$((NOW+12000)); week_pct=10; week_reset=$((NOW+86400)); limiting=five ;;
    tight) five_pct=50; five_reset=$((NOW+9000)); week_pct=80; week_reset=$((NOW+518400)); limiting=week ;;
  esac
  claude_json="$(printf '{"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$five_pct" "$five_reset" "$week_pct" "$week_reset")"
  printf '%s' "$claude_json" | HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
    CC_ORCH_NOW_EPOCH="$NOW" "$HARNESS/bin/orch-model-guard-runtime" ingest-claude

  # Fresh ingest prevents the legacy check from replacing these independent Fable signals.
  # B4/B5 prove this file reaches the guard: high usage demotes deep, low usage preserves Fable.
  rm -f "$TMP/state/state"
  if [ "$fable" != - ]; then printf 'fable_pct=%s\n' "$fable" > "$TMP/state/state"; fi
  if [ "$active" != - ]; then
    printf 'active=%s\npinned=%s\n' "$active" "$pinned" >> "$TMP/state/state"
  fi
  budget="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
    "$HARNESS/bin/orch-model-guard-runtime" budget)"
  assert_eq "$(printf '%s\n' "$budget" | sed -n '/^claude  /p')" \
    "claude  $pressure (limiting: $limiting)" "$case_id pressure fixture"

  route_args=(route "$kind" "$risk")
  if [ "$kind" = lead ]; then
    if [ "$deep" = deep ]; then route_args+=(deep); fi
    route_args+=(alpha)
  fi
  route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
    "$HARNESS/bin/orch-model-guard-runtime" "${route_args[@]}")"
  if [ "$kind" = lead ]; then
    assert_eq "$(route_field "$route" agent_type)" "$expected_agent" "$case_id agent_type"
  fi
  assert_eq "$(route_field "$route" model)" "$expected_model" "$case_id model"
  assert_eq "$(route_field "$route" effort)" "$expected_effort" "$case_id effort"
done <<'CASES'
A1|healthy|90|-|-|lead|critical|-|route-lead-alpha-normal|opus[1m]|high
B1|watch|-|-|-|lead|critical|-|route-lead-alpha-critical|opus[1m]|xhigh
B2|tight|-|-|-|lead|critical|-|route-lead-alpha-normal|opus[1m]|high
B3|healthy|90|-|-|lead|critical|-|route-lead-alpha-critical|opus[1m]|xhigh
B4|healthy|90|-|-|lead|critical|deep|route-lead-alpha-normal|opus[1m]|high
B5|healthy|10|-|-|lead|critical|deep|route-lead-alpha-critical-xhigh|fable[1m]|xhigh
B6|healthy|-|opus[1m]|0|lead|critical|-|route-lead-alpha-critical|opus[1m]|xhigh
B7|healthy|-|opus[1m]|0|lead|critical|deep|route-lead-alpha-normal|opus[1m]|high
B8|watch|-|-|-|lead|normal|-|route-lead-alpha-normal|opus[1m]|high
B9|watch|90|-|-|lead|critical|deep|route-lead-alpha-critical|opus[1m]|xhigh
B10|watch|-|-|-|orchestrator|critical|-|-|opus[1m]|xhigh
B11|watch|90|-|-|orchestrator|deep|-|-|opus[1m]|xhigh
CASES
rm -f "$TMP/state/state"
ok "critical pressure table and model-keyed Fable guards"

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
assert_has "$route" "model=gpt-6.1-sol" "tight implementation model"
assert_not_has "$route" "gpt-6-astra" "tight implementation route unchanged"
route="$(HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" CC_ORCH_NOW_EPOCH="$NOW" \
  CODEX_HOME="$CODEX_HOME_DIR" "$HARNESS/bin/orch-model-guard-runtime" route codex review)"
assert_has "$route" "model=gpt-6.1-sol" "tight gate model"
assert_eq "$(route_field "$route" effort)" medium "tight gate effort"
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
assert_has "$args_out" "--model gpt-6.1-sol --effort high" "auto-routed tight implementation"
assert_has "$args_out" "--fast-mode" "Fast mode default on auto implementation"
assert_not_has "$args_out" "gpt-6-astra" "tight facade route unchanged"
TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
  CC_ORCH_NOW_EPOCH="$NOW" CODEX_HOME="$CODEX_HOME_DIR" \
  "$HARNESS/bin/codex-run-runtime" review "$TMP" "$TMP" --dry-run
args_out="$(cat "$TMP/codex-args")"
assert_has "$args_out" "--model gpt-6.1-sol --effort medium" "auto-routed Codex review args"
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
if grep -q -- '--fast-mode' <<<"$args_out"; then fail "--mech must not receive incompatible Fast mode"; fi
for model in gpt-6-luna luna gpt-6-sol gpt-6.1-sol sol; do
  TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
    CC_ORCH_ALWAYS_FAST_MODE=1 CC_ORCH_CODEX_ROUTE= \
    "$HARNESS/bin/codex-run-runtime" implement "$TMP" "$TMP" --model "$model" --dry-run
  args_out="$(cat "$TMP/codex-args")"
  assert_has "$args_out" "--model $model" "facade preserves explicit $model"
  if [ "$model" = gpt-6-sol ] || [ "$model" = gpt-6.1-sol ] || [ "$model" = sol ]; then
    assert_has "$args_out" "--fast-mode" "Fast mode for explicit $model"
  else
    assert_not_has "$args_out" "--fast-mode" "no Fast mode for explicit $model"
  fi
done
RESUME_TASK="$TMP/resume-task"
mkdir -p "$RESUME_TASK"
for model in gpt-6-sol gpt-6.1-sol gpt-5.6-sol gpt-6-luna; do
  effort=xhigh
  if [ "$model" = gpt-6-luna ]; then effort=medium; fi
  printf 'implement=00000000-0000-4000-8000-0000000000aa|%s|%s\n' "$model" "$effort" > "$RESUME_TASK/.codex-session"
  TEST_ARGS="$TMP/codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$TMP/state" \
    CC_ORCH_ALWAYS_FAST_MODE=1 CC_ORCH_CODEX_ROUTE= \
    "$HARNESS/bin/codex-run-runtime" resume "$TMP" "$RESUME_TASK" "follow up" --dry-run
  args_out="$(cat "$TMP/codex-args")"
  if [ "$model" = gpt-6-luna ]; then
    assert_not_has "$args_out" "--fast-mode" "no Fast mode when resuming $model"
  else
    assert_has "$args_out" "--fast-mode" "Fast mode when resuming $model"
  fi
done
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

# Independent cache and rollout fixtures keep the earlier pressure clocks untouched.
PIN_STATE="$TMP/pin-state"; PIN_CODEX="$TMP/pin-codex"
PIN_NOW=$((NOW3+120))
mkdir -p "$PIN_STATE" "$PIN_CODEX/sessions/$DAY"
pin_guard() {
  HOME="$TMP/home" CC_ORCH_STATE_DIR="$PIN_STATE" CC_ORCH_NOW_EPOCH="$PIN_NOW" \
    CODEX_HOME="$PIN_CODEX" "$HARNESS/bin/orch-model-guard-runtime" "$@"
}
# As in the original Codex fixture, Claude is healthy because its high usage resets soon.
printf '%s' "$claude_json" | pin_guard ingest-claude
for real_state in watch tight critical; do
  case "$real_state" in watch) pct=70 ;; tight) pct=90 ;; critical) pct=95 ;; esac
  cat > "$PIN_CODEX/sessions/$DAY/rollout-pin.jsonl" <<EOF2
{"event":{"rate_limits":{"primary":{"used_percent":$pct,"window_minutes":10080,"resets_at":$((NOW+518400))}}}}
EOF2
  touch -d "@$PIN_NOW" "$PIN_CODEX/sessions/$DAY/rollout-pin.jsonl"
  set_codex_pin healthy
  for mode in implement investigate intake review plan-review verify; do
    route="$(pin_guard route codex "$mode")"
    if [ "$mode" = implement ]; then effort=xhigh; else effort=high; fi
    assert_eq "$(route_field "$route" model)" gpt-6-astra "pinned $real_state $mode model"
    assert_eq "$(route_field "$route" effort)" "$effort" "pinned $real_state $mode effort"
    assert_eq "$(route_field "$route" allow)" 1 "pinned $real_state $mode available"
    assert_eq "$(route_field "$route" pressure)" healthy "pinned pressure stays a bare tier"
    assert_has "$(route_field "$route" reason)" pinned "pinned $real_state $mode reason"
    assert_has "$(route_field "$route" reason)" "real=$real_state" "real $mode pressure visible"
  done
  assert_eq "$(sed -n 's/^codex_state=//p' "$PIN_STATE/budget-state")" "$real_state" "recorded real pressure"
  compact="$(pin_guard budget --compact)"
  assert_has "$compact" "codex=healthy(pinned; real=$real_state, 7d:$pct%/" "compact pin marker"
  assert_eq "$(printf '%s\n' "$compact" | wc -l)" 1 "compact stays one line"
  budget="$(pin_guard budget)"
  header="$(printf '%s\n' "$budget" | sed -n '/^codex   /p')"
  assert_has "$header" pinned "Codex budget header pin marker"
  assert_has "$header" "real=$real_state" "Codex budget header real pressure"
  lanes="$(pin_guard lanes)"
  assert_eq "$(printf '%s\n' "$lanes" | head -1)" dispatch=codex-first "pinned dispatch first line"
  assert_has "$lanes" "pressure=healthy(pinned; real=$real_state)" "lanes real pressure"
  assert_has "$(printf '%s\n' "$lanes" | sed -n '/^reason:/p')" pinned "lanes pin reason"

  if [ "$real_state" = watch ]; then
    context="$(printf '{"prompt_id":"pin-test"}' | HOME="$TMP/home" CC_ORCH_STATE_DIR="$PIN_STATE" \
      CC_ORCH_NOW_EPOCH="$PIN_NOW" CODEX_HOME="$PIN_CODEX" CC_ORCH_PROJECT=demo \
      "$HARNESS/hooks/orch-runtime-context.sh")"
    printf '%s' "$context" | python3 -c '
import json, sys
context = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "\n" not in context
assert "codex=healthy(pinned; real=watch," in context
'
  fi
  if [ "$real_state" = critical ]; then
    pinned_lead="$(pin_guard route lead normal)"
    TEST_ARGS="$TMP/pin-codex-args" HOME="$TMP/home" CC_ORCH_STATE_DIR="$PIN_STATE" \
      CC_ORCH_NOW_EPOCH="$PIN_NOW" CODEX_HOME="$PIN_CODEX" \
      "$HARNESS/bin/codex-run-runtime" implement "$TMP" "$TMP" --model sol --effort low --dry-run
    assert_has "$(cat "$TMP/pin-codex-args")" "--model sol --effort low" "explicit flags beat critical pin"
  fi

  set_codex_pin ""
  for mode in implement investigate intake review plan-review verify; do
    route="$(pin_guard route codex "$mode")"
    expected="$(
      source "$ROOT/budget-policy.conf"
      upper_mode="${mode^^}"; upper_mode="${upper_mode//-/_}"
      prefix="CODEX_AUTO_${upper_mode}_${real_state^^}"
      model_var="${prefix}_MODEL"; effort_var="${prefix}_EFFORT"; allow_var="${prefix}_ALLOW"
      printf '%s|%s|%s' "${!model_var}" "${!effort_var}" "${!allow_var:-1}"
    )"
    assert_eq "$(route_field "$route" model)|$(route_field "$route" effort)|$(route_field "$route" allow)" \
      "$expected" "empty pin dynamic $real_state $mode row"
    assert_eq "$(route_field "$route" pressure)" "$real_state" "empty pin real pressure"
    assert_not_has "$route" pinned "empty pin route marker absent"
  done
  if [ "$real_state" = critical ]; then
    assert_eq "$(pin_guard route lead normal)" "$pinned_lead" "Claude route unaffected by Codex pin"
    assert_eq "$(pin_guard lanes | sed -n '1p')" dispatch=codex-sparing "empty pin restores reserve"
  fi
  # Compare files so every output byte, including trailing newlines, is checked.
  pin_guard route codex implement > "$TMP/pin-empty-route"
  pin_guard lanes > "$TMP/pin-empty-lanes"
  pin_guard budget > "$TMP/pin-empty-budget"
  pin_guard budget --compact > "$TMP/pin-empty-compact"
  for output in route lanes budget compact; do
    assert_not_has "$(cat "$TMP/pin-empty-$output")" pinned "empty pin $output marker absent"
  done
  grep -v '^CODEX_PRESSURE_PIN' "$HARNESS/budget-policy.conf.repo" > "$HARNESS/budget-policy.conf"
  pin_guard route codex implement > "$TMP/pin-unset-route"
  pin_guard lanes > "$TMP/pin-unset-lanes"
  pin_guard budget > "$TMP/pin-unset-budget"
  pin_guard budget --compact > "$TMP/pin-unset-compact"
  for output in route lanes budget compact; do
    cmp "$TMP/pin-empty-$output" "$TMP/pin-unset-$output" || fail "empty != unset ($real_state $output)"
  done
  PIN_NOW=$((PIN_NOW+120))
done

# Invalid and expired pins leave the critical reserve in force.
for invalid_pin in watch HEALTHY ' healthy'; do
  set_codex_pin "$invalid_pin"
  route="$(pin_guard route codex implement 2> "$TMP/pin-stderr")"
  assert_eq "$(route_field "$route" allow)" 0 "invalid pin restores dynamic route"
  assert_has "$(cat "$TMP/pin-stderr")" CODEX_PRESSURE_PIN "invalid pin warning"
  assert_not_has "$route" pinned "invalid pin stdout stays dynamic"
  assert_eq "$(pin_guard lanes 2>/dev/null | sed -n '1p')" dispatch=codex-sparing "invalid pin dispatch"
  budget="$(pin_guard budget 2> "$TMP/pin-stderr")"
  assert_has "$budget" "  pin   ignored:" "invalid pin full budget note"
  assert_eq "$(wc -l < "$TMP/pin-stderr")" 1 "invalid pin warns once despite two metric loads"
done
for invalid_until in not-a-date tomorrow '2026-02-30'; do
  set_codex_pin healthy "$invalid_until"
  route="$(pin_guard route codex implement 2> "$TMP/pin-stderr")"
  assert_eq "$(route_field "$route" allow)" 0 "invalid expiry restores dynamic route"
  assert_has "$(cat "$TMP/pin-stderr")" CODEX_PRESSURE_PIN_UNTIL "invalid expiry warning"
  assert_not_has "$route" pinned "invalid expiry stdout stays dynamic"
  assert_eq "$(pin_guard lanes 2>/dev/null | sed -n '1p')" dispatch=codex-sparing "invalid expiry dispatch"
done
for expired_until in "$((PIN_NOW-1))" "$(date -u -d "@$((PIN_NOW-86400))" '+%Y-%m-%d %H:%M')" "$PIN_NOW"; do
  set_codex_pin healthy "$expired_until"
  route="$(TZ=UTC pin_guard route codex implement 2> "$TMP/pin-stderr")"
  assert_eq "$(route_field "$route" allow)" 0 "expired pin restores dynamic route"
  assert_eq "$(cat "$TMP/pin-stderr")" "" "expired pin is silent on stderr"
  assert_not_has "$route" pinned "expired pin stdout stays dynamic"
  assert_eq "$(TZ=UTC pin_guard lanes | sed -n '1p')" dispatch=codex-sparing "expired pin dispatch"
  assert_has "$(TZ=UTC pin_guard budget)" expired "expired pin budget note"
done
for future_until in "$((PIN_NOW+86400))" "$(date -u -d "@$((PIN_NOW+86400))" '+%Y-%m-%dT%H:%M:%S')"; do
  set_codex_pin healthy "$future_until"
  route="$(TZ=UTC pin_guard route codex implement)"
  assert_eq "$(route_field "$route" model)" gpt-6-astra "future expiry stays pinned"
  assert_eq "$(route_field "$route" effort)" xhigh "future pin healthy effort"
  assert_eq "$(route_field "$route" allow)" 1 "future pin allows implementation"
  assert_eq "$(route_field "$route" pressure)" healthy "future pin pressure"
  assert_has "$route" pin-until= "route pin expiry visible"
  assert_has "$(TZ=UTC pin_guard budget | sed -n '/^codex   /p')" '; until ' "budget pin expiry visible"
done
# A custom reserve boundary must never let real Codex pressure override an active pin.
set_codex_pin healthy
printf '\nBUDGET_CODEX_SPARING_MIN_RANK=0\n' >> "$HARNESS/budget-policy.conf"
assert_eq "$(pin_guard lanes | sed -n '1p')" dispatch=codex-first "pin overrides custom sparing boundary"
set_codex_pin ""
printf '\nBUDGET_CODEX_SPARING_MIN_RANK=0\n' >> "$HARNESS/budget-policy.conf"
assert_eq "$(pin_guard lanes | sed -n '1p')" dispatch=codex-sparing "empty pin honors custom sparing boundary"
set_codex_pin ""
ok "Codex pressure pin preserves real metrics, visibility, expiry and explicit overrides"

# Exercise both real entry points with an offline snapshot and independent budget cache.
(
  PARITY_DIR="$(mktemp -d "$TMP/lanes-parity.XXXXXX")"
  PARITY_HARNESS="$PARITY_DIR/harness"
  PARITY_NOW="$(date +%s)"
  mkdir -p "$PARITY_HARNESS/bin" "$PARITY_HARNESS/lib" "$PARITY_DIR/state" \
    "$PARITY_DIR/codex/sessions" "$PARITY_DIR/home" "$PARITY_DIR/agents"
  cp "$ROOT/bin/orch-model-guard" "$ROOT/bin/orch-model-guard-runtime" "$PARITY_HARNESS/bin/"
  cp "$ROOT/model-policy.conf" "$ROOT/budget-policy.conf" "$PARITY_HARNESS/"
  cp "$ROOT/lib/orch-budget-state.sh" "$ROOT/lib/orch-budget-metrics.sh" \
    "$ROOT/lib/orch-budget-commands.sh" "$PARITY_HARNESS/lib/"
  printf '#!/bin/sh\nexit 1\n' > "$PARITY_DIR/claude"
  chmod +x "$PARITY_DIR/claude"
  cat > "$PARITY_DIR/state/last-usage.txt" <<'PANEL'
Current session: 10% used
Current week (all models): 10% used
Current week (Fable): 10% used
PANEL
  unset CODEX_PRESSURE_PIN CODEX_PRESSURE_PIN_UNTIL
  parity_guard() {
    local entry="$1"; shift
    HOME="$PARITY_DIR/home" CC_ORCH_STATE_DIR="$PARITY_DIR/state" \
      CC_ORCH_AGENTS_DIR="$PARITY_DIR/agents" CODEX_HOME="$PARITY_DIR/codex" \
      CLAUDE_BIN="$PARITY_DIR/claude" CC_ORCH_NOW_EPOCH="$PARITY_NOW" \
      CC_ORCH_BACKEND=claude TZ=UTC "$PARITY_HARNESS/bin/$entry" "$@"
  }
  parity_case() {
    local pin_case="$1" pct="$2" pin="" until="" expected=codex-first legacy runtime
    case "$pin_case" in
      unset) ;;
      healthy) pin=healthy ;;
      invalid) pin=watch ;;
      expired) pin=healthy; until=$((PARITY_NOW-1)) ;;
      future) pin=healthy; until=$((PARITY_NOW+86400)) ;;
      invalid-until) pin=healthy; until=not-a-date ;;
    esac
    grep -v '^CODEX_PRESSURE_PIN' "$ROOT/budget-policy.conf" > "$PARITY_HARNESS/budget-policy.conf"
    if [ "$pin_case" != unset ]; then
      printf '\nCODEX_PRESSURE_PIN=%q\nCODEX_PRESSURE_PIN_UNTIL=%q\n' "$pin" "$until" \
        >> "$PARITY_HARNESS/budget-policy.conf"
    fi
    rm -f "$PARITY_DIR/state/budget-state"
    printf '{"rate_limits":{"primary":{"used_percent":%s,"resets_at":%s}}}\n' \
      "$pct" "$((PARITY_NOW+518400))" > "$PARITY_DIR/codex/sessions/rollout-parity.jsonl"
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s}}}\n' \
      "$((PARITY_NOW+9000))" "$((PARITY_NOW+518400))" | parity_guard orch-model-guard-runtime ingest-claude
    parity_guard orch-model-guard lanes > "$PARITY_DIR/legacy.out" 2> "$PARITY_DIR/legacy.err"
    parity_guard orch-model-guard-runtime lanes > "$PARITY_DIR/runtime.out" 2> "$PARITY_DIR/runtime.err"
    legacy="$(cat "$PARITY_DIR/legacy.out")"; runtime="$(cat "$PARITY_DIR/runtime.out")"
    if [ "$pct" = 95 ] && [ "$pin_case" != healthy ] && [ "$pin_case" != future ]; then
      expected=codex-sparing
    fi
    assert_eq "$(printf '%s\n' "$legacy" | head -1)" "dispatch=$expected" "$pin_case $pct legacy dispatch"
    assert_eq "$(printf '%s\n' "$legacy" | head -1)" "$(printf '%s\n' "$runtime" | head -1)" \
      "$pin_case $pct legacy/runtime dispatch parity"
    assert_eq "$(wc -l < "$PARITY_DIR/legacy.out")" 4 "$pin_case $pct legacy output shape"
    assert_has "$legacy" "week=$pct%" "$pin_case legacy real usage"
    cmp "$PARITY_DIR/legacy.err" "$PARITY_DIR/runtime.err" || fail "$pin_case $pct warning parity"
    case "$pin_case" in
      healthy|future)
        assert_has "$legacy" "pressure=healthy(pinned; real=week $pct%)" "$pin_case legacy pin marker"
        assert_has "$legacy" "; Codex pressure pinned to healthy by CODEX_PRESSURE_PIN (real week=$pct%), so Codex pressure cannot trigger codex-sparing" \
          "$pin_case legacy pin reason"
        ;;
      *) assert_not_has "$legacy" pinned "$pin_case legacy remains dynamic" ;;
    esac
    case "$pin_case" in
      invalid) assert_has "$(cat "$PARITY_DIR/legacy.err")" "CODEX_PRESSURE_PIN='watch' is not supported" "legacy invalid pin warning" ;;
      invalid-until) assert_has "$(cat "$PARITY_DIR/legacy.err")" "is not an epoch or date" "legacy invalid expiry warning" ;;
      *) assert_eq "$(cat "$PARITY_DIR/legacy.err")" "" "$pin_case legacy pin is silent" ;;
    esac
  }
  for pin_case in unset healthy invalid expired; do
    for pct in 95 10; do parity_case "$pin_case" "$pct"; done
  done
  parity_case future 95
  parity_case invalid-until 95

  table_case() {
    local pin_case="$1" pct="$2" days="$3" expected="$4" pin="" until="" legacy runtime
    case "$pin_case" in
      unset) ;;
      healthy) pin=healthy ;;
      invalid) pin=watch ;;
      expired) pin=healthy; until=$((PARITY_NOW-1)) ;;
    esac
    grep -v '^CODEX_PRESSURE_PIN' "$ROOT/budget-policy.conf" > "$PARITY_HARNESS/budget-policy.conf"
    if [ "$pin_case" != unset ]; then
      printf '\nCODEX_PRESSURE_PIN=%q\nCODEX_PRESSURE_PIN_UNTIL=%q\n' "$pin" "$until" \
        >> "$PARITY_HARNESS/budget-policy.conf"
    fi
    rm -f "$PARITY_DIR/state/budget-state"
    printf '{"rate_limits":{"primary":{"used_percent":%s,"resets_at":%s}}}\n' \
      "$pct" "$((PARITY_NOW+days*86400))" > "$PARITY_DIR/codex/sessions/rollout-parity.jsonl"
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s}}}\n' \
      "$((PARITY_NOW+9000))" "$((PARITY_NOW+518400))" | parity_guard orch-model-guard-runtime ingest-claude
    parity_guard orch-model-guard lanes > "$PARITY_DIR/legacy.out" 2> "$PARITY_DIR/legacy.err"
    parity_guard orch-model-guard-runtime lanes > "$PARITY_DIR/runtime.out" 2> "$PARITY_DIR/runtime.err"
    legacy="$(cat "$PARITY_DIR/legacy.out")"; runtime="$(cat "$PARITY_DIR/runtime.out")"
    assert_eq "$(printf '%s\n' "$legacy" | head -1)" "dispatch=$expected" "$pin_case $pct $days-day legacy dispatch"
    assert_eq "$(printf '%s\n' "$legacy" | head -1)" "$(printf '%s\n' "$runtime" | head -1)" \
      "$pin_case $pct $days-day legacy/runtime dispatch parity"
    assert_eq "$(wc -l < "$PARITY_DIR/legacy.out")" 4 "$pin_case $pct $days-day legacy output shape"
    assert_has "$legacy" "week=$pct%" "$pin_case $pct $days-day legacy real usage"
    cmp "$PARITY_DIR/legacy.err" "$PARITY_DIR/runtime.err" || fail "$pin_case $pct $days-day warning parity"
    if [ "$pin_case" = healthy ]; then
      assert_has "$legacy" "pressure=healthy(pinned; real=week $pct%)" "$pin_case $pct $days-day legacy pin marker"
    else
      assert_not_has "$legacy" pinned "$pin_case $pct $days-day legacy remains dynamic"
    fi
  }
  for pin_case in unset healthy invalid expired; do
    for pct in 10 89 90 94; do
      for days in 1 6; do
        # Runtime is sparing only at 94% with six days remaining and no active pin.
        expected=codex-first
        if [ "$pin_case" != healthy ] && [ "$pct" = 94 ] && [ "$days" = 6 ]; then
          expected=codex-sparing
        fi
        table_case "$pin_case" "$pct" "$days" "$expected"
      done
    done
  done

  # parity_guard intentionally fixes the Claude backend; exercise Codex-only mode explicitly.
  for entry in orch-model-guard orch-model-guard-runtime; do
    HOME="$PARITY_DIR/home" CC_ORCH_STATE_DIR="$PARITY_DIR/state" \
      CC_ORCH_AGENTS_DIR="$PARITY_DIR/agents" CODEX_HOME="$PARITY_DIR/codex" \
      CLAUDE_BIN="$PARITY_DIR/claude" CC_ORCH_NOW_EPOCH="$PARITY_NOW" \
      CC_ORCH_BACKEND=codex TZ=UTC "$PARITY_HARNESS/bin/$entry" lanes > "$PARITY_DIR/$entry.codex.out"
  done
  legacy="$(cat "$PARITY_DIR/orch-model-guard.codex.out")"
  runtime="$(cat "$PARITY_DIR/orch-model-guard-runtime.codex.out")"
  assert_eq "$(printf '%s\n' "$legacy" | head -1)" dispatch=codex-first "Codex-only legacy dispatch"
  assert_eq "$(printf '%s\n' "$legacy" | head -1)" "$(printf '%s\n' "$runtime" | head -1)" \
    "Codex-only legacy/runtime dispatch parity"
  assert_eq "$(wc -l < "$PARITY_DIR/orch-model-guard.codex.out")" 4 "Codex-only legacy output shape"
  assert_has "$(printf '%s\n' "$legacy" | sed -n '/^reason: /p')" Astra-only "Codex-only legacy reason"

  cp "$PARITY_HARNESS/bin/orch-model-guard-runtime" "$PARITY_DIR/runtime.real"
  for stub_case in bad-dispatch nonzero success; do
    case "$stub_case" in
      bad-dispatch)
        cat > "$PARITY_HARNESS/bin/orch-model-guard-runtime" <<'STUB'
#!/usr/bin/env bash
echo dispatch=bogus
exit 0
STUB
        ;;
      nonzero)
        cat > "$PARITY_HARNESS/bin/orch-model-guard-runtime" <<'STUB'
#!/usr/bin/env bash
echo dispatch=codex-sparing
echo stub-error >&2
exit 3
STUB
        ;;
      success)
        cat > "$PARITY_HARNESS/bin/orch-model-guard-runtime" <<'STUB'
#!/usr/bin/env bash
echo dispatch=codex-sparing
echo 'reason: stub-reason'
echo stub-warning >&2
exit 0
STUB
        ;;
    esac
    parity_guard orch-model-guard lanes > "$PARITY_DIR/legacy.out" 2> "$PARITY_DIR/legacy.err"
    legacy="$(cat "$PARITY_DIR/legacy.out")"
    assert_eq "$(wc -l < "$PARITY_DIR/legacy.out")" 4 "$stub_case adapter output shape"
    if [ "$stub_case" = success ]; then
      assert_eq "$(printf '%s\n' "$legacy" | head -1)" dispatch=codex-sparing "adapter accepts runtime dispatch"
      assert_eq "$(printf '%s\n' "$legacy" | sed -n '/^reason: /p')" 'reason: stub-reason' "adapter forwards runtime reason"
      printf 'stub-warning\n' > "$PARITY_DIR/expected.err"
      cmp "$PARITY_DIR/legacy.err" "$PARITY_DIR/expected.err" || fail "adapter forwards runtime stderr verbatim"
    else
      assert_eq "$(printf '%s\n' "$legacy" | head -1)" dispatch=codex-first "$stub_case adapter fallback dispatch"
      assert_has "$legacy" "runtime lanes unavailable" "$stub_case adapter fallback reason"
      assert_eq "$(cat "$PARITY_DIR/legacy.err")" "" "$stub_case adapter discards runtime stderr"
    fi
  done
  mv "$PARITY_DIR/runtime.real" "$PARITY_HARNESS/bin/orch-model-guard-runtime"

  ! grep -q 'LANES_CODEX_SPARE_PCT' "$ROOT/bin/orch-model-guard" || fail "legacy keeps its own rule"
  ! grep -q 'resolve_codex_pin' "$ROOT/bin/orch-model-guard" || fail "legacy keeps its own rule"

  # An incomplete old installation must still support legacy lanes under nounset.
  printf '\nCODEX_PRESSURE_PIN=healthy\nCODEX_PRESSURE_PIN_UNTIL=""\n' >> "$PARITY_HARNESS/budget-policy.conf"
  rm "$PARITY_HARNESS/lib/orch-budget-metrics.sh"
  legacy="$(parity_guard orch-model-guard lanes 2> "$PARITY_DIR/legacy.err")"
  assert_eq "$(printf '%s\n' "$legacy" | head -1)" dispatch=codex-first "missing runtime library falls back to codex-first"
  assert_has "$legacy" "runtime lanes unavailable" "missing runtime library reason"
  assert_eq "$(cat "$PARITY_DIR/legacy.err")" "" "missing pin library has no nounset error"
  assert_not_has "$legacy" pinned "missing pin library leaves pin inactive"
)
ok "legacy/runtime lanes pin parity, validation, real usage and missing-library fallback"

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
