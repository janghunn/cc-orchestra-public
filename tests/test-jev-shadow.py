"""Offline shadow contracts, plus explicitly gated loopback transport tests."""
import builtins
import contextlib
import datetime
import fcntl
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "bin/orch-jev"
loader = importlib.machinery.SourceFileLoader("orch_jev_shadow", str(TOOL))
spec = importlib.util.spec_from_loader(loader.name, loader)
jev = importlib.util.module_from_spec(spec)
loader.exec_module(jev)
KEYS = ("timestamp id lane thread_id mode status jev_model difficulty difficulty_confidence reasoning "
        "suggested_model suggested_effort suggested_reason initial_model initial_effort initial_fast_mode "
        "final_model final_effort final_fast_mode final_fallback_from attempts observation explicit_flags "
        "pressure codex_exit duration_ms jev_latency_ms jev_attempts input_tokens truncated").split()
TID = "00000000-0000-4000-8000-000000000001"
try:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
    LOOPBACK_OK, LOOPBACK_REASON = True, ""
except OSError as error:
    LOOPBACK_OK, LOOPBACK_REASON = False, f"loopback bind denied: {error}"


def response_body(server):
    if server.mode == "malformed":
        return b"not json"
    answers = {"difficulty": {"type": "choice", "choice": "routine", "confidence": 0.9},
               "reasoning": {"type": "noul", "noul": 0.3}}
    answers["difficulty"].update(server.values)
    if server.mode == "schema":
        answers["difficulty"]["choice"] = "normal"
    return json.dumps({"model": "jev-server-reflection-sentinel", "answers": answers,
                       "usage": {"input_tokens": 42}}).encode()


class FakeResponse:
    status = 200

    def __init__(self, data):
        self.fp = io.BytesIO(data)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.fp.close()

    def read1(self, count):
        return self.fp.read1(count)


class FakeOpener:
    def __init__(self, server):
        self.server = server

    def open(self, request, timeout):
        server = self.server
        server.requests.append({"body": json.loads(request.data),
                               "auth_ok": request.get_header("Authorization") == "Bearer " + server.expected})
        if server.mode.isdigit():
            raise urllib.error.HTTPError(request.full_url, int(server.mode), "mock", {}, io.BytesIO())
        if server.mode == "network":
            raise OSError("offline mock")
        if server.mode == "slow":
            time.sleep(timeout + 0.05)
            raise TimeoutError
        return FakeResponse(response_body(server))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        server = self.server
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        server.requests.append({"body": body,
                               "auth_ok": self.headers.get("Authorization") == "Bearer " + server.expected})
        try:
            if server.mode == "hang":
                time.sleep(5)
            self.send_response(int(server.mode) if server.mode.isdigit() else 200)
            self.end_headers()
            self.wfile.write(response_body(server))
        except (BrokenPipeError, ConnectionResetError):
            pass


class ShadowFixture:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jev-shadow-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state, self.task, self.work = [self.base / n for n in ("state", "task", "work")]
        for directory in (self.state, self.task, self.work):
            directory.mkdir()
        self.brief = self.task / "brief.md"
        self.brief_text = "# Work\njev-sentinel-task-text\n## Risk\nRISK: critical\nDEEP REASONING: yes\n"
        self.brief.write_text(self.brief_text)
        self.policy = self.base / "jev-policy.conf"
        self.log = self.state / "codex-shadow.jsonl"
        self.env = dict(os.environ, HOME=str(self.base), CC_ORCH_STATE_DIR=str(self.state),
                        CC_ORCH_JEV_POLICY=str(self.policy), CC_ORCH_JEV_TEMPLATES=str(ROOT / "templates/jev"),
                        TYPESAFE_API_KEY="jev-credential-sentinel")
        self.env.pop("CC_ORCH_BACKEND", None)
        self.server = SimpleNamespace(mode="ok", values={}, expected=self.env["TYPESAFE_API_KEY"], requests=[])
        self.write_policy()

    def write_policy(self, **overrides):
        values = dict(JEV_SHADOW_ENABLED=1, JEV_TIMEOUT_SECONDS=0.1, JEV_SHADOW_TIMEOUT_SECONDS=1)
        values.update(overrides)
        self.policy.write_text("".join(f'{k}="{v}"\n' for k, v in values.items()))

    def flags(self, **overrides):
        values = dict(mode="implement", lane="implement", workdir=self.work, **{"task-dir": self.task},
                      pid=2147483647, t0=time.time(), skip="-", initial="gpt-6-astra@xhigh",
                      pressure="healthy", **{"fast-mode": 1}, explicit=0)
        values.update(overrides)
        return [s for k, v in values.items() for s in ("--" + k, str(v))]

    def reset_logs(self):
        for path in (self.log, self.state / "guard.log"):
            path.unlink(missing_ok=True)
        self.server.requests.clear()

    def record(self):
        lines = self.log.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertEqual(list(record), KEYS)
        self.assertFalse((self.state / "jev.log").exists())
        return record

    def codex_line(self, pair="gpt-6-astra@xhigh", rc=0, *, seconds=0, work=None, fallback=""):
        start = datetime.datetime.fromtimestamp(time.time() + seconds).astimezone().isoformat(timespec="seconds")
        note = f" (fallback-from:{fallback})" if fallback else ""
        return f"{start}  implement    {pair}{note}  exit={rc}  {work or self.work}\n"

    def set_log(self, *lines):
        (self.state / "codex.log").write_text("".join(lines))


class InProcessShadowTests(ShadowFixture, unittest.TestCase):
    def invoke(self, **flags):
        out, err = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), patch.object(jev.os, "setsid"), \
                patch.object(jev.signal, "alarm"), patch.object(jev.urllib.request, "build_opener",
                return_value=FakeOpener(self.server)), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = jev.main(["shadow", *self.flags(**flags)])
        self.assertEqual((rc, out.getvalue(), err.getvalue()), (0, "", ""))
        return self.record()

    def test_policy_defaults_and_invalid_values(self):
        self.policy.write_text("")
        with patch.dict(os.environ, self.env, clear=True):
            p = jev.Policy()
            self.assertEqual(p["SHADOW_ENABLED"], "0")
            self.assertEqual(p["SHADOW_MAP_MECHANICAL"], "gpt-5.6-luna@medium")
            self.assertEqual(p["SHADOW_MAP_ROUTINE"], "gpt-6-astra@high")
            self.assertEqual(p["SHADOW_LOG"], "codex-shadow.jsonl")
            self.write_policy(JEV_SHADOW_MIN_CONFIDENCE=2, JEV_SHADOW_MAX_BYTES=0,
                              JEV_SHADOW_TIMEOUT_SECONDS="abc")
            p = jev.Policy()
            self.assertEqual((p["SHADOW_MIN_CONFIDENCE"], p["SHADOW_MAX_BYTES"], p["SHADOW_TIMEOUT_SECONDS"]),
                             (0.6, 12000, 5700))
            self.write_policy(JEV_SHADOW_MIN_CONFIDENCE=0.8, JEV_SHADOW_MAX_BYTES=4000)
            self.assertEqual(jev.Policy()["SHADOW_MAX_BYTES"], 4000)

    def test_templates_and_choice_validation(self):
        with patch.dict(os.environ, self.env, clear=True):
            choice, noul, risk = [jev.load_template(n) for n in ("difficulty", "difficulty-reasoning", "risk")]
            self.assertEqual(set(choice["criteria"]), set(jev.DIFFICULTIES))
            self.assertEqual(noul["type"], "noul")
            self.assertEqual(set(risk["criteria"]), set(jev.TIERS))
            payload = json.loads(response_body(self.server))
            self.assertTrue(jev.valid_response(payload, {"difficulty": choice, "reasoning": noul}))
            payload["answers"]["difficulty"]["choice"] = "normal"
            self.assertFalse(jev.valid_response(payload, {"difficulty": choice}))
            payload["answers"]["difficulty"]["choice"] = "mechanical"
            self.assertFalse(jev.valid_response(payload, {"difficulty": risk}))
            choice["criteria"] = {"normal": "wrong"}
            (self.base / "difficulty.json").write_text(json.dumps(choice))
            os.environ["CC_ORCH_JEV_TEMPLATES"] = str(self.base)
            self.assertIsNone(jev.load_template("difficulty"))

    def test_ok_observation_privacy_and_request(self):
        self.set_log(self.codex_line(seconds=-10), self.codex_line(work=self.base / "elsewhere"),
                     self.codex_line(rc=1), self.codex_line("gpt-5.6-sol@xhigh+fast-mode", fallback="gpt-6-astra"))
        child = subprocess.Popen(["sleep", "0.4"])
        def finish():
            child.wait()
            (self.task / ".codex-session").write_text(f"implement={TID}|gpt-5.6-sol|xhigh\n")
        thread = threading.Thread(target=finish)
        thread.start()
        r = self.invoke(pid=child.pid)
        thread.join()
        for key, value in dict(status="ok", difficulty="routine", difficulty_confidence=0.9, reasoning=0.3,
                suggested_model="gpt-6-astra", suggested_effort="high", suggested_reason="mapped",
                initial_model="gpt-6-astra", initial_effort="xhigh", initial_fast_mode=True,
                final_model="gpt-5.6-sol", final_effort="xhigh", final_fast_mode=True,
                final_fallback_from="gpt-6-astra", attempts=2, observation="exact", thread_id=TID,
                codex_exit=0, pressure="healthy", explicit_flags=False, input_tokens=42, truncated=False,
                jev_model="jev-1.13.0", jev_attempts=1).items():
            self.assertEqual(r[key], value, key)
        self.assertGreaterEqual(r["duration_ms"], 300)
        self.assertEqual(self.server.requests[0]["body"]["state"], jev.risk_state(self.brief_text).strip())
        self.assertEqual(set(self.server.requests[0]["body"]["questions"]), {"difficulty", "reasoning"})
        self.assertTrue(self.server.requests[0]["auth_ok"])
        for sentinel in ("jev-sentinel-task-text", self.server.expected, "jev-server-reflection-sentinel", str(self.base)):
            self.assertNotIn(sentinel, self.log.read_text())
        self.assertFalse((self.state / "guard.log").exists())
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)

    def test_observation_variants(self):
        cases = [([], "none"), ([self.codex_line()] * 3, "ambiguous"),
                 ([self.codex_line()] * 2, "ambiguous"),
                 ([self.codex_line(rc=1), self.codex_line("gpt-5.6-sol@xhigh", fallback="gpt-6-astra")], "exact")]
        for lines, expected in cases:
            with self.subTest(expected=expected, n=len(lines)):
                self.reset_logs()
                self.set_log(*lines)
                start = time.monotonic()
                r = self.invoke()
                self.assertLess(time.monotonic() - start, 1)
                self.assertEqual((r["observation"], r["attempts"]), (expected, len(lines)))
                if not lines:
                    self.assertIsNone(r["final_model"])
        self.reset_logs()
        with patch.object(jev, "shadow_session", side_effect=[None, f"{TID}|gpt-5.6-luna|medium"]):
            self.assertEqual(self.invoke()["observation"], "ambiguous")
        self.reset_logs()
        child = subprocess.Popen(["sleep", "3"])
        try:
            start = time.monotonic()
            r = self.invoke(pid=child.pid)
            self.assertLess(time.monotonic() - start, 2.5)
            self.assertEqual(r["observation"], "timeout")
            self.assertIsNone(r["final_model"])
        finally:
            child.terminate()
            child.wait()

    def test_brief_boundary_and_read_audit(self):
        self.brief.unlink()
        (self.task / "plan.md").write_text("jev-sentinel-forbidden-plan")
        self.brief.symlink_to(self.task / "plan.md")
        for kind in ("symlink", "fifo", "directory"):
            with self.subTest(kind=kind):
                self.reset_logs()
                start = time.monotonic()
                self.assertEqual(self.invoke()["status"], "skipped:unreadable")
                self.assertLess(time.monotonic() - start, 1)
                self.assertFalse(self.server.requests)
                for path in self.state.iterdir():
                    self.assertNotIn("jev-sentinel-forbidden-plan", path.read_text())
                if kind == "symlink":
                    self.brief.unlink()
                    os.mkfifo(self.brief)
                elif kind == "fifo":
                    self.brief.unlink()
                    self.brief.mkdir()
        self.brief.rmdir()
        self.brief.write_text(self.brief_text)
        self.reset_logs()
        reads = []
        real_os_open, real_open, real_io_open = os.open, builtins.open, io.open
        def audit_open(path, flags, *args, **kwargs):
            if flags & os.O_ACCMODE == os.O_RDONLY:
                reads.append(Path(path))
            return real_os_open(path, flags, *args, **kwargs)
        def audit_text(original):
            def wrapper(path, mode="r", *args, **kwargs):
                if isinstance(path, (str, Path)) and "r" in mode:
                    reads.append(Path(path))
                return original(path, mode, *args, **kwargs)
            return wrapper
        with patch.object(os, "open", side_effect=audit_open), \
                patch.object(builtins, "open", side_effect=audit_text(real_open)), \
                patch.object(io, "open", side_effect=audit_text(real_io_open)):
            self.assertEqual(self.invoke()["status"], "ok")
        # Session metadata is explicitly required by observation; no other task content is read.
        self.assertEqual({p for p in reads if p.parent == self.task}, {self.brief, self.task / ".codex-session"})
        self.assertFalse(any(p.is_relative_to(self.work) for p in reads))

    def test_egress_and_truncation(self):
        for text in ('token = "' + "a1b2c3d4" * 4 + '"', 'token =\nRISK: low\n"' + "a1b2c3d4" * 4 + '"\n'):
            self.reset_logs()
            self.brief.write_text(text)
            self.assertEqual(self.invoke()["status"], "skipped:secret-shaped")
            self.assertFalse(self.server.requests)
            self.assertEqual(len((self.state / "guard.log").read_text().splitlines()), 1)
        self.reset_logs()
        self.brief.write_text("가나다abc" * 20000)
        self.write_policy(JEV_SHADOW_MAX_BYTES=4000)
        self.assertTrue(self.invoke()["truncated"])
        sent = self.server.requests[0]["body"]["state"]
        self.assertLessEqual(len(sent.encode()), 4000)
        self.assertEqual(sent, sent.encode().decode())

    def test_missing_and_empty(self):
        self.brief.unlink()
        self.assertEqual(self.invoke()["status"], "skipped:unreadable")
        self.reset_logs()
        self.brief.write_text(" \n\t")
        self.assertEqual(self.invoke()["status"], "skipped:empty")

    def test_fail_open_matrix(self):
        cases = [("no key", {}, {"TYPESAFE_API_KEY": ""}),
                 ("disabled", {"JEV_ENABLED": 0}, {}), ("disabled", {"JEV_SHADOW_ENABLED": 0}, {}),
                 ("codex-only backend", {}, {"CC_ORCH_BACKEND": "codex"}),
                 ("template", {}, {"CC_ORCH_JEV_TEMPLATES": str(self.base / "absent")}),
                 ("config", {"JEV_ENDPOINT": "https://invalid.example/"}, {})]
        for reason, values, env in cases:
            with self.subTest(reason=reason):
                self.reset_logs()
                self.write_policy(**values)
                with patch.dict(self.env, env):
                    self.assertEqual(self.invoke()["status"], "unavailable:" + reason)
                self.assertFalse(self.server.requests)
                self.assertEqual(len((self.state / "guard.log").read_text().splitlines()), 1)
        self.reset_logs()
        self.write_policy()
        (self.state / "jev.key").write_text(self.server.expected)
        (self.state / "jev.key").chmod(0o644)
        with patch.dict(self.env, {"TYPESAFE_API_KEY": ""}):
            self.assertEqual(self.invoke()["status"], "unavailable:no key")

    def test_transport_failure_matrix_still_observes(self):
        self.set_log(self.codex_line())
        for mode, reason in [("401", "auth (HTTP 401)"), ("429", "rate limit (HTTP 429)"),
                ("529", "overloaded (HTTP 529)"), ("malformed", "malformed response"),
                ("schema", "schema"), ("network", "network"), ("slow", "timeout")]:
            with self.subTest(mode=mode):
                self.reset_logs()
                self.server.mode = mode
                self.set_log(self.codex_line())
                r = self.invoke()
                self.assertEqual(r["status"], "unavailable:" + reason)
                self.assertIsNone(r["difficulty"])
                self.assertEqual(r["suggested_reason"], "no-answer")
                self.assertEqual(r["final_model"], "gpt-6-astra")
                self.assertEqual(r["observation"], "exact")
                self.assertEqual(len((self.state / "guard.log").read_text().splitlines()), 1)

    def test_facade_skips_and_mapping(self):
        for reason in ("resume", "dry-run", "explicit-flags", "withheld", "no-route"):
            self.reset_logs()
            r = self.invoke(skip=reason, explicit=1, initial="")
            self.assertEqual((r["status"], r["observation"]), ("skipped:" + reason, "none"))
            self.assertTrue(r["explicit_flags"])
            self.assertIsNone(r["initial_fast_mode"])
            self.assertFalse(self.server.requests)
        self.reset_logs()
        self.server.values = {"confidence": 0.5}
        r = self.invoke()
        self.assertIsNone(r["suggested_model"])
        self.assertEqual(r["suggested_reason"], "low-confidence")
        self.reset_logs()
        self.server.values = {}
        self.write_policy(JEV_SHADOW_MAP_ROUTINE="bogus")
        self.assertEqual(self.invoke()["suggested_reason"], "unmapped")

    def test_log_failure_and_bounded_lock(self):
        self.write_policy(JEV_SHADOW_LOG=self.state)
        # No shadow record is possible when the destination itself is a directory.
        with patch.object(self, "record", return_value={}):
            self.invoke()
        lines = (self.state / "guard.log").read_text().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn("JEV: shadow", lines[0])
        self.assertTrue(lines[0].endswith("— ok"))
        self.reset_logs()
        self.write_policy()
        self.log.touch(mode=0o644)
        ready = threading.Event()
        def hold_lock():
            with self.log.open("a") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                ready.set()
                time.sleep(3)
        thread = threading.Thread(target=hold_lock)
        thread.start()
        ready.wait()
        start = time.monotonic()
        self.assertEqual(self.invoke()["status"], "ok")
        self.assertLess(time.monotonic() - start, 2.6)
        thread.join()
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)

    def report(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), patch.object(jev, "call_jev") as call, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(jev.main(["shadow-report", "--log", str(self.log)]), 0)
            call.assert_not_called()
        self.assertEqual(err.getvalue(), "")
        return out.getvalue()

    def test_report_remaps_counts_and_denominators(self):
        base = self.invoke()
        rows = []
        for i in range(12):
            row = dict(base, observation="exact", final_model="gpt-6-astra", final_effort="high",
                       attempts=1, codex_exit=0)
            if i in (2, 3, 4):
                row["final_effort"] = "xhigh"
            if i == 4:
                row["final_effort"] = "ultra"
            if i == 5:
                row["final_effort"] = "medium"
            if i == 6:
                row["final_model"] = "unknown-model"
            if i in (7, 8):
                row["observation"] = "ambiguous"
            if i in (9, 10):
                row.update(status="skipped:empty" if i == 9 else "unavailable:no key", difficulty=None,
                           difficulty_confidence=None, suggested_model=None, suggested_effort=None,
                           observation="none", codex_exit=None)
            if i == 11:
                row["codex_exit"] = None
            if i == 0:
                row.update(suggested_effort="medium", codex_exit=1, attempts=2)
            rows.append(row)
        rows.append(dict(base, observation="exact", attempts=None, codex_exit="7"))
        self.log.write_text("".join(json.dumps(row) + "\n" for row in rows) + '{}\n')
        out = self.report()
        for line in (f"JEV shadow report — {self.log}", "records: 13  malformed: 1",
                "status: ok 11 · skipped:empty 1 · unavailable:no key 1",
                "comparable (exact observation, suggestion and final pair known): 8",
                "  agreement (suggested == final): 3 (37.5%)",
                "  suggested lower than final:     3 (37.5%)",
                "  suggested higher than final:    1 (12.5%)", "  unranked pair:                  1",
                "stored suggestions differing from the current mapping: 1",
                "counts only — this report draws no conclusion."):
            self.assertIn(line, out.splitlines())
        self.assertIn("routine: 11 records · observed (exact, exit known): 7 · unobserved: 4", out)
        self.assertIn("codex failures (exit != 0): 1/7 (14.3%) · retries (attempts > 1): 1/7 (14.3%) — fewer than 10 records", out)
        self.assertIn("0/0 (n/a)", out)
        self.write_policy(JEV_SHADOW_MAP_ROUTINE="gpt-6-astra@xhigh")
        self.assertIn("agreement (suggested == final): 2 (25.0%)", self.report())

    def test_report_unexpected_failure_is_visible(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(jev, "Policy", side_effect=RuntimeError("private detail")), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(jev.main(["shadow-report"]), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "shadow-report: failed (RuntimeError)\n")

    def test_help_and_usage(self):
        with patch.dict(os.environ, self.env, clear=True):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(jev.main(["--help"]), 0)
            for word in ("lint-brief", "risk", "scan", "advisory", "Codex-only", "shadow"):
                self.assertIn(word, out.getvalue())
            for command in ("shadow", "shadow-report"):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(jev.main([command, "--bogus"]), 2)
                self.assertEqual(len(err.getvalue().splitlines()), 1)
            self.assertFalse(self.log.exists())


class SubprocessShadowTests(ShadowFixture, unittest.TestCase):
    def test_concurrent_atomic_append(self):
        self.env.pop("TYPESAFE_API_KEY")
        workers = [subprocess.Popen([sys.executable, str(TOOL), "shadow", *self.flags(lane=f"lane-{i}")],
                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for i in range(8)]
        for worker in workers:
            self.assertEqual(worker.communicate(timeout=5), (b"", b""))
            self.assertEqual(worker.returncode, 0)
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(rows), 8)
        self.assertEqual(len({row["id"] for row in rows}), 8)
        for row in rows:
            self.assertEqual(list(row), KEYS)
            self.assertEqual(row["status"], "unavailable:no key")


@unittest.skipUnless(LOOPBACK_OK, LOOPBACK_REASON)
class LoopbackShadowTests(ShadowFixture, unittest.TestCase):
    def test_real_transport_failures_and_deadline(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.expected, server.requests, server.values = self.server.expected, [], {}
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.write_policy(JEV_ENDPOINT=f"http://127.0.0.1:{server.server_port}/", JEV_TIMEOUT_SECONDS=1)
            for mode, reason in [("hang", "timeout"), ("401", "auth (HTTP 401)"),
                    ("429", "rate limit (HTTP 429)"), ("529", "overloaded (HTTP 529)"),
                    ("malformed", "malformed response")]:
                with self.subTest(mode=mode):
                    self.reset_logs()
                    server.mode = mode
                    start = time.monotonic()
                    worker = subprocess.Popen([sys.executable, str(TOOL), "shadow", *self.flags()],
                            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.assertEqual(worker.communicate(timeout=4), (b"", b""))
                    self.assertLess(time.monotonic() - start, 4)
                    self.assertEqual(worker.returncode, 0)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(worker.pid, 0)
                    self.assertEqual(self.record()["status"], "unavailable:" + reason)
            self.assertTrue(server.requests)
            self.assertTrue(all(request["auth_ok"] for request in server.requests))
            self.assertNotIn(server.expected, json.dumps(server.requests))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    if not LOOPBACK_OK:
        print("skip: " + LOOPBACK_REASON, flush=True)
    unittest.main(verbosity=2)
