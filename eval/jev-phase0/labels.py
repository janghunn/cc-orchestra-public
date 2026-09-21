#!/usr/bin/env python3
"""Export sourced reasons and reconcile independent reason-level labels."""

import argparse
from collections import Counter
from pathlib import Path

from common import assert_out_of_tree, read_jsonl, state_dir, write_jsonl


CATEGORIES = ("criterion-unverifiable", "repo-fact-mismatch", "scope-overlap", "process", "other")


def worklist(records):
    return [{key: reason[key] for key in
             ("reason_id", "source_path", "source_line", "text", "category_hint") if key in reason}
            for record in records if record["verdict"] in ("amended", "defective")
            for reason in record.get("reasons", [])]


def indexed(rows):
    result = {}
    for row in rows:
        reason_id = row["reason_id"]
        if reason_id in result:
            raise ValueError("duplicate reason id")
        result[reason_id] = row
    return result


def reconcile(reasons, proposal, adjudication):
    sources, a, b = map(indexed, (reasons, proposal, adjudication))
    if sources.keys() != a.keys() or sources.keys() != b.keys():
        raise ValueError("both label sets must cover exactly the worklist reason ids")
    final = []
    for reason_id, source in sources.items():
        for label in (a[reason_id], b[reason_id]):
            if label.get("category") not in (*CATEGORIES, "ambiguous"):
                raise ValueError("invalid label category")
            span = label.get("evidence_span")
            if not isinstance(span, str) or not span or span not in source["text"]:
                raise ValueError("evidence_span must be a nonempty verbatim span of its reason")
            if source.get("category_hint") == "process" and label["category"] not in ("process", "ambiguous"):
                raise ValueError("mid-task amendment reasons must remain process or ambiguous")
        left, right = a[reason_id], b[reason_id]
        agreed = left["category"] == right["category"]
        final.append({"reason_id": reason_id, "source_path": source["source_path"],
                      "source_line": source["source_line"],
                      "category": left["category"] if agreed else "ambiguous",
                      "evidence_span": left["evidence_span"] if agreed else None,
                      "labeler_a": left, "labeler_b": right, "agreed": agreed})
    return final


def agreement_note(labels):
    n = len(labels)
    a = Counter(row["labeler_a"]["category"] for row in labels)
    b = Counter(row["labeler_b"]["category"] for row in labels)
    final = Counter(row["category"] for row in labels)
    observed = sum(row["agreed"] for row in labels) / n if n else None
    expected = sum(a[key] * b[key] for key in (*CATEGORIES, "ambiguous")) / n**2 if n else None
    kappa = (observed - expected) / (1 - expected) if n and expected < 1 else None
    lines = ["# Reason-label agreement", "", f"Reasons: {n}",
             f"Raw agreement rate: {observed:.6f}" if n else "Raw agreement rate: undefined",
             f"Cohen's kappa: {kappa:.6f}" if kappa is not None else "Cohen's kappa: undefined",
             f"Ambiguous count: {final['ambiguous']}", "",
             "| Category | Proposal | Adjudication | Final |", "|---|---:|---:|---:|"]
    lines += [f"| {key} | {a[key]} | {b[key]} | {final[key]} |" for key in (*CATEGORIES, "ambiguous")]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--emit-worklist", action="store_true")
    action.add_argument("--ingest", action="store_true")
    directory = state_dir() / "jev-eval"
    parser.add_argument("--dataset", type=Path, default=directory / "dataset.jsonl")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--proposal", type=Path)
    parser.add_argument("--adjudication", type=Path)
    parser.add_argument("--agreement-note", type=Path,
                        default=Path(__file__).parent / "agreement-note.md")
    args = parser.parse_args(argv)
    output = args.out or directory / ("worklist.jsonl" if args.emit_worklist else "labels.jsonl")
    try:
        assert_out_of_tree(output)
        reasons = worklist(read_jsonl(args.dataset))
        if args.emit_worklist:
            write_jsonl(output, reasons)
            print(f"worklist_reasons: {len(reasons)}")
        else:
            if not args.proposal or not args.adjudication:
                raise ValueError("--ingest requires --proposal and --adjudication")
            # The spec explicitly permits this counts-only note in the checkout.
            # Reject aliases of inputs/outputs so it cannot clobber private artifacts.
            protected = [args.dataset, output, args.proposal, args.adjudication]
            if args.agreement_note.resolve() in {path.resolve() for path in protected}:
                raise ValueError("agreement note must have a distinct path")
            final = reconcile(reasons, read_jsonl(args.proposal), read_jsonl(args.adjudication))
            write_jsonl(output, final)
            args.agreement_note.parent.mkdir(parents=True, exist_ok=True)
            args.agreement_note.write_text(agreement_note(final), encoding="utf-8")
            print(f"labeled_reasons: {len(final)} ambiguous: {sum(r['category'] == 'ambiguous' for r in final)}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        # JSON parser exceptions can contain input snippets; keep them private.
        from common import OutOfTreeError
        message = str(error) if isinstance(error, OutOfTreeError) else "invalid label input or output"
        parser.exit(2, f"labels.py: {message}\n")


if __name__ == "__main__":
    main()
