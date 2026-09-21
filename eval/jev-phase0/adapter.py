#!/usr/bin/env python3
"""The sole Jev integration boundary; live transport is deferred to Stage 2."""

from dataclasses import dataclass

from common import sha256_text


ADAPTER_VERSION = "phase0-mock-v1"


class AdapterNotReady(RuntimeError):
    pass


@dataclass
class LintResult:
    flagged: bool
    score: float
    raw: dict
    findings: list


@dataclass
class ScanResult:
    flagged: bool
    score: float
    raw: dict
    findings: list


def _result(text, mode, result_type):
    if mode == "live":
        raise AdapterNotReady(
            "adapter.py: lint_brief and scan_text await the Stage 2 transport; "
            "implement orch-jev lint-brief/scan with subprocess.run, a timeout, "
            "temporary input files and stdout parsing here")
    if mode != "mock":
        raise ValueError("unsupported adapter mode")
    score = int(sha256_text(text)[:8], 16) / 0xffffffff
    return result_type(score >= 0.5, score, {"mock": True}, [])


def lint_brief(brief_text, *, mode):
    return _result(brief_text, mode, LintResult)


def scan_text(text, *, mode):
    return _result(text, mode, ScanResult)
