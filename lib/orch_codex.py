#!/usr/bin/env python3
"""Codex-only roles and launcher. Never imports a Claude configuration or runs Claude."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
EFFORTS = ["low", "medium", "high", "xhigh", "max", "ultra"]


def toml(value):
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(map(toml, value)) + "]"
    return "{" + ", ".join(toml(k) + " = " + toml(v) for k, v in value.items()) + "}"


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def policy():
    return json.loads((ROOT / "codex-policy.json").read_text())


def catalog():
    if os.environ.get("CC_ORCH_CODEX_CATALOG_CHECK") == "0":
        return {}
    path = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "models_cache.json"
    try:
        return {m["slug"]: m for m in json.loads(path.read_text())["models"] if "slug" in m}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def resolve(pair, models, rules, explicit=False):
    model, effort = pair
    model = "gpt-6-astra" if model == "astra" else model
    if model != "gpt-6-astra" or effort not in EFFORTS:
        raise ValueError("Codex-only mode requires gpt-6-astra; vary effort, not model")
    wanted = model
    if models and model not in models:
        raise ValueError("gpt-6-astra is absent from the account catalog; no model or provider fallback")
    supported = [x.get("effort") for x in models.get(model, {}).get("supported_reasoning_levels", [])]
    if supported and effort not in supported:
        if explicit:
            raise ValueError(f"{model} does not advertise effort {effort}")
        effort = next((e for e in reversed(EFFORTS[:EFFORTS.index(effort) + 1]) if e in supported), supported[0])
    return model, effort, wanted if wanted != model else ""


def state_root():
    return Path(os.environ.get("CC_ORCH_STATE_DIR", str(Path.home() / ".local/state/cc-orchestra-codex"))).resolve()


def instructions(name, **fields):
    text = (ROOT / "agents" / ("codex-" + name + ".md")).read_text()
    for key, value in {"REPO": str(ROOT), **fields}.items():
        text = text.replace("@" + key + "@", value)
    return text


def hooks(project, role):
    command = shlex.join([sys.executable, str(ROOT / "hooks/orch-codex-hook.py"), "--project", project, "--role", role])
    # Scoped CLI config: no writes to ~/.codex/config.toml or the target repository.
    return {
        "SessionStart": [{"hooks": [{"type": "command", "command": command, "timeout": 10}]}],
        "PreToolUse": [{"matcher": "Bash|apply_patch|Write|Edit", "hooks": [{"type": "command", "command": command, "timeout": 15}]}],
        "SubagentStop": [{"matcher": "orch_lead_.*", "hooks": [{"type": "command", "command": command, "timeout": 40}]}],
    }


def config(project, profile, output, model=None, effort=None):
    rules, models = policy(), catalog()
    pair = list(rules["orchestrator"][profile])
    if model:
        pair[0] = model
    if effort:
        pair[1] = effort
    chosen = resolve(pair, models, rules, bool(model or effort))
    roles, manifest = {}, {}
    definitions = []
    for slot in ["alpha", "bravo", "charlie", "delta"]:
        for level, pair in rules["lead"].items():
            definitions.append((f"orch_lead_{slot}_{level}", pair, "lead", f"lead-{slot}", {"SLOT": f"lead-{slot}", "PROFILE": level}))
    for name, source in [("worker", "worker"), ("mechanical", "worker"), ("verifier", "gate"), ("reviewer", "gate"), ("auditor", "gate")]:
        key = {"verifier": "verify", "reviewer": "review"}.get(name, name)
        definitions.append(("orch_" + name, rules[key], source, name, {"ROLE": name}))
    for name, pair, source, hook_role, fields in definitions:
        m, e, fallback = resolve(pair, models, rules)
        text = instructions(source, **fields)
        description = f"cc-orchestra Codex-only {name}; {m}@{e}"
        values = {"name": name, "description": description, "model": m, "model_provider": "openai",
                  "model_reasoning_effort": e, "developer_instructions": text,
                  "hooks": hooks(project, hook_role)}
        if source == "gate":
            values["sandbox_mode"] = "workspace-write" if name == "orch_verifier" else "read-only"
        path = output / (name + ".toml")
        atomic(path, "\n".join(f"{k} = {toml(v)}" for k, v in values.items()) + "\n")
        roles[name] = {"description": description, "config_file": str(path)}
        manifest[name] = {"model": m, "effort": e, "fallback_from": fallback}
    agents = {"enabled": True, "max_concurrent_threads_per_session": rules["max_concurrent_threads"],
              "default_subagent_model": manifest["orch_worker"]["model"],
              "default_subagent_reasoning_effort": manifest["orch_worker"]["effort"], **roles}
    values = {"model_provider": "openai", "model_reasoning_effort": chosen[1],
              "developer_instructions": instructions("orchestrator") + f"\nProject: {project}\nBackend: codex\n",
              "agents": agents, "hooks": hooks(project, "orchestrator"), "features.hooks": True}
    manifest["orchestrator"] = {"model": chosen[0], "effort": chosen[1], "fallback_from": chosen[2]}
    atomic(output / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    return chosen, values


def launch(argv):
    parser = argparse.ArgumentParser(prog="cc-orch-codex", description="Four-tier cc-orchestra using only Codex CLI and GPT models")
    parser.add_argument("--profile", choices=["normal", "critical", "deep"], default="normal")
    parser.add_argument("--model")
    parser.add_argument("--effort", choices=EFFORTS)
    parser.add_argument("--resume", nargs="?", const="saved", metavar="SESSION_ID")
    parser.add_argument("--reload", action="store_true", help="resume saved context; refuses a still-running named launch")
    parser.add_argument("--no-rc", action="store_true", help="compatibility option; uses local Codex, not Claude Remote Control")
    parser.add_argument("--exec", action="store_true", help="run one non-interactive turn")
    parser.add_argument("--prompt", help="initial request or follow-up")
    parser.add_argument("--dry-run", action="store_true", help="render roles and print JSON launch details without model calls")
    parser.add_argument("project")
    parser.add_argument("directory", nargs="?", default=os.getcwd())
    args = parser.parse_args(argv)
    if not NAME.fullmatch(args.project):
        parser.error("invalid project name")
    cwd = Path(args.directory).resolve()
    if not cwd.is_dir():
        parser.error("project directory does not exist")
    env = dict(os.environ, CC_ORCH_BACKEND="codex", CC_ORCH_PROJECT=args.project, CC_ORCH_STATE_DIR=str(state_root()))
    project_dir = state_root() / "codex-projects" / args.project
    project_dir.mkdir(parents=True, exist_ok=True)
    lock = (project_dir / ".launch.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("this named Codex launch is still running; attach to its terminal or stop it before resuming")
    saved_path = project_dir / "project.json"
    saved = json.loads(saved_path.read_text()) if saved_path.exists() else {}
    if saved.get("directory") and saved["directory"] != str(cwd):
        parser.error("project name is already bound to a different directory; choose another name")
    choice, values = config(args.project, args.profile, project_dir / "roles", args.model, args.effort)
    cmd = [os.environ.get("CODEX_BIN", "codex")]
    resume = args.resume or ("saved" if args.reload else None)
    thread = saved.get("session_id") if resume == "saved" else resume
    if resume == "saved" and not thread and args.prompt and not args.exec:
        # `codex resume [SESSION_ID] [PROMPT]` cannot accept a prompt without an ID.
        # Preserve the handoff request in a new conversation when hooks never saved one.
        print("cc-orch-codex: no saved session ID; starting a new conversation with the supplied handoff/request", file=sys.stderr)
        resume = None
    if args.exec:
        cmd += ["exec"]
    elif resume:
        cmd += ["resume"]
    cmd += ["-C", str(cwd), "-m", choice[0], "--sandbox", "workspace-write", "--add-dir", str(state_root())]
    if not args.exec:
        cmd += ["--ask-for-approval", "on-request"]
    for key, value in values.items():
        cmd += ["-c", key + "=" + toml(value)]
    if args.exec:
        cmd += ["--json", "-o", str(project_dir / "last-message.md")]
        if resume:
            if not thread:
                parser.error("no saved Codex session ID; use interactive --resume to choose or provide --resume SESSION_ID")
            cmd += ["resume", thread]
    elif thread:
        cmd += [thread]
    if args.prompt:
        cmd += [args.prompt]
    elif args.exec:
        parser.error("--exec requires --prompt")
    state = {**saved, "project": args.project, "directory": str(cwd), "backend": "codex", "profile": args.profile,
             "model": choice[0], "effort": choice[1], "fallback_from": choice[2]}
    if resume and thread:
        state["session_id"] = thread
    else:
        # A fresh conversation must never inherit the previous conversation's ID if its
        # SessionStart hook has not been trusted or the process exits before reporting it.
        state.pop("session_id", None)
    if args.dry_run:
        print(json.dumps({"command": cmd, "environment": {k: env[k] for k in ["CC_ORCH_BACKEND", "CC_ORCH_PROJECT", "CC_ORCH_STATE_DIR"]}, "state": state}, indent=2))
        return 0
    atomic(saved_path, json.dumps(state, indent=2) + "\n")
    if choice[2]:
        print(f"cc-orch-codex: {choice[2]} unavailable; using {choice[0]}@{choice[1]}", file=sys.stderr)
    if not args.exec:
        return subprocess.call(cmd, cwd=cwd, env=env)
    # Capture real process completion and thread.started, never poll for a made-up result event.
    with (project_dir / "events.jsonl").open("w") as events:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
        for line in proc.stdout:
            events.write(line)
            events.flush()
            print(line, end="", flush=True)
            try:
                event = json.loads(line)
                if event.get("type") == "thread.started" and event.get("thread_id"):
                    state["session_id"] = event["thread_id"]
                    atomic(saved_path, json.dumps(state, indent=2) + "\n")
            except ValueError:
                pass
        return proc.wait()


def route(argv):
    if len(argv) < 2 or argv[0] not in ["codex", "lead", "orchestrator"]:
        raise ValueError("usage: orch-codex-route route codex <mode> | lead <risk> [deep] [slot] | orchestrator <profile>")
    kind, mode, *extra = argv
    rules = policy()
    if kind == "lead":
        mode = "light" if mode in ["low", "trivial"] else mode
        if extra and extra[0] in ["deep", "yes", "true"]:
            if mode == "critical":
                mode = "deep"
            extra.pop(0)
        slot = extra.pop(0) if extra else "{slot}"
        if slot not in ["alpha", "bravo", "charlie", "delta", "{slot}"]:
            raise ValueError("invalid lead slot")
    if extra:
        raise ValueError("unexpected route arguments")
    key = {"implement": "worker", "review": "review", "verify": "verify"}.get(mode, mode)
    pair = rules[kind][mode] if kind in ["lead", "orchestrator"] else rules[key]
    m, e, fallback = resolve(pair, catalog(), rules)
    if kind == "lead":
        print(f"kind=lead\nprofile={mode}\nagent_type=orch_lead_{slot}_{mode}")
    print(f"model={m}\neffort={e}\nallow=1\npressure=codex-only\nreason=Codex-only policy" + (f"; fallback from {fallback}" if fallback else ""))


def shell_policy():
    rules = policy()
    for prefix, key in {"IMPL": "worker", "INVESTIGATE": "investigate", "INTAKE": "intake", "REVIEW": "review", "VERIFY": "verify", "MECH": "mechanical", "FAST": "mechanical"}.items():
        model, effort, _ = resolve(rules[key], {}, rules)
        print(f"CODEX_{prefix}_MODEL={model}\nCODEX_{prefix}_EFFORT={effort}")
    print("CODEX_CRITICAL_EFFORT=max\nCODEX_ESCALATE_EFFORT=max")


if __name__ == "__main__":
    try:
        command, *args = sys.argv[1:]
        if command == "launch":
            sys.exit(launch(args))
        elif command == "route":
            route(args)
        elif command == "shell-policy":
            shell_policy()
        else:
            raise ValueError("expected launch or route")
    except (ValueError, KeyError, OSError) as error:
        print(f"cc-orch-codex: {error}", file=sys.stderr)
        sys.exit(2)
