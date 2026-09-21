#!/usr/bin/env python3
"""Frozen, free acceptance-item heuristic."""

import re


DEFAULT_THRESHOLD = 0.34
THRESHOLDS = tuple(i / 10 for i in range(11))
EVIDENCE_RE = re.compile(
    r"`[^`]+`|[^\s]*\/[^\s]*\.[\w]+|"
    r"\b\w+\.(?:py|sh|md|json|jsonl|yaml|yml|txt|conf|toml|csv)\b|"
    r"\d|\"[^\"]+\"|'[^']+'")


def item_is_unverifiable(item):
    return EVIDENCE_RE.search(item) is None


def score_brief(record):
    items = record.get("acceptance_items", [])
    if not items:
        return None
    return sum(item_is_unverifiable(item) for item in items) / len(items)


def predict(record, threshold=DEFAULT_THRESHOLD):
    score = score_brief(record)
    return score is not None and score >= threshold
