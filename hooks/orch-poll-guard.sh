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


def lex(command):
    quotes = []
    inert = []
    pending_heredocs = []
    heredoc_opener = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"\x27]?)([\w.-]+)\2")
    index = 0
    length = len(command)
    while index < length:
        if command[index] == "\n" and pending_heredocs:
            cursor = index + 1
            for delimiter, strip_tabs in pending_heredocs:
                body_start = cursor
                body_end = length
                found_delimiter = False
                while cursor < length:
                    line_end = command.find("\n", cursor)
                    if line_end < 0:
                        line_end = length
                    candidate = command[cursor:line_end].rstrip("\r")
                    if strip_tabs:
                        candidate = candidate.lstrip("\t")
                    if candidate == delimiter:
                        body_end = cursor
                        cursor = line_end + 1 if line_end < length else length
                        found_delimiter = True
                        break
                    if line_end == length:
                        cursor = length
                        break
                    cursor = line_end + 1
                inert.append((body_start, body_end))
                if not found_delimiter:
                    break
            pending_heredocs = []
            index = cursor
            continue

        if command[index] == "\\":
            index += min(2, length - index)
            continue

        if command[index] in ("\"", "\x27"):
            quote = command[index]
            start = index
            index += 1
            closed = False
            while index < length:
                if (
                    quote == "\""
                    and command[index] == "\\"
                    and index + 1 < length
                    and command[index + 1] == "\""
                ):
                    index += 2
                    continue
                if command[index] == quote:
                    index += 1
                    closed = True
                    break
                index += 1
            content_end = index - 1 if closed else index
            content = command[start + 1:content_end]
            quotes.append({
                "start": start,
                "end": index,
                "suppressive": (
                    quote == "\x27" or ("$(" not in content and "`" not in content)
                ),
            })
            continue

        if (
            command[index] == "#"
            and (
                index == 0
                or command[index - 1].isspace()
                or command[index - 1] in ";|&("
            )
        ):
            end = command.find("\n", index)
            if end < 0:
                end = length
            inert.append((index, end))
            index = end
            continue

        opener = heredoc_opener.match(command, index)
        if opener:
            pending_heredocs.append((opener.group(3), opener.group(1) == "-"))
            index = opener.end()
            continue

        index += 1
    return quotes, inert


def blank_spans(command, spans):
    chars = list(command)
    for start, end in spans:
        chars[start:end] = " " * (end - start)
    return "".join(chars)


def at_command_position(text, start):
    index = start - 1
    while index >= 0 and text[index] in " \t":
        index -= 1
    if index < 0 or text[index] in "\n;&|({`\x27\"":
        return True

    word_end = index + 1
    while index >= 0 and (text[index].isalnum() or text[index] == "_"):
        index -= 1
    return text[index + 1:word_end] in ("do", "then", "else", "elif")


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

    quotes, inert = lex(command)
    suppressive_quotes = [
        (quote["start"], quote["end"])
        for quote in quotes
        if quote["suppressive"]
    ]
    syntax_text = blank_spans(command, inert + suppressive_quotes)
    signal_text = blank_spans(command, inert)

    shell_c_pattern = re.compile(r"\b(?:bash|sh|zsh|dash|ksh)\b[^|&;]*\s-c\b")
    for shell_c in shell_c_pattern.finditer(syntax_text):
        for quote in quotes:
            if quote["start"] >= shell_c.end():
                quote["suppressive"] = False
                break

    suppressive_quotes = [
        (quote["start"], quote["end"])
        for quote in quotes
        if quote["suppressive"]
    ]
    syntax_text = blank_spans(command, inert + suppressive_quotes)

    loop_pattern = re.compile(
        r"\b(?:while|until)\b(?P<cond>.*?)\bdo\b(?P<body>.*?)(?:\bdone\b|$)",
        re.S,
    )
    target_pattern = re.compile(r"codex-[\w.-]*\.(?:md|jsonl)\b")
    primitive_pattern = re.compile(
        r"(?:\[|\btest\b|\bgrep\b|\bcat\b|\bls\b|\bstat\b|\bfind\b|\btail\b|\bwc\b)"
    )

    for loop in loop_pattern.finditer(syntax_text):
        if not at_command_position(syntax_text, loop.start()):
            continue

        region_start = loop.start("cond")
        region_end = loop.end("body")
        syntax_region = syntax_text[region_start:region_end]
        signal_region = signal_text[region_start:region_end]
        has_target = ".orchestra/" in signal_region or target_pattern.search(signal_region)
        if (
            re.search(r"\bsleep\b", syntax_region)
            and has_target
            and primitive_pattern.search(syntax_region)
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
