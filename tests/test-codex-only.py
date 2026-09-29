"""Behavior tests use fake provider binaries: any Claude invocation is a failure."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("orch_codex", ROOT / "lib/orch_codex.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CodexOnly(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.cwd = self.base / "project with spaces"
        self.cwd.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.cwd)], check=True)
        subprocess.run(["git", "-C", str(self.cwd), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline", "--allow-empty"], check=True)
        self.state = self.base / "state"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, CC_ORCH_CLI_AUTO_UPDATE="0", CC_ORCH_STATE_DIR=str(self.state), CC_ORCH_CODEX_CATALOG_CHECK="0",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"], TEST_BASE=str(self.base),
                        CC_ORCH_STOP_GRACE_SECONDS="0")
        self.env.pop("CC_ORCH_BACKEND", None)
        self.env.pop("CC_ORCH_CODEX_ROUTE", None)
        self.script("claude", "import os,pathlib; pathlib.Path(os.environ['TEST_BASE'],'CLAUDE_CALLED').touch(); raise SystemExit(99)")
        self.script("codex", '''import json,os,pathlib,sys,subprocess,tomllib
args=sys.argv[1:]
pathlib.Path(os.environ['TEST_BASE'],'codex-args.json').write_text(json.dumps(args))
for i,arg in enumerate(args):
 if arg=='-c' and args[i+1].startswith('hooks='):
  hooks=tomllib.loads(args[i+1])['hooks']
  command=hooks['SessionStart'][0]['hooks'][0]['command']
  subprocess.run(command,shell=True,input=json.dumps({'hook_event_name':'SessionStart','session_id':'00000000-0000-4000-8000-000000000001'}),text=True,check=True)
print(json.dumps({'type':'thread.started','thread_id':'00000000-0000-4000-8000-000000000001'}))
print(json.dumps({'type':'turn.completed'}))
''')
        self.script("tmux", '''import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_BASE']); path=root/'tmux-state.json'; args=sys.argv[1:]
state=json.loads(path.read_text()) if path.exists() else {}
with (root/'tmux-log.jsonl').open('a') as out: out.write(json.dumps(args)+'\\n')
def value(flag): return args[args.index(flag)+1]
if args[0]=='has-session': raise SystemExit(0 if value('-t') in state else 1)
if args[0]=='new-session': state[value('-s')]=args[-1]
if args[0]=='kill-session': state.pop(value('-t'),None)
path.write_text(json.dumps(state))
''')
        self.env["CODEX_BIN"] = str(self.bin / "codex")
        self.env["TMUX_BIN"] = str(self.bin / "tmux")

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\n" + body + "\n")
        path.chmod(0o755)

    def run_cmd(self, args, expected=0, env=None, input=None):
        p = subprocess.run([str(x) for x in args], cwd=self.cwd, env=env or self.env,
                           input=input, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, expected, p.stdout + p.stderr)
        self.assertFalse((self.base / "CLAUDE_CALLED").exists(), "Claude was invoked")
        return p.stdout

    def launch(self, *args, expected=0):
        return self.run_cmd([ROOT / "bin/cc-orch-codex", *args, "sample", self.cwd], expected)

    def task(self, risk="normal", gates="codex-verify PASS; codex-review CLEAR"):
        task = self.cwd / ".orchestra/01-test"
        task.mkdir(parents=True, exist_ok=True)
        (task / "brief.md").write_text("RISK: " + risk + "\n")
        (task / "plan.md").write_text("# Plan\nTest concrete behavior.\n")
        (task / "codex-verdict.md").write_text("CODEX-VERDICT: PASS\n")
        (task / "codex-review.md").write_text("CODEX-REVIEW: CLEAR\n")
        (task / "codex-audit.md").write_text("CODEX-AUDIT: PASS\n")
        level = "light" if risk in ["trivial", "low"] else risk
        (task / "summary.md").write_text(f"BACKEND: codex\nCODEX PROFILE: {level} gpt-6-astra@high\nPROMOTIONS: none\nDISPATCH: codex-first\nINVESTIGATION: Codex\nLANES: Astra\nGATES: {gates}\nROUNDS: 1\n")
        return task

    def test_role_config_all_astra_and_no_global_config_writes(self):
        s = json.loads(self.launch("--dry-run"))
        self.assertEqual(s["state"]["model"], "gpt-6-astra")
        manifest = json.loads((self.state / "codex-projects/sample/roles/manifest.json").read_text())
        self.assertEqual(len(manifest), 22)
        self.assertEqual({v["model"] for v in manifest.values()}, {"gpt-6-astra"})
        self.assertEqual(manifest["orch_auditor"]["effort"], "max")
        self.assertEqual(manifest["orch_mechanical"]["effort"], "medium")
        self.assert_unrestricted(s["command"])
        for role_file in (self.state / "codex-projects/sample/roles").glob("*.toml"):
            role = tomllib.loads(role_file.read_text())
            self.assertEqual(role["approval_policy"], "never")
            self.assertEqual(role["sandbox_mode"], "danger-full-access")
            self.assertIn("hooks", role)
        self.assertFalse((self.cwd / ".codex").exists())
        self.assertFalse((self.state / "codex-projects/sample/project.json").exists())

    def assert_unrestricted(self, command):
        self.assertEqual(command.count("--dangerously-bypass-approvals-and-sandbox"), 1)
        self.assertNotIn("--sandbox", command)
        self.assertNotIn("--ask-for-approval", command)
        self.assertNotIn("--dangerously-bypass-hook-trust", command)

    def test_execution_policy_applies_to_actual_new_exec_and_resume_arguments(self):
        for options in [[], ["--resume", "saved"], ["--exec", "--prompt", "Read only"],
                        ["--exec", "--resume", "saved", "--prompt", "Continue"]]:
            self.launch(*options)
            command = json.loads((self.base / "codex-args.json").read_text())
            self.assert_unrestricted(command)
            if command[0] == "exec" and "resume" in command:
                self.assertLess(command.index("--dangerously-bypass-approvals-and-sandbox"), command.index("resume"))
        saved = json.loads((self.state / "codex-projects/sample/project.json").read_text())
        self.assertEqual(saved["approval_policy"], "never")
        self.assertEqual(saved["sandbox_mode"], "danger-full-access")

    def test_alias_dispatch_and_explicit_non_astra_rejected(self):
        out = self.run_cmd([ROOT / "bin/cc-orch-runtime", "--backend", "codex", "--dry-run", "other", self.cwd])
        self.assertEqual(json.loads(out)["state"]["backend"], "codex")
        self.launch("--dry-run", "--model", "sol", expected=2)

    def test_missing_astra_has_no_fallback(self):
        with self.assertRaisesRegex(ValueError, "no model or provider fallback"):
            module.resolve(["gpt-6-astra", "high"], {"gpt-5.6-sol": {}}, module.policy())

    def test_pure_installer_and_standalone_worker_alias(self):
        installed = self.base / "installed"
        env = dict(self.env, CC_ORCH_BIN_DIR=str(installed))
        self.run_cmd(["bash", ROOT / "install.sh", "--codex-only"], env=env)
        self.assertEqual((installed / "cc-orch").resolve(), ROOT / "bin/cc-orch-codex")
        self.assertEqual((installed / "codex-run").resolve(), ROOT / "bin/codex-run-codex")
        output = self.run_cmd([installed / "cc-orch", "--dry-run", "sample", self.cwd], env=env)
        self.assertEqual(json.loads(output)["state"]["backend"], "codex")
        task = self.task()
        output = self.run_cmd([installed / "codex-run", "implement", self.cwd, task, "--mech", "--dry-run"], env=env)
        self.assertIn("gpt-6-astra", output)

    def test_legacy_route_contract_uses_native_astra_roles(self):
        env = dict(self.env, CC_ORCH_BACKEND="codex")
        guard = ROOT / "bin/orch-model-guard-runtime"
        self.run_cmd([guard, "check"], env=env)
        for risk, args, role in [("low", ["alpha"], "alpha_light"),
                                 ("critical", ["deep", "bravo"], "bravo_deep")]:
            out = self.run_cmd([guard, "route", "lead", risk, *args], env=env)
            self.assertIn("agent_type=orch_lead_" + role, out)
            self.assertIn("model=gpt-6-astra", out)
        self.run_cmd([guard, "set", "sonnet"], expected=2, env=env)

    def test_exec_completion_capture_and_exact_resume(self):
        self.launch("--exec", "--prompt", "Read only smoke.")
        state = json.loads((self.state / "codex-projects/sample/project.json").read_text())
        self.assertEqual(state["session_id"], "00000000-0000-4000-8000-000000000001")
        self.launch("--exec", "--resume", "saved", "--prompt", "Continue.")
        args = json.loads((self.base / "codex-args.json").read_text())
        self.assertIn(state["session_id"], args)
        self.assertIn("resume", args)

    def test_interactive_session_hook_records_resume_id(self):
        self.launch()
        self.launch("--reload")
        args = json.loads((self.base / "codex-args.json").read_text())
        self.assertEqual(args[0], "resume")
        self.assertIn("00000000-0000-4000-8000-000000000001", args)

    def test_missing_resume_id_keeps_handoff_as_prompt(self):
        out = json.loads(self.launch("--dry-run", "--resume", "saved", "--prompt", "Read handoff."))
        self.assertNotIn("resume", out["command"])
        self.assertEqual(out["command"][-1], "Read handoff.")
        self.launch("--exec", "--resume", "saved", "--prompt", "Read handoff.", expected=2)
        picker = json.loads(self.launch("--dry-run", "--resume", "saved"))
        self.assertEqual(picker["command"][1], "resume")

    def test_fresh_launch_does_not_retain_old_id_when_hook_is_skipped(self):
        self.launch("--exec", "--prompt", "Initial turn")
        saved = self.state / "codex-projects/sample/project.json"
        self.assertIn("session_id", json.loads(saved.read_text()))
        self.script("codex", "# Simulate an interactive CLI whose SessionStart hook is untrusted.\npass")
        self.launch()
        self.assertNotIn("session_id", json.loads(saved.read_text()))
        out = json.loads(self.launch("--dry-run", "--resume", "saved", "--prompt", "Read handoff."))
        self.assertNotIn("resume", out["command"])
        self.launch("--resume", "00000000-0000-4000-8000-000000000002")
        self.assertEqual(json.loads(saved.read_text())["session_id"], "00000000-0000-4000-8000-000000000002")

    def test_named_launch_lock_and_directory_binding(self):
        self.launch("--exec", "--prompt", "Read only")
        self.run_cmd([ROOT / "bin/cc-orch-codex", "--dry-run", "sample", self.base], expected=2)
        import fcntl
        with (self.state / "codex-projects/sample/.launch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.launch("--dry-run", expected=2)

    def test_worker_cli_routes_only_astra_even_fast_or_mechanical(self):
        task = self.task()
        env = dict(self.env, CC_ORCH_BACKEND="codex")
        for mode, extra in [("implement", []), ("implement", ["--mech"]), ("review", ["--fast"]),
                            ("verify", ["--critical"]), ("intake", ["Map scope"]),
                            ("investigate", ["Locate owner"]), ("plan-review", [])]:
            text = self.run_cmd([ROOT / "bin/codex-run-runtime", mode, self.cwd, task, *extra, "--dry-run"], env=env)
            self.assertIn("gpt-6-astra", text)
            self.assertIn("model_provider=", text)
            self.assertIn("openai", text)
            self.assertIn("agents.enabled=false", text)
            self.assertIn("Do not delegate to subagents", text)
            self.assertIn("--dangerously-bypass-approvals-and-sandbox", text)
            self.assertNotIn("--sandbox ", text)
            self.assertNotIn("-m gpt-5.6", text)
            self.assertNotIn("-m gpt-6-sol", text)
            self.assertNotIn("-m gpt-6-luna", text)
        self.run_cmd([ROOT / "bin/codex-run-runtime", "implement", self.cwd, task, "--model", "sol", "--dry-run"], expected=2, env=env)
        self.run_cmd([ROOT / "bin/codex-run-runtime", "implement", self.cwd, task, "--model", "luna", "--dry-run"], expected=2, env=env)

    def test_hybrid_worker_keeps_its_existing_sandbox_policy(self):
        task = self.task()
        for mode, sandbox in [("implement", "workspace-write"), ("review", "read-only")]:
            out = self.run_cmd([ROOT / "bin/codex-run", mode, self.cwd, task, "--model", "astra", "--dry-run"])
            self.assertIn("--sandbox " + sandbox, out)
            self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", out)

    def test_worker_failures_block_without_model_or_provider_fallback(self):
        task = self.task()
        for error, expected in [("usage limit exceeded", 3), ("401 unauthorized", 4),
                                ("ERROR: This model is not supported when using Codex with a ChatGPT account.", 6)]:
            self.script("codex", "import pathlib,os,sys,json\n"
                        "p=pathlib.Path(os.environ['TEST_BASE'])\n"
                        "(p/'error-args.json').write_text(json.dumps(sys.argv[1:]))\n"
                        "with (p/'error-calls').open('a') as f: f.write('call\\n')\n"
                        f"print({error!r},file=sys.stderr)\nraise SystemExit(1)")
            result = subprocess.run([ROOT / "bin/codex-run-codex", "implement", self.cwd, task],
                                    cwd=self.cwd, env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertIn("BLOCKED", result.stderr)
            self.assertNotRegex(result.stderr, "Luna|Claude-only|Claude lane|sol\\|terra")
            args = json.loads((self.base / "error-args.json").read_text())
            self.assertIn('model_provider="openai"', args)
            self.assertIn("agents.enabled=false", args)
            self.assert_unrestricted(args)
            self.assertIn("gpt-6-astra", args)
            self.assertFalse((self.base / "CLAUDE_CALLED").exists())
        self.assertEqual((self.base / "error-calls").read_text().count("call"), 3)

    def test_codex_gate_requirements_and_critical_auditor(self):
        for risk in ["low", "normal"]:
            task = self.task(risk)
            self.assertIn("CHECK: PASS", self.run_cmd([ROOT / "bin/orch-summary-check", "--strict", task]))
        task = self.task("critical")
        self.run_cmd([ROOT / "bin/orch-summary-check", "--strict", task], expected=1)
        task = self.task("critical", "codex-verify PASS; codex-review CLEAR; codex-auditor PASS")
        self.assertIn("CHECK: PASS", self.run_cmd([ROOT / "bin/orch-summary-check", "--strict", task]))
        task = self.task("normal", "codex-verify unavailable; codex-review CLEAR; claude-verifier PASS")
        self.run_cmd([ROOT / "bin/orch-summary-check", "--strict", task], expected=1)

    def test_native_gate_hook_denies_edits(self):
        hook = [sys.executable, ROOT / "hooks/orch-codex-hook.py", "--project", "sample", "--role", "reviewer"]
        for name, content in [("apply_patch", {"command": "fake"}), ("Bash", {"command": "git commit -m nope"})]:
            out = self.run_cmd(hook, input=json.dumps({"hook_event_name": "PreToolUse", "tool_name": name, "tool_input": content, "cwd": str(self.cwd)}))
            self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_native_workers_receive_protected_branch_guard(self):
        task = self.task()
        (self.cwd / ".orchestra/REGISTRY.md").write_text(f"| lead-alpha | agent-12345678 | task | main | {task} | RUNNING | now |\n")
        for role in ["worker", "mechanical"]:
            hook = [sys.executable, ROOT / "hooks/orch-codex-hook.py", "--project", "sample", "--role", role]
            event = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "git commit -m protected"}, "cwd": str(self.cwd)}
            out = self.run_cmd(hook, input=json.dumps(event))
            self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")
            event["tool_input"]["command"] = "git status --short"
            self.assertEqual(self.run_cmd(hook, input=json.dumps(event)), "")

    def test_native_lead_stop_checks_message_without_claude_transcript(self):
        task = self.task("normal", "none")
        with (task / "summary.md").open("a") as out:
            out.write("STATUS: PASS\n")
        (self.cwd / ".orchestra/REGISTRY.md").write_text(f"| lead-alpha | agent-12345678 | task | main | {task} | RUNNING | now |\n")
        hook = [sys.executable, ROOT / "hooks/orch-codex-hook.py", "--project", "sample", "--role", "orchestrator"]
        transcript = self.base / "native.jsonl"
        transcript.write_text(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "STATUS: PASS\nGATES: none"}]}}) + "\n")
        event = {"hook_event_name": "SubagentStop", "agent_type": "orch_lead_alpha_normal", "agent_id": "agent-12345678",
                 "cwd": str(self.cwd), "last_assistant_message": "STATUS: PASS\nGATES: none"}
        for path in [None, str(transcript)]:
            event["agent_transcript_path"] = path
            out = self.run_cmd(hook, input=json.dumps(event))
            self.assertEqual(json.loads(out)["decision"], "block")
        self.task()
        with (task / "summary.md").open("a") as out:
            out.write("STATUS: PASS\n")
        event["last_assistant_message"] = "STATUS: PASS\nGATES: codex-verify PASS; codex-review CLEAR"
        self.assertEqual(self.run_cmd(hook, input=json.dumps(event)), "")

    def test_managed_backend_switch_keeps_worktree_and_artifacts(self):
        command = [ROOT / "bin/cc-orch-codex", "session"]
        self.run_cmd([*command, "new", "sample", self.cwd, "--project-name", "demo", "--model", "astra", "--effort", "max", "--inplace", "--no-attach"])
        initial = json.loads((self.base / "tmux-state.json").read_text())["ccorch-codex-sample"]
        self.run_cmd(["bash", "-c", initial])
        self.assert_unrestricted(json.loads((self.base / "codex-args.json").read_text()))
        artifact = self.task() / "keep.txt"
        artifact.write_text("existing user work")
        self.run_cmd([*command, "switch", "sample", "--backend", "hybrid", "--no-attach"])
        out = self.run_cmd([*command, "status", "sample"])
        self.assertIn("backend    claude", out)
        tmux = json.loads((self.base / "tmux-state.json").read_text())
        self.assertIn("CC_ORCH_BACKEND=claude", tmux["ccorch-codex-sample"])
        self.assertIn("cc-orch-runtime", tmux["ccorch-codex-sample"])
        self.assertNotIn("--model", tmux["ccorch-codex-sample"])
        self.run_cmd([*command, "switch", "sample", "--backend", "codex", "--no-attach"])
        self.assertEqual(artifact.read_text(), "existing user work")
        self.assertTrue((self.cwd / ".orchestra/BACKEND-HANDOFF.md").exists())
        self.assertIn("backend    codex", self.run_cmd([*command, "status", "sample"]))
        resumed = json.loads((self.base / "tmux-state.json").read_text())["ccorch-codex-sample"]
        self.assertIn("--model astra --effort max", resumed)
        self.assertIn("--resume saved", resumed)
        self.run_cmd(["bash", "-c", resumed])
        self.assert_unrestricted(json.loads((self.base / "codex-args.json").read_text()))
        self.run_cmd([*command, "stop", "sample"])
        self.run_cmd([*command, "restart", "sample", "--no-attach"])
        restarted = json.loads((self.base / "tmux-state.json").read_text())["ccorch-codex-sample"]
        self.run_cmd(["bash", "-c", restarted])
        self.assert_unrestricted(json.loads((self.base / "codex-args.json").read_text()))

    def test_switch_missing_target_keeps_session(self):
        command = [ROOT / "bin/cc-orch-codex", "session"]
        self.run_cmd([*command, "new", "sample", self.cwd, "--backend", "hybrid", "--project-name", "demo", "--inplace", "--no-attach"])
        before = (self.base / "tmux-state.json").read_text()
        env = dict(self.env, CODEX_BIN=str(self.base / "absent-codex"))
        self.run_cmd([*command, "switch", "sample", "--backend", "codex", "--no-attach"], expected=2, env=env)
        self.assertEqual((self.base / "tmux-state.json").read_text(), before)
        self.assertIn("backend    claude", self.run_cmd([*command, "status", "sample"]))

    def test_switch_refuses_active_leads_without_stopping_session(self):
        command = [ROOT / "bin/cc-orch-codex", "session"]
        self.run_cmd([*command, "new", "sample", self.cwd, "--project-name", "demo", "--inplace", "--no-attach"])
        self.task()
        (self.cwd / ".orchestra/REGISTRY.md").write_text("| lead-alpha | id | task | branch | path | RUNNING | now |\n")
        self.run_cmd([*command, "switch", "sample", "--backend", "hybrid", "--no-attach"], expected=2)
        self.assertIn("backend    codex", self.run_cmd([*command, "status", "sample"]))
        self.assertIn("ccorch-codex-sample", json.loads((self.base / "tmux-state.json").read_text()))

        for status in ["PASS-ish", ""]:
            with self.subTest(status=status):
                (self.cwd / ".orchestra/REGISTRY.md").write_text(f"| lead-alpha | id | task | branch | path | {status} | now |\n")
                self.run_cmd([*command, "switch", "sample", "--backend", "hybrid", "--no-attach"], expected=2)
                self.assertIn("backend    codex", self.run_cmd([*command, "status", "sample"]))
                self.assertIn("ccorch-codex-sample", json.loads((self.base / "tmux-state.json").read_text()))

    def test_switch_accepts_annotated_terminal_leads(self):
        command = [ROOT / "bin/cc-orch-codex", "session"]
        self.run_cmd([*command, "new", "sample", self.cwd, "--project-name", "demo", "--inplace", "--no-attach"])
        artifact = self.task() / "keep.txt"
        artifact.write_text("existing user work")
        (self.cwd / ".orchestra/REGISTRY.md").write_text(
            "| lead-alpha | id | task | branch | path | PASS (done) | now |\n"
            "| lead-bravo | id | task | branch | path | CLOSED - merged | now |\n"
        )
        self.run_cmd([*command, "switch", "sample", "--backend", "hybrid", "--no-attach"])
        self.assertIn("backend    claude", self.run_cmd([*command, "status", "sample"]))
        self.assertIn("CC_ORCH_BACKEND=claude", json.loads((self.base / "tmux-state.json").read_text())["ccorch-codex-sample"])
        self.assertEqual(artifact.read_text(), "existing user work")


if __name__ == "__main__":
    unittest.main(verbosity=2)
