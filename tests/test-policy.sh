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
