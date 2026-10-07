#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CC_ORCH_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME"
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$ROOT/install.sh"
ok 'installer shell syntax'
help="$(bash "$ROOT/install.sh" --help)"
[[ "$help" == *--safety-hooks-only* ]] || fail 'help does not describe safety-only mode'
ok 'help exits 0 and lists --safety-hooks-only'

install_hooks() { bash "$ROOT/install.sh" --safety-hooks-only; }
install_hooks
python3 - "$CC_ORCH_SETTINGS" <<'PY'
import json, sys
assert isinstance(json.load(open(sys.argv[1])), dict)
PY
ok 'absent settings file becomes valid JSON'

assert_registration() {
  python3 - "$CC_ORCH_SETTINGS" "$ROOT" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, root, event, matcher, basename, timeout = sys.argv[1:]
entries = json.load(open(path))['hooks'][event]
found = [(entry, hook) for entry in entries for hook in entry['hooks'] if basename in hook.get('command', '')]
assert len(found) == 1, found
entry, hook = found[0]
assert entry['matcher'] == matcher
assert hook['type'] == 'command'
assert hook['command'] and root + '/hooks/' + basename in hook['command']
assert hook['command'].endswith('|| true')
assert isinstance(hook['timeout'], (int, float)) and hook['timeout'] == int(timeout)
PY
}
assert_registration PreToolUse Bash orch-worktree-guard.sh 10
ok 'PreToolUse has a concrete current-path command, matcher, fail-open suffix and timeout'
assert_registration SubagentStop '(route-)?lead-.*' orch-stop-gate.sh 30
ok 'SubagentStop has a concrete current-path command, matcher, fail-open suffix and timeout'
assert_registration SessionStart compact orch-compact-context.sh 10
ok 'SessionStart has a concrete current-path command, compact matcher, fail-open suffix and timeout'
cp "$CC_ORCH_SETTINGS" "$TMP/first.json"
install_hooks
cmp "$CC_ORCH_SETTINGS" "$TMP/first.json" || fail 'second registration changes settings'
assert_registration PreToolUse Bash orch-worktree-guard.sh 10
assert_registration SubagentStop '(route-)?lead-.*' orch-stop-gate.sh 30
ok 'second run retains exactly one non-empty command per hook and identical bytes'
assert_registration SessionStart compact orch-compact-context.sh 10
ok 'second run retains exactly one compaction recovery registration'

python3 - "$CC_ORCH_SETTINGS" "$TMP/unrelated.json" <<'PY'
import json, sys
unrelated = {'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo keep-me', 'timeout': 17}]}
settings = {'env': {'UNCHANGED': 'literal $value with spaces'}, 'hooks': {'PreToolUse': [unrelated]}}
with open(sys.argv[1], 'w') as out: json.dump(settings, out, indent=2); out.write('\n')
with open(sys.argv[2], 'w') as out: json.dump(settings, out, indent=2); out.write('\n')
PY
install_hooks
install_hooks
python3 - "$CC_ORCH_SETTINGS" "$TMP/unrelated.json" <<'PY'
import json, sys
now, before = [json.load(open(p)) for p in sys.argv[1:]]
for old, current in [(before['env'], now['env']), (before['hooks']['PreToolUse'][0], now['hooks']['PreToolUse'][0])]:
    assert json.dumps(old).encode() == json.dumps(current).encode()
# Assert the original formatted value blocks themselves survive byte-for-byte too.
for key in ('env',):
    value = json.dumps(before[key], indent=2).replace('\n', '\n  ')
    assert value in open(sys.argv[1]).read()
PY
ok 'unrelated hook and top-level setting survive two merges unchanged'

python3 - "$CC_ORCH_SETTINGS" "$TMP/stale.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
entry = settings['hooks']['PreToolUse'][1]
entry['hooks'][0]['command'] = "bash '/old/checkout/hooks/orch-worktree-guard.sh' || true"
entry['hooks'].append({'type': 'command', 'command': 'echo colocated', 'timeout': 5})
with open(sys.argv[1], 'w') as out: json.dump(settings, out, indent=2); out.write('\n')
with open(sys.argv[2], 'w') as out: json.dump(settings, out, indent=2); out.write('\n')
PY
install_hooks
assert_registration PreToolUse Bash orch-worktree-guard.sh 10
python3 - "$CC_ORCH_SETTINGS" "$TMP/stale.json" <<'PY'
import json, sys
now, old = [json.load(open(p)) for p in sys.argv[1:]]
assert len(now['hooks']['PreToolUse']) == len(old['hooks']['PreToolUse'])
assert now['hooks']['PreToolUse'][0] == old['hooks']['PreToolUse'][0]
assert now['hooks']['PreToolUse'][1]['hooks'][1] == old['hooks']['PreToolUse'][1]['hooks'][1]
PY
ok 'stale hook path heals in place without duplicating or dropping co-located hooks'

python3 - "$ROOT/guardrails.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
for event, matcher, basename, timeout in [('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10), ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30)]:
    found = [(entry, hook) for entry in settings['hooks'][event] for hook in entry['hooks'] if basename in hook.get('command', '')]
    assert len(found) == 1
    entry, hook = found[0]
    assert entry['matcher'] == matcher and hook['type'] == 'command'
    assert '/home/janghun/cc-orchestra/hooks/' + basename in hook['command']
    assert hook['command'].endswith('|| true') and isinstance(hook['timeout'], (int, float)) and hook['timeout'] == timeout
PY
ok 'guardrails JSON contains both matching registrations'

python3 - "$ROOT/guardrails.json" <<'PY'
import json, sys
import shlex
settings = json.load(open(sys.argv[1]))
found = [(entry, hook) for entry in settings['hooks']['SessionStart'] for hook in entry['hooks']
         if 'orch-compact-context.sh' in hook.get('command', '')]
assert len(found) == 1, found
entry, hook = found[0]
assert entry['matcher'] == 'compact' and hook['type'] == 'command'
# Identical command strings let Claude Code run the handler once when both guardrails and user settings register it.
assert hook['command'] == 'bash ' + shlex.quote('/home/janghun/cc-orchestra/hooks/orch-compact-context.sh') + ' || true'
assert isinstance(hook['timeout'], (int, float)) and hook['timeout'] == 10
PY
ok 'guardrails JSON contains the matching compaction recovery registration'

python3 - "$ROOT" <<'PY'
import json, re, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
base = 'HEAD'
for ref in ('refs/heads/main', 'refs/remotes/origin/main'):
    resolved = subprocess.run(['git', '-C', str(root), 'rev-parse', '--verify', ref + '^{commit}'], capture_output=True, text=True)
    if resolved.returncode:
        continue
    ancestor = subprocess.run(['git', '-C', str(root), 'merge-base', 'HEAD', ref], capture_output=True, text=True)
    base = ancestor.stdout.strip() if ancestor.returncode == 0 else resolved.stdout.strip()
    break
old = subprocess.check_output(['git', '-C', str(root), 'show', base + ':guardrails.json'], text=True)
new = (root / 'guardrails.json').read_text()
a, b = json.loads(old), json.loads(new)
assert a['hooks']['UserPromptSubmit'] == b['hooks']['UserPromptSubmit']
assert a['permissions'] == b['permissions']
assert old[old.index('  "permissions":'):] == new[new.index('  "permissions":'):]
start = old.index('    "UserPromptSubmit":')
block = old[start:old.index('\n  },', start)]
assert block in new
old_installer = subprocess.check_output(['git', '-C', str(root), 'show', base + ':install.sh'], text=True)
installer = (root / 'install.sh').read_text()
def runtime(text): return text[text.index('install_runtime_hook() {'):text.index('\n}\n', text.index('install_runtime_hook() {')) + 3]
assert runtime(old_installer) == runtime(installer)
def install_links(text):
    start = text.index('install_repo() {')
    return re.findall(r'^  link .*$', text[start:text.index('\n}\n', start)], re.M)
old_links, new_links = install_links(old_installer), install_links(installer)
# Additive backend aliases are intentional. Preserve every existing hybrid link in order;
# the safety-only filesystem assertion below still prohibits creating any of these links.
# orch-archive is an intentional additive command link (task 38).
# orch-gc is an intentional additive command link (task 64).
added = {'cc-orch-codex', 'codex-run-codex', 'orch-codex-route', 'orch-archive', 'orch-gc'}
# agents/verifier.md is generated from templates/verifier.md.tpl since the verifier became a
# roster artifact; its installer symlink is intentionally gone. Every other historical link
# must still be present, in order, and re-introducing a verifier.md link still fails below.
expected = [line for line in old_links if 'agents/verifier.md' not in line]
assert expected == [line for line in new_links
                    if line in expected or line.rsplit('/', 1)[-1].rstrip('"') not in added]
PY
ok 'existing prompt hook, permissions, runtime installer function and hybrid links are preserved'

[ -x "$ROOT/hooks/orch-worktree-guard.sh" ] && [ -x "$ROOT/hooks/orch-stop-gate.sh" ] || fail 'hook executable bits missing'
ok 'both hooks exist and are executable'
[ -x "$ROOT/hooks/orch-compact-context.sh" ] || fail 'compaction hook executable bit missing'
ok 'compaction hook exists and is executable'
python3 - "$HOME" <<'PY'
from pathlib import Path
import sys
files = sorted(str(path.relative_to(sys.argv[1])) for path in Path(sys.argv[1]).rglob('*'))
assert files == ['.claude', '.claude/settings.json'], files
PY
ok 'safety-only mode creates no links, agents, service files or other HOME state'

CHECK_HOME="$TMP/checkhome"
FAKEBIN="$TMP/fakebin"
mkdir -p "$CHECK_HOME" "$FAKEBIN"
for provider in claude codex; do
  cat > "$FAKEBIN/$provider" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$FAKEBIN/$provider"
done
before="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check || true)"
[[ "$before" == *'MISSING  orch-compact-context.sh in settings.json'* ]] || fail 'check misses absent compaction hook'
ok '--check reports the absent compaction hook in an isolated HOME'
HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --safety-hooks-only
python3 - "$CHECK_HOME/.claude/settings.json" "$ROOT" <<'PY'
import json, shlex, sys
settings = json.load(open(sys.argv[1]))
commands = [hook['command'] for entry in settings['hooks']['SessionStart'] for hook in entry['hooks']
            if 'orch-compact-context.sh' in hook.get('command', '')]
assert commands == ['bash ' + shlex.quote(sys.argv[2] + '/hooks/orch-compact-context.sh') + ' || true'], commands
PY
ok 'installed compaction command uses the same shlex quoting as guardrails'
after="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check || true)"
[[ "$after" == *'ok       orch-compact-context.sh in settings.json'* ]] || fail 'check misses installed compaction hook'
ok '--check reports the installed compaction hook in an isolated HOME'

cat > "$TMP/hook-repair.py" <<'PY'
import ast
import json
from pathlib import Path
import shlex
import sys

path, root, case, action = sys.argv[1:]
installer = (Path(root) / 'install.sh').read_text()
body = installer.split('install_safety_hooks() {', 1)[1].split('\n}\n', 1)[0] + '\n'
source = body.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
definitions = next(ast.literal_eval(node.value) for node in ast.parse(source).body
                   if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'SAFETY_HOOKS'
                           for target in node.targets))
assert definitions and any(item[2] == 'orch-compact-context.sh' for item in definitions)
by_name = {basename: (event, matcher, timeout) for event, matcher, basename, timeout in definitions}


def stale(basename, label):
    return {'type': 'prompt', 'command': "bash '/old/checkout/hooks/" + basename + "'",
            'timeout': 99, 'label': label}


def recognised(hook, basename):
    if not isinstance(hook, dict) or not isinstance(hook.get('command'), str):
        return False
    try:
        lex = shlex.shlex(hook['command'], posix=True, punctuation_chars=True)
        lex.commenters = ''
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False
    return any(token == 'hooks/' + basename or token.endswith('/hooks/' + basename) for token in tokens)


settings = {'hooks': {}}
preserved = {}
if case == 'wrong-matcher':
    for event, matcher, basename, timeout in definitions:
        entry = {'hooks': [stale(basename, 'keep')]}
        if basename != 'orch-compact-context.sh':
            entry['matcher'] = matcher + '-wrong'
        else:
            entry['hooks'][0]['command'] += '||true'
        if event == 'SubagentStop':
            user_hook = {'type': 'command', 'command': 'echo colocated-stop'}
            entry['hooks'].append(user_hook)
            preserved[event] = [{'matcher': entry['matcher'], 'hooks': [user_hook]}]
        settings['hooks'][event] = [entry]
else:
    assert case == 'duplicates', case
    for event, matcher, basename, timeout in definitions:
        first = {'matcher': matcher, 'hooks': [stale(basename, 'keep')]}
        if basename == 'orch-worktree-guard.sh':
            settings['hooks'][event] = [
                {'matcher': 'Write', 'hooks': [stale(basename, 'drop')]}, first]
            settings['hooks'][event][0]['hooks'][0]['command'] += '||true'
        elif basename == 'orch-stop-gate.sh':
            settings['hooks'][event] = [first, {'matcher': matcher, 'hooks': [stale(basename, 'drop')]}]
        else:
            first['hooks'].append(stale(basename, 'drop'))
            settings['hooks'][event] = [first]
    guard_matcher = by_name['orch-worktree-guard.sh'][1]
    preserved = {
        'PreToolUse': [
            {'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo keep-me', 'timeout': 17}]},
            {'matcher': guard_matcher, 'hooks': [{'type': 'command', 'command': 'bash /home/user/my-hooks/orch-worktree-guard.sh'}]},
            {'matcher': 'Edit', 'hooks': [{'type': 'command', 'command': "bash '/x/hooks/orch-worktree-guard.sh.bak'"}]},
            {'matcher': 'Glob', 'hooks': [{'type': 'command', 'command': "bash '/u/hooks/orch-worktree-guard.sh backup'"}]},
            {'matcher': 'Grep', 'hooks': [{'type': 'command', 'command': "bash '/u/hooks/orch-worktree-guard.sh;backup'"}]},
            {'matcher': 'LS', 'hooks': [{'type': 'command', 'command': 'bash /u/hooks/orch-worktree-guard.sh#backup'}]},
        ],
        'SubagentStop': [
            {'matcher': '.*', 'hooks': [{'type': 'command', 'command': 'bash /x/hooks/my-orch-stop-gate.sh'}]},
        ],
    }
    for event, entries in preserved.items():
        settings['hooks'][event].extend(entries)
    settings['hooks']['UserPromptSubmit'] = [{'hooks': [{'type': 'command', 'command': 'echo user-prompt'}]}]
    settings['env'] = {'UNCHANGED': 'literal $value with spaces'}
    settings['permissions'] = {'allow': ['Read'], 'deny': ['Bash(rm:*)']}

if action == 'prepare':
    with open(path, 'w') as output:
        json.dump(settings, output, indent=2)
        output.write('\n')
else:
    assert action == 'check', action
    with open(path) as source:
        current = json.load(source)
    for event, matcher, basename, timeout in definitions:
        found = [(entry, hook) for entry in current['hooks'][event] for hook in entry['hooks']
                 if recognised(hook, basename)]
        assert len(found) == 1, (basename, found)
        entry, hook = found[0]
        assert entry['matcher'] == matcher, entry
        assert hook == {'type': 'command', 'command': 'bash ' + shlex.quote(root + '/hooks/' + basename) + ' || true',
                        'timeout': timeout, 'label': 'keep'}, hook
        unrelated = [item for item in current['hooks'][event]
                     if not any(recognised(hook, basename) for hook in item['hooks'])]
        assert unrelated == preserved.get(event, []), (event, unrelated)
    if case == 'duplicates':
        assert current['hooks']['UserPromptSubmit'] == settings['hooks']['UserPromptSubmit']
        for key in ('env', 'permissions'):
            assert current[key] == settings[key], key
PY

for repair_case in wrong-matcher duplicates; do
  python3 "$TMP/hook-repair.py" "$CC_ORCH_SETTINGS" "$ROOT" "$repair_case" prepare
  install_hooks
  python3 "$TMP/hook-repair.py" "$CC_ORCH_SETTINGS" "$ROOT" "$repair_case" check
  if [[ "$repair_case" == wrong-matcher ]]; then
    ok 'wrong matcher is repaired from the installer definitions, including the compaction hook'
  else
    ok 'duplicate registrations collapse to one; unrelated and similar-path hooks and settings are unchanged'
  fi
  cp "$CC_ORCH_SETTINGS" "$TMP/repaired-$repair_case.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/repaired-$repair_case.json" || fail "repaired $repair_case settings change on re-run"
done
ok 're-running the installer on a repaired file is byte-identical'

for check_case in wrong-matcher duplicates; do
  python3 "$TMP/hook-repair.py" "$CHECK_HOME/.claude/settings.json" "$ROOT" "$check_case" prepare
  cp "$CHECK_HOME/.claude/settings.json" "$TMP/before-check.json"
  before="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check || true)"
  for pair in PreToolUse:orch-worktree-guard.sh SubagentStop:orch-stop-gate.sh SessionStart:orch-compact-context.sh; do
    event="${pair%%:*}"; basename="${pair#*:}"
    [[ "$before" == *"STALE    $basename under $event: "* ]] || fail "check misses $check_case for $basename"
    [[ "$before" != *"ok       $basename in settings.json"* ]] || fail "check reports stale $basename as ok"
    if [[ "$check_case" == duplicates ]]; then
      [[ "$before" == *"STALE    $basename under $event: 2 registrations (expect 1)"* ]] || fail "check misses duplicate count for $basename"
    else
      [[ "$before" == *"STALE    $basename under $event: matcher "* ]] || fail "check misses wrong matcher for $basename"
      if [[ "$basename" != orch-compact-context.sh ]]; then
        [[ "$before" == *"STALE    $basename under $event: command is not the fail-open"* ]] || fail "check misses absent fail-open suffix for $basename"
      fi
    fi
  done
  ok "--check reports $check_case with each safety hook's event and problem"
  cmp "$CHECK_HOME/.claude/settings.json" "$TMP/before-check.json" || fail "check writes $check_case settings"
  ok "--check leaves $check_case settings byte-identical"
  HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --safety-hooks-only
  after="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check || true)"
  for basename in orch-worktree-guard.sh orch-stop-gate.sh orch-compact-context.sh; do
    [[ "$after" == *"ok       $basename in settings.json"* ]] || fail "check misses repaired $basename"
  done
  [[ "$after" != *'STALE    orch-'* ]] || fail "check reports repaired $check_case hooks as stale"
  ok "--check accepts repaired $check_case hooks with unrelated lookalikes preserved"
done

python3 - "$CC_ORCH_SETTINGS" "$TMP/comment-settings.json" <<'PY'
import json, sys
settings = {'hooks': {
    'PreToolUse': [
        {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': "bash '/old/checkout/hooks/orch-worktree-guard.sh' || true # user's guard", 'timeout': 10}]},
        {'matcher': 'LS', 'hooks': [{'type': 'command', 'command': 'bash /u/hooks/orch-worktree-guard.sh#backup'}]},
    ],
    'SubagentStop': [
        {'matcher': '(route-)?lead-.*', 'hooks': [{'type': 'command', 'command': "bash '/old/checkout/hooks/orch-stop-gate.sh' ||true;# it's mine", 'timeout': 30}]},
        {'matcher': '.*', 'hooks': [{'type': 'command', 'command': 'echo user-stop # see hooks/orch-stop-gate.sh'}]},
        {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo user-stop \\\n# see hooks/orch-stop-gate.sh'}]},
    ],
    'SessionStart': [
        {'matcher': 'compact', 'hooks': [{'type': 'command', 'command': "bash \"/u/hooks/orch-compact-context.sh#user's\"", 'timeout': 5}]},
        {'matcher': 'compact', 'hooks': [{'type': 'command', 'command': "bash '/old/checkout/hooks/orch-compact-context.sh' || true \\\n# user's note", 'timeout': 10}]},
    ],
}}
for path in sys.argv[1:]:
    with open(path, 'w') as output:
        json.dump(settings, output, indent=2)
        output.write('\n')
PY
install_hooks
python3 - "$CC_ORCH_SETTINGS" "$TMP/comment-settings.json" "$ROOT" <<'PY'
import json, shlex, sys
now, before = [json.load(open(path))['hooks'] for path in sys.argv[1:3]]
root = sys.argv[3]
for event, matcher, basename, timeout, kept_index, count in (
    ('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10, 0, 2),
    ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30, 3, 4),
    ('SessionStart', 'compact', 'orch-compact-context.sh', 10, 2, 3),
):
    assert len(now[event]) == count, (event, now[event])
    assert now[event][kept_index] == {'matcher': matcher, 'hooks': [{
        'type': 'command', 'command': 'bash ' + shlex.quote(root + '/hooks/' + basename) + ' || true',
        'timeout': timeout,
    }]}, now[event][kept_index]
    for index in range(count):
        if index != kept_index:
            assert json.dumps(now[event][index]).encode() == json.dumps(before[event][index]).encode(), (event, index)
PY
ok 'commented hooks repair in place; word-glued and quoted hashes and comment-only paths stay untouched'
cp "$CC_ORCH_SETTINGS" "$TMP/repaired-comments.json"
install_hooks
cmp "$CC_ORCH_SETTINGS" "$TMP/repaired-comments.json" || fail 'comment repairs change on re-run'
ok 'comment repairs and backslash-newline handling are byte-identical on re-run'

python3 - "$TMP/comment-settings.json" "$CHECK_HOME/.claude/settings.json" <<'PY'
import json, sys
guard = json.load(open(sys.argv[1]))['hooks']['PreToolUse'][0]
with open(sys.argv[2], 'w') as output:
    json.dump({'hooks': {'PreToolUse': [guard]}}, output)
PY
commented="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check || true)"
[[ "$commented" == *'ok       orch-worktree-guard.sh in settings.json'* ]] || fail 'check rejects commented fail-open guard'
ok '--check accepts a fail-open command with an apostrophe in its trailing comment'

HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" python3 - "$ROOT" "$TMP" <<'PY'
import copy, json, os, shlex, subprocess, sys
from pathlib import Path
root, tmp = map(Path, sys.argv[1:])
installer = (root / 'install.sh').read_text()
body = installer.split('install_safety_hooks() {', 1)[1].split('\n}\n', 1)[0] + '\n'
source = body.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
helper = tmp / 'safety-helper.py'
helper.write_text(source)
path = Path(os.environ['CC_ORCH_SETTINGS'])
definitions = (
    ('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10),
    ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30),
    ('SessionStart', 'compact', 'orch-compact-context.sh', 10),
)
base = {'hooks': {event: [{'matcher': matcher, 'hooks': [{
    'type': 'command', 'command': 'bash ' + shlex.quote(str(root / 'hooks' / basename)) + ' || true',
    'timeout': timeout,
}]}] for event, matcher, basename, timeout in definitions}}
base['hooks']['PreToolUse'].append({'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo keep-me'}]})
ok_guard = '  ok       orch-worktree-guard.sh in settings.json'
stale_guard = '  STALE    orch-worktree-guard.sh under PreToolUse: '
missing_guard = '  MISSING  orch-worktree-guard.sh in settings.json'
for case, expected_status, expected_line in (
    ('good', 0, ok_guard),
    ('good-comment', 0, ok_guard),
    ('good-adjacent', 0, ok_guard),
    ('wrong-matcher', 1, stale_guard + 'matcher "Write" (expect "Bash")'),
    ('duplicate', 1, stale_guard + '2 registrations (expect 1)'),
    ('no-fail-open', 1, stale_guard + 'command is not the fail-open'),
    ('quoted-or', 1, missing_guard),
    ('wrong-type', 1, stale_guard),
    ('missing', 1, missing_guard),
    ('lookalike-only', 1, missing_guard),
    ('no-file', 1, missing_guard),
    ('invalid-json', 1, missing_guard),
):
    settings = copy.deepcopy(base)
    entry = settings['hooks']['PreToolUse'][0]
    hook = entry['hooks'][0]
    command = 'bash ' + shlex.quote(str(root / 'hooks' / 'orch-worktree-guard.sh'))
    if case == 'good-comment':
        hook['command'] += " # user's guard"
    elif case == 'good-adjacent':
        hook['command'] = command + ' ||true'
    elif case == 'wrong-matcher':
        entry['matcher'] = 'Write'
    elif case == 'duplicate':
        settings['hooks']['PreToolUse'].append(copy.deepcopy(entry))
    elif case == 'no-fail-open':
        hook['command'] = command
    elif case == 'quoted-or':
        hook['command'] = command + " '||' true"
    elif case == 'wrong-type':
        hook['type'] = 'prompt'
    elif case == 'missing':
        settings['hooks']['PreToolUse'].pop(0)
    elif case == 'lookalike-only':
        hook['command'] = 'bash /home/user/my-hooks/orch-worktree-guard.sh || true'
    path.write_text(json.dumps(settings, indent=2) + '\n')
    if case == 'no-file':
        path.unlink()
    elif case == 'invalid-json':
        path.write_text('{not json')
    before = path.read_bytes() if path.exists() else None
    result = subprocess.run([sys.executable, str(helper), str(path), str(root), 'check'], capture_output=True, text=True)
    assert result.returncode == expected_status, (case, result.returncode, result.stdout, result.stderr)
    assert not result.stderr, (case, result.stderr)
    assert expected_line in result.stdout, (case, result.stdout)
    assert (path.read_bytes() if path.exists() else None) == before, case
    if expected_status == 0:
        assert 'STALE' not in result.stdout, (case, result.stdout)
    else:
        assert ok_guard not in result.stdout, (case, result.stdout)
    for event, matcher, basename, timeout in definitions[1:]:
        status = 'MISSING ' if case in ('no-file', 'invalid-json') else 'ok      '
        assert f'  {status} {basename} in settings.json' in result.stdout, (case, result.stdout)
    if case == 'invalid-json':
        assert '(invalid JSON)' in result.stdout, result.stdout
    print('helper check:', case, 'exit', result.returncode)
PY
ok 'direct helper checks return independent success/failure statuses and preserve settings in all 12 cases'

python3 - "$CC_ORCH_SETTINGS" "$ROOT" <<'PY'
import json, shlex, sys
path, root = sys.argv[1:]
settings = {'hooks': {event: [{'matcher': matcher, 'hooks': [{
    'type': 'command', 'command': 'bash ' + shlex.quote(root + '/hooks/' + basename) + ' || true',
    'timeout': timeout,
}]}] for event, matcher, basename, timeout in (
    ('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10),
    ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30),
    ('SessionStart', 'compact', 'orch-compact-context.sh', 10),
)}}
settings['hooks']['SubagentStop'].append({'matcher': '.*', 'hooks': [{
    'type': 'command', 'command': "printf '%s\\n' $'user\\'s /u/hooks/orch-stop-gate.sh # note'",
}]})
with open(path, 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
cp "$CC_ORCH_SETTINGS" "$TMP/ansi-c-settings.json"
install_hooks
cmp "$CC_ORCH_SETTINGS" "$TMP/ansi-c-settings.json" || fail 'repair changes the canonical stop hook or its ANSI-C lookalike'
ok 'repair preserves the canonical stop hook and unrelated ANSI-C quoted lookalike byte-for-byte'
install_hooks
cmp "$CC_ORCH_SETTINGS" "$TMP/ansi-c-settings.json" || fail 'ANSI-C lookalike settings change on re-run'
ok 'settings containing an ANSI-C quoted lookalike remain byte-identical on re-run'

for check_case in good-continued ansi-c-lookalike; do
  HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" python3 - "$TMP/safety-helper.py" "$TMP/ansi-c-settings.json" "$ROOT" "$check_case" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
helper, fixture, root, case = sys.argv[1:]
settings = json.loads(Path(fixture).read_text())
settings['hooks']['SubagentStop'] = settings['hooks']['SubagentStop'][:1]
entries = settings['hooks']['PreToolUse']
entries.append({'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo keep-me'}]})
if case == 'good-continued':
    entries[0]['hooks'][0]['command'] += " \\\n# user's note"
else:
    assert case == 'ansi-c-lookalike', case
    entries.append({'matcher': 'Bash', 'hooks': [{
        'type': 'command', 'command': "printf '%s\\n' $'user\\'s /u/hooks/orch-worktree-guard.sh # note'",
    }]})
path = Path(os.environ['CC_ORCH_SETTINGS'])
path.write_text(json.dumps(settings, indent=2) + '\n')
before = path.read_bytes()
result = subprocess.run([sys.executable, helper, str(path), root, 'check'], capture_output=True, text=True)
assert result.returncode == (1 if case == 'good-continued' else 0), (case, result.returncode, result.stdout, result.stderr)
assert not result.stderr, (case, result.stderr)
assert 'STALE' not in result.stdout, (case, result.stdout)
for basename in ('orch-worktree-guard.sh', 'orch-stop-gate.sh', 'orch-compact-context.sh'):
    if case == 'good-continued' and basename == 'orch-worktree-guard.sh':
        assert f'  MISSING  {basename} in settings.json' in result.stdout, (case, result.stdout)
        assert f'  ok       {basename}' not in result.stdout, (case, result.stdout)
    else:
        assert f'  ok       {basename} in settings.json' in result.stdout, (case, result.stdout)
assert path.read_bytes() == before, case
print('helper check:', case, 'exit', result.returncode)
PY
  ok "direct helper check handles $check_case (continued canonical is not ours; ANSI-C lookalike ignored) without writing settings"
done

for continuation_count in 1 2; do
  python3 - "$TMP/ansi-c-settings.json" "$CC_ORCH_SETTINGS" "$continuation_count" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
hook = settings['hooks']['SubagentStop'][1]['hooks'][0]
hook['command'] = hook['command'].replace("$'", '$' + '\\\n' * int(sys.argv[3]) + "'", 1)
with open(sys.argv[2], 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
  cp "$CC_ORCH_SETTINGS" "$TMP/continued-ansi-c-settings.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/continued-ansi-c-settings.json" || fail "repair changes an ANSI-C lookalike with $continuation_count continuations"
  ok "repair preserves canonical and ANSI-C lookalike stop entries with $continuation_count continuations byte-for-byte"

  python3 - "$CC_ORCH_SETTINGS" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
settings['hooks']['SubagentStop'] = settings['hooks']['SubagentStop'][1:]
with open(sys.argv[1], 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
  cp "$CC_ORCH_SETTINGS" "$TMP/continued-lookalike-only.json"
  install_hooks
  python3 - "$CC_ORCH_SETTINGS" "$TMP/continued-lookalike-only.json" "$TMP/ansi-c-settings.json" <<'PY'
import json, sys
now, before, canonical = [json.load(open(path)) for path in sys.argv[1:]]
entries = now['hooks']['SubagentStop']
assert len(entries) == 2, entries
assert json.dumps(entries[0], indent=2).encode() == json.dumps(before['hooks']['SubagentStop'][0], indent=2).encode()
before['hooks']['SubagentStop'].append(canonical['hooks']['SubagentStop'][0])
assert now == before, now
PY
  ok "repair appends one canonical stop entry after an unchanged ANSI-C lookalike with $continuation_count continuations"
done

for substitution_case in nested backtick parameter continued; do
  python3 - "$TMP/ansi-c-settings.json" "$CC_ORCH_SETTINGS" "$substitution_case" <<'PY'
import json, sys
commands = {
    'nested': "echo \"$(echo \"user /u/hooks/orch-stop-gate.sh # user's note\")\"",
    'backtick': 'echo `echo /u/hooks/orch-stop-gate.sh`',
    'parameter': 'echo ${X:-/u/hooks/orch-stop-gate.sh}',
    'continued': 'echo $' + '\\\n' + '(echo /u/hooks/orch-stop-gate.sh)',
}
settings = json.load(open(sys.argv[1]))
settings['hooks']['SubagentStop'][1]['hooks'][0]['command'] = commands[sys.argv[3]]
with open(sys.argv[2], 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
  cp "$CC_ORCH_SETTINGS" "$TMP/substitution-$substitution_case.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/substitution-$substitution_case.json" || fail "repair changes the $substitution_case substitution lookalike beside a canonical stop hook"
  ok "repair preserves the $substitution_case substitution lookalike beside a canonical stop hook byte-for-byte"

  python3 - "$CC_ORCH_SETTINGS" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
settings['hooks']['SubagentStop'] = settings['hooks']['SubagentStop'][1:]
with open(sys.argv[1], 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
  cp "$CC_ORCH_SETTINGS" "$TMP/substitution-only.json"
  install_hooks
  python3 - "$CC_ORCH_SETTINGS" "$TMP/substitution-only.json" "$TMP/ansi-c-settings.json" <<'PY'
import json, sys
now, before, canonical = [json.load(open(path)) for path in sys.argv[1:]]
entries = now['hooks']['SubagentStop']
assert len(entries) == 2, entries
assert json.dumps(entries[0], indent=2).encode() == json.dumps(before['hooks']['SubagentStop'][0], indent=2).encode()
before['hooks']['SubagentStop'].append(canonical['hooks']['SubagentStop'][0])
assert now == before, now
PY
  ok "repair appends one canonical stop entry after an unchanged $substitution_case substitution lookalike"
  cp "$CC_ORCH_SETTINGS" "$TMP/repaired-substitution.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/repaired-substitution.json" || fail "$substitution_case substitution settings change on re-run"
  ok "$substitution_case substitution settings remain byte-identical on re-run"
done

HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" python3 - "$ROOT" "$TMP" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
root, tmp = map(Path, sys.argv[1:])
installer = (root / 'install.sh').read_text()
body = installer.split('install_safety_hooks() {', 1)[1].split('\n}\n', 1)[0] + '\n'
source = body.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
helper = tmp / 'safety-helper.py'
helper.write_text(source)
settings = json.loads((tmp / 'substitution-nested.json').read_text())
command = settings['hooks']['SubagentStop'][1]['hooks'][0]['command'].replace('orch-stop-gate.sh', 'orch-worktree-guard.sh')
settings['hooks']['SubagentStop'] = settings['hooks']['SubagentStop'][:1]
settings['hooks']['PreToolUse'].append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': command}]})
path = Path(os.environ['CC_ORCH_SETTINGS'])
path.write_text(json.dumps(settings, indent=2) + '\n')
before = path.read_bytes()
result = subprocess.run([sys.executable, str(helper), str(path), str(root), 'check'], capture_output=True, text=True)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
assert not result.stderr, result.stderr
assert 'STALE' not in result.stdout, result.stdout
for basename in ('orch-worktree-guard.sh', 'orch-stop-gate.sh', 'orch-compact-context.sh'):
    assert f'  ok       {basename} in settings.json' in result.stdout, result.stdout
assert path.read_bytes() == before
print('helper check: nested-substitution exit', result.returncode)
PY
ok 'direct helper check ignores the nested substitution lookalike without writing settings'

# N1: every non-allow-listed command survives both beside a canonical hook and alone.
python3 - "$TMP" "$ROOT" > "$TMP/lookalike-cases" <<'PY'
import copy, json, shlex, sys
from pathlib import Path
tmp, root = map(Path, sys.argv[1:])
canonical = {'hooks': {event: [{'matcher': matcher, 'hooks': [{
    'type': 'command', 'command': 'bash ' + shlex.quote(str(root / 'hooks' / basename)) + ' || true',
    'timeout': timeout,
}]}] for event, matcher, basename, timeout in (
    ('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10),
    ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30),
    ('SessionStart', 'compact', 'orch-compact-context.sh', 10),
)}}
(tmp / 'allowlist-canonical.json').write_text(json.dumps(canonical, indent=2) + '\n')
lookalikes = [
    ('semicolon', 'bash /abs/hooks/orch-stop-gate.sh || true; rm -rf /x'),
    ('and-command', 'bash /abs/hooks/orch-stop-gate.sh || true && other'),
    ('background', 'bash /abs/hooks/orch-stop-gate.sh & other'),
    ('pipeline', 'bash /abs/hooks/orch-stop-gate.sh | tee /tmp/x'),
    ('output-redirection', 'bash /abs/hooks/orch-stop-gate.sh || true > /tmp/x'),
    ('input-redirection', 'bash /abs/hooks/orch-stop-gate.sh < /dev/null'),
    ('extra-argument', 'bash /abs/hooks/orch-stop-gate.sh arg'),
    ('bash-option', 'bash -x /abs/hooks/orch-stop-gate.sh || true'),
    ('two-spaces', 'bash  /abs/hooks/orch-stop-gate.sh || true'),
    ('other-shell', 'sh /abs/hooks/orch-stop-gate.sh || true'),
    ('unquoted-space', 'bash /a b/hooks/orch-stop-gate.sh || true'),
    ('unquoted-apostrophe', "bash /it's/hooks/orch-stop-gate.sh || true"),
    ('embedded-quote', 'bash ' + shlex.quote("/old/it's/hooks/orch-stop-gate.sh") + ' || true'),
    ('double-quoted', 'bash "/abs/hooks/orch-stop-gate.sh" || true'),
    ('glued-word', "bash '/abs/hooks/orch-stop-gate.sh'x || true"),
    ('backup-extension', 'bash /abs/hooks/orch-stop-gate.sh.bak || true'),
    ('relative-path', 'bash hooks/orch-stop-gate.sh || true'),
    ('my-hooks', 'bash /abs/my-hooks/orch-stop-gate.sh || true'),
    ('glued-hash', 'bash /abs/hooks/orch-stop-gate.sh#backup'),
    ('glued-true-hash', 'bash /abs/hooks/orch-stop-gate.sh||true#x'),
    ('or-false', 'bash /abs/hooks/orch-stop-gate.sh || false'),
    ('two-or-true', 'bash /abs/hooks/orch-stop-gate.sh || true || true'),
    ('trailing-newline', 'bash /abs/hooks/orch-stop-gate.sh || true\n'),
    ('command-after-comment', 'bash /abs/hooks/orch-stop-gate.sh # c\nrm -rf /x'),
    ('line-continuation', 'bash /abs/hooks/orch-stop-gate.sh \\\n|| true'),
    ('home-expansion', 'bash $HOME/hooks/orch-stop-gate.sh || true'),
    ('parameter-expansion', 'bash ${X}/hooks/orch-stop-gate.sh || true'),
    ('command-substitution', 'bash /abs/$(id)/hooks/orch-stop-gate.sh'),
    ('backtick-substitution', 'bash /abs/`id`/hooks/orch-stop-gate.sh'),
    ('tilde-expansion', 'bash ~/hooks/orch-stop-gate.sh || true'),
    ('heredoc', "cat <<'EOF'\n/u/hooks/orch-stop-gate.sh # user's note\nEOF"),
    ('ansi-c-path', "bash $'/abs/hooks/orch-stop-gate.sh' || true"),
    ('comment-newline', 'bash /abs/hooks/orch-stop-gate.sh || true # x\n'),
]
for case, command in lookalikes:
    entry = {'matcher': '.*', 'hooks': [{'type': 'command', 'command': command}]}
    beside = copy.deepcopy(canonical)
    beside['hooks']['SubagentStop'].append(entry)
    alone = {'hooks': {'SubagentStop': [entry]}}
    for kind, settings in (('beside', beside), ('alone', alone)):
        (tmp / f'lookalike-{case}-{kind}.json').write_text(json.dumps(settings, indent=2) + '\n')
    print(case)
PY
while IFS= read -r lookalike_case; do
  cp "$TMP/lookalike-$lookalike_case-beside.json" "$CC_ORCH_SETTINGS"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/lookalike-$lookalike_case-beside.json" || fail "$lookalike_case changes settings beside canonical hooks"
  cp "$TMP/lookalike-$lookalike_case-alone.json" "$CC_ORCH_SETTINGS"
  install_hooks
  python3 - "$CC_ORCH_SETTINGS" "$TMP/lookalike-$lookalike_case-alone.json" "$TMP/allowlist-canonical.json" <<'PY'
import json, sys
now, before, canonical = [json.load(open(path)) for path in sys.argv[1:]]
entries = now['hooks']['SubagentStop']
assert len(entries) == 2, entries
assert json.dumps(entries[0]).encode() == json.dumps(before['hooks']['SubagentStop'][0]).encode()
assert entries[1] == canonical['hooks']['SubagentStop'][0], entries
canonical['hooks']['SubagentStop'].insert(0, before['hooks']['SubagentStop'][0])
assert now == canonical, now
PY
  cp "$CC_ORCH_SETTINGS" "$TMP/repaired-lookalike.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/repaired-lookalike.json" || fail "$lookalike_case changes on re-run"
  ok "allow-list preserves $lookalike_case beside canonical hooks and alone, with byte-identical re-run"
done < "$TMP/lookalike-cases"

# N2: recognised historical forms repair at the same index, preserving unrelated entries.
python3 - "$TMP" > "$TMP/recognised-cases" <<'PY'
import copy, json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
canonical = json.loads((tmp / 'allowlist-canonical.json').read_text())
cases = []
for event, basename in (
    ('PreToolUse', 'orch-worktree-guard.sh'),
    ('SubagentStop', 'orch-stop-gate.sh'),
    ('SessionStart', 'orch-compact-context.sh'),
):
    command = canonical['hooks'][event][0]['hooks'][0]['command']
    for shape, stale in (
        # install.sh 4b750d1: plain and shlex.quote-produced single-quoted paths.
        ('installer-plain', f'bash /old/checkout/hooks/{basename} || true'),
        ('installer-quoted', f"bash '/old/my checkout/hooks/{basename}' || true"),
        # Existing stale() and duplicate fixtures also require these legacy forms.
        ('no-or-true', f"bash '/old/checkout/hooks/{basename}'"),
        ('adjacent-or-true', f"bash '/old/checkout/hooks/{basename}'||true"),
        ('trailing-comment', f"bash /old/checkout/hooks/{basename} || true # user's guard"),
        ('unmatched-comment-quotes', command + " # it's \"odd"),
        ('tab-spacing', f'bash /old/checkout/hooks/{basename}\t||  true'),
    ):
        cases.append((event + '-' + shape, event, stale))
    if event != 'SessionStart':
        # guardrails.json 4b750d1: the two historical single-quoted literals.
        cases.append((event + '-guardrails-4b750d1', event,
                      f"bash '/home/janghun/cc-orchestra/hooks/{basename}' || true"))
    else:
        # guardrails.json f4053e3: historical plain compaction-hook literal.
        cases.append((event + '-guardrails-f4053e3', event,
                      'bash /home/janghun/cc-orchestra/hooks/orch-compact-context.sh || true'))
for case, event, command in cases:
    settings = {'hooks': {event: [
        {'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo keep-me'}]},
        {'matcher': 'wrong-matcher', 'hooks': [{'type': 'prompt', 'command': command, 'timeout': 99}]},
    ]}}
    expected = copy.deepcopy(settings)
    expected['hooks'][event][1] = canonical['hooks'][event][0]
    for other_event, entries in canonical['hooks'].items():
        if other_event != event:
            expected['hooks'][other_event] = entries
    for kind, value in (('before', settings), ('expected', expected)):
        (tmp / f'recognised-{case}-{kind}.json').write_text(json.dumps(value, indent=2) + '\n')
    print(case)
PY
while IFS= read -r recognised_case; do
  cp "$TMP/recognised-$recognised_case-before.json" "$CC_ORCH_SETTINGS"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/recognised-$recognised_case-expected.json" || fail "$recognised_case was not repaired in place with unrelated entries intact"
  cp "$CC_ORCH_SETTINGS" "$TMP/repaired-recognised.json"
  install_hooks
  cmp "$CC_ORCH_SETTINGS" "$TMP/repaired-recognised.json" || fail "$recognised_case changes on re-run"
  ok "allow-list repairs $recognised_case in place with byte-identical re-run"
done < "$TMP/recognised-cases"

# N3: canonical equality recognises shlex.quote output outside the historical grammar.
for path_case in quote newline; do
  python3 - "$ROOT" "$TMP" "$path_case" <<'PY'
import json, shlex, subprocess, sys
from pathlib import Path
root, tmp = map(Path, sys.argv[1:3])
case = sys.argv[3]
repo = tmp / ("it's repo" if case == 'quote' else 'new\nline')
installer = (root / 'install.sh').read_text()
body = installer.split('install_safety_hooks() {', 1)[1].split('\n}\n', 1)[0] + '\n'
source = body.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
helper = tmp / 'safety-helper.py'
helper.write_text(source)
path = tmp / f'canonical-{case}.json'
args = [sys.executable, str(helper), str(path), str(repo)]
subprocess.run(args, check=True)
before = path.read_bytes()
settings = json.loads(before)
definitions = (
    ('PreToolUse', 'Bash', 'orch-worktree-guard.sh', 10),
    ('SubagentStop', '(route-)?lead-.*', 'orch-stop-gate.sh', 30),
    ('SessionStart', 'compact', 'orch-compact-context.sh', 10),
)
assert settings == {'hooks': {event: [{'matcher': matcher, 'hooks': [{
    'type': 'command', 'command': 'bash ' + shlex.quote(str(repo / 'hooks' / basename)) + ' || true',
    'timeout': timeout,
}]}] for event, matcher, basename, timeout in definitions}}, settings
subprocess.run(args, check=True)
assert path.read_bytes() == before, case
result = subprocess.run(args + ['check'], capture_output=True, text=True)
assert result.returncode == 0, (case, result.returncode, result.stdout, result.stderr)
assert not result.stderr, (case, result.stderr)
assert result.stdout.splitlines() == [f'  ok       {basename} in settings.json'
                                      for event, matcher, basename, timeout in definitions], result.stdout
assert path.read_bytes() == before, case
PY
  ok "exact canonical equality supports a checkout path containing a $path_case"
done

# N4: check the real installer with a command-type canonical guard missing only || true.
python3 - "$TMP/allowlist-canonical.json" "$CHECK_HOME/.claude/settings.json" "$ROOT" <<'PY'
import json, shlex, sys
settings = json.load(open(sys.argv[1]))
settings['hooks']['PreToolUse'][0]['hooks'][0]['command'] = 'bash ' + shlex.quote(sys.argv[3] + '/hooks/orch-worktree-guard.sh')
with open(sys.argv[2], 'w') as output:
    json.dump(settings, output, indent=2)
    output.write('\n')
PY
cp "$CHECK_HOME/.claude/settings.json" "$TMP/no-or-true.json"
if no_or_true="$(HOME="$CHECK_HOME" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$TMP/checkstate" CC_ORCH_SETTINGS="$CHECK_HOME/.claude/settings.json" bash "$ROOT/install.sh" --check)"; then
  fail '--check succeeds with a guard missing || true'
fi
[[ "$no_or_true" == *'STALE    orch-worktree-guard.sh under PreToolUse: command is not the fail-open'* ]] || fail 'check misses absent || true on the canonical guard'
[[ "$no_or_true" != *'ok       orch-worktree-guard.sh'* ]] || fail 'check reports guard missing || true as ok'
cmp "$CHECK_HOME/.claude/settings.json" "$TMP/no-or-true.json" || fail 'check writes settings missing || true'
ok '--check reports a canonical guard without || true as stale and leaves settings byte-identical'

echo "PASS: $pass hook-wiring cases"
