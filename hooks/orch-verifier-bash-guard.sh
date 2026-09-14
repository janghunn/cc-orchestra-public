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
WRAPPERS = {"env", "command", "builtin", "exec", "nohup", "nice", "ionice", "xargs",
            "time", "timeout", "setsid", "stdbuf"}
WRAPPER_VALUES = {
    "env": {"-u", "--unset", "-C", "--chdir"},
    "exec": {"-a"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "-P", "-u"},
    "xargs": {"-a", "--arg-file", "-d", "--delimiter", "-E", "-I", "-L", "-n",
              "--max-lines", "--max-args", "-P", "--max-procs", "-s", "--max-chars",
              "--process-slot-var"},
    "time": {"-f", "--format", "-o", "--output"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*=")
REDIRECT = re.compile(r"(?:[0-9]+)?(<<<|<<-|<<|>>|>&|<&|<>|>\||&>>|&>|>|<)")
PREFIXES = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "}"}


def basename(word):
    return word.rsplit("/", 1)[-1]


def split_env(value):
    """Split static GNU env -S words, including its non-shell escapes.

    Environment-variable values remain unresolved, like other dynamic shell data.
    No command is executed to obtain the resulting argument vector.
    """
    parts, word = [], []
    quote = None
    started = False
    index = 0
    escapes = {"f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
    while index < len(value):
        char = value[index]
        if not quote and char.isspace():
            if started:
                parts.append("".join(word))
            word, started = [], False
        elif not quote and char == "#" and not started:
            break
        elif char == "\\" and index + 1 < len(value):
            escaped = value[index + 1]
            if quote == chr(39) and escaped not in {chr(39), "\\"}:
                word.append(char)
                started = True
                index += 1
                continue
            index += 1
            if escaped == "c" and not quote:
                break
            if escaped == "_" and not quote:
                if started:
                    parts.append("".join(word))
                word, started = [], False
            else:
                word.append(" " if escaped == "_" and quote != chr(39)
                            else escapes.get(escaped, escaped) if quote != chr(39)
                            else escaped)
                started = True
        elif char in (chr(39), "\""):
            if not quote:
                quote = char
            elif quote == char:
                quote = None
            else:
                word.append(char)
            started = True
        else:
            word.append(char)
            started = True
        index += 1
    if started:
        parts.append("".join(word))
    return parts


def unwrap(words, split_codes=None):
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
            split_option = re.fullmatch(r"-[iv0]*S(.*)", option) if wrapper == "env" else None
            if wrapper == "env" and (
                split_option or option == "--split-string"
                or option.startswith("--split-string=")
            ):
                consumed = 1
                if option == "--split-string" or (split_option and not split_option[1]):
                    if index + 1 >= len(words):
                        return []
                    value = words[index + 1]
                    consumed = 2
                else:
                    value = split_option[1] if split_option else option.split("=", 1)[1]
                if split_codes is not None:
                    split_codes.append(value)
                # Preserve the resulting verb for pipeline detection as well as
                # checking the split-string payload as shell-like command text.
                words = words[:index] + split_env(value) + words[index + consumed:]
                continue
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
        if wrapper == "timeout" and index < len(words):
            index += 1  # The duration precedes the command, after timeout options.
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


def substitution(command, start, opener_length=2):
    """Consume a $(...), <(...), or >(...) unit without losing later commands."""
    cursor = start + opener_length
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
                return command[start + opener_length:cursor], cursor + 1
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
            arithmetic = body.startswith("$((", index)
            code, index = substitution(body, index)
            substitutions.extend(heredoc_substitutions(code) if arithmetic else [code])
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
    current = {"words": [], "heredocs": [], "groups": []}
    groups = []
    case = None
    conditional = False
    pending = []
    substitutions = []
    pipe_pending = False
    length = len(command)
    index = 0

    def at_command_position():
        return not current["groups"] and all(
            value in PREFIXES or ASSIGNMENT.match(value) for value in current["words"]
        )

    def open_group(closer):
        nonlocal pipelines, pipeline, current, pipe_pending, case
        groups.append((closer, pipelines, pipeline, current, case))
        pipelines, pipeline = [], []
        current = {"words": [], "heredocs": [], "groups": []}
        case = {"phase": "subject", "depth": 0, "seen": False} if closer == "esac" else None
        pipe_pending = False

    def close_group(closer):
        nonlocal pipelines, pipeline, current, pipe_pending, case
        if not groups or groups[-1][0] != closer:
            raise ValueError("unmatched group terminator")
        body = pipelines + [pipeline + [current]]
        _, pipelines, pipeline, current, case = groups.pop()
        current["groups"].append(body)
        pipe_pending = False

    def word(start, expand=True, data=False):
        cursor = start
        value = []
        quote = None
        while cursor < length:
            char = command[cursor]
            if expand and not quote and command[cursor:cursor + 2] in {"<(", ">("}:
                body, end = substitution(command, cursor)
                substitutions.append(body)
                value.append(command[cursor:end])
                cursor = end
                continue
            if not quote and (char.isspace() or (not data and char in ";|&()<>")):
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
            if expand and quote != chr(39) and command.startswith("$(", cursor):
                body, end = substitution(command, cursor)
                substitutions.extend(heredoc_substitutions(body)
                                     if command.startswith("$((", cursor) else [body])
                value.append(command[cursor:end])
                cursor = end
                continue
            if expand and quote != chr(39) and char == "`":
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
                current = {"words": [], "heredocs": [], "groups": []}
            index += 1
            for delimiter, strip_tabs, quoted, owner in pending:
                body = []
                while index < length:
                    end = command.find("\n", index)
                    if end < 0:
                        end = length
                    line = command[index:end]
                    index = min(end + 1, length)
                    # Bash folds an unescaped backslash-newline before testing an
                    # unquoted heredoc delimiter, including across multiple lines.
                    while not quoted and end < length and (
                        len(line) - len(line.rstrip("\\"))
                    ) % 2:
                        next_end = command.find("\n", index)
                        if next_end < 0:
                            next_end = length
                        line = line[:-1] + command[index:next_end]
                        end = next_end
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
        if conditional:
            if command.startswith("]]", index):
                conditional = False
                index += 2
            else:
                _, index = word(index, data=True)
            continue
        # Case subjects/patterns are data. Only the body after a pattern-closing
        # parenthesis occupies command positions; nested case blocks get frames.
        if case and case["phase"] != "body":
            if case["phase"] == "pattern" and char in "|()":
                if char == "(" and case["seen"]:
                    case["depth"] += 1
                elif char == ")":
                    if case["depth"]:
                        case["depth"] -= 1
                    else:
                        case["phase"] = "body"
                index += 1
                continue
            value, end = word(index)
            if end == index:
                raise ValueError("unsupported case syntax")
            raw = command[index:end]
            if case["phase"] == "subject":
                case["phase"] = "in"
            elif case["phase"] == "in" and raw == "in":
                case["phase"] = "pattern"
            elif case["phase"] == "pattern" and raw == "esac" and not case["seen"]:
                close_group("esac")
            else:
                case["seen"] = True
            index = end
            continue
        if command.startswith("((", index) and (
            at_command_position() or current["words"] == ["for"]
        ):
            body, index = substitution(command, index, opener_length=1)
            substitutions.extend(heredoc_substitutions(body))
            current["words"].append("((arithmetic))")
            continue
        if char == "(":
            open_group(")")
            index += 1
            continue
        if char == ")":
            close_group(")")
            index += 1
            continue
        redirect = (None if command[index:index + 2] in {"<(", ">("}
                    else REDIRECT.match(command, index))
        if redirect:
            pipe_pending = False
            index = redirect.end()
            while index < length and command[index] in " \t":
                index += 1
            is_heredoc = redirect.group(1) in {"<<", "<<-"}
            target, end = word(index, expand=not is_heredoc)
            if end == index:
                raise ValueError("missing redirect target")
            if is_heredoc:
                delimiter_syntax = command[index:end].replace("\\\n", "")
                quoted = any(char in delimiter_syntax for char in (chr(39), "\"", "\\"))
                pending.append((target, redirect.group(1) == "<<-", quoted, current))
            elif redirect.group(1) == "<<<":
                current["heredocs"].append(target)
            index = end
            continue
        if char in ";|&":
            operator = char
            if command[index:index + 3] == ";;&":
                operator = ";;&"
            elif command[index:index + 2] in {"&&", "||", "|&", ";;", ";&"}:
                operator = command[index:index + 2]
            pipeline.append(current)
            current = {"words": [], "heredocs": [], "groups": []}
            pipe_pending = operator in {"|", "|&"}
            if operator not in {"|", "|&"}:
                pipelines.append(pipeline)
                pipeline = []
            if case and operator in {";;", ";&", ";;&"}:
                case.update(phase="pattern", depth=0, seen=False)
            index += len(operator)
            continue
        value, end = word(index)
        if end == index:
            raise ValueError("unsupported shell token")
        raw = command[index:end]
        if raw == "[[" and at_command_position():
            conditional = True
            current["words"].append(raw)
        elif raw == "case" and at_command_position():
            open_group("esac")
        elif raw in {"if", "while", "until", "for", "select"} and at_command_position():
            open_group("fi" if raw == "if" else "done")
            if raw in {"for", "select"}:
                current["words"].append(raw)  # Loop variable/list words are not commands.
        elif raw in {"fi", "done"} and at_command_position():
            close_group(raw)
        elif raw == "esac" and case and at_command_position():
            close_group("esac")
        elif raw == "{" and (at_command_position() or current["groups"]):
            open_group("}")
        elif raw == "}" and groups and groups[-1][0] == "}" and at_command_position():
            close_group("}")
        else:
            current["words"].append(value)
        pipe_pending = False
        index = end
    pipeline.append(current)
    pipelines.append(pipeline)
    if groups:
        raise ValueError("unclosed command group")
    return pipelines, substitutions


def denied_verb(words):
    split_codes = []
    words = unwrap(words, split_codes)
    for code in split_codes:
        try:
            reason = inspect(code)
        except ValueError:
            # env arguments may contain literal shell metacharacters. If its
            # shell-like scan is inapplicable, still check the split argv below
            # and the remaining outer commands instead of aborting everything.
            reason = None
        if reason:
            return reason
    if not words:
        return None
    verb, args = basename(words[0]), words[1:]
    if verb in DESTRUCTIVE or verb.startswith("mkfs."):
        return verb
    if verb == "eval":
        return inspect(" ".join(args))
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


def stage_words(part):
    """A compound stage retains the executable names inside its grouped commands."""
    words = unwrap(part["words"])
    result = [words] if words else []
    bodies = list(part["groups"])
    code, _ = shell_mode(words)
    if words and basename(words[0]) == "eval":
        code = " ".join(words[1:])
    if code is not None:
        bodies.append(lex(code)[0])
    for body in bodies:
        for pipeline in body:
            for child in pipeline:
                result.extend(stage_words(child))
    return result


def stage_heredocs(part):
    result = list(part["heredocs"])
    for body in part["groups"]:
        for pipeline in body:
            for child in pipeline:
                result.extend(stage_heredocs(child))
    return result


def inspect_pipelines(pipelines):
    for pipeline in pipelines:
        verbs = [stage_words(part) for part in pipeline]
        names = [{basename(words[0]) for words in stage} for stage in verbs]
        shell_stdin = [any(shell_mode(words)[1] for words in stage) for stage in verbs]
        for index, part in enumerate(pipeline):
            reason = denied_verb(part["words"])
            if reason:
                return reason
            for body in part["groups"]:
                reason = inspect_pipelines(body)
                if reason:
                    return reason
            downloads = names[index] & {"curl", "wget"}
            if downloads and any(
                stage & SHELLS for stage in names[index + 1:]
            ):
                return sorted(downloads)[0] + " piped to a shell"
            # A heredoc belongs to its command, or flows through a pipe to a shell.
            if any(shell_stdin[index:]):
                for body in stage_heredocs(part):
                    reason = inspect(body)
                    if reason:
                        return reason
    return None


def inspect(command):
    pipelines, substitutions = lex(command)
    for body in substitutions:
        reason = inspect(body)
        if reason:
            return reason
    return inspect_pipelines(pipelines)


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
