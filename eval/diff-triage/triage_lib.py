#!/usr/bin/env python3
"""Read-only diff inputs, frozen scorers, statistics, and guarded artifact IO."""
import sys
sys.dont_write_bytecode = True

import csv
import fnmatch
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import random
import re
import subprocess
import uuid

CLONE = Path(__file__).resolve().parents[2]
SEED = 20260921
REPLICATES = 2000
MANIFEST_FIELDS = ['case', 'task', 'base', 'head', 'head_round', 'fix', 'status', 'evidence']
DIFF_OPTIONS = ('--no-color', '--no-ext-diff', '--no-textconv', '-M',
                '--src-prefix=a/', '--dst-prefix=b/', '--no-relative')
SECURITY = re.compile(
    r'\b(subprocess|shell=True|os\.system|eval|exec|chmod|chown|sudo|rm\s+-rf|curl|wget|'
    r'socket|token|secret|password|credential|api[_-]?key|permission|allow|deny|sandbox|guard)\b|--force',
    re.I)
_COMMON = None


def load_common():
    global _COMMON
    if _COMMON is None:
        spec = importlib.util.spec_from_file_location(
            'jev_phase0_common', CLONE / 'eval/jev-phase0/common.py')
        _COMMON = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_COMMON)
    return _COMMON


def git(repo, *args, binary=False):
    allowed = {'rev-parse', 'cat-file', 'diff', 'log', 'merge-base', 'for-each-ref', 'status'}
    if not args or args[0] not in allowed:
        raise ValueError('only read-only git commands are allowed')
    if args[0] == 'status' and not any(a.startswith('--porcelain') for a in args):
        raise ValueError('status requires --porcelain')
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', LC_ALL='C',
               GIT_LITERAL_PATHSPECS='1')
    result = subprocess.run(['git', '-C', str(repo), *map(str, args)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        # Do not copy corpus paths or content from Git's diagnostics into aggregate logs.
        raise ValueError('read-only git command failed: ' + args[0])
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace').strip()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_scorer_input(repo, base, head):
    """No labels, fix identifiers, reports, or history beyond base/head enter here."""
    statuses = {}
    tokens = iter(git(repo, 'diff', *DIFF_OPTIONS, '--name-status', '-z', base, head,
                      binary=True).split(b'\0')[:-1])
    for token in tokens:
        status = token.decode('ascii')
        old = next(tokens).decode('utf-8')
        path = next(tokens).decode('utf-8') if status.startswith('R') else old
        statuses[path] = (status, old if status.startswith('R') else None)
    tokens = iter(git(repo, 'diff', *DIFF_OPTIONS, '--numstat', '-z', base, head,
                      binary=True).split(b'\0')[:-1])
    files = []
    for token in tokens:
        added, removed, name = token.split(b'\t', 2)
        if not name:  # -z rename: counts<TAB><NUL>old<NUL>new<NUL>
            next(tokens)
            name = next(tokens)
        path = name.decode('utf-8')
        status, old = statuses[path]
        binary = added == b'-' or removed == b'-'
        paths = [old, path] if old else [path]
        patch = '' if binary else git(repo, 'diff', *DIFF_OPTIONS, '-U3', base, head,
                                       '--', *paths, binary=True).decode('utf-8', errors='replace')
        files.append(dict(path=path, old_path=old, status=status,
                          added=0 if binary else int(added), removed=0 if binary else int(removed),
                          binary=binary, patch=patch))
    return canonical({'schema': 'diff-triage-input/1',
                      'files': sorted(files, key=lambda f: f['path'].encode())})


def input_files(input_bytes):
    data = json.loads(input_bytes)
    if data['schema'] != 'diff-triage-input/1':
        raise ValueError('unsupported scorer input schema')
    return data['files']


def is_test(path):
    name = PurePosixPath(path).name
    return (path.startswith(('tests/', 'test/')) or
            any(fnmatch.fnmatchcase(name, p) for p in ('test_*', 'test-*', '*_test.*', '*.test.*')))


def path_class(path):
    name = PurePosixPath(path).name
    ext = PurePosixPath(path).suffix
    if is_test(path):
        return 'test', 0
    if (path.startswith(('bin/', 'hooks/', 'lib/')) or
        name in {'guardrails.json', 'install.sh', 'build-roster.sh', 'build-roster-runtime.sh', 'sync-to.sh'} or
            ('policy' in name and ext in {'.conf', '.json'})):
        return 'runtime', 3
    if path.startswith(('agents/', 'templates/', 'skills/')):
        return 'prompt', 1
    if ext in {'.md', '.txt', '.rst'}:
        return 'docs', 0
    if ext in {'.py', '.sh', '.js', '.ts', '.go', '.rs', '.rb', '.pl', '.bash'}:
        return 'code', 2
    if ext in {'.json', '.jsonl', '.conf', '.toml', '.yml', '.yaml', '.ini', '.cfg'}:
        return 'config', 1
    return 'other', 1


def added_lines(patch):
    # Only hunk contents: a real added line beginning '++' is not a file header.
    in_hunk = False
    for line in patch.splitlines():
        if line.startswith('diff --git '):
            in_hunk = False
        elif line.startswith('@@ '):
            in_hunk = True
        elif in_hunk and line.startswith('+'):
            yield line[1:]


def score_s1(input_bytes):
    return {f['path']: f['added'] + f['removed'] for f in input_files(input_bytes)}


def score_s2(input_bytes):
    files = input_files(input_bytes)
    tests = [line for f in files if is_test(f['path']) for line in added_lines(f['patch'])]
    scores = {}
    for f in files:
        path = f['path']
        kind, value = path_class(path)
        lines = list(added_lines(f['patch']))
        count = sum(bool(line.strip()) and not line.strip().startswith(('#', '//', '/*', '*', '--', ';'))
                    for line in lines) if kind in {'runtime', 'code', 'test', 'config'} else 0
        name = PurePosixPath(path).name
        stem = name.split('.', 1)[0]
        scores[path] = (value + int(count >= 1) + int(count >= 20)
                        + int(any(SECURITY.search(line) for line in lines))
                        + int('policy' in name or name == 'guardrails.json')
                        - int(not is_test(path) and len(stem) >= 3 and any(stem in line for line in tests)))
    return scores


def rank(input_bytes, scores):
    size = score_s1(input_bytes)
    if set(scores) != set(size) or any(not math.isfinite(s) for s in scores.values()):
        raise ValueError('scores must cover every file with finite values')
    return sorted(size, key=lambda path: (-scores[path], -size[path], path.encode()))


def random_orders(input_bytes, seed=SEED):
    digest = hashlib.sha256(input_bytes).digest()
    paths = [f['path'] for f in input_files(input_bytes)]
    for r in range(1000):
        yield sorted(paths, key=lambda path: (
            hashlib.sha256(f'{seed}:{r}:{path}'.encode() + digest).hexdigest(), path.encode()))


def score_s0(input_bytes, seed=SEED):
    """Scores for S0's first strict order; evaluation averages random_orders()."""
    return {path: -float(index) for index, path in enumerate(next(random_orders(input_bytes, seed)))}


def metrics(order, defective):
    defective = set(defective)
    n = len(order)
    if len(set(order)) != n or not defective <= set(order) or not (0 < len(defective) < n):
        raise ValueError('metrics require a strict order and a nonempty proper defective subset')
    first = next(i for i, path in enumerate(order, 1) if path in defective)
    return {'recall@1': len(defective & set(order[:1])) / len(defective),
            'recall@3': len(defective & set(order[:min(3, n)])) / len(defective),
            'recall@k20': len(defective & set(order[:max(1, math.ceil(.2 * n))])) / len(defective),
            'first_rank': first, 'normalized_first_rank': (first - 1) / (n - len(defective))}


def mean_metrics(rows):
    return {k: math.fsum(row[k] for row in rows) / len(rows) for k in rows[0]} if rows else {}


def percentile(values, fraction):
    values = sorted(values)
    h = (len(values) - 1) * fraction
    lo, hi = math.floor(h), math.ceil(h)
    return values[lo] + (values[hi] - values[lo]) * (h - lo)


def bootstrap_delta(candidate, reference, seed=SEED):
    if len(candidate) != len(reference):
        raise ValueError('paired samples must have equal length')
    if len(candidate) < 10:
        return None
    delta = [c - r for c, r in zip(candidate, reference)]
    rng = random.Random(seed)
    values = [math.fsum(delta[i] for i in rng.choices(range(len(delta)), k=len(delta))) / len(delta)
              for _ in range(REPLICATES)]
    return {'mean': math.fsum(delta) / len(delta),
            'low': percentile(values, .025), 'high': percentile(values, .975)}


def verdict(n, comparisons):
    if n < 10:
        return 'inconclusive', 'fewer than 10 usable diffs'
    if any(c['S1']['mean'] >= .10 and c['S1']['low'] > 0 and c['S0']['low'] > 0
           for c in comparisons.values()):
        return 'worth designing an advisory hint', 'candidate meets all primary thresholds'
    if comparisons and all(c['S1']['high'] < .10 for c in comparisons.values()):
        return 'do not build', 'every candidate upper bound versus S1 is below 0.10'
    return 'inconclusive', 'primary thresholds not resolved'


def default_out():
    return load_common().state_dir() / 'diff-triage'


def ensure_out_dir(path):
    common = load_common()
    target = common.assert_out_of_tree(path)
    common.assert_out_of_tree(target / '.containment-probe')
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    return target


def write_private(path, data):
    path = Path(path)
    common = load_common()
    common.assert_out_of_tree(path)
    if path.is_symlink():
        raise ValueError('refusing output-file symlink')
    parent = ensure_out_dir(path.parent)
    target = parent / path.name
    temp = parent / ('.triage-' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data.encode('utf-8') if isinstance(data, str) else data)
        common.assert_out_of_tree(target)
        if target.is_symlink():
            raise ValueError('refusing output-file symlink')
        os.replace(temp, target)
        common.assert_out_of_tree(target)
    finally:
        if temp.exists():
            temp.unlink()


def note_path(path):
    target = Path(path).resolve()
    allowed = CLONE / 'eval/diff-triage/evidence'
    if allowed not in target.parents or target.suffix != '.md' or Path(path).is_symlink():
        raise ValueError('aggregate note must be an .md inside the approved evidence directory')
    return target


def write_note(path, text):
    target = note_path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    note_path(target).write_text(text, encoding='utf-8')


def readonly_fingerprint(repo, files):
    return {'corpus': {str(i): sha256(path) if Path(path).is_file() else None
                       for i, path in enumerate(files)},
            'head': git(repo, 'rev-parse', 'HEAD'),
            'refs': hashlib.sha256(git(repo, 'for-each-ref', '--format=%(refname) %(objectname)', binary=True)).hexdigest(),
            'status': hashlib.sha256(git(repo, 'status', '--porcelain=v1', '-z',
                                         '--untracked-files=all', '--ignored=matching', binary=True)).hexdigest()}


def corpus_files(tabulation):
    tabulation = Path(tabulation)
    inventory = tabulation.with_name('inventory.csv')
    return [tabulation] + ([inventory] if inventory.exists() else [])


def load_manifest(path, repo, validate=True):
    with Path(path).open(newline='', encoding='utf-8') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != MANIFEST_FIELDS:
            raise ValueError('invalid manifest header')
        rows = list(reader)
    if len({r['case'] for r in rows}) != len(rows) or len({r['task'] for r in rows}) != len(rows):
        raise ValueError('duplicate manifest case or task')
    for row in rows:
        if (None in row or any(not row[k] for k in MANIFEST_FIELDS) or
                row['status'] not in {'P', 'G', 'H', 'U'} or row['head_round'] != 'r1'):
            raise ValueError('invalid manifest row')
        # G can have a verified head without a task fix (the documented J08 case).
        # Such a row gets citation-only evidence, hence no primary labels.
        if row['fix'] == '-' and row['status'] not in {'G', 'U'}:
            raise ValueError('missing fix for protocol or history-only candidate')
        if row['status'] == 'U' and row['fix'] != '-':
            raise ValueError('unrecoverable heads must not supply fix evidence')
        for key in ('base', 'head', 'fix'):
            if key == 'fix' and row[key] == '-':
                continue
            if not re.fullmatch('[0-9a-f]{40}', row[key]):
                raise ValueError('manifest requires full commit SHAs')
            if validate:
                git(repo, 'cat-file', '-e', row[key] + '^{commit}')
        if validate:
            git(repo, 'merge-base', '--is-ancestor', row['base'], row['head'])
            if row['fix'] != '-':
                if row['fix'] == row['head']:
                    raise ValueError('fix must follow head')
                git(repo, 'merge-base', '--is-ancestor', row['head'], row['fix'])
                if not git(repo, 'log', '-1', '--format=%s', row['fix']).startswith('fix('):
                    raise ValueError('fix subject must start with fix(')
                fixes = git(repo, 'log', '--reverse', '--ancestry-path', '--format=%H\t%s',
                            row['head'] + '..' + row['fix']).splitlines()
                first = next((line.split('\t', 1)[0] for line in fixes
                              if line.split('\t', 1)[1].startswith('fix(')), None)
                if first != row['fix']:
                    raise ValueError('fix is not the first fix commit after head')
    return rows


def jsonl(records):
    return b''.join(canonical(row) + b'\n' for row in records)
