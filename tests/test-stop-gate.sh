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
NOSUMMARY="$REPO/.orchestra/unsaved task"
MARKER="$TMP/checker.calls"
TRANSCRIPT="$TMP/transcript.jsonl"
mkdir -p "$STATE" "$GOOD" "$BAD" "$NOSUMMARY" "$TMP/home"
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

# Real Git root for ARTIFACTS containment checks, built without writing Git commands.
python3 - "$REPO" <<'PY'
import hashlib, sys, zlib
from pathlib import Path
dot = Path(sys.argv[1]) / '.git'
for sub in ('objects', 'refs/heads', 'refs/tags'):
    (dot / sub).mkdir(parents=True, exist_ok=True)
(dot / 'config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n')
def obj(kind, data):
    raw = kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data
    sha = hashlib.sha1(raw).hexdigest()
    path = dot / 'objects' / sha[:2] / sha[2:]
    path.parent.mkdir(exist_ok=True)
    path.write_bytes(zlib.compress(raw))
    return sha
tree = obj('tree', b'')
commit = obj('commit', (f'tree {tree}\nauthor Fixture <fixture@example.invalid> 1 +0000\n'
                        'committer Fixture <fixture@example.invalid> 1 +0000\n\nFixture\n').encode())
(dot / 'refs/heads/main').write_text(commit + '\n')
(dot / 'HEAD').write_text('ref: refs/heads/main\n')
PY
git -C "$REPO" rev-parse --show-toplevel >/dev/null

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
sed '/^GATES:/d' "$GOOD/summary.md" > "$BAD/summary.md"
cp "$GOOD/brief.md" "$GOOD/plan.md" "$NOSUMMARY/"
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
  python3 - "${4:-$REPO}" "$TRANSCRIPT" "${1:-route-lead-charlie-critical}" "${2:-false}" "${3:-cccccccc1234}" <<'PY'
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
    if ! python3 - "$RUN_OUTPUT" "$expected" "$TMP/stderr" "${CHECK_ERROR_TEXT:-ERROR: summary lacks GATES}" "$expected_task" <<'PY'
import json, shlex, sys
from pathlib import Path
out = json.loads(sys.argv[1])
if sys.argv[2] == 'block':
    assert out['decision'] == 'block'
    assert sys.argv[4] in out['reason']
    assert 'Re-run:' in out['reason'] and '--strict' in out['reason']
    assert 'stop-gate.off' in out['reason']
    assert not Path(sys.argv[3]).read_text()
elif sys.argv[2] == 'note':
    assert 'decision' not in out
    assert 'orch-stop-gate: note:' in out['systemMessage']
    assert 'summary.md not saved yet' in out['systemMessage']
    assert 'Tier 1 saves the returned block and runs' in out['systemMessage']
    assert shlex.join(['orch-summary-check', '--strict', sys.argv[5]]) in out['systemMessage']
    assert not Path(sys.argv[3]).read_text()
else:
    assert 'decision' not in out
    if sys.argv[2] == 'warn':
        assert 'was claimed but orch-summary-check --strict could not be run' in out['systemMessage']
    elif sys.argv[2] == 'warn-check':
        assert 'strict summary check failed' in out['systemMessage']
        assert sys.argv[4] in out['systemMessage']
    elif sys.argv[2] == 'warn-mismatch':
        assert 'strict summary check passed' in out['systemMessage']
        assert 'disagrees with summary.md STATUS:' in out['systemMessage']
    else:
        raise AssertionError('unknown warning expectation')
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
check block 'real strict checker missing GATES blocks' yes
transcript 'Implementation is running; waiting for the background lane.'
check allow 'ordinary mid-task prose never invokes checker' no
transcript 'STATUS: PASS'
check allow 'STATUS without GATES never invokes checker' no
transcript $'I will report the STATUS: PASS when done.\nGATES: not yet run'
check allow 'prospective report prose never invokes checker' no
transcript $'Note that the template requires a STATUS: PASS line.\nGATES: line follows it.'
check allow 'template explanation prose never invokes checker' no
transcript $'STATUS: PASS\nGATES: codex-verify PASS'
check block 'bare real STATUS claim still validates' yes
transcript "$CLAIM"
check block 'labelled real STATUS claim still validates' yes
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
transcript "$CLAIM"$'\nARTIFACTS: '"$GOOD"
check allow 'passing ARTIFACTS inside repo without registry' yes route-lead-charlie-critical false cccccccc1234 "$GOOD"
registry '.orchestra/failing-task' lead-alpha aaaaaaaa
check warn 'registry without this lead rejects stale passing ARTIFACTS' no
rm "$REPO/.orchestra/REGISTRY.md"
mkdir -p "$TMP/outside-task" "$TMP/repo-sibling"
cp "$GOOD/brief.md" "$GOOD/plan.md" "$GOOD/summary.md" "$TMP/outside-task/"
cp "$GOOD/brief.md" "$GOOD/plan.md" "$GOOD/summary.md" "$TMP/repo-sibling/"
ln -s "$TMP/outside-task" "$REPO/.orchestra/outside-link"
for path in "$TMP/outside-task" "$TMP/repo-sibling" "$REPO/.orchestra/outside-link"; do
  transcript "$CLAIM"$'\nARTIFACTS: '"$path"
  check warn 'ARTIFACTS outside repo root is rejected' no
done
transcript "$CLAIM"$'\nARTIFACTS: '"$BAD"
run_payload "$(make_payload route-lead-charlie-critical false cccccccc1234 "$GOOD")"
assert_output block 'nested cwd resolves Git root for ARTIFACTS' yes
run_payload "$(make_payload route-lead-charlie-critical false cccccccc1234 "$TMP")"
assert_output warn 'unresolvable repo root rejects ARTIFACTS' no
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
# Absence of Python must remain silent, while the normal warn cases above retain stderr.
rm "$TMP/fakebin/python3"
payload="$(make_payload)"
rm -f "$MARKER"
set +e
RUN_OUTPUT="$(printf '%s' "$payload" | PATH="$TMP/fakebin" "$HOOK" 2>"$TMP/stderr")"
RUN_STATUS=$?
set -e
assert_output allow 'missing Python fails open without startup stderr' no
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
check warn-check 'C BLOCKED with missing GATES warns without blocking' yes
transcript $'STATUS: FAIL\nGATES: failed'
check warn-check 'C FAIL with missing GATES warns without blocking' yes

registry '.orchestra/unsaved task'
for status in PASS ACCEPTED BLOCKED; do
  transcript "STATUS: $status"$'\nGATES: codex-verify INCONCLUSIVE'
  check note "$status without summary emits only a note" no route-lead-charlie-critical false cccccccc1234 "$NOSUMMARY"
  [[ "$RUN_OUTPUT" == *"$status was claimed"* ]] || fail 'note did not identify claimed status'
done

ESCALATION="$REPO/.orchestra/escalation"
PASSED_ESCALATION="$REPO/.orchestra/passed-escalation"
mkdir -p "$ESCALATION" "$PASSED_ESCALATION"
cp "$GOOD/brief.md" "$GOOD/plan.md" "$GOOD/summary.md" "$PASSED_ESCALATION/"
cp "$GOOD/plan.md" "$ESCALATION/plan.md"
printf 'RISK: normal\n' > "$ESCALATION/brief.md"
cat > "$ESCALATION/summary.md" <<'SUMMARY'
STATUS: BLOCKED
CLAUDE PROFILE: normal
PROMOTIONS: none
DISPATCH: codex-first
INVESTIGATION: none
LANES: codex
GATES: codex-verify PASS; codex-review BLOCKING
ROUNDS: 1
SUMMARY
printf 'CODEX-VERDICT: PASS\n' > "$ESCALATION/codex-verdict.md"
printf 'CODEX-REVIEW: BLOCKING 1 / NONBLOCKING 0\n' > "$ESCALATION/codex-review.md"
registry '.orchestra/escalation'
transcript $'STATUS: BLOCKED\nGATES: codex-review BLOCKING'
CHECK_ERROR_TEXT='ERROR: adversarial review is not CLEAR/NONBLOCKING' check warn-check 'C honest BLOCKED summary with real gate failure can escalate' yes route-lead-charlie-critical false cccccccc1234 "$ESCALATION"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: BLOCKED'* ]] || fail 'recorded BLOCKED status was not read'
transcript "$CLAIM"
CHECK_ERROR_TEXT='ERROR: adversarial review is not CLEAR/NONBLOCKING' check block 'C PASS claim contradicting BLOCKED summary still blocks' yes route-lead-charlie-critical false cccccccc1234 "$ESCALATION"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: BLOCKED'* ]] || fail 'PASS block did not identify recorded BLOCKED status'
python3 - "$ESCALATION/summary.md" "$PASSED_ESCALATION/summary.md" <<'PY'
import sys
from pathlib import Path
failed, passed = map(Path, sys.argv[1:])
failed.write_text(failed.read_text().replace('STATUS: BLOCKED', '[lead-charlie] STATUS: FAIL'))
passed.write_text(passed.read_text().replace('STATUS: PASS', '[lead-charlie] STATUS: BLOCKED'))
PY
transcript $'STATUS: FAIL\nGATES: codex-review BLOCKING'
CHECK_ERROR_TEXT='ERROR: adversarial review is not CLEAR/NONBLOCKING' check warn-check 'C honest FAIL report never blocks' yes route-lead-charlie-critical false cccccccc1234 "$ESCALATION"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: FAIL'* ]] || fail 'prefixed recorded FAIL status was not read'
transcript "$CLAIM"
CHECK_ERROR_TEXT='ERROR: adversarial review is not CLEAR/NONBLOCKING' check block 'C PASS claim contradicting FAIL summary still blocks' yes route-lead-charlie-critical false cccccccc1234 "$ESCALATION"
registry '.orchestra/passing task'
transcript $'STATUS: BLOCKED\nGATES: awaiting escalation'
check warn-mismatch 'C BLOCKED claim with passing PASS summary only warns' yes route-lead-charlie-critical false cccccccc1234 "$GOOD"
registry '.orchestra/passed-escalation'
check allow 'C BLOCKED claim and prefixed BLOCKED summary with passing check allow' yes route-lead-charlie-critical false cccccccc1234 "$PASSED_ESCALATION"
transcript "$CLAIM"
check warn-mismatch 'C passing checker with mismatched recorded BLOCKED status warns' yes route-lead-charlie-critical false cccccccc1234 "$PASSED_ESCALATION"

ACCEPTED_TASK="$REPO/.orchestra/accepted-task"
mkdir -p "$ACCEPTED_TASK"
cp "$ESCALATION/brief.md" "$ESCALATION/plan.md" "$ESCALATION/summary.md" "$ESCALATION/codex-verdict.md" "$ESCALATION/codex-review.md" "$ACCEPTED_TASK/"
sed -i 's/\[lead-charlie\] STATUS: FAIL/[lead-charlie] STATUS: ACCEPTED/' "$ACCEPTED_TASK/summary.md"
printf 'USER ACCEPTED: 2026-10-02 — accept the blocking review\n' >> "$ACCEPTED_TASK/brief.md"
registry '.orchestra/accepted-task'
transcript $'[lead-charlie] STATUS: ACCEPTED\nGATES: codex-verify PASS; codex-review BLOCKING'
check allow 'authorised ACCEPTED and prefixed summary allow after strict check' yes route-lead-charlie-critical false cccccccc1234 "$ACCEPTED_TASK"
transcript "$CLAIM"
check warn-mismatch 'PASS claim disagrees with accepted summary' yes route-lead-charlie-critical false cccccccc1234 "$ACCEPTED_TASK"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: ACCEPTED'* ]] || fail 'recorded ACCEPTED status was not read'
cat >> "$ACCEPTED_TASK/summary.md" <<'SUMMARY'
```
STATUS: PASS
```
SUMMARY
check warn-mismatch 'fenced PASS example cannot conceal accepted summary mismatch' yes route-lead-charlie-critical false cccccccc1234 "$ACCEPTED_TASK"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: ACCEPTED'* ]] || fail 'fenced PASS replaced recorded ACCEPTED status'
transcript $'STATUS: ACCEPTED\nGATES: codex-verify PASS'
registry '.orchestra/passing task'
check warn-mismatch 'ACCEPTED claim disagrees with PASS summary' yes route-lead-charlie-critical false cccccccc1234 "$GOOD"
registry '.orchestra/accepted-task'
sed -i '/^USER ACCEPTED:/d' "$ACCEPTED_TASK/brief.md"
CHECK_ERROR_TEXT="ERROR: STATUS: ACCEPTED requires a column-0 'USER ACCEPTED:" check block 'ACCEPTED without user authorisation blocks on strict failure' yes route-lead-charlie-critical false cccccccc1234 "$ACCEPTED_TASK"

transcript $'STATUS: ACCEPTED-ish\nGATES: codex-verify PASS'
check allow 'ACCEPTED-ish transcript is not an ACCEPTED claim' no
sed -i 's/STATUS: BLOCKED/STATUS: ACCEPTED-ish/' "$PASSED_ESCALATION/summary.md"
registry '.orchestra/passed-escalation'
transcript $'STATUS: ACCEPTED\nGATES: codex-verify PASS'
check warn-mismatch 'ACCEPTED-ish summary disagrees with ACCEPTED claim' yes route-lead-charlie-critical false cccccccc1234 "$PASSED_ESCALATION"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: unknown'* ]] || fail 'ACCEPTED-ish was parsed as a terminal status'

cat >> "$PASSED_ESCALATION/summary.md" <<'SUMMARY'
STATUS: ACCEPTED
STATUS: ACCEPTED-ish
SUMMARY
check warn-mismatch 'later ACCEPTED-ish supersedes an earlier ACCEPTED summary status' yes route-lead-charlie-critical false cccccccc1234 "$PASSED_ESCALATION"
[[ "$RUN_OUTPUT" == *'summary.md STATUS: unknown'* ]] || fail 'earlier ACCEPTED concealed the later unrecognised status'
CHECKER_OUTPUT="$("$TEST_REAL_CHECKER" --strict "$PASSED_ESCALATION")" || fail 'checker rejected the later unrecognised status with passing gates'
[[ "$CHECKER_OUTPUT" != *'authorised by brief.md USER ACCEPTED'* ]] || fail 'checker treated the later unrecognised status as ACCEPTED'
ok 'real checker treats the same later ACCEPTED-ish summary as not ACCEPTED'

cat >> "$GOOD/summary.md" <<'SUMMARY'
~~~
STATUS: BLOCKED
~~~
SUMMARY
registry '.orchestra/passing task'
transcript "$CLAIM"
check allow 'fenced BLOCKED example cannot override passing PASS summary' yes route-lead-charlie-critical false cccccccc1234 "$GOOD"

registry
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
assert {'allow', 'block', 'warn', 'note'} <= {row['decision'] for row in rows}
assert all(row['hook'] == 'orch-stop-gate' and row['event'] == 'SubagentStop' and '\n' not in row['reason'] for row in rows)
PY
ok 'claimed outcomes journal allow/block/warn/note'
before="$(wc -c < "$STATE/safety-hooks.log")"
check allow 'mid-task journal bypass' no
[ "$(wc -c < "$STATE/safety-hooks.log")" = "$before" ] || fail 'non-claim journalled'
ok 'non-claim paths never journal'

echo "PASS: $pass stop-gate cases"
