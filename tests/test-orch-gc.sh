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
import platform
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
                 'lent', 'shared', 'midop', 'submod', 'nlstale', 'stalereg', 'badrow', 'ancestor', 'reflogonly', 'orighead'):
        make_merged(name)
    make_merged('trail ', 'orch/trail')
    git(F, 'init', '--bare', str(R / 'submod/.git/modules/sub'))
    git(R / 'stalereg', 'worktree', 'add', str(F / 'tmpwt'), '-b', 'tmp/x')
    shutil.rmtree(F / 'tmpwt')
    # The registered worktree protects tmp/x; its tip is already merged into L.
    git(F, 'clone', '--separate-git-dir', str(F / 'sepgit'), str(L), str(R / 'sepdir'))
    write(R / 'reflogonly/tracked', 'reflog-only change\n')
    git(R / 'reflogonly', 'commit', '-am', 'reflog-only commit')
    git(R / 'reflogonly', 'reset', '--hard', 'HEAD~1')
    write(R / 'orighead/tracked', 'ORIG_HEAD-only change\n')
    git(R / 'orighead', 'commit', '-am', 'ORIG_HEAD-only commit')
    git(R / 'orighead', 'reset', '--hard', 'HEAD~1')
    git(R / 'orighead', 'reflog', 'expire', '--expire=now', '--all')
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
    for name, path in [('wtsafe', R / 'wtsafe'), ('wtrewritten', R / 'wtrewritten'), ('wtlocked', R / 'wtlocked'),
                       ('orch', R / 'orch'), ('coord', F / 'coord'), ('nlcoord', F / 'co\nord'),
                       ('lead-y', L / '.orchestra/wt/lead-y')]:
        git(L, 'worktree', 'add', '-b', 'wt/' + name, str(path))
        if name in ('wtsafe', 'wtrewritten', 'wtlocked'):
            artifacts(path)
            row(L, 'wt/' + name, directory=str(path / '.orchestra' / TASK))
    git(L, 'worktree', 'lock', str(R / 'wtlocked'))
    row(F / 'co\nord', 'orch/nlstale', 'RUNNING', str(R / 'nlstale/.orchestra' / TASK))
    private = git(L, 'commit-tree', git(L, 'rev-parse', 'HEAD^{tree}'),
                  '-p', git(L, 'rev-parse', 'HEAD'), '-m', 'worktree-private commit')
    git(R / 'wtrewritten', 'update-ref', 'refs/rewritten/keep', private)
    write(F / 'state/worktrees/other/broken/.git', f'gitdir: {F}/missing/.git/worktrees/broken\n')
    write(F / 'state/worktrees/other/broken/plain', 'broken worktree')
    row(R / 'orch', 'orch/open', 'RUNNING', 'open/.orchestra/' + TASK + '/')
    with (R / 'orch/.orchestra/REGISTRY.md').open('a') as stream:
        stream.write('| lead-bad | a2 | t | orch/badrow | badrow/.orchestra/01-task/ | RUNNING |\n')
    row(R.parent, 'orch/ancestor', 'RUNNING', 'proj/ancestor/.orchestra/' + TASK + '/')
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

DISABLED = ('orch-gc: apply is disabled in this release; nothing was deleted.\n'
            'orch-gc: deletion stays off until open review findings are fixed (--repo vs worktree items, '
            '"(deleted)" path names, "~N" id collisions, partial-clone fetch); a follow-up task re-enables it. '
            "Clean up manually after reading 'orch-gc scan'.\n")

def refuse_apply(*args, env=None):
    before = snapshot()
    argv = [os.fsencode(arg) for arg in ('python3', gc, 'apply', *args)]
    result = subprocess.run(argv, capture_output=True, env=env)
    assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
    assert result.stdout == b'', result.stdout
    assert result.stderr == DISABLED.encode('ascii'), result.stderr
    assert before == snapshot(), 'disabled apply changed fixture'

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

def preflight():
    _, incomplete = module().process_table()
    if incomplete:
        for message in incomplete:
            print('preflight: external ' + message, flush=True)
        raise AssertionError('preflight: external process scan incomplete')
    print('preflight: process scan complete')

def case1():
    before = snapshot()
    report = scan_json()
    items = {i['id']: i for i in report['items']}
    expected = {
        'SAFE': {'merged': 'merged into', 'wtsafe': 'merged into', 'trail ': 'merged into'},
        'CAUTION': {'dirty': 'dirty', 'unmerged': 'not merged', 'norow': 'no registry row',
                    'blocked': 'BLOCKED', 'branch2': 'not merged', 'tagged': 'not merged',
                    'stash': 'stash', 'ignored': 'git-ignored', 'hidden': 'index flags',
                    'filter': 'git filter', 'nogit': 'not a git checkout',
                    'parent': 'nested checkout', 'archive-tmp-x': 'temp backup',
                    'wtrewritten': 'not merged', 'midop': 'git operation in progress: MERGE_HEAD',
                    'submod': 'submodule repository present', 'stalereg': 'has linked worktree registration',
                    'sepdir': 'separate git dir', 'badrow': 'unparseable registry row',
                    'reflogonly': 'reflog-only commits', 'wtlocked': 'worktree locked',
                    'orighead': 'ORIG_HEAD not merged'},
        'DANGER': {'open': 'open registry row', 'stale': 'open registry row', 'secret': 'secret-shaped',
                   'escape': 'escapes root', 'proc': 'in use by pid', 'orch': 'session record',
                   'lent': 'objects borrowed by', 'shared': 'objects borrowed by',
                   'nlstale': 'open registry row', 'ancestor': 'open registry row'}}
    # The specified relative-dir matching also places orch's own RUNNING row under orch.
    for category, names in expected.items():
        for name, keyword in names.items():
            item = items['proj/' + name]
            assert item['class'] == category, item
            assert any(keyword in r['text'] for r in item['reasons']), item
    assert {i['id'] for i in items.values() if i['class'] == 'SAFE'} == {'proj/merged', 'proj/wtsafe', 'proj/trail '}
    assert 'proj/parent/.orchestra/wt/lead-x' in items
    assert not any(id.startswith('proj/escape/') for id in items)
    assert len(items) == sum(map(len, expected.values())) + 2, items.keys()  # nested worktree and borrower
    assert items['proj/merged']['archive'] == 'yes'
    assert not (F / 'filter-ran').exists()
    table = run('--root', str(R), '--repo', str(L))
    assert table.startswith('CLASS  SIZE  AGE  ARCHIVE  ID  REASON\n')
    assert len([line for line in table.splitlines() if line.startswith(('SAFE ', 'CAUTION ', 'DANGER '))]) == len(items)
    assert 'totals: SAFE 3 (' in table and 'archive is not a full copy' in table
    assert r'0-\xff.ckpt' in table, table
    assert report['totals']['all']['count'] == len(items)
    assert report['totals']['all']['bytes'] == sum(i['bytes'] for i in items.values())
    case1ascii()
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

def case1ascii():
    table = run('--root', str(R), '--repo', str(L), env=dict(os.environ, PYTHONIOENCODING='ascii'))
    totals = next(line for line in table.splitlines() if line.startswith('totals: '))
    assert r' \xb7 ' in totals, totals
    print('scan output: ASCII totals separator escaped')

def case2():
    before = snapshot()
    for selection in [('--class', 'safe'), ('--item', 'proj/merged')]:
        refuse_apply('--root', str(R), '--repo', str(L), *selection)
        assert before == snapshot(), 'disabled apply changed fixture'
    print('apply refusal: no --yes; fixture unchanged')

def case3():
    before = snapshot()
    for ids in [('proj/dirty',), ('proj/open',), ('proj/escape',), ('proj/archive-tmp-x',),
                ('proj/../outside',), ('unknown',), ('proj/merged', 'proj/dirty')]:
        args = [word for id in ids for word in ('--item', id)]
        refuse_apply('--root', str(R), '--repo', str(L), '--yes', *args)
        assert before == snapshot(), 'invalid selection changed fixture'
    for category in ('caution', 'danger'):
        refuse_apply('--root', str(R), '--repo', str(L), '--class', category)
    refuse_apply('--root', str(R), '--repo', str(L), '--item', 'proj/dirty')
    refuse_apply('--root', str(R), '--repo', str(L))
    refuse_apply()
    refuse_apply('--unknown-flag', 'value', '--yes')
    refuse_apply('--help')
    run('scan', '--root', str(F / 'absent'), '--repo', str(L), code=2)
    assert before == snapshot()
    print('apply refusal: invalid selections, bare apply and unknown flags; fixture unchanged')

def case4():
    before = snapshot()
    refs = git(L, 'for-each-ref')
    for selection in [('--class', 'safe'), ('--item', 'proj/merged'),
                      ('--item', 'proj/wtsafe'), ('--item', 'proj/trail ')]:
        refuse_apply('--root', str(R), '--repo', str(L), '--yes', *selection)
    assert (R / 'merged').is_dir() and (R / 'wtsafe').is_dir()
    assert (R / 'trail ').is_dir()
    after = snapshot()
    assert before == after, [(p, before.get(p), after.get(p)) for p in before.keys() | after.keys() if before.get(p) != after.get(p)]
    assert refs == git(L, 'for-each-ref'), 'live refs changed'
    assert str(R / 'wtsafe') in git(L, 'worktree', 'list', '--porcelain')
    print('apply refusal: --yes with SAFE selections; all checkouts and refs preserved')

def case5():
    mod = module()
    paths = [(str(R) + '/../outside/victim', str(R) + '/../outside'), (str(R / 'escape'), str(R)),
             (str(R / 'escape/.orchestra/wt/x'), str(R / 'escape/.orchestra/wt'))]
    # Keep the textual traversal target present for the containment checks.
    write(R.parent / 'outside/victim/file', 'must survive traversal')
    for path, root in paths:
        item = mod.Item('crafted', path, root, str(R))
        assert not mod.contained(item.path, item)
        assert os.path.exists(path)
    item = mod.Item('outside-worktree', str(F / 'coord'), str(R), str(R))
    assert not mod.contained(item.path, item)
    assert (F / 'coord').is_dir()

def case6():
    mod = module()
    opts = options(mod)
    item = next(i for i in mod.scan(opts).items if i.id == 'proj/merged')
    assert item.classification == 'SAFE', item.reasons
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

    zombie = os.fork()
    if zombie == 0:
        os._exit(0)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            state = Path(f'/proc/{zombie}/stat').read_bytes().rpartition(b') ')[2][:1]
            if state == b'Z':
                break
            time.sleep(0.05)
        else:
            raise AssertionError('child did not become a zombie')
        _, incomplete = mod.process_table()
        assert not any(f'pid {zombie} ' in message for message in incomplete), incomplete
    finally:
        os.waitpid(zombie, 0)
    print('process scan: zombie skipped without incomplete reason')

    original_lstat = mod.os.lstat
    attempts = []
    def transient_lstat(path, *args, **kwargs):
        if path == f'/proc/{pid}/fd':
            attempts.append(path)
            if len(attempts) == 1:
                raise PermissionError(path)
        return original_lstat(path, *args, **kwargs)
    mod.os.lstat = transient_lstat
    try:
        paths, incomplete = mod.process_table()
    finally:
        mod.os.lstat = original_lstat
    assert len(attempts) == 2, attempts
    assert not any(f'pid {pid} ' in message for message in incomplete), incomplete
    assert any(path == cwd and found_pid == pid for path, found_pid, _ in paths), paths
    print('process scan: transient inspection failure retried successfully')

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

def case7mapped():
    ready = F.parent / (F.name + '.mapped.ready')
    deadline = time.monotonic() + 5
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert ready.exists(), 'mapped-file child did not become ready'
    pid = (F.parent / (F.name + '.mapped.pid')).read_text().strip()
    mod = module()
    item = next(i for i in mod.scan(options(mod)).items if i.id == 'proj/merged')
    assert item.classification == 'DANGER', item.reasons
    assert any(f'in use by pid {pid} ' in r['text'] for r in item.reasons), item.reasons
    print('process scan: closed-fd mapping makes merged DANGER')

def case7nlsetup():
    (R / 'merged').rename(R / 'mapped\ncheckout')

def case7nlmapped():
    ready = F.parent / (F.name + '.nlmapped.ready')
    deadline = time.monotonic() + 5
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert ready.exists(), 'newline-mapped-file child did not become ready'
    pid = (F.parent / (F.name + '.nlmapped.pid')).read_text().strip()
    mod = module()
    item = next(i for i in mod.scan(options(mod)).items if i.id == 'proj/mapped\ncheckout')
    assert item.classification == 'DANGER', item.reasons
    assert any(f'in use by pid {pid} ' in r['text'] for r in item.reasons), item.reasons
    print('process scan: closed-fd mapping in newline checkout makes it DANGER')

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
               'rev-list', 'cat-file', 'merge-base'}
    for args, git_env in calls:
        assert git_env == {'GIT_OPTIONAL_LOCKS': '0', 'GIT_TERMINAL_PROMPT': '0', 'GIT_NO_LAZY_FETCH': '1',
                           'GIT_ALLOW_PROTOCOL': '', 'GIT_CONFIG_GLOBAL': '/dev/null',
                           'GIT_CONFIG_NOSYSTEM': '1'}, git_env
        assert args[0] == '-C' or args[0].startswith('--git-dir='), args
        offset = 2 if args[0] == '-C' else 1
        assert args[offset:offset+4] == ['-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never'], args
        command = args[offset+4:]
        assert command[0] in allowed, args
        if command[0] == 'rev-list':
            assert command[1:] == ['--reflog', '--not', '--all'], args
        if command[0] == 'config':
            assert command[1:] in (['--get-regexp', r'^filter\.'],
                                   ['--get-regexp', r'^(extensions\.partialclone|remote\..*\.promisor)$']), args
        if command[0] == 'cat-file':
            assert command[1] == '-e', args
        if command[0] == 'merge-base':
            assert command[1] == '--is-ancestor', args
    code = 'import sys,runpy; sys.modules["socket"]=sys.modules["ssl"]=None; sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")'
    result = subprocess.run(['python3', '-c', code, gc, 'scan', '--root', str(R), '--repo', str(L), '--json'],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['totals']['SAFE']['count'] == 3
    assert before == snapshot()
    scan_log = log.read_bytes()
    for args in [(), ('--yes', '--class', 'safe'), ('--yes', '--item', 'proj/merged'),
                 ('--item', 'proj/dirty'), ('--class', 'caution'), ('--unknown-flag',), ('--help',)]:
        refuse_apply(*args, env=env)
        assert log.read_bytes() == scan_log, 'disabled apply called git'
    print('apply refusal: zero git calls under the git shim')

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
    refuse_apply('--yes', '--item', 'backup/archive-tmp')
    assert before == snapshot()

def case10():
    source = Path(gc).read_text()
    assert not re.search(r'rmtree|os\.(remove|unlink|rmdir)|shutil|worktree remove|"remove"', source)
    assert '# GUARD:' not in source
    mod = module()
    assert not any(hasattr(mod, name) for name in ('delete_item', 'remove_tree', 'remove_worktree', 'Refused'))
    originals = {name: getattr(mod, name) for name in ('Context', 'scan', 'git')}
    def unexpected(*args, **kwargs):
        raise AssertionError('disabled apply reached Context, scan or git')
    before = snapshot()
    try:
        for name in originals:
            setattr(mod, name, unexpected)
        for args in [[], ['--root', str(R), '--repo', str(L), '--yes', '--class', 'safe'],
                     ['--unknown-flag'], ['--help']]:
            output, errors = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                code = mod.main(['apply', *args])
            assert code == 1, (code, errors.getvalue())
            assert output.getvalue() == '', output.getvalue()
            assert errors.getvalue() == DISABLED, errors.getvalue()
    finally:
        for name, original in originals.items():
            setattr(mod, name, original)
    assert before == snapshot()
    print('apply refusal: no deletion primitives; returns before Context, scan or git')

def byte_items():
    names = [os.fsdecode(b'bytes-safe-\xff'), os.fsdecode(b'bytes-dirty-\xff')]
    for original, name in zip(('bytes-safe', 'bytes-dirty'), names):
        path = make_merged(original)
        path.rename(R / name)
    write(R / names[1] / 'tracked', 'changed dirty bytes fixture\n')
    return names

def case11():
    safe, dirty = byte_items()
    before = snapshot()
    for name in (dirty, safe):
        refuse_apply('--root', str(R), '--repo', str(L), '--yes', '--item', 'proj/' + name)
        assert (R / name).is_dir()
        assert before == snapshot()
    print('apply refusal: non-UTF-8 SAFE and CAUTION ids; fixture unchanged')

def case12repo():
    reference = F / 'otherref'
    git(F, 'init', str(reference))
    git(reference, 'checkout', '-b', 'local/installed-main')
    write(reference / 'unrelated', 'unrelated repository\n')
    git(reference, 'add', 'unrelated')
    git(reference, 'commit', '-m', 'unrelated')
    before = snapshot()
    report = json.loads(run('scan', '--root', str(R), '--repo', str(reference), '--json'))
    item = next(i for i in report['items'] if i['id'] == 'proj/wtsafe')
    assert item['class'] != 'SAFE', item
    assert any('not merged into local/installed-main' in r['text'] for r in item['reasons']), item
    report = json.loads(run('scan', '--root', str(R), '--repo', str(R / 'wtsafe'), '--json'))
    item = next(i for i in report['items'] if i['id'] == 'proj/wtsafe')
    assert item['class'] == 'DANGER', item
    assert any(r['text'] == 'contains the reference repository' for r in item['reasons']), item
    assert before == snapshot()

def case12deleted():
    original, renamed = R / 'merged', R / 'merged (deleted)'
    original.rename(renamed)
    process = None
    try:
        process = subprocess.Popen(['sleep', '300'], cwd=renamed)
        item = next(i for i in scan_json()['items'] if i['id'] == 'proj/merged (deleted)')
        assert item['class'] == 'DANGER', item
        assert any(f'in use by pid {process.pid} ' in r['text'] for r in item['reasons']), item
    finally:
        if process is not None:
            process.terminate()
            process.wait()
        renamed.rename(original)

def case12ids():
    first, second = F / 'ida/proj', F / 'idb/proj'
    for path in (first / 'dup', second / 'dup', second / 'dup~2'):
        path.mkdir(parents=True)
    report = json.loads(run('scan', '--root', str(first), '--root', str(second),
                            '--repo', str(L), '--json'))
    ids = [i['id'] for i in report['items']]
    assert len(ids) == len(set(ids)), ids
    paths = {i['id']: i['path'] for i in report['items']}
    assert paths['proj/dup~2'] == str(second / 'dup~2'), paths
    assert paths['proj/dup'] == str(first / 'dup'), paths
    assert paths['proj/dup~3'] == str(second / 'dup'), paths

def case12partial():
    shim = F.parent / ('partial-' + F.name)
    shim.mkdir()
    helper_log, trace_log = shim / 'helper.log', shim / 'trace.log'
    real_git = shutil.which('git')
    write(shim / 'git-remote-counting', '#!/usr/bin/env python3\nimport sys\n' +
          f'with open({str(helper_log)!r}, "a") as f: f.write(repr(sys.argv) + "\\n")\n' +
          'sys.exit(1)\n')
    # Model upstream Git 2.34, which ignores GIT_NO_LAZY_FETCH; Ubuntu 2.34.1 backports it.
    write(shim / 'git', '#!/usr/bin/env python3\nimport os, sys\n' +
          'env = dict(os.environ)\nenv.pop("GIT_NO_LAZY_FETCH", None)\n' +
          f'env["GIT_TRACE"] = {str(trace_log)!r}\n' +
          f'os.execve({real_git!r}, [{real_git!r}, *sys.argv[1:]], env)\n')
    for name in ('git', 'git-remote-counting'):
        (shim / name).chmod(0o755)
    env = dict(os.environ, PATH=str(shim) + ':' + os.environ['PATH'])
    promisor = F.parent / ('promisor-' + F.name)
    git(F, 'clone', '--bare', str(R / 'unmerged'), str(promisor))
    missing = git(R / 'unmerged', 'rev-parse', 'HEAD')
    partial = F / 'partial'
    for url, protocol in (('counting::stub', 'counting'), (str(promisor), 'file')):
        def reset_partial():
            if partial.exists():
                shutil.rmtree(partial)
            git(F, 'clone', str(L), str(partial))
            for key, value in (('core.repositoryformatversion', '1'),
                               ('extensions.partialClone', 'origin'),
                               ('remote.origin.promisor', 'true'), ('remote.origin.url', url),
                               ('protocol.' + protocol + '.allow', 'always')):
                git(partial, 'config', key, value)

        reset_partial()
        subprocess.run(['git', '--git-dir=' + str(partial / '.git'), 'cat-file', '-e',
                        missing + '^{commit}'], env=env, capture_output=True, text=True)
        assert any(' fetch ' in line for line in trace_log.read_text().splitlines()), trace_log.read_text()
        if protocol == 'counting':
            assert helper_log.exists() and helper_log.read_bytes(), 'positive control did not run helper'
        reset_partial()
        helper_log.unlink(missing_ok=True)
        trace_log.unlink(missing_ok=True)
        before = snapshot(exclude=('partial',))
        report = json.loads(run('scan', '--root', str(R), '--repo', str(partial), '--json', env=env))
        trace = trace_log.read_text()
        assert not any(' fetch ' in line for line in trace.splitlines()), trace
        assert not helper_log.exists(), 'scan ran a remote helper'
        items = {i['id']: i for i in report['items']}
        assert items['proj/unmerged']['class'] != 'SAFE', items['proj/unmerged']
        merged = items['proj/merged']
        assert merged['class'] == 'CAUTION', merged
        assert any('partial clone' in r['text'] for r in merged['reasons']), merged
        result = subprocess.run([real_git, '--git-dir=' + str(partial / '.git'), 'cat-file', '-e', missing],
                                env=dict(os.environ, GIT_NO_LAZY_FETCH='1'), capture_output=True)
        assert result.returncode != 0, 'scan fetched the missing object'
        assert before == snapshot(exclude=('partial',))
        print(f'partial clone: {protocol} positive control attempted fetch; scan spawned no fetch or helper')

    repo = R / 'merged'
    registry_path = F / 'coord/.orchestra/REGISTRY.md'
    original_registry = registry_path.read_text()
    git(repo, 'config', 'core.repositoryformatversion', '1')
    git(repo, 'config', 'extensions.partialClone', 'origin')
    git(repo, 'config', 'remote.origin.promisor', 'true')
    try:
        row(F / 'coord', 'orch/merged', 'RUNNING', 'nowhere/')
        trace_log.unlink(missing_ok=True)
        report = json.loads(run('scan', '--root', str(R), '--repo', str(L), '--json', env=env))
        merged = next(i for i in report['items'] if i['id'] == 'proj/merged')
        assert merged['class'] == 'DANGER', merged
        assert any('open registry row' in r['text'] for r in merged['reasons']), merged
        assert any('partial clone:' in r['text'] for r in merged['reasons']), merged
        trace = trace_log.read_text()
        assert not any(' fetch ' in line for line in trace.splitlines()), trace
        print('partial clone: branch-only RUNNING row keeps merged DANGER; scan spawned no fetch')
    finally:
        git(repo, 'config', '--unset', 'remote.origin.promisor')
        git(repo, 'config', '--unset', 'extensions.partialClone')
        git(repo, 'config', 'core.repositoryformatversion', '0')
        registry_path.write_text(original_registry)

def case12zombie():
    syscall = {'x86_64': 60, 'aarch64': 93}.get(platform.machine())
    if syscall is None:
        print('skip: zombie leader syscall unavailable on ' + platform.machine())
        return
    ready = F.parent / (F.name + '.zombie.ready')
    code = ('import ctypes, os, sys, threading, time\n'
            'held = open(sys.argv[1])\nos.chdir("/")\n'
            'threading.Thread(target=time.sleep, args=(300,)).start()\n'
            'open(sys.argv[2], "w").close()\n'
            f'ctypes.CDLL(None).syscall({syscall}, 0)\n')
    holder = subprocess.Popen(['python3', '-c', code, str(R / 'merged/tracked'), str(ready)])
    pid = str(holder.pid)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if ready.exists() and Path(f'/proc/{pid}/stat').read_bytes().rpartition(b') ')[2][:1] == b'Z':
                break
            time.sleep(0.05)
        else:
            raise AssertionError('holder did not become a zombie leader')
        item = next(i for i in scan_json()['items'] if i['id'] == 'proj/merged')
        assert item['class'] == 'DANGER', item
        assert any(f'in use by pid {pid} ' in r['text'] for r in item['reasons']), item
        mod = module()
        tid = next(t for t in sorted(os.listdir(f'/proc/{pid}/task')) if t != pid)
        worker_fd = f'/proc/{pid}/task/{tid}/fd'
        original_lstat = mod.os.lstat
        for persistent in (False, True):
            attempts = []
            def vanished_lstat(path, *args, **kwargs):
                if path == worker_fd:
                    attempts.append(path)
                    if persistent or len(attempts) == 1:
                        raise FileNotFoundError(path)
                return original_lstat(path, *args, **kwargs)
            mod.os.lstat = vanished_lstat
            try:
                paths, incomplete = mod.process_table()
            finally:
                mod.os.lstat = original_lstat
            if persistent:
                assert not any(found_pid == pid for _, found_pid, _ in paths), paths
                assert any(f'pid {pid} ' in message for message in incomplete), incomplete
            else:
                assert len(attempts) == 2, attempts
                assert any(path.startswith(str(R / 'merged') + '/') and found_pid == pid
                           for path, found_pid, _ in paths), paths
                assert not any(f'pid {pid} ' in message for message in incomplete), incomplete
    finally:
        holder.terminate()
        holder.wait()
        ready.unlink(missing_ok=True)

if action == 'fixture':
    fixture_setup()
elif action == 'preflight':
    preflight()
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
python3 "$TMP/cases.py" preflight "$TMP/preflight" "$GC" || fail 'external process preflight'
fixture="$TMP/case-12"
make_fixture "$fixture"
failed=()
for finding in 12repo 12deleted 12ids 12partial 12zombie; do
  if case_run "$finding" "$fixture"; then ok "case $finding"; else echo "FAIL: case $finding" >&2; failed+=("$finding"); fi
done
[[ ${#failed[@]} -eq 0 ]] || fail "regression cases: ${failed[*]}"
for number in {1..9}; do
  fixture="$TMP/case-$number"
  make_fixture "$fixture"
  if [[ "$number" == 7 ]]; then
    (
      exec python3 -c 'import mmap,os,sys,time; f=open(sys.argv[1],"rb"); mapping=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ,trackfd=False); f.close(); os.chdir("/"); open(sys.argv[2],"w").close(); time.sleep(300)' \
        "$fixture/state/worktrees/proj/merged/tracked" "$fixture.mapped.ready"
    ) &
    worker_pids+=("$!")
    child_pid="$!"
    printf '%s\n' "$child_pid" > "$fixture.mapped.pid"
    case_run 7mapped "$fixture" || fail 'mapped-file activity'
    kill "$child_pid"
    wait "$child_pid" 2>/dev/null || true
    case_run 7nlsetup "$fixture" || fail 'newline-mapped-file setup'
    (
      exec python3 -c 'import mmap,os,sys,time; f=open(sys.argv[1],"rb"); mapping=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ,trackfd=False); f.close(); os.chdir("/"); open(sys.argv[2],"w").close(); time.sleep(300)' \
        "$fixture/state/worktrees/proj/"$'mapped\ncheckout/tracked' "$fixture.nlmapped.ready"
    ) &
    worker_pids+=("$!")
    child_pid="$!"
    printf '%s\n' "$child_pid" > "$fixture.nlmapped.pid"
    case_run 7nlmapped "$fixture" || fail 'newline-mapped-file activity'
    kill "$child_pid"
    wait "$child_pid" 2>/dev/null || true
    mv "$fixture/state/worktrees/proj/"$'mapped\ncheckout' "$fixture/state/worktrees/proj/merged"
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

fixture="$TMP/case-10"
make_fixture "$fixture"
case_run 10 "$fixture" || fail 'case 10'
ok 'case 10: disabled apply has no deletion path'
fixture="$TMP/case-11"
make_fixture "$fixture"
case_run 11 "$fixture" || fail 'case 11'
ok 'case 11: non-UTF-8 apply refusal'
echo "PASS: $pass orch-gc cases"
