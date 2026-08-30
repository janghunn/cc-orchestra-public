#!/usr/bin/env bash
# PreToolUse guard: deny Bash loops that manually poll cc-orchestra gate artifacts.
# Denial requires a sleep loop, a gate-artifact target, and a file-watch primitive. Parsing and
# runtime failures fail open: this script always exits 0, and registration must add `|| true` to
# cover shell parse errors before the script can run. Disable via
# ${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/poll-guard.off.
set -uo pipefail

state_dir="${CC_ORCH_STATE_DIR:-${HOME:-}/.claude/orchestra-state}"
[ -e "$state_dir/poll-guard.off" ] && exit 0

payload="$(cat)"
[ -n "$payload" ] || exit 0

printf '%s' "$payload" | python3 -c '
import json
import re
import sys


def quoted_spans(command):
    spans = []
    index = 0
    length = len(command)
    while index < length:
        quote = command[index]
        if quote not in ("\"", "\x27"):
            index += 1
            continue

        start = index
        index += 1
        closed = False
        while index < length:
            if quote == "\"" and command[index] == "\\":
                index += min(2, length - index)
                continue
            if command[index] == quote:
                index += 1
                closed = True
                break
            index += 1
        content_end = index - 1 if closed else index
        content = command[start + 1:content_end]
        spans.append({
            "start": start,
            "end": index,
            "suppressive": quote == "\x27" or ("$(" not in content and "`" not in content),
        })
    return spans


def inside(position, spans):
    return any(start <= position < end for start, end in spans)


def comment_spans(command, quotes):
    spans = []
    quote_ranges = [(quote["start"], quote["end"]) for quote in quotes]
    index = 0
    while index < len(command):
        if (
            command[index] == "#"
            and not inside(index, quote_ranges)
            and (
                index == 0
                or command[index - 1].isspace()
                or command[index - 1] in ";|&("
            )
        ):
            end = command.find("\n", index)
            if end < 0:
                end = len(command)
            spans.append((index, end))
            index = end
        else:
            index += 1
    return spans


def heredoc_spans(command, quotes, comments):
    spans = []
    quote_ranges = [(quote["start"], quote["end"]) for quote in quotes]
    protected = quote_ranges + comments
    opener = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"\x27]?)(\w+)\2")
    for match in opener.finditer(command):
        if inside(match.start(), protected + spans):
            continue

        delimiter = match.group(3)
        strip_tabs = match.group(1) == "-"
        opener_line_end = command.find("\n", match.end())
        if opener_line_end < 0:
            spans.append((len(command), len(command)))
            continue

        body_start = opener_line_end + 1
        end = len(command)
        cursor = body_start
        while cursor < len(command):
            line_end = command.find("\n", cursor)
            if line_end < 0:
                line_end = len(command)
            candidate = command[cursor:line_end].rstrip("\r")
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == delimiter:
                end = cursor
                break
            if line_end == len(command):
                break
            cursor = line_end + 1
        spans.append((body_start, end))
    return spans


try:
    event = json.load(sys.stdin)
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        raise SystemExit(0)
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        raise SystemExit(0)
    command = tool_input.get("command")
    if not isinstance(command, str):
        raise SystemExit(0)

    quotes = quoted_spans(command)
    comments = comment_spans(command, quotes)
    heredocs = heredoc_spans(command, quotes, comments)
    shell_c_pattern = re.compile(r"\b(?:bash|sh|zsh|dash|ksh)\b[^|&;]*\s-c\b")
    for shell_c in shell_c_pattern.finditer(command):
        for quote in quotes:
            if quote["start"] > shell_c.end():
                quote["suppressive"] = False
                break

    spans = comments + heredocs + [
        (quote["start"], quote["end"])
        for quote in quotes
        if quote["suppressive"]
    ]

    loop_pattern = re.compile(
        r"\b(?:while|until)\b(?P<cond>.*?)\bdo\b(?P<body>.*?)(?:\bdone\b|$)",
        re.S,
    )
    target_pattern = re.compile(r"codex-[\w.-]*\.(?:md|jsonl)\b")
    primitive_pattern = re.compile(
        r"(?:\[|\btest\b|\bgrep\b|\bcat\b|\bls\b|\bstat\b|\bfind\b|\btail\b|\bwc\b)"
    )

    for loop in loop_pattern.finditer(command):
        start, end = loop.span()
        if any(span_start <= start and end <= span_end for span_start, span_end in spans):
            continue

        watched_text = loop.group("cond") + loop.group("body")
        has_target = ".orchestra/" in watched_text or target_pattern.search(watched_text)
        if (
            re.search(r"\bsleep\b", watched_text)
            and has_target
            and primitive_pattern.search(watched_text)
        ):
            reason = (
                "Manual polling of background gate artifacts (.orchestra/ or codex-*.md/jsonl) "
                "is forbidden. Wait for the automatic completion notification, or arm exactly "
                "ONE bounded Monitor tool call; do NOT retry the same command in a plain Bash call."
            )
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }))
            break
except Exception:
    pass
' 2>/dev/null || true

exit 0
