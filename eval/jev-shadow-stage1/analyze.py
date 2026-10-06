#!/usr/bin/env python3
"""Read-only, aggregate Stage 1 review using the pre-registered analysis plan."""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import random
import sys


SEED = 20261006
RESAMPLES = 10000
ENABLED_DATE = datetime.date(2026, 9, 22)
REVIEW_DATE = datetime.date(2026, 10, 6)
DEFAULT_POLICY = Path(__file__).resolve().parents[2] / "jev-policy.conf"


def average_ranks(values):
    """Return 1-based ranks, averaging the positions occupied by ties."""
    order = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    start = 0
    while start < len(order):
        end = start + 1
        while end < len(order) and values[order[end]] == values[order[start]]:
            end += 1
        rank = (start + 1 + end) / 2
        for position in range(start, end):
            ranks[order[position]] = rank
        start = end
    return ranks


def spearman(xs, ys):
    """Pearson correlation of average ranks; None for zero rank variance."""
    if len(xs) != len(ys):
        raise ValueError("paired vectors must have the same length")
    if len(xs) < 2:
        return None
    rx, ry = average_ranks(xs), average_ranks(ys)
    mean = (len(xs) + 1) / 2
    dx, dy = [x - mean for x in rx], [y - mean for y in ry]
    vx, vy = sum(x * x for x in dx), sum(y * y for y in dy)
    if not vx or not vy:
        return None
    return sum(x * y for x, y in zip(dx, dy)) / math.sqrt(vx * vy)


def bootstrap_interval(pairs, seed=SEED, resamples=RESAMPLES):
    """Paired percentile bootstrap, dropping and counting undefined rhos."""
    if resamples < 1:
        raise ValueError("resamples must be positive")
    if not pairs:
        return None, None, resamples
    rng = random.Random(seed)
    defined = []
    for _ in range(resamples):
        sample = [pairs[rng.randrange(len(pairs))] for _ in pairs]
        rho = spearman([x for x, _ in sample], [y for _, y in sample])
        if rho is not None:
            defined.append(rho)
    count = len(defined)
    if not count:
        return None, None, resamples
    defined.sort()
    return (defined[int(0.025 * count)], defined[int(0.975 * count) - 1],
            resamples - count)


def finite_number(value):
    return type(value) is int or (type(value) is float and math.isfinite(value))


def valid_fields(record):
    return (
        finite_number(record.get("reasoning"))
        and type(record.get("duration_ms")) is int and record["duration_ms"] >= 0
        and type(record.get("codex_exit")) is int
        and type(record.get("attempts")) is int and record["attempts"] >= 0
        and isinstance(record.get("difficulty"), str)
        and finite_number(record.get("difficulty_confidence"))
    )


def timestamp_span(records):
    """Use all parseable timestamps; treat offset-free timestamps as UTC."""
    timestamps = []
    for record in records:
        try:
            stamp = datetime.datetime.fromisoformat(record.get("timestamp"))
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=datetime.timezone.utc)
            timestamps.append(stamp.timestamp())
        except (TypeError, ValueError, OverflowError, OSError):
            continue
    span = (max(timestamps) - min(timestamps)) / 86400 if len(timestamps) >= 2 else None
    return span, len(records) - len(timestamps)


def excludes_zero(interval):
    lower, upper = interval
    return lower is not None and upper is not None and (lower > 0 or upper < 0)


def signal_status(n, rho, interval):
    if n < 10:
        return "insufficient"
    return "met" if rho is not None and rho >= 0.30 and excludes_zero(interval) else "not met"


def verdict(sufficiency, criteria):
    if sufficiency != "met":
        return "inconclusive"
    if "not met" in criteria:
        return "do not adopt"
    if all(status == "met" for status in criteria):
        return "proceed to Stage 2 discussion"
    return "inconclusive"


def evaluate(records, threshold, enabled_date, review_date):
    """Return aggregate counts, per-criterion results and both verdicts."""
    implement = [r for r in records if r.get("mode") == "implement"]
    ok = [r for r in implement if r.get("status") == "ok"]
    exact = [r for r in ok if r.get("observation") == "exact"]
    analysed = [r for r in exact if valid_fields(r)]
    n = len(analysed)
    pairs = [(r["reasoning"], r["duration_ms"]) for r in analysed]
    rho = spearman([x for x, _ in pairs], [y for _, y in pairs])
    lower, upper, undefined = bootstrap_interval(pairs)
    days = (review_date - enabled_date).days
    span, skipped_timestamps = timestamp_span(records)
    mechanical = [r for r in analysed if r["difficulty"] == "mechanical"
                  and r["difficulty_confidence"] >= threshold]
    m = len(mechanical)
    o = n - m
    failure = lambda r: r["codex_exit"] != 0 or r["attempts"] > 1
    f = sum(failure(r) for r in mechanical)
    g = sum(failure(r) for r in analysed) - f
    c1 = "met" if days >= 14 and n >= 30 else "not met"
    alternative = "met" if span is not None and span >= 14 and n >= 30 else "not met"
    c2 = signal_status(n, rho, (lower, upper))
    c3 = "insufficient" if n < 10 else ("met" if m / n >= 0.20 else "not met")
    # Cross multiplication compares the unrounded rates, including exact equality.
    c4 = "insufficient" if min(m, o) < 10 else ("met" if f * o <= g * m else "not met")
    return {
        "records": len(records), "implement": len(implement), "implement_ok": len(ok),
        "n": n, "excluded": len(exact) - n,
        "exact_not_ok": sum(r.get("observation") == "exact" and r.get("status") != "ok"
                            for r in implement),
        "threshold": threshold, "skipped_timestamps": skipped_timestamps,
        "criterion1": {"status": c1, "days": days, "enabled_date": enabled_date,
                       "review_date": review_date, "span_days": span,
                       "alternative_status": alternative},
        "criterion2": {"status": c2, "rho": rho, "interval": (lower, upper),
                       "undefined": undefined, "excludes_zero": excludes_zero((lower, upper))},
        "criterion3": {"status": c3, "mechanical": m},
        "criterion4": {"status": c4, "mechanical": m, "other": o,
                       "mechanical_failures": f, "other_failures": g,
                       "all_mechanical": sum(r["difficulty"] == "mechanical" for r in analysed)},
        "verdict": verdict(c1, (c2, c3, c4)),
        "alternative_verdict": verdict(alternative, (c2, c3, c4)),
    }


def rate(count, total):
    return f"{count}/{total} ({100 * count / total:.1f}%)" if total else "0/0 (n/a)"


def render(result, log_path, log_sha256, policy_path, malformed=0):
    """Render only aggregate data, never the underlying records or their ids."""
    c1, c2, c3, c4 = (result[f"criterion{i}"] for i in range(1, 5))
    n, threshold = result["n"], result["threshold"]
    rho = "undefined" if c2["rho"] is None else f"{c2['rho']:.4f}"
    lower, upper = c2["interval"]
    interval = "undefined" if lower is None else f"[{lower:.4f}, {upper:.4f}]"
    span = "n/a" if c1["span_days"] is None else f"{c1['span_days']:.2f} days"
    return "\n".join([
        "Jev shadow Stage 1 review — criteria from eval/jev-shadow-decision.md",
        f"log: {log_path}",
        f"log sha256: {log_sha256}",
        f"policy: {policy_path} · JEV_SHADOW_MIN_CONFIDENCE={threshold}",
        f"records: {result['records']} · malformed lines: {malformed}",
        f"population: implement {result['implement']} · implement+ok {result['implement_ok']}"
        f" · analysed (implement, ok, exact) {n} · excluded (invalid fields) {result['excluded']}"
        f" · exact but not ok (not analysed) {result['exact_not_ok']}",
        f"criterion 1 sufficiency: days {c1['enabled_date']} -> {c1['review_date']} = {c1['days']}"
        f" (>= 14) · records {n} (>= 30) -> {c1['status']}",
        f"  alternative reading: first-to-last record span = {span} (>= 14) -> {c1['alternative_status']}",
        f"  timestamps: parseable {result['records'] - result['skipped_timestamps']}"
        f" · skipped {result['skipped_timestamps']}",
        f"criterion 2 signal: n {n} · spearman(reasoning, duration_ms) = {rho} (>= 0.30)"
        f" · 95% bootstrap interval {interval} ({RESAMPLES} resamples, seed {SEED},"
        f" undefined {c2['undefined']}) · excludes 0: {'yes' if c2['excludes_zero'] else 'no'} -> {c2['status']}",
        f"criterion 3 savings potential: mechanical with confidence >= {threshold}:"
        f" {rate(c3['mechanical'], n)} (>= 20%) -> {c3['status']}",
        f"criterion 4 no hidden risk: failure-or-retry mechanical"
        f" {rate(c4['mechanical_failures'], c4['mechanical'])} vs other"
        f" {rate(c4['other_failures'], c4['other'])}"
        f" (each group >= 10; mechanical not higher) -> {c4['status']}",
        f"  informational: analysed records with difficulty mechanical regardless of confidence = {c4['all_mechanical']}",
        f"verdict: {result['verdict']}",
        f"verdict under the alternative 14-day reading: {result['alternative_verdict']}",
        "limit: the log cannot show whether a cheaper model would have succeeded; a pass never authorises a model switch.",
    ]) + "\n"


def read_policy(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError("invalid policy assignment")
        key, value = line.split("=", 1)
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        values[key.strip()] = value
    try:
        threshold = float(values["JEV_SHADOW_MIN_CONFIDENCE"])
    except (KeyError, ValueError):
        raise ValueError("policy requires numeric JEV_SHADOW_MIN_CONFIDENCE") from None
    if not math.isfinite(threshold):
        raise ValueError("policy requires finite JEV_SHADOW_MIN_CONFIDENCE")
    return values, threshold


def resolve_log_path(log_arg, policy):
    override = log_arg or os.environ.get("JEV_STAGE1_LOG")
    if override:
        return Path(override)
    if not policy.get("JEV_SHADOW_LOG"):
        raise ValueError("policy requires JEV_SHADOW_LOG when no log override is supplied")
    state = Path(os.environ.get("CC_ORCH_STATE_DIR") or Path.home() / ".claude/orchestra-state")
    return state / policy["JEV_SHADOW_LOG"]


def read_log(path):
    records, malformed = [], 0
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for line in stream:
            digest.update(line)
            try:
                record = json.loads(line.decode("utf-8"))
                if not isinstance(record, dict):
                    raise ValueError("not an object")
                records.append(record)
            except (ValueError, RecursionError):
                malformed += 1
    return records, malformed, digest.hexdigest()


def parse_date(value):
    try:
        date = datetime.date.fromisoformat(value)
        if date.isoformat() == value:
            return date
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("date must be YYYY-MM-DD")


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def main(argv=None):
    parser = ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--enabled-date", type=parse_date, default=ENABLED_DATE)
    parser.add_argument("--review-date", type=parse_date, default=REVIEW_DATE)
    try:
        args = parser.parse_args(argv)
        policy, threshold = read_policy(args.policy)
        path = resolve_log_path(args.log, policy)
        records, malformed, digest = read_log(path)
        result = evaluate(records, threshold, args.enabled_date, args.review_date)
    except (OSError, ValueError) as error:
        print("analyze.py: " + " ".join(str(error).splitlines()), file=sys.stderr)
        return 2
    print(render(result, path, digest, args.policy, malformed), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
