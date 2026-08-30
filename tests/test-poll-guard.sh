#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/orch-poll-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

make_payload() {
  python3 - "$1" "$2" "${3:-false}" <<'PY'
import json
import sys

payload = {"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}
if sys.argv[3] == "true":
    payload["tool_input"]["run_in_background"] = True
print(json.dumps(payload))
PY
}

run_payload() {
  local payload="$1"
  local state_dir="${2:-$STATE}"
  set +e
  RUN_OUTPUT="$(printf '%s' "$payload" | CC_ORCH_STATE_DIR="$state_dir" "$HOOK")"
  RUN_STATUS=$?
  set -e
}

assert_exit_zero() {
  [ "$RUN_STATUS" -eq 0 ] || fail "$1 exited $RUN_STATUS instead of 0"
}

assert_deny() {
  local command="$1"
  local label="$2"
  local background="${3:-false}"
  local payload
  payload="$(make_payload Bash "$command" "$background")"
  run_payload "$payload"
  assert_exit_zero "$label"
  if ! printf '%s' "$RUN_OUTPUT" | python3 -c '
import json
import sys

result = json.load(sys.stdin)
hook = result["hookSpecificOutput"]
assert hook["hookEventName"] == "PreToolUse"
assert hook["permissionDecision"] == "deny"
reason = hook["permissionDecisionReason"]
assert "automatic completion notification" in reason
assert "ONE bounded Monitor tool call" in reason
assert "poll-guard.off" not in reason
'; then
    fail "$label did not emit the required deny JSON: $RUN_OUTPUT"
  fi
  ok "$label"
}

assert_allow_payload() {
  local payload="$1"
  local label="$2"
  local state_dir="${3:-$STATE}"
  run_payload "$payload" "$state_dir"
  assert_exit_zero "$label"
  [ -z "$RUN_OUTPUT" ] || fail "$label unexpectedly emitted output: $RUN_OUTPUT"
  ok "$label"
}

assert_allow_command() {
  local command="$1"
  local label="$2"
  local tool_name="${3:-Bash}"
  local payload
  payload="$(make_payload "$tool_name" "$command")"
  assert_allow_payload "$payload" "$label"
}

bash -n "$HOOK"
ok "hook shell syntax"

assert_deny \
  'until [ -f /w/.orchestra/t/impl-report-codex.md ]; do sleep 5; done; echo READY' \
  "T1 file-existence polling loop denied"
assert_deny \
  'until grep -q '\''"type":"result"'\'' /w/.orchestra/t/codex-implement.jsonl; do sleep 10; done' \
  "T2 grep polling loop denied"
assert_deny \
  'while true; do cat /w/x/codex-verify.jsonl; sleep 3; done' \
  "T3 codex artifact polling loop denied"

assert_allow_command 'ls' "T4 ls allowed"
assert_allow_command 'git status' "T4 git status allowed"
assert_allow_command 'sleep 2' "T4 short sleep allowed"
assert_allow_command 'sleep 300' "T4 long one-shot sleep allowed"
assert_allow_command 'cat /w/.orchestra/t/plan.md' "T5 non-loop orchestra read allowed"
assert_allow_command \
  'until [ -f /tmp/other.txt ]; do sleep 5; done' \
  "T6 unrelated polling loop allowed"

assert_allow_payload '{not json' "T7 malformed JSON allowed"
assert_allow_payload '' "T7 empty input allowed"

t1_command='until [ -f /w/.orchestra/t/impl-report-codex.md ]; do sleep 5; done; echo READY'
assert_allow_command "$t1_command" "T8 BashOutput event allowed" BashOutput
assert_allow_command "$t1_command" "T8 Monitor event allowed" Monitor
assert_deny "$t1_command" "T9 background polling loop denied" true

OFF_STATE="$TMP/off-state"
mkdir -p "$OFF_STATE"
touch "$OFF_STATE/poll-guard.off"
off_payload="$(make_payload Bash "$t1_command")"
assert_allow_payload "$off_payload" "T10 kill switch allows polling command" "$OFF_STATE"

assert_allow_command \
  'git commit -m "fix: until codex-implement.jsonl polling; do not sleep"' \
  "T11 quoted polling prose allowed"

heredoc_command="$(printf '%s\n' \
  "cat <<'DOC'" \
  'until [ -f /w/.orchestra/t/impl-report-codex.md ]; do sleep 5; done' \
  'DOC')"
assert_allow_command "$heredoc_command" "T12 heredoc polling documentation allowed"

assert_deny \
  "bash -c 'until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done'" \
  "T13 sh -c polling loop denied"
assert_deny \
  'until [ -f "/w/.orchestra/t/x.md" ]; do sleep 5; done' \
  "T14 real loop with quoted target denied"
assert_allow_command \
  'echo "while do sleep done .orchestra/"' \
  "T15 quoted loop-shaped prose allowed"

pseudo_heredoc_command="$(printf '%s\n' 'echo "<<DOC"' "$t1_command")"
assert_deny "$pseudo_heredoc_command" "T16 quoted pseudo-heredoc does not suppress real code"
assert_deny \
  'echo "$(until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done)"' \
  "T17 command substitution inside double quotes denied"
assert_allow_command \
  '# until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done' \
  "T18 comment-only polling prose allowed"
assert_allow_command \
  'echo ok # until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done' \
  "T19 trailing-comment polling prose allowed"
assert_allow_command \
  'echo "until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done"; bash -c "echo ok"' \
  "T20 sh -c un-suppresses only its payload quote"
assert_deny \
  'until sleep 5 && [ -f /w/.orchestra/t/x.md ]; do :; done' \
  "T21 sleep in loop condition denied"
assert_allow_command \
  'grep -q x /tmp/f <<< "until do sleep done .orchestra/"' \
  "T22 here-string with quoted polling prose allowed"

assert_deny \
  'until [ -f /w/.orchestra/t/x.md ]; do echo "not done"; sleep 5; done' \
  "T23 quoted done does not terminate loop scan"
assert_allow_command \
  'echo while do sleep .orchestra/ grep done' \
  "T24 unquoted loop-shaped prose allowed"
comment_apostrophe_command="$(printf '%s\n' "# don't poll manually" "$t1_command")"
assert_deny "$comment_apostrophe_command" "T25 comment apostrophe does not suppress real loop"
hyphen_heredoc_command="$(printf '%s\n' \
  'cat <<DOC-END' \
  'prose' \
  'DOC-END' \
  "$t1_command")"
assert_deny "$hyphen_heredoc_command" "T26 hyphenated heredoc closes before real loop"
comment_signal_command="$(printf '%s\n' \
  'while true; do # sleep 5; grep .orchestra/' \
  '  break; done')"
assert_allow_command "$comment_signal_command" "T27 comment text supplies no deny signals"
assert_allow_command \
  'echo "bash -c"; echo "until [ -f /w/.orchestra/t/x.md ]; do sleep 5; done"' \
  "T28 quoted sh -c does not un-suppress later prose"
assert_allow_command \
  'until [ -f /w/.orchestra/t/x.md ]; do echo "sleep 5"; done' \
  "T29 quoted sleep is data"

echo "PASS: $pass poll-guard cases"
