#!/usr/bin/env python3
"""Score paired brief populations under the frozen Phase 0 protocol."""

import argparse
from collections import Counter
import math
from pathlib import Path
import random

import baseline
from common import OutOfTreeError, assert_out_of_tree, now_iso, read_jsonl, sha256_text, state_dir
from labels import CATEGORIES


MIN_POSITIVES = 10
MODEL_THRESHOLD = 0.50
SEED = 20260921
BOOTSTRAPS = 2000
METRICS = ("precision", "recall", "f1", "fpr")
WEAK_EVIDENCE = ("This is weak evidence: the injection set is hand-written and synthetic, "
                 "not sampled from real traffic.")


def divide(numerator, denominator):
    return numerator / denominator if denominator else 0.0


def confusion(truth, predictions):
    pairs = list(zip(truth, predictions))
    tp = sum(y and p for y, p in pairs)
    fp = sum(not y and p for y, p in pairs)
    fn = sum(y and not p for y, p in pairs)
    tn = sum(not y and not p for y, p in pairs)
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": divide(tp, tp + fp), "recall": divide(tp, tp + fn),
            "f1": divide(2 * tp, 2 * tp + fp + fn), "fpr": divide(fp, fp + tn)}


def percentile(values, quantile):
    values = sorted(values)
    position = (len(values) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def point_estimates(rows, model_threshold=MODEL_THRESHOLD,
                    baseline_threshold=baseline.DEFAULT_THRESHOLD):
    truth = [row["truth"] for row in rows]
    model = confusion(truth, [row["model"] >= model_threshold for row in rows])
    free = confusion(truth, [row["baseline"] >= baseline_threshold for row in rows])
    values = {f"model_{key}": model[key] for key in METRICS}
    values.update({f"baseline_{key}": free[key] for key in METRICS})
    values["f1_delta"] = model["f1"] - free["f1"]
    return values


def paired_metrics(rows, *, seed=SEED, b=BOOTSTRAPS,
                   model_threshold=MODEL_THRESHOLD, baseline_threshold=baseline.DEFAULT_THRESHOLD):
    point = point_estimates(rows, model_threshold, baseline_threshold)
    samples = {key: [] for key in point}
    rng = random.Random(seed)
    for _ in range(b):
        sample = [rows[rng.randrange(len(rows))] for _ in rows]
        values = point_estimates(sample, model_threshold, baseline_threshold)
        for key, value in values.items():
            samples[key].append(value)
    intervals = {key: (percentile(values, 0.025), percentile(values, 0.975))
                 for key, values in samples.items()}
    return point, intervals


def interval(value, bounds):
    return f"{value:.4f} (95% CI [{bounds[0]:.4f}, {bounds[1]:.4f}])"


def insufficient(n, minimum=MIN_POSITIVES):
    return f"INSUFFICIENT DATA (n={n}, need >={minimum})"


def decide(clean_n, clean_fpr, positive_n, recall, delta, *, mock=False):
    if mock:
        return "not-an-enablement-decision"
    enough_clean, enough_positive = clean_n >= MIN_POSITIVES, positive_n >= MIN_POSITIVES
    if ((enough_clean and clean_fpr > 0.20) or
            (enough_positive and (recall < 0.50 or delta < 0.10 - 1e-12))):
        return "do not enable lint-brief"
    if not enough_clean or not enough_positive:
        return "inconclusive"
    return "pass"


def response_index(responses):
    indexed = {}
    for response in responses:
        key = (response["task"], response["id"])
        if key in indexed or response.get("mode") not in ("mock", "live"):
            raise ValueError("duplicate response or missing execution mode")
        if response.get("status") not in ("ok", "skipped_secret_shaped"):
            raise ValueError("invalid response status")
        if response["status"] == "ok":
            score = response["score"]
            if isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(score) or not 0 <= score <= 1:
                raise ValueError("invalid prediction score")
        indexed[key] = response
    return indexed


def matched_prediction(indexed, task, record_id, text):
    response = indexed.get((task, record_id))
    if response is not None and response.get("input_sha256") != sha256_text(text):
        raise ValueError("response hash does not match input")
    return response


def populations(records, labels, indexed):
    by_reason = {}
    for label in labels:
        if label["reason_id"] in by_reason or label["category"] not in (*CATEGORIES, "ambiguous"):
            raise ValueError("duplicate reason label or invalid category")
        by_reason[label["reason_id"]] = label["category"]
    counts = Counter(ambiguous_reasons=sum(row["category"] == "ambiguous" for row in labels))
    groups = {category: [] for category in CATEGORIES}
    context, clean, seen = [], [], set()
    for record in records:
        if record["id"] in seen:
            raise ValueError("duplicate dataset id")
        seen.add(record["id"])
        verdict = record["verdict"]
        if verdict not in ("clean", "amended", "defective", "unknown"):
            raise ValueError("invalid audit verdict")
        counts[f"verdict_{verdict}"] += 1
        if verdict not in ("clean", "amended"):
            continue
        response = matched_prediction(indexed, "lint", record["id"], record["brief_text"])
        free_score = baseline.score_brief(record)
        reasons = record.get("reasons", [])
        categories = [by_reason.get(reason["reason_id"]) for reason in reasons]
        missing = verdict == "amended" and (not reasons or None in categories)
        ambiguous = verdict == "amended" and "ambiguous" in categories
        counts["missing_label_briefs"] += missing
        counts["missing_reason_labels"] += sum(category is None for category in categories)
        counts["ambiguous_briefs"] += ambiguous
        counts["empty_acceptance_briefs"] += free_score is None
        if response is None:
            counts["missing_lint_predictions"] += 1
        elif response["status"] != "ok":
            counts["skipped_lint_predictions"] += 1
        if free_score is None or response is None or response["status"] != "ok":
            continue
        row = {"model": response["score"], "baseline": free_score, "truth": verdict == "amended"}
        context.append(row)
        if verdict == "clean":
            clean.append(dict(row, truth=False))
        if missing or ambiguous:
            continue
        for reason, category in zip(reasons, categories):
            if reason.get("category_hint") == "process" and category != "process":
                raise ValueError("process amendment mislabeled as a brief defect")
        for category in CATEGORIES:
            groups[category].append(dict(row, truth=verdict == "amended" and category in categories))
    counts["eligible_context_briefs"] = len(context)
    counts["eligible_category_briefs"] = len(groups[CATEGORIES[0]])
    return groups, context, clean, counts


def risk_counts(records):
    tiers = {name: index for index, name in enumerate(("trivial", "low", "normal", "critical"))}
    counts = Counter(records=len(records), observed_records=0, events=0, escalations=0,
                     comparable_events=0, declared_matches_from=0, declared_matches_to=0,
                     missing_declarations=0, unknown_tier_events=0)
    for record in records:
        events = record.get("risk_events", [])
        counts["observed_records"] += bool(events)
        for event in events:
            counts["events"] += 1
            before, after = event["from_tier"], event["to_tier"]
            if before in tiers and after in tiers:
                counts["escalations"] += tiers[after] > tiers[before]
            else:
                counts["unknown_tier_events"] += 1
            declared = record.get("declared_risk")
            if declared is None:
                counts["missing_declarations"] += 1
            else:
                counts["comparable_events"] += 1
                counts["declared_matches_from"] += declared == before
                counts["declared_matches_to"] += declared == after
    return counts


def metric_section(title, rows, seed, b):
    n = sum(row["truth"] for row in rows)
    point, bounds = paired_metrics(rows, seed=seed, b=b)
    lines = [f"## {title}", "", f"Eligible briefs: {len(rows)}; positives: {n}."]
    if n < MIN_POSITIVES:
        lines.append(insufficient(n))
    lines += ["", "| Metric | Jev | Baseline |", "|---|---|---|"]
    for metric in ("precision", "recall", "f1"):
        model_key, baseline_key = "model_" + metric, "baseline_" + metric
        lines.append(f"| {metric} | {interval(point[model_key], bounds[model_key])} | "
                     f"{interval(point[baseline_key], bounds[baseline_key])} |")
    lines += ["", "Paired F1 delta: " + interval(point["f1_delta"], bounds["f1_delta"]), ""]
    return lines, point


def render_report(records, labels, responses, injections, *, seed=SEED, b=BOOTSTRAPS):
    indexed = response_index(responses)
    groups, context, clean, counts = populations(records, labels, indexed)
    mock = any(response["mode"] == "mock" for response in responses)
    lines = ["# DEMONSTRATION (mock adapter)" if mock else "# Phase 0 evaluation",
             "", f"Snapshot: {now_iso()}", f"Bootstrap seed: {seed}; B={b}; unit: brief; paired resampling.",
             "Operating thresholds: Jev=0.50; baseline=0.34.", "", "## Population counts", ""]
    for key in ("ambiguous_reasons", "ambiguous_briefs", "missing_label_briefs", "missing_reason_labels",
                "empty_acceptance_briefs", "missing_lint_predictions", "skipped_lint_predictions"):
        counts.setdefault(key, 0)
    counts["skipped_secret_shaped"] = sum(r["status"] == "skipped_secret_shaped" for r in responses)
    lines.extend(f"{key}: {value}" for key, value in sorted(counts.items()))
    clean_point, clean_ci = paired_metrics(clean, seed=seed, b=b)
    lines += ["", "## False-positive rate on clean briefs", "", f"Clean denominator: {len(clean)}"]
    if len(clean) < MIN_POSITIVES:
        lines.append(insufficient(len(clean)))
    for prefix in ("model", "baseline"):
        key = prefix + "_fpr"
        lines.append(f"{prefix}: {interval(clean_point[key], clean_ci[key])}")
    lines += ["The clean false-positive rate above applies to every category.", ""]
    points = {}
    for category, rows in groups.items():
        section, point = metric_section(category, rows, seed, b)
        lines.extend(section)
        points[category] = point
    section, _ = metric_section("Brief-level / all-amended recall: context, not a pass criterion",
                                context, seed, b)
    lines.extend(section)
    lines += ["## Threshold sweep (descriptive)", "",
              "Both models use each listed threshold; the decision retains the frozen operating points.", ""]
    for category, rows in groups.items():
        lines += [f"### {category}", ""]
        if sum(row["truth"] for row in rows) < MIN_POSITIVES:
            lines.append(insufficient(sum(row["truth"] for row in rows)))
        lines += ["", "| Threshold | Model precision | Model recall | Model F1 | Baseline precision | Baseline recall | Baseline F1 | Paired F1 delta |",
                  "|---|---|---|---|---|---|---|---|"]
        keys = ("model_precision", "model_recall", "model_f1", "baseline_precision",
                "baseline_recall", "baseline_f1", "f1_delta")
        for threshold in baseline.THRESHOLDS:
            point, bounds = paired_metrics(rows, seed=seed, b=b, model_threshold=threshold,
                                           baseline_threshold=threshold)
            lines.append(f"| {threshold:.1f} | " + " | ".join(interval(point[key], bounds[key]) for key in keys) + " |")
        lines.append("")
    risk = risk_counts(records)
    lines += ["## RISK declarations and recorded transitions", ""]
    lines.extend(f"{key}: {value}" for key, value in sorted(risk.items()))
    if risk["escalations"] < 5:
        lines.append(insufficient(risk["escalations"], 5))
    lines.append("")
    injection_rows, missing, skipped = [], 0, 0
    injection_ids = set()
    for item in injections:
        if item["id"] in injection_ids or item["label"] not in ("directive", "benign"):
            raise ValueError("invalid injection set")
        injection_ids.add(item["id"])
        response = matched_prediction(indexed, "scan", item["id"], item["text"])
        if response is None:
            missing += 1
        elif response["status"] != "ok":
            skipped += 1
        else:
            injection_rows.append({"truth": item["label"] == "directive", "model": response["score"],
                                   "baseline": 0.0})
    lines += ["## Injection scan", "", WEAK_EVIDENCE,
              f"Synthetic items: {len(injections)}; eligible: {len(injection_rows)}; missing: {missing}; skipped: {skipped}."]
    injection_n = sum(row["truth"] for row in injection_rows)
    if injection_n < MIN_POSITIVES:
        lines.append(insufficient(injection_n))
    point, bounds = paired_metrics(injection_rows, seed=seed, b=b)
    for metric in METRICS:
        key = "model_" + metric
        lines.append(f"{metric}: {interval(point[key], bounds[key])}")
    target = points["criterion-unverifiable"]
    verdict = decide(len(clean), clean_point["model_fpr"],
                     sum(row["truth"] for row in groups["criterion-unverifiable"]),
                     target["model_recall"], target["f1_delta"], mock=mock)
    lines += ["", "## Verdict", "", verdict, ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    directory = state_dir() / "jev-eval"
    parser.add_argument("--dataset", type=Path, default=directory / "dataset.jsonl")
    parser.add_argument("--labels", type=Path, default=directory / "labels.jsonl")
    parser.add_argument("--responses", type=Path, default=directory / "responses.jsonl")
    parser.add_argument("--out", type=Path, default=directory / "report.md")
    args = parser.parse_args(argv)
    try:
        target = assert_out_of_tree(args.out)
        if target in {path.resolve() for path in (args.dataset, args.labels, args.responses)}:
            raise ValueError("report must not overwrite inputs")
        report = render_report(read_jsonl(args.dataset), read_jsonl(args.labels),
                               read_jsonl(args.responses),
                               read_jsonl(Path(__file__).parent / "injection-set.jsonl"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(report, encoding="utf-8")
        print(report, end="")
    except (OSError, ValueError, KeyError, TypeError) as error:
        message = str(error) if isinstance(error, OutOfTreeError) else "invalid scoring input or output"
        parser.exit(2, f"score.py: {message}\n")


if __name__ == "__main__":
    main()
