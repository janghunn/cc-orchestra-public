#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/orch-stop-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
REPO="$TMP/repo"
GOOD="$REPO/.orchestra/passing task"
BAD="$REPO/.orchestra/failing-task"
MARKER="$TMP/checker.calls"
TRANSCRIPT="$TMP/transcript.jsonl"
mkdir -p "$STATE" "$GOOD" "$BAD" "$TMP/home"
export HOME="$TMP/home"
export CC_ORCH_STATE_DIR="$STATE"
export TEST_REAL_CHECKER="$ROOT/bin/orch-summary-check"
export TEST_MARKER="$MARKER"
export CC_ORCH_SUMMARY_CHECK="$TMP/checker"
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$HOOK"
ok 'hook shell syntax'

printf 'RISK: trivial\n' > "$GOOD/brief.md"
printf '# Plan\n' > "$GOOD/plan.md"
cat > "$GOOD/summary.md" <<'SUMMARY'
STATUS: PASS
CLAUDE PROFILE: light
PROMOTIONS: none
DISPATCH: codex-first
INVESTIGATION: none
LANES: codex
GATES: self-check only (trivial) — bash -n fixture.sh
ROUNDS: 1
SUMMARY
cp "$GOOD/brief.md" "$BAD/brief.md"
cp "$GOOD/plan.md" "$BAD/plan.md"
cat > "$TMP/checker" <<'CHECKER'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json, os, sys
with open(os.environ['TEST_MARKER'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\n')
PY
case "${TEST_CHECKER_MODE:-real}" in
  usage) echo 'usage: synthetic checker' >&2; exit 2 ;;
  crash) echo 'synthetic checker failed' >&2; exit 7 ;;
  *) exec "$TEST_REAL_CHECKER" "$@" ;;
esac
CHECKER
chmod +x "$TMP/checker"

registry() {
  python3 - "$REPO" "${1:-.orchestra/failing-task}" "${2:-lead-charlie}" "${3:-cccccccc}" <<'PY'
import sys
from pathlib import Path
root, task, slot, agent = sys.argv[1:]
(Path(root) / '.orchestra/REGISTRY.md').write_text(
    '| slot | agentId | task | branch | dir | status | last update |\n'
    f'| {slot} | {agent} | task | orch/task | {task} | PASS | now |\n')
PY
}
transcript() {
  python3 - "$TRANSCRIPT" "$1" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as out:
    out.write(json.dumps({'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': sys.argv[2]}]}}) + '\n')
    out.write(json.dumps({'type': 'user', 'message': {'content': 'tool result'}}) + '\n')
PY
}
make_payload() {
  python3 - "$REPO" "$TRANSCRIPT" "${1:-route-lead-charlie-critical}" "${2:-false}" "${3:-cccccccc1234}" <<'PY'
import json, sys
print(json.dumps({'hook_event_name': 'SubagentStop', 'cwd': sys.argv[1], 'agent_transcript_path': sys.argv[2],
                  'agent_type': sys.argv[3], 'stop_hook_active': json.loads(sys.argv[4]), 'agent_id': sys.argv[5]}))
PY
}
run_payload() {
  rm -f "$MARKER"
  set +e
  RUN_OUTPUT="$(printf '%s' "$1" | "$HOOK" 2>"$TMP/stderr")"
  RUN_STATUS=$?
  set -e
}
assert_output() {
  local expected="$1" label="$2" invoked="$3" expected_task="${4:-$BAD}"
  [ "$RUN_STATUS" -eq 0 ] || fail "$label exited $RUN_STATUS instead of 0"
  if [ "$expected" = allow ]; then
    [ -z "$RUN_OUTPUT" ] && [ ! -s "$TMP/stderr" ] || fail "$label unexpectedly emitted: $RUN_OUTPUT"
  else
    if ! python3 - "$RUN_OUTPUT" "$expected" "$TMP/stderr" <<'PY'
import json, sys
from pathlib import Path
out = json.loads(sys.argv[1])
if sys.argv[2] == 'block':
    assert out['decision'] == 'block'
    assert 'ERROR: missing summary.md' in out['reason']
    assert 'Re-run:' in out['reason'] and '--strict' in out['reason']
    assert 'stop-gate.off' in out['reason']
    assert not Path(sys.argv[3]).read_text()
else:
    assert 'decision' not in out
    assert 'was claimed but orch-summary-check --strict could not be run' in out['systemMessage']
    assert 'Verify manually:' in out['systemMessage']
    assert Path(sys.argv[3]).read_text().strip() == out['systemMessage']
PY
    then fail "$label incorrect JSON: $RUN_OUTPUT"; fi
  fi
  if [ "$invoked" = yes ]; then
    [ -f "$MARKER" ] || fail "$label did not invoke checker"
    python3 - "$MARKER" "$expected_task" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows == [['--strict', sys.argv[2]]], rows
PY
  else
    [ ! -e "$MARKER" ] || fail "$label unexpectedly invoked checker"
  fi
  ok "$label (exit 0)"
}
check() {
  run_payload "$(make_payload "${4:-route-lead-charlie-critical}" "${5:-false}" "${6:-cccccccc1234}")"
  assert_output "$1" "$2" "$3" "${7:-$BAD}"
}

CLAIM=$'[lead-charlie] STATUS: PASS\nGATES: codex-verify PASS'
transcript "$CLAIM"
registry '.orchestra/passing task'
check allow 'real strict checker passes' yes route-lead-charlie-critical false cccccccc1234 "$GOOD"
registry
check block 'real strict checker missing summary blocks' yes
transcript 'Implementation is running; waiting for the background lane.'
check allow 'ordinary mid-task prose never invokes checker' no
transcript 'STATUS: PASS'
check allow 'STATUS without GATES never invokes checker' no
transcript "$CLAIM"
check allow 'stop_hook_active loop protection' no route-lead-charlie-critical true
check allow 'string stop_hook_active loop protection' no route-lead-charlie-critical '"true"'
check allow 'numeric stop_hook_active loop protection' no route-lead-charlie-critical 1
touch "$STATE/stop-gate.off"
check allow 'off-switch bypass' no
rm "$STATE/stop-gate.off"
check allow 'dev stop bypass' no dev-1
check allow 'orchestrator stop bypass' no orchestrator
check block 'repo-relative registry dir uses registry root' yes
rm "$REPO/.orchestra/REGISTRY.md"
transcript "$CLAIM"$'\nARTIFACTS: '"$BAD"
check block 'ARTIFACTS fallback with brief' yes
registry
transcript "$CLAIM"$'\nARTIFACTS: '"$GOOD"
check block 'registry overrides different passing ARTIFACTS' yes
registry "$BAD"
check block 'absolute registry dir' yes
registry '.orchestra/failing-task' lead-alpha cccccccc
check block 'matching truncated agent ID precedes slot' yes
registry '.orchestra/failing-task' lead-charlie other-agent-id
check block 'slot fallback when agent ID does not match' yes
rm "$REPO/.orchestra/REGISTRY.md"
for path in "$TMP" "$TMP/nonexistent"; do
  transcript "$CLAIM"$'\nARTIFACTS: '"$path"
  check warn 'invalid ARTIFACTS warns without checker' no
done
transcript "$CLAIM"
check warn 'no registry or ARTIFACTS warns' no
registry

# Isolate the hook from all checker fallback locations; the full installer is never run.
mkdir -p "$TMP/isolated/hooks" "$TMP/fakebin"
cp "$HOOK" "$TMP/isolated/hooks/orch-stop-gate.sh"
for command in bash cat dirname readlink python3; do
  ln -s "$(command -v "$command")" "$TMP/fakebin/$command"
done
set +e
rm -f "$MARKER"
RUN_OUTPUT="$(printf '%s' "$(make_payload)" | PATH="$TMP/fakebin" CC_ORCH_SUMMARY_CHECK="$TMP/missing-checker" "$TMP/isolated/hooks/orch-stop-gate.sh" 2>"$TMP/stderr")"
RUN_STATUS=$?
set -e
assert_output warn 'missing checker and no fallback warns' no
export TEST_CHECKER_MODE=usage
check warn 'checker exit 2 warns' yes
export TEST_CHECKER_MODE=crash
check warn 'unexpected checker exit warns' yes
unset TEST_CHECKER_MODE
for bad in missing directory nonjson empty; do
  case "$bad" in
    missing) rm -f "$TRANSCRIPT" ;;
    directory) rm -f "$TRANSCRIPT"; mkdir "$TRANSCRIPT" ;;
    nonjson) rmdir "$TRANSCRIPT"; printf 'not JSONL\n' > "$TRANSCRIPT" ;;
    empty) : > "$TRANSCRIPT" ;;
  esac
  check allow "unreadable transcript: $bad" no
done
run_payload '{"agent_type":"lead-charlie"}'
assert_output allow 'missing transcript payload field' no
for payload in '{' '' '[]'; do
  run_payload "$payload"
  assert_output allow 'malformed/empty payload' no
done
transcript $'STATUS: BLOCKED\nGATES: failed'
check block 'BLOCKED claim also validates' yes
transcript $'STATUS: FAIL\nGATES: failed'
check block 'FAIL claim also validates' yes
transcript "$CLAIM"
python3 - "$TRANSCRIPT" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'type': 'assistant', 'message': {'content': 'Still working.'}}) + '\n')
PY
check allow 'only last assistant message controls claim' no

python3 - "$STATE/safety-hooks.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert {'allow', 'block', 'warn'} <= {row['decision'] for row in rows}
assert all(row['hook'] == 'orch-stop-gate' and row['event'] == 'SubagentStop' and '\n' not in row['reason'] for row in rows)
PY
ok 'claimed outcomes journal allow/block/warn'
before="$(wc -c < "$STATE/safety-hooks.log")"
check allow 'mid-task journal bypass' no
[ "$(wc -c < "$STATE/safety-hooks.log")" = "$before" ] || fail 'non-claim journalled'
ok 'non-claim paths never journal'

echo "PASS: $pass stop-gate cases"
