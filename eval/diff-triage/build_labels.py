#!/usr/bin/env python3
"""Map corpus rows to head-diff files, keeping all private detail out of tree."""
import sys
sys.dont_write_bytecode = True

import argparse
from collections import Counter
import csv
import json
import os
from pathlib import Path
import re

import triage_lib as lib

PATH_RE = re.compile(r'(?<![\w./-])((?:[\w.-]+/)*[\w.-]+\.(?:py|sh|md|json|jsonl|conf|toml|yml|yaml|txt|csv)|bin/[\w.-]+|hooks/[\w.-]+)(?::\d+)?')
SOURCE_RE = re.compile(r'^(.*?)(?::([1-9]\d*)(?:-([1-9]\d*))?)?$')


def citations(sources, root, universe, missing):
    bounded, unbounded = set(), set()
    for source in sources.split(';'):
        if not source.strip():
            continue
        match = SOURCE_RE.fullmatch(source.strip())
        if not match:
            raise ValueError('invalid source citation')
        relative, start, end = match.groups()
        path = (root / relative).resolve()
        if root not in path.parents:
            raise ValueError('source citation escapes corpus root')
        if not path.is_file():
            missing.add(path)
            continue
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        if start:
            last = int(end or start)
            if last < int(start):
                raise ValueError('invalid source range')
            text = '\n'.join(lines[int(start) - 1:last])
            bounded.update(m[1] for m in PATH_RE.finditer(text) if m[1] in universe)
        else:
            unbounded.update(m[1] for m in PATH_RE.finditer('\n'.join(lines)) if m[1] in universe)
    return bounded, unbounded


def map_row(e1, unbounded, strong, weak, status):
    corroborated = e1 & (strong | weak)
    if corroborated:
        files, confidence, methods = corroborated, 'high', ['E1', 'E2']
    elif strong:
        files, confidence, methods = strong, 'medium', ['E2-strong']
    elif e1:
        files, confidence, methods = e1, 'low', ['E1']
    elif weak or unbounded:
        files, confidence = weak | unbounded, 'low'
        methods = (['E2-weak'] if weak else []) + (['E1-unbounded'] if unbounded else [])
    else:
        return [], None, []
    return sorted(files), 'low' if status == 'H' else confidence, methods


def build(repo, tabulation, manifest, root):
    cases = lib.load_manifest(manifest, repo)
    by_task = {row['task']: row for row in cases}
    evidence = {}
    for case in cases:
        files = lib.input_files(lib.build_scorer_input(repo, case['base'], case['head']))
        universe = {f['path'] for f in files}
        strong, weak = set(), set()
        if case['status'] != 'U' and case['fix'] != '-':
            fixes = lib.input_files(lib.build_scorer_input(repo, case['head'], case['fix']))
            for f in fixes:
                path = f['old_path'] or f['path']
                if path not in universe or f['binary']:
                    continue
                if f['removed']:
                    strong.add(path)
                elif f['added']:
                    weak.add(path)
        evidence[case['case']] = (universe, strong, weak)
    with Path(tabulation).open(newline='', encoding='utf-8') as stream:
        rows = list(csv.DictReader(stream))
    labels, missing = [], set()
    for row in rows:
        case = by_task.get(row['task'])
        label = dict(id=row['id'], case=case['case'] if case else None, decision='excluded',
                     reason=None, confidence=None, files=[], methods=[])
        if row['stage'] == 'design':
            reason = 'design-stage'
        elif row['disposition'] == 'rejected':
            reason = 'rejected'
        elif case is None:
            reason = 'task-not-in-manifest'
        elif case['status'] == 'U':
            reason = 'head-not-recoverable'
        elif row['stage'] != 'diff' or row['first_round'] != case['head_round']:
            reason = 'not-first-reported-at-head'
        else:
            universe, strong, weak = evidence[case['case']]
            e1, unbounded = citations(row['sources'], root, universe, missing)
            files, confidence, methods = map_row(e1, unbounded, strong, weak, case['status'])
            reason = None if files else 'no-in-diff-file-evidence'
            label.update(files=files, confidence=confidence, methods=methods,
                         decision='mapped' if files else 'excluded')
        label['reason'] = reason
        labels.append(label)
    diffs = []
    for case in cases:
        universe, _, _ = evidence[case['case']]
        primary_universe = {p for p in universe if not lib.is_test(p)}
        mapped = [r for r in labels if r['case'] == case['case'] and r['decision'] == 'mapped']
        union = lambda levels: {p for r in mapped if r['confidence'] in levels for p in r['files']}
        primary = union({'high', 'medium'}) & primary_universe
        high = union({'high'}) & primary_universe
        sensitivity = union({'high', 'medium', 'low'})
        usable = lambda u, d: len(u) >= 3 and 1 <= len(d) < len(u)
        diffs.append(dict(case=case['case'], N=len(primary_universe), files=sorted(universe),
                          primary_files=sorted(primary_universe), primary_defective=sorted(primary),
                          high_only_defective=sorted(high), sensitivity_defective=sorted(sensitivity),
                          usable_primary=usable(primary_universe, primary),
                          usable_high_only=usable(primary_universe, high),
                          usable_sensitivity=usable(universe, sensitivity)))
    counts = {'rows total': len(labels), 'rows mapped': sum(r['decision'] == 'mapped' for r in labels),
              'exclusions': dict(sorted(Counter(r['reason'] for r in labels if r['reason']).items())),
              'confidence': dict(sorted(Counter(r['confidence'] for r in labels if r['confidence']).items())),
              'mapped rows by method': dict(sorted(Counter(m for r in labels for m in r['methods']).items())),
              'usable diffs': {s: sum(r['usable_' + s] for r in diffs)
                               for s in ('primary', 'high_only', 'sensitivity')},
              'missing-source files': len(missing)}
    return labels, diffs, counts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=lib.CLONE)
    parser.add_argument('--tabulation', type=Path)
    parser.add_argument('--manifest', type=Path, default=lib.CLONE / 'eval/diff-triage/manifest.tsv')
    parser.add_argument('--root', type=Path, default=os.environ.get('GATE_AB_ROOT'))
    parser.add_argument('--out', type=Path, default=lib.default_out())
    parser.add_argument('--note', type=Path)
    args = parser.parse_args(argv)
    if args.root is None:
        parser.error('pass --root or set GATE_AB_ROOT')
    try:
        tabulation = args.tabulation or args.repo / 'eval/gate-ab/tabulation.csv'
        if args.note:
            lib.note_path(args.note)
        out = lib.ensure_out_dir(args.out)
        root = args.root.resolve(strict=True)
        before = lib.readonly_fingerprint(args.repo, lib.corpus_files(tabulation))
        provenance = {'mapping_version': 1, 'manifest_sha256': lib.sha256(args.manifest),
                      'tabulation_sha256': lib.sha256(tabulation), 'repo_head': before['head'],
                      'root': str(root), 'tabulation': str(tabulation.resolve())}
        labels, diffs, counts = build(args.repo, tabulation, args.manifest, root)
        for name, records in (('labels', labels), ('diffs', diffs)):
            lib.write_private(out / (name + '.jsonl'), lib.jsonl([{'provenance': provenance}, *records]))
        after = lib.readonly_fingerprint(args.repo, lib.corpus_files(tabulation))
        lines = [f'{k}: {json.dumps(v, sort_keys=True)}' for k, v in counts.items()]
        lines += ['corpus sha256 before: ' + json.dumps(before['corpus'], sort_keys=True),
                  'corpus sha256 after: ' + json.dumps(after['corpus'], sort_keys=True),
                  'unchanged: ' + ('yes' if before == after else 'no')]
        text = '\n'.join(lines) + '\n'
        print(text, end='')
        if before != after:
            return 3
        if args.note:
            lib.write_note(args.note, text)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        # Error classes are safe aggregates; corpus strings/paths stay private.
        print('build_labels.py: validation failed (' + type(error).__name__ + ')', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
