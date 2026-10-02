#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
ARCHIVE_TEST_HOME="$(mktemp -d)"
trap 'rm -rf -- "$ARCHIVE_TEST_HOME"' EXIT
export HOME="$ARCHIVE_TEST_HOME" PYTHONDONTWRITEBYTECODE=1
export ORCH_ARCHIVE_VAULT="$HOME/vault" ORCH_ARCHIVE_RAW="$HOME/raw"
export ORCH_ARCHIVE_ALLOWLIST="$HOME/allowlist.txt"
export ORCH_ARCHIVE_STATE_DIRS="$HOME/state:$HOME/codex-state"
export ORCH_ARCHIVE_CLAUDE_PROJECTS="$HOME/claude-projects"
export ORCH_ARCHIVE_CODEX_HOME="$HOME/codex" CODEX_HOME="$HOME/codex"
export ORCH_ARCHIVE_EXTRA_BASES="$HOME/extra" CC_ORCH_STATE_DIR="$HOME/state"
export ORCH_ARCHIVE_POLICY="$HOME/archive.conf" ARCHIVE_REPO_DIR="$REPO_DIR"
python3 - <<'PY'
import sys
sys.dont_write_bytecode = True
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess

repo = Path(os.environ['ARCHIVE_REPO_DIR'])
home = Path(os.environ['HOME'])
vault, raw = home / 'vault', home / 'raw'
command = repo / 'bin/orch-archive'
sys.path.insert(0, str(repo / 'lib'))
import orch_archive as archive
groups = 0

def ok(condition, description):
    global groups
    groups += 1
    if not condition:
        print(f'fail {groups} - {description}', flush=True)
        raise AssertionError(description)
    print(f'ok {groups} - {description}', flush=True)

def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())

def run(*args, code=0, env=None):
    result = subprocess.run([str(command), *args], env=env, text=True, capture_output=True)
    if result.returncode != code:
        print(result.stdout)
        print(result.stderr)
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}')
    return result.stdout

def git_read(*args):
    return subprocess.check_output(['git', '-C', str(vault), *args], env=archive.git_env(), text=True).strip()

def listing(base, exclude=()):
    result = {}
    for path in sorted(base.rglob('*')):
        if any(path == p or p in path.parents for p in exclude):
            continue
        st = path.lstat()
        result[str(path.relative_to(base))] = (st.st_size, st.st_mtime_ns, stat.S_IMODE(st.st_mode), st.st_ino)
    return result

def hashes(base, exclude_git=False):
    return {str(path.relative_to(base)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(base.rglob('*')) if path.is_file() and not path.is_symlink()
            and not (exclude_git and '.git' in path.relative_to(base).parts)}

def source_hashes():
    return {str(path): hashes(path) for path in (p1, p2, p3, home / 'claude-projects', home / 'codex', home / 'state', home / 'codex-state')}

def catalog():
    return json.loads((vault / '_meta/catalog.json').read_text())

def generation(path):
    key = archive.sha(str(path.resolve()).encode())[:24]
    return json.loads((raw / f'sources/{key}.json').read_text())['generations'][-1]

def reconstruct(gen):
    pointers = gen['chunks'] + ([gen['tail']] if gen.get('tail') else [])
    return b''.join(gzip.decompress((raw / pointer['blob']).read_bytes()) for pointer in pointers)

cache_before = {str(p) for base in (repo / 'lib', repo / 'eval/jev-phase0') for p in base.rglob('__pycache__')}
p1, p2, p3 = (home / name for name in ('project-one', 'project-two', 'codex-only'))
for p in (p1, p2, p3, home / 'extra'):
    p.mkdir()
put(home / 'archive.conf', 'PAYLOAD_FILE_MAX_BYTES=8\nPAYLOAD_TASK_MAX_BYTES=32\nSIZE_REPORT_BYTES=32\n')
token = 'AKIA' + 'ABCDEFGHIJKLMNOP'
other_token = 'AKIA' + 'PONMLKJIHGFEDCBA'
put(home / 'state/sessions/alpha.conf', f'LAUNCH_NAME=alpha\nPROJECT_NAME=demo\nREPO={p1}\nWORKDIR={p1}\nBACKEND=claude\nCREATED_AT=2026-01-01\nPRIVATE={token}\nOTHER_PRIVATE={other_token}\n')
put(home / 'state/projects/alpha', f'dir={p1}\ncreated_at=2026-01-01\n')
put(home / 'state/projects/server', f'dir={home}\ncreated_at=2026-01-01\n')
put(home / 'codex-state/sessions/beta.conf', f'PROJECT_NAME=demo\nNAME=beta\nREPO={p2}\n'
    + r"NOTES=$'line\n\tquote\'\x41\101\\'" + '\n')
put(home / 'state/sessions/broken.conf', 'LAUNCH_NAME=broken\nNAME=x\nNAME=duplicate\nBAD=two words\nnot-an-assignment\n')
put(home / 'codex-state/codex-projects/native/project.json', json.dumps({'directory': str(p3), 'session_id': '22222222-2222-2222-2222-222222222222'}))

def task(base, name, summary=None, extra=''):
    path = base / '.orchestra' / name
    put(path / 'brief.md', f'# {name}\nRISK: normal\n## Git\nBRANCH: orch/{name}\n{extra}')
    put(path / 'plan.md', '# Plan\n')
    if summary is not None:
        put(path / 'summary.md', summary)
    return path

t1 = task(p1, '05-dup', 'STATUS: PASS\nSTATUS: FAIL\nCLAUDE PROFILE: lead-alpha opus@high\nCODEX PROFILE: gpt-6.1-sol@high\nROUNDS: 2\nCOMMITS: abc1234 1234567\n')
fence = chr(96) * 3
outer_fence = chr(96) * 4
put(t1 / 'brief.md', (t1 / 'brief.md').read_text().replace('RISK: normal',
    f'{outer_fence}text\n{fence}text\nRISK: critical\n{fence}\n{outer_fence}\nRISK: normal'))
t2 = task(p2, '05-dup', f'STATUS: PASS\n{fence}text\n[lead-alpha] STATUS: FAIL\n{fence}\nBRANCH: orch/05-dup MODE: inplace WORKTREE: /tmp/example\n')
task(p1, '01-base', 'STATUS: PASS\n')
task(p1, '02-other', 'STATUS: PASS\n')
running = task(p1, '06-running', extra='Build on orch/01-base\nConstraints as in orch/02-other\nT18 is a test reference.\n')
task(p1 / '.orchestra/wt/checkout', '07-old', 'STATUS: CLOSED\n')
task(p3, '01-codex-task')
home_task = task(home, '01-home')
(p1 / '.orchestra/08-empty').mkdir()
put(p1 / '.orchestra/REGISTRY.md', '| task | dir | branch | status | owner | risk | date | note |\n'
    '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
    f'| 5 | .orchestra/05-dup | orch/05-dup | PASS | lead | normal | today | 한국어 원문 보존 [[missing-note]] {token} |\n')
put(p2 / '.orchestra/REGISTRY.md', '| dir | status | note |\n| --- | --- | --- |\n'
    '| .orchestra/05-dup | FAIL | 한국어 원문 보존 [[missing-note]] |\n')
put(t2 / 'summary.md', (t2 / 'summary.md').read_text() + 'GATES: [[ -f x ]]\n')
put(t1 / 'secret.md', f'{token}\n')
put(t1 / 'secret-[[historical-name]].md', f'{token}\n')
put(t1 / 'invalid-history.json', 'Verbatim historical text, not JSON.\n')
put(t1 / f'{token}.md', 'A safe body with a secret-shaped filename.\n')
put(t1 / 'payload.png', b'P' * 64)
put(t1 / 'tiny.png', b'P')
put(t1 / 'partial.log', b'complete\nunterminated')
outside = home / 'outside.txt'
put(outside, 'outside target must never be followed\n')
(t1 / 'outside-link').symlink_to(outside)
thread = '11111111-1111-1111-1111-111111111111'
put(t1 / '.codex-session', f'implement={thread}|gpt-6.1-sol|high\nold={thread}|gpt-5.4|medium\n')
put(t1 / 'codex-implement.jsonl', json.dumps({'type': 'thread.started', 'thread_id': thread}) + '\n')
rollout = home / f'codex/sessions/2026/rollout-2026-{thread}.jsonl'
put(rollout, '{"type":"event"}\n')
put(home / 'codex/archived_sessions/rollout-old-22222222-2222-2222-2222-222222222222.jsonl', '{"type":"old"}\n')
put(home / 'codex/sessions/rollout-native-33333333-3333-3333-3333-333333333333.jsonl', '{}\n')
claude_project = home / 'claude-projects' / re.sub(r'[^A-Za-z0-9]', '-', str(p1))
transcript = claude_project / 'main.jsonl'
put(transcript, json.dumps({'cwd': str(p1), 'message': 'original'}) + '\n')
put(claude_project / 'main/subagents/agent-a.jsonl', '{}\n')
put(claude_project / 'main/subagents/agent-a.meta.json', '{}\n')
put(home / 'claude-projects/unlinked/not-ours.jsonl', '{"cwd":"/not/cc-orch"}\n')
put(home / 'claude-projects/cwd-linked/a-no-cwd.jsonl', '{}\n')
put(home / 'claude-projects/cwd-linked/b-with-cwd.jsonl', json.dumps({'cwd': str(p1)}) + '\n')

# Hostile git environment/config must not escape the fixture vault.
put(home / '.gitconfig', f'[core]\n\thooksPath = {home}/hostile-hooks\n')
hook = home / 'hostile-hooks/pre-commit'
put(hook, '#!/bin/sh\ntouch "' + str(home / 'HOOK-RAN') + '"\n')
hook.chmod(0o700)
os.environ.update(GIT_DIR=str(home / 'external-git'), GIT_WORK_TREE=str(home / 'external-worktree'), GIT_INDEX_FILE=str(home / 'external-index'))
# Pin recorded source times so primary selection cannot depend on crossing a wall-clock second.
for base, recorded in ((p1, 1767225600), (p2, 1767312000), (p3, 1767225600)):
    for path in base.rglob('*'):
        if path.is_file() and not path.is_symlink():
            os.utime(path, (recorded, recorded))
tree_before = listing(home)
sources_before = source_hashes()
report = json.loads(run('--json'))
ok(listing(home) == tree_before and not vault.exists() and not raw.exists() and report['logical_tasks'] == 8,
   'default plan writes nothing and discovers nested, empty and Codex-only tasks')
first = run('apply')
generated_bytes = sum(p.stat().st_size for p in vault.rglob('*') if p.is_file() and '.git' not in p.relative_to(vault).parts)
ok(source_hashes() == sources_before and 'commit:' in first and report['vault_bytes'] == generated_bytes
   and sum(report['vault_bytes_breakdown'].values()) == generated_bytes,
   'apply leaves every source unchanged and plan includes all generated metadata bytes')
vault_before, raw_before = hashes(vault, True), hashes(raw)
mtimes_before = listing(vault, (vault / '.git',)), listing(raw)
count_before = git_read('rev-list', '--count', 'HEAD')
second = run('apply')
ok(hashes(vault, True) == vault_before and hashes(raw) == raw_before and count_before == git_read('rev-list', '--count', 'HEAD')
   and mtimes_before == (listing(vault, (vault / '.git',)), listing(raw)) and '0 files written' in second and 'commit: none' in second,
   're-apply preserves bytes, mtimes and commit count')
cat = catalog()
dup = cat['tasks']['demo--05-dup']
fields, body = archive.frontmatter((vault / 'tasks/demo--05-dup.md').read_text())
empty_fields, _ = archive.frontmatter((vault / 'tasks/demo--08-empty.md').read_text())
assert all(set(source) == {'path', 'present', 'snapshot', 'root'} for source in fields['sources'])
assert [source['path'] for source in fields['sources']] == sorted(source['path'] for source in fields['sources'])
assert dup['sessions'] == ['alpha', 'demo-beta'] and 'server' not in dup['sessions']
assert cat['tasks']['home--01-home']['project'] == 'home'
assert cat['tasks']['home--01-home']['sessions'] == ['server']
assert archive.Discovery(archive.load_policy(), archive.Guard(archive.load_policy())).run().bases[home][0] == ('server', 'home')
for snapshot in dup['snapshots'].values():
    assert 'entries' not in snapshot
    manifest_data = (vault / snapshot['manifest']['path']).read_bytes()
    manifest = json.loads(manifest_data)
    assert archive.sha(manifest_data) == snapshot['manifest']['sha256']
    assert snapshot['files'] == len(manifest['entries'])
    assert snapshot['bytes'] == sum(entry['size'] for entry in manifest['entries'])
    assert snapshot['counts'] == dict(archive.collections.Counter(entry['kind'] for entry in manifest['entries']))
    assert all(len(line) < 4096 for line in manifest_data.splitlines())
assert empty_fields['status'] == 'running' and empty_fields['created'] == empty_fields['updated'] == 'unknown'
ok(len(dup['snapshots']) == 2 and len(dup['locations']) == 2 and 'status' in fields['conflicts'] and
   fields['status'] == 'fail' and fields['registry_statuses'] == ['FAIL', 'PASS'] and 'Per-snapshot values' in body and
   fields['models'] == ['[[models/claude-opus]]', '[[models/gpt-5.4]]', '[[models/gpt-6.1-sol]]'] and
   {snap['fields']['risk'] for snap in dup['snapshots'].values()} == {'normal'} and
   (vault / 'models/claude-opus.md').is_file() and (vault / 'models/gpt-6.1-sol.md').is_file(),
   'compact sources/manifests, deepest session ownership, home project and conflicting snapshot provenance')
ok('한국어 원문 보존 [[missing-note]]' in body and '[[ -f x ]]' in body and 'verify: OK' in run('verify'),
   'Korean history and historical wikilinks are fenced; verify passes')
running_fields, _ = archive.frontmatter((vault / 'tasks/demo--06-running.md').read_text())
ok(running_fields['status'] == 'running' and running_fields['predecessors'] == ['[[tasks/demo--01-base]]'] and
   running_fields['mentions'] == ['[[tasks/demo--02-other]]'] and running_fields['unresolved_refs'] == ['T18'] and
   len(cat['sessions']['alpha']['sources']) == 2 and cat['sessions']['demo-beta']['fields']['NOTES'] == "line\n\tquote'AA\\" and
   len(cat['sessions']['broken']['parse_error']) == 3,
   'evidence-based relations, merged sessions, ANSI-C decoder and parse errors')
ok(reconstruct(generation(t1 / 'partial.log')) == (t1 / 'partial.log').read_bytes() and generation(t1 / 'partial.log')['tail'] is not None,
   'static unterminated log tail is preserved')
before_chunks = len(generation(transcript)['chunks'])
with transcript.open('ab') as stream:
    stream.write(b'{"live":true}\npartial')
source_bytes = transcript.read_bytes()
run('apply')
gen = generation(transcript)
ok(transcript.read_bytes() == source_bytes and len(gen['chunks']) == before_chunks + 1 and gen['tail'] is not None
   and reconstruct(gen) == source_bytes, 'live append adds complete-line chunk and preserves partial tail')
with transcript.open('ab') as stream:
    stream.write(b'-completed\n')
source_bytes = transcript.read_bytes()
run('apply')
ok(transcript.read_bytes() == source_bytes and reconstruct(generation(transcript)) == source_bytes and generation(transcript)['tail'] is None,
   'completing the tail advances the watermark losslessly')
withheld = (vault / '_meta/withheld.md').read_text()
digest = archive.sha((t1 / 'secret.md').read_bytes())
all_vault_text = [p.read_text() for p in vault.rglob('*') if p.is_file() and '.git' not in p.relative_to(vault).parts]
ok(all(not archive.scan_record(text)[0] for text in all_vault_text) and token not in ''.join(all_vault_text)
   and digest in withheld and digest in first and all(kind in withheld for kind in ('artifact', 'path', 'field')),
   'artifact, conf, registry and filename secrets are withheld across every vault byte')
put(home / 'allowlist.txt', f'sha256:{digest}\n')
run('apply')
ok(any(p.read_bytes() == (t1 / 'secret.md').read_bytes() for p in (vault / 'artifacts/tasks/demo--05-dup').rglob('secret.md')),
   'explicit hash allow-list releases a withheld artifact')
secret_pointers = generation(t1 / 'secret.md')['chunks']
lazy_copy = archive.Artifact(raw, secret_pointers, len((t1 / 'secret.md').read_bytes()), digest)
assert not isinstance(lazy_copy, bytes) and lazy_copy.materialize() == (t1 / 'secret.md').read_bytes()
try:
    archive.Artifact(raw, secret_pointers, len(lazy_copy), '0' * 64).materialize()
except archive.ArchiveError as error:
    assert error.code == 1 and 'hash or length mismatch' in str(error)
else:
    raise AssertionError('lazy copy must validate the complete content hash')
put(home / 'allowlist.txt', f'sha256:{digest}\nsha256:{archive.sha(token.encode())}\n')
run('apply')
released_note = (vault / 'sessions/alpha.md').read_text()
all_released_vault = [p.read_bytes() for p in vault.rglob('*') if p.is_file() and '.git' not in p.relative_to(vault).parts]
release_guard = archive.Guard(archive.load_policy())
assert release_guard.value(token) == token
release_guard.check(json.dumps({'released': token}).encode(), 'note.json')
# Also exercise an escaped metadata release rather than only a bare token.
escaped_value = token + ' "quoted"\nline'
release_guard.allow.add(archive.sha(escaped_value.encode()))
assert release_guard.value(escaped_value) == escaped_value
release_guard.check(json.dumps({'released': escaped_value}).encode(), 'note.json')
try:
    release_guard.check(other_token.encode(), 'note.md')
except archive.ArchiveError as error:
    assert error.code == 1 and 'secret guard:' in str(error) and other_token not in str(error)
else:
    raise AssertionError('non-listed generated secret must abort')
ok(token in released_note and '[withheld:' in released_note and 'verify: OK' in run('verify') and
   all(other_token.encode() not in data for data in all_released_vault),
   'allow-listed conf value is released and verifies; a different secret stays withheld and backstop rejects it')
put(home / 'allowlist.txt', f'sha256:{digest}\n')
ok('verify: OK' in run('verify') and run('show', '05-dup').startswith('---\n') and
   run('show', 'does-not-exist', code=1).strip() == 'show: unknown or ambiguous id', 'verify and show support known and unknown ids')

# Corruption is isolated in copies owned by the test.
corrupt_vault, corrupt_raw = home / 'corrupt-vault', home / 'corrupt-raw'
shutil.copytree(vault, corrupt_vault)
shutil.copytree(raw, corrupt_raw)
blob = next((corrupt_raw / 'blobs').rglob('*.gz'))
corrupt_bytes = bytearray(blob.read_bytes())
corrupt_bytes[len(corrupt_bytes) // 2] ^= 0x80
put(blob, bytes(corrupt_bytes))
with (corrupt_vault / 'tasks/demo--05-dup.md').open('a') as stream:
    stream.write('\n[[missing-real-note]]\n')
bad_env = dict(os.environ, ORCH_ARCHIVE_VAULT=str(corrupt_vault), ORCH_ARCHIVE_RAW=str(corrupt_raw))
bad = run('verify', code=1, env=bad_env)
ok('unresolved wikilink missing-real-note' in bad and 'raw pointer' in bad,
   'verify reports both corrupt raw blobs and unresolved live links')
shutil.rmtree(corrupt_vault)
shutil.rmtree(corrupt_raw)

# Immutable snapshots and cumulative catalog with no commits.
old_snapshots = set(catalog()['tasks']['demo--06-running']['snapshots'])
put(running / 'new.txt', 'new snapshot\n')
run('apply', '--no-commit')
new_snapshots = set(catalog()['tasks']['demo--06-running']['snapshots'])
shutil.rmtree(running)
run('apply', '--no-commit')
historical = catalog()['tasks']['demo--06-running']
# An older catalog may still contain entries. Upgrade it without changing the
# immutable manifests, including snapshots whose source directory is now gone.
legacy_catalog = catalog()
for snap in legacy_catalog['tasks']['demo--06-running']['snapshots'].values():
    manifest_path = snap['manifest']['path']
    snap['entries'] = json.loads((vault / manifest_path).read_text())['entries']
    for key in ('manifest', 'counts', 'files', 'bytes'):
        snap.pop(key)
put(vault / '_meta/catalog.json', archive.json_bytes(legacy_catalog))
run('apply', '--no-commit')
historical = catalog()['tasks']['demo--06-running']
assert all('entries' not in snap and 'manifest' in snap for snap in historical['snapshots'].values())
retained_report = json.loads(run('--json'))
assert retained_report['vault_bytes'] == sum(p.stat().st_size for p in vault.rglob('*')
    if p.is_file() and '.git' not in p.relative_to(vault).parts)
assert 'verify: OK' in run('verify')
ok(len(new_snapshots) == len(old_snapshots) + 1 and all((vault / f'artifacts/tasks/demo--06-running/{sid}').is_dir() for sid in new_snapshots)
   and not any(loc['present'] for loc in historical['locations'].values()) and
   '"current": false' in (vault / 'tasks/demo--06-running.md').read_text(),
   'snapshots survive updates and deleted source locations without commits')

# Bounded capture seam simulates a writer after stat, without writing in production.
seam = home / 'capture-test.log'
original = b'first\n'
put(seam, original)
def append_after_stat(path):
    with Path(path).open('ab') as stream:
        stream.write(b'late\n')
archive._after_stat = append_after_stat
captured = archive.capture(seam, keep=True)
archive._after_stat = lambda path: None
ok(captured['length'] == len(original) and captured['sha256'] == archive.sha(original) and
   gzip.decompress(captured['gzip']) == original, 'single bounded capture excludes bytes appended after stat')
archive._WRITE_BASES = {vault.resolve(), raw.resolve()}
put(seam, original)
archive._after_stat = append_after_stat
spooled = archive.capture(seam, keep=True, raw_dir=raw)
archive._after_stat = lambda path: None
ok(spooled['length'] == len(original) and spooled['sha256'] == archive.sha(original) and
   gzip.decompress(spooled['gzip'].path.read_bytes()) == original,
   'apply capture streams the same bounded bytes into a private raw-store temporary blob')
spooled['gzip'].close()
seam.unlink()

bad_policy = home / 'bad.conf'
put(bad_policy, 'BOGUS=1\n')
run('plan', code=2, env=dict(os.environ, ORCH_ARCHIVE_POLICY=str(bad_policy)))
bad_policy.unlink()
run('apply', code=2, env=dict(os.environ, ORCH_ARCHIVE_VAULT=str(raw / 'nested')))
run('apply', code=2, env=dict(os.environ, ORCH_ARCHIVE_VAULT=str(p1 / '.orchestra/vault')))
unowned = home / 'unowned'
put(unowned / 'user.txt', 'keep\n')
unowned_before = listing(unowned)
run('apply', code=2, env=dict(os.environ, ORCH_ARCHIVE_VAULT=str(unowned)))
ok(listing(unowned) == unowned_before, 'invalid policy, overlap, source-root and unowned-vault checks precede writes')
shutil.rmtree(unowned)
with (raw / '.lock').open('rb') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    run('apply', code=3)
ok(True, 'apply returns lock-busy exit 3')

for path in (vault / '.obsidian/graph.json', *vault.glob('dashboards/*.base')):
    json.loads(path.read_text())
install = (repo / 'install.sh').read_text()
install_repo = install.split('install_repo() {', 1)[1].split('\n}', 1)[0]
check = install.split('check() {', 1)[1].split('\n}', 1)[0]
links = re.findall(r'^\s*link "\$REPO_DIR/bin/orch-archive"\s+"\$BIN_DIR/orch-archive"\s*$', install_repo, re.M)
ok(len(links) == 1 and '"$BIN_DIR/orch-archive:$REPO_DIR/bin/orch-archive"' in check and
   '[remote ' not in (vault / '.git/config').read_text() and not (home / 'HOOK-RAN').exists() and
   not (home / 'external-git').exists() and not (home / 'external-index').exists(),
   'installer link/check pair, JSON dashboards, no remote and isolated git environment')
ok(stat.S_IMODE(vault.stat().st_mode) == 0o700 and stat.S_IMODE(raw.stat().st_mode) == 0o700 and
   all(stat.S_IMODE(p.stat().st_mode) == 0o600 for base in (vault, raw) for p in base.rglob('*') if p.is_file()),
   'archive directories and files have private permissions')

# Ignore only deliberate test edits; all other files outside vault/raw stay untouched.
deliberate = {str(p.relative_to(home)) for p in (transcript, home / 'allowlist.txt')}
outside_after = listing(home, (vault, raw))
for key in list(tree_before):
    if key == str(running.relative_to(home)) or key.startswith(str(running.relative_to(home)) + '/'):
        del tree_before[key]
for mapping in (tree_before, outside_after):
    for key in list(mapping):
        if key in deliberate:
            del mapping[key]
        elif (home / key).is_dir():
            mapping[key] = mapping[key][2:]
ok(tree_before == outside_after, 'all other writes stay inside configured vault/raw directories')
cache_after = {str(p) for base in (repo / 'lib', repo / 'eval/jev-phase0') for p in base.rglob('__pycache__')}
subprocess.run(['bash', '-n', str(repo / 'tests/test-archive.sh')], check=True)
compile_env = dict(os.environ, PYTHONPYCACHEPREFIX=str(home / 'compile-cache'))
subprocess.run(['python3', '-m', 'py_compile', str(command), str(repo / 'lib/orch_archive.py')], env=compile_env, check=True)
ok(cache_before == cache_after, 'shell/Python syntax checks and no repository bytecode writes')
print(f'PASS: {groups} archive test groups')
PY
