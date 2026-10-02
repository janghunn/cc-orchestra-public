#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/orch-worktree-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
REPO="$TMP/repo"
OWN="$REPO/.orchestra/wt/lead-charlie"
OTHER="$REPO/.orchestra/wt/lead-alpha"
mkdir -p "$STATE"
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$HOOK"
ok "hook shell syntax"

# Build real Git objects/refs and linked-worktree metadata directly. This suite never runs a
# writing Git command (including fixture commits); all Git probes below are read-only.
python3 - "$REPO" "$TMP/no-registry" <<'PY'
import hashlib, sys, zlib
from pathlib import Path

def make_repo(path):
    dot = path / '.git'
    for sub in ('objects', 'refs/heads', 'refs/tags'):
        (dot / sub).mkdir(parents=True, exist_ok=True)
    (dot / 'config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n')
    def obj(kind, data):
        raw = kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data
        sha = hashlib.sha1(raw).hexdigest()
        target = dot / 'objects' / sha[:2] / sha[2:]
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(zlib.compress(raw))
        return sha
    tree = obj('tree', b'')
    sha = obj('commit', (f'tree {tree}\nauthor Fixture <fixture@example.invalid> 1 +0000\n'
                         'committer Fixture <fixture@example.invalid> 1 +0000\n\nFixture\n').encode())
    for branch in ('main', 'master', 'develop', 'orch/10-a', 'orch/12-c', 'orch/unowned'):
        target = dot / 'refs/heads' / branch
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(sha + '\n')
    (dot / 'HEAD').write_text('ref: refs/heads/main\n')
    return dot

repo = Path(sys.argv[1])
dot = make_repo(repo)
make_repo(Path(sys.argv[2]))
for slot, branch in (('lead-alpha', 'orch/10-a'), ('lead-charlie', 'orch/12-c')):
    tree = repo / '.orchestra/wt' / slot
    tree.mkdir(parents=True)
    meta = dot / 'worktrees' / slot
    meta.mkdir(parents=True)
    (tree / '.git').write_text(f'gitdir: {meta}\n')
    (meta / 'gitdir').write_text(str(tree / '.git') + '\n')
    (meta / 'commondir').write_text('../..\n')
    (meta / 'HEAD').write_text('ref: refs/heads/' + branch + '\n')
PY

git -C "$REPO" rev-parse --verify HEAD >/dev/null
git -C "$OWN" rev-parse --show-toplevel >/dev/null
git -C "$REPO" worktree list --porcelain > "$TMP/worktrees"
[ "$(grep -c '^worktree ' "$TMP/worktrees")" = 3 ] || fail "fixture lacks three real Git worktrees"
ok "real commit and linked worktrees are readable without writing Git commands"

registry() {
  python3 - "$REPO" "${1:-two}" <<'PY'
import sys
from pathlib import Path
repo, mode = Path(sys.argv[1]), sys.argv[2]
rows = [('lead-charlie', 'cccccccc', 'orch/12-c', 'RUNNING')]
if mode != 'one':
    rows.append(('lead-alpha', 'aaaaaaaa', 'orch/10-a', 'ACCEPTED' if mode == 'accepted' else 'PASS' if mode == 'inactive' else mode if mode.startswith('PASS ') else 'RUNNING'))
if mode == 'four':
    rows += [('lead-bravo', 'bbbbbbbb', 'orch/11-b', 'WORKING'), ('lead-delta', 'dddddddd', 'orch/13-d', 'WORKING')]
text = '| slot | agentId | task | branch | dir | status | last update |\n| --- | --- | --- | --- | --- | --- | --- |\n'
for slot, agent, branch, status in rows:
    text += f'| {slot} | {agent} | task | {branch} | .orchestra/task-{slot}/ | {status} | now |\n'
(repo / '.orchestra/REGISTRY.md').write_text(text)
PY
}
head_at() { printf 'ref: refs/heads/%s\n' "$2" > "$1"; }

make_payload() {
  python3 - "$1" "$2" "${3:-route-lead-charlie-critical-xhigh}" "${4:-Bash}" "${5:-}" <<'PY'
import json, sys
p = {'hook_event_name': 'PreToolUse', 'cwd': sys.argv[1], 'tool_name': sys.argv[4], 'tool_input': {'command': sys.argv[2]}}
if sys.argv[3] != 'orchestrator': p['agent_type'] = sys.argv[3]
if sys.argv[5]: p['agent_id'] = sys.argv[5]
print(json.dumps(p))
PY
}
run_payload() {
  set +e
  RUN_OUTPUT="$(printf '%s' "$1" | CC_ORCH_STATE_DIR="$STATE" "$HOOK" 2>"$TMP/stderr")"
  RUN_STATUS=$?
  set -e
}
assert_output() {
  local expected="$1" label="$2" rule="${3:-}"
  [ "$RUN_STATUS" -eq 0 ] || fail "$label exited $RUN_STATUS instead of 0"
  [ ! -s "$TMP/stderr" ] || fail "$label wrote stderr"
  if [ "$expected" = allow ]; then
    [ -z "$RUN_OUTPUT" ] || fail "$label unexpectedly emitted: $RUN_OUTPUT"
  else
    if ! python3 - "$RUN_OUTPUT" "$rule" <<'PY'
import json, sys
h = json.loads(sys.argv[1])['hookSpecificOutput']
assert h['hookEventName'] == 'PreToolUse'
assert h['permissionDecision'] == 'deny'
assert 'worktree-guard.off' in h['permissionDecisionReason']
assert sys.argv[2] in h['permissionDecisionReason']
PY
    then fail "$label missing deny JSON: $RUN_OUTPUT"; fi
  fi
  ok "$label (exit 0)"
}
check() {
  local expected="$1" label="$2" cwd="$3" command="$4" actor="${5:-route-lead-charlie-critical-xhigh}" rule="${6:-}" tool="${7:-Bash}" agent="${8:-}"
  run_payload "$(make_payload "$cwd" "$command" "$actor" "$tool" "$agent")"
  assert_output "$expected" "$label" "$rule"
}

registry
check deny 'R1 main commit' "$REPO" 'git commit -m x' lead-charlie R1
check deny 'JSON-escaped tab before Git operation' "$REPO" $'git\tcommit -m x' lead-charlie R1
check allow 'own branch and worktree' "$OWN" 'git commit -m x'
check deny 'other lead branch/worktree' "$OTHER" 'git commit'
check deny 'git -C targets other lead' "$OWN" "git -C '$OTHER' commit -m x"
head_at "$REPO/.git/worktrees/lead-alpha/HEAD" orch/unowned
check deny 'R3 other worktree even on unowned branch' "$OTHER" 'git commit' lead-charlie R3
head_at "$REPO/.git/worktrees/lead-alpha/HEAD" orch/10-a
head_at "$REPO/.git/worktrees/lead-charlie/HEAD" orch/10-a
check deny 'R2 other branch in own worktree' "$OWN" 'git commit' lead-charlie R2
registry inactive
check allow 'PASS row is inactive' "$OWN" 'git commit'
registry accepted
check allow 'ACCEPTED row is inactive' "$OWN" 'git commit'
registry 'PASS (worktree)'
check deny 'annotated PASS remains conservatively active' "$OWN" 'git commit' lead-charlie R2
head_at "$REPO/.git/worktrees/lead-charlie/HEAD" orch/12-c
registry four
check allow 'orchestrator integration merge' "$REPO" 'git merge orch/12-c' orchestrator
check allow 'orchestrator checkout main' "$REPO" 'git checkout main' orchestrator
check deny 'R4 literal T8 switch with four leads' "$REPO" 'git switch orch/09-x' lead-charlie R4
head_at "$REPO/.git/HEAD" orch/12-c
check deny 'R4 shared checkout on own branch' "$REPO" 'git commit' lead-charlie R4
registry one
check allow 'one active lead in-place' "$REPO" 'git commit'
head_at "$REPO/.git/HEAD" main
check allow 'single lead creates task branch from main' "$REPO" 'git switch -c orch/12-c'
head_at "$REPO/.git/HEAD" master
check allow 'A new branch then commit uses effective branch' "$REPO" 'git switch -c orch/new && git commit'
check allow 'A checkout branch then add and commit uses effective branch' "$REPO" 'git checkout -b orch/new && git add -A && git commit'
check allow 'A standalone new-branch switch remains allowed' "$REPO" 'git switch -c orch/new'
check deny 'B skipped conditional switch retains protected branch before semicolon' "$REPO" 'false && git switch -c orch/new; git commit -m x' lead-charlie R1
check deny 'B skipped conditional switch retains protected branch before AND' "$REPO" 'false && git switch -c orch/new && git commit -m x' lead-charlie R1
check deny 'B skipped conditional checkout retains protected branch for add' "$REPO" 'false && git checkout -b orch/new; git add -A' lead-charlie R1
check deny 'B OR-conditional switch retains protected branch' "$REPO" 'true || git switch -c orch/new; git commit -m x' lead-charlie R1
check deny 'B newline after AND keeps branch change conditional' "$REPO" $'false &&\ngit switch -c orch/new; git commit -m x' lead-charlie R1
check allow 'B unconditional switch before semicolon replaces branch' "$REPO" 'git switch -c orch/new; git commit -m x'
check allow 'B unconditional switch before AND replaces branch' "$REPO" 'git switch -c orch/new && git commit -m x'
check allow 'B conditional switch retains effective branch instead of live HEAD' "$REPO" 'git switch -c orch/new; false && git switch -c orch/later; git commit -m x'
check deny 'B conditional existing branch switch evaluates protected new candidate' "$OWN" 'false && git switch develop; git commit -m x' lead-charlie R1
check allow 'B conditional switch between task branches stays allowed' "$OWN" 'false && git switch -c orch/new; git commit -m x'
check allow 'B unconditional switch after semicolon replaces branch candidates' "$OWN" 'false && git switch develop; git switch -c orch/new; git commit -m x'
check allow 'B unconditional switch after newline replaces branch candidates' "$OWN" $'false && git switch develop\ngit switch -c orch/new; git commit -m x'
check deny 'B composed cwd and branch candidates retain protected combination' "$REPO" "false && cd '$OWN' && git switch -c orch/new; git commit -m x" lead-charlie R1
check allow 'B composed candidates keep safe branch set isolated by checkout' "$REPO" "false && cd '$OWN' && git switch -c orch/new; git -C '$OWN' commit -m x"
check allow 'A forced checkout branch creation is tracked' "$REPO" 'git checkout -B orch/new && git commit'
check allow 'A forced switch branch creation is tracked' "$REPO" 'git switch -C orch/new && git commit'
check allow 'A existing task branch switch is tracked' "$REPO" 'git switch orch/12-c && git commit'
check deny 'A checkout path does not change branch' "$REPO" 'git checkout -- somefile && git commit -m x' lead-charlie R1
check deny 'A bare path argument does not change branch' "$REPO" 'git checkout somefile && git commit' lead-charlie R1
check deny 'A multiple arguments remain ambiguous' "$REPO" 'git checkout orch/12-c somefile && git commit' lead-charlie R1
check deny 'A explicit detach does not become a branch override' "$REPO" 'git switch --detach orch/12-c && git commit' lead-charlie R1
sha="$(git -C "$REPO" rev-parse HEAD)"
check deny 'A detached SHA does not become a branch override' "$REPO" "git checkout $sha && git commit" lead-charlie R1
check deny 'A switch into protected branch then commit is denied' "$OWN" 'git switch develop && git commit -m x' lead-charlie R1
check deny 'A checkout into protected branch then commit is denied' "$OWN" 'git checkout develop && git commit' lead-charlie R1
mkdir -p "$OWN/subdir"
check deny 'B conditional branch candidates survive checkout path aliases' "$OWN" "false && git -C '$OWN/subdir' switch develop; git -C '$OWN' commit -m x" lead-charlie R1
check deny 'A branch override survives -C and cd aliases' "$OWN" "git -C '$OWN/subdir' switch develop; cd '$OWN'; git commit" lead-charlie R1
check allow 'A branch override is isolated by checkout root' "$OWN" "git switch develop; git -C '$REPO' switch -c orch/new; git -C '$REPO' commit"
check deny 'A separate checkout keeps its own effective branch' "$OWN" "git switch develop; git -C '$REPO' switch -c orch/new; git commit" lead-charlie R1
check allow 'A branch overrides do not leak between payloads' "$OWN" 'git commit'
head_at "$REPO/.git/HEAD" main
registry
check deny 'A creating a branch still cannot bypass shared-checkout collision' "$REPO" 'git switch -c orch/new && git commit' lead-charlie R4
check deny 'B skipped conditional cd retains shared checkout candidate' "$REPO" "false && cd '$OWN'; git commit" lead-charlie R1
check deny 'B skipped conditional pushd retains shared checkout candidate' "$REPO" "false && pushd '$OWN'; git commit" lead-charlie R1
check deny 'B OR-conditional cd retains shared checkout candidate' "$REPO" "true || cd '$OWN'; git commit" lead-charlie R1
check deny 'B conditional cd also evaluates the new checkout candidate' "$OWN" "false && cd '$OTHER'; git commit" lead-charlie R2
check deny 'B conditional cd followed by newline retains alternatives' "$REPO" "false && cd '$OWN'"$'\ngit commit' lead-charlie R1
check deny 'B newline after AND does not erase conditional execution' "$REPO" $'false &&\n'"cd '$OWN'; git commit" lead-charlie R1
check allow 'B unconditional cd after semicolon replaces candidates' "$REPO" "false && cd '$OTHER'; cd '$OWN'; git commit"
check allow 'B unconditional cd after newline replaces candidates' "$REPO" "false && cd '$OTHER'"$'\n'"cd '$OWN'; git commit"
check allow 'B absolute -C resolves all cwd candidates to own checkout' "$REPO" "false && cd '$OTHER'; git -C '$OWN' commit"
check allow 'B conditional cd within own checkout stays allowed' "$OWN" "false && cd '$OWN/subdir'; git commit"
check allow 'B conditional unresolvable cd keeps safe previous candidate' "$OWN" 'false && cd $UNSET_VAR; git commit'
check deny 'B conditional unresolvable cd keeps protected previous candidate' "$REPO" 'false && cd $UNSET_VAR; git commit' lead-charlie R1
check allow 'cd to own worktree from shared main' "$REPO" "cd '$OWN' && git commit -m x"
check deny 'cd to other worktree' "$OWN" "cd '$OTHER' && git commit"
check deny 'second Git invocation tracked' "$OWN" "git status && cd '$OTHER' && git commit"
check deny 'pushd tracks target' "$OWN" "pushd '$OTHER'; git commit"
for operation in cd pushd; do
  check deny "failed $operation keeps shared checkout" "$REPO" "$operation '$TMP/missing'; git commit" lead-charlie R1
  check allow "failed $operation keeps own worktree" "$OWN" "$operation '$TMP/missing'; git commit"
  check allow "successful $operation enters own worktree" "$REPO" "$operation '$OWN'; git commit"
done
printf 'not a directory\n' > "$TMP/not-directory"
check deny 'cd to regular file keeps shared checkout' "$REPO" "cd '$TMP/not-directory'; git commit" lead-charlie R1
HOME="$TMP" check deny 'tilde path enters protected checkout' "$OWN" 'cd ~/repo && git commit' lead-charlie R1
HOME="$TMP" check allow 'tilde path enters own worktree' "$REPO" 'cd ~/repo/.orchestra/wt/lead-charlie && git commit'
HOME="$REPO" check deny 'bare tilde enters protected checkout' "$OWN" 'cd ~ && git commit' lead-charlie R1
HOME="$OWN" check allow 'bare tilde enters own worktree' "$REPO" 'cd ~ && git commit'
HOME="$TMP" check deny 'pushd expands tilde path' "$OWN" 'pushd ~/repo; git commit' lead-charlie R1
HOME="$TMP" check deny 'git -C expands tilde path' "$OWN" 'git -C ~/repo commit' lead-charlie R1
check allow 'named-user tilde remains unresolvable' "$REPO" 'cd ~otheruser/repo && git commit'
for command in 'git -C $UNSET_VAR commit' 'git --git-dir=/x commit' 'git --work-tree=/x commit' 'cd - && git commit' 'cd && git commit' 'cd $UNSET_VAR && git commit' 'GIT_DIR=/x git commit'; do
  check allow "unresolvable: $command" "$REPO" "$command"
done
check deny 'dev main commit' "$REPO" 'git commit' dev-1 R1
check allow 'dev works on lead branch' "$OWN" 'git commit' dev-1
check deny 'Opus dev protected branch' "$REPO" 'git commit' dev-opus-2 R1
registry one
check allow 'explicit non-protected push from main' "$REPO" 'git push -u origin orch/12-c'
check allow 'explicit non-protected destination from main' "$REPO" 'git push origin HEAD:refs/heads/orch/12-c'
check allow 'explicit push with --repo remote' "$REPO" 'git push --repo origin orch/12-c'
check allow 'explicit push with --repo=remote' "$REPO" 'git push --repo=origin orch/12-c'
check deny 'bare push from main' "$REPO" 'git push' lead-charlie R1
check deny 'explicit main push from main' "$REPO" 'git push origin main' lead-charlie R1
check deny 'refspec targeting main' "$REPO" 'git push origin orch/12-c:refs/heads/main' lead-charlie R1
for command in 'git push origin main' 'git push origin HEAD:main' 'git push origin orch/12-c:refs/heads/main' 'git push origin +main' 'git push --all' 'git push --mirror'; do
  check deny "protected push from task branch: $command" "$OWN" "$command" lead-charlie R1
done
check allow 'tag-only push from own task worktree' "$OWN" 'git push --tags'
check deny 'tags flag does not exempt an explicit protected branch' "$OWN" 'git push --tags origin main' lead-charlie R1
for refspec in 'refs/heads/*:refs/heads/*' '*' 'refs/heads/*' 'refs/heads/*:refs/heads/m*'; do
  check deny "protected wildcard destination: $refspec" "$OWN" "git push origin '$refspec'" lead-charlie R1
done
for refspec in 'orch/*' 'releases/*' 'refs/heads/*:refs/heads/orch/*' 'refs/heads/*:refs/heads/releases/*'; do
  check allow "non-protected wildcard destination: $refspec" "$OWN" "git push origin '$refspec'"
done
check allow 'explicit task push from task branch' "$OWN" 'git push -u origin orch/12-c'
check allow 'bare push from task branch' "$OWN" 'git push'
check allow 'HEAD push from task branch' "$OWN" 'git push origin HEAD'
check deny 'HEAD push from protected branch' "$REPO" 'git push origin HEAD' lead-charlie R1
check deny 'protected destination after unresolved refspec' "$OWN" 'git push origin HEAD main' lead-charlie R1
registry
for command in 'git status' 'git diff' 'git log' 'git show' 'git fetch' 'git rev-parse HEAD' 'git worktree add /unused' 'git branch -a' 'git tag -l'; do
  check allow "read-only/unclassified: $command" "$REPO" "$command"
done
check allow 'quoted instruction is data' "$REPO" 'echo "remember to git commit on main"'
check allow 'single-quoted instruction is data' "$REPO" "printf '%s' 'git commit'"
check allow 'heredoc commit is data' "$REPO" $'cat <<\'EOF\'\ngit commit\nEOF'
check allow 'comment commit is data' "$REPO" '# git commit'
check allow 'Read tool bypass' "$REPO" 'git commit' lead-charlie '' Read
check allow 'Monitor tool bypass' "$REPO" 'git commit' lead-charlie '' Monitor
for payload in '{git commit' '' '[]' '{"tool_name":"Bash","tool_input":null}'; do
  run_payload "$payload"
  assert_output allow 'malformed/empty payload'
done
touch "$STATE/worktree-guard.off"
check allow 'off-switch bypass' "$REPO" 'git commit'
rm "$STATE/worktree-guard.off"
check allow 'no registry exists' "$TMP/no-registry" 'git commit'
for malformed in 'not a table' '| lead-charlie | cccccccc |' '| slot | agentId | task | branch | status |' '| slot | agentId | task | branch | dir | status | last update |'; do
  printf '%s\n' "$malformed" > "$REPO/.orchestra/REGISTRY.md"
  check allow 'malformed/header-only registry' "$REPO" 'git commit'
done
registry
check allow 'non-Git target' "$TMP" 'git commit'
check deny 'truncated registry identity' "$REPO" 'git commit' unknown R1 Bash cccccccc123456789
check allow 'short identity prefix is not trusted' "$REPO" 'git commit' unknown '' Bash cccc
check deny 'registry identity overrides agent type' "$REPO" 'git commit' verifier R1 Bash cccccccc1234
check deny 'assignment and env prefixes' "$REPO" 'FLAG=x env TEST=y git -c color.ui=false commit' lead-charlie R1
for command in 'git checkout main' 'git switch main' 'git branch -f orch/12-c' 'git branch -D stale' 'git branch -m renamed' 'git branch -M renamed' 'git tag -f v1' 'git tag -d v1'; do
  check deny "R4 ref mutation: $command" "$REPO" "$command" lead-charlie R4
done
for op in commit merge rebase cherry-pick revert reset am apply add rm mv stash restore; do
  check deny "R1 index mutation: $op" "$REPO" "git $op" lead-charlie R1
done
check deny 'sequential relative -C paths' "$OWN" 'git -C .. -C lead-alpha commit'

# Journal checks include real concurrent append/rotation, unknown actors, and the bash fast path.
python3 - "$STATE/safety-hooks.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows and {'allow', 'deny', 'skip'} <= {row['decision'] for row in rows}
for row in rows:
    assert all(key in row for key in ('timestamp', 'hook', 'event', 'agent_type', 'agent_id', 'decision', 'reason'))
    assert '\n' not in row['reason']
PY
ok 'evaluated invocations journal valid one-line decisions'
before="$(wc -c < "$STATE/safety-hooks.log")"
check allow 'unknown actor mutation bypass' "$REPO" 'git commit' unrelated
check allow 'fast path with no mutation keywords' "$REPO" 'printf hello'
check allow 'non-git add command fast path' "$REPO" 'npm add package'
[ "$(wc -c < "$STATE/safety-hooks.log")" = "$before" ] || fail 'fast/unknown path journalled'
ok 'fast and unknown paths do not journal'
# Confirm the non-git fast path avoids Python, beyond simply emitting no journal record.
mkdir -p "$TMP/fastbin"
cat > "$TMP/fastbin/python3" <<'PYTHON_STUB'
#!/usr/bin/env bash
touch "$TEST_PYTHON_MARKER"
exit 1
PYTHON_STUB
chmod +x "$TMP/fastbin/python3"
payload="$(make_payload "$REPO" 'npm add package')"
PATH="$TMP/fastbin:$PATH" TEST_PYTHON_MARKER="$TMP/python-called" run_payload "$payload"
assert_output allow 'non-git add command bypasses Python'
[ ! -e "$TMP/python-called" ] || fail 'non-git fast path spawned Python'
python3 - "$HOOK" "$STATE" "$OWN" <<'PY'
import concurrent.futures, json, os, subprocess, sys
from pathlib import Path
hook, state, cwd = sys.argv[1:]
path = Path(state) / 'safety-hooks.log'
old = json.dumps({'padding': 'x' * 1000}) + '\n'
path.write_text(old * 2200)
env = dict(os.environ, CC_ORCH_STATE_DIR=state)
def invoke(n):
    payload = {'hook_event_name': 'PreToolUse', 'agent_type': 'lead-charlie', 'agent_id': f'rotation-{n}',
               'cwd': cwd, 'tool_name': 'Bash', 'tool_input': {'command': 'git commit'}}
    p = subprocess.run([hook], input=json.dumps(payload), text=True, capture_output=True, env=env)
    assert p.returncode == 0 and not p.stdout and not p.stderr
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(invoke, range(24)))
rows = [json.loads(line) for line in path.read_text().splitlines()]
assert {row.get('agent_id') for row in rows if 'agent_id' in row} == {f'rotation-{n}' for n in range(24)}
assert path.stat().st_size < 2 * 1024 * 1024
assert not (Path(state) / 'safety-hooks.trim.lock').exists()
PY
ok 'concurrent journal rotation retains every new record'

echo "PASS: $pass worktree-guard cases"
