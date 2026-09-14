#!/usr/bin/env bash
# Runtime safety worktree-guard; failures always allow. Registration must retain `|| true`.
set -uo pipefail
state_dir="${CC_ORCH_STATE_DIR:-${HOME:-}/.claude/orchestra-state}"
[ -e "$state_dir/worktree-guard.off" ] && exit 0
payload="$(cat)"
[ -n "$payload" ] || exit 0
# Common Bash calls exit before starting Python or Git.
mutating='(^|[^[:alnum:]_]|\\[nrt])(commit|merge|rebase|cherry-pick|revert|reset|am|apply|add|rm|mv|stash|restore|checkout|switch|branch|tag|push)($|[^[:alnum:]_])'
git_token='(^|[^[:alnum:]_]|\\[nrt])git($|[^[:alnum:]_])'
[[ "$payload" =~ $mutating && "$payload" =~ $git_token ]] || exit 0
python3 - "$state_dir" 3<<< "$payload" 2>/dev/null <<'PYTHON' || true
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

STATE = Path(sys.argv[1])
LEAD = re.compile(r"^(?:route-)?lead-(alpha|bravo|charlie|delta)(?:-(?:light|normal|critical|critical-xhigh))?$")
INACTIVE = {"PASS", "FAIL", "BLOCKED", "CLOSED", "IDLE", "UNASSIGNED"}


def journal(event, hook, decision, reason):
    # Both hooks keep this small implementation local: no runtime/shared-module dependency.
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "hook": hook, "event": str(event.get("hook_event_name", ""))[:100],
            "agent_type": str(event.get("agent_type", ""))[:120],
            "agent_id": str(event.get("agent_id", ""))[:120],
            "decision": decision, "reason": " ".join(str(reason).split())[:600],
        }
        line = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        path = STATE / "safety-hooks.log"
        while True:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "ab", buffering=0) as out:
                # Serialize append/rename as well as trimming. O_EXCL alone cannot stop an
                # appender from writing to the old inode after a concurrent os.replace.
                fcntl.flock(out, fcntl.LOCK_EX)
                if os.fstat(out.fileno()).st_ino != path.stat().st_ino:
                    continue
                os.write(out.fileno(), line)  # one bounded, newline-terminated O_APPEND write
                if os.fstat(out.fileno()).st_size <= 2 * 1024 * 1024:
                    return
                lock = STATE / "safety-hooks.trim.lock"
                try:
                    lock_fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                except FileExistsError:
                    return
                tmp = None
                try:
                    os.close(lock_fd)
                    with path.open("rb") as source:
                        source.seek(-1024 * 1024, os.SEEK_END)
                        source.readline()  # discard a possibly partial first record
                        tail = source.read()
                    temp_fd, tmp = tempfile.mkstemp(prefix="safety-hooks.", dir=STATE)
                    with os.fdopen(temp_fd, "wb") as target:
                        target.write(tail)
                    os.replace(tmp, path)
                finally:
                    if tmp and os.path.exists(tmp):
                        os.unlink(tmp)
                    lock.unlink(missing_ok=True)
                return
    except Exception:
        pass  # Observability must never change a decision or break a tool call.


def git(directory, *args):
    # Inherited Git environment must not override the invocation target being inspected.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(["git", "-C", str(directory), *args], env=env,
                            capture_output=True, text=True, timeout=2)
    if result.returncode:
        raise ValueError("git target could not be inspected")
    return result.stdout.strip()


def worktrees(directory):
    return [Path(line[9:]) for line in git(directory, "worktree", "list", "--porcelain").splitlines()
            if line.startswith("worktree ")]


def find_registry(checkout, cwd, common=None):
    for start in (checkout, cwd):
        if start is None:
            continue
        start = Path(start).resolve()
        for parent in (start, *start.parents):
            candidate = parent / ".orchestra/REGISTRY.md"
            if candidate.is_file():
                return candidate
    if common is not None:
        candidate = Path(common).parent / ".orchestra/REGISTRY.md"
        if candidate.is_file():
            return candidate
    try:
        for tree in worktrees(checkout or cwd):
            candidate = tree / ".orchestra/REGISTRY.md"
            if candidate.is_file():
                return candidate
    except Exception:
        pass
    return None


def registry_rows(path):
    if path is None:
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = [part.strip() for part in line.split("|")]
        if len(parts) != 9 or parts[0] or parts[-1] or not parts[1].startswith("lead-"):
            continue
        rows.append(dict(zip(("slot", "agentId", "task", "branch", "dir", "status", "updated"), parts[1:8])))
    return rows


def id_matches(left, right):
    return (isinstance(left, str) and isinstance(right, str) and bool(left) and bool(right)
            and (left == right or (min(len(left), len(right)) >= 8
                                  and (left.startswith(right) or right.startswith(left)))))


def slot_for_type(agent_type):
    match = LEAD.fullmatch(agent_type) if isinstance(agent_type, str) else None
    return "lead-" + match[1] if match else None


# Copied verbatim from orch-poll-guard.sh: keep its 35-case hardened parser
# untouched; ~110 duplicated lines are safer than a shared-module refactor.
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

INDEX_WRITE = {"commit", "merge", "rebase", "cherry-pick", "revert", "reset", "am", "apply",
               "add", "rm", "mv", "stash", "restore"}
PROTECTED = {"main", "master", "develop", "trunk"}


def resolve_path(value, cwd):
    if cwd is None or not value or any(ch in value for ch in ("$", "`", "~", "*", "?", "[")):
        return None
    return (Path(cwd) / value).resolve()


def invocations(command, cwd):
    quotes, inert = lex(command)
    syntax = blank_spans(command, inert + [(q["start"], q["end"]) for q in quotes])
    data = blank_spans(command, inert)
    # Split only top-level shell separators. Compound/substitution syntax is deliberately
    # unresolvable; this is a conservative recognizer, not a shell interpreter.
    cuts = []
    depth = 0
    start = 0
    index = 0
    while index < len(syntax):
        ch = syntax[index]
        if ch == "\\":
            index += 2
            continue
        if ch in "({":
            depth += 1
        elif ch in ")}":
            depth = max(0, depth - 1)
        elif ch in ";&|\n" and depth == 0:
            cuts.append((start, index))
            start = index + 1
        index += 1
    cuts.append((start, len(syntax)))
    running = Path(cwd).resolve() if isinstance(cwd, str) and cwd and "$" not in cwd else None
    for start, end in cuts:
        visible = syntax[start:end]
        first = re.search(r"\S+", visible)
        if not first or not at_command_position(syntax, start + first.start()):
            continue
        try:
            words = shlex.split(data[start:end], comments=True)
        except ValueError:
            running = None
            continue
        if not words:
            continue
        if words[0] in ("cd", "pushd"):
            args = words[1:]
            if args and args[0] == "--":
                args = args[1:]
            running = (resolve_path(args[0], running) if len(args) == 1 and
                       not args[0].startswith("-") else None)
            continue
        if words[0] == "popd" or first[0][0] in "({":
            running = None
            continue
        index = 0
        unsafe_env = False
        while index < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[index]):
            unsafe_env |= words[index].startswith("GIT_")
            index += 1
        if index < len(words) and words[index] == "env":
            index += 1
            while index < len(words):
                if words[index] == "--":
                    index += 1
                    break
                if words[index] in ("-i", "--ignore-environment"):
                    index += 1
                elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[index]):
                    unsafe_env |= words[index].startswith("GIT_")
                    index += 1
                else:
                    break
        if index >= len(words) or words[index] != "git":
            continue
        # A quoted command name is data for this recognizer, as prescribed by the lexer.
        if not re.search(r"\bgit\b", visible):
            continue
        index += 1
        target = running
        while index < len(words) and words[index].startswith("-"):
            word = words[index]
            if word.startswith(("--git-dir", "--work-tree")):
                unsafe_env = True
                break
            if word in ("-C", "-c", "--config-env"):
                if index + 1 >= len(words):
                    unsafe_env = True
                    break
                if word == "-C":
                    target = resolve_path(words[index + 1], target)
                index += 2
            elif word.startswith("-C"):
                target = resolve_path(word[2:], target)
                index += 1
            elif word.startswith(("-c", "--config-env=")) or word in ("--no-pager", "--paginate", "--no-optional-locks"):
                index += 1
            else:
                unsafe_env = True
                break
        if unsafe_env or index >= len(words):
            continue
        op, args = words[index], words[index + 1:]
        category = None
        if op in INDEX_WRITE:
            category = "INDEX_WRITE"
        elif op in ("checkout", "switch"):
            category = "REF_MOVE"
        elif op == "branch" and any(arg in ("-f", "-D", "-m", "-M") for arg in args):
            category = "REF_MOVE"
        elif op == "tag" and any(arg in ("-f", "-d") for arg in args):
            category = "REF_MOVE"
        elif op == "push":
            category = "PUSH"
        if category:
            yield target, op, category, args


def protected_push(args):
    # True: explicitly protected/bulk push; None: implicit or unresolved destination;
    # False: only explicit non-protected destinations. Preserve the latter two separately
    # so an ordinary bare push remains allowed from a non-protected checkout.
    positional = []
    remote_option = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("--all", "--mirror", "--tags"):
            return True
        if arg == "--repo":
            remote_option = True
            index += 2
            continue
        if arg.startswith("--repo="):
            remote_option = True
            index += 1
            continue
        if arg in ("--receive-pack", "--exec", "--push-option", "-o"):
            index += 2
            continue
        if arg == "--":
            positional.extend(args[index + 1:])
            break
        if not arg.startswith("-"):
            positional.append(arg)
        index += 1
    refs = positional if remote_option else positional[1:]
    if not refs:
        return None
    unresolved = False
    for ref in refs:
        destination = ref.lstrip("+").split(":")[-1]
        destination = destination.removeprefix("refs/heads/")
        if destination in PROTECTED:
            return True
        if destination == "HEAD" or not destination or any(ch in destination for ch in ("$", "`", "*", "?", "[")):
            unresolved = True
    return None if unresolved else False


def main(event):
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        return
    tool_input = event.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return
    agent_id = event.get("agent_id")
    agent_type = event.get("agent_type", "")
    typed_slot = slot_for_type(agent_type)
    dev = isinstance(agent_type, str) and re.fullmatch(r"dev(?:-opus)?-[1-9][0-9]*", agent_type)
    if not typed_slot and not dev and not agent_id:
        return
    for target, op, category, args in invocations(command, event.get("cwd")):
        # Classification is the evaluation boundary; only known actors are journalled.
        kind, slot = ("lead", typed_slot) if typed_slot else (("dev", None) if dev else ("unknown", None))
        try:
            if target is None:
                raise ValueError("unresolvable git target")
            info = git(target, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD", "--git-common-dir").splitlines()
            if len(info) != 3:
                raise ValueError("unknown git target shape")
            checkout, branch, common = Path(info[0]).resolve(), info[1], (target / info[2]).resolve()
            registry = find_registry(checkout, event.get("cwd"), common)
            rows = [row for row in registry_rows(registry) if row["status"] and row["status"] not in INACTIVE]
            matched = next((row for row in rows if id_matches(agent_id, row["agentId"])), None)
            if matched:
                kind, slot = "lead", matched["slot"]
            if kind == "unknown":
                continue
            if not rows:
                journal(event, "orch-worktree-guard", "skip", "no active registry rows")
                continue
            registry_root = registry.parent.parent.resolve()
            reason = None
            push_protection = protected_push(args) if category == "PUSH" else False
            if category == "PUSH" and push_protection is True:
                reason = f"R1: push from {checkout} on {branch} targets protected refs or a bulk ref set ({shlex.join(args)}). Push only your own task branch."
            elif branch in PROTECTED and (category == "INDEX_WRITE" or (category == "PUSH" and push_protection is not False)):
                reason = f"R1: {op} would mutate protected branch {branch} in {checkout}. Switch to your task branch in your own worktree first."
            elif kind == "lead" and slot:
                other_branch = next((row for row in rows if row["slot"] != slot and row["branch"] == branch), None)
                other_tree = next((row for row in rows if row["slot"] != slot and row["slot"] == checkout.name), None)
                if other_branch:
                    owner = other_branch["slot"]
                    reason = f"R2: branch {branch} in {checkout} belongs to active {owner}. Use your own branch/worktree ({slot})."
                elif other_tree and checkout.parent.name == "wt" and checkout.parent.parent.name == ".orchestra":
                    owner = other_tree["slot"]
                    reason = f"R3: checkout {checkout} belongs to active {owner}. Use your own worktree ({slot})."
                elif checkout == registry_root and len(rows) >= 2:
                    others = ", ".join(row["slot"] for row in rows if row["slot"] != slot)
                    suggestion = "git worktree add " + shlex.quote(str(registry_root / ".orchestra/wt" / slot)) + " -b <your branch>"
                    reason = f"R4: shared checkout {checkout} has concurrent active leads ({others}). Create your own worktree: {suggestion}."
            if reason:
                reason += " Disable with: " + shlex.join(["touch", str(STATE / "worktree-guard.off")])
                journal(event, "orch-worktree-guard", "deny", reason)
                print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
                return
            journal(event, "orch-worktree-guard", "allow", f"{op} in {checkout} on {branch}: no collision rule matched")
        except Exception as exc:
            if kind != "unknown":
                journal(event, "orch-worktree-guard", "skip", str(exc))


try:
    with os.fdopen(3) as payload:
        main(json.load(payload))
except Exception:
    pass

PYTHON
exit 0
