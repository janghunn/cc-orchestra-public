#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
ARCHIVE_TEST_HOME="$(mktemp -d)"
IMAGE_TEST_HOME="$(mktemp -d)"
IMPORT_TEST_HOME="$(mktemp -d)"
# A temporary HOME hides a per-user Pillow install; keep the real user site visible to the image tests.
IMAGE_USER_BASE="$(python3 -c 'import site; print(site.getuserbase())')"
trap 'rm -rf -- "$ARCHIVE_TEST_HOME" "$IMAGE_TEST_HOME" "$IMPORT_TEST_HOME"' EXIT
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
import resource
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

def run(*args, code=0, env=None, preexec_fn=None):
    result = subprocess.run([str(command), *args], env=env, preexec_fn=preexec_fn, text=True, capture_output=True)
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
checkpoint_task = task(p1, '10-checkpoints', 'STATUS: PASS\n')
put(checkpoint_task / 'model.PT', b'C' * 64)
put(checkpoint_task / 'samples.npy', b'N')
put(checkpoint_task / 'small.bin', b'P')
running = task(p1, '06-running', extra='Build on orch/01-base\nConstraints as in orch/02-other\nT18 is a test reference.\n')
task(p1 / '.orchestra/wt/checkout', '07-old', 'STATUS: CLOSED\n')
task(p3, '01-codex-task')
home_task = task(home, '01-home')
(p1 / '.orchestra/08-empty').mkdir()
copy_task = task(p1, '09-copy', '## Status: BLOCKED (tooling policy conflict)\n')
cleanup_container = p1 / '.orchestra/archive/20260101-cleanup-x'
copy_root = cleanup_container / 'copy/.orchestra'
shutil.copytree(copy_task, copy_root / '09-copy')
numeric_container = p1 / '.orchestra/20261001-cleanup'
overlapping_task = task(numeric_container / 'copy', '01-task', 'STATUS: PASS\n')
put(p1 / '.orchestra/REGISTRY.md', '| task | dir | branch | status | owner | risk | date | note |\n'
    '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
    f'| 5 | .orchestra/05-dup | orch/05-dup | PASS | lead | normal | today | 한국어 원문 보존 [[missing-note]] {token} |\n')
put(p2 / '.orchestra/REGISTRY.md', '| dir | status | note |\n| --- | --- | --- |\n'
    '| .orchestra/05-dup | FAIL | 한국어 원문 보존 [[missing-note]] |\n')
put(t2 / 'summary.md', (t2 / 'summary.md').read_text() + 'GATES: [[ -f x ]]\n')
put(t1 / 'secret.md', f'{token}\n')
put(t1 / 'secret-[[historical-name]].md', f'{token}\n')
put(t1 / 'invalid-history.json', 'Verbatim historical text, not JSON.\n')
for artifact_base in (t1, p1 / '.orchestra'):
    put(artifact_base / 'MANIFEST.json', 'Source MANIFEST.json is verbatim text.\n')
    put(artifact_base / 'raw.json', 'Source raw.json is verbatim text.\n')
put(t1 / f'{token}.md', 'A safe body with a secret-shaped filename.\n')
put(t1 / 'payload.bin', b'P' * 64)
secret_payload = t1 / f'{token}.bin'
secret_payload_bytes = b'Unique oversized payload with a secret-shaped filename.'
put(secret_payload, secret_payload_bytes)
put(t1 / 'tiny.bin', b'P')
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
outside_agents = home / 'outside-agents'
put(outside_agents / 'outside.jsonl', '{"message":"outside subagents sentinel"}\n')
linked_agents = claude_project / 'linked-session/subagents'
linked_agents.parent.mkdir()
linked_agents.symlink_to(outside_agents, target_is_directory=True)
outside_session = home / 'outside-session'
put(outside_session / 'subagents/outside.jsonl', '{"message":"outside session sentinel"}\n')
linked_session = claude_project / 'session-link'
linked_session.symlink_to(outside_session, target_is_directory=True)
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
ok(listing(home) == tree_before and not vault.exists() and not raw.exists() and report['logical_tasks'] == 11,
   'default plan writes nothing and discovers nested, empty and Codex-only tasks')
first = run('apply')
task_fields, task_body = archive.frontmatter((vault / 'tasks/demo--05-dup.md').read_text())
manifest_pointer = next(p for p in task_fields['manifests'] if p['snapshot'] ==
                        next(loc['snapshot'] for loc in catalog()['tasks']['demo--05-dup']['locations'].values() if loc['path'] == str(t1)))
manifest_blob = raw / manifest_pointer['blob']
manifest_bytes = gzip.decompress(manifest_blob.read_bytes())
manifest_value = json.loads(manifest_bytes)
secret_payload_digest = archive.sha(secret_payload_bytes)
secret_path_digest = archive.sha(secret_payload.name.encode())
secret_payload_entry = next(e for e in manifest_value['entries'] if e['relpath'] == f'[withheld:{secret_path_digest[:12]}]')
ok(len(secret_payload_bytes) > archive.load_policy()['PAYLOAD_FILE_MAX_BYTES']
   and secret_payload_entry['kind'] == 'payload-over-budget' and secret_payload_entry['reason'] == 'payload-over-budget'
   and 'raw' not in secret_payload_entry and 'sha256' not in secret_payload_entry
   and not (raw / f'blobs/{secret_payload_digest[:2]}/{secret_payload_digest}.gz').exists()
   and not (raw / f'sources/{archive.sha(str(secret_payload.resolve()).encode())[:24]}.json').exists()
   and f'| {secret_path_digest[:12]} | path |' in (vault / '_meta/withheld.md').read_text()
   and all(token.encode() not in p.read_bytes() for p in vault.rglob('*') if p.is_file()),
   'secret-shaped payload filenames keep oversized files manifest-only without raw capture or vault token leakage')
assert archive.sha(manifest_bytes) == manifest_pointer['sha256'] and len(manifest_bytes) == manifest_pointer['length']
assert any(e['relpath'] == 'outside-link' and e['kind'] == 'symlink' for e in manifest_value['entries'])
original_blob = manifest_blob.read_bytes()
put(manifest_blob, b'corrupted gzip')
assert 'invalid' in run('verify', code=1)
put(manifest_blob, original_blob)
original_catalog = (vault / '_meta/catalog.json').read_bytes()
invalid_manifest_catalog = json.loads(original_catalog)
invalid_manifest_bytes = b'not valid JSON\n'
invalid_manifest_digest = archive.sha(invalid_manifest_bytes)
invalid_manifest_blob = f'blobs/{invalid_manifest_digest[:2]}/{invalid_manifest_digest}.gz'
put(raw / invalid_manifest_blob, gzip.compress(invalid_manifest_bytes, mtime=0))
invalid_manifest_catalog['tasks']['demo--05-dup']['snapshots'][manifest_pointer['snapshot']]['manifest'] = dict(
    snapshot=manifest_pointer['snapshot'], blob=invalid_manifest_blob, sha256=invalid_manifest_digest, length=len(invalid_manifest_bytes))
put(vault / '_meta/catalog.json', archive.json_bytes(invalid_manifest_catalog, compact=True))
assert 'invalid' in run('verify', code=1)
put(vault / '_meta/catalog.json', original_catalog)
(raw / invalid_manifest_blob).unlink()
ok(all('files' in p.relative_to(vault).parts for p in vault.rglob('MANIFEST.json'))
   and 'symlink: 1' in task_body and 'manifests' not in report['vault_bytes_breakdown']
   and report['raw']['manifests']['blobs'] > 0 and 'verify: OK' in run('verify'),
   'generated manifests are raw gzip pointers containing every entry; corrupt blobs fail verify')
checkpoint_guard = archive.Guard(archive.load_policy())
checkpoint_discovery = archive.Discovery(archive.load_policy(), checkpoint_guard).run()
real_capture = archive.capture
def reject_checkpoint_capture(path, *args, **kwargs):
    assert Path(path).suffix.lower() not in {'.pt', '.npy'}, f'checkpoint read: {path}'
    return real_capture(path, *args, **kwargs)
archive.capture = reject_checkpoint_capture
try:
    checkpoint_probe = archive.Archive(archive.load_policy(), checkpoint_discovery, checkpoint_guard).build()
finally:
    archive.capture = real_capture
checkpoint_record = catalog()['tasks']['demo--10-checkpoints']
checkpoint_snapshot = next(iter(checkpoint_record['snapshots'].values()))
checkpoint_entries = json.loads(gzip.decompress((raw / checkpoint_snapshot['manifest']['blob']).read_bytes()))['entries']
checkpoint_body = (vault / 'tasks/demo--10-checkpoints.md').read_text().split('## Checkpoint files (not copied)', 1)[1].split('## Per-snapshot values', 1)[0]
assert all(e['kind'] == 'checkpoint' and e['reason'] == 'checkpoint-not-copied' and 'sha256' not in e and 'raw' not in e
           for e in checkpoint_entries if e['relpath'] in ('model.PT', 'samples.npy'))
assert next(e for e in checkpoint_entries if e['relpath'] == 'small.bin')['kind'] == 'raw'
assert all(f"{e['relpath']} | {e['size']} | {archive.utc(e['mtime'])}" in checkpoint_body
           for e in checkpoint_entries if e['kind'] == 'checkpoint')
empty_checkpoint_policy = dict(archive.load_policy(), CHECKPOINT_EXTENSIONS=set())
empty_checkpoint_guard = archive.Guard(empty_checkpoint_policy)
disabled_probe = archive.Archive(empty_checkpoint_policy, checkpoint_discovery, empty_checkpoint_guard)
_, disabled_summary, _ = disabled_probe.scan_files(checkpoint_task, 'demo--10-checkpoints', 'artifacts/tasks/demo--10-checkpoints')
ok(report['checkpoints']['files'] == 2 and report['checkpoints']['bytes'] == 65
   and ['demo--10-checkpoints', 65] in report['checkpoints']['top_tasks']
   and 'sha256' not in checkpoint_body and checkpoint_probe.checkpoints['files'] == 2
   and disabled_summary['counts'].get('checkpoint', 0) == 0 and disabled_summary['counts']['payload-over-budget'] == 3,
   'case-insensitive checkpoints are stat-only, listed without hashes, excluded from PNG budget; empty policy disables')
collision_task = catalog()['tasks']['demo--05-dup']
collision_sid = next(loc['snapshot'] for loc in collision_task['locations'].values() if loc['path'] == str(t1))
collision_dir = vault / f'artifacts/tasks/demo--05-dup/{collision_sid}'
root_dir = vault / f'artifacts/roots/demo/{archive.sha(str(p1 / ".orchestra").encode())[:12]}'
collision_manifest = collision_task['snapshots'][collision_sid]['manifest']
assert json.loads(gzip.decompress((raw / collision_manifest['blob']).read_bytes()))['snapshot'] == collision_sid
root_manifest = next(p for p in catalog()['projects']['demo']['manifests'] if p['root'] == str(p1 / '.orchestra'))
assert json.loads(gzip.decompress((raw / root_manifest['blob']).read_bytes()))['root'] == str(p1 / '.orchestra')
ok(all((destination / 'files' / name).read_bytes() == (source / name).read_bytes()
       for destination, source in ((collision_dir, t1), (root_dir, p1 / '.orchestra'))
       for name in ('MANIFEST.json', 'raw.json')) and 'verify: OK' in run('verify')
   and report['vault_bytes_breakdown']['artifacts'] == sum(p.stat().st_size for p in vault.rglob('*')
       if p.is_file() and re.fullmatch(archive.COPIED_ARTIFACT_PATH, str(p.relative_to(vault)))),
   'task and root MANIFEST.json/raw.json copies live under files, preserving generated metadata and byte accounting')
ok(all(any(item['path'] == str(link) and item['reason'] == 'symlink' for item in report['skipped'])
       for link in (linked_agents, linked_session))
   and not any(pointer['source'].startswith(str(target)) for pointer in catalog()['sessions']['alpha']['raw']
       for target in (outside_agents, outside_session))
   and not any((raw / f'blobs/{archive.sha(path.read_bytes())[:2]}/{archive.sha(path.read_bytes())}.gz').exists()
       for path in (outside_agents / 'outside.jsonl', outside_session / 'subagents/outside.jsonl')),
   'symlinked subagents and session directories are reported and never archived')
generated_bytes = sum(p.stat().st_size for p in vault.rglob('*') if p.is_file() and '.git' not in p.relative_to(vault).parts)
ok(source_hashes() == sources_before and 'commit:' in first and report['vault_bytes'] == generated_bytes
   and sum(report['vault_bytes_breakdown'].values()) == generated_bytes,
   'apply leaves every source unchanged and plan includes all generated metadata bytes')
vault_before, raw_before = hashes(vault, True), hashes(raw)
mtimes_before = listing(vault, (vault / '.git',)), listing(raw)
count_before = git_read('rev-list', '--count', 'HEAD')
lock_inode = (raw / '.lock').stat().st_ino
second = run('apply')
ok(hashes(vault, True) == vault_before and hashes(raw) == raw_before and count_before == git_read('rev-list', '--count', 'HEAD')
   and mtimes_before == (listing(vault, (vault / '.git',)), listing(raw)) and '0 files written' in second and 'commit: none' in second,
   're-apply preserves bytes, mtimes and commit count')
assert (raw / '.lock').stat().st_ino == lock_inode
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
    manifest_data = gzip.decompress((raw / snapshot['manifest']['blob']).read_bytes())
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
copied = cat['tasks']['demo--09-copy']
copy_fields, _ = archive.frontmatter((vault / 'tasks/demo--09-copy.md').read_text())
assert not archive.Discovery.task_dir(cleanup_container)
assert {location['path'] for location in copied['locations'].values()} == {
    str(copy_task), str(copy_root / '09-copy')}
assert any(root['path'] == str(copy_root) and root['kind'] == 'nested' for root in report['roots'])
for label in ('STATUS', 'Status', 'status', 'sTaTuS'):
    parsed, _ = archive.extract({'summary.md': f'## {label}: BLOCKED (tooling policy conflict)\n'}, str(copy_task), [])
    assert parsed['status'] == 'blocked'
lowercase, _ = archive.extract({'summary.md': '## Status: blocked\n'}, str(copy_task), [])
assert lowercase['status'] == 'unknown' and lowercase['status_mentions'] == []
ok(len(copied['snapshots']) == 1 and len(copied['locations']) == 2 and copy_fields['status'] == 'blocked' and
   copied['fields']['status_mentions'][0]['line'] == '## Status: BLOCKED (tooling policy conflict)',
   'numeric cleanup containers reveal nested roots; identical copies dedupe and mixed-case STATUS labels keep uppercase values')
overlapping = cat['tasks']['demo--01-task']
overlapping_fields, _ = archive.frontmatter((vault / 'tasks/demo--01-task.md').read_text())
assert 'demo--20261001-cleanup' not in cat['tasks']
assert any(item['path'] == str(numeric_container) and item['reason'] == 'checkout container'
           for item in report['skipped'])
assert not list(archive.walk(numeric_container, skip_nested=True))
task_walk_paths = [str(path.relative_to(overlapping_task)) for path in archive.walk(overlapping_task, skip_nested=True)]
assert task_walk_paths == ['brief.md', 'plan.md', 'summary.md']
capture_guard = archive.Guard(archive.load_policy())
capture_probe = archive.Archive(archive.load_policy(), archive.Discovery(archive.load_policy(), capture_guard).run(), capture_guard)
captured_paths = []
archive._after_stat = lambda path: captured_paths.append(Path(path))
first_capture = capture_probe.captured(overlapping_task / 'brief.md', keep=True)
capture_probe.capture_cache[str((overlapping_task / 'brief.md').resolve())] = dict(first_capture, data=None, gzip=None)
second_capture = capture_probe.captured(overlapping_task / 'brief.md', keep=True)
archive._after_stat = lambda path: None
assert first_capture is not second_capture and len(captured_paths) == 2
assert second_capture['data'] == (overlapping_task / 'brief.md').read_bytes()
archive._WRITE_BASES = {vault.resolve(), raw.resolve()}
spool_probe = archive.Archive(archive.load_policy(), capture_probe.d, capture_guard, apply=True)
first_spool = spool_probe.captured(overlapping_task / 'brief.md', keep=False)
second_spool = spool_probe.captured(overlapping_task / 'brief.md', keep=True)
try:
    assert second_spool['data'] == second_capture['data']
    assert gzip.decompress(first_spool['gzip'].path.read_bytes()) == second_capture['data']
    assert gzip.decompress(second_spool['gzip'].path.read_bytes()) == second_capture['data']
finally:
    first_spool['gzip'].close()
    second_spool['gzip'].close()
overlapping_snapshot = next(iter(overlapping['snapshots']))
overlapping_artifacts = vault / f'artifacts/tasks/demo--01-task/{overlapping_snapshot}/files'
ok(overlapping_fields['status'] == 'pass' and all((overlapping_artifacts / name).read_bytes() ==
   (overlapping_task / name).read_bytes() for name in ('brief.md', 'plan.md', 'summary.md')),
   'numeric overlapping roots are containers; nested walks exclude them and stripped captures are refreshed')
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
retained_conf = home / 'state/sessions/retained-release.conf'
put(retained_conf, f'LAUNCH_NAME=retained-release\nPRIVATE={token}\n')
run('apply')
retained_conf.unlink()
run('apply')
ok(catalog()['sessions']['retained-release']['fields']['PRIVATE'] == token and
   token in (vault / 'sessions/retained-release.md').read_text() and 'verify: OK' in run('verify'),
   'allow-listed catalog metadata stays released after its source conf is deleted')
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
    manifest_path = snap['manifest']['blob']
    snap['entries'] = json.loads(gzip.decompress((raw / manifest_path).read_bytes()))['entries']
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

# First-time contenders must share the holder's inode, regardless of its contents.
fresh_store = home / 'fresh-lock-store'
fresh_raw = fresh_store / 'raw'
fresh_raw.mkdir(parents=True)
fresh_lock = fresh_raw / '.lock'
fresh_env = dict(os.environ, ORCH_ARCHIVE_RAW=str(fresh_raw), ORCH_ARCHIVE_VAULT=str(fresh_store / 'vault'))
fresh_fd = os.open(fresh_lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
try:
    fcntl.flock(fresh_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.write(fresh_fd, b'held by regression test\n')
    fresh_inode = os.fstat(fresh_fd).st_ino
    run('apply', '--no-commit', code=3, env=fresh_env)
    assert fresh_lock.stat().st_ino == fresh_inode
finally:
    os.close(fresh_fd)
run('apply', '--no-commit', env=fresh_env)
run('apply', '--no-commit', env=fresh_env)
ok(fresh_lock.stat().st_ino == fresh_inode and fresh_lock.read_bytes() == b'held by regression test\n',
   'first-time lock contenders return busy without replacement; lock inode stays stable across applies')
shutil.rmtree(fresh_store)

pressure_project = home / 'claude-projects/many-unlinked'
for number in range(200):
    put(pressure_project / f'{number:03}.jsonl', '{"cwd":"/not/cc-orch"}\n')
def limit_descriptors():
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (64 if hard == resource.RLIM_INFINITY else min(64, hard), hard))
pressure_report = json.loads(run('--json', preexec_fn=limit_descriptors))
ok(pressure_report['transcripts']['unlinked_projects'] == report['transcripts']['unlinked_projects'] + 1 and
   any(item['path'] == str(pressure_project) and item['reason'] == 'not linked to a cc-orch base'
       for item in pressure_report['skipped']),
   '200 unlinked transcripts under a 64-fd limit are reported without descriptor exhaustion')
shutil.rmtree(pressure_project)

truncation_projects = home / 'truncation-projects'
truncated = truncation_projects / claude_project.name / 'truncated.jsonl'
put(truncated, '{"message":"before truncation"}\n')
truncation_env = dict(os.environ, ORCH_ARCHIVE_CLAUDE_PROJECTS=str(truncation_projects))
run('apply', '--no-commit', env=truncation_env)
assert any(p['source'] == str(truncated) for p in catalog()['sessions']['alpha']['raw'])
put(truncated, b'')
run('apply', '--no-commit', env=truncation_env)
truncation_report = json.loads(run('--json', env=truncation_env))
session_index = json.loads((vault / 'artifacts/sessions/alpha/raw.json').read_text())
ok(not any(p['source'] == str(truncated) for p in session_index)
   and generation(truncated)['size_seen'] == 0 and reconstruct(generation(truncated)) == b''
   and truncation_report['transcripts']['files'] == 1 and truncation_report['transcripts']['bytes'] == 0
   and 'verify: OK' in run('verify'),
   'zero-byte recapture replaces old source pointers and reports zero transcript bytes')
shutil.rmtree(truncation_projects)
run('apply', '--no-commit')

vanished_source = home / 'vanished-seam.jsonl'
put(vanished_source, '{"unique":"vanished before capture"}\n')
vanished_guard = archive.Guard(archive.load_policy())
vanished_store = archive.RawStore(archive.load_policy(), True, vanished_guard)
raw_before_vanish = hashes(raw)
archive._after_stat = lambda path: Path(path).unlink()
try:
    vanished_pointers = vanished_store.archive(vanished_source, 'rollouts')
finally:
    archive._after_stat = lambda path: None
ok(vanished_pointers is None and vanished_guard.source_errors.report(1)['count'] == 1
   and vanished_guard.source_errors.report(1)['items'][0]['reason'] == 'vanished'
   and vanished_guard.source_errors.report(1)['items'][0]['errno'] == 2
   and vanished_store.new_blobs == 0 and hashes(raw) == raw_before_vanish,
   'a source unlinked after stat is reported as vanished without partial raw data or pointers')

error_fixture = home / 'source-errors-fixture'
error_base = error_fixture / 'project'
error_task = task(error_base, '01-errors', 'STATUS: PASS\n')
error_thread = '44444444-4444-4444-4444-444444444444'
put(error_task / '.codex-session', f'implement={error_thread}|gpt-6.1-sol|high\n')
error_rollout = error_fixture / f'codex/sessions/rollout-{error_thread}.jsonl'
put(error_rollout, '{"message":"restorable rollout"}\n')
error_transcript = error_fixture / 'claude-projects' / re.sub(r'[^A-Za-z0-9]', '-', str(error_base)) / 'unreadable.jsonl'
put(error_transcript, '{"message":"restorable unreadable transcript"}\n')
put(error_fixture / 'state/sessions/errors.conf', f'LAUNCH_NAME=errors\nPROJECT_NAME=errors\nREPO={error_base}\n')
blocked_sources = [error_transcript, error_task / 'blocked.md', error_fixture / 'state/sessions/zz-blocked.conf',
                   error_fixture / 'state/projects/zz-blocked-record', error_fixture / 'state/codex-projects/zz-blocked-native/project.json']
put(blocked_sources[1], 'restorable task artifact\n')
put(blocked_sources[2], f'LAUNCH_NAME=zz-blocked\nPROJECT_NAME=errors\nREPO={error_base}\n')
put(blocked_sources[3], f'dir={error_base}\n')
put(blocked_sources[4], json.dumps({'directory': str(error_base)}))
error_env = dict(os.environ, ORCH_ARCHIVE_VAULT=str(error_fixture / 'vault'), ORCH_ARCHIVE_RAW=str(error_fixture / 'raw'),
    ORCH_ARCHIVE_STATE_DIRS=str(error_fixture / 'state'), ORCH_ARCHIVE_EXTRA_BASES=str(error_base),
    ORCH_ARCHIVE_CLAUDE_PROJECTS=str(error_fixture / 'claude-projects'), ORCH_ARCHIVE_CODEX_HOME=str(error_fixture / 'codex'))
if os.geteuid() != 0:
    for blocked in blocked_sources:
        blocked.chmod(0)
else:
    print('SKIP: chmod 000 unreadable sub-case (running as root)')
error_code = 'import sys; from pathlib import Path; sys.path.insert(0, ' + repr(str(repo / 'lib')) + '); import orch_archive as a; ' + \
    'a._after_stat = lambda p: Path(p).unlink() if Path(p) == Path(' + repr(str(error_rollout)) + ') else None; ' + \
    'sys.exit(a.main(["apply", "--json"]))'
error_process = subprocess.run(['python3', '-B', '-c', error_code], env=error_env, text=True, capture_output=True)
assert error_process.returncode == 4, (error_process.returncode, error_process.stdout, error_process.stderr)
error_report, _ = json.JSONDecoder().raw_decode(error_process.stdout)
error_catalog = json.loads((error_fixture / 'vault/_meta/catalog.json').read_text())
expected_error_count = len(blocked_sources) + 1 if os.geteuid() != 0 else 1
assert error_report['source_errors']['count'] == expected_error_count
assert any(item['path'] == str(error_rollout) and item['reason'] == 'vanished' and item['errno'] == 2
           for item in error_report['source_errors']['items'])
assert all(p['source'] not in (str(error_rollout), str(error_transcript)) for p in error_catalog['tasks']['errors--01-errors']['raw'])
assert not (error_fixture / f'raw/sources/{archive.sha(str(error_rollout).encode())[:24]}.json').exists()
if os.geteuid() != 0:
    assert all(any(item['path'] == str(blocked) and item['reason'] == 'unreadable' and item['errno'] == 13
                   for item in error_report['source_errors']['items']) for blocked in blocked_sources)
    plan_errors = json.loads(run('--json', '--top', '1', code=4, env=error_env))
    assert plan_errors['source_errors']['count'] == len(blocked_sources) and len(plan_errors['source_errors']['items']) == 1
    assert json.loads(run('--json', '--top', '0', code=4, env=error_env))['source_errors'] == {'count': len(blocked_sources), 'items': []}
for blocked in blocked_sources:
    blocked.chmod(0o600)
put(error_rollout, '{"message":"restorable rollout"}\n')
restored_report = json.loads(run('--json', env=error_env))
restored_apply = run('apply', env=error_env)
restored_catalog = json.loads((error_fixture / 'vault/_meta/catalog.json').read_text())
ok('commit: none' not in error_process.stdout and error_report['skipped_counts']['vanished'] == 1
   and restored_report['source_errors']['count'] == 0 and 'commit:' in restored_apply
   and any(p['source'] == str(error_rollout) for p in restored_catalog['tasks']['errors--01-errors']['raw'])
   and any(p['source'] == str(error_transcript) for p in restored_catalog['sessions']['errors']['raw'])
   and 'verify: OK' in run('verify', env=error_env),
   'CLI source errors exit 4 while apply commits; restored sources archive normally with exit 0')
shutil.rmtree(error_fixture)

tail_fixture = home / 'manifest-tail-fixture'
tail_base = tail_fixture / 'project'
tail_task = task(tail_base, '01-tail', 'STATUS: PASS\n')
tail_log = tail_task / 'history.log'
put(tail_log, b'task complete line\nunique old task tail')
put(tail_base / '.orchestra/root.log', b'unique root complete line\nroot tail')
tail_vault, tail_raw = tail_fixture / 'vault', tail_fixture / 'raw'
tail_env = dict(os.environ, ORCH_ARCHIVE_VAULT=str(tail_vault), ORCH_ARCHIVE_RAW=str(tail_raw),
    ORCH_ARCHIVE_STATE_DIRS='', ORCH_ARCHIVE_EXTRA_BASES=str(tail_base),
    ORCH_ARCHIVE_CLAUDE_PROJECTS=str(tail_fixture / 'claude'), ORCH_ARCHIVE_CODEX_HOME=str(tail_fixture / 'codex'))
run('apply', '--no-commit', env=tail_env)
tail_catalog = json.loads((tail_vault / '_meta/catalog.json').read_text())
old_snapshot = next(iter(tail_catalog['tasks']['project--01-tail']['snapshots'].values()))
old_manifest = old_snapshot['manifest']
old_entries = json.loads(gzip.decompress((tail_raw / old_manifest['blob']).read_bytes()))['entries']
old_tail = next(e for e in old_entries if e['relpath'] == 'history.log')['raw'][-1]
assert old_tail['offset'] == len(b'task complete line\n')
with tail_log.open('ab') as stream:
    stream.write(b' extended tail')
run('apply', '--no-commit', env=tail_env)
current_source = json.loads((tail_raw / f'sources/{archive.sha(str(tail_log.resolve()).encode())[:24]}.json').read_text())
assert not any(p.get('blob') == old_tail['blob'] for p in archive.pointer_values(current_source))
assert 'verify: OK' in run('verify', env=tail_env)
damaged_raw = tail_fixture / 'damaged-raw'
shutil.copytree(tail_raw, damaged_raw)
put(damaged_raw / old_tail['blob'], b'corrupt old tail gzip')
tail_failure = run('verify', code=1, env=dict(tail_env, ORCH_ARCHIVE_RAW=str(damaged_raw)))
assert 'manifest ' + old_manifest['blob'] in tail_failure
# Project-root manifests must follow their embedded chunk pointers too.
put(damaged_raw / old_tail['blob'], (tail_raw / old_tail['blob']).read_bytes())
root_pointer = tail_catalog['projects']['project']['manifests'][0]
root_entries = json.loads(gzip.decompress((tail_raw / root_pointer['blob']).read_bytes()))['entries']
root_chunk = next(e for e in root_entries if e['relpath'] == 'root.log')['raw'][0]
put(damaged_raw / root_chunk['blob'], b'corrupt root chunk gzip')
root_failure = run('verify', code=1, env=dict(tail_env, ORCH_ARCHIVE_RAW=str(damaged_raw)))
ok('manifest ' + root_pointer['blob'] in root_failure and 'verify: OK' in run('verify', env=tail_env),
   'verify checks immutable task-manifest tails and project-manifest chunks, naming the manifest on corruption')
shutil.rmtree(tail_fixture)

if os.geteuid() != 0:
    inaccessible_dir = home / 'codex/sessions/listable-not-traversable'
    inaccessible_rollout = inaccessible_dir / 'rollout-55555555-5555-5555-5555-555555555555.jsonl'
    put(inaccessible_rollout, '{"message":"blocked traversal"}\n')
    inaccessible_mode = stat.S_IMODE(inaccessible_dir.stat().st_mode)
    try:
        inaccessible_dir.chmod(0o600)
        inaccessible_report = json.loads(run('--json', code=4))
        assert any(item['path'] == str(inaccessible_rollout) and item['reason'] == 'unreadable' and item['errno'] == 13
                   for item in inaccessible_report['source_errors']['items'])
        ok(inaccessible_report['source_errors']['count'] == 1 and inaccessible_report['logical_tasks'] > 0,
           'a listable rollout directory without traversal permission completes plan with source-error exit 4')
    finally:
        inaccessible_dir.chmod(inaccessible_mode)
        shutil.rmtree(inaccessible_dir)
else:
    print('SKIP: mode 0o600 rollout-directory sub-case (running as root)')
    ok(True, 'rollout traversal regression skipped for root')

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

# Thumbnail tests: their own temporary home, vaults and policy; tests needing Pillow or ffmpeg print
# "skip - ... (SKIPPED: ...)" without counting as a pass, and the final line lists every skip by name.
env HOME="$IMAGE_TEST_HOME" CODEX_HOME="$IMAGE_TEST_HOME/codex" PYTHONUSERBASE="$IMAGE_USER_BASE" \
    ORCH_ARCHIVE_VAULT="$IMAGE_TEST_HOME/unused-vault" ORCH_ARCHIVE_RAW="$IMAGE_TEST_HOME/unused-raw" python3 - <<'PY'
import sys
sys.dont_write_bytecode = True
import gzip
import hashlib
import importlib.util
import contextlib
import gc
import io
import json
import os
from pathlib import Path
import random
import re
import shutil
import stat
import struct
import subprocess
import zlib

repo = Path(os.environ['ARCHIVE_REPO_DIR'])
home = Path(os.environ['HOME'])
command = repo / 'bin/orch-archive'
sys.path.insert(0, str(repo / 'lib'))
import orch_archive as archive
groups, skipped = 0, []
HAVE_PIL = importlib.util.find_spec('PIL') is not None
HAVE_FFMPEG = shutil.which('ffmpeg') is not None
HAVE_ANY = HAVE_PIL or HAVE_FFMPEG
TID = 'proj--01-task'

def ok(condition, description):
    global groups
    groups += 1
    if not condition:
        print(f'fail {groups} - {description}', flush=True)
        raise AssertionError(description)
    print(f'ok {groups} - {description}', flush=True)

def skip(description, why):
    skipped.append(description)
    print(f'skip - {description} (SKIPPED: {why})', flush=True)

def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())

def sha(data):
    return hashlib.sha256(data).hexdigest()

# --- stdlib PNG writer and JPEG reader -------------------------------------------------------------
SIGNATURE = b'\x89PNG\r\n\x1a\n'

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

def png(width, height, color, depth, rows, plte=None, trns=None, extra=b'', idat=None):
    out = SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, 0)) + extra
    if plte:
        out += chunk(b'PLTE', plte)
    if trns:
        out += chunk(b'tRNS', trns)
    if idat is None:
        idat = zlib.compress(b''.join(b'\x00' + row for row in rows), 6)
    return out + chunk(b'IDAT', idat) + chunk(b'IEND', b'')

def rgb_png():
    rng = random.Random(42)
    rows = [bytes((x // 3 * 2 + y + rng.randrange(6)) % 256 for x in range(700 * 3)) for y in range(300)]
    return png(700, 300, 2, 8, rows, extra=chunk(b'tEXt', b'Comment\x00thumbnail-metadata-marker'))

def rgba_png():
    clear, red = bytes((0, 0, 0, 0)), bytes((200, 30, 30, 255))
    return png(300, 200, 6, 8, [clear * 150 + red * 150] * 200)

def paletted_png():
    palette = bytes((0, 0, 0, 220, 20, 20, 20, 200, 20, 20, 20, 200))
    return png(120, 80, 3, 8, [bytes([0] * 60 + [1] * 60)] * 80, plte=palette, trns=b'\x00')

def gray16_png():
    return png(100, 60, 0, 16, [b''.join(struct.pack('>H', x * 655) for x in range(100))] * 60)

def bomb_png():
    return png(20000, 20000, 2, 8, None, idat=zlib.compress(b'\x00\x01\x02'))

def solid_png(width, height):
    return png(width, height, 2, 8, [bytes((x * 7 + 40) % 256 for x in range(width * 3))] * height)

def trns_gray16_png():
    # Samples equal to the tRNS key (0) are transparent; 100 is a different, almost black sample.
    row = struct.pack('>H', 0) * 20 + struct.pack('>H', 100) * 5 + struct.pack('>H', 40000) * 15
    return png(40, 20, 0, 16, [row] * 20, trns=struct.pack('>H', 0))

def trns_rgb16_png():
    key = struct.pack('>HHH', 1000, 2000, 3000)
    return png(40, 20, 2, 16, [key * 20 + struct.pack('>HHH', 60000, 10000, 10000) * 20] * 20, trns=key)

def jpeg_size(data):
    assert data[:2] == b'\xff\xd8', 'not a JPEG'
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC2):
            height, width = struct.unpack('>HH', data[i + 5:i + 9])
            return width, height
        if marker == 0xFF:
            i += 1
        elif marker == 0x01 or 0xD0 <= marker <= 0xD9:
            i += 2
        else:
            i += 2 + struct.unpack('>H', data[i + 2:i + 4])[0]
    raise AssertionError('no SOF marker')

def pixel(data, xy):
    from PIL import Image
    with Image.open(io.BytesIO(data)) as image:
        return image.convert('RGB').getpixel(xy)

FILES = {'rgb.png': rgb_png(), 'nested/alpha.png': rgba_png(), 'paletted.png': paletted_png(), 'gray16.png': gray16_png()}

# --- scenarios ----------------------------------------------------------------------------------------
checked_applies = 0

class Scn:
    def __init__(self, name, files=None, conf='', state=False):
        self.root = home / name
        self.state = self.root / 'state' if state else None
        self.base = self.root / 'proj'
        self.task = self.base / '.orchestra/01-task'
        self.vault, self.raw, self.conf = self.root / 'vault', self.root / 'raw', self.root / 'archive.conf'
        put(self.task / 'brief.md', '# Image task\nRISK: normal\n')
        put(self.task / 'plan.md', '# Plan\n')
        for rel, data in (files or {}).items():
            put(self.task / rel, data)
        self.set_conf(conf)

    def set_conf(self, text):
        put(self.conf, 'PAYLOAD_FILE_MAX_BYTES=16777216\nPAYLOAD_TASK_MAX_BYTES=268435456\n' + text)

    def env(self, **extra):
        env = dict(os.environ, ORCH_ARCHIVE_VAULT=str(self.vault), ORCH_ARCHIVE_RAW=str(self.raw),
                   ORCH_ARCHIVE_ALLOWLIST=str(self.root / 'allow.txt'), ORCH_ARCHIVE_STATE_DIRS=str(self.state) if self.state else '',
                   ORCH_ARCHIVE_CLAUDE_PROJECTS=str(self.root / 'claude'), ORCH_ARCHIVE_CODEX_HOME=str(self.root / 'codex'),
                   CODEX_HOME=str(self.root / 'codex'), ORCH_ARCHIVE_EXTRA_BASES=str(self.base),
                   ORCH_ARCHIVE_POLICY=str(self.conf))
        env.update(extra)
        return env

    def sources(self):
        return {str(p): (sha(p.read_bytes()), p.lstat().st_mtime_ns) for p in sorted(self.base.rglob('*')) if p.is_file()}

    def run(self, *args, code=0, env=None, stderr=False):
        global checked_applies
        before = self.sources()
        result = subprocess.run([str(command), *args], env=env or self.env(), text=True, capture_output=True)
        if result.returncode != code:
            print(result.stdout)
            print(result.stderr)
            raise AssertionError(f'{args}: expected {code}, got {result.returncode}')
        if self.sources() != before:
            raise AssertionError(f'{args}: a source file changed')
        checked_applies += 1
        return (result.stdout, result.stderr) if stderr else result.stdout

    def report(self, *args, code=0, env=None):
        out = self.run(*args, code=code, env=env)
        value, _ = json.JSONDecoder().raw_decode(out[out.index('{'):])
        return value

    def catalog(self):
        return json.loads((self.vault / '_meta/catalog.json').read_text())

    def task_record(self):
        return self.catalog()['tasks'][TID]

    def thumbs(self):
        return sorted((self.vault / f'artifacts/tasks/{TID}/thumbs').glob('*.jpg')) if (self.vault / 'artifacts').exists() else []

    def commits(self):
        return int(subprocess.check_output(['git', '-C', str(self.vault), 'rev-list', '--count', 'HEAD'], env=archive.git_env(), text=True))

    def hashes(self, base, git=False):
        return {str(p.relative_to(base)): sha(p.read_bytes()) for p in sorted(base.rglob('*'))
                if p.is_file() and not p.is_symlink() and (git or '.git' not in p.relative_to(base).parts)}

    def snapshot_rows(self):
        return [row for snap in self.task_record()['snapshots'].values() for row in snap.get('images', [])]

    def inprocess(self, apply=False, **overrides):
        """Build an Archive in this process with the scenario's environment (plan mode that may encode, or apply mode)."""
        saved = {k: os.environ.get(k) for k in self.env()}
        os.environ.update(self.env())
        try:
            policy = dict(archive.load_policy(), **overrides)
            guard = archive.Guard(policy)
            if apply:
                archive._WRITE_BASES = {self.vault.resolve(), self.raw.resolve()}
            return archive.Archive(policy, archive.Discovery(policy, guard).run(), guard, apply=apply, measure=not apply)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

def files_matching(bases, needles):
    """Every file under the bases whose raw, gunzipped or zlib-inflated bytes contain a needle."""
    found = []
    for base in bases:
        for path in sorted(base.rglob('*')):
            if not path.is_file() or path.is_symlink():
                continue
            blobs = [path.read_bytes()]
            for inflate in (gzip.decompress, zlib.decompress):
                try:
                    blobs.append(inflate(blobs[0]))
                except Exception:
                    pass
            if any(needle in blob for blob in blobs for needle in needles):
                found.append(path)
    return found

def idat_payload(data):
    pos = 8
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        if kind == b'IDAT':
            return data[pos + 8:pos + 8 + length]
        pos += 12 + length

# (a) any encoder: PNG -> JPEG within caps; PNG bytes nowhere in vault/raw ---------------------------------
if HAVE_ANY:
    main = Scn('main', FILES)
    out = main.report('apply', '--json')
    record = main.task_record()
    thumbs = main.thumbs()
    sizes = [jpeg_size(path.read_bytes()) for path in thumbs]
    pngs = [(main.task / rel).read_bytes() for rel in FILES]
    needles = pngs + [idat_payload(data) for data in pngs]
    leaks = files_matching([main.vault, main.raw], needles)
    ok(len(thumbs) == 4 and all(max(w, h) <= 512 for w, h in sizes) and all(p.stat().st_size <= 65536 for p in thumbs)
       and any(w == 512 and h in (218, 219) for w, h in sizes) and out['images']['thumbnails'] == 4
       and out['images']['encoder']['id'] in ('pillow', 'ffmpeg') and out['images']['files'] == 4
       and out['images']['source_bytes'] == sum(map(len, pngs)) and not out['images']['metadata_only']
       and not leaks and not any((main.raw / f'blobs/{sha(data)[:2]}/{sha(data)}.gz').exists() for data in pngs)
       and not any((main.raw / f'sources/{sha(str((main.task / rel).resolve()).encode())[:24]}.json').exists() for rel in FILES)
       and b'thumbnail-metadata-marker' not in b''.join(p.read_bytes() for p in thumbs)
       and 'verify: OK' in main.run('verify'),
       'PNGs become JPEG thumbnails within the edge and byte caps; PNG bytes never reach the vault or raw store')
else:
    skip('PNG to JPEG thumbnails and no PNG bytes in vault/raw', 'neither Pillow nor ffmpeg is available')
    main = None

# (b) Pillow: idempotent re-apply, no decode on reuse, parameter change, encoder switch ---------------------
if HAVE_PIL:
    pil = Scn('pillow', FILES, 'THUMB_ENCODER=pillow\n')
    first = pil.report('apply', '--json')
    vault_before, raw_before, commits = pil.hashes(pil.vault), pil.hashes(pil.raw), pil.commits()
    mtimes = {str(p): p.stat().st_mtime_ns for p in sorted(pil.vault.rglob('*')) if p.is_file() and '.git' not in p.parts}
    second_out = pil.run('apply')
    ok(pil.hashes(pil.vault) == vault_before and pil.hashes(pil.raw) == raw_before and pil.commits() == commits
       and '0 files written' in second_out and 'commit: none' in second_out and 'images: 0 encoded, 4 reused' in second_out
       and 'images: 4 encoded, 0 reused' in pil.run('apply', '--no-commit', env=pil.env(ORCH_ARCHIVE_VAULT=str(pil.root / 'fresh-vault'),
           ORCH_ARCHIVE_RAW=str(pil.root / 'fresh-raw'))) and mtimes == {str(p): p.stat().st_mtime_ns
           for p in sorted(pil.vault.rglob('*')) if p.is_file() and '.git' not in p.parts},
       'Pillow re-apply is byte-identical with no new commit and reuses all thumbnails; a fresh vault encodes them')
    real_encode = archive.ImageEncoder.encode
    calls = []
    def forbidden(self, *args, **kwargs):
        calls.append(args)
        raise AssertionError('decoded an unchanged image')
    archive.ImageEncoder.encode = forbidden
    try:
        probe = pil.inprocess()
        probe.build()
    finally:
        archive.ImageEncoder.encode = real_encode
    ok(not calls and probe.images['reused'] == 4 and probe.images['encoded'] == 0 and probe.images['thumbnails'] == 4,
       'unchanged sources, encoder and parameters are reused without decoding (encode() is never called)')
    healed = pil.thumbs()[0]
    healed_bytes = healed.read_bytes()
    damaged = bytearray(healed_bytes)
    damaged[len(damaged) // 2] ^= 0x01
    healed.write_bytes(bytes(damaged))
    healed_out = pil.run('apply')
    ok(healed.read_bytes() == healed_bytes and 'images: 1 encoded, 3 reused' in healed_out and pil.commits() == commits
       and 'verify: OK' in pil.run('verify'),
       'a damaged thumbnail in the vault is never reused: apply re-encodes exactly that one and restores the committed bytes')
    before_thumbs = {p.name: sha(p.read_bytes()) for p in pil.thumbs()}
    pil.set_conf('THUMB_ENCODER=pillow\nTHUMB_QUALITY=60\n')
    pending = pil.report('plan', '--json')
    reencode = pil.run('apply')
    after_thumbs = {p.name: sha(p.read_bytes()) for p in pil.thumbs()}
    new_records = pil.task_record()['thumbnails'].values()
    ok(pending['images']['pending'] == 4 and pending['images']['thumbnails'] == 0 and 'images: 4 encoded, 0 reused' in reencode
       and pil.commits() == commits + 1 and set(after_thumbs) == set(before_thumbs)
       and all(after_thumbs[name] != before_thumbs[name] for name in after_thumbs)
       and all(r['params']['quality'] == 60 and r['used']['quality'] == 60 for r in new_records) and 'verify: OK' in pil.run('verify'),
       'a changed THUMB_QUALITY is pending in plan, re-encodes in apply, overwrites each thumbnail in place and commits')
    pil.set_conf('THUMB_ENCODER=pillow\nTHUMB_QUALITY=60\nTHUMB_EMBED_MAX=2\n')
    embed_out = pil.run('apply')
    note = (pil.vault / f'tasks/{TID}.md').read_text()
    embeds = re.findall(r'^!\[\[([^]\n]+)\]\]$', note, re.M)
    ok('images: 0 encoded, 4 reused' in embed_out and len(embeds) == 2 and len(set(embeds)) == 2
       and all((pil.vault / target).is_file() for target in embeds) and len(note.split('## Images', 1)[1].split('## Per-snapshot', 1)[0].split('"thumbnail_path"')) == 5
       and 'verify: OK' in pil.run('verify'),
       'THUMB_EMBED_MAX=2 embeds exactly two thumbnails, every embed resolves, all four stay listed, and verify passes')
    if HAVE_FFMPEG:
        pil.set_conf('THUMB_ENCODER=ffmpeg\nTHUMB_QUALITY=60\nTHUMB_EMBED_MAX=2\n')
        switch_out = pil.run('apply')
        ok('images: 4 encoded, 0 reused' in switch_out and all(r['encoder']['id'] == 'ffmpeg' and r['encoder']['version']
               for r in pil.task_record()['thumbnails'].values()) and 'verify: OK' in pil.run('verify'),
           'switching THUMB_ENCODER from pillow to ffmpeg re-encodes and records the new encoder id and version')
    else:
        skip('switching THUMB_ENCODER pillow -> ffmpeg re-encodes', 'ffmpeg is not available')
else:
    for name in ('Pillow re-apply idempotence', 'no decode on reuse', 'parameter change re-encodes and embed limit',
                 'encoder switch pillow -> ffmpeg'):
        skip(name, 'Pillow is not available')

# (b2) byte-cap fallback ladder ---------------------------------------------------------------------------
if HAVE_PIL:
    probe_quality = Scn('cap-probe', {'rgb.png': FILES['rgb.png']}, 'THUMB_ENCODER=pillow\n')
    probe_quality.report('apply', '--json')
    q70_bytes = probe_quality.thumbs()[0].stat().st_size
    cap = Scn('cap', {'rgb.png': FILES['rgb.png']}, f'THUMB_ENCODER=pillow\nTHUMB_QUALITY=95\nTHUMB_MAX_BYTES={q70_bytes}\n')
    cap.report('apply', '--json')
    used = next(iter(cap.task_record()['thumbnails'].values()))
    impossible = Scn('cap-impossible', {'rgb.png': FILES['rgb.png']}, 'THUMB_ENCODER=pillow\nTHUMB_MAX_BYTES=100\n')
    impossible_report = impossible.report('apply', '--json')
    ok(used['used'] == {'max_edge': 512, 'quality': 50} and used['bytes'] <= q70_bytes and used['params']['quality'] == 95
       and cap.thumbs()[0].stat().st_size == used['bytes'],
       'a thumbnail over THUMB_MAX_BYTES falls back to lower quality and records the parameters actually used')
    ok(impossible_report['images']['metadata_only'] == {'thumbnail-over-cap': 1} and not impossible.thumbs()
       and impossible.snapshot_rows()[0]['reason'] == 'thumbnail-over-cap' and 'verify: OK' in impossible.run('verify'),
       'when no fallback fits THUMB_MAX_BYTES the image is metadata-only with reason thumbnail-over-cap')
else:
    skip('byte-cap fallback ladder', 'Pillow is not available')

# (c) alpha, paletted and 16-bit PNGs ---------------------------------------------------------------------
def pixel_checks(scn):
    thumbs = {rec['source']['sha256']: (scn.vault / rec['path']).read_bytes() for rec in scn.task_record()['thumbnails'].values()}
    alpha, paletted, gray = (thumbs[sha(FILES[name])] for name in ('nested/alpha.png', 'paletted.png', 'gray16.png'))
    transparent, opaque = pixel(alpha, (10, 100)), pixel(alpha, (250, 100))
    pal_clear, pal_red = pixel(paletted, (10, 40)), pixel(paletted, (110, 40))
    gray_dark, gray_bright = pixel(gray, (3, 30)), pixel(gray, (96, 30))
    return (min(transparent) >= 240 and opaque[0] > 150 and opaque[1] < 100
            and min(pal_clear) >= 240 and pal_red[0] > 150 and pal_red[1] < 100
            and max(gray_dark) < 60 and min(gray_bright) > 190)

for encoder, available in (('pillow', HAVE_PIL), ('ffmpeg', HAVE_FFMPEG)):
    description = f'{encoder}: alpha composites onto white; paletted+tRNS and 16-bit grayscale PNGs get thumbnails; re-apply is a no-op'
    if not available:
        skip(description, f'{encoder} is not available')
        continue
    scn = Scn('mode-' + encoder, FILES, f'THUMB_ENCODER={encoder}\n')
    scn.report('apply', '--json')
    records = list(scn.task_record()['thumbnails'].values())
    again = scn.run('apply')
    # Pixel values need Pillow to decode the JPEG; without it only the structure is checked.
    decoded = pixel_checks(scn) if HAVE_PIL else True
    ok(len(records) == 4 and all(r['encoder']['id'] == encoder for r in records) and decoded
       and '0 files written' in again and 'commit: none' in again and 'images: 0 encoded, 4 reused' in again
       and all(jpeg_size((scn.vault / r['path']).read_bytes()) == (r['width'], r['height']) for r in records),
       description + ('' if HAVE_PIL else ' (structure only; Pillow is needed to decode pixels)'))

# (d) invalid PNGs are source errors, the run continues ----------------------------------------------------
truncated_png = rgb_png()[:len(rgb_png()) // 3]
bad = Scn('invalid', {'truncated.png': truncated_png, 'notpng.png': 'this is plain text, not a PNG\n',
                      'short.png': SIGNATURE + b'xx', 'note.md': '# a note\n'})
bad_plan = bad.report('plan', '--json', code=4)
bad_report = bad.report('apply', '--json', code=4)
items = {Path(i['path']).name: i for i in bad_report['source_errors']['items']}
manifest_blob = bad.task_record()['snapshots']
entries = json.loads(gzip.decompress((bad.raw / next(iter(manifest_blob.values()))['manifest']['blob']).read_bytes()))['entries']
kinds = {e['relpath']: (e['kind'], e.get('reason')) for e in entries}
ok(bad_report['source_errors']['count'] == 3 and bad_plan['source_errors']['count'] == 3
   and items['truncated.png']['reason'] == 'invalid-image' and items['truncated.png']['detail'] == 'truncated'
   and items['notpng.png']['detail'] == 'not-png' and items['short.png']['detail'] == 'bad-header'
   and kinds['truncated.png'] == ('invalid-image', 'truncated') and kinds['notpng.png'] == ('invalid-image', 'not-png')
   and bad_report['images']['invalid'] == 3 and not bad.thumbs() and (bad.vault / f'tasks/{TID}.md').is_file()
   and any(p.read_bytes() == b'# a note\n' for p in (bad.vault / 'artifacts').rglob('note.md'))
   and 'verify: OK' in bad.run('verify'),
   'truncated, signature-only and non-PNG files named .png are invalid-image source errors (exit 4); the rest still archives')

crc_png = bytearray(rgb_png())
crc_png[len(crc_png) // 2] ^= 0xFF
header_png = bytearray(gray16_png())
header_png[8 + 8 + 8] = 7  # bit depth 7 is not a legal PNG depth (IHDR CRC is rewritten below)
header_png[29:33] = struct.pack('>I', zlib.crc32(bytes(header_png[12:29])) & 0xFFFFFFFF)
strict = Scn('strict', {'badcrc.png': bytes(crc_png), 'baddepth.png': bytes(header_png),
                        'big-trailer.png': FILES['paletted.png'] + b'trailing bytes after IEND'})
strict_report = strict.report('apply', '--json', code=4)
strict_items = {Path(i['path']).name: i['detail'] for i in strict_report['source_errors']['items']}
trailer_row = next(r for r in strict.snapshot_rows() if r['relpath'] == 'big-trailer.png')
ok(strict_items == {'badcrc.png': 'bad-chunk-crc', 'baddepth.png': 'bad-header'}
   and trailer_row['source_sha256'] == sha(FILES['paletted.png'] + b'trailing bytes after IEND'),
   'structural check rejects bad chunk CRCs and illegal IHDR fields; trailing bytes are still hashed')

if HAVE_PIL:
    garbage = png(64, 64, 2, 8, None, idat=b'\x00this is not a zlib stream')
    undecodable = Scn('undecodable', {'garbage.png': garbage, 'good.png': FILES['gray16.png']}, 'THUMB_ENCODER=pillow\n')
    undecodable_report = undecodable.report('apply', '--json', code=4)
    rows = {r['relpath']: r for r in undecodable.snapshot_rows()}
    ok(rows['garbage.png']['disposition'] == 'metadata-only' and rows['garbage.png']['reason'] == 'decode-failed'
       and rows['good.png']['disposition'] == 'thumbnail' and undecodable_report['source_errors']['items'][0]['detail'] == 'decode-failed'
       and len(undecodable.thumbs()) == 1,
       'structurally valid but undecodable pixel data is metadata-only decode-failed (exit 4) and does not stop other images')
else:
    skip('undecodable pixel data is decode-failed', 'Pillow is not available')

# round 3: chunk-order rules and partial decodes -----------------------------------------------------------
def ihdr(width, height):
    return chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))

idat_rows = zlib.compress(b''.join(b'\x00' + bytes(15 * 3) for _ in range(10)))
duplicate_ihdr = SIGNATURE + ihdr(1, 1) + ihdr(15, 10) + chunk(b'IDAT', idat_rows) + chunk(b'IEND', b'')
no_idat = SIGNATURE + ihdr(15, 10) + chunk(b'IEND', b'')
iend_payload = SIGNATURE + ihdr(15, 10) + chunk(b'IDAT', idat_rows) + chunk(b'IEND', b'x')
order = Scn('chunk-order', {'dup.png': duplicate_ihdr, 'noidat.png': no_idat, 'iend.png': iend_payload}, 'THUMB_MAX_PIXELS=100\n')
real_encode = archive.ImageEncoder.encode
order_calls = []
def order_encode(self, *args, **kwargs):
    order_calls.append(args)
    return real_encode(self, *args, **kwargs)
archive.ImageEncoder.encode = order_encode
try:
    order_probe = order.inprocess()
    order_probe.build()
finally:
    archive.ImageEncoder.encode = real_encode
order_report = order.report('apply', '--json', code=4)
order_details = {Path(i['path']).name: i['detail'] for i in order_report['source_errors']['items']}
ok(order_details == {'dup.png': 'bad-header', 'noidat.png': 'bad-header', 'iend.png': 'bad-header'} and not order_calls
   and order_report['images']['invalid'] == 3 and not order.thumbs() and order_probe.images['invalid'] == 3,
   'a second IHDR, an IEND without IDAT data or a non-empty IEND is invalid-image/bad-header (exit 4) and never reaches the encoder')

# Indexed PNGs require a palette before their image data; keep all other chunks and CRCs intact.
palette_source = FILES['paletted.png']
palette_parts, position = [SIGNATURE], len(SIGNATURE)
while position < len(palette_source):
    length = struct.unpack('>I', palette_source[position:position + 4])[0]
    end = position + 12 + length
    if palette_source[position + 4:position + 8] != b'PLTE':
        palette_parts.append(palette_source[position:end])
    position = end
missing_palette = Scn('missing-palette', {'indexed.png': b''.join(palette_parts)})
real_encode = archive.ImageEncoder.encode
def reject_palette_encode(self, *args, **kwargs):
    raise AssertionError('an indexed PNG without PLTE reached the encoder')
archive.ImageEncoder.encode = reject_palette_encode
try:
    for limit in (16777216, 1):
        palette_probe = missing_palette.inprocess(PAYLOAD_FILE_MAX_BYTES=limit)
        palette_probe.build()
        assert palette_probe.images['invalid'] == 1 and not palette_probe.encoder.resolved
finally:
    archive.ImageEncoder.encode = real_encode
palette_report = missing_palette.report('apply', '--json', code=4)
palette_errors = palette_report['source_errors']['items']
palette_snap = next(iter(missing_palette.task_record()['snapshots'].values()))
palette_entries = json.loads(gzip.decompress((missing_palette.raw / palette_snap['manifest']['blob']).read_bytes()))['entries']
palette_entry = next(entry for entry in palette_entries if entry['relpath'] == 'indexed.png')
ok(palette_report['source_errors']['count'] == 1 and palette_report['images']['invalid'] == 1
   and palette_errors[0]['reason'] == 'invalid-image' and palette_errors[0]['detail'] == 'bad-header'
   and palette_entry['kind'] == 'invalid-image' and palette_entry['reason'] == 'bad-header'
   and not missing_palette.thumbs() and not palette_report['images']['resolved']
   and 'verify: OK' in missing_palette.run('verify'),
   'an indexed PNG with PLTE removed and valid CRCs is invalid-image/bad-header (apply exit 4), never reaching an encoder in full or seek-only validation')

noise = random.Random(1)
cut_zlib = zlib.compress(b''.join(b'\x00' + bytes(noise.randrange(256) for _ in range(300 * 3)) for _ in range(200)))
partial = png(300, 200, 2, 8, None, idat=cut_zlib[:len(cut_zlib) // 2])
for encoder, available in (('pillow', HAVE_PIL), ('ffmpeg', HAVE_FFMPEG)):
    description = f'{encoder}: a PNG whose zlib stream is cut short (valid chunk CRCs) is decode-failed, not a partial thumbnail'
    if not available:
        skip(description, f'{encoder} is not available')
        continue
    cut = Scn('cut-' + encoder, {'cut.png': partial, 'good.png': FILES['gray16.png']}, f'THUMB_ENCODER={encoder}\n')
    cut_report = cut.report('apply', '--json', code=4)
    cut_rows = {r['relpath']: r for r in cut.snapshot_rows()}
    ok(cut_rows['cut.png']['disposition'] == 'metadata-only' and cut_rows['cut.png']['reason'] == 'decode-failed'
       and cut_rows['good.png']['disposition'] == 'thumbnail' and len(cut.thumbs()) == 1
       and [i['detail'] for i in cut_report['source_errors']['items']] == ['decode-failed'], description)

# (e) pixel cap -------------------------------------------------------------------------------------------
bomb = Scn('bomb', {'bomb.png': bomb_png(), 'small.png': FILES['gray16.png']}, 'THUMB_MAX_PIXELS=100000000\n')
real_encode = archive.ImageEncoder.encode
bomb_calls = []
def bomb_encode(self, *args, **kwargs):
    bomb_calls.append(args)
    return real_encode(self, *args, **kwargs)
archive.ImageEncoder.encode = bomb_encode
try:
    bomb_probe = bomb.inprocess()
    bomb_probe.build()
finally:
    archive.ImageEncoder.encode = real_encode
bomb_report = bomb.report('apply', '--json')
bomb_row = next(r for r in bomb.snapshot_rows() if r['relpath'] == 'bomb.png')
ok(bomb_row['disposition'] == 'metadata-only' and bomb_row['reason'] == 'over-pixel-cap' and (bomb_row['width'], bomb_row['height']) == (20000, 20000)
   and bomb_report['images']['metadata_only'] == ({'over-pixel-cap': 1} if HAVE_ANY else {'no-encoder': 1, 'over-pixel-cap': 1}) and len(bomb.thumbs()) == (1 if HAVE_ANY else 0)
   and all(args[1:3] != (20000, 20000) for args in bomb_calls) and 'verify: OK' in bomb.run('verify'),
   'a 20000x20000 header-only PNG is metadata-only over-pixel-cap with its dimensions and is never handed to the encoder')
lowered = Scn('lowered', {'small.png': FILES['paletted.png']}, 'THUMB_MAX_PIXELS=5000\n')
lowered_report = lowered.report('apply', '--json')
ok(lowered_report['images']['metadata_only'] == {'over-pixel-cap': 1} and not lowered.thumbs() and not lowered_report['images']['resolved'],
   'lowering THUMB_MAX_PIXELS turns a small PNG metadata-only without resolving or importing any encoder')

# (f) no encoder ------------------------------------------------------------------------------------------
none = Scn('none', FILES, 'THUMB_ENCODER=none\n')
none_out = none.run('apply')
none_report = none.report('plan', '--json')
none_rows = {r['relpath']: r for r in none.snapshot_rows()}
ok(none_out.count('no image encoder') == 1 and none_report['images']['notice'] == 'no image encoder'
   and not none.thumbs() and set(none_rows) == set(FILES) and all(r['disposition'] == 'metadata-only' and r['reason'] == 'no-encoder'
       and r['source_sha256'] == sha(FILES[k]) and r['size'] == len(FILES[k]) and r['mtime'].endswith('Z') and r['width'] and r['height']
       for k, r in none_rows.items()) and none_report['images']['metadata_only'] == {'no-encoder': 4} and 'verify: OK' in none.run('verify'),
   'THUMB_ENCODER=none records metadata (path, size, mtime, dimensions, sha256) and reports "no image encoder" exactly once')

blocked = home / 'blocked-pillow'
put(blocked / 'sitecustomize.py', 'import sys\nsys.modules["PIL"] = None\n')
tools = home / 'bare-bin'
tools.mkdir()
for name in ('python3', 'git'):
    (tools / name).symlink_to(shutil.which(name))
bare = Scn('bare', FILES)
bare_env = bare.env(PATH=str(tools), PYTHONPATH=str(blocked))
probe = subprocess.run(['python3', '-c', 'import PIL'], env=bare_env, capture_output=True)
bare_out = bare.run('apply', env=bare_env)
ok(probe.returncode != 0 and shutil.which('ffmpeg', path=str(tools)) is None and bare_out.count('no image encoder') == 1
   and not bare.thumbs() and all(r['reason'] == 'no-encoder' for r in bare.snapshot_rows()) and 'verify: OK' in bare.run('verify'),
   'THUMB_ENCODER=auto with Pillow blocked and no ffmpeg on PATH degrades to metadata-only with the single notice')

# (g) verify catches damaged thumbnails -------------------------------------------------------------------
if main is not None:
    target = main.thumbs()[0]
    original = target.read_bytes()
    flipped = bytearray(original)
    flipped[len(flipped) // 2] ^= 0x01
    target.write_bytes(bytes(flipped))
    flipped_out = main.run('verify', code=1)
    target.write_bytes(b'not a jpeg at all')
    garbage_out = main.run('verify', code=1)
    target.write_bytes(original)
    target.unlink()
    missing_out = main.run('verify', code=1)
    inside = main.vault / 'inside-copy.jpg'
    inside.write_bytes(original)
    target.symlink_to(inside)
    symlink_out = main.run('verify', code=1)
    target.unlink()
    inside.unlink()
    target.write_bytes(original)
    target.chmod(0o600)
    ok('invalid' in flipped_out and 'thumbnail missing or invalid' in garbage_out and 'invalid' in missing_out
       and 'thumbnail missing or invalid' in symlink_out and 'verify: OK' in main.run('verify'),
       'verify exits 1 for a corrupted, non-JPEG, missing or symlinked thumbnail and passes again once it is restored')
else:
    skip('verify catches damaged thumbnails', 'neither Pillow nor ffmpeg is available')

# version-1 catalogs without any image keys keep working --------------------------------------------------
if HAVE_PIL:
    legacy = Scn('legacy', FILES, 'THUMB_ENCODER=pillow\n')
    legacy.run('apply')
    def strip(value):
        if isinstance(value, dict):
            return {k: strip(v) for k, v in value.items() if k not in ('images', 'thumbnails')}
        if isinstance(value, list):
            return [strip(v) for v in value]
        return value
    put(legacy.vault / '_meta/catalog.json', archive.json_bytes(strip(legacy.catalog()), compact=True))
    legacy_verify = legacy.run('verify')
    legacy_apply = legacy.run('apply')
    ok('verify: OK' in legacy_verify and 'images: 4 encoded' in legacy_apply and 'verify: OK' in legacy.run('verify')
       and len(legacy.task_record()['thumbnails']) == 4,
       'a version-1 catalog without images/thumbnails keys still verifies and re-applies, restoring the records')
else:
    skip('version-1 catalog compatibility', 'Pillow is not available')

# changed during scan -------------------------------------------------------------------------------------
if HAVE_PIL:
    racing = Scn('racing', {'rgb.png': FILES['rgb.png']}, 'THUMB_ENCODER=pillow\n')
    real_encode = archive.ImageEncoder.encode
    def touch_after(self, path, *args, **kwargs):
        result = real_encode(self, path, *args, **kwargs)
        stat_before = os.stat(path)
        os.utime(path, ns=(stat_before.st_atime_ns, stat_before.st_mtime_ns + 1_000_000_000))
        return result
    archive.ImageEncoder.encode = touch_after
    try:
        racing_probe = racing.inprocess()
        racing_probe.build()
    finally:
        archive.ImageEncoder.encode = real_encode
    racing_row = racing_probe.images
    ok(racing_row['thumbnails'] == 0 and racing_row['metadata_only'] == {'changed-during-scan': 1}
       and not any(isinstance(v, archive.Thumbnail) for v in racing_probe.files.values())
       and any(item['detail'] == 'changed-during-scan' for item in racing_probe.errors.report(5)['items']),
       'a source modified while it is encoded is discarded as changed-during-scan with a source error and no thumbnail')
else:
    skip('changed-during-scan handling', 'Pillow is not available')

# IMAGE_EXTENSIONS empty -> ordinary payload handling ------------------------------------------------------
disabled = Scn('disabled', {'fake.png': b'P' * 10, 'real.png': FILES['gray16.png']}, 'IMAGE_EXTENSIONS=\n')
disabled_report = disabled.report('apply', '--json')
disabled_entries = json.loads(gzip.decompress((disabled.raw / next(iter(disabled.task_record()['snapshots'].values()))['manifest']['blob']).read_bytes()))['entries']
ok({e['relpath']: e['kind'] for e in disabled_entries if e['relpath'].endswith('.png')} == {'fake.png': 'raw', 'real.png': 'raw'}
   and disabled_report['images']['files'] == 0 and not disabled.thumbs() and 'verify: OK' in disabled.run('verify'),
   'an empty IMAGE_EXTENSIONS disables the image path: PNGs follow ordinary payload handling')

# budgets, unknown hashes, shared thumbnails and root-level images ----------------------------------------
if HAVE_ANY:
    within = Scn('budget-within', {'rgb.png': FILES['rgb.png']}, 'PAYLOAD_TASK_MAX_BYTES=100000\n')
    within_report = within.report('apply', '--json')
    over = Scn('budget-over', {'rgb.png': FILES['rgb.png']}, 'PAYLOAD_TASK_MAX_BYTES=1000\n')
    over_report = over.report('apply', '--json')
    off = Scn('budget-off', {'rgb.png': FILES['rgb.png']}, 'INCLUDE_PAYLOAD=0\n')
    off_report = off.report('apply', '--json')
    ok(len(rgb_png()) > 100000 and within_report['images']['thumbnails'] == 1 and not within_report['images']['metadata_only']
       and over_report['images']['metadata_only'] == {'payload-over-budget': 1} and not over.thumbs()
       and off_report['images']['metadata_only'] == {'payload-disabled': 1} and not off.thumbs()
       and within_report['payload_over_budget']['files'] == 0,
       'the task budget counts each image as at most one thumbnail (not its source bytes); over-budget and disabled payload are metadata-only')

    big = Scn('big-source', {'rgb.png': FILES['rgb.png']}, 'PAYLOAD_FILE_MAX_BYTES=100\n')
    big_first = big.report('apply', '--json')
    big_row = big.snapshot_rows()[0]
    big_again = big.run('apply')
    ok(big_first['images']['thumbnails'] == 1 and 'source_sha256' not in big_row and big_row['size'] == len(FILES['rgb.png'])
       and 'images: 0 encoded, 1 reused' in big_again and '0 files written' in big_again and 'commit: none' in big_again
       and 'verify: OK' in big.run('verify'),
       'a source above PAYLOAD_FILE_MAX_BYTES is not hashed or fully read for validation, still gets a thumbnail, and re-apply reuses it')

    shared = Scn('shared', {'a.png': FILES['paletted.png'], 'b/copy.png': FILES['paletted.png']})
    shared.root.joinpath('proj/.orchestra/root-chart.png').write_bytes(FILES['gray16.png'])
    shared_out = shared.run('apply')
    project = shared.catalog()['projects']['proj']
    root_thumbs = sorted(shared.vault.glob('artifacts/roots/proj/*/thumbs/*.jpg'))
    ok('images: 2 encoded, 1 reused' in shared_out and len(shared.thumbs()) == 1
       and len({r['thumbnail'] for r in shared.snapshot_rows()}) == 1 and len(shared.snapshot_rows()) == 2
       and len(root_thumbs) == 1 and len(project['thumbnails']) == 1 and next(iter(project['images'].values()))[0]['relpath'] == 'root-chart.png'
       and 'verify: OK' in shared.run('verify'),
       'identical images in one task share one content-keyed thumbnail; a root-level image gets its own root thumbnail')
else:
    skip('budget, large-source, shared and root-level image handling', 'neither Pillow nor ffmpeg is available')

# apply spools encoded JPEGs to private raw-dir temp files; none is kept in memory or left behind ---------
if HAVE_ANY:
    spool = Scn('spool', FILES)
    spooled = spool.inprocess(apply=True)
    spooled.build()
    objects = [v for v in spooled.files.values() if isinstance(v, archive.Thumbnail)]
    names = sorted(p.name for p in spool.raw.glob('.thumb-*'))
    no_bytes = all(t.data is None and not any(isinstance(v, (bytes, bytearray)) and len(v) > 200 for v in vars(t).values()) for t in objects)
    on_disk = all(t.temp is not None and t.temp.parent == spool.raw and t.temp.stat().st_size == len(t)
                  and sha(t.materialize()) == t.sha256 and stat.S_IMODE(t.temp.stat().st_mode) == 0o600 for t in objects)
    named = all(re.fullmatch(r'\.thumb-[0-9a-f]{24}-\d+-[0-9a-f]{8}\.jpg', n) for n in names)
    objects[0].close()
    one_closed = len(list(spool.raw.glob('.thumb-*'))) == 3
    del objects
    spooled.files.clear()
    del spooled
    gc.collect()
    ok(len(names) == 4 and named and no_bytes and on_disk and one_closed and not list(spool.raw.glob('.thumb-*')),
       'apply-mode Thumbnail objects hold no JPEG bytes (data is None), spool to 0600 .thumb-* files in raw, and delete them on close/__del__')

    clean = Scn('spool-clean', FILES)
    clean.run('apply')
    broken = Scn('spool-exit4', dict(FILES, **{'truncated.png': truncated_png}))
    broken.run('apply', code=4)
    ok(not list(clean.raw.glob('.thumb-*')) and len(clean.thumbs()) == 4 and not list(broken.raw.glob('.thumb-*')) and len(broken.thumbs()) == 4,
       'no .thumb-* spool file remains in raw after a successful apply or one that exits 4')

    failing = Scn('spool-fail', FILES)
    seen = []
    real_finalize = archive.Archive.finalize
    def failing_finalize(self, *args, **kwargs):
        seen.append(len(list(failing.raw.glob('.thumb-*'))))
        raise archive.ArchiveError('simulated failure', 1)
    archive.Archive.finalize = failing_finalize
    saved_env, saved_umask = dict(os.environ), os.umask(0o022)
    os.environ.update(failing.env())
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            code = archive.main(['apply'])
    finally:
        archive.Archive.finalize = real_finalize
        os.environ.clear()
        os.environ.update(saved_env)
        os.umask(saved_umask)
    ok(code == 1 and seen == [4] and not list(failing.raw.glob('.thumb-*')),
       'an apply that fails after encoding (4 spool files present) still leaves no .thumb-* file in raw')

    if HAVE_PIL:
        racing_apply = Scn('racing-apply', {'rgb.png': FILES['rgb.png']}, 'THUMB_ENCODER=pillow\n')
        real_encode = archive.ImageEncoder.encode
        def touch_after_apply(self, path, *args, **kwargs):
            result = real_encode(self, path, *args, **kwargs)
            before = os.stat(path)
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
            return result
        archive.ImageEncoder.encode = touch_after_apply
        try:
            discarded = racing_apply.inprocess(apply=True)
            discarded.build()
        finally:
            archive.ImageEncoder.encode = real_encode
        ok(discarded.images['metadata_only'] == {'changed-during-scan': 1} and not list(racing_apply.raw.glob('.thumb-*')) and not any(isinstance(v, archive.Thumbnail) for v in discarded.files.values()),
           'a thumbnail discarded as changed-during-scan has its spool file deleted immediately')
    else:
        skip('discarded thumbnail spool cleanup', 'Pillow is not available')
else:
    skip('thumbnail spool files', 'neither Pillow nor ffmpeg is available')

# round 2: per-root thumbnail records, tiny budgets, one-pixel sizes, 16-bit transparency -----------------
if HAVE_ANY:
    shared_png = FILES['paletted.png']
    twin = Scn('twin-roots', state=True)
    for checkout in ('a', 'b'):
        put(twin.state / f'worktrees/proj/{checkout}/.orchestra/chart.png', shared_png)
    twin_first = twin.run('apply')
    twin_thumbs = sorted(twin.vault.glob('artifacts/roots/proj/*/thumbs/*.jpg'))
    twin_projects = twin.catalog()['projects']['proj']
    twin_again = twin.run('apply')
    root_damage = []
    for victim in twin_thumbs:
        original = victim.read_bytes()
        victim.write_bytes(original[:len(original) // 2] + bytes([original[len(original) // 2] ^ 1]) + original[len(original) // 2 + 1:])
        root_damage.append('invalid' in twin.run('verify', code=1))
        victim.write_bytes(original)
    ok(len(twin_thumbs) == 2 and 'images: 2 encoded, 0 reused' in twin_first and len(twin_projects['thumbnails']) == 2
       and 'images: 0 encoded, 2 reused' in twin_again and '0 files written' in twin_again and 'commit: none' in twin_again
       and root_damage == [True, True] and 'verify: OK' in twin.run('verify'),
       'identical PNGs in two roots of one project keep separate records: re-apply is a no-op and corrupting either root thumbnail fails verify')

    tiny = Scn('tiny-budget', {'dot.png': solid_png(1, 1)}, 'PAYLOAD_TASK_MAX_BYTES=100\n')
    tiny_report = tiny.report('apply', '--json')
    ok(len(solid_png(1, 1)) < 100 and tiny_report['images']['metadata_only'] == {'payload-over-budget': 1} and not tiny.thumbs()
       and tiny.snapshot_rows()[0]['reason'] == 'payload-over-budget',
       'each image reserves the full THUMB_MAX_BYTES, so a tiny PNG cannot slip a larger JPEG past a small task budget')

SIZES = {'col.png': (1, 20), 'row.png': (20, 1), 'dot.png': (1, 1), 'odd.png': (3, 5)}
for encoder, available in (('pillow', HAVE_PIL), ('ffmpeg', HAVE_FFMPEG)):
    description = f'{encoder}: 1x20, 20x1, 1x1 and odd-sized PNGs, and THUMB_MAX_EDGE=1, all produce thumbnails (exit 0)'
    if not available:
        skip(description, f'{encoder} is not available')
        continue
    thin = Scn('thin-' + encoder, {name: solid_png(*size) for name, size in SIZES.items()}, f'THUMB_ENCODER={encoder}\n')
    thin_report = thin.report('apply', '--json')
    thin_sizes = sorted(jpeg_size((thin.vault / r['path']).read_bytes()) for r in thin.task_record()['thumbnails'].values())
    edge = Scn('edge1-' + encoder, {'wide.png': FILES['rgb.png'], 'col.png': solid_png(1, 20)}, f'THUMB_ENCODER={encoder}\nTHUMB_MAX_EDGE=1\n')
    edge_report = edge.report('apply', '--json')
    edge_sizes = [jpeg_size((edge.vault / r['path']).read_bytes()) for r in edge.task_record()['thumbnails'].values()]
    ok(thin_report['images']['thumbnails'] == 4 and thin_sizes == sorted(SIZES.values())
       and edge_report['images']['thumbnails'] == 2 and edge_sizes == [(1, 1), (1, 1)] and not edge_report['source_errors']['count'],
       description)

TRNS = {'gray16-trns.png': trns_gray16_png(), 'rgb16-trns.png': trns_rgb16_png()}
for encoder, available in (('pillow', HAVE_PIL), ('ffmpeg', HAVE_FFMPEG)):
    description = f'{encoder}: 16-bit gray and 16-bit RGB tRNS keys become white, other samples stay'
    if not available:
        skip(description, f'{encoder} is not available')
        continue
    if not HAVE_PIL:
        # Without Pillow the JPEG pixels cannot be decoded here; only the structure is checked.
        scn = Scn('trns-' + encoder, TRNS, f'THUMB_ENCODER={encoder}\n')
        scn.report('apply', '--json')
        ok(len(scn.thumbs()) == 2, description + ' (structure only; Pillow is needed to decode pixels)')
        continue
    scn = Scn('trns-' + encoder, TRNS, f'THUMB_ENCODER={encoder}\n')
    scn.report('apply', '--json')
    by_source = {r['source']['sha256']: (scn.vault / r['path']).read_bytes() for r in scn.task_record()['thumbnails'].values()}
    gray, rgb = by_source[sha(TRNS['gray16-trns.png'])], by_source[sha(TRNS['rgb16-trns.png'])]
    key_gray, near_key, light_gray = pixel(gray, (3, 10)), pixel(gray, (21, 10)), pixel(gray, (35, 10))
    key_rgb, opaque_rgb = pixel(rgb, (3, 10)), pixel(rgb, (35, 10))
    ok(min(key_gray) >= 240 and max(near_key) < 80 and 100 < light_gray[0] < 220
       and min(key_rgb) >= 240 and opaque_rgb[0] > 150 and opaque_rgb[1] < 100,
       description)

# policy validation ---------------------------------------------------------------------------------------
# Per-task sample: selection is fixed before validation, with compact folder summaries -------------------
indices = archive.thumbnail_sample_indices
hundred = indices(100, 48)
ok(len(hundred) == len(set(hundred)) == 48 and hundred == sorted(hundred) and hundred[0] == 0 and hundred[-1] == 99
   and indices(5, 48) == [0, 1, 2, 3, 4] and indices(100, 1) == [0] and indices(100, 0) == []
   and indices(100, 2) == [0, 99] and indices(0, 48) == [],
   'thumbnail sample indices cover all images below the limit, evenly spaced endpoints, and limits 0/1/2')

SAMPLE_FILES = {f'{"a" if i < 4 else "b"}/{i}.png': solid_png(8 + i, 6) for i in reversed(range(7))}
SAMPLE_PATHS = sorted(SAMPLE_FILES)
SAMPLED = [SAMPLE_PATHS[i] for i in (0, 3, 6)]

def sample_folders(thumbnails):
    return [{'folder': folder, 'pngs': count,
             'source_bytes': sum(len(data) for rel, data in SAMPLE_FILES.items() if rel.startswith(folder + '/')),
             'thumbnails': thumbs}
            for folder, count, thumbs in (('a', 4, 2 if thumbnails else 0), ('b', 3, 1 if thumbnails else 0))]

if HAVE_ANY:
    sampled = Scn('sampled', SAMPLE_FILES, 'THUMB_MAX_PER_TASK=3\nTHUMB_EMBED_MAX=2\n')
    sampled_report = sampled.report('apply', '--json')
    sampled_task = sampled.task_record()
    sid, snap = next(iter(sampled_task['snapshots'].items()))
    manifest = json.loads(gzip.decompress((sampled.raw / snap['manifest']['blob']).read_bytes()))
    png_entries = {entry['relpath']: entry for entry in manifest['entries'] if entry['kind'] == 'image'}
    image_section = (sampled.vault / f'tasks/{TID}.md').read_text().split('## Images', 1)[1].split('## Per-snapshot', 1)[0]
    blocks = re.findall(r'```text\n(.*?)\n```', image_section, re.S)
    listing = json.loads(blocks[1])
    expected_folders = sample_folders(True)
    expected_table = 'snapshot | folder | pngs | source_bytes | thumbnails\n' + '\n'.join(
        f"{sid} | {row['folder']} | {row['pngs']} | {row['source_bytes']} | {row['thumbnails']}" for row in expected_folders)
    before = sampled.hashes(sampled.vault), sampled.hashes(sampled.raw), sampled.commits()
    again = sampled.run('apply')
    ok(sampled_report['images']['thumbnails'] == 3 and sampled_report['images']['max_per_task'] == 3
       and sampled_report['images']['metadata_only'] == {'not-sampled': 4} and len(sampled.thumbs()) == 3
       and [row['relpath'] for row in snap['images']] == SAMPLED and [row['relpath'] for row in listing] == SAMPLED
       and set(png_entries) == set(SAMPLE_PATHS) and all(
           entry['sha256'] == sha(SAMPLE_FILES[rel]) and entry['width'] == 8 + int(Path(rel).stem) and entry['height'] == 6
           and (('sampled' not in entry) if rel in SAMPLED else entry.get('sampled') is False)
           for rel, entry in png_entries.items())
       and snap['image_folders'] == expected_folders and blocks[0] == expected_table
       and image_section.count('![[artifacts/') == 2
       and 'Sampled: 3 thumbnails of 7 PNG files (THUMB_MAX_PER_TASK=3);' in image_section
       and before == (sampled.hashes(sampled.vault), sampled.hashes(sampled.raw), sampled.commits())
       and '0 files written' in again and 'commit: none' in again and 'images: 0 encoded, 3 reused' in again
       and 'verify: OK' in sampled.run('verify'),
       '7 PNGs sample sorted positions 0/3/6: only 3 catalog/note rows, 7 manifest entries, exact folder totals, bounded embeds and no-op re-apply')

    many = Scn('sample-budget', {f'{i:03}.png': solid_png(i + 1, 1) for i in range(200)},
               'THUMB_MAX_PER_TASK=2\nTHUMB_MAX_BYTES=65536\nPAYLOAD_TASK_MAX_BYTES=262144\n')
    many_report = many.report('apply', '--json')
    ok(many_report['images']['thumbnails'] == 2 and len(many.thumbs()) == 2
       and many_report['images']['metadata_only'] == {'not-sampled': 198}
       and [row['relpath'] for row in many.snapshot_rows()] == ['000.png', '199.png']
       and many_report['payload_over_budget']['files'] == 0 and 'verify: OK' in many.run('verify'),
       '200 tiny PNGs reserve only min(n, K) times the thumbnail cap: K=2 fits a 256 KiB task budget')

    sampled.set_conf('THUMB_MAX_PER_TASK=0\n')
    zero_report = sampled.report('apply', '--json')
    zero_note = (sampled.vault / f'tasks/{TID}.md').read_text()
    ok(zero_report['images']['metadata_only'] == {'not-sampled': 7} and zero_report['images']['thumbnails'] == 0
       and not zero_report['images']['resolved'] and not sampled.snapshot_rows()
       and next(iter(sampled.task_record()['snapshots'].values()))['image_folders'] == sample_folders(False)
       and '![[artifacts/' not in zero_note and 'Sampled: 0 thumbnails of 7 PNG files (THUMB_MAX_PER_TASK=0);' in zero_note
       and 'verify: OK' in sampled.run('verify'),
       'changing the sample limit to zero clears current image rows and embeds, retaining folder summaries and existing artifacts')
else:
    skip('sample selection, manifest metadata, folder table, re-apply, sampled budget and zero-limit transition',
         'neither Pillow nor ffmpeg is available')

sample_none = Scn('sample-none', SAMPLE_FILES, 'THUMB_MAX_PER_TASK=3\nTHUMB_ENCODER=none\n')
none_sample_report = sample_none.report('apply', '--json')
none_sample_note = (sample_none.vault / f'tasks/{TID}.md').read_text()
ok(none_sample_report['images']['metadata_only'] == {'no-encoder': 3, 'not-sampled': 4}
   and not sample_none.thumbs() and [row['relpath'] for row in sample_none.snapshot_rows()] == SAMPLED
   and all(row['reason'] == 'no-encoder' for row in sample_none.snapshot_rows())
   and next(iter(sample_none.task_record()['snapshots'].values()))['image_folders'] == sample_folders(False)
   and 'Sampled: 0 thumbnails of 7 PNG files (THUMB_MAX_PER_TASK=3);' in none_sample_note
   and '![[artifacts/' not in none_sample_note and 'verify: OK' in sample_none.run('verify'),
   'without an encoder only sampled PNGs get no-encoder rows; the rest are not-sampled and folder thumbnail counts are zero')

sample_invalid = Scn('sample-invalid', {'a.png': b'not png', 'b.png': truncated_png,
                                      'c.png': solid_png(2, 2), 'd.png': solid_png(3, 2), 'e.png': solid_png(4, 2)},
                     'THUMB_MAX_PER_TASK=2\nTHUMB_ENCODER=none\n')
invalid_report = sample_invalid.report('apply', '--json', code=4)
invalid_snap = next(iter(sample_invalid.task_record()['snapshots'].values()))
ok(invalid_report['images']['invalid'] == invalid_report['source_errors']['count'] == 2
   and invalid_report['images']['metadata_only'] == {'no-encoder': 1, 'not-sampled': 2}
   and [row['relpath'] for row in invalid_snap['images']] == ['e.png']
   and invalid_snap['image_folders'][0]['folder'] == '.' and invalid_snap['image_folders'][0]['pngs'] == 5
   and invalid_snap['image_folders'][0]['source_bytes'] == sum((sample_invalid.task / f'{name}.png').stat().st_size for name in 'abcde'),
   'invalid PNGs inside and outside the fixed sample still exit 4 and count in folder totals; invalid slots are not refilled')

zero = Scn('sample-zero', SAMPLE_FILES, 'THUMB_MAX_PER_TASK=0\n')
root_pngs = {zero.base / '.orchestra' / f'{i}.png': solid_png(5 + i, 2) for i in range(3)}
for path, data in root_pngs.items():
    put(path, data)
zero_first = zero.report('apply', '--json')
zero_project = zero.catalog()['projects']['proj']
zero_snap = next(iter(zero.task_record()['snapshots'].values()))
zero_entries = json.loads(gzip.decompress((zero.raw / zero_snap['manifest']['blob']).read_bytes()))['entries']
ok(zero_first['images']['metadata_only'] == {'not-sampled': 10} and not zero_first['images']['resolved']
   and not zero.snapshot_rows() and zero_snap['image_folders'] == sample_folders(False)
   and all(entry['sampled'] is False for entry in zero_entries if entry['kind'] == 'image')
   and next(iter(zero_project['image_folders'].values())) == [
       {'folder': '.', 'pngs': 3, 'source_bytes': sum(map(len, root_pngs.values())), 'thumbnails': 0}]
   and 'images' not in zero_project and 'verify: OK' in zero.run('verify'),
   'a zero limit validates every task/root PNG without resolving an encoder and still stores folder summaries and manifest metadata')

zero.set_conf('THUMB_MAX_PER_TASK=1\nTHUMB_ENCODER=none\n')
one_report = zero.report('apply', '--json')
one_project = zero.catalog()['projects']['proj']
assert one_report['images']['metadata_only'] == {'no-encoder': 2, 'not-sampled': 8}
assert [row['relpath'] for row in zero.snapshot_rows()] == [SAMPLE_PATHS[0]]
assert [row['relpath'] for row in next(iter(one_project['images'].values()))] == ['0.png']
for path in root_pngs:
    path.unlink()
zero.run('apply')
ok('image_folders' not in zero.catalog()['projects']['proj'] and 'images' not in zero.catalog()['projects']['proj'],
   'each task/root scan gets its own sample; root folder and image summaries are removed when root PNGs disappear')

policy_checks = [('IMAGE_EXTENSIONS=.bmp\n', 'IMAGE_EXTENSIONS supports only .png'), ('THUMB_ENCODER=magic\n', 'THUMB_ENCODER must be auto, pillow, ffmpeg or none'),
                 ('THUMB_QUALITY=0\n', 'THUMB_QUALITY must be 1..95'), ('THUMB_QUALITY=96\n', 'THUMB_QUALITY must be 1..95'),
                 ('THUMB_MAX_EDGE=0\n', 'at least 1'), ('THUMB_MAX_BYTES=0\n', 'at least 1'), ('THUMB_MAX_PIXELS=0\n', 'at least 1'),
                 ('THUMB_EMBED_MAX=-1\n', 'THUMB_EMBED_MAX must be nonnegative'), ('THUMB_MAX_PER_TASK=-1\n', 'THUMB_MAX_PER_TASK must be nonnegative'),
                 ('THUMB_MAX_PER_TASK=abc\n', 'THUMB_MAX_PER_TASK must be an integer'), ('TEXT_EXTENSIONS=.md .png\n', 'IMAGE_EXTENSIONS overlaps TEXT_EXTENSIONS'),
                 ('CHECKPOINT_EXTENSIONS=.PNG\n', 'IMAGE_EXTENSIONS overlaps CHECKPOINT_EXTENSIONS')]
validation = Scn('policy')
messages = []
for text, expected in policy_checks:
    validation.set_conf(text)
    _, err = validation.run('plan', code=2, stderr=True)
    messages.append(expected in err)
ok(all(messages), 'invalid image policy values exit 2 with a specific message: ' + ', '.join(t.strip() for t, _ in policy_checks[:3]) + ' ...')

# plan writes nothing -------------------------------------------------------------------------------------
if HAVE_ANY:
    dry = Scn('dry', FILES)
    def tree(base):
        return sorted((str(p.relative_to(base)), p.lstat().st_size, p.lstat().st_mtime_ns) for p in base.rglob('*'))
    before = tree(dry.root)
    plan_plain = dry.report('plan', '--json')
    plan_measure = dry.report('plan', '--json', '--measure-thumbnails')
    ok(tree(dry.root) == before and not dry.vault.exists() and not dry.raw.exists()
       and plan_plain['images']['pending'] == 4 and plan_plain['images']['thumbnails'] == 0 and 'images_measurement' not in plan_plain
       and plan_measure['images']['thumbnails'] == 4 and plan_measure['images']['pending'] == 0
       and plan_measure['images_measurement']['encoded'] == 4 and plan_measure['images_measurement']['reused'] == 0
       and plan_measure['images']['thumbnail_bytes'] > 0 and set(plan_measure['images_measurement']['peak_rss_kib']) == {'self', 'children'},
       'plan writes nothing; without --measure-thumbnails images are pending, with it they are encoded in memory and measured')
    applied = Scn('dry-applied', FILES)
    applied.run('apply')
    reuse_plan = applied.report('plan', '--json', '--measure-thumbnails')
    ok(reuse_plan['images_measurement']['encoded'] == 0 and reuse_plan['images_measurement']['reused'] == 4
       and applied.report('plan', '--json')['images']['pending'] == 0,
       'plan reuses thumbnails already in the vault (no decode, nothing pending)')
else:
    skip('plan writes nothing / measurement', 'neither Pillow nor ffmpeg is available')

ok(checked_applies >= 20, f'source files were byte- and mtime-identical after each of {checked_applies} archive runs')
print(f'PASS: {groups} image test groups; SKIPPED: {len(skipped)}' + (' (' + '; '.join(skipped) + ')' if skipped else ''))
PY

# Host import tests use identical source paths across fixture hosts, then leave A's sources live.
env HOME="$IMPORT_TEST_HOME" CODEX_HOME="$IMPORT_TEST_HOME/codex" PYTHONUSERBASE="$IMAGE_USER_BASE" python3 - <<'PY'
import sys
sys.dont_write_bytecode = True
import collections
import copy
import fcntl
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import zlib

repo, home = Path(os.environ['ARCHIVE_REPO_DIR']), Path(os.environ['HOME'])
command = repo / 'bin/orch-archive'
sys.path.insert(0, str(repo / 'lib'))
import orch_archive as archive
groups, skipped = 0, []
work = home / 'work'
base = work / 'demo'
secret = 'AKIA' + 'ABCDEFGHIJKLMNOP'
secret_line = '# ' + secret + '\n'
have_encoder = importlib.util.find_spec('PIL') is not None or shutil.which('ffmpeg') is not None

def ok(condition, description):
    global groups
    assert condition, description
    groups += 1
    print(f'ok {groups} - {description}', flush=True)

def skip(description):
    skipped.append(description)
    print(f'skip - {description} (SKIPPED: no image encoder)', flush=True)

def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())

def environment(name):
    root = home / name
    return dict(os.environ, HOME=str(home), CODEX_HOME=str(work / 'codex'),
                ORCH_ARCHIVE_VAULT=str(root / 'vault'), ORCH_ARCHIVE_RAW=str(root / 'raw'),
                ORCH_ARCHIVE_ALLOWLIST=str(root / 'allowlist'), ORCH_ARCHIVE_POLICY=str(home / 'policy'),
                ORCH_ARCHIVE_STATE_DIRS=str(work / 'state'), ORCH_ARCHIVE_CLAUDE_PROJECTS=str(work / 'claude-projects'),
                ORCH_ARCHIVE_CODEX_HOME=str(work / 'codex'), ORCH_ARCHIVE_EXTRA_BASES='')

def run(name, *args, code=0):
    result = subprocess.run([str(command), *args], env=environment(name), text=True, capture_output=True)
    assert result.returncode == code, (name, args, result.returncode, code, result.stdout, result.stderr)
    return result.stdout + result.stderr

def report(output):
    return json.loads(output.splitlines()[0])

def catalog(name):
    return json.loads((home / name / 'vault/_meta/catalog.json').read_bytes())

def save_catalog(name, value):
    put(home / name / 'vault/_meta/catalog.json', archive.json_bytes(value, compact=True))

def hashes(path, git=False):
    return {str(p.relative_to(path)): archive.sha(p.read_bytes()) for p in sorted(path.rglob('*'))
            if p.is_file() and (git or '.git' not in p.relative_to(path).parts)}

def listing(path, git=False):
    result = {}
    for p in sorted(path.rglob('*')):
        if not git and '.git' in p.relative_to(path).parts:
            continue
        st = p.lstat()
        result[str(p.relative_to(path))] = (st.st_size, st.st_mtime_ns, stat.S_IMODE(st.st_mode), st.st_ino)
    return result

def state(name, git=False):
    return [(hashes(home / name / kind, git), listing(home / name / kind, git)) for kind in ('vault', 'raw')]

def clone(source, dest):
    shutil.copytree(home / source, home / dest)
    return dest

def imported(dest, source='bee', host=None, *options, code=0):
    return run(dest, 'import', '--host', host or source, '--source-vault', str(home / source / 'vault'),
               '--source-raw', str(home / source / 'raw'), '--json', '--top', '1000', *options, code=code)

def verified(name):
    return 'verify: OK' in run(name, 'verify')

def task(name, label):
    path = base / '.orchestra' / name
    put(path / 'brief.md', f'# {label}\nRISK: normal\n## Git\nBRANCH: orch/{name}\n' +
        ('Build on orch/01-shared\n' if name.startswith('02-') else ''))
    put(path / 'plan.md', '# Plan\n')
    put(path / 'summary.md', 'STATUS: PASS\nCLAUDE PROFILE: lead-alpha opus@high\n')
    return path

def make_host(name):
    if work.exists():
        shutil.rmtree(work)
    put(work / 'state/sessions/alpha.conf', f'LAUNCH_NAME=alpha\nPROJECT_NAME=demo\nREPO={base}\nBACKEND=claude\n')
    put(base / '.orchestra/REGISTRY.md', '# Registry\n')
    shared = task('01-shared', name + ' shared task')
    other = task('02-' + name + '-only', name + ' task')
    model = {'bee': 'gpt-6-sol', 'cat': 'gpt-6-astra', 'sec': 'gpt-6-luna', 'A': 'gpt-6.1-sol'}[name]
    put(other / 'summary.md', f'STATUS: PASS\nCODEX PROFILE: {model}@high\n')
    if name == 'sec':
        put(shared / 'brief.md', secret_line)
        put(home / name / 'allowlist', 'sha256:' + archive.sha(secret_line.encode()) + '\nsha256:' + archive.sha(secret.encode()) + '\n')
    if name == 'bee' and have_encoder:
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        png = archive.PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
        png += chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 2) * 2)) + chunk(b'IEND', b'')
        put(other / 'plot.png', png)
    encoded = re.sub(r'[^A-Za-z0-9]', '-', str(base))
    put(work / 'claude-projects' / encoded / 't.jsonl', json.dumps({'message': name}) + '\n')
    run(name, 'apply')
    assert verified(name)

put(home / 'policy', '')
for name in ('bee', 'cat', 'sec', 'A'):
    make_host(name)
clone('A', 'original')
bee_before = state('bee', git=True)
local_before = state('A')
local_catalog = catalog('A')
local_pages = {rel: (home / 'A/vault' / rel).read_bytes() for rel in local_before[0][0]}

# 1: namespace collisions, relation links, model aggregation, roots, histories and thumbnails.
output = imported('A')
data = report(output)
merged = catalog('A')
for kind in ('tasks', 'sessions', 'projects'):
    for identifier in catalog('bee')[kind]:
        assert merged[kind]['bee--' + identifier]['source_id'] == identifier
for rel in ('projects/bee--demo.md', 'sessions/bee--alpha.md', 'tasks/bee--demo--01-shared.md',
            'tasks/bee--demo--02-bee-only.md', '_meta/hosts/bee.md', 'projects/demo.md', 'sessions/alpha.md', 'tasks/demo--01-shared.md'):
    assert (home / 'A/vault' / rel).is_file(), rel
fields, _ = archive.frontmatter((home / 'A/vault/models/claude-opus.md').read_text())
assert {'[[tasks/demo--01-shared]]', '[[tasks/bee--demo--01-shared]]'} <= set(fields['tasks'])
assert '[[tasks/bee--demo--01-shared]]' in (home / 'A/vault/tasks/bee--demo--02-bee-only.md').read_text()
assert list((home / 'A/vault/artifacts/roots/bee--demo').glob('*/files/REGISTRY.md'))
for p in (home / 'bee/raw/sources').glob('*.json'):
    assert (home / 'A/raw/sources/bee' / p.name).read_bytes() == p.read_bytes()
assert {p.name for p in (home / 'bee/raw/sources').glob('*.json')} & {p.name for p in (home / 'original/raw/sources').glob('*.json')}
assert {'kind': 'projects', 'from': 'demo', 'to': 'bee--demo'} in data['collisions']['renamed']
assert 'claude-opus' in data['collisions']['models_aggregated']
if have_encoder:
    thumbnails = merged['tasks']['bee--demo--02-bee-only']['thumbnails']
    assert thumbnails and all((home / 'A/vault' / row['path']).is_file() for row in thumbnails.values())
    assert '![[artifacts/tasks/bee--demo--02-bee-only/thumbs/' in (home / 'A/vault/tasks/bee--demo--02-bee-only.md').read_text()
else:
    skip('imported thumbnail and image embed')
ok(verified('A'), 'host records, relations, aggregate models, artifacts and raw histories resolve')

# 2: independently check shared-page supersets and immutability of all other pre-existing content.
def superset(rel, old, new):
    if rel.endswith('.md'):
        of, ob = archive.frontmatter(old.decode())
        nf, nb = archive.frontmatter(new.decode())
        assert of.keys() == nf.keys()
        for key, value in of.items():
            if isinstance(value, list):
                encode = lambda rows: collections.Counter(json.dumps(row, sort_keys=True) for row in rows)
                assert encode(value) <= encode(nf[key])
            else:
                assert value == nf[key]
        assert collections.Counter(ob.splitlines()) <= collections.Counter(nb.splitlines())
    elif rel == '.obsidian/graph.json':
        of, nf = json.loads(old), json.loads(new)
        groups = of.pop('colorGroups')
        assert nf.pop('colorGroups')[:len(groups)] == groups and of == nf
    elif rel == '_meta/catalog.json':
        of, nf = json.loads(old), json.loads(new)
        for kind in ('tasks', 'sessions', 'projects', 'models'):
            assert all(nf[kind][key] == value for key, value in of[kind].items())
        assert set(of['generated']) <= set(nf['generated'])
    else:
        assert old == new

for rel, old in local_pages.items():
    new = (home / 'A/vault' / rel).read_bytes()
    if archive.Importer.shared(rel):
        superset(rel, old, new)
    else:
        assert old == new, rel
assert all(hashes(home / 'A/raw')[rel] == value for rel, value in local_before[1][0].items())
ok(True, 'local files and records remain identical; shared pages only gain content')

# 3 and 11: dry runs before and after import change no bytes, mtimes, modes, inodes or git files.
clone('original', 'dry')
(home / 'dry/raw/.lock').unlink()
before = state('dry', git=True)
dry_report = report(imported('dry', 'bee', None, '--dry-run'))
assert state('dry', git=True) == before and not (home / 'dry/raw/.lock').exists()
assert dry_report['dry_run'] and dry_report['adds']['tasks'] and dry_report['collisions']['renamed']
before = state('A', git=True)
assert report(imported('A', 'bee', None, '--dry-run'))['files']['new_count'] == 0
assert state('A', git=True) == before
ok(state('bee', git=True) == bee_before, 'both source trees stay byte- and metadata-identical during import and dry-run')
ok(True, 'dry-run before and after import writes nothing, creates no lock and reports additions/collisions')

# 4: re-import makes no content or file metadata changes and no commit.
def commit_count(name):
    return subprocess.check_output(['git', '-C', str(home / name / 'vault'), 'rev-list', '--count', 'HEAD'],
                                   env=archive.git_env(), text=True).strip()
before, commits = state('A'), commit_count('A')
assert 'commit: none' in imported('A')
ok(state('A') == before and commit_count('A') == commits, 'unchanged re-import preserves hashes/mtimes and creates no commit')

# 5 and 14: import order commutes, including colors and raw gzip bytes.
clone('original', 'order1')
clone('original', 'order2')
imported('order1', 'bee')
imported('order1', 'cat')
imported('order2', 'cat')
first_graph = json.loads((home / 'order2/vault/.obsidian/graph.json').read_bytes())['colorGroups']
imported('order2', 'bee')
second_graph = json.loads((home / 'order2/vault/.obsidian/graph.json').read_bytes())['colorGroups']
ok(all(hashes(home / 'order1' / kind) == hashes(home / 'order2' / kind) for kind in ('vault', 'raw'))
   and verified('order1') and verified('order2'), 'bee then cat equals cat then bee byte-for-byte')
local_graph = json.loads(local_pages['.obsidian/graph.json'])['colorGroups']
ok(all(group in second_graph for group in first_graph) and first_graph[:len(local_graph)] == second_graph[:len(local_graph)] == local_graph,
   'host graph colors survive later imports; local groups retain their prefix')

# 6: later applies retain all imported records, host pages, notes and artifacts.
def host_files(name, host='bee'):
    return {rel: value for rel, value in hashes(home / name / 'vault').items()
            if any(part.startswith(host + '--') for part in Path(rel).parts) or rel == f'_meta/hosts/{host}.md'}

def host_records(name, host='bee'):
    value = catalog(name)
    return {kind: {key: row for key, row in value[kind].items() if row.get('host') == host}
            for kind in ('tasks', 'sessions', 'projects')}

before_files, before_records = host_files('A'), host_records('A')
all_before = set(hashes(home / 'A/vault'))
task('03-new-local', 'new local task')
run('A', 'apply')
assert host_files('A') == before_files and host_records('A') == before_records
assert all_before <= set(hashes(home / 'A/vault')) and 'demo--03-new-local' in catalog('A')['tasks']
assert 'commit: none' in imported('A')
run('A', 'apply')
ok(host_files('A') == before_files and host_records('A') == before_records and verified('A'),
   'apply/import/apply freezes imported notes and records while discovering new local tasks')

# 7: importing must not opportunistically migrate legacy local snapshots.
clone('original', 'legacy')
legacy = catalog('legacy')
for item in legacy['tasks'].values():
    for snapshot in item['snapshots'].values():
        snapshot['entries'] = json.loads(gzip.decompress((home / 'legacy/raw' / snapshot['manifest']['blob']).read_bytes()))['entries']
        for key in ('manifest', 'counts', 'files', 'bytes'):
            snapshot.pop(key)
save_catalog('legacy', legacy)
imported('legacy')
assert all(catalog('legacy')['tasks'][key] == value for key, value in legacy['tasks'].items())
before = host_files('legacy')
run('legacy', 'apply')
ok(before == host_files('legacy') and verified('legacy') and all('manifest' in snapshot for item in catalog('legacy')['tasks'].values()
   for snapshot in item['snapshots'].values()), 'legacy local catalogs import unchanged and migrate only on later apply')

# Rejection helper proves all local bytes and metadata are preserved.
def rejected(dest, source, reason, host='bee', *options):
    before = state(dest, git=True)
    data = report(imported(dest, source, host, *options, code=4))
    assert reason in {item['reason'] for item in data['rejected']['items']}, data
    assert state(dest, git=True) == before, (source, reason)
    return data

# 8: invalid gzip, wrong uncompressed digest, missing referenced blob.
clone('original', 'reject')
for name, reason in [('bad-gzip', 'blob-gzip'), ('bad-hash', 'blob-hash'), ('missing-blob', 'source-verify')]:
    clone('bee', name)
    pointer = next(iter(catalog(name)['tasks']['demo--01-shared']['snapshots'].values()))['manifest']
    path = home / name / 'raw' / pointer['blob']
    if name == 'missing-blob':
        path.unlink()
    else:
        put(path, b'bad gzip' if name == 'bad-gzip' else gzip.compress(b'wrong content'))
    rejected('reject', name, reason)
ok(True, 'bad gzip, wrong blob hashes and missing referenced blobs reject before writes')

# 9: traversal ids and generated artifact paths.
clone('bee', 'unsafe-id')
value = catalog('unsafe-id')
record = value['tasks'].pop('demo--01-shared')
record['id'] = '../../evil'
value['tasks']['../../evil'] = record
save_catalog('unsafe-id', value)
rejected('reject', 'unsafe-id', 'unsafe-id')
clone('bee', 'unsafe-path')
value = catalog('unsafe-path')
value['generated'].append('artifacts/tasks/demo--01-shared/../../../x')
save_catalog('unsafe-path', value)
rejected('reject', 'unsafe-path', 'unsafe-path')
ok(not (home / 'evil').exists() and not (home / 'x').exists(), 'traversal ids and artifact paths are rejected without writes')

# 10: source release policy is not authority for local vault output.
clone('original', 'secret')
value = report(imported('secret', 'sec', code=4))
assert value['withheld_count'] >= 1 and not value['rejected']['count']
assert all(secret.encode() not in p.read_bytes() for p in (home / 'secret/vault').rglob('*') if p.is_file())
assert archive.sha(secret_line.encode()) in (home / 'secret/vault/_meta/hosts/sec.md').read_text()
ok(verified('secret'), 'locally withheld imported text stays out of the vault and is reported by hash')

# 12: usage, chaining, id collisions, apply collision guard and lock busy.
for host in ('local', 'Bad', 'a--b', '-a', 'a-', 'a' * 33):
    before = state('reject', git=True)
    run('reject', 'import', '--host=' + host, '--source-vault', str(home / 'bee/vault'), '--source-raw', str(home / 'bee/raw'), code=2)
    assert state('reject', git=True) == before
run('reject', 'import', '--host', 'bee', '--source-vault', str(home / 'reject/vault'), '--source-raw', str(home / 'bee/raw'), code=2)
rejected('reject', 'A', 'chained-import', host='nested')
clone('original', 'id-collision')
value = catalog('id-collision')
value['projects']['bee--demo'] = dict(value['projects']['demo'], id='bee--demo')
save_catalog('id-collision', value)
rejected('id-collision', 'bee', 'id-collision')
clone('A', 'apply-collision')
conf = work / 'state/sessions/alpha.conf'
original_conf = conf.read_bytes()
put(conf, original_conf.replace(b'PROJECT_NAME=demo', b'PROJECT_NAME=bee--demo'))
before = hashes(home / 'apply-collision/vault', git=True)
assert 'collides with an imported host record' in run('apply-collision', 'apply', code=2)
assert hashes(home / 'apply-collision/vault', git=True) == before
put(conf, original_conf)
with (home / 'reject/raw/.lock').open('r+b') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    imported('reject', code=3)
ok(True, 'usage, chained imports, record collisions, apply collisions and concurrent writers fail safely')

# 13: append-only checks and source-history/artifact integrity.
clone('bee', 'changed-record')
value = catalog('changed-record')
value['tasks']['demo--01-shared']['fields']['title'] = 'changed title'
save_catalog('changed-record', value)
rejected('A', 'changed-record', 'existing-differs')
clone('original', 'existing-file')
put(home / 'existing-file/vault/tasks/bee--demo--01-shared.md', 'uncatalogued local data\n')
rejected('existing-file', 'bee', 'existing-differs')
clone('bee', 'guard-collision')
value = catalog('guard-collision')
for sid in (secret, 'withheld-' + archive.sha(secret.encode())[:12]):
    value['sessions'][sid] = dict(copy.deepcopy(value['sessions']['alpha']), id=sid)
save_catalog('guard-collision', value)
rejected('reject', 'guard-collision', 'id-collision')
clone('bee', 'history-corrupt')
path = next((home / 'history-corrupt/raw/sources').glob('*.json'))
value = json.loads(path.read_bytes())
value['generations'][0]['prefix_sha256'] = '0' * 64
put(path, archive.json_bytes(value))
rejected('reject', 'history-corrupt', 'source-verify')
clone('bee', 'artifact-corrupt')
path = next((home / 'artifact-corrupt/vault/artifacts/tasks/demo--01-shared').glob('*/files/brief.md'))
put(path, 'modified artifact\n')
rejected('reject', 'artifact-corrupt', 'artifact-hash')
ok(True, 'changed records/files, guarded-id collisions, broken histories and edited artifacts reject before writes')

# Round 2: released source ids remain intact after namespacing, including in references.
clone('bee', 'released-id-source')
clone('original', 'released-id-dest')
released_id = 'AKIA' + 'PONMLKJIHGFEDCBA'
value = catalog('released-id-source')
value['sessions'][released_id] = dict(copy.deepcopy(value['sessions']['alpha']), id=released_id)
value['tasks']['demo--01-shared']['sessions'].append(released_id)
save_catalog('released-id-source', value)
put(home / 'released-id-dest/allowlist', 'sha256:' + archive.sha(released_id.encode()) + '\n')
assert verified('released-id-source')
data = report(imported('released-id-dest', 'released-id-source', 'bee'))
assert data['withheld_count'] == 0 and not data['withheld']
assert not catalog('released-id-dest')['hosts']['bee']['withheld']
assert catalog('released-id-dest')['sessions']['bee--' + released_id]['source_id'] == released_id
assert (home / 'released-id-dest/vault/sessions' / ('bee--' + released_id + '.md')).is_file()
fields, _ = archive.frontmatter((home / 'released-id-dest/vault/tasks/bee--demo--01-shared.md').read_text())
assert '[[sessions/bee--' + released_id + ']]' in fields['sessions']
assert 'commit: none' in imported('released-id-dest', 'released-id-source', 'bee')
before_files, before_records = host_files('released-id-dest'), host_records('released-id-dest')
run('released-id-dest', 'apply')
assert host_files('released-id-dest') == before_files and host_records('released-id-dest') == before_records
ok(verified('released-id-dest'), 'source_id preserves locally released ids across apply; imported files/records stay frozen and reports add no withheld items')

# Every reference must address the raw files import actually copies, even when verify
# accepts the same bytes under a hidden filename. Exercise all pointer-bearing inputs.
def hidden_blob(name, pointer):
    source = home / name / 'raw' / pointer['blob']
    hidden = source.parent / '.hidden.gz'
    put(hidden, source.read_bytes())
    pointer['blob'] = str(hidden.relative_to(home / name / 'raw'))

def replace_manifest(name, pointer, manifest):
    data = archive.json_bytes(manifest, compact=True)
    digest = archive.sha(data)
    rel = f'blobs/{digest[:2]}/{digest}.gz'
    put(home / name / 'raw' / rel, gzip.compress(data, mtime=0))
    pointer.update(blob=rel, sha256=digest, length=len(data))

for location in ('snapshot', 'session', 'task-entry', 'project-entry', 'history-chunk', 'history-tail'):
    source_name = 'hidden-' + location
    clone('bee', source_name)
    value = catalog(source_name)
    snapshot = next(iter(value['tasks']['demo--01-shared']['snapshots'].values()))
    if location == 'snapshot':
        hidden_blob(source_name, snapshot['manifest'])
    elif location == 'session':
        pointer = next(pointer for pointer in archive.pointer_values(value['sessions']['alpha']) if 'blob' in pointer)
        hidden_blob(source_name, pointer)
    elif location.endswith('-entry'):
        pointer = snapshot['manifest'] if location == 'task-entry' else value['projects']['demo']['manifests'][0]
        manifest = json.loads(gzip.decompress((home / source_name / 'raw' / pointer['blob']).read_bytes()))
        embedded = next(pointer for pointer in archive.pointer_values(manifest['entries']) if 'blob' in pointer)
        hidden_blob(source_name, embedded)
        replace_manifest(source_name, pointer, manifest)
    else:
        path = next((home / source_name / 'raw/sources').glob('*.json'))
        history = json.loads(path.read_bytes())
        generation = history['generations'][0]
        if location == 'history-tail':
            generation['tail'] = generation['chunks'].pop()
            prefix = b''.join(gzip.decompress((home / source_name / 'raw' / pointer['blob']).read_bytes())
                              for pointer in generation['chunks'])
            generation['prefix_sha256'] = archive.sha(prefix)
            hidden_blob(source_name, generation['tail'])
        else:
            hidden_blob(source_name, generation['chunks'][0])
        put(path, archive.json_bytes(history))
    save_catalog(source_name, value)
    assert verified(source_name), location
    rejected('reject', source_name, 'blob-name')
ok(True, 'noncanonical blob pointers in records, both manifest kinds, chunks and tails reject before writes')

clone('bee', 'extra-vault-pointer')
value = catalog('extra-vault-pointer')
value['sessions']['alpha']['fields']['extra'] = {'path': 'extra.txt', 'sha256': archive.sha(b'x\n')}
put(home / 'extra-vault-pointer/vault/extra.txt', b'x\n')
save_catalog('extra-vault-pointer', value)
assert verified('extra-vault-pointer')
rejected('reject', 'extra-vault-pointer', 'unsafe-path')
ok(True, 'vault pointers outside the copied artifact set reject before writes')

# Round 3: a source verify pass must not hide bad reused blobs or catalog-only pointers.
clone('original', 'damaged-local-blob')
bee_only = next(rel for rel in hashes(home / 'bee/raw')
                if rel.startswith('blobs/') and not (home / 'original/raw' / rel).exists())
put(home / 'damaged-local-blob/raw' / bee_only, b'garbage local blob\n')
assert verified('bee') and verified('damaged-local-blob')
rejected('damaged-local-blob', 'bee', 'local-blob')
ok(True, 'damaged unreferenced local blobs are refused before becoming imported references')

for source_name, reason in (('missing-catalog-blob', 'blob-missing'), ('short-catalog-blob', 'blob-length')):
    clone('bee', source_name)
    value = catalog(source_name)
    pointer = value['sessions']['alpha']['raw'][0]
    if reason == 'blob-missing':
        digest = archive.sha(b'not present in either raw store\n')
        pointer.update(sha256=digest, blob=f'blobs/{digest[:2]}/{digest}.gz')
        assert not (home / source_name / 'raw' / pointer['blob']).exists()
        assert not (home / 'reject/raw' / pointer['blob']).exists()
    else:
        pointer['length'] += 1
    value['generated'].remove('_meta/catalog.json')
    save_catalog(source_name, value)
    assert verified(source_name)
    rejected('reject', source_name, reason)
    ok(True, f'{reason} is detected even when the source generated list omits its catalog')

# A catalog-only pointer can also use a good local blob absent from the incoming store.
clone('bee', 'local-only-source')
clone('original', 'local-only-dest')
value = catalog('local-only-source')
payload = b'verified local-only content\n'
digest = archive.sha(payload)
rel = f'blobs/{digest[:2]}/{digest}.gz'
value['sessions']['alpha']['raw'][0].update(sha256=digest, blob=rel, length=len(payload))
value['generated'].remove('_meta/catalog.json')
save_catalog('local-only-source', value)
put(home / 'local-only-dest/raw' / rel, gzip.compress(payload, mtime=0))
assert verified('local-only-source') and verified('local-only-dest')
before = (home / 'local-only-dest/raw' / rel).read_bytes()
imported('local-only-dest', 'local-only-source', 'bee')
ok(verified('local-only-dest') and (home / 'local-only-dest/raw' / rel).read_bytes() == before,
   'a pointer can reuse a verified local-only blob without rewriting it')

clone('bee', 'rendered-broken-link')
value = catalog('rendered-broken-link')
snapshot = next(iter(value['tasks']['demo--01-shared']['snapshots'].values()))
snapshot['counts']['x [[nowhere]]'] = 1
save_catalog('rendered-broken-link', value)
assert verified('rendered-broken-link')
rejected('reject', 'rendered-broken-link', 'merged-verify')
rejected('reject', 'rendered-broken-link', 'merged-verify', 'bee', '--dry-run')
clone('original', 'escaped-link-dest')
put(home / 'outside-link', 'outside vault\n')
(home / 'escaped-link-dest/vault/nowhere').symlink_to(home / 'outside-link')
put(home / 'escaped-link-dest/vault/nowhere.md', 'an existing alias does not authorize an escaping target\n')
assert verified('escaped-link-dest')
rejected('escaped-link-dest', 'rendered-broken-link', 'merged-verify')
ok(True, 'rendered live links are checked before import and dry-run, independent of source notes')

clone('bee', 'rendered-bad-pointer')
value = catalog('rendered-bad-pointer')
artifact = next(rel for rel in value['generated'] if re.fullmatch(
    r'artifacts/tasks/demo--01-shared/[0-9a-f]{12}/files/brief.md', rel))
value['sessions']['alpha']['fields']['extra'] = {
    'path': artifact.replace('/demo--01-shared/', '/bee--demo--01-shared/', 1), 'sha256': '0' * 64}
value['generated'].remove('_meta/catalog.json')
save_catalog('rendered-bad-pointer', value)
assert verified('rendered-bad-pointer')
rejected('reject', 'rendered-bad-pointer', 'merged-verify')
ok(True, 'rendered pointers must match copied artifact bytes, even for catalog-only fields')

if have_encoder:
    clone('bee', 'secret-thumbnail')
    value = catalog('secret-thumbnail')
    thumbnail = next(iter(value['tasks']['demo--02-bee-only']['thumbnails'].values()))
    path = home / 'secret-thumbnail/vault' / thumbnail['path']
    data = path.read_bytes() + b'\n' + secret.encode() + b'\n'
    put(path, data)
    thumbnail.update(sha256=archive.sha(data), bytes=len(data))
    save_catalog('secret-thumbnail', value)
    assert verified('secret-thumbnail')
    rejected('reject', 'secret-thumbnail', 'artifact-secret')
    ok(all(secret.encode() not in p.read_bytes() for p in (home / 'reject/vault').rglob('*') if p.is_file()),
       'secret-shaped thumbnail bytes reject import without leaking into the destination vault')
else:
    skip('secret-shaped thumbnail bytes')

# Retained pointers must not pin shared pages that import is about to replace.
for location in ('catalog', 'note', 'top-level', 'other-host', 'json'):
    dest = 'retained-' + location
    clone('original', dest)
    if location == 'other-host':
        imported(dest, 'cat')
    receipt = {'path': './index.md', 'sha256': archive.sha((home / dest / 'vault/index.md').read_bytes())}
    value = catalog(dest)
    if location == 'note':
        path = home / dest / 'vault/tasks/demo--01-shared.md'
        fields, body = archive.frontmatter(path.read_text())
        fields['receipt'] = receipt
        put(path, archive.note(fields, body))
    elif location == 'json':
        rel = 'artifacts/projects/retained/raw.json'
        put(home / dest / 'vault' / rel, archive.json_bytes({'receipt': receipt}))
        value['generated'].append(rel)
        save_catalog(dest, value)
    else:
        if location == 'top-level':
            value['receipt'] = receipt
        else:
            owner = 'cat--demo' if location == 'other-host' else 'demo'
            value['projects'][owner]['receipt'] = receipt
        save_catalog(dest, value)
    assert verified(dest) and verified('bee'), location
    rejected(dest, 'bee', 'merged-verify')
    rejected(dest, 'bee', 'merged-verify', 'bee', '--dry-run')
    ok(True, f'retained {location} pointers to changed shared pages reject import and dry-run without writes')

# Unchanged shared pages may still be referenced by retained records.
clone('A', 'retained-unchanged')
value = catalog('retained-unchanged')
value['projects']['demo']['receipt'] = {
    'path': 'index.md', 'sha256': archive.sha((home / 'retained-unchanged/vault/index.md').read_bytes())}
save_catalog('retained-unchanged', value)
assert verified('retained-unchanged')
before = state('retained-unchanged', git=True)
data = report(imported('retained-unchanged', 'bee', 'bee', '--no-commit'))
ok(data['files']['changed_count'] == 0 and state('retained-unchanged', git=True) == before
   and verified('retained-unchanged'), 'retained pointers to unchanged shared pages allow a no-op import')

# Artifact filenames must be guarded even when a release exempts the compact catalog line.
clone('bee', 'secret-artifact-path')
rel = 'artifacts/roots/demo/000000000000/files/' + secret + '.md'
put(home / 'secret-artifact-path/vault' / rel, b'benign\n')
value = catalog('secret-artifact-path')
value['generated'].append(rel)
save_catalog('secret-artifact-path', value)
assert verified('secret-artifact-path')
for with_release in (True, False):
    dest = 'artifact-path-' + ('released' if with_release else 'control')
    clone('original', dest)
    if with_release:
        marker = 'AKIA' + 'PONMLKJIHGFEDCBA'
        value = catalog(dest)
        value['projects']['demo']['release_marker'] = marker
        save_catalog(dest, value)
        put(home / dest / 'allowlist', 'sha256:' + archive.sha(marker.encode()) + '\n')
    assert verified(dest)
    data = report(imported(dest, 'secret-artifact-path', 'bee', code=4))
    assert data['withheld_count'] >= 1 and data['incoming']['artifacts_withheld'] >= 1
    assert not data['rejected']['count'], data
    assert all(secret.encode() not in path.read_bytes() for path in (home / dest / 'vault').rglob('*') if path.is_file())
    ok(verified(dest), f'secret artifact paths are withheld with exit 4, no rejection or leak ({dest})')

# Syntax checks keep caches in the fixture home.
subprocess.run(['bash', '-n', str(repo / 'tests/test-archive.sh')], check=True)
subprocess.run(['python3', '-m', 'py_compile', str(command), str(repo / 'lib/orch_archive.py')], check=True,
               env=dict(os.environ, PYTHONPYCACHEPREFIX=str(home / 'compile-cache')))
ok(True, 'shell and Python syntax checks pass')
print(f'PASS: {groups} import test groups; SKIPPED: {len(skipped)}')
PY
