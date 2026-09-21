#!/usr/bin/env python3
"""Scanner parity using ASCII classes instead of locale-dependent Bash case folding."""

import re


AWS_RE = re.compile(r"AKIA[0-9A-Z]{16}")
SECRET_RE = re.compile(
    r"(^|[^a-z0-9_])(key|token|secret|password|api[_-]?key)[\"']?"
    r"[ \t\v\f\r]*[:=][ \t\v\f\r]*[\"'][a-z0-9_/+=-]{20,}[\"']")
PLACEHOLDER_RE = re.compile(
    r"example|xxx|changeme|your_|redacted|dummy|placeholder|<[a-z_]+>|\$\{|todo")


def is_secret_shaped(line):
    low = line.lower()
    return bool(AWS_RE.search(line) or
                (SECRET_RE.search(low) and not PLACEHOLDER_RE.search(low)))


def scan_record(text):
    # Bash read splits on LF only, not vertical tab, form feed, or CR.
    for number, line in enumerate(text.split("\n"), 1):
        if is_secret_shaped(line):
            return True, number
    return False, None
