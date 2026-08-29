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
        while index < length:
            if quote == "\"" and command[index] == "\\":
                index += min(2, length - index)
                continue
            if command[index] == quote:
                index += 1
                break
            index += 1
        spans.append((start, index))
    return spans


def heredoc_spans(command):
    spans = []
    lines = command.splitlines(keepends=True)
    offsets = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    line_index = 0
    opener = re.compile(r"<<(-?)\s*([\"\x27]?)(\w+)\2")
    while line_index < len(lines):
        match = opener.search(lines[line_index])
        if not match:
            line_index += 1
            continue

        delimiter = match.group(3)
        strip_tabs = match.group(1) == "-"
        body_start = offsets[line_index] + len(lines[line_index])
        end = len(command)
        scan = line_index + 1
        while scan < len(lines):
            candidate = lines[scan].rstrip("\r\n")
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == delimiter:
                end = offsets[scan]
                break
            scan += 1
        spans.append((body_start, end))
        line_index = scan + 1 if scan < len(lines) else len(lines)
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

    spans = heredoc_spans(command)
    shell_c = re.search(r"\b(?:bash|sh|zsh|dash|ksh)\b[^|&;]*\s-c\b", command)
    if not shell_c:
        spans.extend(quoted_spans(command))

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

        body = loop.group("body")
        watched_text = loop.group("cond") + body
        has_target = ".orchestra/" in watched_text or target_pattern.search(watched_text)
        if (
            re.search(r"\bsleep\b", body)
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
