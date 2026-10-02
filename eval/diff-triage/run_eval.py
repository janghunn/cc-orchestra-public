#!/usr/bin/env python3
"""Score isolated head diffs, then load labels and apply frozen comparisons."""
import sys
sys.dont_write_bytecode = True

import argparse
import json
from pathlib import Path
import resource
import time

import triage_lib as lib


def read_provenance(path, manifest):
    """Read only the metadata header, never an evaluation label record."""
    with Path(path).open(encoding='utf-8') as stream:
        header = json.loads(stream.readline())
    if not isinstance(header.get('provenance'), dict):
        raise ValueError('missing provenance')
    provenance = header['provenance']
    if (provenance.get('mapping_version') != 1 or
            provenance.get('manifest_sha256') != lib.sha256(manifest) or
            provenance.get('tabulation_sha256') != lib.sha256(provenance['tabulation'])):
        raise ValueError('stale provenance')
    return provenance


def read_diffs(path, manifest):
    provenance = read_provenance(path, manifest)
    with Path(path).open(encoding='utf-8') as stream:
        rows = [json.loads(line) for line in stream if line.strip()]
    if not rows or rows[0].get('provenance') != provenance:
        raise ValueError('provenance changed during read')
    return rows[1:], provenance


def summarize(results, seed):
    groups = [('primary', 'primary', None), ('high-only', 'high_only', None),
              ('sensitivity', 'sensitivity', None)]
    groups += [('series ' + s, 'primary', s) for s in ('J', 'C', 'S')]
    lines, primary_comparisons, primary_n = [], {}, 0
    arms = sorted({r['arm'] for r in results})
    for name, stratum, series in groups:
        selected = [r for r in results if r['metrics'][stratum] is not None
                    and (series is None or r['case'].startswith(series))]
        by_arm = {arm: [r['metrics'][stratum] for r in selected if r['arm'] == arm] for arm in arms}
        n = len(by_arm['S1'])
        lines.append(f'{name}: usable diffs = {n}')
        for arm, metrics in by_arm.items():
            lines.append(f'{name} {arm} mean metrics: ' + json.dumps(lib.mean_metrics(metrics), sort_keys=True))
        comparisons = {}
        if n < 10:
            lines.append(name + ': INSUFFICIENT DATA')
        else:
            for arm in (a for a in arms if a in {'S2', 'S3'}):
                candidate = [m['recall@k20'] for m in by_arm[arm]]
                comparisons[arm] = {}
                for ref in ('S1', 'S0'):
                    delta = lib.bootstrap_delta(candidate, [m['recall@k20'] for m in by_arm[ref]], seed)
                    comparisons[arm][ref] = delta
                    lines.append(f'{name} {arm} - {ref}: ' + json.dumps(delta, sort_keys=True))
        if name == 'primary':
            primary_n, primary_comparisons = n, comparisons
    decision, reason = lib.verdict(primary_n, primary_comparisons)
    lines.append(f'verdict: {decision} ({reason})')
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=lib.CLONE)
    parser.add_argument('--manifest', type=Path, default=lib.CLONE / 'eval/diff-triage/manifest.tsv')
    parser.add_argument('--labels-dir', type=Path, default=lib.default_out())
    parser.add_argument('--out', type=Path, default=lib.default_out())
    parser.add_argument('--seed', type=int, default=lib.SEED)
    parser.add_argument('--s3', choices=['auto', 'off'], default='auto')
    parser.add_argument('--note', type=Path)
    args = parser.parse_args(argv)
    started = time.monotonic()
    try:
        if args.note:
            lib.note_path(args.note)
        out = lib.ensure_out_dir(args.out)
        # The header is metadata only. Its path selects the files to fingerprint,
        # including custom --tabulation inputs; no row or file labels are read.
        initial_provenance = read_provenance(args.labels_dir / 'diffs.jsonl', args.manifest)
        watched = lib.corpus_files(initial_provenance['tabulation'])
        before = lib.readonly_fingerprint(args.repo, watched)
        # Manifest identifiers orchestrate Git reads only; scorers receive just input bytes.
        cases = lib.load_manifest(args.manifest, args.repo, validate=False)
        inputs, orders = {}, {}
        for case in cases:
            key = case['case']
            data = lib.build_scorer_input(args.repo, case['base'], case['head'])
            inputs[key] = data
            orders[key] = {'S0': list(lib.random_orders(data, args.seed)),
                           'S1': [lib.rank(data, lib.score_s1(data))],
                           'S2': [lib.rank(data, lib.score_s2(data))]}
        s3_status = 'S3 skipped: disabled by --s3 off'
        if args.s3 == 'auto':
            import s3_local
            available, reasons = s3_local.availability(out)
            s3_status = 'S3 skipped: ' + '; '.join(reasons)
            if available:
                try:
                    scores = {}
                    with s3_local.transport_session(out) as transport:
                        for key, data in inputs.items():
                            scores[key] = lib.rank(data, s3_local.run(data, transport))
                    for key in inputs:
                        orders[key]['S3'] = [scores[key]]
                    s3_status = 'S3 ran: task-owned local model'
                except Exception as error:
                    # Never report a partially scored S3 as a candidate.
                    s3_status = 'S3 skipped: local scoring failed (' + type(error).__name__ + ')'
        # A mutation during scoring is a read-only violation (exit 3), rather
        # than a pre-existing stale-label error (exit 2). Check before reopening
        # label records so no verdict can be emitted for the changed corpus.
        scored_fingerprint = lib.readonly_fingerprint(args.repo, watched)
        if before != scored_fingerprint:
            print('fingerprint before: ' + json.dumps(before, sort_keys=True))
            print('fingerprint after: ' + json.dumps(scored_fingerprint, sort_keys=True))
            print('unchanged: no')
            return 3
        # This is the first label-record read, after every arm has finished scoring.
        diffs, provenance = read_diffs(args.labels_dir / 'diffs.jsonl', args.manifest)
        if provenance != initial_provenance:
            raise ValueError('provenance changed during scoring')
        if len(diffs) != len(cases) or {d['case'] for d in diffs} != set(inputs):
            raise ValueError('label cases do not match manifest')
        results = []
        for diff in sorted(diffs, key=lambda d: d['case']):
            key = diff['case']
            all_files = {f['path'] for f in lib.input_files(inputs[key])}
            primary_files = {p for p in all_files if not lib.is_test(p)}
            if set(diff['files']) != all_files or set(diff['primary_files']) != primary_files:
                raise ValueError('label universe does not match scored diff')
            for arm, arm_orders in sorted(orders[key].items()):
                evaluated = {}
                for stratum in ('primary', 'high_only', 'sensitivity'):
                    universe = all_files if stratum == 'sensitivity' else primary_files
                    defective = set(diff[stratum + '_defective'])
                    usable = len(universe) >= 3 and 1 <= len(defective) < len(universe)
                    if not defective <= universe or diff['usable_' + stratum] != usable:
                        raise ValueError('invalid label stratum')
                    evaluated[stratum] = lib.mean_metrics([
                        lib.metrics([p for p in order if p in universe], defective)
                        for order in arm_orders]) if usable else None
                record = {'case': key, 'arm': arm, 'order': arm_orders[0], 'metrics': evaluated}
                if arm == 'S0':
                    record['orders'] = arm_orders
                results.append(record)
        lib.write_private(out / 'results.jsonl', lib.jsonl(results))
        after = lib.readonly_fingerprint(args.repo, watched)
        unchanged = before == after and lib.sha256(provenance['tabulation']) == provenance['tabulation_sha256']
        # Paths are deliberately elided: the tracked note may contain aggregates only.
        command = f'python3 run_eval.py --seed {args.seed} --s3 {args.s3} (path arguments elided)'
        commit = lib.git(lib.CLONE, 'log', '-1', '--format=%H', '--', 'eval/diff-triage/criteria.md')
        lines = ['command: ' + command, 'criteria.md commit: ' + (commit or 'uncommitted'),
                 *summarize(results, args.seed), s3_status,
                 'fingerprint before: ' + json.dumps(before, sort_keys=True),
                 'fingerprint after: ' + json.dumps(after, sort_keys=True),
                 'unchanged: ' + ('yes' if unchanged else 'no'),
                 f'runtime seconds: {time.monotonic() - started:.6f}',
                 f'peak RSS SELF KiB: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}',
                 f'peak RSS CHILDREN KiB: {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss}']
        text = '\n'.join(lines) + '\n'
        print(text, end='')
        if not unchanged:
            return 3
        if args.note:
            lib.write_note(args.note, text)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('run_eval.py: validation failed (' + type(error).__name__ + ')', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
