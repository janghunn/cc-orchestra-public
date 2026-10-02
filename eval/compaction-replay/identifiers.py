#!/usr/bin/env python3
"""Conservative, case-sensitive identifier extraction; see protocol.md."""
import sys
sys.dont_write_bytecode = True

import re

CLASSES = ("agentid", "path", "sha", "error")
# Neither UUID segments nor prefixes/suffixes of longer identifiers qualify.
AGENT_RE = re.compile(r"(?<![0-9A-Za-z_-])a[0-9a-f]{16}(?![0-9A-Za-z_-])")
SHA_RE = re.compile(r"(?<![0-9A-Za-z_-])[0-9a-f]{7,40}(?![0-9A-Za-z_-])")
SEG = r"[A-Za-z0-9._@%+~-]+"
PATH_RE = re.compile(r"(?<![A-Za-z0-9._~/-])/?" + SEG + r"(?:/" + SEG + r")+")
URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+")
EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
ERROR_RE = re.compile(
    r"(?i)\b(error|exception|traceback|fatal|failed|failure|panic|denied|refused|not found|no such file)\b")


def extract(text):
    agents = set(AGENT_RE.findall(text))
    shas = {s for s in SHA_RE.findall(text) if s not in agents
            and any(c.isdigit() for c in s) and any(c in "abcdef" for c in s)}
    urls = [m.span() for m in URL_RE.finditer(text)]
    paths = set()
    for match in PATH_RE.finditer(text):
        if any(a <= match.start() < b for a, b in urls):
            continue
        if text[max(0, match.start() - 2):match.start()] == ":/":
            continue
        token = match.group().rstrip(".,:;)]}'\"")
        last = token.rsplit("/", 1)[-1]
        if len(token) >= 4 and (token.startswith("/") or EXT_RE.search(last)
                               or token.count("/") >= 2
                               or re.search(r"[-_0-9]", last)):
            paths.add(token)
    return {"agentid": agents, "path": paths, "sha": shas}


def error_lines(text):
    return {line for raw in text.split("\n")
            if 12 <= len(line := raw.strip()) <= 300 and ERROR_RE.search(line)}


def occurs_error(line, text):
    return line in text
