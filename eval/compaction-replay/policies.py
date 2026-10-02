#!/usr/bin/env python3
"""Policies see only the current pre-cut epoch, never subsequent events."""
import sys
sys.dont_write_bytecode = True

import hashlib
import importlib.util
from pathlib import Path

from identifiers import extract, error_lines


def load_jev(name):
    spec = importlib.util.spec_from_file_location(
        "jev_" + name, Path(__file__).resolve().parents[1] / "jev-phase0" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scan_record = load_jev("secrets").scan_record
PINNED_MESSAGES = 6
P1_KEEP = 10
TRUNCATE_CHARS = 300
SMALL_BYTES = 2048
IDENTIFIERS_PER_KIB = 4
PINNED_TOOLS = {"Agent", "Task", "SendMessage", "ListAgents", "TaskOutput"}
DROP_TOOLS = {"Read", "WebFetch", "WebSearch", "Glob", "Grep", "ToolSearch"}


def epoch_start(events, cut):
    # A real cut is at (not after) its boundary; that boundary ends the old epoch.
    return next((i + 1 for i in range(cut - 1, -1, -1)
                 if events[i].kind == "boundary"), 0)


def fake_scorer(tool_name, input_text, result_text):
    return (hashlib.sha256(input_text.encode()).hexdigest()[0] in "01234567",
            hashlib.sha256(result_text.encode()).hexdigest()[0] in "0123")


def retained_text(text, outcome):
    return text if outcome == "keep" else text[:TRUNCATE_CHARS] if outcome == "truncate" else ""


def decide(policy, events, cut, ctx=None):
    ctx = {} if ctx is None else ctx
    pre = events[epoch_start(events, cut):cut]
    pinned = set()
    for event in reversed(pre):
        if event.msg_key:
            pinned.add(event.msg_key)
        if len(pinned) == PINNED_MESSAGES:
            break
    results = [e for e in pre if e.kind == "result"]
    next_nonresult, adjacency = None, {}
    for i in range(len(pre) - 1, -1, -1):
        if pre[i].kind == "result":
            adjacency[i] = next_nonresult == "user_text"
        else:
            next_nonresult = pre[i].kind
    outcomes, ordinal = [], 0
    for i, event in enumerate(pre):
        if event.kind != "result":
            continue
        ordinal += 1
        if policy == "P0" or event.msg_key in pinned:
            outcome = "keep"
        elif policy == "P1":
            outcome = "keep" if ordinal > len(results) - P1_KEEP else "drop"
        elif policy == "P2":
            tokens = extract(event.text)
            size = len(event.text.encode("utf-8"))
            if (event.name in PINNED_TOOLS or "REGISTRY" in event.input_text
                    or tokens["agentid"] or adjacency[i] or event.is_error
                    or error_lines(event.text) or size <= SMALL_BYTES
                    or (len(tokens["path"]) + len(tokens["sha"])) * 1024 / max(1, size)
                    >= IDENTIFIERS_PER_KIB):
                outcome = "keep"
            else:
                outcome = "drop" if event.name in DROP_TOOLS else "truncate"
        elif policy == "P3":
            if any(scan_record(t)[0] for t in (event.name, event.input_text, event.text)):
                ctx["p3_secret_skips"] = ctx.get("p3_secret_skips", 0) + 1
                outcome = "keep"
            else:
                try:
                    call, verbatim = ctx["scorer"](event.name, event.input_text, event.text)
                    outcome = "keep" if verbatim else "truncate" if call else "drop"
                except Exception:
                    ctx["p3_errors"] = ctx.get("p3_errors", 0) + 1
                    outcome = "keep"
        else:
            raise ValueError("unknown policy")
        outcomes.append(outcome)
    return outcomes
