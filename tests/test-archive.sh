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
put(checkpoint_task / 'small.png', b'P')
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
assert next(e for e in checkpoint_entries if e['relpath'] == 'small.png')['kind'] == 'raw'
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
