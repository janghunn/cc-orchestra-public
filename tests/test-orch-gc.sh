#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
GC=${GC:-$ROOT/bin/orch-gc}
worker_pids=()
cleanup() {
  if [[ ${#worker_pids[@]} -gt 0 ]]; then
    kill "${worker_pids[@]}" 2>/dev/null || true
    wait "${worker_pids[@]}" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" PYTHONDONTWRITEBYTECODE=1
unset ORCH_ARCHIVE_POLICY CC_ORCH_WORKTREE_ROOT
while IFS= read -r name; do unset "$name"; done < <(compgen -v GIT_)
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The helper lives outside each fixture so logs and test imports cannot affect its hash.
cat > "$TMP/cases.py" <<'PY'
import hashlib
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

action, fixture, gc = sys.argv[1:]
F = Path(fixture)
L, R = F / 'L', F / 'state/worktrees/proj'
TASK = '01-task'

def git(repo, *args):
    return subprocess.check_output(['git', '-c', 'user.name=t', '-c', 'user.email=t@t',
                                    '-c', 'protocol.file.allow=always', '-C', str(repo), *args],
                                   stderr=subprocess.PIPE, text=True).strip()

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def row(repo, branch, status='PASS', directory=None):
    path = repo / '.orchestra/REGISTRY.md'
    write(path, (path.read_text() if path.exists() else '') +
          f'| lead-alpha | a1 | t | {branch} | {directory or ".orchestra/" + TASK + "/"} | {status} | x |\n')

def artifacts(repo):
    write(repo / '.orchestra' / TASK / 'plan.md', 'fixture task\n')

def make_merged(name, branch=None):
    branch = branch or 'orch/' + name
    repo = R / name
    git(F, 'clone', str(L), str(repo))
    with (repo / '.git/info/exclude').open('a') as stream:
        stream.write('\n.orchestra/\n')
    git(repo, 'checkout', '-b', branch)
    write(repo / 'tracked', name + '\n')
    git(repo, 'add', 'tracked')
    git(repo, 'commit', '-m', name)
    git(L, 'fetch', str(repo), branch)
    git(L, 'merge', '--no-ff', 'FETCH_HEAD', '-m', 'merge ' + name)
    artifacts(repo)
    row(repo, branch)
    return repo

def fixture_setup():
    F.mkdir(parents=True)
    (F / 'home/.claude').mkdir(parents=True)
    (F / 'home/.claude/orchestra').symlink_to(L)
    R.mkdir(parents=True)
    git(F, 'init', str(L))
    git(L, 'checkout', '-b', 'local/installed-main')
    write(L / 'tracked', 'base\n')
    git(L, 'add', 'tracked')
    git(L, 'commit', '-m', 'base')
    with (L / '.git/info/exclude').open('a') as stream:
        stream.write('\n.orchestra/\n')
    write(L / '.orchestra/REGISTRY.md', '# Registry\n')
    for name in ('merged', 'dirty', 'unmerged', 'open', 'stale', 'secret', 'norow', 'blocked',
                 'branch2', 'tagged', 'stash', 'ignored', 'hidden', 'filter', 'proc', 'parent', 'archive-tmp-x',
                 'lent', 'shared', 'midop'):
        make_merged(name)
    write(L / '.git/objects/info/alternates', str(R / 'lent/.git/objects') + '\n')
    git(F, 'clone', '--shared', str(R / 'shared'), str(R / 'borrower'))
    # Keep the borrower independent of shared's completion row and the exact SAFE set.
    git(R / 'borrower', 'checkout', '-b', 'orch/borrower')
    write(R / 'midop/.git/MERGE_HEAD', git(R / 'midop', 'rev-parse', 'HEAD') + '\n')
    write(R / 'dirty/tracked', 'changed dirty\n')
    write(R / 'unmerged/tracked', 'changed unmerged\n')
    git(R / 'unmerged', 'commit', '-am', 'unmerged')
    for name in ('open', 'norow', 'blocked'):
        (R / name / '.orchestra/REGISTRY.md').unlink()
    row(R / 'blocked', 'orch/blocked', 'BLOCKED')
    write(R / 'secret/.env', 'fixture only\n')
    with (R / 'secret/.git/info/exclude').open('a') as stream:
        stream.write('.env\n')
    for name in ('branch2', 'tagged'):
        repo = R / name
        git(repo, 'checkout', '-b', 'unique/' + name)
        write(repo / 'unique', name)
        git(repo, 'add', 'unique')
        git(repo, 'commit', '-m', 'unique')
        if name == 'tagged':
            git(repo, 'tag', '-a', 'only-tag', '-m', 'unique tag')
        git(repo, 'checkout', 'orch/' + name)
        if name == 'tagged':
            git(repo, 'branch', '-D', 'unique/' + name)
    write(R / 'stash/tracked', 'stashed\n')
    git(R / 'stash', 'stash', 'push', '-m', 'only stash')
    write(R / 'ignored/.gitignore', 'out/\n')
    git(R / 'ignored', 'add', '.gitignore')
    git(R / 'ignored', 'commit', '-m', 'ignore outputs')
    git(L, 'fetch', str(R / 'ignored'), 'orch/ignored')
    git(L, 'merge', '--no-ff', 'FETCH_HEAD', '-m', 'merge ignore')
    write(R / 'ignored/out/model.ckpt', 'only checkpoint')
    fd = os.open(os.fsencode(R / 'ignored/out') + b'/0-\xff.ckpt', os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        os.write(fd, b'non-UTF-8 ignored checkpoint')
    finally:
        os.close(fd)
    write(R / 'hidden/tracked', 'changed hidden\n')
    git(R / 'hidden', 'update-index', '--assume-unchanged', 'tracked')
    git(R / 'filter', 'config', 'filter.evil.clean', f"sh -c 'touch {F}/filter-ran; cat'")
    write(R / 'filter/.gitattributes', '* filter=evil\n')
    os.utime(R / 'filter/tracked', None)
    write(R / 'nogit/plain', 'plain')
    write(F / 'outside/victim/file', 'must survive')
    (F / 'outside/.orchestra/wt/x').mkdir(parents=True)
    (R / 'escape').symlink_to(F / 'outside')
    for name, path in [('wtsafe', R / 'wtsafe'), ('wtrewritten', R / 'wtrewritten'),
                       ('orch', R / 'orch'), ('coord', F / 'coord'),
                       ('lead-y', L / '.orchestra/wt/lead-y')]:
        git(L, 'worktree', 'add', '-b', 'wt/' + name, str(path))
        if name in ('wtsafe', 'wtrewritten'):
            artifacts(path)
            row(L, 'wt/' + name, directory=str(path / '.orchestra' / TASK))
    private = git(L, 'commit-tree', git(L, 'rev-parse', 'HEAD^{tree}'),
                  '-p', git(L, 'rev-parse', 'HEAD'), '-m', 'worktree-private commit')
    git(R / 'wtrewritten', 'update-ref', 'refs/rewritten/keep', private)
    write(F / 'state/worktrees/other/broken/.git', f'gitdir: {F}/missing/.git/worktrees/broken\n')
    write(F / 'state/worktrees/other/broken/plain', 'broken worktree')
    row(R / 'orch', 'orch/open', 'RUNNING', 'open/.orchestra/' + TASK + '/')
    row(F / 'coord', 'orch/stale', 'RUNNING', str(R / 'stale/.orchestra' / TASK))
    write(F / 'state/sessions/orch.conf', f'WORKDIR={R}/orch\nREPO={L}\n')
    write(F / 'state/codex-projects/aborted/.launch.lock', '')
    git(R / 'parent', 'worktree', 'add', '-b', 'nested/lead-x', str(R / 'parent/.orchestra/wt/lead-x'))
    write(F / 'home/archive-tmp/file', 'backup')
    write(F / 'vault/tasks/proj--01-task.md', 'archived note')
    process = subprocess.Popen(['sleep', '300'], cwd=R / 'proc', stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    write(F.parent / (F.name + '.pid'), str(process.pid))

def run(*args, code=0, env=None):
    result = subprocess.run(['python3', gc, *args], capture_output=True, text=True, env=env)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

def scan_json(*args):
    return json.loads(run('scan', '--root', str(R), '--repo', str(L), '--json', *args))

def snapshot(exclude=(), ignore_mtime=()):
    result = {}
    def visit(path):
        rel = path.relative_to(F).as_posix()
        if any(rel == x or rel.startswith(x + '/') for x in exclude):
            return
        info = path.lstat()
        directory = stat.S_ISDIR(info.st_mode)
        target = os.readlink(path) if path.is_symlink() else None
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None
        result[rel] = (stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), info.st_size,
                       None if rel in ignore_mtime else info.st_mtime_ns, target, digest)
        if directory:
            for child in sorted(path.iterdir()):
                visit(child)
    visit(F)
    return result

def module():
    loader = importlib.machinery.SourceFileLoader('orch_gc', gc)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod

def options(mod):
    return mod.parser().parse_args(['scan', '--root', str(R), '--repo', str(L)])

def case1():
    before = snapshot()
    report = scan_json()
    items = {i['id']: i for i in report['items']}
    expected = {
        'SAFE': {'merged': 'merged into', 'wtsafe': 'merged into'},
        'CAUTION': {'dirty': 'dirty', 'unmerged': 'not merged', 'norow': 'no registry row',
                    'blocked': 'BLOCKED', 'branch2': 'not merged', 'tagged': 'not merged',
                    'stash': 'stash', 'ignored': 'git-ignored', 'hidden': 'index flags',
                    'filter': 'git filter', 'nogit': 'not a git checkout',
                    'parent': 'nested checkout', 'archive-tmp-x': 'temp backup',
                    'wtrewritten': 'not merged', 'midop': 'git operation in progress: MERGE_HEAD'},
        'DANGER': {'open': 'open registry row', 'stale': 'open registry row', 'secret': 'secret-shaped',
                   'escape': 'escapes root', 'proc': 'in use by pid', 'orch': 'session record',
                   'lent': 'objects borrowed by', 'shared': 'objects borrowed by'}}
    # The specified relative-dir matching also places orch's own RUNNING row under orch.
    for category, names in expected.items():
        for name, keyword in names.items():
            item = items['proj/' + name]
            assert item['class'] == category, item
            assert any(keyword in r['text'] for r in item['reasons']), item
    assert {i['id'] for i in items.values() if i['class'] == 'SAFE'} == {'proj/merged', 'proj/wtsafe'}
    assert 'proj/parent/.orchestra/wt/lead-x' in items
    assert not any(id.startswith('proj/escape/') for id in items)
    assert len(items) == sum(map(len, expected.values())) + 2, items.keys()  # nested worktree and borrower
    assert items['proj/merged']['archive'] == 'yes'
    assert not (F / 'filter-ran').exists()
    table = run('--root', str(R), '--repo', str(L))
    assert table.startswith('CLASS  SIZE  AGE  ARCHIVE  ID  REASON\n')
    assert len([line for line in table.splitlines() if line.startswith(('SAFE ', 'CAUTION ', 'DANGER '))]) == len(items)
    assert 'totals: SAFE 2 (' in table and 'archive is not a full copy' in table
    assert r'0-\xff.ckpt' in table, table
    assert report['totals']['all']['count'] == len(items)
    assert report['totals']['all']['bytes'] == sum(i['bytes'] for i in items.values())
    assert before == snapshot(), 'scan changed fixture'

    mod = module()
    context = mod.scan(options(mod))
    item = next(i for i in context.items if i.id == 'proj/merged')
    item.reasons = [{'severity': 'CAUTION', 'text': 'first\nsecond\tpart'}]
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        mod.report(context, False)
    rows = [line for line in output.getvalue().splitlines() if line.startswith(('SAFE ', 'CAUTION ', 'DANGER '))]
    assert len(rows) == len(context.items), output.getvalue()
    assert any('proj/merged  first second part' in line for line in rows), rows
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        mod.report(context, True)
    raw_item = next(i for i in json.loads(output.getvalue())['items'] if i['id'] == 'proj/merged')
    assert raw_item['reasons'][0]['text'] == 'first\nsecond\tpart'

def case2():
    before = snapshot()
    for selection in [('--class', 'safe'), ('--item', 'proj/merged')]:
        out = run('apply', '--root', str(R), '--repo', str(L), *selection)
        assert 'dry run: would delete proj/merged ' in out and 'dry run: nothing deleted' in out, out
        assert before == snapshot(), 'dry run changed fixture'

def case3():
    before = snapshot()
    for ids in [('proj/dirty',), ('proj/open',), ('proj/escape',), ('proj/archive-tmp-x',),
                ('proj/../outside',), ('unknown',), ('proj/merged', 'proj/dirty')]:
        args = [word for id in ids for word in ('--item', id)]
        out = run('apply', '--root', str(R), '--repo', str(L), '--yes', *args, code=1)
        assert 'refused ' in out and 'nothing deleted' in out, out
        assert before == snapshot(), 'invalid selection changed fixture'
    for category in ('caution', 'danger'):
        run('apply', '--root', str(R), '--repo', str(L), '--class', category, code=2)
    run('apply', '--root', str(R), '--repo', str(L), code=2)
    run('scan', '--root', str(F / 'absent'), '--repo', str(L), code=2)
    assert before == snapshot()

def case4():
    exclude = ('state/worktrees/proj/merged', 'state/worktrees/proj/wtsafe', 'L/.git/worktrees/wtsafe')
    ignore = ('state/worktrees/proj', 'L/.git/worktrees')
    before = snapshot(exclude, ignore)
    refs = git(L, 'for-each-ref')
    out = run('apply', '--root', str(R), '--repo', str(L), '--yes', '--class', 'safe')
    assert 'deleted proj/merged ' in out and 'deleted proj/wtsafe ' in out, out
    assert re.search(r'freed \d+ bytes .* from 2 item\(s\)', out), out
    assert not (R / 'merged').exists() and not (R / 'wtsafe').exists()
    after = snapshot(exclude, ignore)
    assert before == after, [(p, before.get(p), after.get(p)) for p in before.keys() | after.keys() if before.get(p) != after.get(p)]
    assert refs == git(L, 'for-each-ref'), 'live refs changed'
    assert str(R / 'wtsafe') not in git(L, 'worktree', 'list', '--porcelain')

def case5():
    mod = module()
    paths = [(str(R) + '/../outside/victim', str(R) + '/../outside'), (str(R / 'escape'), str(R)),
             (str(R / 'escape/.orchestra/wt/x'), str(R / 'escape/.orchestra/wt'))]
    # The textual traversal target must exist, so deletion without the guard would succeed.
    write(R.parent / 'outside/victim/file', 'must survive traversal')
    for path, root in paths:
        item = mod.Item('crafted', path, root, str(R))
        assert not mod.contained(item.path, item)
        try:
            mod.remove_tree(item)
        except mod.Refused:
            pass
        else:
            raise AssertionError('remove_tree did not refuse ' + path)
        assert os.path.exists(path)
    item = mod.Item('outside-worktree', str(F / 'coord'), str(R), str(R))
    assert not mod.contained(item.path, item)
    try:
        mod.remove_worktree(item, str(L / '.git'))
    except mod.Refused:
        pass
    else:
        raise AssertionError('remove_worktree did not refuse')
    assert (F / 'coord').is_dir()

def case6():
    mod = module()
    opts = options(mod)
    item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
    assert item.classification == 'SAFE', item.reasons
    write(R / 'merged/tracked', 'changed after selection\n')
    try:
        mod.delete_item(item, opts)
    except mod.Refused as error:
        assert 'no longer SAFE' in str(error)
    else:
        raise AssertionError('recheck did not refuse')
    assert (R / 'merged').is_dir()

def case7():
    mod = module()
    opts = options(mod)
    original = mod.mount_table
    mod.mount_table = lambda: ([str(R / 'merged/sub')], False)
    item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
    assert item.classification == 'DANGER' and 'mount point' in item.reason(), item.reasons
    mod.mount_table = original

    pid = str(os.getpid())
    original_readlink = mod.os.readlink
    cwd = original_readlink(f'/proc/{pid}/cwd')
    vanished = []
    with open(os.devnull) as handle:
        missing_link = f'/proc/{pid}/fd/{handle.fileno()}'
        def readlink(path, *args, **kwargs):
            if path == missing_link:
                vanished.append(path)
                raise FileNotFoundError(path)
            return original_readlink(path, *args, **kwargs)
        mod.os.readlink = readlink
        try:
            paths, _ = mod.process_table()
        finally:
            mod.os.readlink = original_readlink
    assert vanished, 'vanished fd was not inspected'
    assert any(path == cwd and found_pid == pid for path, found_pid, _ in paths), paths
    print('process scan: vanished fd retains cwd')

    write(F / 'state/sessions/bad.conf', 'this is not a record\n')
    item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
    assert item.classification == 'CAUTION' and 'activity records incomplete' in item.reason(), item.reasons
    (F / 'state/sessions/bad.conf').unlink()
    write(F / 'state/codex-projects/bad/project.json', '{')
    item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
    assert item.classification == 'CAUTION' and 'activity records incomplete' in item.reason(), item.reasons

def nondumpable(daemon):
    mod = module()
    opts = options(mod)
    child_pid = (F.parent / (F.name + '.nondumpable.pid')).read_text().strip()
    deadline = time.monotonic() + 5
    observable = False
    while time.monotonic() < deadline:
        try:
            observable = os.lstat(f'/proc/{child_pid}/fd').st_uid != os.getuid()
        except FileNotFoundError:
            pass
        if observable:
            break
        time.sleep(0.05)
    if observable:
        item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
        if daemon:
            assert item.classification == 'SAFE', item.reasons
            assert not any('process scan incomplete' in r['text'] for r in item.reasons), item.reasons
            print('process scan: non-dumpable sshd skipped; merged stays SAFE')
        else:
            assert item.classification == 'CAUTION', item.reasons
            assert any(f'process scan incomplete: pid {child_pid} (python3)' in r['text']
                       for r in item.reasons), item.reasons
            print('process scan: non-dumpable python3 makes merged CAUTION')
    else:
        print('skip: non-dumpable ownership not observable here')

def case7python():
    nondumpable(False)

def case7daemon():
    nondumpable(True)

def case8():
    shim = F.parent / ('shim-' + F.name)
    shim.mkdir()
    log = shim / 'argv.jsonl'
    real_git = shutil.which('git')
    write(shim / 'git', '#!/usr/bin/env python3\nimport json, os, sys\n' +
          f'with open({str(log)!r}, "a") as f: f.write(json.dumps([sys.argv[1:], {{k:v for k,v in os.environ.items() if k.startswith("GIT_")}}]) + "\\n")\n' +
          f'os.execv({real_git!r}, [{real_git!r}, *sys.argv[1:]])\n')
    (shim / 'git').chmod(0o755)
    env = dict(os.environ, PATH=str(shim) + ':' + os.environ['PATH'], GIT_DIR='/bogus/dir',
               GIT_WORK_TREE='/bogus/tree', GIT_INDEX_FILE='/bogus/index')
    before = snapshot()
    run('scan', '--root', str(R), '--repo', str(L), '--json', env=env)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert calls
    allowed = {'rev-parse', 'config', 'status', 'ls-files', 'for-each-ref', 'symbolic-ref',
               'worktree', 'cat-file', 'merge-base'}
    for args, git_env in calls:
        assert git_env == {'GIT_OPTIONAL_LOCKS': '0', 'GIT_TERMINAL_PROMPT': '0', 'GIT_NO_LAZY_FETCH': '1',
                           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'}, git_env
        assert args[0] == '-C' or args[0].startswith('--git-dir='), args
        offset = 2 if args[0] == '-C' else 1
        assert args[offset:offset+4] == ['-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never'], args
        command = args[offset+4:]
        assert command[0] in allowed, args
        if command[0] == 'worktree':
            assert command[1:] == ['list', '--porcelain'], args
        if command[0] == 'config':
            assert command[1:] == ['--get-regexp', r'^filter\.'], args
        if command[0] == 'cat-file':
            assert command[1] == '-e', args
        if command[0] == 'merge-base':
            assert command[1] == '--is-ancestor', args
    code = 'import sys,runpy; sys.modules["socket"]=sys.modules["ssl"]=None; sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")'
    result = subprocess.run(['python3', '-c', code, gc, 'scan', '--root', str(R), '--repo', str(L), '--json'],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['totals']['SAFE']['count'] == 2
    assert before == snapshot()

def case9():
    before = snapshot()
    report = json.loads(run('scan', '--json'))
    items = {i['id']: i for i in report['items']}
    assert 'proj/merged' in items and 'L/.orchestra/wt/lead-y' in items, items.keys()
    assert items['other/broken']['class'] == 'CAUTION', items['other/broken']
    assert items['proj/merged']['class'] == 'SAFE', items['proj/merged']
    assert not any('activity records incomplete' in r['text'] for r in items['proj/merged']['reasons'])
    assert items['backup/archive-tmp']['class'] == 'CAUTION'
    assert any('temp backup' in r['text'] for r in items['backup/archive-tmp']['reasons'])
    out = run('apply', '--yes', '--item', 'backup/archive-tmp', code=1)
    assert 'refused backup/archive-tmp' in out and 'nothing deleted' in out
    assert before == snapshot()

if action == 'fixture':
    fixture_setup()
else:
    globals()['case' + action]()
PY

make_fixture() {
  local fixture="$1"
  export HOME="$fixture/home" CC_ORCH_STATE_DIR="$fixture/state"
  export ORCH_ARCHIVE_STATE_DIRS="$fixture/state" ORCH_ARCHIVE_VAULT="$fixture/vault"
  export ORCH_ARCHIVE_RAW="$fixture/raw" ORCH_ARCHIVE_EXTRA_BASES="$fixture/home"
  python3 "$TMP/cases.py" fixture "$fixture" "$GC"
  worker_pids+=("$(cat "$fixture.pid")")
}
case_run() { python3 "$TMP/cases.py" "$1" "$2" "$GC"; }
for number in {1..9}; do
  fixture="$TMP/case-$number"
  make_fixture "$fixture"
  if [[ "$number" == 7 ]]; then
    (
      cd "$fixture"
      exec python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(4,0,0,0,0); time.sleep(300)'
    ) &
    worker_pids+=("$!")
    child_pid="$!"
    printf '%s\n' "$child_pid" > "$fixture.nondumpable.pid"
    case_run 7python "$fixture" || fail 'non-dumpable python3'
    kill "$child_pid"
    wait "$child_pid" 2>/dev/null || true
    (
      cd "$fixture"
      exec python3 -c 'import ctypes,time; libc=ctypes.CDLL(None); libc.prctl(15,b"sshd",0,0,0); libc.prctl(4,0,0,0,0); time.sleep(300)'
    ) &
    worker_pids+=("$!")
    child_pid="$!"
    printf '%s\n' "$child_pid" > "$fixture.nondumpable.pid"
    case_run 7daemon "$fixture" || fail 'non-dumpable sshd'
    kill "$child_pid"
    wait "$child_pid" 2>/dev/null || true
  fi
  case_run "$number" "$fixture" || fail "case $number"
  ok "case $number"
done

original_gc="$GC"
for marker in yes selection recheck contain-tree contain-worktree; do
  [[ $(grep -c "# GUARD:$marker\$" "$original_gc") == 1 ]] || fail "guard marker $marker"
  mutant="$TMP/mut-$marker"
  mkdir -p "$mutant/bin"
  ln -s "$ROOT/lib" "$mutant/lib"
  sed "s/^\( *\)if .*:  # GUARD:$marker\$/\1if False:  # GUARD:$marker/" \
    "$original_gc" > "$mutant/bin/orch-gc"
  ! cmp -s "$original_gc" "$mutant/bin/orch-gc" || fail "mutant unchanged: $marker"
  case "$marker" in
    yes) number=2 ;;
    selection) number=3 ;;
    recheck) number=6 ;;
    contain-*) number=5 ;;
  esac
  GC="$mutant/bin/orch-gc"
  fixture="$TMP/mutation-$marker"
  make_fixture "$fixture"
  if case_run "$number" "$fixture" > "$TMP/mutation-$marker.log" 2>&1; then
    fail "guard mutation survived: $marker"
  fi
  grep -q 'AssertionError' "$TMP/mutation-$marker.log" || {
    cat "$TMP/mutation-$marker.log"
    fail "mutation failed for an unrelated reason: $marker"
  }
  echo "mutation caught: $marker"
done
GC="$original_gc"
ok "case 10: all five guard mutations caught"
echo "PASS: $pass orch-gc cases"
