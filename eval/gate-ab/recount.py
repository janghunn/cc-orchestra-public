#!/usr/bin/env python3
"""Validate and render the frozen gate A/B historical tabulation."""

import csv
import os
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("GATE_AB_ROOT", "/home/janghun/.claude/orchestra-state/worktrees/cc-orchestra"))
ROW_HEADER = "id,task,series,risk,stage,implementer,implementer_family,defect,severity,disposition,first_gate,first_round,also_reported_by,missed_then_caught,ran_not_reported,not_run,sources,confidence,note".split(",")
INV_HEADER = "task,series,risk,status,implementer_lanes,implementer_family,gates_run,rounds_detailed,rounds_summary,rounds_agree,rows,zero_row_reason,sources".split(",")
CORE = ("lead-diff-review", "codex-verify", "codex-review", "claude-verifier-opus", "claude-verifier-normal")
PLAIN = set(CORE) | {"lead-plan", "codex-intake", "codex-plan-review", "codex-audit", "codex-orchestrator", "implementer-self-test", "orchestrator", "user"}
BLOCKS = ("rows", "inventory", "matrix", "buckets")


def read_csv(name, header, errors):
    with (HERE / name).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != header:
            errors.append(f"{name}: wrong header {reader.fieldnames!r}")
        rows = []
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                errors.append(f"{name}: line {reader.line_num}: wrong field count")
            rows.append(row)
        return rows


def split(value):
    return [part for part in value.split(";") if part]


def gate(token):
    return token.split("@", 1)[0]


def valid_gate(token):
    if token in PLAIN:
        return True
    match = re.fullmatch(r"later-task:([JCS]\d{2})/(.+)", token)
    return bool(match and match.group(2) in PLAIN)


def family(token, implementer):
    name = token.split("/", 1)[-1]
    if name.startswith("codex-"):
        return "codex"
    if name.startswith(("lead-", "claude-verifier")) or name == "orchestrator":
        return "claude"
    if name == "user":
        return "human"
    if name == "implementer-self-test":
        return implementer
    return "unknown"


def validate(rows, inventory):
    errors = []
    ids = set()
    counts = Counter(row["task"] for row in rows)
    inv_tasks = set()
    for row in rows:
        rid = row["id"]
        if rid in ids or not re.fullmatch(r"[JCS]\d{2}-d[1-9]\d*", rid):
            errors.append(f"{rid}: duplicate or malformed id")
        ids.add(rid)
        task_pattern = {"J": rf"ccorch/\.orchestra/{rid[1:3]}-",
                        "C": rf"cc-orchestra/\.orchestra/{rid[1:3]}-",
                        "S": rf"self-hosting-\d+/\.orchestra/{rid[1:3]}-"}.get(rid[:1], r"(?!)")
        if not re.match(task_pattern, row["task"]):
            errors.append(f"{rid}: id does not match task path")
        if row["series"] != rid[0] or row["risk"] not in {"trivial", "low", "normal", "critical"}:
            errors.append(f"{rid}: series/risk vocabulary")
        if row["stage"] not in {"design", "diff", "post-merge"} or row["disposition"] not in {"fixed", "fixed-later-task", "accepted", "rejected", "unresolved"}:
            errors.append(f"{rid}: stage/disposition vocabulary")
        if row["implementer_family"] not in {"codex", "claude", "mixed", "unknown", "n/a"} or row["confidence"] not in {"high", "medium", "low"}:
            errors.append(f"{rid}: family/confidence vocabulary")
        impl = row["implementer"]
        if not (impl in {"n/a", "lead", "unknown", "codex:unknown"} or re.fullmatch(r"codex:[A-Za-z0-9._-]+@[A-Za-z0-9._-]+|dev(?:-opus)?-[1-9]\d*:[A-Za-z0-9._-]+", impl)):
            errors.append(f"{rid}: implementer vocabulary")
        if row["stage"] == "design" and (row["implementer"] != "n/a" or row["implementer_family"] != "n/a" or row["first_round"] != "pre"):
            errors.append(f"{rid}: design attribution")
        if row["stage"] == "post-merge" and row["first_round"] != "post":
            errors.append(f"{rid}: post-merge round")
        if row["stage"] == "diff" and not re.fullmatch(r"r[1-9]\d*", row["first_round"]):
            errors.append(f"{rid}: diff round")
        if not row["defect"] or not row["severity"]:
            errors.append(f"{rid}: missing defect/severity")
        if not valid_gate(row["first_gate"]):
            errors.append(f"{rid}: invalid first gate")
        reported = {row["first_gate"]} | {gate(t) for t in split(row["also_reported_by"])}
        ran = {gate(t) for t in split(row["ran_not_reported"])}
        absent = set(split(row["not_run"]))
        missed = {gate(t) for t in split(row["missed_then_caught"])}
        for field in ("also_reported_by", "missed_then_caught", "ran_not_reported"):
            for token in split(row[field]):
                parts = token.rsplit("@", 1)
                if len(parts) != 2 or not valid_gate(parts[0]) or not re.fullmatch(r"r[1-9]\d*|pre|post", parts[1]):
                    errors.append(f"{rid}: invalid {field} token {token}")
        allowed_absent = {"codex-plan-review"} if row["stage"] == "design" else set(CORE)
        if any(t not in allowed_absent for t in absent) or len(split(row["not_run"])) != len(absent):
            errors.append(f"{rid}: invalid not_run token")
        if not missed <= reported:
            errors.append(f"{rid}: missed_then_caught without report")
        for core in (("codex-plan-review",) if row["stage"] == "design" else CORE):
            membership = sum(core in group for group in (reported, ran, absent))
            if membership != 1:
                errors.append(f"{rid}: partition {core} in {membership} sets")
        paths = split(row["sources"])
        if not paths:
            errors.append(f"{rid}: no sources")
        for source in paths:
            path = source.split(":", 1)[0]
            if Path(path).is_absolute() or not (ROOT / path).exists():
                errors.append(f"{rid}: missing source {path}")
    for item in inventory:
        task = item["task"]
        if task in inv_tasks:
            errors.append(f"inventory: duplicate {task}")
        inv_tasks.add(task)
        if item["status"] not in {"included", "excluded"} or item["implementer_family"] not in {"codex", "claude", "mixed", "none", "unknown", "n/a"}:
            errors.append(f"inventory: vocabulary {task}")
        if item["rows"] != str(counts[task]):
            errors.append(f"inventory: count {task}: {item['rows']} != {counts[task]}")
        if item["rows"] == "0" and not item["zero_row_reason"]:
            errors.append(f"inventory: no zero-row reason {task}")
        if item["status"] == "included" and item["risk"] not in {"trivial", "low", "normal", "critical"}:
            errors.append(f"inventory: risk {task}")
        if item["series"] not in ({"J", "C", "S"} if item["status"] == "included" else {"n/a"}):
            errors.append(f"inventory: series {task}")
        if item["rounds_agree"] not in {"yes", "no", "n/a"}:
            errors.append(f"inventory: rounds_agree {task}")
        for field in ("rounds_detailed", "rounds_summary"):
            if not re.fullmatch(r"\d+|n/a", item[field]):
                errors.append(f"inventory: {field} {task}")
        for token in split(item["gates_run"]):
            parts = token.rsplit("@", 1)
            if len(parts) != 2 or not valid_gate(parts[0]) or not re.fullmatch(r"r[1-9]\d*|pre|post", parts[1]):
                errors.append(f"inventory: invalid gates_run token {token} for {task}")
        for source in split(item["sources"]):
            path = source.split(":", 1)[0]
            if Path(path).is_absolute() or not (ROOT / path).exists():
                errors.append(f"inventory: missing source {source}")
    for task in counts:
        if task not in inv_tasks:
            errors.append(f"inventory: missing task {task}")
    return errors


def table(header, records):
    escape = lambda value: str(value).replace("|", "\\|").replace("\n", "<br>")
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    lines += ["| " + " | ".join(escape(value) for value in record) + " |" for record in records]
    return "\n".join(lines) + "\n"


def reporters(row):
    return [row["first_gate"]] + [gate(t) for t in split(row["also_reported_by"])]


def aggregate(token):
    if token.startswith("later-task:"):
        return "later-task/" + token.split("/", 1)[1]
    return token


def matrix(rows):
    header = ("gate", "caught-first", "caught-also", "caught-total", "missed-then-caught", "ran-missed", "not-run")
    diff = [r for r in rows if r["stage"] in {"diff", "post-merge"} and r["disposition"] != "rejected"]
    design = [r for r in rows if r["stage"] == "design" and r["disposition"] != "rejected"]
    lines = ["#### Diff and post-merge defects", ""]
    entries = []
    for g in CORE:
        first = sum(r["first_gate"] == g for r in diff)
        also = sum(g in [gate(t) for t in split(r["also_reported_by"])] for r in diff)
        total = sum(g in reporters(r) for r in diff)
        missed = sum(g in [gate(t) for t in split(r["missed_then_caught"])] for r in diff)
        ran = sum(g in [gate(t) for t in split(r["ran_not_reported"])] for r in diff)
        absent = sum(g in split(r["not_run"]) for r in diff)
        entries.append((g, first, also, total, missed, ran, absent))
    other = sorted(({aggregate(t) for r in diff for t in reporters(r)}
                    | {"codex-plan-review", "codex-audit", "codex-orchestrator", "lead-plan", "implementer-self-test", "orchestrator", "user"}) - set(CORE))
    for g in other:
        first = sum(aggregate(r["first_gate"]) == g for r in diff)
        also = sum(g in {aggregate(gate(t)) for t in split(r["also_reported_by"])} for r in diff)
        entries.append((g, first, also, sum(g in {aggregate(t) for t in reporters(r)} for r in diff), "-", "-", "-"))
    lines += [table(header, entries).rstrip(), ""]
    flagged = sum("lead-review-unrecorded" in r["note"] for r in diff if "lead-diff-review" in split(r["not_run"]))
    lines += [f"lead-diff-review not-run rows flagged lead-review-unrecorded: {flagged}", "", "#### Design defects", ""]
    entries = []
    for g in ("codex-plan-review", "lead-plan"):
        first = sum(r["first_gate"] == g for r in design)
        also = sum(g in [gate(t) for t in split(r["also_reported_by"])] for r in design)
        entries.append((g, first, also, sum(g in reporters(r) for r in design), sum(g in [gate(t) for t in split(r["missed_then_caught"])] for r in design), sum(g in [gate(t) for t in split(r["ran_not_reported"])] for r in design), sum(g in split(r["not_run"]) for r in design)))
    rejected = Counter(r["first_gate"] for r in rows if r["disposition"] == "rejected")
    lines += [table(header, entries).rstrip(), "", "Rejected rows by first_gate: " + (", ".join(f"{key}={value}" for key, value in sorted(rejected.items())) or "none"), ""]
    return "\n".join(lines) + "\n"


def buckets(rows, inventory):
    diff = [r for r in rows if r["stage"] in {"diff", "post-merge"} and r["disposition"] != "rejected"]
    def bucket(row):
        families = {family(t, row["implementer_family"]) for t in reporters(row)}
        if families == {"codex"}: return "codex-only"
        if families == {"claude"}: return "claude-only"
        if {"codex", "claude"} <= families: return "both"
        return "other-only"
    header = ("implementer-family", "codex-only", "claude-only", "both", "other-only", "total", "escaped-in-task-gates")
    entries = []
    for fam in ("codex", "claude", "mixed", "unknown"):
        group = [r for r in diff if r["implementer_family"] == fam]
        entries.append((fam,) + tuple(sum(bucket(r) == key for r in group) for key in header[1:5]) + (len(group), sum(r["stage"] == "post-merge" for r in group)))
    codex = [r for r in diff if r["implementer_family"] == "codex"]
    claude = [r for r in diff if r["implementer_family"] == "claude"]
    ids = lambda group, key: ", ".join(r["id"] for r in group if bucket(r) == key) or "none"
    claude_only = [r for r in codex if bucket(r) == "claude-only"]
    codex_only = [r for r in codex if bucket(r) == "codex-only"]
    ran = lambda row, gates: bool({gate(t) for t in split(row["ran_not_reported"])} & gates)
    codex_missed = [r for r in claude_only if ran(r, {"codex-verify", "codex-review"})]
    before_codex = [r for r in claude_only if r not in codex_missed]
    claude_missed = [r for r in codex_only if ran(r, {"lead-diff-review", "claude-verifier-opus", "claude-verifier-normal"})]
    id_list = lambda group: ", ".join(r["id"] for r in group) or "none"
    def risk_split(group):
        counts = Counter(r["risk"] for r in group)
        return "Risk split: " + ", ".join(f"{risk}={counts[risk]}" for risk in ("critical", "normal", "low", "trivial"))
    first_reporters = Counter(aggregate(r["first_gate"]) for r in codex_missed)
    first_reporter_split = "First reporter split: " + ", ".join(f"{gate}={count}" for gate, count in sorted(first_reporters.items()))
    dispositions = Counter(r["disposition"] for r in claude_only)
    included = [item for item in inventory if item["status"] == "included"]
    denom = Counter(item["implementer_family"] for item in included)
    return (table(header, entries) + "\n"
            + f"Codex-written & Claude-only IDs: {ids(codex, 'claude-only')}\n\n"
            + f"Claude-written & Codex-only IDs: {ids(claude, 'codex-only')}\n\n"
            + f"Codex-written & Codex-only IDs: {ids(codex, 'codex-only')}\n\n"
            + f"Codex-written, Claude-only, Codex verify/review ran over it and missed: {len(codex_missed)}; IDs: {id_list(codex_missed)}.\n"
            + f"{risk_split(codex_missed)}\n"
            + f"{first_reporter_split}\n\n"
            + f"Codex-written, Claude-only, caught before any Codex gate ran: {len(before_codex)}; IDs: {id_list(before_codex)}.\n"
            + f"{risk_split(before_codex)}\n\n"
            + f"Codex-written, Codex-only, a Claude-family check ran over it and missed: {len(claude_missed)}; IDs: {id_list(claude_missed)}.\n"
            + f"{risk_split(claude_missed)}\n\n"
            + f"Codex-written, Claude-only dispositions: fixed={dispositions['fixed']}; accepted={dispositions['accepted']}; fixed-later-task={dispositions['fixed-later-task']}.\n\n"
            + f"Included task denominators: codex={denom['codex']}; claude={denom['claude']}; mixed={denom['mixed']}; none={denom['none']}.\n\n"
            + f"Codex-written diff defects reported only by Claude-family checks: {sum(bucket(r) == 'claude-only' for r in codex)} of {len(codex)}; Claude-written diff defects reported only by Codex gates: {sum(bucket(r) == 'codex-only' for r in claude)} of {len(claude)}.\n")


def render(rows, inventory):
    return {"rows": table(ROW_HEADER, ([r[key] for key in ROW_HEADER] for r in rows)),
            "inventory": table(INV_HEADER, ([r[key] for key in INV_HEADER] for r in inventory)),
            "matrix": matrix(rows), "buckets": buckets(rows, inventory)}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"render", "check"}:
        print("usage: recount.py {render|check}", file=sys.stderr)
        return 2
    errors = []
    rows = read_csv("tabulation.csv", ROW_HEADER, errors)
    inventory = read_csv("inventory.csv", INV_HEADER, errors)
    if errors:
        print("\n".join(f"CHECK FAIL: {error}" for error in errors), file=sys.stderr)
        return 1
    errors += validate(rows, inventory)
    blocks = render(rows, inventory)
    if sys.argv[1] == "render":
        for name in BLOCKS:
            print(f"<!-- BEGIN {name} -->")
            print(blocks[name], end="")
            print(f"<!-- END {name} -->")
        return 0 if not errors else 1
    document = (HERE / "tabulation.md").read_text(encoding="utf-8")
    for name in BLOCKS:
        match = re.search(rf"<!-- BEGIN {name} -->\n(.*?)<!-- END {name} -->", document, re.S)
        if not match or match.group(1).rstrip() != blocks[name].rstrip():
            errors.append(f"tabulation.md: {name} block differs")
    if errors:
        print("\n".join(f"CHECK FAIL: {error}" for error in errors))
        return 1
    print(f"CHECK OK: {len(rows)} rows, {sum(i['status'] == 'included' for i in inventory)} tasks read, {sum(i['status'] == 'included' and int(i['rows']) > 0 for i in inventory)} tasks contributed rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
