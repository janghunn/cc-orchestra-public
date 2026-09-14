#!/usr/bin/env python3
"""Adapt native Codex hook events to the existing local guards; no provider calls."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))
from orch_codex import atomic, state_root


def run_guard(path, event):
    # Native Codex supplies the final assistant message directly; its transcript is not
    # Claude JSONL. Normalize only this message for the existing stop-gate parser.
    message = event.get("last_assistant_message")
    if event.get("hook_event_name") == "SubagentStop" and isinstance(message, str):
        with tempfile.NamedTemporaryFile(mode="w+", suffix=".jsonl") as transcript:
            json.dump({"type": "assistant", "message": {"role": "assistant", "content": message}}, transcript)
            transcript.write("\n")
            transcript.flush()
            payload = json.dumps({**event, "agent_transcript_path": transcript.name})
            return subprocess.run(["bash", str(path)], input=payload, text=True, capture_output=True, timeout=35)
    return subprocess.run(["bash", str(path)], input=json.dumps(event), text=True, capture_output=True, timeout=35)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--role", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", args.project):
        return
    event = json.load(sys.stdin)
    kind = event.get("hook_event_name")
    if kind == "SessionStart":
        if args.role == "orchestrator" and event.get("session_id"):
            path = state_root() / "codex-projects" / args.project / "project.json"
            saved = json.loads(path.read_text()) if path.exists() else {}
            saved["session_id"] = event["session_id"]
            atomic(path, json.dumps(saved, indent=2) + "\n")
        return
    role = args.role
    if kind == "PreToolUse" and role in ["verifier", "reviewer", "auditor"] and event.get("tool_name") in ["apply_patch", "Write", "Edit"]:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Independent Codex gates cannot edit files; return evidence to the lead."}}))
        return
    if kind == "SubagentStop":
        match = re.fullmatch(r"orch_lead_(alpha|bravo|charlie|delta)_(light|normal|critical|deep)", event.get("agent_type", ""))
        if not match:
            return
        role = "lead-" + match[1]
        script = "orch-stop-gate.sh"
    elif kind == "PreToolUse" and event.get("tool_name") == "Bash":
        script = "orch-verifier-bash-guard.sh" if role in ["verifier", "reviewer", "auditor"] else "orch-worktree-guard.sh"
    else:
        return
    # Legacy collision protection classifies implementation agents by the dev-N family.
    # Preserve the real agent_id; these aliases identify guard roles, not conversations.
    event["agent_type"] = {"worker": "dev-1", "mechanical": "dev-2"}.get(role, role)
    scripts = [script]
    if kind == "PreToolUse":
        scripts.append("orch-poll-guard.sh")
    for script in scripts:
        path = ROOT / "hooks" / script
        if not path.is_file():
            continue
        result = run_guard(path, event)
        if result.stdout.strip():
            print(result.stdout.strip())
            return
        if result.returncode == 2:
            print(result.stderr, file=sys.stderr)
            sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        # Existing safety hooks intentionally fail open; native sandbox policy still applies.
        pass
