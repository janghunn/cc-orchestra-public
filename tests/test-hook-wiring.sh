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
cp "$CC_ORCH_SETTINGS" "$TMP/first.json"
install_hooks
cmp "$CC_ORCH_SETTINGS" "$TMP/first.json" || fail 'second registration changes settings'
assert_registration PreToolUse Bash orch-worktree-guard.sh 10
assert_registration SubagentStop '(route-)?lead-.*' orch-stop-gate.sh 30
ok 'second run retains exactly one non-empty command per hook and identical bytes'

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

python3 - "$ROOT" <<'PY'
import json, re, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
old = subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:guardrails.json'], text=True)
new = (root / 'guardrails.json').read_text()
a, b = json.loads(old), json.loads(new)
assert a['hooks']['UserPromptSubmit'] == b['hooks']['UserPromptSubmit']
assert a['permissions'] == b['permissions']
assert old[old.index('  "permissions":'):] == new[new.index('  "permissions":'):]
start = old.index('    "UserPromptSubmit":')
block = old[start:old.index('\n  },', start)]
assert block in new
old_installer = subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:install.sh'], text=True)
installer = (root / 'install.sh').read_text()
def runtime(text): return text[text.index('install_runtime_hook() {'):text.index('\n}\n', text.index('install_runtime_hook() {')) + 3]
assert runtime(old_installer) == runtime(installer)
assert re.findall(r'^  link .*$', old_installer, re.M) == re.findall(r'^  link .*$', installer, re.M)
PY
ok 'existing prompt hook, permissions, runtime installer function and link inventory remain byte-identical'

[ -x "$ROOT/hooks/orch-worktree-guard.sh" ] && [ -x "$ROOT/hooks/orch-stop-gate.sh" ] || fail 'hook executable bits missing'
ok 'both hooks exist and are executable'
python3 - "$HOME" <<'PY'
from pathlib import Path
import sys
files = sorted(str(path.relative_to(sys.argv[1])) for path in Path(sys.argv[1]).rglob('*'))
assert files == ['.claude', '.claude/settings.json'], files
PY
ok 'safety-only mode creates no links, agents, service files or other HOME state'

echo "PASS: $pass hook-wiring cases"
