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
added = {'cc-orch-codex', 'codex-run-codex', 'orch-codex-route', 'orch-archive'}
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
        tokens = shlex.split(hook['command'])
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

echo "PASS: $pass hook-wiring cases"
