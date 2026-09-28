"""Offline local-companion contracts; socket suites skip explicitly when bind is denied."""
import sys
sys.dont_write_bytecode = True

import contextlib
import copy
import hashlib
import http.client
import http.server
import importlib.machinery
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import socketserver
import stat
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "bin/orch-jev-local"
loader = importlib.machinery.SourceFileLoader("orch_jev_local", str(TOOL))
local = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(local)
jev = local.orch
SENTINEL = "synthetic-local-sentinel-key"
KEYS = ("timestamp", "id", "status", "model", "jev_model", "jev_outcome", "chunks", "local_p",
        "jev_p", "min_option_mass", "requests", "latency_ms", "prompt_tokens", "cached_tokens")


def probe_bind(family):
    try:
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="jl-") as directory:
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0) if family == socket.AF_INET else directory + "/s")
        return ""
    except OSError as error:
        reason = f"{family.name} bind denied: {error}"
        print("SKIP: " + reason, flush=True)
        return reason


INET_REASON = probe_bind(socket.AF_INET)
UNIX_REASON = probe_bind(socket.AF_UNIX)


def candidates(a=0.8, b=0.2):
    return [{"token": "A", "logprob": math.log(a)}, {"token": " B", "logprob": math.log(b)}]


def response(tokens=None):
    return {"model": local.alias(local.MODEL_SHA256),
            "choices": [{"logprobs": {"content": [{"top_logprobs": candidates() if tokens is None else tokens}]}}],
            "timings": {"prompt_n": 42, "cache_n": 7}}


def handoff():
    return {"version": 1, "pid": 123, "t0": 456.9,
            "state": {"chunks": [{"source": "fixture", "lines": "1-2", "text": "안녕\n", "id": "c1"},
                                 {"source": "second", "lines": "3-4", "text": "hello\n", "id": "c2"}]},
            "questions": {name: {"type": "noul", "instructions": f"Check {name}",
                                 "criteria": {"true": "yes", "false": "no"}} for name in ("c1", "c2")},
            "jev_model": "jev-1.13.0", "jev_outcome": "ok", "jev_noul": {"c1": 0.9, "c2": 0.1}}


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="jl-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.state = self.base / "state"
        self.policy = self.base / "policy"
        self.log = self.state / "jev-local.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")
                    and k not in ("CC_ORCH_BACKEND", "TYPESAFE_API_KEY")}
        self.env.update(HOME=str(self.home), CC_ORCH_STATE_DIR=str(self.state),
                        CC_ORCH_JEV_POLICY=str(self.policy), CC_ORCH_JEV_TEMPLATES=str(ROOT / "templates/jev"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.environment = patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.write_policy()

    def write_policy(self, **overrides):
        values = {"JEV_LOCAL_ENABLED": "1", "JEV_LOCAL_TIMEOUT_SECONDS": 1,
                  "JEV_LOCAL_DEADLINE_SECONDS": 3, **overrides}
        self.policy.write_text("\n".join(f"{key}={json.dumps(value)}" for key, value in values.items()) + "\n")

    def invoke(self, *args, input=None, env=None, tool=TOOL):
        return subprocess.run([sys.executable, str(tool), *map(str, args)], input=input,
                              env=dict(os.environ) if env is None else env,
                              capture_output=True, text=True, timeout=12)

    def run_worker(self, data=None, reply=None, error=None, raw=None):
        raw = json.dumps(handoff() if data is None else data).encode() if raw is None else raw
        out, err = io.StringIO(), io.StringIO()
        with patch.object(sys, "stdin", SimpleNamespace(buffer=io.BytesIO(raw))), \
             patch.object(local, "post_unix", return_value=response() if reply is None else reply,
                          side_effect=error) as transport, \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(local.main(["worker"]), 0)
        self.assertEqual((out.getvalue(), err.getvalue()), ("", ""))
        rows = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return rows[-1] if rows else None, transport


class ScoringTests(Case):
    def test_variants_and_refusals(self):
        tokens = [{"token": " [A] ", "logprob": math.log(0.4)},
                  {"token": "A", "logprob": math.log(0.4)},
                  {"token": " [ B ]", "logprob": math.log(0.2)}]
        probs, missing, bound, mass = local.score_letters(tokens, "AB")
        self.assertAlmostEqual(probs["A"], 0.8)
        self.assertEqual((missing, bound), ([], 0))
        self.assertAlmostEqual(mass, 1)
        for values, error in (([{"token": "think", "logprob": -0.1}], local.NoOptionToken),
                              (candidates(0.01, 0.02), local.NonOptionAnswer),
                              ([{"token": "A", "logprob": -0.1}], local.OptionMassUnknown)):
            with self.subTest(error=error), self.assertRaises(error):
                local.score_letters(values, "AB")
        probs, missing, bound, _ = local.score_letters(
            [{"token": "A", "logprob": -0.1}, {"token": "x", "logprob": -10}], "AB")
        self.assertEqual(missing, ["B"])
        self.assertTrue(0 < bound < local.MISSING_BOUND)
        self.assertGreater(probs["B"], 0)
        for bad in (True, float("nan"), float("inf"), 1, "-1"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                local.score_letters([{"token": "A", "logprob": bad}], "AB")

    def test_exact_two_chunk_prompt(self):
        data = handoff()
        expected = ('State:\n{"chunks": [{"source": "fixture", "lines": "1-2", "text": "안녕\\n", "id": "c1"}, '
                    '{"source": "second", "lines": "3-4", "text": "hello\\n", "id": "c2"}]}\n\n'
                    'Question: Check c1\nOptions:\n[A] true: yes\n[B] false: no\n\n'
                    'Answer with the letter of the best option only.')
        self.assertEqual(local.build_prompt(data["state"], data["questions"]["c1"]), expected)

    def test_default_keys_match_policy_parser(self):
        for name in jev.DEFAULTS:
            with self.subTest(name=name):
                self.assertIsNotNone(re.fullmatch(r"[A-Z_]+", name))

    def test_syntax_defaults_usage_and_paths(self):
        compile(TOOL.read_bytes(), str(TOOL), "exec")
        os.environ["CC_ORCH_JEV_POLICY"] = str(ROOT / "jev-policy.conf")
        policy = jev.Policy()
        for name, value in jev.DEFAULTS.items():
            if name.startswith("JEV_LOCAL_"):
                self.assertEqual(policy.values[name], value)
        self.assertEqual(policy["LOCAL_ENABLED"], "0")
        self.assertEqual(local.state_path("relative"), self.state / "relative")
        self.assertEqual(local.state_path("/absolute"), Path("/absolute"))
        for args in ([], ["unknown"], ["worker", "extra"], ["serve", "extra"],
                     ["report", "--log"], ["report", "--other", "x"]):
            result = self.invoke(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr.strip(), local.USAGE)


class FakeSocket:
    def __init__(self):
        self.timeouts, self.addresses = [], []
        self.closed = False
        self.stopped = threading.Event()

    def settimeout(self, timeout):
        self.timeouts.append(timeout)

    def connect(self, address):
        self.addresses.append((os.getcwd(), address))

    def shutdown(self, how):
        self.stopped.set()

    def close(self):
        self.closed = True


class FakeResponse:
    def __init__(self, body=b'{"ok": true}', status=200, drip=False):
        self.body, self.status, self.drip = io.BytesIO(body), status, drip

    def read(self, size):
        if self.drip:
            time.sleep(0.04)
            return b" "
        return self.body.read(size)

    def isclosed(self):
        return False


class FakeConnection:
    def __init__(self, response, stall=False):
        self.response, self.stall, self.requests, self.closed = response, stall, [], False

    def request(self, *args, **kwargs):
        self.requests.append((args, kwargs))

    def getresponse(self):
        if self.stall:
            self.sock.stopped.wait(2)
            raise http.client.RemoteDisconnected()
        return self.response

    def close(self):
        self.closed = True


class TransportTests(Case):
    def transport(self, reply=None, stall=False, path=None, timeout=0.15):
        self.sock = FakeSocket()
        self.conn = FakeConnection(reply or FakeResponse(), stall)
        with patch.object(local.socket, "socket", return_value=self.sock), \
             patch.object(local.http.client, "HTTPConnection", return_value=self.conn):
            return local.post_unix(path or self.base / "server.sock", {"text": "안녕"}, timeout)

    def test_ok_request_timeout_updates_and_closes(self):
        self.assertEqual(self.transport(), {"ok": True})
        self.assertTrue(self.sock.closed and self.conn.closed)
        self.assertGreaterEqual(len(self.sock.timeouts), 4)
        self.assertEqual(self.sock.timeouts, sorted(self.sock.timeouts, reverse=True))
        args, kwargs = self.conn.requests[0]
        self.assertEqual(args, ("POST", "/v1/chat/completions"))
        self.assertEqual(json.loads(kwargs["body"]), {"text": "안녕"})
        self.assertEqual(kwargs["headers"]["User-Agent"], "cc-orchestra-orch-jev-local")

    def test_http_and_malformed_no_redirects(self):
        for reply, message in ((FakeResponse(status=302), "http 302"), (FakeResponse(status=500), "http 500"),
                               (FakeResponse(b"no json"), "malformed response"),
                               (FakeResponse(b"\xff"), "malformed response"),
                               (FakeResponse(b"x" * (local.RESPONSE_MAX_BYTES + 1)), "malformed response")):
            with self.subTest(message=message), self.assertRaisesRegex(local.LocalError, message):
                self.transport(reply)
            self.assertEqual(len(self.conn.requests), 1)
            self.assertTrue(self.conn.closed and self.sock.closed)

    def test_drip_total_deadline_and_header_stall(self):
        for reply, stall in ((FakeResponse(drip=True), False), (FakeResponse(), True)):
            started = time.monotonic()
            with self.subTest(stall=stall), self.assertRaises(TimeoutError):
                self.transport(reply, stall=stall)
            self.assertLess(time.monotonic() - started, 0.65)
            self.assertTrue(self.conn.closed and self.sock.closed)

    def test_long_socket_path_restores_cwd_on_success_and_failure(self):
        directory = self.base / ("a" * 110)
        directory.mkdir()
        path = directory / "s.sock"
        original = os.getcwd()
        self.transport(path=path)
        self.assertEqual(self.sock.addresses, [(str(directory), "s.sock")])
        self.assertEqual(os.getcwd(), original)
        with patch.object(FakeSocket, "connect", side_effect=PermissionError), self.assertRaises(PermissionError):
            self.transport(path=path)
        self.assertEqual(os.getcwd(), original)

    def test_continuous_header_drip_with_real_http_parser(self):
        # No socket is opened: exercise getresponse's internal repeated reads.
        class DripRaw(io.RawIOBase):
            def readable(self):
                return True

            def readinto(raw, buffer):
                if sock.stopped.wait(0.01):
                    return 0
                buffer[0] = 32
                return 1

        sock = FakeSocket()
        sock.sendall = lambda data: None
        sock.makefile = lambda mode: io.BufferedReader(DripRaw())
        started = time.monotonic()
        with patch.object(local.socket, "socket", return_value=sock), self.assertRaises(TimeoutError):
            local.post_unix(self.base / "s", {}, 0.15)
        self.assertLess(time.monotonic() - started, 0.65)

    def test_real_http_parser_body_drip_and_complete_response(self):
        for drip in (False, True):
            sock = FakeSocket()
            prefix = io.BytesIO(b'HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n'
                                + (b'' if drip else b'{"ok": true}'))

            class Raw(io.RawIOBase):
                def readable(self):
                    return True

                def readinto(raw, buffer):
                    data = prefix.read(len(buffer))
                    if data:
                        buffer[:len(data)] = data
                        return len(data)
                    if not drip or sock.stopped.wait(0.04):
                        return 0
                    buffer[0] = 32
                    return 1

            sock.sendall = lambda data: None
            sock.makefile = lambda mode: io.BufferedReader(Raw())
            started = time.monotonic()
            with self.subTest(drip=drip), patch.object(local.socket, "socket", return_value=sock):
                if drip:
                    with self.assertRaises(TimeoutError):
                        local.post_unix(self.base / "s", {}, 0.15)
                else:
                    self.assertEqual(local.post_unix(self.base / "s", {}, 0.15), {"ok": True})
            self.assertLess(time.monotonic() - started, 0.65)


class WorkerTests(Case):
    def test_ok_exact_schema_values_and_only_private_log(self):
        data = handoff()
        privacy = "unique-private-input-sentinel-283719"
        data["state"]["chunks"][0].update(text=privacy, source=privacy, lines=privacy)
        data["questions"]["c1"]["instructions"] = privacy
        row, call = self.run_worker(data)
        self.assertEqual(tuple(row), KEYS)
        self.assertEqual(row["status"], "ok")
        self.assertEqual((row["id"], row["chunks"], row["requests"]), ("123:456", 2, 2))
        self.assertEqual(row["model"], local.alias(local.MODEL_SHA256))
        self.assertEqual(row["jev_p"], [0.9, 0.1])
        self.assertEqual(row["local_p"], [0.8, 0.8])
        self.assertEqual((row["prompt_tokens"], row["cached_tokens"]), (84, 14))
        self.assertAlmostEqual(row["min_option_mass"], 1)
        self.assertIsInstance(row["latency_ms"], int)
        self.assertEqual(list(self.state.iterdir()), [self.log])
        self.assertEqual(stat.S_IMODE(self.log.stat().st_mode), 0o600)
        for path in self.state.rglob("*"):
            if path.is_file():
                self.assertNotIn(privacy, path.read_text())
        self.assertEqual(call.call_count, 2)
        for index, (_, body, timeout) in enumerate(c.args for c in call.call_args_list):
            self.assertEqual(timeout, 1)
            self.assertEqual(body, {"model": row["model"], "messages": [{"role": "user", "content":
                             local.build_prompt(data["state"], data["questions"][f"c{index + 1}"])}],
                             "max_tokens": 1, "temperature": 0, "logprobs": True, "top_logprobs": 20,
                             "chat_template_kwargs": {"enable_thinking": False}})

    def test_transport_failure_classes(self):
        errors = [(FileNotFoundError(), "server"), (ConnectionRefusedError(), "server"),
                  (PermissionError(), "socket-denied"), (TimeoutError(), "timeout"),
                  (local.LocalError("http 302"), "http 302"), (local.LocalError("http 500"), "http 500"),
                  (local.LocalError("malformed response"), "malformed response"),
                  (OSError(), "network"), (http.client.HTTPException(), "network"),
                  (RuntimeError(), "internal error")]
        for error, status in errors:
            with self.subTest(status=status):
                row, call = self.run_worker(error=error)
                self.assertEqual(row["status"], "unavailable:" + status)
                self.assertEqual(row["requests"], 1)
                self.assertEqual(call.call_count, 1)
                self.assertIsNone(row["local_p"])

    def test_response_failures(self):
        wrong = response()
        wrong["model"] = "other"
        fixtures = [(wrong, "model-mismatch"), ({}, "malformed response"),
                    ([], "malformed response"), (response(["bad"]), "malformed response"),
                    (response([{"token": "A", "logprob": True}]), "malformed response"),
                    (response([{"token": "think", "logprob": -0.1}]), "no-option"),
                    (response(candidates(0.01, 0.02)), "non-option"),
                    (response([{"token": "A", "logprob": -0.1}]), "option-mass-unknown")]
        for reply, status in fixtures:
            with self.subTest(status=status):
                row, call = self.run_worker(reply=reply)
                self.assertEqual(row["status"], "unavailable:" + status)
                self.assertEqual(call.call_count, 1)

    def test_handoff_validation(self):
        fixtures = [b"not json", b" " * (local.HANDOFF_MAX_BYTES + 1), b"[]"]
        def changed(key, value):
            data = handoff()
            data[key] = value
            return data
        invalid = [changed("extra", 1), changed("version", True), changed("pid", -1), changed("pid", True),
                   changed("t0", float("nan")), changed("t0", float("inf")), changed("t0", True),
                   changed("state", {"chunks": []}), changed("state", {"chunks": [], "extra": 1}),
                   changed("jev_model", None), changed("jev_outcome", "x" * 65),
                   changed("jev_outcome", "ok\n"), changed("jev_noul", {"c1": 0.2}),
                   changed("jev_noul", {"c1": True, "c2": 0.1}),
                   changed("jev_noul", {"c1": 1.1, "c2": 0.1}),
                   changed("jev_noul", {"c1": float("nan"), "c2": 0.1})]
        for key in handoff():
            data = handoff()
            del data[key]
            invalid.append(data)
        for change in ("question_id", "question_order", "question_type", "criteria", "chunk_extra", "chunk_type"):
            data = handoff()
            if change == "question_id":
                data["questions"]["wrong"] = data["questions"].pop("c1")
            elif change == "question_order":
                data["questions"] = dict(reversed(list(data["questions"].items())))
            elif change == "question_type":
                data["questions"]["c1"]["type"] = "choice"
            elif change == "criteria":
                data["questions"]["c1"]["criteria"]["extra"] = "x"
            elif change == "chunk_extra":
                data["state"]["chunks"][0]["extra"] = "x"
            else:
                data["state"]["chunks"][0]["text"] = 12
            invalid.append(data)
        fixtures += [json.dumps(data).encode() for data in invalid]
        for index, raw in enumerate(fixtures):
            with self.subTest(index=index):
                row, call = self.run_worker(raw=raw)
                self.assertEqual(row["status"], "unavailable:handoff")
                self.assertEqual(row["requests"], 0)
                call.assert_not_called()

    def test_secret_guard_all_four_checks(self):
        for location in ("text", "source", "question", "assembled"):
            data = handoff()
            secret = "api_key=" + "s" * 28
            if location == "question":
                data["questions"]["c1"]["instructions"] = secret
            elif location == "assembled":
                data["state"]["chunks"][0]["text"] = "api_key=\n" + "s" * 28
            else:
                data["state"]["chunks"][0][location] = secret
            row, call = self.run_worker(data)
            self.assertEqual(row["status"], "skipped:secret-shaped")
            call.assert_not_called()
        self.assertNotIn(secret, self.log.read_text())

    def test_disabled_paths_create_nothing(self):
        for values, backend in (({"JEV_LOCAL_ENABLED": "0"}, "hybrid"),
                                ({"JEV_ENABLED": "0"}, "hybrid"), ({}, "codex")):
            self.write_policy(**values)
            os.environ["CC_ORCH_BACKEND"] = backend
            row, call = self.run_worker()
            self.assertIsNone(row)
            call.assert_not_called()
            self.assertFalse(self.state.exists())

    def test_jev_unavailable_and_optional_timings(self):
        data = handoff()
        data.update(jev_noul=None, jev_outcome="network")
        reply = response()
        reply["timings"] = {"prompt_n": True, "cache_n": "7"}
        row, _ = self.run_worker(data, reply=reply)
        self.assertEqual(row["status"], "ok")
        self.assertIsNone(row["jev_p"])
        self.assertIsNone(row["prompt_tokens"])
        self.assertIsNone(row["cached_tokens"])

    def test_deadline_appends_once_and_exits(self):
        def alarm(seconds):
            if seconds:
                signal.getsignal(signal.SIGALRM)(signal.SIGALRM, None)
        with patch.object(local.signal, "alarm", side_effect=alarm), \
             patch.object(local.os, "_exit", side_effect=SystemExit(0)) as exit_call, \
             self.assertRaises(SystemExit):
            self.run_worker()
        exit_call.assert_called_once_with(0)
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "unavailable:deadline")

    def test_symlink_fifo_and_unwritable_log(self):
        self.state.mkdir()
        target = self.base / "target"
        target.write_text("untouched")
        self.log.symlink_to(target)
        self.assertFalse(local.append_record(self.log, {"test": 1}))
        self.assertEqual(target.read_text(), "untouched")
        self.log.unlink()
        os.mkfifo(self.log)
        start = time.monotonic()
        self.assertFalse(local.append_record(self.log, {"test": 1}))
        self.assertLess(time.monotonic() - start, 0.5)
        self.log.unlink()
        with patch.object(local.os, "open", side_effect=PermissionError):
            self.assertFalse(local.append_record(self.log, {"test": 1}))
        self.assertEqual(list(self.state.iterdir()), [])

    def test_config_sha(self):
        self.write_policy(JEV_LOCAL_MODEL_DIGEST="bad")
        row, call = self.run_worker()
        self.assertEqual(row["status"], "unavailable:config")
        call.assert_not_called()


class JevResponse:
    status = 200

    def __init__(self, body):
        self.fp = io.BytesIO(json.dumps(body).encode())

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.fp.close()

    def read1(self, size):
        return self.fp.read1(size)


class HookTests(Case):
    def setUp(self):
        super().setUp()
        self.brief = self.base / "brief.md"
        self.brief.write_text("# Task\n## Acceptance\n1. Run true.\n## Verification\ntrue\n## Risk\nRISK: low\n")
        os.environ["TYPESAFE_API_KEY"] = SENTINEL
        self.requests, self.handoffs = [], []
        self.failure = False

    def open(self, request, timeout):
        body = json.loads(request.data)
        self.requests.append(body)
        if self.failure:
            raise OSError("offline")
        answers = {name: ({"type": "noul", "noul": 0.8} if question["type"] == "noul" else
                          {"type": "choice", "choice": "normal", "confidence": 0.9})
                   for name, question in body["questions"].items()}
        return JevResponse({"model": body["model"], "answers": answers})

    def capture(self, args, **kwargs):
        self.handoffs.append((args, kwargs.copy(), json.load(kwargs["stdin"])))

    def run_jev(self, command, source=None, stdin=None, popen_error=None):
        self.requests.clear()
        self.handoffs.clear()
        out, err = io.StringIO(), io.StringIO()
        with patch.object(jev.urllib.request, "build_opener", return_value=self), \
             patch.object(jev.subprocess, "Popen", side_effect=popen_error or self.capture) as popen, \
             patch.object(sys, "stdin", io.StringIO(stdin or "")), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = jev.main([command, str(self.brief if source is None else source)])
        return (out.getvalue(), err.getvalue(), code), popen

    def test_hook_exact_launch_handoff_and_env(self):
        result, popen = self.run_jev("scan")
        self.assertEqual(result[1:], ("", 0))
        popen.assert_called_once()
        args, kwargs, data = self.handoffs[0]
        self.assertEqual(args, [sys.executable, "-B", str(TOOL), "worker"])
        self.assertTrue(kwargs["start_new_session"])
        self.assertTrue(kwargs["close_fds"])
        self.assertEqual(kwargs["cwd"], "/")
        self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
        self.assertNotIn("TYPESAFE_API_KEY", kwargs["env"])
        self.assertEqual(set(data), local.HANDOFF_KEYS)
        self.assertEqual(data["state"], self.requests[0]["state"])
        self.assertEqual(data["questions"], self.requests[0]["questions"])
        self.assertEqual(data["jev_noul"], {c: 0.8 for c in data["questions"]})
        self.assertEqual(data["jev_model"], "jev-1.13.0")
        self.assertEqual(data["jev_outcome"], "ok")
        self.assertEqual(data["pid"], os.getpid())

    def test_off_on_byte_identity_all_paths(self):
        for command, unavailable, stdin in (("scan", False, False), ("scan", True, False),
                                             ("scan", False, True), ("lint-brief", False, False),
                                             ("risk", False, False)):
            with self.subTest(command=command, unavailable=unavailable, stdin=stdin):
                self.failure = unavailable
                results = []
                for enabled in ("0", "1"):
                    self.write_policy(JEV_LOCAL_ENABLED=enabled)
                    result, popen = self.run_jev(command, source="-" if stdin else None,
                                               stdin="Synthetic stdin\n" if stdin else None)
                    results.append(result)
                    expected = int(enabled == "1" and command == "scan")
                    self.assertEqual(popen.call_count, expected)
                    if unavailable and enabled == "1":
                        self.assertIsNone(self.handoffs[0][2]["jev_noul"])
                        self.assertEqual(self.handoffs[0][2]["jev_outcome"], "network")
                self.assertEqual(*results)

    def test_pre_call_skips_do_not_launch(self):
        cases = (("api_key=" + "a" * 28, {}, "hybrid"), ("", {}, "hybrid"),
                 ("content", {}, "codex"), ("content", {"JEV_ENABLED": "0"}, "hybrid"))
        for text, policy, backend in cases:
            self.brief.write_text(text)
            self.write_policy(**policy)
            os.environ["CC_ORCH_BACKEND"] = backend
            _, popen = self.run_jev("scan")
            popen.assert_not_called()
            self.assertEqual(self.requests, [])

    def test_launch_failure_changes_no_output(self):
        self.write_policy(JEV_LOCAL_ENABLED="0")
        baseline, _ = self.run_jev("scan")
        self.write_policy()
        result, popen = self.run_jev("scan", popen_error=OSError("unavailable"))
        popen.assert_called_once()
        self.assertEqual(result, baseline)

    def test_off_does_not_open_handoff_file(self):
        self.write_policy(JEV_LOCAL_ENABLED="0")
        with patch.object(jev.tempfile, "TemporaryFile") as temporary:
            _, popen = self.run_jev("scan")
        temporary.assert_not_called()
        popen.assert_not_called()


class ServeTests(Case):
    def setUp(self):
        super().setUp()
        self.model = self.base / "tiny.gguf"
        self.model.write_bytes(b"synthetic GGUF fixture")
        self.sha = hashlib.sha256(self.model.read_bytes()).hexdigest()
        self.binary = self.base / "fake-server"
        self.capture_path = self.base / "launch.json"
        self.binary.write_text(f"#!{sys.executable}\nimport json, os, sys\n"
                               "with open(os.environ['CAPTURE'], 'w') as stream:\n"
                               "    json.dump({'argv': sys.argv, 'env': dict(os.environ)}, stream)\n")
        self.binary.chmod(0o755)
        self.socket = self.base / "socket-dir" / "llama.sock"
        self.options = {"JEV_LOCAL_MODEL_PATH": str(self.model), "JEV_LOCAL_MODEL_DIGEST": self.sha,
                        "JEV_LOCAL_SERVER_BIN": str(self.binary), "JEV_LOCAL_SOCKET": str(self.socket),
                        "JEV_LOCAL_GPU": "2"}
        self.write_policy(**self.options)
        os.environ.update(CAPTURE=str(self.capture_path), TYPESAFE_API_KEY=SENTINEL,
                          LLAMA_ARG_HOST="0.0.0.0", LLAMA_ARG_MODEL="wrong", CUDA_DEVICE_ORDER="wrong")

    def test_exact_argv_gpu_clean_env_and_private_directory(self):
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 0, result.stderr)
        launch = json.loads(self.capture_path.read_text())
        self.assertEqual(launch["argv"], [str(self.binary), "-m", str(self.model), "--host", "llama.sock",
                         "--alias", local.alias(self.sha), "-c", "16384", "-np", "1", "-ngl", "999",
                         "--jinja", "--reasoning-budget", "0", "--cache-reuse", "256",
                         "--no-webui", "--no-slots", "--offline"])
        self.assertEqual(launch["env"]["CUDA_VISIBLE_DEVICES"], "2")
        self.assertEqual(launch["env"]["CUDA_DEVICE_ORDER"], "PCI_BUS_ID")
        self.assertNotIn("TYPESAFE_API_KEY", launch["env"])
        self.assertFalse(any(k.startswith("LLAMA_ARG_") for k in launch["env"]))
        self.assertEqual(stat.S_IMODE(self.socket.parent.stat().st_mode), 0o700)

    def test_missing_model_hints_and_mismatch(self):
        self.model.unlink()
        self.write_policy(**dict(self.options, JEV_LOCAL_MODEL_DIGEST=local.MODEL_SHA256))
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn("model not found:", result.stderr)
        self.assertIn(f"mkdir -p {self.model.parent} && curl -fL -o {self.model} {local.MODEL_URL}", result.stderr)
        self.write_policy(**self.options)
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Acquire the configured GGUF", result.stderr)
        self.assertNotIn("curl", result.stderr)
        self.model.write_bytes(b"wrong model")
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"model SHA-256 mismatch (expected {self.sha})", result.stderr)
        self.assertFalse(self.capture_path.exists())

    def test_invalid_gpu_and_sha(self):
        for key, value in (("JEV_LOCAL_GPU", "-1"), ("JEV_LOCAL_GPU", "0,1"),
                           ("JEV_LOCAL_MODEL_DIGEST", "bad"), ("JEV_LOCAL_MODEL_DIGEST", "A" * 64)):
            self.write_policy(**dict(self.options, **{key: value}))
            result = self.invoke("serve")
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr.strip(), f"JEV: local — config: {key} invalid")
            self.assertFalse(self.capture_path.exists())

    def test_refuse_non_socket_and_missing_binary(self):
        self.socket.parent.mkdir()
        self.socket.write_text("keep")
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing non-socket", result.stderr)
        self.assertEqual(self.socket.read_text(), "keep")
        self.socket.unlink()
        self.write_policy(**dict(self.options, JEV_LOCAL_SERVER_BIN="/no/such/llama-server"))
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama-server not found", result.stderr)

    @unittest.skipIf(UNIX_REASON, UNIX_REASON)
    def test_stale_and_live_socket(self):
        self.socket.parent.mkdir()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
            stale.bind(str(self.socket))
        result = self.invoke("serve")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.socket.exists())
        self.capture_path.unlink()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as live:
            live.bind(str(self.socket))
            live.listen(1)
            result = self.invoke("serve")
        self.assertEqual(result.returncode, 1)
        self.assertIn("already running", result.stderr)
        self.assertFalse(self.capture_path.exists())


class ReportTests(Case):
    def record(self, **overrides):
        row = dict.fromkeys(KEYS)
        row.update(timestamp="2026-01-01T00:00:00+00:00", id="1:1", status="ok", requests=2,
                   model="local", jev_model="jev-1.13.0", jev_outcome="ok", chunks=2,
                   local_p=[0.8, 0.2], jev_p=[0.9, 0.8], latency_ms=10)
        row.update(overrides)
        return row

    def test_exact_counts_and_current_threshold(self):
        self.state.mkdir()
        records = [self.record(), self.record(local_p=[0.7, 0.1], jev_p=[0.1, 0.2], latency_ms=30),
                   self.record(status="unavailable:server", local_p=None, latency_ms=None),
                   self.record(jev_outcome="network", jev_p=None, latency_ms=20)]
        malformed = [dict(records[0], extra="bad"), dict(records[0], requests=True),
                     dict(records[0], local_p=[0.2]), dict(records[0], jev_p=[float("nan"), 0.1]),
                     dict(records[0], local_p=[True, 0.1]), dict(records[0], timestamp=1)]
        self.log.write_text("\n".join(json.dumps(row) for row in records + malformed) + "\nnot json\n")
        result = self.invoke("report")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.splitlines(), [
            f"JEV local report — {self.log}", "records: 4  malformed: 7",
            "status: ok 3 · unavailable:server 1",
            "comparable (local ok and Jev ok): 2 records, 4 chunks — fewer than 10 comparable records",
            "chunks at JEV_SCAN_THRESHOLD=0.7: both flagged 1 · Jev only 1 · local only 1 · both clear 1 · agreement 50.0%",
            "records with any chunk flagged: both 1 · Jev only 0 · local only 1 · neither 0",
            "mean |local p - Jev p| per chunk: 0.350",
            "local latency ms (ok records): median 20 · p95 30",
            "counts only — this report draws no conclusion."])
        self.write_policy(JEV_SCAN_THRESHOLD=0.85)
        result = self.invoke("report", "--log", self.log)
        self.assertIn("chunks at JEV_SCAN_THRESHOLD=0.85: both flagged 0 · Jev only 1 · local only 0 · both clear 3 · agreement 75.0%", result.stdout)
        self.assertIn("records with any chunk flagged: both 0 · Jev only 1 · local only 0 · neither 1", result.stdout)

    def test_empty_and_missing_zero_counts(self):
        for exists in (False, True):
            if exists:
                self.state.mkdir()
                self.log.touch()
            result = self.invoke("report")
            self.assertEqual(result.returncode, 0)
            self.assertIn("records: 0  malformed: 0", result.stdout)
            self.assertIn("comparable (local ok and Jev ok): 0 records, 0 chunks", result.stdout)
            self.assertIn("agreement n/a", result.stdout)
            self.assertIn("mean |local p - Jev p| per chunk: n/a", result.stdout)
            self.assertIn("local latency ms (ok records): median n/a · p95 n/a", result.stdout)

    def test_report_failure_still_exits_zero(self):
        errors = io.StringIO()
        with patch.object(local, "report", side_effect=OSError("private-path")), \
             contextlib.redirect_stderr(errors):
            self.assertEqual(local.main(["report"]), 0)
        self.assertEqual(errors.getvalue(), "local-report: failed (OSError)\n")


class StubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(body)
        if self.server.provider == "jev":
            assert self.headers.get("Authorization") == "Bearer " + SENTINEL
            reply = {"model": body["model"], "answers": {c: {"type": "noul", "noul": 0.9}
                                                       for c in body["questions"]}}
        else:
            assert "Authorization" not in self.headers
            reply = response()
        raw = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


@unittest.skipIf(INET_REASON or UNIX_REASON, INET_REASON or UNIX_REASON)
class EndToEndTests(Case):
    def setUp(self):
        super().setUp()
        self.repo = self.base / "copy"
        (self.repo / "bin").mkdir(parents=True)
        for name in ("orch-jev", "orch-jev-local"):
            shutil.copy2(ROOT / "bin" / name, self.repo / "bin" / name)
        shutil.copy2(ROOT / "jev-policy.conf", self.repo / "jev-policy.conf")
        shutil.copytree(ROOT / "templates/jev", self.repo / "templates/jev")
        os.environ["CC_ORCH_JEV_TEMPLATES"] = str(self.repo / "templates/jev")
        os.environ["TYPESAFE_API_KEY"] = SENTINEL
        os.environ.pop("PYTHONDONTWRITEBYTECODE", None)
        os.environ.pop("PYTHONPYCACHEPREFIX", None)
        self.source = self.base / "input.txt"
        self.source.write_text("Synthetic test input.\n")
        self.socket = self.base / "llama.sock"
        self.jev_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
        self.llama_server = socketserver.UnixStreamServer(str(self.socket), StubHandler)
        for server, provider in ((self.jev_server, "jev"), (self.llama_server, "local")):
            server.provider, server.requests = provider, []
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(thread.join, 2)
            self.addCleanup(server.shutdown)
        self.options = {"JEV_ENDPOINT": f"http://127.0.0.1:{self.jev_server.server_port}/v1/systemone",
                        "JEV_LOCAL_SOCKET": str(self.socket)}

    def test_real_subprocess_off_on_identity_and_paired_probabilities(self):
        self.write_policy(**self.options, JEV_LOCAL_ENABLED="0")
        off = self.invoke("scan", self.source, tool=self.repo / "bin/orch-jev")
        self.assertEqual(off.returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertEqual(self.llama_server.requests, [])
        self.write_policy(**self.options)
        on = self.invoke("scan", self.source, tool=self.repo / "bin/orch-jev")
        self.assertEqual((off.stdout, off.stderr, off.returncode), (on.stdout, on.stderr, on.returncode))
        deadline = time.monotonic() + 10
        rows = []
        while time.monotonic() < deadline:
            if self.log.exists():
                rows = [json.loads(line) for line in self.log.read_text().splitlines()]
                if rows:
                    break
            time.sleep(0.02)
        self.assertTrue(self.log.exists())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "ok")
        self.assertEqual(rows[0]["local_p"], [0.8])
        self.assertEqual(rows[0]["jev_p"], [0.9])
        self.assertEqual(len(self.llama_server.requests), 1)
        self.assertEqual(list(self.repo.rglob("__pycache__")), [])

    def test_sleeping_companion_does_not_block_and_off_never_launches(self):
        marker = self.base / "worker-pid"
        fake = self.repo / "bin/orch-jev-local"
        fake.write_text("import os, time\nfrom pathlib import Path\n"
                        f"Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(5)\n")
        self.write_policy(**self.options, JEV_LOCAL_ENABLED="0")
        self.invoke("scan", self.source, tool=self.repo / "bin/orch-jev")
        time.sleep(0.15)
        self.assertFalse(marker.exists())
        self.write_policy(**self.options)
        started = time.monotonic()
        result = self.invoke("scan", self.source, tool=self.repo / "bin/orch-jev")
        elapsed = time.monotonic() - started
        try:
            deadline = time.monotonic() + 1
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            self.assertEqual(result.returncode, 0)
            self.assertLess(elapsed, 2)
        finally:
            if marker.exists():
                try:
                    os.kill(int(marker.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.assertEqual(list(self.repo.rglob("__pycache__")), [])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    reasons = sorted({reason for _, reason in result.skipped})
    print(f"JEV-LOCAL-TESTS: {len(result.skipped)} test(s) skipped — " + ("; ".join(reasons) or "none"))
    sys.exit(0 if result.wasSuccessful() else 1)
