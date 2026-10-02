#!/usr/bin/env python3
"""Offline replay CLI. Private artifacts contain counts, never source text/tokens."""
import sys
sys.dont_write_bytecode = True

import argparse
from bisect import bisect_left
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import resource
import time

from identifiers import CLASSES, extract, error_lines, occurs_error
from policies import decide, epoch_start, fake_scorer, retained_text, load_jev
from score import verdict, render_note, cells
from transcripts import discover, load_events

common = load_jev("common")
assert_out_of_tree = common.assert_out_of_tree
USES = {"assistant_text", "tool_input", "user_text"}
STATUSES = ("needed", "rederivable", "resurfaced", "not_used")


def cuts(events):
    positions = [i for i, e in enumerate(events) if e.kind == "result"]
    result = []
    if len(positions) >= 8:
        result.extend((positions[n - 1] + 1, "synthetic")
                      for n in sorted({len(positions) * q // 4 for q in (1, 2, 3)}))
    result.extend((i, "real") for i, e in enumerate(events) if e.kind == "boundary")
    return sorted(result)


def token_index(events):
    index = {cls: {} for cls in CLASSES if cls != "error"}
    for i, event in enumerate(events):
        for cls, tokens in extract(event.text).items():
            for token in tokens:
                index[cls].setdefault(token, []).append(i)
    return index


def needed_tokens(events, cut, index=None):
    start = epoch_start(events, cut)
    index = token_index(events) if index is None else index
    statuses = {cls: {status: set() for status in STATUSES} for cls in CLASSES}

    def classify(cls, token, pre, first_post):
        if not pre or not any(events[i].kind == "result" for i in pre):
            return
        if events[pre[0]].kind != "result" or any(events[i].kind in USES for i in pre):
            status = "rederivable"
        elif first_post is None:
            status = "not_used"
        elif events[first_post].kind == "result":
            status = "resurfaced"
        else:
            status = "needed"
        statuses[cls][status].add(token)

    for cls, tokens in index.items():
        for token, positions in tokens.items():
            a, b = bisect_left(positions, start), bisect_left(positions, cut)
            classify(cls, token, positions[a:b], positions[b] if b < len(positions) else None)
    candidates = set()
    for event in events[start:cut]:
        if event.kind == "result":
            candidates.update(error_lines(event.text))
    for line in sorted(candidates):
        pre = []
        for i in range(start, cut):
            if occurs_error(line, events[i].text):
                pre.append(i)
                # Once re-derivable, post-cut occurrences cannot change the status.
                if events[i].kind in USES:
                    statuses["error"]["rederivable"].add(line)
                    break
        else:
            first_post = next((i for i in range(cut, len(events))
                               if occurs_error(line, events[i].text)), None)
            classify("error", line, pre, first_post)
    return statuses


def empty_metric():
    return dict(files=0, cuts=0, bytes_total=0, bytes_removed=0, lost_agentids=0,
                p3_secret_skips=0, p3_errors=0,
                classes={c: dict(needed=0, retained=0, rederivable=0, resurfaced=0, not_used=0)
                         for c in CLASSES})


def merge_metric(target, source):
    for key in ("files", "cuts", "bytes_total", "bytes_removed", "lost_agentids",
                "p3_secret_skips", "p3_errors"):
        target[key] += source[key]
    for cls in CLASSES:
        for key in ("needed", "retained", "rederivable", "resurfaced", "not_used"):
            target["classes"][cls][key] += source["classes"][cls][key]


def finish_metric(metric):
    metric["removed_share"] = (metric["bytes_removed"] / metric["bytes_total"]
                               if metric["bytes_total"] else None)
    for m in metric["classes"].values():
        m["recall"] = m["retained"] / m["needed"] if m["needed"] else None
    return metric


def empty_policy():
    return dict(pooled=empty_metric(),
                file_kind={k: empty_metric() for k in ("main", "subagent")},
                cut_kind={k: empty_metric() for k in ("synthetic", "real")},
                size_bucket={k: empty_metric() for k in ("<8", "8-49", "50-199", ">=200")})


def measure(events, cut, outcomes, needed, ctx):
    metric = empty_metric()
    metric["cuts"] = 1
    retained = {c: set() for c in CLASSES}
    pre = [e for e in events[epoch_start(events, cut):cut] if e.kind == "result"]
    for event, outcome in zip(pre, outcomes):
        text = retained_text(event.text, outcome)
        metric["bytes_total"] += len(event.text.encode("utf-8"))
        metric["bytes_removed"] += len(event.text.encode("utf-8")) - len(text.encode("utf-8"))
        for cls, tokens in extract(text).items():
            retained[cls].update(tokens)
        retained["error"].update(t for t in needed["error"]["needed"] if occurs_error(t, text))
    for cls in CLASSES:
        metric["classes"][cls].update({s: len(needed[cls][s]) for s in STATUSES})
        metric["classes"][cls]["retained"] = len(needed[cls]["needed"] & retained[cls])
    metric["lost_agentids"] = metric["classes"]["agentid"]["needed"] - metric["classes"]["agentid"]["retained"]
    for key in ("p3_secret_skips", "p3_errors"):
        metric[key] = ctx.get(key, 0)
    return finish_metric(metric)


def evaluate_file(events, kind, scorer=None):
    count = sum(e.kind == "result" for e in events)
    bucket = "<8" if count < 8 else "8-49" if count < 50 else "50-199" if count < 200 else ">=200"
    policies = {p: empty_policy() for p in (["P0", "P1", "P2"] + (["P3"] if scorer else []))}
    index = token_index(events)
    for cut, cut_kind in cuts(events):
        needed = needed_tokens(events, cut, index)
        for name, policy in policies.items():
            ctx = {"scorer": scorer}
            outcomes = decide(name, events, cut, ctx)
            metric = measure(events, cut, outcomes, needed, ctx)
            if name == "P0":
                assert metric["bytes_removed"] == 0
                assert all(m["needed"] == m["retained"] for m in metric["classes"].values())
            for cell in (policy["pooled"], policy["file_kind"][kind],
                         policy["cut_kind"][cut_kind], policy["size_bucket"][bucket]):
                merge_metric(cell, metric)
    for policy in policies.values():
        for _, cell in cells(policy):
            cell["files"] = int(cell["cuts"] > 0)
            finish_metric(cell)
    return policies, bucket


def quantile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def bootstrap(metrics, seed, repetitions):
    # Numeric per-file vectors only: no transcript events survive file iteration.
    vectors = [[m["bytes_removed"], m["bytes_total"]] +
               [v for c in CLASSES for v in (m["classes"][c]["retained"], m["classes"][c]["needed"])]
               for m in metrics if m["cuts"]]
    samples = [[] for _ in range(5)]
    rng = random.Random(seed)
    if vectors:
        for _ in range(repetitions):
            sums = [0] * 10
            for _ in vectors:
                row = vectors[rng.randrange(len(vectors))]
                for i, value in enumerate(row):
                    sums[i] += value
            for i in range(5):
                if sums[i * 2 + 1]:
                    samples[i].append(sums[i * 2] / sums[i * 2 + 1])
    ci = [[quantile(s, 0.025), quantile(s, 0.975)] if s else None for s in samples]
    return {"removed_share": ci[0], "recall": dict(zip(CLASSES, ci[1:]))}


def aggregate_rows(rows, counts, p3, seed, repetitions):
    names = ["P0", "P1", "P2"] + (["P3"] if p3["status"] in ("fake", "ran", "errors") else [])
    aggregate = dict(counts=counts, p3=p3, policies={p: empty_policy() for p in names})
    for name, policy in aggregate["policies"].items():
        by_cell = {scope: [] for scope, _ in cells(policy)}
        for row in rows:
            for scope, metric in cells(row["policies"][name]):
                by_cell[scope].append(metric)
        for scope, cell in cells(policy):
            for metric in by_cell[scope]:
                merge_metric(cell, metric)
            finish_metric(cell)
            cell["bootstrap"] = bootstrap(by_cell[scope], seed, repetitions)
    if "P3" in aggregate["policies"]:
        errors = aggregate["policies"]["P3"]["pooled"]["p3_errors"]
        if errors:
            aggregate["p3"] = {"status": "errors", "errors": errors}
    aggregate["verdict"] = verdict(aggregate)
    return aggregate


def write_json(path, value):
    target = assert_out_of_tree(path)
    target.write_text(json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2) + "\n",
                      encoding="utf-8")


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1_048_576), b""):
            digest.update(block)
    return digest.hexdigest()


class CachedScorer:
    """Called only after policies.decide has screened all three input strings."""
    def __init__(self, scorer, directory, model_digest):
        self.scorer = scorer
        self.directory = assert_out_of_tree(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.model_digest = model_digest

    def __call__(self, name, input_text, result_text):
        prompt = list(self.scorer.requests(name, input_text, result_text))
        payload = json.dumps([self.model_digest, prompt], sort_keys=True, ensure_ascii=True)
        key = hashlib.sha256(payload.encode()).hexdigest()
        path = assert_out_of_tree(self.directory / (key + ".json"))
        if path.exists():
            value = json.loads(path.read_text())
            if isinstance(value, list) and len(value) == 2 and all(type(v) is bool for v in value):
                return tuple(value)
            raise ValueError("invalid scorer cache")
        value = self.scorer(name, input_text, result_text)
        write_json(path, value)
        return value


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    state = common.state_dir()
    result.add_argument("--projects", type=Path, default=Path(os.environ.get(
        "CC_ORCH_CLAUDE_PROJECTS", str(Path.home() / ".claude/projects"))))
    result.add_argument("--out", type=Path, default=state / "compaction-replay")
    result.add_argument("--seed", type=int, default=20261002)
    result.add_argument("--bootstrap", type=int, default=2000)
    result.add_argument("--p3", choices=("off", "fake", "local"), default="off")
    result.add_argument("--p3-model", type=Path, default=state / "models/Qwen3-8B-Q8_0.gguf")
    result.add_argument("--p3-server", default="llama-server")
    result.add_argument("--note", type=Path)
    result.add_argument("--criteria-commit", default="UNCOMMITTED")
    result.add_argument("--limit-files", type=int)
    return result


def run(args):
    wall_start, start = time.time(), time.monotonic()
    # Validate all primary destinations before creating any of them.
    out = assert_out_of_tree(args.out)
    destinations = [assert_out_of_tree(out / name) for name in
                    ("per-file.jsonl", "aggregate.json", "run-meta.json", "p3-cache")]
    source_root = args.projects.resolve()
    if any(p == source_root or source_root in p.parents for p in (out, *destinations)):
        raise ValueError("outputs overlap the source tree")
    refs = discover(args.projects)
    if args.limit_files is not None:
        refs = refs[:args.limit_files]
    eligible = [r for r in refs if r.mtime <= wall_start - 600]
    sample = random.Random(args.seed).sample(eligible, min(20, len(eligible)))
    before = {r.key: digest_file(r.path) for r in sample}
    # An aggregate note must never alias a source, private artifact or other data file.
    if args.note:
        note = args.note.resolve()
        if (args.note.suffix != ".md" or note == source_root or source_root in note.parents
                or note in {r.path.resolve() for r in refs} | set(destinations)):
            raise ValueError("invalid aggregate note destination")
    out.mkdir(parents=True, exist_ok=True)
    p3, scorer = {"status": "off"}, None
    with ExitStack() as stack:
        if args.p3 == "fake":
            p3, scorer = {"status": "fake"}, fake_scorer
            print("DEMONSTRATION: P3 fake scorer is not a verdict arm")
        elif args.p3 == "local":
            from local_scorer import preflight, LocalServer, LocalScorer, LocalError, MODEL_DIGEST
            reason = preflight(args.p3_model, args.p3_server)
            if reason is None:
                try:
                    server = stack.enter_context(LocalServer(args.p3_model, args.p3_server, out))
                    scorer = CachedScorer(LocalScorer(server.socket_path), destinations[3], MODEL_DIGEST)
                    p3 = {"status": "ran"}
                except (LocalError, OSError):
                    reason = "local server startup failed"
            if reason:
                p3 = {"status": "skipped", "reason": reason}
                print("P3 skipped: " + reason)
        seen_uuids, rows = set(), []
        counts = dict(files_discovered=len(refs), files_evaluated=0, main_files=0, subagent_files=0,
                      records=0, parse_errors=0, dup_records_in_file=0, dup_conflicts=0,
                      copied_records=0, files_skipped_copy=0, nontext_result_blocks=0,
                      excluded_records=0)
        with assert_out_of_tree(destinations[0]).open("w", encoding="utf-8") as stream:
            for ref in refs:
                events, stats = load_events(ref, seen_uuids)
                for key, value in stats.items():
                    counts[key] = counts.get(key, 0) + value
                if stats["files_skipped_copy"]:
                    continue
                policies, bucket = evaluate_file(events, ref.kind, scorer)
                evaluated = bool(policies["P0"]["pooled"]["cuts"])
                counts["files_evaluated"] += int(evaluated)
                counts[ref.kind + "_files"] += 1
                row = dict(id=ref.key, kind=ref.kind, size_bucket=bucket, stats=stats, policies=policies)
                stream.write(json.dumps(row, sort_keys=True) + "\n")
                rows.append(row)
                del events  # No prior file's events or extracted tokens remain in memory.
    after = {r.key: digest_file(r.path) for r in sample}
    unchanged = sum(after[key] == value for key, value in before.items())
    aggregate = aggregate_rows(rows, counts, p3, args.seed, args.bootstrap)
    # Paths are placeholders, so an evidence note cannot expose a private directory name.
    command = ('python3 eval/compaction-replay/replay.py --projects "$CC_ORCH_CLAUDE_PROJECTS" '
               f'--out "$REPLAY_OUT" --seed {args.seed} --bootstrap {args.bootstrap} --p3 {args.p3}')
    if args.p3 == "local":
        command += ' --p3-model "$REPLAY_MODEL" --p3-server "$REPLAY_SERVER"'
    if args.limit_files is not None:
        command += f" --limit-files {args.limit_files}"
    if args.note:
        command += ' --note "$REPLAY_NOTE"'
    command += " --criteria-commit " + args.criteria_commit
    meta = dict(start_time=datetime.fromtimestamp(wall_start, timezone.utc).isoformat(),
                runtime_seconds=time.monotonic() - start,
                peak_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
                source_hash_check=dict(sampled=len(sample), unchanged=unchanged),
                source_hashes={r.key: {"before": before[r.key], "after": after[r.key]} for r in sample},
                run_command=command, criteria_commit=args.criteria_commit,
                seed=args.seed, bootstrap=args.bootstrap)
    write_json(destinations[1], aggregate)
    write_json(destinations[2], meta)
    if args.note:
        args.note.parent.mkdir(parents=True, exist_ok=True)
        args.note.write_text(render_note(aggregate, meta), encoding="utf-8")
    print(f"Files discovered: {len(refs)}; files evaluated: {counts['files_evaluated']}")
    print("Overall verdict: " + aggregate["verdict"]["overall"])
    return 0 if unchanged == len(sample) else 2


def main(argv=None):
    args = parser().parse_args(argv)
    if args.bootstrap < 1 or (args.limit_files is not None and args.limit_files < 1):
        print("replay: sample sizes must be positive", file=sys.stderr)
        return 2
    if args.criteria_commit != "UNCOMMITTED" and not re.fullmatch(r"[0-9a-f]{40}", args.criteria_commit):
        print("replay: criteria commit must be 40 lowercase hex characters", file=sys.stderr)
        return 2
    try:
        return run(args)
    except common.OutOfTreeError:
        print("replay: refusing output path: " + str(args.out), file=sys.stderr)
    except (OSError, ValueError, RecursionError):
        print("replay: input/output failure (source details suppressed)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
