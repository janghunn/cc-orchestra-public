#!/usr/bin/env bash
# Runtime safety stop-gate; failures always allow. Registration must retain `|| true`.
set -uo pipefail
state_dir="${CC_ORCH_STATE_DIR:-${HOME:-}/.claude/orchestra-state}"
[ -e "$state_dir/stop-gate.off" ] && exit 0
payload="$(cat)"
[ -n "$payload" ] || exit 0
repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# Keep intentional warnings on fd 4; suppress interpreter startup errors on stderr.
python3 - "$state_dir" "$repo_dir" 3<<< "$payload" 4>&2 2>/dev/null <<'PYTHON' || true
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

def last_assistant(path):
    # Scan the JSONL records from the end; tool/user records do not replace the last assistant.
    for line in reversed(Path(path).read_text(encoding="utf-8").splitlines()):
        if not line.strip():
            continue
        record = json.loads(line)
        if not isinstance(record, dict):
            continue
        message = record.get("message", {})
        if not isinstance(message, dict):
            continue
        if record.get("type") != "assistant" and message.get("role") != "assistant":
            continue
        content = message.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(block.get("text", "") for block in content
                             if isinstance(block, dict) and block.get("type") == "text"
                             and isinstance(block.get("text"), str))
        return ""
    return ""


def checker_path():
    candidates = [os.environ.get("CC_ORCH_SUMMARY_CHECK"),
                  str(Path(sys.argv[2]) / "bin/orch-summary-check"),
                  str(Path.home() / ".local/bin/orch-summary-check"),
                  shutil.which("orch-summary-check")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    return None


def recorded_status(task):
    try:
        summary = (task / "summary.md").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    matches = re.findall(r"^(?:\[lead-[A-Za-z0-9_-]+\]\s*)?STATUS:\s*(PASS\b|FAIL\b|BLOCKED\b|ACCEPTED(?![A-Za-z0-9_-]))", summary, re.M)
    return matches[-1] if matches else None


def warn(event, status, why, task=None, checked=False):
    command = shlex.join(["orch-summary-check", "--strict", str(task) if task else "<unknown>"])
    if checked:
        message = f"orch-stop-gate: {status} was claimed; {why}. Verify manually: {command}"
    else:
        message = f"orch-stop-gate: {status} was claimed but orch-summary-check --strict could not be run ({why}). Verify manually: {command}"
    print(json.dumps({"systemMessage": message}))
    with os.fdopen(os.dup(4), "w") as warning_stderr:
        print(message, file=warning_stderr)
    journal(event, "orch-stop-gate", "warn", message)


def main(event):
    if not isinstance(event, dict) or event.get("stop_hook_active"):
        return
    slot = slot_for_type(event.get("agent_type"))
    if not slot:
        return
    try:
        message = last_assistant(event.get("agent_transcript_path"))
    except Exception:
        return  # With no readable transcript there is no observable claim.
    claim = re.search(r"^\[?[A-Za-z0-9_-]*\]?\s*STATUS:\s*(PASS\b|FAIL\b|BLOCKED\b|ACCEPTED(?![A-Za-z0-9_-]))", message, re.M)
    if not claim or not re.search(r"^GATES:", message, re.M):
        return
    status, task = claim[1], None
    try:
        cwd = event.get("cwd")
        registry = None
        checkout, common = None, None
        if isinstance(cwd, str) and cwd:
            try:
                info = git(cwd, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD", "--git-common-dir").splitlines()
                if len(info) == 3:
                    checkout, common = Path(info[0]), (Path(cwd) / info[2]).resolve()
            except Exception:
                pass
            registry = find_registry(checkout, cwd, common)
        rows = registry_rows(registry)
        row = next((row for row in rows if id_matches(event.get("agent_id"), row["agentId"])), None)
        if row is None:
            row = next((row for row in rows if row["slot"] == slot), None)
        if row and row["dir"]:
            task = (registry.parent.parent / row["dir"]).resolve()
        elif registry is not None:
            warn(event, status, "registry has no task directory for this lead")
            return
        elif checkout is not None:
            artifact = re.search(r"^ARTIFACTS:\s*(.+)$", message[claim.start():], re.M)
            if artifact:
                candidate = Path(artifact[1].strip())
                if not candidate.is_absolute():
                    candidate = Path(cwd) / candidate if isinstance(cwd, str) and cwd else None
                if candidate is not None:
                    candidate = candidate.resolve()
                    repo_root = checkout.resolve()
                    if (candidate == repo_root or repo_root in candidate.parents) and candidate.is_dir() and (candidate / "brief.md").is_file():
                        task = candidate
        if task is None:
            warn(event, status, "task directory could not be resolved")
            return
        if task.is_dir() and not (task / "summary.md").exists():
            command = shlex.join(["orch-summary-check", "--strict", str(task)])
            note = f"orch-stop-gate: note: {status} was claimed; summary.md not saved yet; Tier 1 saves the returned block and runs {command}"
            print(json.dumps({"systemMessage": note}))
            journal(event, "orch-stop-gate", "note", note)
            return
        checker = checker_path()
        if checker is None:
            warn(event, status, "checker not found", task)
            return
        result = subprocess.run([checker, "--strict", str(task)], capture_output=True, timeout=20)
        recorded = recorded_status(task)
        if result.returncode == 0:
            if status != recorded:
                warn(event, status, f"strict summary check passed, but transcript STATUS: {status} disagrees with summary.md STATUS: {recorded or 'unknown'}", task, checked=True)
            else:
                journal(event, "orch-stop-gate", "allow", f"{status} claim: strict summary check passed for {task}")
        elif result.returncode == 1:
            excerpt = result.stdout[:1500].decode("utf-8", errors="replace")
            if status in ("BLOCKED", "FAIL"):
                warn(event, status, f"strict summary check failed; summary.md STATUS: {recorded or 'unknown'}.\n{excerpt}", task, checked=True)
                return
            command = shlex.join([checker, "--strict", str(task)])
            disable = shlex.join(["touch", str(STATE / "stop-gate.off")])
            reason = f"orch-stop-gate: {status} claim failed strict validation; summary.md STATUS: {recorded or 'unknown'}.\n{excerpt}\nRe-run: {command}\nDisable with: {disable}"
            journal(event, "orch-stop-gate", "block", reason)
            print(json.dumps({"decision": "block", "reason": reason}))
        else:
            warn(event, status, f"checker exited {result.returncode}", task)
    except Exception as exc:
        warn(event, status, str(exc), task)


try:
    with os.fdopen(3) as payload:
        main(json.load(payload))
except Exception:
    pass

PYTHON
exit 0
