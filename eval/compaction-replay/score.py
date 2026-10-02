#!/usr/bin/env python3
"""Frozen decision procedure and a numbers-only evidence renderer."""
import sys
sys.dont_write_bytecode = True

from identifiers import CLASSES

RECALL_THRESHOLDS = {"path": 0.95, "sha": 0.95, "error": 0.90}
MIN_FILES = {"pooled": 30, "main": 10, "subagent": 10}
MIN_NEEDED = {"pooled": 100, "main": 30, "subagent": 30}
MIN_AGENTIDS = 20
MIN_REMOVED = 0.30


def verdict(aggregate, recall_thresholds=RECALL_THRESHOLDS, min_files=MIN_FILES,
            min_needed=MIN_NEEDED, min_agentids=MIN_AGENTIDS, min_removed=MIN_REMOVED):
    arms = {}
    for name, policy in sorted(aggregate["policies"].items()):
        if name == "P0" or (name == "P3" and aggregate["p3"]["status"] != "ran"):
            continue
        failed, insufficient = [], []
        pooled = policy["pooled"]
        for scope in ("pooled", "main", "subagent"):
            cell = pooled if scope == "pooled" else policy["file_kind"][scope]
            files_ok = cell["files"] >= min_files[scope]
            if not files_ok:
                insufficient.append(scope + ":files")
            for cls, threshold in recall_thresholds.items():
                metric = cell["classes"][cls]
                if metric["needed"] < min_needed[scope]:
                    insufficient.append(scope + ":" + cls)
                elif files_ok and metric["retained"] / metric["needed"] < threshold:
                    failed.append(scope + ":" + cls + " recall")
        if pooled["classes"]["agentid"]["needed"] < min_agentids:
            insufficient.append("pooled:agentid")
        if pooled["files"] >= min_files["pooled"] and pooled["bytes_total"]:
            if pooled["bytes_removed"] / pooled["bytes_total"] < min_removed:
                failed.append("pooled:removed_share")
        elif not pooled["bytes_total"]:
            insufficient.append("pooled:bytes")
        # The hard rule wins even if all required cells are insufficient.
        if pooled["lost_agentids"]:
            decision, reasons = "do not pursue", ["agentId lost"]
        elif failed:
            decision, reasons = "do not pursue", failed
        elif insufficient:
            decision, reasons = "inconclusive", ["INSUFFICIENT DATA"]
        else:
            decision, reasons = "proceed to design discussion", []
        arms[name] = dict(verdict=decision, reasons=reasons,
                          insufficient=insufficient, failed=failed)
    values = {a["verdict"] for a in arms.values()}
    overall = ("proceed to design discussion" if "proceed to design discussion" in values
               else "inconclusive" if "inconclusive" in values else "do not pursue")
    return {"arms": arms, "overall": overall}


def cells(policy):
    yield "pooled", policy["pooled"]
    for dimension in ("file_kind", "cut_kind", "size_bucket"):
        for value, cell in sorted(policy[dimension].items()):
            yield dimension + ":" + value, cell


def number(value):
    return "n/a" if value is None else f"{value:.6f}"


def interval(value):
    return "n/a" if value is None else "[" + ", ".join(number(v) for v in value) + "]"


def render_note(aggregate, meta):
    p3 = aggregate["p3"]
    p3_status = ("P3 skipped: " + p3["reason"] if p3["status"] == "skipped"
                 else "fake (demonstration, not a verdict arm)" if p3["status"] == "fake"
                 else p3["status"])
    hashes = meta["source_hash_check"]
    lines = ["# Tool-result retention replay — aggregate evidence", "",
             "Run command: " + meta["run_command"],
             "Criteria commit: " + meta["criteria_commit"],
             "P3 status: " + p3_status,
             f"Runtime seconds: {meta['runtime_seconds']:.3f}",
             f"Peak RSS MiB: {meta['peak_rss_mib']:.3f}",
             f"Source hash check: {hashes['unchanged']}/{hashes['sampled']} unchanged", "",
             "## Corpus and normalization", "", "| count | value |", "|---|---:|"]
    for key, value in sorted(aggregate["counts"].items()):
        lines.append(f"| {key} | {value} |")
    if p3["status"] == "fake":
        lines += ["", "DEMONSTRATION: P3 fake scores never contribute to the verdict."]
    lines += ["", "## Retention by policy and stratum", "",
              "Counts pool file/cut units; files are counted once within each cell.", "",
              "| arm | stratum | files | cuts | bytes total | bytes removed | removed share | 95% CI | lost agentIds |",
              "|---|---|---:|---:|---:|---:|---:|---|---:|"]
    for arm, policy in sorted(aggregate["policies"].items()):
        for scope, cell in cells(policy):
            ci = cell.get("bootstrap", {})
            lines.append(f"| {arm} | {scope} | {cell['files']} | {cell['cuts']} | "
                         f"{cell['bytes_total']} | {cell['bytes_removed']} | "
                         f"{number(cell['removed_share'])} | {interval(ci.get('removed_share'))} | "
                         f"{cell['lost_agentids']} |")
    lines += ["", "| arm | stratum | class | needed | retained | recall | 95% CI | rederivable | resurfaced | not_used |",
              "|---|---|---|---:|---:|---:|---|---:|---:|---:|"]
    for arm, policy in sorted(aggregate["policies"].items()):
        for scope, cell in cells(policy):
            for cls in CLASSES:
                m = cell["classes"][cls]
                ci = cell.get("bootstrap", {}).get("recall", {}).get(cls)
                lines.append(f"| {arm} | {scope} | {cls} | {m['needed']} | {m['retained']} | "
                             f"{number(m['recall'])} | {interval(ci)} | {m['rederivable']} | "
                             f"{m['resurfaced']} | {m['not_used']} |")
    decision = verdict(aggregate)
    lines += ["", "## Verdict", "", "| arm | verdict | reasons / insufficient cells |", "|---|---|---|"]
    for arm, result in decision["arms"].items():
        reasons = result["reasons"] + ["INSUFFICIENT DATA: " + c for c in result["insufficient"]]
        lines.append(f"| {arm} | {result['verdict']} | {'; '.join(reasons) or 'all criteria met'} |")
    lines += ["", "Overall verdict: " + decision["overall"], "",
              "Bootstrap intervals are descriptive, resampling whole files with replacement.",
              "A pass never authorises a live hook.", ""]
    return "\n".join(lines)
