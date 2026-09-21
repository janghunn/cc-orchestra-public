#!/usr/bin/env python3
"""Build a private, sourced dataset from direct historical task directories."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re

from common import (assert_out_of_tree, iter_task_dirs, now_iso, read_text,
                    sha256_text, state_dir, strip_fences, write_jsonl)


HEADING = re.compile(r"^(#{1,6})[ \t]+(.*)")
ITEM = re.compile(r"^\s*(?:\d+[.)]|[-*])\s+(.*)")
PROCESS = re.compile(r"mid-task|orchestrator|ruling|course correction|round\s*\d|post-gate", re.I)


def audit_verdict(summary):
    lines = summary.split("\n")
    for index, line in enumerate(lines):
        match = re.match(r"^BRIEF AUDIT:[ \t]*(clean|amended|defective)\b(.*)", line, re.I)
        if match:
            reason = [match.group(2).strip()]
            for continuation in lines[index + 1:]:
                if not continuation.strip() or re.match(r"^[A-Z][A-Z0-9 _-]*:", continuation):
                    break
                reason.append(continuation.strip())
            return match.group(1).lower(), index + 1, " ".join(reason).strip()
    return "unknown", None, ""


def declared_risk(brief):
    """Historical extraction, deliberately separate from the policy checker."""
    match = re.search(r"^[ \t]*(?:-[ \t]*)?RISK:[ \t]*\*{0,2}([a-z]+)",
                      strip_fences(brief), re.M)
    return match.group(1) if match else None


def risk_events(text, source_path):
    events = []
    for number, line in enumerate(strip_fences(text).split("\n"), 1):
        match = re.match(r"^RISK AMENDED:[ \t]*([a-z]+)[ \t]*(?:->|→)[ \t]*([a-z]+)", line)
        if match:
            events.append({"from_tier": match.group(1), "to_tier": match.group(2),
                           "source_path": str(source_path), "source_line": number})
    return events


def split_items(lines):
    """Return (first source line, joined text), retaining unnumbered prose."""
    result, current, start = [], [], None
    for number, line in lines:
        match = ITEM.match(line)
        if match and current:
            result.append((start, " ".join(current)))
            current, start = [], None
        content = match.group(1) if match else line.strip()
        if content:
            if start is None:
                start = number
            current.append(content)
    if current:
        result.append((start, " ".join(current)))
    return result


def acceptance_items(brief):
    selected, level = [], None
    for number, line in enumerate(brief.split("\n"), 1):
        opening = re.match(r"^(#{1,3})[ \t]*Acceptance", line)
        if level is None and opening:
            level = len(opening.group(1))
            continue
        heading = HEADING.match(line)
        if heading:
            depth = len(heading.group(1))
            if level is not None and depth <= level:
                break
        if level is not None:
            selected.append((number, line))
    return [text for _, text in split_items(selected)]


def amendment_sections(plan):
    """Classify each amendment heading's own body, ending at the next heading."""
    sections, current, kind = [], [], None
    for number, line in enumerate(strip_fences(plan).split("\n"), 1):
        heading = HEADING.match(line)
        if heading:
            if current:
                sections.append((kind, current))
            current, kind = [], None
            title = heading.group(2)
            if re.search("amendment", title, re.I):
                kind = "process" if PROCESS.search(title) else "audit"
        if kind is not None:
            current.append((number, line))
    if current:
        sections.append((kind, current))
    return sections


def amendment_reasons(lines):
    """Use list items alone, or a single heading-and-prose reason without a list."""
    body = lines[1:]
    first_item = next((index for index, (_, text) in enumerate(body) if ITEM.match(text)), None)
    if first_item is not None:
        candidates = split_items(body[first_item:])
    elif any(character.isalnum() for _, text in body for character in text):
        title = HEADING.match(lines[0][1]).group(2)
        text = " ".join([title, *(text.strip() for _, text in body if text.strip())])
        candidates = [(lines[0][0], text)]
    else:
        candidates = []
    return [(number, text.strip()) for number, text in candidates
            if any(character.isalnum() for character in text)]


def root_slug(root):
    root = Path(root)
    return root.parent.name if root.name == ".orchestra" else root.name


def task_record(root, task):
    brief_path, plan_path, summary_path = (task / name for name in
                                          ("brief.md", "plan.md", "summary.md"))
    brief, plan, summary = (read_text(path) for path in (brief_path, plan_path, summary_path))
    verdict, line_no, reason = audit_verdict(summary)
    record_id = f"{root_slug(root)}/{task.name}"
    reasons, audit_lines = [], []

    def add_reasons(items, source, path):
        for number, text in items:
            text = text.strip()
            if not any(character.isalnum() for character in text):
                continue
            entry = {"reason_id": f"{record_id}#r{len(reasons) + 1:02d}", "text": text,
                     "source": source, "source_path": str(path), "source_line": number}
            reasons.append(entry)

    if verdict in ("amended", "defective") and reason:
        add_reasons([(line_no, reason)], "summary", summary_path)
    if verdict == "amended":
        for kind, lines in amendment_sections(plan):
            if kind == "audit":
                audit_lines.extend(lines)
                add_reasons(amendment_reasons(lines), "plan", plan_path)
    events = risk_events(plan, plan_path) + risk_events(summary, summary_path)
    return {"id": record_id, "root": str(root), "task": task.name,
            "brief_path": str(brief_path), "brief_text": brief,
            "brief_sha256": sha256_text(brief), "acceptance_items": acceptance_items(brief),
            "declared_risk": declared_risk(brief), "risk_events": events,
            "risk_observed": bool(events), "verdict": verdict, "verdict_line_no": line_no,
            "verdict_reason": reason, "plan_amendment_text": "\n".join(t for _, t in audit_lines),
            "reasons": reasons}


def excluded_counts(root):
    counts = Counter()
    # Diagnostic walk never follows symlinks, and never contributes records.
    for directory, _, files in os.walk(root, followlinks=False):
        if "brief.md" not in files:
            continue
        parts = Path(directory).relative_to(root).parts
        if parts and parts[0] == "wt":
            counts["excluded_wt"] += 1
        elif len(parts) > 1:
            counts["excluded_subunit"] += 1
    return counts


def build_dataset(roots):
    stats = {"total": 0, "with_verdict": 0, "without_verdict": 0,
             "summaries": 0, "plans": 0, "excluded_wt": 0,
             "excluded_subunit": 0, "realpath_collisions": 0,
             "per_verdict": dict.fromkeys(("clean", "amended", "defective", "unknown"), 0),
             "per_root": {}, "snapshot": now_iso()}
    records, seen, ids = [], set(), set()
    for root in map(Path, roots):
        root = root.absolute()
        local = {"briefs": 0, "summaries": 0, "plans": 0}
        for key, value in excluded_counts(root).items():
            stats[key] += value
        for task in iter_task_dirs(root, seen=seen, stats=stats):
            record = task_record(root, task)
            if record["id"] in ids:
                raise ValueError("duplicate dataset id; choose roots with distinct slugs")
            ids.add(record["id"])
            records.append(record)
            local["briefs"] += 1
            local["summaries"] += (task / "summary.md").is_file()
            local["plans"] += (task / "plan.md").is_file()
            stats["per_verdict"][record["verdict"]] += 1
        stats["per_root"][root_slug(root)] = local
        stats["summaries"] += local["summaries"]
        stats["plans"] += local["plans"]
    stats["total"] = len(records)
    stats["without_verdict"] = stats["per_verdict"]["unknown"]
    stats["with_verdict"] = len(records) - stats["without_verdict"]
    return records, stats


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roots", nargs="+", type=Path,
                        help="historical roots; overrides colon-separated JEV_EVAL_ROOTS")
    parser.add_argument("--out", type=Path, default=state_dir() / "jev-eval/dataset.jsonl")
    parser.add_argument("--stats-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        assert_out_of_tree(args.out)
        roots = args.roots
        if roots is None:
            roots = [Path(root) for root in os.environ.get("JEV_EVAL_ROOTS", "").split(":") if root]
        if not roots:
            raise ValueError("pass --roots or set JEV_EVAL_ROOTS")
        records, stats = build_dataset(roots)
        if not args.stats_only:
            write_jsonl(args.out, records)
        print(json.dumps(stats, sort_keys=True))
    except (OSError, ValueError) as error:
        parser.exit(2, f"build_dataset.py: {error}\n")


if __name__ == "__main__":
    main()
