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
assert_not_has() { ! printf '%s' "$1" | grep -qF -- "$2" || fail "unexpected '$2' ($3)"; }

for script in "$ROOT/build-roster.sh" "$ROOT/install.sh" "$ROOT/bin/cc-orch" "$ROOT/bin/codex-run" "$ROOT/bin/codex-run-runtime" "$ROOT/bin/orch-model-guard" "$ROOT/bin/orch-policy-rev" "$ROOT/bin/orch-summary-check" "$ROOT/bin/orch-usage-report" "$ROOT/hooks/orch-model-notice.sh" "$ROOT/lib/codex-catalog.sh"
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

CAT_ASTRA="$TMP/cat-astra"
CAT_NOASTRA="$TMP/cat-noastra"
CAT_LIMITED="$TMP/cat-limited"
mkdir -p "$CAT_ASTRA" "$CAT_NOASTRA" "$CAT_LIMITED"
cat > "$CAT_ASTRA/models_cache.json" <<'JSON'
{"fetched_at":"2026-09-04T08:00:00Z","models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-sol","supported_reasoning_levels":[{"effort":"ultra"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-terra","supported_reasoning_levels":[{"effort":"ultra"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"max"}],"additional_speed_tiers":["fast"]}]}
JSON
cat > "$CAT_NOASTRA/models_cache.json" <<'JSON'
{"fetched_at":"2026-09-04T08:00:00Z","models":[{"slug":"gpt-5.6-sol","supported_reasoning_levels":[{"effort":"ultra"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-terra","supported_reasoning_levels":[{"effort":"ultra"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"max"}],"additional_speed_tiers":["fast"]}]}
JSON
cat > "$CAT_LIMITED/models_cache.json" <<'JSON'
{"fetched_at":"2026-09-04T08:00:00Z","models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"additional_speed_tiers":[]}]}
JSON

run_astra_dry() {
  local catalog="$1" route="$2"
  shift 2
  PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" CODEX_HOME="$catalog" \
    CC_ORCH_CODEX_ROUTE="$route" "$ROOT/bin/codex-run" "$@" --model astra --dry-run 2>&1
}

out="$(run_astra_dry "$CAT_ASTRA" "" implement "$WORK" "$TASK" --fast-mode)"
assert_has "$out" "gpt-6-astra" "explicit Astra alias"
assert_has "$out" "service_tier=" "explicit Astra Fast service tier"
assert_has "$out" "features.fast_mode=true" "explicit Astra Fast feature"
out="$(run_astra_dry "$CAT_ASTRA" "" implement "$WORK" "$TASK" --effort ultra)"
assert_has "$out" "model_reasoning_effort=ultra" "catalog-supported Astra ultra"

set +e
out="$(run_astra_dry "$CAT_NOASTRA" "" implement "$WORK" "$TASK")"
rc=$?
set -e
assert_eq "$rc" "6" "explicit unavailable Astra exit"
assert_has "$out" "MODEL_UNAVAILABLE" "explicit unavailable Astra classification"
assert_has "$out" "gpt-6-astra" "explicit unavailable Astra name"
assert_not_has "$out" "CODEX-RUN: FAILED" "explicit unavailable Astra is specific"
assert_not_has "$out" "MODEL_FALLBACK" "explicit unavailable Astra is not substituted"

set +e
out="$(run_astra_dry "$CAT_NOASTRA" "healthy:gpt-5.6-sol@xhigh" implement "$WORK" "$TASK")"
rc=$?
set -e
assert_eq "$rc" "6" "marker for another model is not an Astra auto-route"
assert_has "$out" "MODEL_UNAVAILABLE" "mismatched marker keeps explicit Astra classification"
assert_not_has "$out" "MODEL_FALLBACK" "mismatched marker cannot enable Astra fallback"

for mode in implement investigate intake review plan-review verify; do
  case "$mode" in
    implement) args=(implement "$WORK" "$TASK"); fallback="gpt-5.6-sol"; effort="xhigh" ;;
    investigate) args=(investigate "$WORK" "$TASK" "q"); fallback="gpt-5.6-sol"; effort="high" ;;
    intake) args=(intake "$WORK" "$TASK" "g"); fallback="gpt-5.6-terra"; effort="high" ;;
    review) args=(review "$WORK" "$TASK" --base main); fallback="gpt-5.6-sol"; effort="high" ;;
    plan-review) args=(plan-review "$WORK" "$TASK"); fallback="gpt-5.6-sol"; effort="high" ;;
    verify) args=(verify "$WORK" "$TASK"); fallback="gpt-5.6-terra"; effort="high" ;;
  esac
  out="$(run_astra_dry "$CAT_NOASTRA" "healthy:gpt-6-astra@$effort" "${args[@]}")"
  assert_has "$out" "MODEL_FALLBACK" "$mode unavailable Astra fallback warning"
  assert_has "$out" "gpt-6-astra" "$mode unavailable Astra source"
  assert_has "$out" "$fallback" "$mode lane fallback model"
  assert_has "$out" "model_reasoning_effort=$effort" "$mode lane fallback effort"
done

set +e
out="$(run_astra_dry "$CAT_LIMITED" "" implement "$WORK" "$TASK" --effort ultra)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "limited Astra ultra should be rejected"
assert_has "$out" "ultra" "limited Astra effort error"
set +e
out="$(run_astra_dry "$CAT_LIMITED" "" investigate "$WORK" "$TASK" "q" --fast-mode)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "limited Astra Fast should be rejected"
assert_has "$out" "Fast" "limited Astra Fast error"
out="$(run_astra_dry "$CAT_LIMITED" "healthy:gpt-6-astra@xhigh+fast-mode" implement "$WORK" "$TASK" --fast-mode)"
assert_has "$out" "gpt-5.6-sol" "limited Astra auto fallback model"
assert_has "$out" "MODEL_FALLBACK" "limited Astra auto fallback warning"
assert_has "$out" "service_tier=" "limited Astra fallback preserves Fast"

out="$(run_astra_dry "$TMP/no-codex-home" "" implement "$WORK" "$TASK")"
assert_has "$out" "gpt-6-astra" "missing catalog fails open explicitly"
assert_not_has "$out" "MODEL_FALLBACK" "missing catalog has no preflight fallback"
out="$(run_astra_dry "$TMP/no-codex-home" "healthy:gpt-6-astra@xhigh" implement "$WORK" "$TASK")"
assert_has "$out" "gpt-6-astra" "missing catalog fails open automatically"
assert_not_has "$out" "MODEL_FALLBACK" "missing catalog auto path has no preflight fallback"

out="$(CODEX_HOME="$CAT_NOASTRA" CC_ORCH_CODEX_ROUTE= run_dry implement "$WORK" "$TASK")"
assert_has "$out" "gpt-5.6-sol" "plain core default remains Sol"
if CODEX_HOME="$CAT_NOASTRA" CC_ORCH_CODEX_ROUTE= run_dry implement "$WORK" "$TASK" --model luna --fast-mode >/dev/null 2>&1; then
  fail "--fast-mode with Luna should remain rejected"
fi
if CODEX_HOME="$CAT_NOASTRA" CC_ORCH_CODEX_ROUTE= run_dry implement "$WORK" "$TASK" --model luna --effort ultra >/dev/null 2>&1; then
  fail "ultra with Luna should remain rejected"
fi
out="$(CODEX_HOME="$CAT_NOASTRA" CC_ORCH_CODEX_ROUTE= run_dry implement "$WORK" "$TASK" --model gpt-5.5)"
assert_has "$out" "gpt-5.5" "catalog gate does not apply to other full slugs"
usage_out="$("$ROOT/bin/codex-run" 2>&1 || true)"
assert_has "$usage_out" "astra=gpt-6-astra" "usage lists Astra alias"
assert_has "$usage_out" "6 model unavailable" "usage lists model-unavailable exit"
ok "Astra catalog gate and per-lane fallback policy"

HOME_E2E="$TMP/home-e2e"
STATE_E2E="$TMP/state-e2e"
mkdir -p "$HOME_E2E" "$STATE_E2E"
run_facade_dry() {
  local catalog="$1"
  shift
  PATH="$FAKEBIN:$PATH" HOME="$HOME_E2E" CC_ORCH_STATE_DIR="$STATE_E2E" \
    CODEX_HOME="$catalog" CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run-runtime" "$@" --dry-run 2>&1
}

for catalog in "$CAT_NOASTRA" "$CAT_ASTRA"; do
  for mode in implement investigate intake review plan-review verify; do
    case "$mode" in
      implement) args=(implement "$WORK" "$TASK"); fallback="gpt-5.6-sol" ;;
      investigate) args=(investigate "$WORK" "$TASK" "q"); fallback="gpt-5.6-sol" ;;
      intake) args=(intake "$WORK" "$TASK" "g"); fallback="gpt-5.6-terra" ;;
      review) args=(review "$WORK" "$TASK" --base main); fallback="gpt-5.6-sol" ;;
      plan-review) args=(plan-review "$WORK" "$TASK"); fallback="gpt-5.6-sol" ;;
      verify) args=(verify "$WORK" "$TASK"); fallback="gpt-5.6-terra" ;;
    esac
    out="$(run_facade_dry "$catalog" "${args[@]}")"
    assert_has "$out" "service_tier=" "$mode facade preserves Fast"
    if [ "$catalog" = "$CAT_NOASTRA" ]; then
      assert_has "$out" "MODEL_FALLBACK" "$mode facade unavailable warning"
      assert_has "$out" "$fallback" "$mode facade fallback model"
    else
      assert_has "$out" "gpt-6-astra" "$mode facade healthy Astra model"
      assert_not_has "$out" "MODEL_FALLBACK" "$mode facade available Astra has no fallback"
    fi
  done
done

set +e
out="$(run_facade_dry "$CAT_NOASTRA" review "$WORK" "$TASK" --base main --model astra)"
rc=$?
set -e
assert_eq "$rc" "6" "facade explicit unavailable Astra exit"
assert_has "$out" "MODEL_UNAVAILABLE" "facade explicit unavailable Astra classification"
ok "Astra runtime facade routing and fallback"

FAKEBIN_LIVE="$TMP/fakebin-live"
mkdir -p "$FAKEBIN_LIVE"
cat > "$FAKEBIN_LIVE/codex" <<'EOF'
#!/usr/bin/env bash
model="" output=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) shift; model="${1:-}" ;;
    -o) shift; output="${1:-}" ;;
  esac
  shift || true
done
if [ "${FAKE_CODEX_ERROR_STYLE:-not-supported}" = stray-substring ]; then
  printf '%s\n' 'tool output mentioning model_not_found in an unrelated log line' >&2
  printf '%s\n' 'ERROR: stream disconnected' >&2
  exit 1
fi
if [ "$model" = "gpt-6-astra" ]; then
  printf '%s\n' 'warning: Model metadata for `gpt-6-astra` not found. Defaulting to fallback metadata; ...' >&2
  case "${FAKE_CODEX_ERROR_STYLE:-not-supported}" in
    this-model)
      printf '%s\n' 'ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"This model is not supported when using Codex with a ChatGPT account."}}' >&2
      ;;
    not-exist)
      printf '%s\n' 'ERROR: {"type":"error","status":404,"error":{"type":"invalid_request_error","code":"model_not_found","message":"The model `gpt-6-astra` does not exist or you do not have access to it."}}' >&2
      ;;
    warning-only)
      printf '%s\n' 'ERROR: stream disconnected' >&2
      ;;
    embedded-test-output)
      cat <<'JSON'
{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"ERROR: {\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account.\"}}"}}
JSON
      printf '%s\n' 'ERROR: stream disconnected' >&2
      ;;
    not-supported|*)
      printf '%s\n' 'ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The '\''gpt-6-astra'\'' model is not supported when using Codex with a ChatGPT account."}}' >&2
      ;;
  esac
  exit 1
fi
printf '%s\n' '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}'
printf 'ok\nroute=%s\n' "${CC_ORCH_CODEX_ROUTE-unset}" > "$output"
EOF
chmod +x "$FAKEBIN_LIVE/codex"

STATE_LIVE="$TMP/state-live"
out="$(PATH="$FAKEBIN_LIVE:$PATH" HOME="$HOME_E2E" CC_ORCH_STATE_DIR="$STATE_LIVE" \
  CODEX_HOME="$TMP/no-codex-home" CC_ORCH_CODEX_ROUTE= \
  "$ROOT/bin/codex-run-runtime" implement "$WORK" "$TASK" 2>&1)"
assert_has "$out" "MODEL_FALLBACK" "live Codex rejection triggers auto fallback"
[ -s "$TASK/impl-report-codex.md" ] || fail "live fallback did not create implementation report"
assert_has "$(cat "$TASK/impl-report-codex.md")" "route=unset" "live fallback child does not inherit route marker"
session="$(sed -n 's/^implement=//p' "$TASK/.codex-session")"
case "$session" in *'|gpt-5.6-sol|xhigh') ;; *) fail "live fallback session has '$session'" ;; esac
assert_eq "$(wc -l < "$STATE_LIVE/codex.log" | tr -d ' ')" "2" "live fallback attempt log count"
first_log="$(sed -n '1p' "$STATE_LIVE/codex.log")"
second_log="$(sed -n '2p' "$STATE_LIVE/codex.log")"
assert_has "$first_log" "gpt-6-astra" "live first attempt model"
assert_has "$first_log" "exit=1" "live first attempt exit"
assert_has "$second_log" "exit=0" "live fallback attempt exit"
assert_has "$second_log" "fallback-from:gpt-6-astra" "live fallback log marker"

set +e
out="$(PATH="$FAKEBIN_LIVE:$PATH" CC_ORCH_STATE_DIR="$TMP/state-live-explicit" \
  CODEX_HOME="$TMP/no-codex-home" CC_ORCH_CODEX_ROUTE= \
  "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model astra 2>&1)"
rc=$?
set -e
assert_eq "$rc" "6" "live explicit unavailable Astra exit"
assert_has "$out" "MODEL_UNAVAILABLE" "live explicit unavailable Astra classification"
assert_not_has "$out" "CODEX-RUN: FAILED" "live explicit unavailable Astra is specific"

for style in this-model not-exist; do
  style_state="$TMP/state-live-$style-auto"
  out="$(FAKE_CODEX_ERROR_STYLE="$style" PATH="$FAKEBIN_LIVE:$PATH" HOME="$HOME_E2E" \
    CC_ORCH_STATE_DIR="$style_state" CODEX_HOME="$TMP/no-codex-home" CC_ORCH_CODEX_ROUTE= \
    "$ROOT/bin/codex-run-runtime" implement "$WORK" "$TASK" 2>&1)"
  assert_has "$out" "MODEL_FALLBACK" "$style auto rejection triggers fallback"
  second_log="$(sed -n '2p' "$style_state/codex.log")"
  assert_has "$second_log" "exit=0" "$style fallback second attempt succeeds"

  set +e
  out="$(FAKE_CODEX_ERROR_STYLE="$style" PATH="$FAKEBIN_LIVE:$PATH" \
    CC_ORCH_STATE_DIR="$TMP/state-live-$style-explicit" CODEX_HOME="$TMP/no-codex-home" \
    CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model astra 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "6" "$style explicit unavailable Astra exit"
  assert_has "$out" "MODEL_UNAVAILABLE" "$style explicit unavailable classification"
  assert_not_has "$out" "CODEX-RUN: FAILED" "$style explicit failure is specific"
done

set +e
out="$(FAKE_CODEX_ERROR_STYLE=warning-only PATH="$FAKEBIN_LIVE:$PATH" \
  CC_ORCH_STATE_DIR="$TMP/state-live-warning-explicit" CODEX_HOME="$TMP/no-codex-home" \
  CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model astra 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "metadata warning alone is not model unavailable"
assert_has "$out" "CODEX-RUN: FAILED" "warning-only explicit failure stays generic"
assert_not_has "$out" "MODEL_UNAVAILABLE" "warning-only explicit failure is not exit 6"

set +e
out="$(FAKE_CODEX_ERROR_STYLE=warning-only PATH="$FAKEBIN_LIVE:$PATH" HOME="$HOME_E2E" \
  CC_ORCH_STATE_DIR="$TMP/state-live-warning-auto" CODEX_HOME="$TMP/no-codex-home" \
  CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run-runtime" implement "$WORK" "$TASK" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "warning-only auto failure is not retried"
assert_not_has "$out" "MODEL_FALLBACK" "metadata warning alone cannot trigger fallback"

set +e
out="$(FAKE_CODEX_ERROR_STYLE=stray-substring PATH="$FAKEBIN_LIVE:$PATH" \
  CC_ORCH_STATE_DIR="$TMP/state-live-stray-sol" CODEX_HOME="$TMP/no-codex-home" \
  CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model sol 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "stray model_not_found substring stays generic"
assert_has "$out" "CODEX-RUN: FAILED" "stray model_not_found failure classification"
assert_not_has "$out" "MODEL_UNAVAILABLE" "stray model_not_found is not model unavailable"

set +e
out="$(FAKE_CODEX_ERROR_STYLE=embedded-test-output PATH="$FAKEBIN_LIVE:$PATH" HOME="$HOME_E2E" \
  CC_ORCH_STATE_DIR="$TMP/state-live-embedded-auto" CODEX_HOME="$TMP/no-codex-home" \
  CC_ORCH_CODEX_ROUTE= "$ROOT/bin/codex-run-runtime" implement "$WORK" "$TASK" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "embedded test output is not retried"
assert_not_has "$out" "MODEL_FALLBACK" "embedded test output cannot trigger fallback"
assert_eq "$(wc -l < "$TMP/state-live-embedded-auto/codex.log" | tr -d ' ')" "1" "embedded test output attempt log count"

EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
set +e
out="$(PATH="$EMPTYBIN:/usr/bin:/bin" CODEX_HOME="$CAT_NOASTRA" CC_ORCH_CODEX_ROUTE= \
  "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model astra 2>&1)"
rc=$?
set -e
assert_eq "$rc" "4" "missing Codex CLI precedes unavailable catalog"
assert_has "$out" "codex CLI not on PATH" "missing Codex CLI classification"
assert_not_has "$out" "MODEL_UNAVAILABLE" "missing CLI is not catalog exit 6"

out="$(PATH="$FAKEBIN_LIVE:$PATH" CC_ORCH_STATE_DIR="$TMP/state-live-sol" \
  CODEX_HOME="$TMP/no-codex-home" CC_ORCH_CODEX_ROUTE= \
  "$ROOT/bin/codex-run" implement "$WORK" "$TASK" --model sol 2>&1)"
assert_has "$out" "codex-run: implement done" "live fake Codex fallback-model sanity"
ok "live unavailable-model retry and explicit classification"

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

TRIV="$WORK/.orchestra/02-trivial"
mkdir -p "$TRIV"
cp "$TASK/plan.md" "$TRIV/plan.md"

SELF='GATES: self-check only (trivial) — ran bash tests/test-policy.sh; self-reviewed diff once'
FULL='GATES: codex-verify PASS · codex-review CLEAR · claude-verifier not-required'
LOW_WAIVED='GATES: codex-verify PASS · codex-review waived (docs only) · claude-verifier not-required'

triv_brief() {
  local risk_line="$1"
  cat > "$TRIV/brief.md" <<EOF
# Test
$risk_line
Verification: true
EOF
}

triv_summary() {
  local profile="$1" gates="$2" rounds="${3:-1}" audit="${4:-clean}"
  cat > "$TRIV/summary.md" <<EOF
[lead-alpha] STATUS: PASS
CLAUDE PROFILE: $profile
PROMOTIONS: none
BRIEF AUDIT: $audit
$gates
ROUNDS: $rounds
DISPATCH: codex-first
INVESTIGATION: self: trivial lookup
LANES: codex gpt-5.6-sol@xhigh
EOF
}

triv_check() {
  set +e
  TRIV_OUT="$("$ROOT/bin/orch-summary-check" --strict "$TRIV" 2>&1)"
  TRIV_RC=$?
  set -e
}

# T1: a well-formed trivial summary needs only a populated self-check marker.
triv_brief 'RISK: trivial'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "0" "T1 trivial self-check exit"
assert_has "$TRIV_OUT" "CHECK: PASS (risk=trivial)" "T1 trivial self-check risk"

# T1b-T1d: trivial accepts a dash-led reason, but not enum or slash suffixes.
triv_brief 'RISK: trivial — docs only'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "0" "T1b trivial dash reason exit"
assert_has "$TRIV_OUT" "risk=trivial" "T1b trivial dash reason risk"

triv_brief 'RISK: trivial | low | normal | critical'
triv_check
assert_eq "$TRIV_RC" "1" "T1c trivial enum declaration exit"
assert_has "$TRIV_OUT" "got 'malformed-trivial'" "T1c trivial enum declaration message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1c trivial enum declaration normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1c trivial enum declaration cannot select trivial"

triv_brief 'RISK: trivial/critical'
triv_check
assert_eq "$TRIV_RC" "1" "T1d trivial slash declaration exit"
assert_has "$TRIV_OUT" "got 'malformed-trivial'" "T1d trivial slash declaration message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1d trivial slash declaration normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1d trivial slash declaration cannot select trivial"

triv_brief 'RISK: trivial-ish'
triv_check
assert_eq "$TRIV_RC" "1" "T1e trivial hyphen suffix exit"
assert_has "$TRIV_OUT" "got 'malformed-trivial'" "T1e trivial hyphen suffix message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1e trivial hyphen suffix normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1e trivial hyphen suffix cannot select trivial"

triv_brief 'RISK: trivial (or critical)'
triv_check
assert_eq "$TRIV_RC" "1" "T1f trivial parenthesis reason exit"
assert_has "$TRIV_OUT" "got 'malformed-trivial'" "T1f trivial parenthesis reason message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1f trivial parenthesis reason normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1f trivial parenthesis reason cannot select trivial"

triv_brief 'RISK: trivial ()'
triv_check
assert_eq "$TRIV_RC" "1" "T1f trivial empty parentheses exit"
assert_has "$TRIV_OUT" "got 'malformed-trivial'" "T1f trivial empty parentheses message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1f trivial empty parentheses normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1f trivial empty parentheses cannot select trivial"

cat > "$TRIV/brief.md" <<'EOF'
# Test
```
RISK: trivial
```
RISK: trivial
Verification: true
EOF
triv_check
assert_eq "$TRIV_RC" "1" "T1g ambiguous trivial exit"
assert_has "$TRIV_OUT" "got 'ambiguous-trivial'" "T1g ambiguous trivial message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1g ambiguous trivial normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1g ambiguous trivial cannot select trivial"

cat > "$TRIV/brief.md" <<'EOF'
# Test
```
RISK: trivial
```
## Risk — RISK: critical
Verification: true
EOF
triv_check
assert_eq "$TRIV_RC" "1" "T1h conflicting fenced trivial exit"
assert_has "$TRIV_OUT" "got 'conflicting-trivial'" "T1h conflicting fenced trivial message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T1h conflicting fenced trivial normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1h conflicting fenced trivial cannot select trivial"

cat > "$TRIV/brief.md" <<'EOF'
# Test
RISK: trivial
This would otherwise be RISK: low.
Verification: true
EOF
triv_check
assert_eq "$TRIV_RC" "1" "T1i conflicting prose tier exit"
assert_has "$TRIV_OUT" "got 'conflicting-trivial'" "T1i conflicting prose tier message"
assert_not_has "$TRIV_OUT" "risk=trivial" "T1i conflicting prose tier cannot select trivial"

triv_brief 'RISK: trivial'
triv_summary 'light sonnet@medium' "$SELF"

# T2: GATES remains mandatory for trivial.
sed -i '/^GATES:/d' "$TRIV/summary.md"
triv_check
assert_eq "$TRIV_RC" "1" "T2 missing GATES exit"
assert_has "$TRIV_OUT" "summary lacks GATES" "T2 missing GATES message"

# T3-T5: the fixed marker must be anchored and followed by a description.
triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) —'
triv_check
assert_eq "$TRIV_RC" "1" "T3 empty self-check description exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3 empty self-check description message"

# T3b: non-ASCII descriptions work in the C locale when they include ASCII evidence.
triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — 문서 확인, exit 0'
LC_ALL=C triv_check
assert_eq "$TRIV_RC" "0" "T3b C-locale description with ASCII evidence exit"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — 문서 확인'
LC_ALL=C triv_check
assert_eq "$TRIV_RC" "1" "T3b C-locale description without ASCII evidence exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3b C-locale description without ASCII evidence message"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) —'
LC_ALL=C triv_check
assert_eq "$TRIV_RC" "1" "T3b C-locale empty description exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3b C-locale empty description message"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — !!!'
triv_check
assert_eq "$TRIV_RC" "1" "T3c punctuation-only description exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3c punctuation-only description message"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — ...'
triv_check
assert_eq "$TRIV_RC" "1" "T3c ellipsis-only description exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3c ellipsis-only description message"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — ✅'
LC_ALL=C triv_check
assert_eq "$TRIV_RC" "1" "T3d C-locale emoji-only description exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T3d C-locale emoji-only description message"

triv_summary 'light sonnet@medium' 'GATES: looked fine'
triv_check
assert_eq "$TRIV_RC" "1" "T4 arbitrary GATES exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T4 arbitrary GATES message"

triv_summary 'light sonnet@medium' "$FULL"
triv_check
assert_eq "$TRIV_RC" "1" "T5 full gates without marker exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T5 full gates without marker message"

triv_summary 'light sonnet@medium' 'GATES: self-check only (trivial) — ran tests; additionally codex-verify PASS'
triv_check
assert_eq "$TRIV_RC" "0" "T5b marker with extra evidence exit"

triv_summary 'light sonnet@medium' 'GATES: codex-verify FAIL · self-check only (trivial) — ran tests'
triv_check
assert_eq "$TRIV_RC" "1" "T5c unanchored marker exit"
assert_has "$TRIV_OUT" "trivial risk must report" "T5c unanchored marker message"

# T6-T8: malformed, missing, and prose-only trivial declarations fall back to normal.
triv_brief 'RISK: trivail'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T6 misspelled RISK exit"
assert_has "$TRIV_OUT" "invalid or missing RISK (got 'trivail')" "T6 misspelled RISK message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T6 misspelled RISK normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T6 misspelled RISK cannot select trivial"

cat > "$TRIV/brief.md" <<'EOF'
# Test
Verification: true
EOF
triv_check
assert_eq "$TRIV_RC" "1" "T7 missing RISK exit"
assert_has "$TRIV_OUT" "invalid or missing RISK (got 'empty')" "T7 missing RISK message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T7 missing RISK normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T7 missing RISK cannot select trivial"

cat > "$TRIV/brief.md" <<'EOF'
# Add a RISK: trivial tier
Verification: true
EOF
triv_check
assert_eq "$TRIV_RC" "1" "T7b prose-only trivial exit"
assert_has "$TRIV_OUT" "got 'unanchored-trivial'" "T7b prose-only trivial message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T7b prose-only trivial normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T7b prose-only trivial cannot select trivial"

triv_brief 'RISK:'
triv_check
assert_eq "$TRIV_RC" "1" "T8 empty RISK exit"
assert_has "$TRIV_OUT" "invalid or missing RISK (got 'empty')" "T8 empty RISK message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T8 empty RISK normal gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T8 empty RISK cannot select trivial"

# T9: an anchored declaration wins over an earlier prose mention.
cat > "$TRIV/brief.md" <<'EOF'
# Add a RISK: trivial tier
RISK: critical
Verification: true
EOF
triv_summary 'critical fable@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T9 prose-first critical exit"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T9 prose-first critical executable gate"
assert_has "$TRIV_OUT" "critical risk requires claude-verifier PASS" "T9 prose-first critical verifier gate"
assert_not_has "$TRIV_OUT" "invalid or missing RISK" "T9 prose-first anchored declaration"

# T10: legacy unanchored low layouts retain their existing behavior.
cat > "$TRIV/brief.md" <<'EOF'
# Test
## Risk — RISK: low
Verification: true
EOF
triv_summary 'light sonnet@medium' "$LOW_WAIVED"
triv_check
assert_eq "$TRIV_RC" "0" "T10 legacy low full gate exit"
assert_has "$TRIV_OUT" "CHECK: PASS (risk=low)" "T10 legacy low risk"
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T10 low rejects trivial marker exit"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T10 low rejects trivial marker"

cat > "$TRIV/brief.md" <<'EOF'
# Test
RISK: low
RISK: critical
Verification: true
EOF
triv_summary 'light sonnet@medium' "$LOW_WAIVED"
triv_check
assert_eq "$TRIV_RC" "0" "T10b multiple anchored non-trivial exit"
assert_has "$TRIV_OUT" "risk=low" "T10b multiple anchored non-trivial first-line risk"

# T11: normal and critical do not accept the trivial marker.
triv_brief 'RISK: normal'
triv_summary 'normal opus@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T11 normal rejects trivial marker exit"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T11 normal rejects trivial marker"

triv_brief 'RISK: critical'
triv_summary 'critical fable@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T11 critical rejects trivial marker exit"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T11 critical rejects trivial marker"

# T12-T14: trivial keeps the normal round cap and light profile, including bold syntax.
triv_brief 'RISK: trivial'
triv_summary 'light sonnet@medium' "$SELF" 3
triv_check
assert_eq "$TRIV_RC" "1" "T12 trivial round cap exit"
assert_has "$TRIV_OUT" "exceeds trivial cap=2" "T12 trivial round cap message"
triv_summary 'light sonnet@medium' "$SELF" 2
triv_check
assert_eq "$TRIV_RC" "0" "T12 trivial round cap boundary"

triv_summary 'critical fable@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T13 trivial profile exit"
assert_has "$TRIV_OUT" "trivial risk should use light/Sonnet" "T13 trivial profile message"

triv_brief 'RISK: **trivial**'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "0" "T14 bold trivial exit"
assert_has "$TRIV_OUT" "risk=trivial" "T14 bold trivial risk"

# T15: the pre-existing normal fixture and checks above remain unchanged and passing.
set +e
out="$("$ROOT/bin/orch-summary-check" --strict "$TASK" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "T15 pre-existing normal fixture"

# T16-T19: plan amendments can move only a matching low brief to trivial.
cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: low -> trivial
EOF
triv_brief 'RISK: low'
triv_summary 'light sonnet@medium' "$SELF" 1 'amended (low -> trivial: docs only)'
triv_check
assert_eq "$TRIV_RC" "0" "T16 low to trivial amendment exit"
assert_has "$TRIV_OUT" "CHECK: PASS (risk=trivial)" "T16 low to trivial amendment risk"
assert_has "$TRIV_OUT" "NOTE:" "T16 low to trivial amendment note"

triv_summary 'light sonnet@medium' "$SELF" 1 clean
triv_check
assert_eq "$TRIV_RC" "1" "T17 amendment audit exit"
assert_has "$TRIV_OUT" "BRIEF AUDIT: amended" "T17 amendment audit message"

triv_summary 'light sonnet@medium' "$SELF" 1 'clean (not amended)'
triv_check
assert_eq "$TRIV_RC" "1" "T17b misleading amendment audit exit"
assert_has "$TRIV_OUT" "BRIEF AUDIT: amended" "T17b misleading amendment audit message"

triv_brief 'RISK: normal'
triv_summary 'normal opus@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T18 normal amendment exit"
assert_has "$TRIV_OUT" "RISK AMENDED may only downgrade low -> trivial" "T18 normal amendment message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T18 normal amendment gates"

cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: low -> trivial/normal
EOF
triv_brief 'RISK: low'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T18b malformed target amendment exit"
assert_has "$TRIV_OUT" "RISK AMENDED may only downgrade" "T18b malformed target amendment message"
assert_has "$TRIV_OUT" "got 'malformed'" "T18b malformed target amendment value"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T18b malformed target amendment gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T18b malformed target amendment cannot select trivial"

cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: low -> trivial — docs only
EOF
triv_summary 'light sonnet@medium' "$SELF" 1 amended
triv_check
assert_eq "$TRIV_RC" "0" "T18c amendment reason exit"
assert_has "$TRIV_OUT" "risk=trivial" "T18c amendment reason risk"

cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: low -> trivial/normal
RISK AMENDED: low -> trivial
EOF
triv_brief 'RISK: low'
triv_summary 'light sonnet@medium' "$SELF" 1 amended
triv_check
assert_eq "$TRIV_RC" "1" "T18d duplicate amendment exit"
assert_has "$TRIV_OUT" "at most one RISK AMENDED line" "T18d duplicate amendment message"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T18d duplicate amendment gates"
assert_not_has "$TRIV_OUT" "risk=trivial" "T18d duplicate amendment cannot select trivial"

cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: critical -> trivial
EOF
triv_brief 'RISK: critical'
triv_summary 'critical fable@high' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T19 critical amendment exit"
assert_has "$TRIV_OUT" "RISK AMENDED may only downgrade" "T19 critical amendment message"
assert_has "$TRIV_OUT" "critical risk requires claude-verifier PASS" "T19 critical amendment gates"

cat > "$TRIV/plan.md" <<'EOF'
# Plan
RISK AMENDED: low -> normal
EOF
triv_brief 'RISK: low'
triv_summary 'light sonnet@medium' "$SELF"
triv_check
assert_eq "$TRIV_RC" "1" "T19 low to normal amendment exit"
assert_has "$TRIV_OUT" "RISK AMENDED may only downgrade" "T19 low to normal amendment message"
cp "$TASK/plan.md" "$TRIV/plan.md"

# T20-T26: lock every pre-existing risk tier's gate behavior.
triv_brief 'RISK: critical'
triv_summary 'critical fable@high' 'GATES: codex-verify PASS · codex-review CLEAR · claude-verifier PASS'
triv_check
assert_eq "$TRIV_RC" "0" "T20 critical complete gates exit"
assert_has "$TRIV_OUT" "risk=critical" "T20 critical complete gates risk"

triv_summary 'critical fable@high' "$FULL"
triv_check
assert_eq "$TRIV_RC" "1" "T21 critical missing verifier exit"
assert_has "$TRIV_OUT" "critical risk requires claude-verifier PASS" "T21 critical missing verifier message"

triv_brief 'RISK: normal'
triv_summary 'normal opus@high' 'GATES: codex-verify unavailable · codex-review CLEAR · claude-verifier PASS'
triv_check
assert_eq "$TRIV_RC" "0" "T22 normal executable fallback exit"

triv_summary 'normal opus@high' 'GATES: codex-verify unavailable · codex-review CLEAR · claude-verifier not-required'
triv_check
assert_eq "$TRIV_RC" "1" "T23 normal missing executable fallback exit"
assert_has "$TRIV_OUT" "executable verification did not PASS" "T23 normal missing executable fallback message"

triv_brief 'RISK: low'
triv_summary 'light sonnet@medium' 'GATES: codex-verify PASS · codex-review waived (docs) · claude-verifier not-required'
triv_check
assert_eq "$TRIV_RC" "0" "T24 low review waiver exit"
assert_has "$TRIV_OUT" "risk=low" "T24 low review waiver risk"

triv_brief 'RISK: normal'
triv_summary 'normal opus@high' 'GATES: codex-verify PASS · codex-review waived (docs) · claude-verifier not-required'
triv_check
assert_eq "$TRIV_RC" "1" "T25 normal review waiver exit"
assert_has "$TRIV_OUT" "only low risk may waive it" "T25 normal review waiver message"

triv_summary 'normal opus@high' 'GATES: codex-verify PASS · codex-review unavailable · claude-verifier PASS'
triv_check
assert_eq "$TRIV_RC" "0" "T26 normal review fallback exit"
ok "trivial risk tier gate policy and safe RISK fallback"

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
printf '%s\n' "\${CC_ORCH_POLICY_REV:-}" > "$TMP/claude-policy-rev"
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
rev="$("$ROOT/bin/orch-policy-rev" "$ROOT")"
assert_eq "$(cat "$TMP/claude-policy-rev")" "$rev" "launcher policy revision"
assert_eq "$("$ROOT/bin/orch-policy-rev" "$HOME_DIR/.claude/orchestra")" "$rev" "symlink-independent policy revision"

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

cat > "$STATE/state" <<'EOF'
active=sonnet[1m]
pinned=0
reason=test
EOF
quiet="$(printf '{}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='sonnet[1m]' CC_ORCH_EFFORT=high CC_ORCH_PROFILE=normal CC_ORCH_POLICY_REV="$rev" "$ROOT/hooks/orch-model-notice.sh")"
assert_eq "$quiet" "" "current-policy hook silence"
legacy_rev="$("$ROOT/bin/orch-policy-rev" --legacy "$HOME_DIR/.claude/orchestra")"
quiet="$(printf '{}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='sonnet[1m]' CC_ORCH_EFFORT=high CC_ORCH_PROFILE=normal CC_ORCH_POLICY_REV="$legacy_rev" "$ROOT/hooks/orch-model-notice.sh")"
assert_eq "$quiet" "" "live legacy-policy hook silence"
quiet="$(printf '{}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='opus[1m]' CC_ORCH_EFFORT=medium CC_ORCH_PROFILE=normal CC_ORCH_MODEL_OVERRIDE=1 CC_ORCH_EFFORT_OVERRIDE=1 CC_ORCH_POLICY_REV="$rev" "$ROOT/hooks/orch-model-notice.sh")"
assert_eq "$quiet" "" "explicit override hook silence"

notice="$(printf '{"prompt_id":"policy-test"}' | HOME="$HOME_DIR" CC_ORCH_STATE_DIR="$STATE" CC_ORCH_MODEL='fable[1m]' CC_ORCH_EFFORT=xhigh CC_ORCH_PROFILE=normal CC_ORCH_PROJECT=dsv CC_ORCH_POLICY_REV=old "$ROOT/hooks/orch-model-notice.sh")"
printf '%s' "$notice" | python3 -c 'import json,sys; json.load(sys.stdin)'
assert_has "$notice" "cc-orch --reload dsv" "reload notice"
ok "stale-policy hook"

echo "PASS: $pass policy test groups"
