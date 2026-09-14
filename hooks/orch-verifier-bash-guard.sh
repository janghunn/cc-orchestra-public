#!/usr/bin/env bash
# Agent-local PreToolUse guard for verifier Bash calls. This is defense in depth,
# not a shell sandbox or a verdict-path validator. No writable disable switch.
# Like orch-poll-guard.sh, consume stdin JSON and fail open on parsing/runtime errors.
# Registrations also use `|| true` to cover shell errors before this script runs.
set -uo pipefail

payload="$(cat)"
[ -n "$payload" ] || exit 0

printf '%s' "$payload" | python3 -c '
import json
import re
import sys


SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
DESTRUCTIVE = {
    "rm", "mv", "shred", "truncate", "sudo", "chmod", "chown", "chgrp",
    "dd", "mkfs", "shutdown", "reboot",
}
GIT_MUTATIONS = {
    "commit", "push", "checkout", "switch", "reset", "merge", "rebase", "stash",
    "clean", "apply", "add", "config", "rm", "restore",
}
WRAPPERS = {"env", "command", "exec", "nohup", "nice", "ionice", "xargs", "time"}
WRAPPER_VALUES = {
    "env": {"-u", "--unset", "-C", "--chdir"},
    "exec": {"-a"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "-P", "-u"},
    "xargs": {"-a", "--arg-file", "-d", "--delimiter", "-E", "-I", "-L", "-n",
              "--max-lines", "--max-args", "-P", "--max-procs", "-s", "--max-chars",
              "--process-slot-var"},
    "time": {"-f", "--format", "-o", "--output"},
}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*=")
REDIRECT = re.compile(r"(?:[0-9]+)?(<<<|<<-|<<|>>|>&|<&|<>|>\||&>>|&>|>|<)")
PREFIXES = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "}"}


def basename(word):
    return word.rsplit("/", 1)[-1]


def unwrap(words):
    """Expose verbs behind common neutral prefixes without scanning ordinary arguments."""
    index = 0
    while index < len(words):
        if ASSIGNMENT.match(words[index]) or words[index] in PREFIXES:
            index += 1
            continue
        wrapper = basename(words[index])
        if wrapper not in WRAPPERS:
            break
        index += 1
        while index < len(words):
            option = words[index]
            if option == "--":
                index += 1
                break
            if ASSIGNMENT.match(option):
                index += 1
            elif option.startswith("-"):
                # Lookup flags may follow -p or be combined with it.
                if wrapper == "command" and not option.startswith("--") and any(
                    flag in option[1:] for flag in "vV"
                ):
                    return []
                index += 2 if option in WRAPPER_VALUES.get(wrapper, set()) else 1
            else:
                break
    return words[index:]


def shell_mode(words):
    """Return executable -c code and whether the shell executes stdin as code.

    Parse options before selecting the command string: -o/-O and startup-file
    options consume values, while -n/noexec can be combined or later unset.
    Outer-shell expansions are inspected separately even for syntax-only calls.
    """
    if not words or basename(words[0]) not in SHELLS:
        return None, False
    index = 1
    noexec = interactive = command_string = stdin = False
    while index < len(words):
        option = words[index]
        if option == "--":
            index += 1
            break
        if len(option) < 2 or option[0] not in "-+":
            break
        index += 1
        if option in {"--help", "--version"}:
            return None, False
        if option in {"--rcfile", "--init-file"}:
            index += 1
            continue
        if option.startswith("--"):
            continue
        enabled = option[0] == "-"
        for position, flag in enumerate(option[1:], 1):
            if flag in "oO":
                value = option[position + 1:]
                if not value and index < len(words):
                    value = words[index]
                    index += 1
                if flag == "o" and value == "noexec":
                    noexec = enabled
                break
            if flag == "n":
                noexec = enabled
            elif flag == "i":
                interactive = enabled
            elif flag == "c":
                command_string = True
            elif flag == "s":
                stdin = enabled
    # Interactive shells ignore noexec; a later +n/+o noexec also restores execution.
    if noexec and not interactive:
        return None, False
    if command_string:
        return (words[index] if index < len(words) else None), False
    return None, stdin or index >= len(words)


def substitution(command, start):
    """Consume a $(...), <(...), or >(...) unit without losing later commands."""
    cursor = start + 2
    depth = 1
    quote = None
    while cursor < len(command):
        char = command[cursor]
        if char == "\\" and quote != chr(39):
            cursor += 2
            continue
        if quote:
            if char == quote:
                quote = None
        elif char in (chr(39), "\""):
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return command[start + 2:cursor], cursor + 1
        cursor += 1
    raise ValueError("unclosed substitution")


def backtick(command, start):
    cursor = start + 1
    while cursor < len(command):
        if command[cursor] == "\\":
            cursor += 2
        elif command[cursor] == "`":
            return command[start + 1:cursor], cursor + 1
        else:
            cursor += 1
    raise ValueError("unclosed backtick")


def heredoc_substitutions(body):
    """Unquoted heredocs expand substitutions even inside literal quote characters."""
    substitutions = []
    index = 0
    while index < len(body):
        if body[index] == "\\":
            index += 2
        elif body.startswith("$(", index):
            code, index = substitution(body, index)
            substitutions.append(code)
        elif body[index] == "`":
            code, index = backtick(body, index)
            substitutions.append(code)
        else:
            index += 1
    return substitutions


def lex(command):
    """Quote/comment/heredoc-aware scan, adapted from orch-poll-guard.sh.

    Preserve quoted command words, keep data arguments out of command positions,
    and retain heredoc ownership so interpreter input can be scanned as code.
    This intentionally does not implement shell expansion or arbitrary eval.
    """
    pipelines = []
    pipeline = []
    current = {"words": [], "heredocs": []}
    pending = []
    substitutions = []
    pipe_pending = False
    length = len(command)
    index = 0

    def word(start):
        cursor = start
        value = []
        quote = None
        while cursor < length:
            char = command[cursor]
            if not quote and command[cursor:cursor + 2] in {"<(", ">("}:
                body, end = substitution(command, cursor)
                substitutions.append(body)
                value.append(command[cursor:end])
                cursor = end
                continue
            if not quote and (char.isspace() or char in ";|&()<>"):
                break
            if char == "\\" and quote != chr(39):
                if cursor + 1 < length:
                    if command[cursor + 1] != "\n":
                        value.append(command[cursor + 1])
                    cursor += 2
                    continue
            if char in (chr(39), "\""):
                if not quote:
                    quote = char
                    cursor += 1
                    continue
                if char == quote:
                    quote = None
                    cursor += 1
                    continue
            if quote != chr(39) and command.startswith("$(", cursor):
                body, end = substitution(command, cursor)
                substitutions.append(body)
                value.append(command[cursor:end])
                cursor = end
                continue
            if quote != chr(39) and char == "`":
                body, end = backtick(command, cursor)
                substitutions.append(body)
                value.append(command[cursor:end])
                cursor = end
                continue
            value.append(char)
            cursor += 1
        if quote:
            raise ValueError("unclosed quote")
        return "".join(value), cursor

    while index < length:
        char = command[index]
        if char == "\n":
            if not pipe_pending:
                pipeline.append(current)
                pipelines.append(pipeline)
                pipeline = []
                current = {"words": [], "heredocs": []}
            index += 1
            for delimiter, strip_tabs, quoted, owner in pending:
                body = []
                while index < length:
                    end = command.find("\n", index)
                    if end < 0:
                        end = length
                    line = command[index:end]
                    index = min(end + 1, length)
                    candidate = line.lstrip("\t") if strip_tabs else line
                    if candidate == delimiter:
                        break
                    body.append(line)
                body = "\n".join(body)
                owner["heredocs"].append(body)
                if not quoted:
                    substitutions.extend(heredoc_substitutions(body))
            pending = []
            continue
        if char.isspace():
            index += 1
            continue
        if command.startswith("\\\n", index):
            index += 2
            continue
        if char == "#":
            end = command.find("\n", index)
            index = end if end >= 0 else length
            continue
        redirect = (None if command[index:index + 2] in {"<(", ">("}
                    else REDIRECT.match(command, index))
        if redirect:
            pipe_pending = False
            index = redirect.end()
            while index < length and command[index] in " \t":
                index += 1
            target, end = word(index)
            if end == index:
                raise ValueError("missing redirect target")
            if redirect.group(1) in {"<<", "<<-"}:
                quoted = any(char in command[index:end] for char in (chr(39), "\"", "\\"))
                pending.append((target, redirect.group(1) == "<<-", quoted, current))
            elif redirect.group(1) == "<<<":
                current["heredocs"].append(target)
            index = end
            continue
        if char in ";|&()":
            operator = char
            if command[index:index + 2] in {"&&", "||", "|&", ";;"}:
                operator = command[index:index + 2]
            pipeline.append(current)
            current = {"words": [], "heredocs": []}
            pipe_pending = operator in {"|", "|&"}
            if operator not in {"|", "|&"}:
                pipelines.append(pipeline)
                pipeline = []
            index += len(operator)
            continue
        value, end = word(index)
        if end == index:
            raise ValueError("unsupported shell token")
        current["words"].append(value)
        pipe_pending = False
        index = end
    pipeline.append(current)
    pipelines.append(pipeline)
    return pipelines, substitutions


def denied_verb(words):
    words = unwrap(words)
    if not words:
        return None
    verb, args = basename(words[0]), words[1:]
    if verb in DESTRUCTIVE or verb.startswith("mkfs."):
        return verb
    code, _ = shell_mode(words)
    if code is not None:
        reason = inspect(code)
        if reason:
            return reason
    if verb == "git":
        index = 0
        while index < len(args) and args[index].startswith("-"):
            if args[index] == "--":
                index += 1
                break
            index += 2 if args[index] in {"-C", "-c", "--git-dir", "--work-tree",
                                          "--namespace", "--config-env"} else 1
        if index < len(args):
            subcommand = args[index]
            if subcommand in GIT_MUTATIONS:
                return "git " + subcommand
            if subcommand == "branch" and any(
                arg == "--delete" or (arg.startswith("-") and not arg.startswith("--")
                                      and ("d" in arg or "D" in arg))
                for arg in args[index + 1:]
            ):
                return "git branch deletion"
    if verb == "find":
        index = 0
        while index < len(args):
            arg = args[index]
            if arg == "-delete":
                return "find -delete"
            if arg in {"-exec", "-execdir", "-ok", "-okdir"}:
                end = index + 1
                while end < len(args) and args[end] not in {";", "+"}:
                    end += 1
                reason = denied_verb(args[index + 1:end])
                if reason:
                    return "find " + arg + " " + reason
                index = end + 1
            # Predicate values and print formats are data, not find actions.
            elif arg == "-fprintf":
                index += 3
            elif arg in {"-name", "-iname", "-path", "-ipath", "-wholename",
                         "-iwholename", "-regex", "-iregex", "-lname", "-ilname",
                         "-printf", "-fprint", "-fprint0", "-fls", "-newer",
                         "-anewer", "-cnewer", "-samefile", "-user", "-group",
                         "-fstype", "-regextype"} or re.fullmatch(r"-newer[a-zA-Z]{2}", arg):
                index += 2
            else:
                index += 1
    return None


def inspect(command):
    pipelines, substitutions = lex(command)
    for body in substitutions:
        reason = inspect(body)
        if reason:
            return reason
    for pipeline in pipelines:
        verbs = [unwrap(part["words"]) for part in pipeline]
        names = [basename(words[0]) if words else "" for words in verbs]
        shell_stdin = [shell_mode(words)[1] for words in verbs]
        for index, part in enumerate(pipeline):
            words = verbs[index]
            reason = denied_verb(words)
            if reason:
                return reason
            if names[index] in {"curl", "wget"} and any(
                name in SHELLS for name in names[index + 1:]
            ):
                return names[index] + " piped to a shell"
            # A heredoc belongs to its command, or flows through a pipe to a shell.
            if any(shell_stdin[index:]):
                for body in part["heredocs"]:
                    reason = inspect(body)
                    if reason:
                        return reason
    return None


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
    reason = inspect(command)
    if reason:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Verifier Bash policy forbids " + reason + ". Run read-only inspection "
                    "or the legitimate verification commands, and write only your verdict file. "
                    "Report a forbidden verification command as a finding; do not bypass the guard."
                ),
            }
        }))
except Exception:
    pass
' 2>/dev/null || true

exit 0
