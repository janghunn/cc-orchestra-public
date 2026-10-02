#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIAGE_TMP="$(mktemp -d /tmp/diff-triage-test.XXXXXXXX)"
trap 'rm -rf "$TRIAGE_TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export CC_ORCH_STATE_DIR="$TRIAGE_TMP/state"
export CC_ORCH_CLI_AUTO_UPDATE=0
export GIT_OPTIONAL_LOCKS=0
export PYTHONPATH="$ROOT/eval/diff-triage"
export TRIAGE_ROOT="$ROOT" TRIAGE_TMP
python3 - <<'PY'
import ast
import csv
from contextlib import redirect_stdout
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
from unittest.mock import patch

import triage_lib as lib
import build_labels
import run_eval
import s3_local

ROOT = Path(os.environ['TRIAGE_ROOT'])
TMP = Path(os.environ['TRIAGE_TMP'])
REPO = TMP / 'repo'
CORPUS = TMP / 'corpus'
OUT = TMP / 'out'
MODULES = ROOT / 'eval/diff-triage'
COUNT = 0


def ok(name):
    global COUNT
    COUNT += 1
    print(f'ok {COUNT} - {name}', flush=True)


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def fixture_git(*args, repo=REPO):
    # Mutating Git commands below operate exclusively on this throwaway repository.
    assert TMP in repo.resolve().parents
    return subprocess.check_output(['git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null',
                                    '-c', 'commit.gpgSign=false', '-c', 'user.name=Fixture',
                                    '-c', 'user.email=fixture@example.invalid', *args],
                                   stderr=subprocess.PIPE).decode().strip()


def commit(message, repo=REPO):
    fixture_git('add', '.', repo=repo)
    fixture_git('commit', '-m', message, repo=repo)
    return fixture_git('rev-parse', 'HEAD', repo=repo)


def cli(script, *args, env=None):
    return subprocess.run([sys.executable, str(MODULES / script), *map(str, args)],
                          capture_output=True, text=True, timeout=90, env=env)


def passed(result):
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    return result


REPO.mkdir()
fixture_git('init')
initial = {'bin/tool': '#!/usr/bin/env python3\nold = 0\n',
           'hooks/guard.sh': '# guard\nallow=old\n', 'README.md': '# Fixture\n',
           'tests/test-tool.sh': '#!/bin/sh\n', 'docs/notes.md': 'old notes\n',
           'config/app-policy.conf': 'mode=old\n', 'blob.dat': b'\0old',
           'assets/old ü.txt': 'rename me\n'}
for path, content in initial.items():
    put(REPO / path, content)
BASE = commit('base')
put(REPO / 'bin/tool', initial['bin/tool'] + 'import subprocess\n' + ''.join(f'value{i} = {i}\n' for i in range(29)))
put(REPO / 'hooks/guard.sh', '# guard\ndeny=new\n')
put(REPO / 'README.md', initial['README.md'] + ''.join(f'Prose line {i}.\n' for i in range(40)))
put(REPO / 'tests/test-tool.sh', '#!/bin/sh\necho tool\n')
put(REPO / 'docs/notes.md', '# just a comment\n')
put(REPO / 'config/app-policy.conf', 'mode=new\n')
put(REPO / 'blob.dat', b'\0new')
(REPO / 'assets/old ü.txt').rename(REPO / 'assets/new ü.txt')
HEAD = commit('head')
SENTINEL = 'FIXSENTINEL-' + uuid.uuid4().hex
put(REPO / 'hooks/guard.sh', '# guard\nallow=fixed # ' + SENTINEL + '\n')
FIX = commit('fix(test): guard finding')
DATA = lib.build_scorer_input(REPO, BASE, HEAD)
S1 = ['README.md', 'bin/tool', 'config/app-policy.conf', 'docs/notes.md', 'hooks/guard.sh',
      'tests/test-tool.sh', 'assets/new ü.txt', 'blob.dat']
assert lib.rank(DATA, lib.score_s1(DATA)) == S1
assert next(f for f in lib.input_files(DATA) if f['path'] == 'blob.dat') == {
    'path': 'blob.dat', 'old_path': None, 'status': 'M', 'added': 0, 'removed': 0,
    'binary': True, 'patch': ''}
rename = next(f for f in lib.input_files(DATA) if f['old_path'])
assert rename['old_path'] == 'assets/old ü.txt' and rename['path'] == 'assets/new ü.txt'
ok('S1 hand-computed order, binary counts and Unicode rename')

assert lib.score_s2(DATA) == {'README.md': 0, 'bin/tool': 5, 'config/app-policy.conf': 5,
    'docs/notes.md': 0, 'hooks/guard.sh': 5, 'tests/test-tool.sh': 1, 'assets/new ü.txt': 0, 'blob.dat': 1}
assert lib.rank(DATA, lib.score_s2(DATA)) == ['bin/tool', 'config/app-policy.conf', 'hooks/guard.sh',
    'tests/test-tool.sh', 'blob.dat', 'README.md', 'docs/notes.md', 'assets/new ü.txt']
for path in ('tests/a', 'test/a', 'a/test_thing.py', 'test-thing', 'a/thing_test.py', 'a/thing.test.js'):
    assert lib.is_test(path)
assert lib.path_class('templates/prompt.md') == ('prompt', 1)
assert lib.path_class('thing.py') == ('code', 2)
ok('S2 hand-computed integer scores, class precedence and ranking')

ORDERS = list(lib.random_orders(DATA))
assert len(ORDERS) == 1000 and ORDERS == list(lib.random_orders(DATA))
assert lib.rank(DATA, lib.score_s0(DATA)) == ORDERS[0]
assert ORDERS[0] != next(lib.random_orders(DATA, 19))
mean1 = lib.mean_metrics([lib.metrics(o, {'hooks/guard.sh'}) for o in ORDERS])
mean2 = lib.mean_metrics([lib.metrics(o, {'hooks/guard.sh'}) for o in lib.random_orders(DATA)])
assert mean1 == mean2
ok('S0 seeded orders and mean metrics are reproducible')

m = lib.metrics(list('abcdefg'), {'b', 'f'})
assert m == {'recall@1': 0, 'recall@3': .5, 'recall@k20': .5, 'first_rank': 2, 'normalized_first_rank': .2}
assert lib.metrics(list('abcd'), {'d'})['normalized_first_rank'] == 1
assert lib.metrics(list('abc'), {'a', 'b'})['recall@3'] == 1
ok('recall, k20, first rank and normalized first rank arithmetic')

TIE = lib.canonical({'schema': 'diff-triage-input/1', 'files': [
    dict(path=p, old_path=None, status='M', added=2, removed=1, binary=False,
         patch='@@ -1 +1,2 @@\n-old\n+new\n+next\n') for p in ('z.py', 'a.py')]})
assert lib.rank(TIE, lib.score_s1(TIE)) == ['a.py', 'z.py']
assert lib.rank(TIE, lib.score_s2(TIE)) == ['a.py', 'z.py']
ok('S1 and S2 equal-score ties use ascending paths')

# Exact expected bytes for a separate minimal fixture; no implementation helper
# computes the expected patch, schema, blob prefix or serialization.
MINI = TMP / 'exact-repo'
MINI.mkdir()
fixture_git('init', repo=MINI)
fixture_git('commit', '--allow-empty', '-m', 'empty', repo=MINI)
mini_base = fixture_git('rev-parse', 'HEAD', repo=MINI)
put(MINI / 'a.txt', 'hello\n')
mini_head = commit('add greeting', repo=MINI)
EXPECTED = (b'{"files":[{"added":1,"binary":false,"old_path":null,"patch":"diff --git a/a.txt b/a.txt\\n'
 b'new file mode 100644\\nindex 0000000..ce01362\\n--- /dev/null\\n+++ b/a.txt\\n@@ -0,0 +1 @@\\n+hello\\n",'
 b'"path":"a.txt","removed":0,"status":"A"}],"schema":"diff-triage-input/1"}')
assert lib.build_scorer_input(MINI, mini_base, mini_head) == EXPECTED
for forbidden in (SENTINEL, 'FINDINGSENTINEL', BASE, HEAD, FIX, mini_base, mini_head):
    assert forbidden.encode() not in DATA + EXPECTED
payloads = []
def transport(payload):
    payloads.append(payload)
    text = json.dumps(payload)
    assert SENTINEL not in text and 'FINDINGSENTINEL' not in text
    assert all(sha not in text for sha in (BASE, HEAD, FIX))
    prob = .8 if 'Path: hooks/guard.sh\n' in payload['messages'][0]['content'] else .2
    return {'model': payload['model'], 'choices': [{'logprobs': {'content': [{'top_logprobs': [
        {'token': 'A', 'logprob': math.log(prob)}, {'token': 'B', 'logprob': math.log(1-prob)}]}]}}]}
scores = s3_local.run(DATA, transport)
assert len(payloads) == 8
assert all(p['max_tokens'] == 1 and p['top_logprobs'] == 20 and
           p['chat_template_kwargs'] == {'enable_thinking': False} for p in payloads)
ok('exact scorer-input bytes and no finding, fix or SHA leakage to fake S3')

# Additional task snapshots supply citation-only and pure-addition mapping cases.
# The first task fix changes an existing line; the next fix only appends to a file.
put(REPO / 'docs/notes.md', '# just a comment\nnew guidance\n')
WEAK_FIX = commit('fix(test): append guidance')
MANIFEST = TMP / 'manifest.tsv'
rows = [dict(zip(lib.MANIFEST_FIELDS, values)) for values in [
    ['J01', 'tasks/one', BASE, HEAD, 'r1', FIX, 'G', 'synthetic:1'],
    ['C01', 'tasks/two', BASE, FIX, 'r1', WEAK_FIX, 'G', 'synthetic:1'],
    ['S01', 'tasks/history', BASE, HEAD, 'r1', FIX, 'H', 'git-history'],
    ['S02', 'tasks/unrecoverable', BASE, HEAD, 'r1', '-', 'U', 'synthetic:1']]]
with MANIFEST.open('w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=lib.MANIFEST_FIELDS, delimiter='\t', lineterminator='\n')
    w.writeheader(); w.writerows(rows)
put(CORPUS / 'report.md', 'FINDINGSENTINEL hooks/guard.sh:2\nbin/tool:2\nnot a repo path\n')
TAB = REPO / 'eval/gate-ab/tabulation.csv'
TAB.parent.mkdir(parents=True)
fields = ['id', 'task', 'stage', 'disposition', 'first_round', 'sources']
corpus_rows = [
 ['high', 'tasks/one', 'diff', 'fixed', 'r1', 'report.md:1'],
 ['medium', 'tasks/one', 'diff', 'fixed', 'r1', 'missing.md:1'],
 ['low', 'tasks/two', 'diff', 'accepted', 'r1', 'report.md:2'],
 ['design', 'tasks/one', 'design', 'fixed', 'r1', 'report.md:1'],
 ['rejected', 'tasks/one', 'diff', 'rejected', 'r1', 'report.md:1'],
 ['later', 'tasks/one', 'diff', 'fixed', 'r2', 'report.md:1'],
 ['post', 'tasks/one', 'post-merge', 'fixed', 'r1', 'report.md:1'],
 ['history', 'tasks/history', 'diff', 'fixed', 'r1', 'report.md:1'],
 ['unrecoverable', 'tasks/unrecoverable', 'diff', 'fixed', 'r1', 'report.md:1'],
 ['unknown', 'tasks/missing', 'diff', 'fixed', 'r1', 'report.md:1'],
 ['weak', 'tasks/two', 'diff', 'fixed', 'r1', 'report.md:3'],
 ['unbounded', 'tasks/two', 'diff', 'fixed', 'r1', 'report.md']]
with TAB.open('w', newline='') as f:
    w = csv.writer(f); w.writerow(fields); w.writerows(corpus_rows)
put(TAB.with_name('inventory.csv'), 'task\ntasks/one\n')
# Register the synthetic sibling before the fingerprint; no user repository refs change.
SIBLING = TMP / 'registered sibling'
fixture_git('worktree', 'add', '--detach', str(SIBLING), 'HEAD')
BEFORE = lib.readonly_fingerprint(REPO, [TAB, TAB.with_name('inventory.csv')])
INDEX_MTIME = (REPO / '.git/index').stat().st_mtime_ns
build_args = ['--repo', REPO, '--manifest', MANIFEST, '--root', CORPUS, '--out', OUT]
built = passed(cli('build_labels.py', *build_args))
eval_args = ['--repo', REPO, '--manifest', MANIFEST, '--labels-dir', OUT, '--out', OUT, '--s3', 'off']
first = passed(cli('run_eval.py', *eval_args))
first_bytes = (OUT / 'results.jsonl').read_bytes()
second = passed(cli('run_eval.py', *eval_args))
assert first_bytes == (OUT / 'results.jsonl').read_bytes()
def stable(text):
    return '\n'.join(line for line in text.splitlines() if not line.startswith(('runtime seconds:', 'peak RSS')))
assert stable(first.stdout) == stable(second.stdout)
assert 'S3 skipped: disabled by --s3 off' in first.stdout
ok('two complete evaluations produce identical results and stable aggregate stdout')

LINK = TMP / 'clone-link'
LINK.symlink_to(ROOT, target_is_directory=True)
for bad in (REPO / 'bad-output', ROOT / 'bad-triage-output', SIBLING / 'bad-output', LINK / 'bad-output', REPO):
    existed = bad.exists()
    for script, args in (('build_labels.py', build_args), ('run_eval.py', eval_args)):
        result = cli(script, *args, '--out', bad)
        assert result.returncode == 2, (bad, result)
    assert bad.exists() == existed
bad_note = TMP / 'note.md'
for script, args in (('build_labels.py', build_args), ('run_eval.py', eval_args)):
    assert cli(script, *args, '--note', bad_note).returncode == 2
assert not bad_note.exists()
ok('outputs refuse clone, evaluated repo, registered sibling and symlink; notes confined')

labels = {r['id']: r for r in map(json.loads, (OUT / 'labels.jsonl').read_text().splitlines()[1:])}
assert labels['high']['confidence'] == 'high' and labels['high']['files'] == ['hooks/guard.sh']
assert labels['medium']['confidence'] == 'medium' and labels['medium']['methods'] == ['E2-strong']
assert labels['low']['confidence'] == 'low' and labels['low']['files'] == ['bin/tool']
assert labels['history']['confidence'] == 'low'
assert labels['weak']['methods'] == ['E2-weak']
assert set(labels['unbounded']['methods']) == {'E2-weak', 'E1-unbounded'}
for key, reason in [('design', 'design-stage'), ('rejected', 'rejected'), ('later', 'not-first-reported-at-head'),
                    ('post', 'not-first-reported-at-head'), ('unknown', 'task-not-in-manifest'),
                    ('unrecoverable', 'head-not-recoverable')]:
    assert labels[key]['reason'] == reason
assert 'FINDINGSENTINEL' not in built.stdout and '/' not in built.stdout
assert '"primary": 1' in built.stdout
# Inclusive bounds and out-of-span citations; the whole report must not feed E1.
missing = set()
e1, unbounded = build_labels.citations('report.md:2-3', CORPUS.resolve(), {'bin/tool','hooks/guard.sh'}, missing)
assert e1 == {'bin/tool'} and not unbounded
assert build_labels.map_row(set(),set(),set(),set(),'G') == ([], None, [])
ok('high, medium, low, weak, history-capped labels and ordered exclusions')

assert lib.rank(DATA, scores) == ['hooks/guard.sh', *[p for p in S1 if p != 'hooks/guard.sh']]
spec = s3_local.launch_spec('7', TMP / 'server')
assert 'JEV_LOCAL_GPU="7"' in spec['policy_text']
assert f'JEV_LOCAL_SOCKET="{spec["socket"]}"' in spec['policy_text']
assert spec['env']['CC_ORCH_JEV_POLICY'] == str(spec['policy_path'])
assert spec['argv'] == [str(ROOT / 'bin/orch-jev-local'), 'serve']
assert not spec['policy_path'].exists()  # launch_spec is pure.
# Fake sleeping foreground server; mock socket readiness without creating any socket.
spec['argv'] = [sys.executable, '-c', 'import time; time.sleep(300)']
with patch.object(s3_local.stat, 'S_ISSOCK', return_value=True), \
     patch.object(Path, 'lstat', return_value=os.stat(TMP)):
    # lexists uses os.lstat, not Path.lstat, so collision checking remains real.
    with s3_local.server(spec) as process:
        pid = process.pid
        assert process.poll() is None
assert process.returncode is not None
try:
    os.kill(pid, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError('fake server left running')
assert not spec['policy_path'].exists()
# Startup failure must also terminate and reap the process.
with patch.object(s3_local.subprocess, 'Popen', wraps=subprocess.Popen) as spawned:
    try:
        with s3_local.server(spec, wait_seconds=0):
            raise AssertionError('unexpected readiness')
    except TimeoutError:
        pass
assert not spec['policy_path'].exists()
auto = passed(cli('run_eval.py', *eval_args, '--s3', 'auto'))
assert 'S3 skipped:' in auto.stdout and 'S3 mean metrics' not in auto.stdout
assert next(l for l in auto.stdout.splitlines() if l.startswith('verdict:')) == next(
    l for l in first.stdout.splitlines() if l.startswith('verdict:'))
print('S3 real local-model path: SKIPPED (fake transport only in tests)', flush=True)
ok('fake S3 probabilities, policy overrides, PID lifecycle and automatic skip')

reference = [0., 1., .25, .75, 0., .5, 1., .25, .75, 1., .5, 0.]
candidate = [v + .25 for v in reference]
ci = lib.bootstrap_delta(candidate, reference)
assert ci == {'mean': .25, 'low': .25, 'high': .25}
assert ci == lib.bootstrap_delta(candidate, reference)
assert lib.bootstrap_delta([.75]*12, [.25]*12) == {'mean': .5, 'low': .5, 'high': .5}
assert lib.bootstrap_delta([1]*9, [0]*9) is None
assert 'primary: INSUFFICIENT DATA' in first.stdout
assert lib.percentile([0, 10], .25) == 2.5
ok('deterministic paired bootstrap, degenerate deltas and insufficient groups')

comparison = lambda mean, low, high: {'mean': mean, 'low': low, 'high': high}
worth = {'S2': {'S1': comparison(.1,.01,.2), 'S0': comparison(.2,.01,.3)}}
no = {'S2': {'S1': comparison(0,-.1,.09), 'S0': comparison(0,-.1,.1)}}
unclear = {'S2': {'S1': comparison(.1,0,.2), 'S0': comparison(.2,.01,.3)}}
assert lib.verdict(9, worth) == ('inconclusive','fewer than 10 usable diffs')
assert lib.verdict(10, worth)[0] == 'worth designing an advisory hint'
assert lib.verdict(10, no)[0] == 'do not build'
assert lib.verdict(10, unclear)[0] == 'inconclusive'
assert lib.verdict(10, {'S2': no['S2'], 'S3': worth['S2']})[0] == 'worth designing an advisory hint'
ok('verdict precedence, strict CI boundaries and candidate inclusion')

for path in MODULES.glob('*.py'):
    tree = ast.parse(path.read_text())
    for node in ast.walk(tree):
        names = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module] if isinstance(node, ast.ImportFrom) else []
        assert not any(n and n.split('.')[0] in {'socket','urllib','http','requests','ftplib','smtplib','telnetlib','ssl'} for n in names)
    assert 'AF_INET' not in path.read_text()
local_text = (ROOT / 'bin/orch-jev-local').read_text()
assert 'socket.AF_UNIX' in local_text and 'AF_INET' not in local_text
ok('static egress check limits networking to the existing AF_UNIX transport')

assert lib.readonly_fingerprint(REPO, [TAB, TAB.with_name('inventory.csv')]) == BEFORE
assert (REPO / '.git/index').stat().st_mtime_ns == INDEX_MTIME
plain_env = dict(os.environ)
plain_env.pop('PYTHONDONTWRITEBYTECODE', None)
plain_env.pop('PYTHONPYCACHEPREFIX', None)
passed(cli('build_labels.py', *build_args, env=plain_env))
passed(cli('run_eval.py', *eval_args, env=plain_env))
assert not list(MODULES.rglob('__pycache__'))
private = TMP / 'symlink-output'
private.mkdir()
target = MODULES / 'criteria.md'
original = target.read_bytes()
(private / 'labels.jsonl').symlink_to(target)
assert cli('build_labels.py', *build_args, '--out', private).returncode == 2
assert target.read_bytes() == original
assert (private / 'labels.jsonl').is_symlink()
for file in OUT.iterdir():
    assert file.stat().st_mode & 0o777 == 0o600
original_manifest = MANIFEST.read_bytes()
MANIFEST.write_bytes(original_manifest + b'\n')
assert cli('run_eval.py', *eval_args).returncode == 2
MANIFEST.write_bytes(original_manifest)
original_labels = (OUT / 'diffs.jsonl').read_bytes()
(OUT / 'diffs.jsonl').write_bytes(b'\n'.join(original_labels.splitlines()[1:]) + b'\n')
assert cli('run_eval.py', *eval_args).returncode == 2
(OUT / 'diffs.jsonl').write_bytes(original_labels)
# A custom tabulation and its sibling inventory must be fingerprinted, not the
# default paths in the Git repository. Metadata is not an evaluation label.
custom_tab = TMP / 'custom-corpus/tabulation.csv'
put(custom_tab, TAB.read_bytes())
put(custom_tab.with_name('inventory.csv'), TAB.with_name('inventory.csv').read_bytes())
passed(cli('build_labels.py', *build_args, '--tabulation', custom_tab))
custom_run = passed(cli('run_eval.py', *eval_args))
assert 'unchanged: yes' in custom_run.stdout
passed(cli('build_labels.py', *build_args))
# A mid-run corpus mutation must suppress a verdict and return the distinct
# read-only violation code, not a stale-input validation code.
tab_bytes = TAB.read_bytes()
original_s1 = lib.score_s1
def mutate_after_snapshot(data):
    TAB.write_bytes(tab_bytes + b'\n')
    return original_s1(data)
captured = io.StringIO()
try:
    with patch.object(lib, 'score_s1', side_effect=mutate_after_snapshot), redirect_stdout(captured):
        assert run_eval.main(list(map(str, eval_args))) == 3
finally:
    TAB.write_bytes(tab_bytes)
assert 'unchanged: no' in captured.getvalue() and 'verdict:' not in captured.getvalue()
# Invalid fix subject, abbreviated SHA and non-descendant fix must fail closed.
for change in ({'fix': HEAD}, {'head': HEAD[:7]}, {'fix': BASE}, {'status': 'P', 'fix': '-'}):
    bad = [dict(row) for row in rows]
    bad[0].update(change)
    with MANIFEST.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=lib.MANIFEST_FIELDS,delimiter='\t');w.writeheader();w.writerows(bad)
    assert cli('build_labels.py', *build_args).returncode == 2
MANIFEST.write_bytes(original_manifest)
assert lib.readonly_fingerprint(REPO, [TAB, TAB.with_name('inventory.csv')]) == BEFORE
ok('read-only fingerprints, no bytecode, private modes, symlink refusal and provenance binding')

compile_env = dict(os.environ, PYTHONPYCACHEPREFIX=str(TMP / 'pycache'))
subprocess.run([sys.executable, '-m', 'py_compile', *map(str, sorted(MODULES.glob('*.py')))],
               env=compile_env, check=True)
ok('all four Python modules compile with an out-of-tree pycache')
print(f'PASS: {COUNT} diff-triage test groups', flush=True)
PY
