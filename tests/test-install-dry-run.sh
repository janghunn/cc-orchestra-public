#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/tmp" "$TMP/fakebin"
git -C "$ROOT" ls-files -z --cached --others --exclude-standard |
  python3 -c 'import sys; sys.stdout.buffer.write(b"".join(p+b"\0" for p in sys.stdin.buffer.read().split(b"\0") if p and not p.startswith(b".orchestra/")))' |
  (cd "$ROOT" && tar --null -T - -cf -) | tar -C "$TMP/repo" -xf -
# A parent orchestration session must not route any helper into its real state.
for name in ${!CC_ORCH_@}; do unset "$name"; done
unset CLAUDE_BIN CODEX_PRESSURE_PIN
export TMP TMPDIR="$TMP/tmp" PATH="$TMP/fakebin:$PATH"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "$TMP/calls.log"
if [[ "${1:-}" == auth ]]; then echo 'Login method: test'; exit 0; fi
printf '%s\n' 'Current session: 10% used' 'Current week (all models): 40% used' 'Current week (Fable): 99% used'
EOF
cat > "$TMP/fakebin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$TMP/calls.log"
case "${1:-}" in --version) echo 'codex-cli 1.0.0' ;; login) echo 'Logged in' ;; esac
exit 0
EOF
cat > "$TMP/fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$TMP/calls.log"
printf '%s\n' "$*" >> "$TMP/systemctl.log"
EOF
chmod +x "$TMP/fakebin/"*
cat > "$TMP/snapshot.py" <<'PY'
import hashlib, json, os, pathlib, stat, sys
root, kind = sys.argv[1:]
root = pathlib.Path(root)
result = {}
for path in [root, *sorted(root.rglob('*'))]:
    # pathlib does not recurse through symlink directories.
    rel = str(path.relative_to(root))
    if kind == 'content':
        state = pathlib.Path(os.environ.get('CC_ORCH_STATE_DIR') or os.environ['HOME'] + '/.claude/orchestra-state').absolute()
        if state in path.parents and path != state / 'statusline.previous.json':
            continue
        backup = pathlib.Path(os.environ['HOME']) / '.claude/backups'
        if path == backup or (path.parent == backup and path.name.startswith('settings.json.') and path.name.endswith('.bak')):
            continue
    st = path.lstat()
    typ = 'link' if stat.S_ISLNK(st.st_mode) else 'dir' if stat.S_ISDIR(st.st_mode) else 'file'
    value = [typ, stat.S_IMODE(st.st_mode)]
    value += [os.readlink(path) if typ == 'link' else hashlib.sha256(path.read_bytes()).hexdigest() if typ == 'file' else '']
    if kind == 'strict':
        value += [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino]
    result[rel] = value
print(json.dumps(result, sort_keys=True, indent=2))
PY
fresh_home() {
  export HOME="$TMP/$1" XDG_STATE_HOME="$TMP/$1/.local/state" CODEX_HOME="$TMP/$1/.codex"
  export CC_ORCH_BIN_DIR="$HOME/.local/bin" CC_ORCH_AGENTS_DIR="$HOME/.claude/agents"
  export CC_ORCH_MANIFEST="$CC_ORCH_AGENTS_DIR/.install-manifest.json"
  export CC_ORCH_STATE_DIR="$HOME/.claude/orchestra-state" CC_ORCH_SETTINGS="$HOME/.claude/settings.json"
  export CC_ORCH_UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$HOME"
}
snap() { python3 "$TMP/snapshot.py" "$1" "${2:-strict}"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
preview() {
  local expected="$1" output="$2" rc=0
  shift 2
  rm -f "$TMP/calls.log" "$TMP/systemctl.log"
  snap "$HOME" > "$TMP/before-home"
  snap "$TMP/repo" > "$TMP/before-repo"
  bash "${INSTALL_REPO:-$TMP/repo}/install.sh" "$@" > "$output" 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || { cat "$output"; fail "exit $rc, expected $expected"; }
  snap "$HOME" > "$TMP/after-home"
  snap "$TMP/repo" > "$TMP/after-repo"
  diff -u "$TMP/before-home" "$TMP/after-home"
  diff -u "$TMP/before-repo" "$TMP/after-repo"
  [[ ! -s "$TMP/calls.log" && ! -e "$TMP/systemctl.log" ]] || fail 'dry-run called a provider or systemctl'
  [[ -z "$(ls -A "$TMPDIR")" ]] || fail 'dry-run left temporary files'
}
real_install() { bash "${INSTALL_REPO:-$TMP/repo}/install.sh" > "$TMP/install.log" 2>&1 || { cat "$TMP/install.log"; fail 'real install'; }; }
assert_created_paths() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
home = os.environ['HOME']
actual = {home + '/' + p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
planned = set()
for line in open(sys.argv[3]):
    parts = line.split()
    if parts[0] in ('create', 'replace', 'relink', 'backup-then-replace'):
        path = parts[1].rstrip('/')
        planned.add(path)
        if parts[0] == 'backup-then-replace':
            planned.add(path + '.pre-cc-orchestra')
assert actual == planned, ('unplanned', sorted(actual-planned), 'not changed', sorted(planned-actual))
PY
}
assert_stable_plan() {
  python3 - "$1" "$2" <<'PY'
import os, sys
lines = open(sys.argv[1]).read().splitlines()
reorder = sys.argv[2] == 'reorder'
seen_reorder = False
for line in lines:
    action, detail = line.split(None, 1)
    if action in ('cc-orchestra', 'unchanged', 'enable-unit', 'state-dependent'):
        continue
    if action == 'generate-profiles' and '0 create, 0 replace' in detail:
        continue
    if action == 'backup-then-replace' and '<timestamp>' in detail:
        continue
    if action == 'create' and detail == os.environ['HOME'] + '/.claude/backups/':
        continue
    if action == 'merge-json':
        if 'unchanged' in detail:
            continue
        if reorder and 'replace orch-model-notice.sh' in detail and 'entry re-appended last' in detail:
            seen_reorder = True
            continue
    raise AssertionError(line)
assert seen_reorder == reorder, (seen_reorder, reorder)
PY
}

fresh_home home
snap "$HOME" content > "$TMP/initial"
preview 0 "$TMP/first" --dry-run
grep -Eq '^create +.*/.local/bin/cc-orch ->' "$TMP/first"
grep -Eq '^generate-profiles .*39 profiles: 39 create' "$TMP/first"
grep -Eq '^enable-unit +orch-model-guard.timer' "$TMP/first"
grep -Eq '^merge-json .*orch-worktree-guard.sh' "$TMP/first"
! grep -q '^backup-then-replace' "$TMP/first"
python3 - "$TMP/before-home" "$TMP/first" <<'PY'
import json, os, sys
before = json.load(open(sys.argv[1]))
existing_dirs = {os.path.normpath(os.path.join(os.environ['HOME'], path))
                 for path, entry in before.items() if entry[0] == 'dir'}
paths = {'create': set(), 'unchanged': set()}
for line in open(sys.argv[2]):
    parts = line.split()
    if parts[0] not in paths or not parts[1].startswith('/'):
        continue
    path = os.path.normpath(parts[1])
    paths[parts[0]].add(path)
    if parts[0] == 'unchanged' and parts[1].endswith('/'):
        assert path in existing_dirs, ('unchanged directory absent before dry-run', path)
assert not paths['create'] & paths['unchanged'], ('both create and unchanged', paths['create'] & paths['unchanged'])
PY
echo 'PASS: fresh dry-run preserves HOME/repo contents, modes, timestamps and inodes; no external calls'
real_install
snap "$HOME" content > "$TMP/installed"
assert_created_paths "$TMP/initial" "$TMP/installed" "$TMP/first"
preview 0 "$TMP/second" --dry-run
assert_stable_plan "$TMP/second" reorder
real_install
python3 - <<'PY'
import json, os
entries = json.load(open(os.environ['CC_ORCH_SETTINGS']))['hooks']['UserPromptSubmit']
commands = [e['hooks'][0]['command'] for e in entries]
assert 'orch-runtime-context.sh' in commands[0] and 'orch-model-notice.sh' in commands[1], commands
PY
preview 0 "$TMP/third" --dry-run
assert_stable_plan "$TMP/third" stable
snap "$HOME" content > "$TMP/stable-before"
real_install
snap "$HOME" content > "$TMP/stable-after"
diff -u "$TMP/stable-before" "$TMP/stable-after"
bash "$TMP/repo/install.sh" --check > "$TMP/check.log" 2>&1 || { cat "$TMP/check.log"; fail 'installed check'; }
grep -q '^installed\.' "$TMP/check.log"
echo 'PASS: predicted paths match real install; notice reorder predicted; third install stable; --check passed'

mkdir -p "$HOME/tmp"
TMPDIR="$HOME/tmp" preview 0 "$TMP/nested-temp" --dry-run
grep -q '^generate-profiles .*0 create, 0 replace' "$TMP/nested-temp"
cp "$CC_ORCH_AGENTS_DIR/dev-1.md" "$TMP/dev-copy"
rm "$CC_ORCH_AGENTS_DIR/dev-1.md"
ln -s "$TMP/dev-copy" "$CC_ORCH_AGENTS_DIR/dev-1.md"
preview 0 "$TMP/symlink" --dry-run
grep -Eq '^replace +.*/dev-1.md ' "$TMP/symlink"
cp "$CC_ORCH_AGENTS_DIR/route-lead-alpha-normal.md" "$TMP/route-copy"
printf 'stale\n' > "$TMP/route-copy"
rm "$CC_ORCH_AGENTS_DIR/route-lead-alpha-normal.md"
ln -s "$TMP/route-copy" "$CC_ORCH_AGENTS_DIR/route-lead-alpha-normal.md"
chmod 600 "$CC_ORCH_AGENTS_DIR/dev-2.md"
preview 0 "$TMP/objects" --dry-run
grep -Eq '^replace +.*/dev-2.md ' "$TMP/objects"
grep -Eq '^replace +.*/route-lead-alpha-normal.md \(writes through symlink to ' "$TMP/objects"
echo 'PASS: unsafe TMPDIR falls back outside HOME; core modes/symlinks and route write-through compared'

fresh_home user-hooks
mkdir -p "$CC_ORCH_BIN_DIR" "$(dirname "$CC_ORCH_SETTINGS")"
printf 'existing command\n' > "$CC_ORCH_BIN_DIR/cc-orch"
cat > "$CC_ORCH_SETTINGS" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"echo user"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo prompt"}]}]}}
JSON
preview 0 "$TMP/user-hooks.out" --dry-run
grep -F "${CC_ORCH_BIN_DIR}/cc-orch -> ${CC_ORCH_BIN_DIR}/cc-orch.pre-cc-orchestra" "$TMP/user-hooks.out" >/dev/null
grep -q 'keep 1 unrelated hook(s)' "$TMP/user-hooks.out"
grep -q 'keep 1 other UserPromptSubmit entries' "$TMP/user-hooks.out"
echo 'PASS: file backup and preservation of unrelated hooks reported'

fresh_home modes
for args in '--dry-run --bootstrap' '--bootstrap --dry-run' '--dry-run --check' '--check --dry-run'; do
  preview 2 "$TMP/rejected" $args
  grep -q 'ERROR: --dry-run' "$TMP/rejected"
done
preview 0 "$TMP/codex" --dry-run --codex-only
[[ "$(grep -c '^create .* -> ' "$TMP/codex")" == 6 ]]
! grep -q '/.claude\|generate-profiles\|merge-json\|enable-unit' "$TMP/codex"
preview 0 "$TMP/safety" --dry-run --safety-hooks-only
! grep -q -- ' -> \|generate-profiles\|enable-unit' "$TMP/safety"
grep -q '^merge-json .*orch-worktree-guard.sh' "$TMP/safety"
CC_ORCH_BACKEND=codex preview 1 "$TMP/backend" --dry-run
grep -q '^error .*CC_ORCH_BACKEND=codex refuses it' "$TMP/backend"
! grep -q '^enable-unit\|^merge-json' "$TMP/backend"
CLAUDE_BIN="$TMP/missing-claude" preview 0 "$TMP/no-claude" --dry-run
! grep -q '^enable-unit\|^backup-then-replace\|^merge-json .*orch-model-notice.sh' "$TMP/no-claude"
grep -q '^merge-json .*statusLine: replace' "$TMP/no-claude"
echo 'PASS: rejected combinations, codex-only, safety-only, Codex backend and missing Claude'

fresh_home custom
export CC_ORCH_SETTINGS="$HOME/custom/settings.json"
preview 0 "$TMP/custom.out" --dry-run
grep -F "$HOME/.claude/settings.json hooks.UserPromptSubmit: add orch-runtime-context.sh" "$TMP/custom.out" >/dev/null
grep -F "$CC_ORCH_SETTINGS hooks.UserPromptSubmit: skipped orch-model-notice.sh" "$TMP/custom.out" >/dev/null
grep -F "$CC_ORCH_SETTINGS statusLine: replace" "$TMP/custom.out" >/dev/null
real_install
python3 - <<'PY'
import json, os
custom = json.load(open(os.environ['CC_ORCH_SETTINGS']))
assert 'statusLine' in custom
assert 'orch-model-notice.sh' not in json.dumps(custom)
assert 'orch-runtime-context.sh' not in json.dumps(custom)
assert 'orch-runtime-context.sh' in open(os.environ['HOME']+'/.claude/settings.json').read()
PY
# A partly configured statusLine owned by us still needs its canonical type/refresh fields.
python3 - <<'PY'
import json, os
path = os.environ['CC_ORCH_SETTINGS']
settings = json.load(open(path))
settings['statusLine'].pop('refreshInterval')
settings['statusLine']['type'] = 'wrong'
with open(path, 'w') as f: json.dump(settings, f)
PY
preview 0 "$TMP/statusline" --dry-run
grep -q '^merge-json .*statusLine: replace' "$TMP/statusline"
! grep -q '^replace .*statusline.previous.json\|^create .*statusline.previous.json' "$TMP/statusline"
printf '{invalid' > "$CC_ORCH_SETTINGS"
preview 1 "$TMP/invalid" --dry-run
grep -q '^merge-json .*ERROR: .*the install would stop here' "$TMP/invalid"
preview 1 "$TMP/invalid-safety" --dry-run --safety-hooks-only
grep -q '^merge-json .*ERROR:' "$TMP/invalid-safety"
echo 'PASS: custom settings parent prediction, statusLine repair and invalid JSON errors'

fresh_home logical-repo
ln -s "$TMP/repo" "$TMP/repo-link"
INSTALL_REPO="$TMP/repo-link" real_install
INSTALL_REPO="$TMP/repo-link" real_install
INSTALL_REPO="$TMP/repo-link" preview 0 "$TMP/logical-repo.out" --dry-run
assert_stable_plan "$TMP/logical-repo.out" stable
python3 - <<'PY'
import json, os, pathlib, shlex
repo = os.environ['TMP'] + '/repo'
logical = os.environ['TMP'] + '/repo-link'
settings = json.load(open(os.environ['CC_ORCH_SETTINGS']))
commands = [hook['command'] for entry in settings['hooks']['UserPromptSubmit'] for hook in entry['hooks']]
assert "bash '%s/hooks/orch-model-notice.sh'" % repo in commands, commands
assert logical + '/hooks/orch-runtime-context.sh' in commands, commands
assert settings['statusLine']['command'] == 'bash ' + repr(repo + '/hooks/orch-statusline.sh')
safety = settings['hooks']['PreToolUse'][0]['hooks'][0]['command']
assert safety == 'bash ' + shlex.quote(logical + '/hooks/orch-worktree-guard.sh') + ' || true', safety
unit = pathlib.Path(os.environ['CC_ORCH_UNIT_DIR'], 'orch-model-guard.service').read_text()
assert 'ExecStart=' + repo + '/bin/orch-model-guard check\n' in unit, unit
assert os.readlink(os.environ['HOME'] + '/.claude/orchestra') == logical
PY
echo 'PASS: symlinked repo keeps logical installer paths and physical guard paths; stable after two installs'

fresh_home relative-claude
(
  cd "$TMP/fakebin"
  CLAUDE_BIN=claude real_install
  CLAUDE_BIN=claude real_install
  CLAUDE_BIN=claude preview 0 "$TMP/relative-claude.out" --dry-run
  assert_stable_plan "$TMP/relative-claude.out" stable
  grep -Fx 'Environment=PATH=.:/usr/local/bin:/usr/bin:/bin' "$CC_ORCH_UNIT_DIR/orch-model-guard.service" >/dev/null
)
echo 'PASS: relative Claude executable uses the same dirname in previewed and installed units'

fresh_home empty-overrides
preview 0 "$TMP/default-overrides.out" --dry-run
for name in CC_ORCH_SETTINGS CC_ORCH_STATE_DIR CC_ORCH_AGENTS_DIR CC_ORCH_MANIFEST CC_ORCH_UNIT_DIR CC_ORCH_BACKEND CC_ORCH_BIN_DIR CLAUDE_BIN; do
  (
    export "$name="
    preview 0 "$TMP/empty-$name.out" --dry-run
    cmp "$TMP/default-overrides.out" "$TMP/empty-$name.out"
  )
done
(
  export CC_ORCH_SETTINGS='' CC_ORCH_STATE_DIR='' CC_ORCH_AGENTS_DIR='' CC_ORCH_MANIFEST=''
  export CC_ORCH_UNIT_DIR='' CC_ORCH_BACKEND='' CC_ORCH_BIN_DIR='' CLAUDE_BIN=''
  preview 0 "$TMP/all-empty.out" --dry-run
  cmp "$TMP/default-overrides.out" "$TMP/all-empty.out"
  grep -F "$HOME/.claude/settings.json hooks.UserPromptSubmit: add orch-model-notice.sh" "$TMP/all-empty.out" >/dev/null
  preview 0 "$TMP/empty-safety.out" --dry-run --safety-hooks-only
  grep -F "$HOME/.claude/settings.json hooks.PreToolUse[Bash]: add" "$TMP/empty-safety.out" >/dev/null
)
(
  export CC_ORCH_AGENTS_DIR="$HOME/custom/agents" CC_ORCH_MANIFEST=''
  preview 0 "$TMP/empty-manifest.out" --dry-run
  grep -Eq "^create +$CC_ORCH_AGENTS_DIR/.install-manifest.json\$" "$TMP/empty-manifest.out"
)
echo 'PASS: individual and combined empty overrides match default plans with zero writes'

# Every mkdir -p before settings registration makes both its target and ancestors available.
fresh_home earlier-dirs
export CC_ORCH_BIN_DIR="$HOME/earlier/bin/deep" CC_ORCH_STATE_DIR="$HOME/earlier/state/deep"
export CC_ORCH_AGENTS_DIR="$HOME/earlier/agents/deep" CC_ORCH_MANIFEST="$HOME/earlier/manifest/deep/manifest.json"
export CC_ORCH_UNIT_DIR="$HOME/earlier/units/deep"
for directory in "$HOME/.claude/agents" "$CC_ORCH_BIN_DIR" "$CC_ORCH_STATE_DIR" "$CC_ORCH_AGENTS_DIR" "$(dirname "$CC_ORCH_MANIFEST")" "$CC_ORCH_UNIT_DIR"; do
  for parent in "$directory" "$(dirname "$directory")"; do
    CC_ORCH_SETTINGS="$parent/settings.json" preview 0 "$TMP/earlier-dirs.out" --dry-run
    grep -F "$parent/settings.json hooks.UserPromptSubmit: add orch-model-notice.sh" "$TMP/earlier-dirs.out" >/dev/null
    ! grep -q 'skipped orch-model-notice.sh' "$TMP/earlier-dirs.out"
    # Settings must not report another creation of a directory already planned earlier.
    python3 - "$TMP/earlier-dirs.out" <<'PY'
import sys
directories = [line.split()[1] for line in open(sys.argv[1])
               if line.startswith('create ') and line.split()[1].endswith('/')]
assert len(directories) == len(set(directories)), directories
PY
  done
done
echo 'PASS: notice registration recognizes all earlier directory creations and their ancestors'

fresh_home unit-settings
export CC_ORCH_SETTINGS="$CC_ORCH_UNIT_DIR/settings.json"
snap "$HOME" content > "$TMP/unit-initial"
preview 0 "$TMP/unit-settings.out" --dry-run
grep -F "$CC_ORCH_SETTINGS hooks.UserPromptSubmit: add orch-model-notice.sh" "$TMP/unit-settings.out" >/dev/null
! grep -q 'skipped orch-model-notice.sh' "$TMP/unit-settings.out"
real_install
snap "$HOME" content > "$TMP/unit-installed"
assert_created_paths "$TMP/unit-initial" "$TMP/unit-installed" "$TMP/unit-settings.out"
python3 - <<'PY'
import json, os
settings = json.load(open(os.environ['CC_ORCH_SETTINGS']))
assert any('orch-model-notice.sh' in h['command']
           for e in settings['hooks']['UserPromptSubmit'] for h in e['hooks'])
assert 'statusLine' in settings
PY
echo 'PASS: settings in newly created unit directory match real install paths and notice hook'

fresh_home no-claude-unit-settings
export CC_ORCH_SETTINGS="$CC_ORCH_UNIT_DIR/settings.json"
CLAUDE_BIN="$TMP/missing-claude" preview 0 "$TMP/no-claude-unit-settings.out" --dry-run
grep -Eq "^create +$CC_ORCH_UNIT_DIR/\$" "$TMP/no-claude-unit-settings.out"
! grep -Eq "^unchanged +$CC_ORCH_UNIT_DIR/" "$TMP/no-claude-unit-settings.out"
! grep -q '^merge-json .*orch-model-notice.sh\|^enable-unit' "$TMP/no-claude-unit-settings.out"
grep -F "$CC_ORCH_SETTINGS statusLine: replace" "$TMP/no-claude-unit-settings.out" >/dev/null
echo 'PASS: without Claude, statusLine still plans creation of the missing custom settings parent'

# mkdir -p cannot replace a non-directory, including one reached through a symlink.
for kind in file symlink dangling; do
  fresh_home "blocked-bin-$kind"
  block="$HOME/blocked"
  if [[ "$kind" == file ]]; then
    printf 'keep\n' > "$block"
  elif [[ "$kind" == symlink ]]; then
    printf 'keep\n' > "$HOME/target"
    ln -s "$HOME/target" "$block"
  else
    ln -s "$HOME/missing" "$block"
  fi
  for dest in "$block" "$block/child"; do
    for mode in hybrid codex-only; do
      args=()
      [[ "$mode" == hybrid ]] || args+=(--codex-only)
      CC_ORCH_BIN_DIR="$dest" preview 1 "$TMP/blocked-bin.out" --dry-run "${args[@]}"
      grep -Eq '^error ' "$TMP/blocked-bin.out"
      grep -F "$block (exists and is not a directory; the install would stop here)" "$TMP/blocked-bin.out" >/dev/null
      ! grep -q -- ' -> ' "$TMP/blocked-bin.out"
      rc=0
      CC_ORCH_BIN_DIR="$dest" bash "$TMP/repo/install.sh" "${args[@]}" > "$TMP/blocked-real.log" 2>&1 || rc=$?
      [[ "$rc" != 0 ]] || fail 'real install accepted a non-directory bin path'
    done
  done
done
echo 'PASS: non-directory bin paths and ancestors fail before links, preserve dry-run snapshots, and fail real installs'

fresh_home blocked-planners
printf 'keep\n' > "$HOME/blocked"
ln -s "$HOME/blocked" "$HOME/blocked-link"
for block in "$HOME/blocked" "$HOME/blocked-link"; do
  for name in CC_ORCH_STATE_DIR CC_ORCH_AGENTS_DIR CC_ORCH_MANIFEST CC_ORCH_UNIT_DIR CC_ORCH_SETTINGS; do
    for dest in "$block" "$block/child"; do
      (
        case "$name" in
          CC_ORCH_MANIFEST|CC_ORCH_SETTINGS) export "$name=$dest/settings.json" ;;
          *) export "$name=$dest" ;;
        esac
        preview 1 "$TMP/blocked-planner.out" --dry-run
        grep -Eq '^error ' "$TMP/blocked-planner.out"
        grep -F "$block (exists and is not a directory; the install would stop here)" "$TMP/blocked-planner.out" >/dev/null
      )
    done
  done
  CC_ORCH_SETTINGS="$block/child/settings.json" preview 1 "$TMP/blocked-safety.out" --dry-run --safety-hooks-only
  grep -F "$block (exists and is not a directory; the install would stop here)" "$TMP/blocked-safety.out" >/dev/null
done
mkdir -p "$HOME/.claude"
printf '{}\n' > "$CC_ORCH_SETTINGS"
printf 'keep\n' > "$HOME/.claude/backups"
preview 1 "$TMP/blocked-backups.out" --dry-run
grep -F "$HOME/.claude/backups (exists and is not a directory; the install would stop here)" "$TMP/blocked-backups.out" >/dev/null
echo 'PASS: both Python planners and safety-only reject non-directory targets, ancestors and backup directories'

fresh_home relative-agents
(
  cd "$HOME"
  export CC_ORCH_AGENTS_DIR=relative-agents
  unset CC_ORCH_MANIFEST
  real_install
  real_install
  preview 0 "$TMP/relative-agents.out" --dry-run
  assert_stable_plan "$TMP/relative-agents.out" stable
  grep -Eq "^unchanged +$HOME/relative-agents/.install-manifest.json\$" "$TMP/relative-agents.out"
)
echo 'PASS: relative agents directory and default manifest remain unchanged after two real installs'

fresh_home relative-targets
(
  cd "$HOME"
  export CC_ORCH_BIN_DIR=paths/bin CC_ORCH_AGENTS_DIR=paths/agents CC_ORCH_MANIFEST=paths/manifest.json
  export CC_ORCH_STATE_DIR=paths/state CC_ORCH_UNIT_DIR=paths/units CC_ORCH_SETTINGS=paths/settings.json
  snap "$HOME" content > "$TMP/relative-initial"
  preview 0 "$TMP/relative-targets-first.out" --dry-run
  real_install
  snap "$HOME" content > "$TMP/relative-installed"
  assert_created_paths "$TMP/relative-initial" "$TMP/relative-installed" "$TMP/relative-targets-first.out"
  real_install
  preview 0 "$TMP/relative-targets.out" --dry-run
  assert_stable_plan "$TMP/relative-targets.out" stable
  for path in paths/bin/cc-orch paths/manifest.json paths/units/orch-model-guard.service paths/settings.json; do
    grep -F "$HOME/$path" "$TMP/relative-targets.out" >/dev/null
  done
)
echo 'PASS: all six relative destination overrides match real install paths and stabilize'

for provider in claude missing; do
fresh_home "bare-settings-$provider"
(
  cd "$HOME"
  export CC_ORCH_SETTINGS=settings.json
  if [[ "$provider" == missing ]]; then export CLAUDE_BIN="$TMP/missing-claude"; fi
  snap "$HOME" content > "$TMP/bare-initial"
  preview 0 "$TMP/bare-first.out" --dry-run
  real_install
  snap "$HOME" content > "$TMP/bare-installed"
  assert_created_paths "$TMP/bare-initial" "$TMP/bare-installed" "$TMP/bare-first.out"
  real_install
  preview 0 "$TMP/bare-settings.out" --dry-run
  assert_stable_plan "$TMP/bare-settings.out" stable
  grep -F "$HOME/settings.json statusLine: unchanged (settings path has no parent component; registration fails before writing)" "$TMP/bare-settings.out" >/dev/null
  python3 - <<'PY'
import json, os
settings = json.load(open('settings.json'))
assert 'statusLine' not in settings
assert not os.path.exists(os.environ['CC_ORCH_STATE_DIR'] + '/statusline.previous.json')
PY
)
done
echo 'PASS: bare settings filename predicts the existing statusLine registration failure without writes'
# T1a: BIN follows a symlink before climbing through .. .
(
  fresh_home physical-bin
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$HOME/link"
  export CC_ORCH_BIN_DIR="$HOME/link/../x"
  snap "$HOME" content > "$TMP/physical-bin-initial"
  preview 0 "$TMP/physical-bin-first.out" --dry-run
  grep -Eq "^create +$HOME/elsewhere/x/cc-orch -> " "$TMP/physical-bin-first.out"
  real_install
  snap "$HOME" content > "$TMP/physical-bin-installed"
  assert_created_paths "$TMP/physical-bin-initial" "$TMP/physical-bin-installed" "$TMP/physical-bin-first.out"
  [[ -L "$HOME/elsewhere/x/cc-orch" && ! -e "$HOME/x" ]]
  real_install
  preview 0 "$TMP/physical-bin-stable.out" --dry-run
  assert_stable_plan "$TMP/physical-bin-stable.out" stable
)
echo 'PASS: BIN symlink/.. preview matches physical installation and stabilizes'

# T1b: AGENTS and its default manifest follow the same physical path.
(
  fresh_home physical-agents
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$HOME/link"
  export CC_ORCH_AGENTS_DIR="$HOME/link/../x"
  unset CC_ORCH_MANIFEST
  snap "$HOME" content > "$TMP/physical-agents-initial"
  preview 0 "$TMP/physical-agents-first.out" --dry-run
  grep -Eq "^generate-profiles +$HOME/elsewhere/x/ \(39 profiles: 39 create" "$TMP/physical-agents-first.out"
  real_install
  snap "$HOME" content > "$TMP/physical-agents-installed"
  assert_created_paths "$TMP/physical-agents-initial" "$TMP/physical-agents-installed" "$TMP/physical-agents-first.out"
  real_install
  preview 0 "$TMP/physical-agents-stable.out" --dry-run
  assert_stable_plan "$TMP/physical-agents-stable.out" stable
  grep -Eq "^unchanged +$HOME/elsewhere/x/.install-manifest.json\$" "$TMP/physical-agents-stable.out"
)
echo 'PASS: AGENTS symlink/.. preview matches physical profiles and manifest'

# T1c: Settings writers split when the lexical temporary-file parent is missing.
(
  fresh_home physical-settings-missing
  mkdir -p "$HOME/elsewhere/child" "$HOME/elsewhere/x"
  ln -s "$HOME/elsewhere/child" "$HOME/link"
  export CC_ORCH_SETTINGS="$HOME/link/../x/settings.json"
  snap "$HOME" content > "$TMP/physical-settings-missing-initial"
  preview 0 "$TMP/physical-settings-missing.out" --dry-run
  grep -Eq "^merge-json +$HOME/elsewhere/x/settings.json hooks.UserPromptSubmit: add" "$TMP/physical-settings-missing.out"
  grep -F "statusLine: unchanged (registration writes its temporary file in $HOME/x/, which is missing" "$TMP/physical-settings-missing.out" >/dev/null
  grep -Eq "^merge-json +$HOME/x/settings.json hooks.PreToolUse" "$TMP/physical-settings-missing.out"
  real_install
  snap "$HOME" content > "$TMP/physical-settings-missing-installed"
  assert_created_paths "$TMP/physical-settings-missing-initial" "$TMP/physical-settings-missing-installed" "$TMP/physical-settings-missing.out"
  python3 - <<'PY'
import json, os
home = os.environ['HOME']
physical = json.load(open(home + '/elsewhere/x/settings.json'))
lexical = json.load(open(home + '/x/settings.json'))
assert 'UserPromptSubmit' in physical['hooks'] and 'statusLine' not in physical
assert 'PreToolUse' in lexical['hooks']
PY
)
echo 'PASS: settings preview splits notice and safety files and predicts missing temporary parent'

# T1d: An existing lexical temporary-file parent permits statusLine registration.
(
  fresh_home physical-settings-present
  mkdir -p "$HOME/elsewhere/child" "$HOME/elsewhere/x" "$HOME/x"
  ln -s "$HOME/elsewhere/child" "$HOME/link"
  export CC_ORCH_SETTINGS="$HOME/link/../x/settings.json"
  snap "$HOME" content > "$TMP/physical-settings-present-initial"
  preview 0 "$TMP/physical-settings-present.out" --dry-run
  grep -F "$HOME/elsewhere/x/settings.json statusLine: replace none" "$TMP/physical-settings-present.out" >/dev/null
  real_install
  snap "$HOME" content > "$TMP/physical-settings-present-installed"
  assert_created_paths "$TMP/physical-settings-present-initial" "$TMP/physical-settings-present-installed" "$TMP/physical-settings-present.out"
  python3 - <<'PY'
import json, os
assert 'statusLine' in json.load(open(os.environ['HOME'] + '/elsewhere/x/settings.json'))
PY
)
echo 'PASS: settings statusLine reaches the physical file when the lexical temporary parent exists'

# T1e: A non-directory symlink before .. must retain the kernel failure.
for kind in file-symlink dangling; do
  for target in BIN AGENTS; do
  (
    fresh_home "physical-blocked-$kind-$target"
    if [[ "$kind" == file-symlink ]]; then
      printf x > "$HOME/f"
      ln -s "$HOME/f" "$HOME/fl"
      blocked="$HOME/fl"
    else
      ln -s "$HOME/nowhere" "$HOME/dl"
      blocked="$HOME/dl"
    fi
    export "CC_ORCH_${target}_DIR=$blocked/../x"
    unset CC_ORCH_MANIFEST
    preview 1 "$TMP/physical-blocked.out" --dry-run
    grep -Eq "^error +$blocked \(exists and is not a directory" "$TMP/physical-blocked.out"
    if [[ "$target" == BIN ]]; then
      if grep -q -- ' -> ' "$TMP/physical-blocked.out"; then
        fail 'blocked BIN preview includes a link action'
      fi
    fi
    if bash "$TMP/repo/install.sh" > "$TMP/physical-blocked-install.log" 2>&1; then
      fail "real install accepted $kind before .. in $target"
    fi
  )
  done
done
echo 'PASS: symlink-to-file and dangling symlink before .. fail for BIN and AGENTS'

# T1f: Safety-only registration continues to use the lexical settings path.
(
  fresh_home physical-safety-only
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$HOME/link"
  export CC_ORCH_SETTINGS="$HOME/link/../x/settings.json"
  snap "$HOME" content > "$TMP/physical-safety-initial"
  preview 0 "$TMP/physical-safety.out" --dry-run --safety-hooks-only
  grep -Eq "^create +$HOME/x/\$" "$TMP/physical-safety.out"
  grep -Eq "^merge-json +$HOME/x/settings.json hooks.PreToolUse" "$TMP/physical-safety.out"
  if grep -q elsewhere "$TMP/physical-safety.out"; then
    fail 'safety-only preview includes the physical settings path'
  fi
  bash "$TMP/repo/install.sh" --safety-hooks-only > "$TMP/physical-safety-install.log" 2>&1
  snap "$HOME" content > "$TMP/physical-safety-installed"
  assert_created_paths "$TMP/physical-safety-initial" "$TMP/physical-safety-installed" "$TMP/physical-safety.out"
  [[ -f "$HOME/x/settings.json" && ! -e "$HOME/elsewhere/x" ]]
)
echo 'PASS: safety-only symlink/.. settings stay lexical'

# T1g: A temporary file on another filesystem cannot replace physical settings.
(
  fresh_home physical-settings-exdev
  D=''
  trap '[[ -z "$D" ]] || rm -rf "$D"; rm -rf "$TMP"' EXIT
  for candidate in /dev/shm "${XDG_RUNTIME_DIR:-}"; do
    if [[ -n "$candidate" && -d "$candidate" && -w "$candidate" &&
          "$(stat -c %d "$candidate")" != "$(stat -c %d "$TMP")" ]]; then
      if D="$(mktemp -d "$candidate/cc72.XXXXXX" 2>/dev/null)"; then break; fi
    fi
  done
  if [[ -z "$D" ]]; then
    echo 'SKIP: no second filesystem for the EXDEV statusLine case'
  else
    mkdir -p "$D/child" "$D/x" "$HOME/x"
    ln -s "$D/child" "$HOME/xlink"
    export CC_ORCH_SETTINGS="$HOME/xlink/../x/settings.json"
    snap "$D" > "$TMP/exdev-before"
    preview 0 "$TMP/physical-settings-exdev.out" --dry-run
    snap "$D" > "$TMP/exdev-after"
    diff -u "$TMP/exdev-before" "$TMP/exdev-after"
    grep -F "$D/x/settings.json statusLine: unchanged (registration writes its temporary file in $HOME/x/, on a different filesystem" "$TMP/physical-settings-exdev.out" >/dev/null
    real_install
    python3 - "$D/x/settings.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
assert 'UserPromptSubmit' in settings['hooks'] and 'statusLine' not in settings
PY
    rm -rf "$D"
    D=''
    echo 'PASS: settings preview predicts cross-filesystem statusLine failure'
  fi
  trap - EXIT
)

# T2: Manifest destinations retain the builder's spelling and logical PWD.
for spelling in ./agents agents/ a//agents; do
(
  fresh_home "manifest-spelling-${spelling//\//_}"
  cd "$HOME"
  export CC_ORCH_AGENTS_DIR="$spelling"
  unset CC_ORCH_MANIFEST
  real_install
  real_install
  preview 0 "$TMP/manifest-spelling.out" --dry-run
  assert_stable_plan "$TMP/manifest-spelling.out" stable
  grep -Eq '^unchanged +.*/.install-manifest.json$' "$TMP/manifest-spelling.out"
)
done
(
  fresh_home manifest-logical-cwd
  mkdir -p "$HOME/real"
  ln -s "$HOME/real" "$HOME/cwdlink"
  cd "$HOME/cwdlink"
  export CC_ORCH_AGENTS_DIR=agents
  unset CC_ORCH_MANIFEST
  real_install
  real_install
  preview 0 "$TMP/manifest-logical-cwd.out" --dry-run
  assert_stable_plan "$TMP/manifest-logical-cwd.out" stable
  grep -Eq '^unchanged +.*/.install-manifest.json$' "$TMP/manifest-logical-cwd.out"
)
echo 'PASS: manifest comparison preserves ./, trailing and repeated slashes, and logical PWD'

# T3: Generated-profile directories stop installation in either builder.
(
  fresh_home profile-directory
  real_install
  for name in route-lead-alpha-normal.md lead-alpha.md; do
    for kind in dir symlink-to-dir; do
      profile="$CC_ORCH_AGENTS_DIR/$name"
      rm "$profile"
      if [[ "$kind" == dir ]]; then
        mkdir "$profile"
      else
        mkdir "$HOME/profile-target"
        ln -s "$HOME/profile-target" "$profile"
      fi
      preview 1 "$TMP/profile-directory.out" --dry-run
      grep -Eq "^error +$profile \(a directory occupies" "$TMP/profile-directory.out"
      if grep -Eq "^replace +$profile" "$TMP/profile-directory.out"; then
        fail 'profile-directory preview includes a profile replacement'
      fi
      if grep -q '^enable-unit' "$TMP/profile-directory.out"; then
        fail 'profile-directory preview enables units after builder failure'
      fi
      if bash "$TMP/repo/install.sh" > "$TMP/profile-directory-install.log" 2>&1; then
        fail "real install accepted $kind at $name"
      fi
      rm -rf "$profile" "$HOME/profile-target"
      real_install
    done
  done
)
echo 'PASS: profile directories and directory symlinks predict builder failure before units and settings'

# T1h: BIN creation makes a dangling AGENTS symlink usable before .. .
(
  fresh_home planned-bin-agents
  ln -s "$HOME/.local/bin" "$HOME/link"
  export CC_ORCH_AGENTS_DIR="$HOME/link/../profiles"
  unset CC_ORCH_MANIFEST
  snap "$HOME" content > "$TMP/planned-bin-agents-initial"
  preview 0 "$TMP/planned-bin-agents-first.out" --dry-run
  grep -Eq "^generate-profiles +$HOME/.local/profiles/ \(39 profiles: 39 create" "$TMP/planned-bin-agents-first.out"
  real_install
  snap "$HOME" content > "$TMP/planned-bin-agents-installed"
  assert_created_paths "$TMP/planned-bin-agents-initial" "$TMP/planned-bin-agents-installed" "$TMP/planned-bin-agents-first.out"
  real_install
  preview 0 "$TMP/planned-bin-agents-stable.out" --dry-run
  assert_stable_plan "$TMP/planned-bin-agents-stable.out" stable
)
echo 'PASS: AGENTS symlink/.. uses the BIN directory planned earlier and stabilizes'

# T1i: Static agent directory creation makes a dangling BIN symlink usable.
(
  fresh_home planned-agents-bin
  ln -s "$HOME/.claude/agents" "$HOME/link"
  export CC_ORCH_BIN_DIR="$HOME/link/../bin"
  snap "$HOME" content > "$TMP/planned-agents-bin-initial"
  preview 0 "$TMP/planned-agents-bin-first.out" --dry-run
  grep -Eq "^create +$HOME/.claude/bin/cc-orch -> " "$TMP/planned-agents-bin-first.out"
  real_install
  snap "$HOME" content > "$TMP/planned-agents-bin-installed"
  assert_created_paths "$TMP/planned-agents-bin-initial" "$TMP/planned-agents-bin-installed" "$TMP/planned-agents-bin-first.out"
  [[ -L "$HOME/.claude/bin/cc-orch" ]]
)
echo 'PASS: BIN symlink/.. uses the static agents directory planned earlier'
echo 'PASS: all install dry-run tests'
