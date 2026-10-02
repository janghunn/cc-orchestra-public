#!/usr/bin/env python3
"""Invented transcripts only; no TCP, DNS, real model or git write commands."""
import sys
sys.dont_write_bytecode = True

import ast
from contextlib import redirect_stdout, redirect_stderr
from copy import deepcopy
import hashlib
import io
import json
import math
import os
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time
from unittest.mock import patch

ROOT = Path(os.environ["TEST_ROOT"])
TMP = Path(os.environ["TEST_TMP"])
MODULES = ROOT / "eval/compaction-replay"
FIXTURES = MODULES / "fixtures/projects"
sys.path.insert(0, str(MODULES))
import identifiers
import local_scorer
import policies
import replay
import score
import transcripts
from transcripts import Event

ORIGINAL_SOCKET = socket.socket


def unix_only(family=socket.AF_INET, *args, **kwargs):
    assert family == socket.AF_UNIX, "network socket forbidden"
    return ORIGINAL_SOCKET(family, *args, **kwargs)


def cli(*args):
    stdout, stderr = io.StringIO(), io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        code = replay.main(["--projects", str(FIXTURES), "--bootstrap", "40", *map(str, args)])
    return code, stdout.getvalue(), stderr.getvalue()


def load(name):
    ref = next(r for r in transcripts.discover(FIXTURES) if r.path.name == name)
    return transcripts.load_events(ref, set())[0]


def event(kind, text="", key="", **kwargs):
    return Event(kind, text, msg_key=key, **kwargs)


def unpinned(text="result", **kwargs):
    return [event("result", text, "old", **kwargs)] + [
        event("assistant_text", "padding", f"pad-{i}") for i in range(6)]


def extraction():
    valid = "a0123456789abcdef"
    invalid = "a0123456789abcde a0123456789abcdef0 z-" + valid + "-z"
    assert identifiers.extract(valid + " " + invalid)["agentid"] == {valid}
    text = ("(/tmp/example.py), tests/example.sh; bin/codex-run-runtime src/lib/unit "
            "and/or w/o src/foo https://example.org/src/file.py "
            "http://example.org/src/else.py /one/two.")
    assert identifiers.extract(text)["path"] == {
        "/tmp/example.py", "tests/example.sh", "bin/codex-run-runtime", "src/lib/unit", "/one/two"}
    long_sha = "1a" * 20
    assert identifiers.extract("1a2b3c4 " + long_sha + " 1234567 abcdefa " + valid
                               + " 1a2b3c4-5678-1234-abcd-0123456789ab")["sha"] == {"1a2b3c4", long_sha}
    assert identifiers.error_lines("error: short") == {"error: short"}
    assert identifiers.error_lines("error: tiny") == set()
    assert identifiers.error_lines("fatal " + "x" * 294) == {"fatal " + "x" * 294}
    assert identifiers.error_lines("fatal " + "x" * 295) == set()
    assert identifiers.error_lines("  ERROR: synthetic failure  \nnot a problem") == {"ERROR: synthetic failure"}
    assert identifiers.occurs_error("ERROR: synthetic failure", "prefix ERROR: synthetic failure suffix")
    assert not identifiers.occurs_error("ERROR: synthetic failure", "error: synthetic failure")


def later_needed():
    paths = ["/work/" + name + ".py" for name in "XYZW"]
    events = [event("result", " ".join(paths), "r"), event("assistant_text", paths[1], "a"),
              event("result", paths[2], "r2"), event("tool_input", paths[0], "a2"),
              event("user_text", paths[2], "u")]
    result = replay.needed_tokens(events, 2)["path"]
    assert result == dict(needed={paths[0]}, rederivable={paths[1]}, resurfaced={paths[2]}, not_used={paths[3]})
    epochs = [event("result", "/work/old.py", "old"), event("boundary"),
              event("result", "/work/new.py", "new"), event("assistant_text", "/work/old.py /work/new.py", "use")]
    statuses = replay.needed_tokens(epochs, 3)
    assert statuses["path"]["needed"] == {"/work/new.py"}
    metric = replay.measure(epochs, 3, policies.decide("P0", epochs, 3), statuses, {})
    assert metric["bytes_total"] == 12 and metric["classes"]["path"]["retained"] == 1
    assert replay.needed_tokens(epochs, 1)["path"]["needed"] == {"/work/old.py"}
    # Six later result messages unpin the first result; a post-cut user message
    # must not trigger its adjacency rule.
    pre = [event("result", "x" * 2500, "r", name="Read")] + [
        event("result", "filler", f"r{i}") for i in range(6)]
    for arm in ("P1", "P2", "P3"):
        a = policies.decide(arm, pre + [event("user_text", "later", "u")], len(pre),
                            {"scorer": policies.fake_scorer})
        b = policies.decide(arm, pre + [event("assistant_text", "changed", "a")], len(pre),
                            {"scorer": policies.fake_scorer})
        assert a == b
    assert policies.decide("P2", pre + [event("user_text", "later", "u")], len(pre))[0] == "drop"
    # Every ordered heuristic has a positive case, including byte vs character units.
    for kwargs, text in (({"name": "SendMessage"}, "x" * 2500),
                         ({"input_text": "read REGISTRY"}, "x" * 2500),
                         ({}, "x" * 2500 + " a0123456789abcdef"),
                         ({"is_error": True}, "x" * 2500),
                         ({}, "x" * 2500 + "\nerror: synthetic failure"),
                         ({}, "x" * 2048),
                         ({}, "x" * 2050 + " " + " ".join(f"/work/a{i}.py" for i in range(12)))):
        seq = unpinned(text, **kwargs)
        assert policies.decide("P2", seq, len(seq))[0] == "keep"
    seq = unpinned("x" * 2500, name="Read")
    seq.insert(1, event("user_text", "reply", "u"))
    assert policies.decide("P2", seq, len(seq))[0] == "keep"
    seq = unpinned("é" * 1500, name="Bash")
    assert policies.decide("P2", seq, len(seq))[0] == "truncate"
    assert len(policies.retained_text(seq[0].text, "truncate").encode()) == 600


def hand_computed():
    events = load("basic.jsonl")
    cut = next(c for c, _ in replay.cuts(events) if sum(e.kind == "result" for e in events[:c]) == 12)
    needed = replay.needed_tokens(events, cut)
    # First three results: 66, 2223, 2224 UTF-8 bytes, then 9 * 6 filler bytes.
    # P1 drops 66+2223=2289. P2 drops 2223 and truncates 2224 to 300:
    # 2223+1924=4147. Only the Agent result survives P2 with full identifiers.
    expected = {"P0": ([1, 3, 3, 1], 0), "P1": ([0, 1, 1, 0], 2289), "P2": ([1, 1, 1, 1], 4147)}
    for arm, (retained, removed) in expected.items():
        metric = replay.measure(events, cut, policies.decide(arm, events, cut), needed, {})
        assert [metric["classes"][c]["needed"] for c in identifiers.CLASSES] == [1, 3, 3, 1]
        assert [metric["classes"][c]["retained"] for c in identifiers.CLASSES] == retained
        assert metric["bytes_total"] == 4567 and metric["bytes_removed"] == removed
    measured, bucket = replay.evaluate_file(events, "main")
    assert bucket == "8-49"
    # Three cuts after results 4,8,12: 4519+4543+4567=13629 bytes.
    # P2 prunes at cuts 8 and 12 only; P1 prunes at cut 12 only.
    for arm, retained, removed in (("P0", [3, 9, 9, 3], 0), ("P1", [2, 7, 7, 2], 2289),
                                   ("P2", [3, 5, 5, 3], 8294)):
        m = measured[arm]["pooled"]
        assert m["bytes_total"] == 13629 and m["bytes_removed"] == removed
        assert [m["classes"][c]["retained"] for c in identifiers.CLASSES] == retained


def sufficient():
    aggregate = {"p3": {"status": "off"}, "policies": {}}
    for arm in ("P0", "P1", "P2"):
        policy = replay.empty_policy()
        for _, cell in score.cells(policy):
            cell.update(files=40, cuts=120, bytes_total=10000, bytes_removed=4000)
            for cls in identifiers.CLASSES:
                cell["classes"][cls].update(needed=200, retained=200)
            replay.finish_metric(cell)
        aggregate["policies"][arm] = policy
    return aggregate


def hard_rule():
    actual, _ = replay.evaluate_file(load("basic.jsonl"), "main")
    assert actual["P1"]["pooled"]["lost_agentids"] == 1
    aggregate = sufficient()
    aggregate["policies"]["P1"]["pooled"]["lost_agentids"] = 1
    result = score.verdict(aggregate)
    assert result["arms"]["P1"]["verdict"] == "do not pursue"
    assert result["arms"]["P1"]["reasons"] == ["agentId lost"]
    assert result["arms"]["P2"]["verdict"] == "proceed to design discussion"
    aggregate["policies"]["P1"]["pooled"]["classes"]["agentid"]["needed"] = 1
    assert score.verdict(aggregate)["arms"]["P1"]["reasons"] == ["agentId lost"]


def verdicts():
    aggregate = sufficient()
    assert score.verdict(aggregate)["overall"] == "proceed to design discussion"
    assert "P0" not in score.verdict(aggregate)["arms"]
    for policy in aggregate["policies"].values():
        policy["pooled"]["files"] = 29
    assert score.verdict(aggregate)["overall"] == "inconclusive"
    aggregate = sufficient()
    for policy in aggregate["policies"].values():
        policy["file_kind"]["subagent"]["classes"]["path"]["retained"] = 189
    assert score.verdict(aggregate)["overall"] == "do not pursue"
    for status in ("off", "skipped", "fake", "errors"):
        aggregate["p3"] = {"status": status}
        aggregate["policies"]["P3"] = sufficient()["policies"]["P2"]
        assert "P3" not in score.verdict(aggregate)["arms"]
        assert score.verdict(aggregate)["overall"] == "do not pursue"
    aggregate["p3"] = {"status": "ran"}
    assert score.verdict(aggregate)["overall"] == "proceed to design discussion"
    aggregate["policies"]["P3"]["pooled"]["p3_errors"] = 1
    assert "P3" not in score.verdict(aggregate)["arms"]
    assert score.verdict(aggregate)["overall"] == "do not pursue"
    # Threshold failures with sufficient cells precede unrelated insufficient cells.
    aggregate = sufficient()
    aggregate["policies"]["P1"]["pooled"]["classes"]["sha"]["needed"] = 1
    aggregate["policies"]["P1"]["file_kind"]["main"]["classes"]["error"]["retained"] = 179
    assert score.verdict(aggregate)["arms"]["P1"]["verdict"] == "do not pursue"
    assert replay.quantile([0, 10], .025) == .25


def without_ci(obj):
    if isinstance(obj, dict):
        return {k: without_ci(v) for k, v in obj.items() if k != "bootstrap"}
    if isinstance(obj, list):
        return [without_ci(v) for v in obj]
    return obj


def determinism():
    for name, seed in (("a", 20261002), ("b", 20261002), ("c", 99)):
        code, stdout, stderr = cli("--out", TMP / name, "--seed", seed)
        assert code == 0, (stdout, stderr)
    a, b, c = [(TMP / name / "aggregate.json").read_bytes() for name in "abc"]
    assert a == b
    assert without_ci(json.loads(a)) == without_ci(json.loads(c))
    assert "20261002" not in a.decode()  # Seed belongs in metadata, not count fields.


def normalization():
    refs = transcripts.discover(FIXTURES)
    assert len(refs) == 7 and sum(r.kind == "subagent" for r in refs) == 1
    ref = next(r for r in refs if r.path.name == "split_and_dup.jsonl")
    events, stats = transcripts.load_events(ref, set())
    assert stats["dup_records_in_file"] == 2 and stats["dup_conflicts"] == 1
    assert stats["excluded_records"] == 3 and stats["nontext_result_blocks"] == 1
    assert [e.kind for e in events] == ["tool_input", "result", "assistant_text", "tool_input", "result"]
    assert events[0].msg_key == events[2].msg_key
    assert events[1].text == "FIXTURE-SECRET-TEXT" and len(events[1].text.encode()) == 19
    seen = set()
    main = next(r for r in refs if r.path.name == "copy_main.jsonl")
    full = next(r for r in refs if r.path.name == "copy_resumed.jsonl")
    partial = next(r for r in refs if r.path.name == "copy_partial.jsonl")
    assert len(transcripts.load_events(main, seen)[0]) == 16
    events, stats = transcripts.load_events(full, seen)
    assert events == [] and stats["files_skipped_copy"] == 1
    events, stats = transcripts.load_events(partial, seen)
    assert len(events) == 16 and stats["copied_records"] == 2
    assert replay.evaluate_file(events, "main")[0]["P0"]["pooled"]["cuts"] == 3
    compact = load("compaction.jsonl")
    assert replay.cuts(compact) == [(2, "real")]
    assert all("summary excluded" not in e.text for e in compact)
    # Frozen byte limit, ignored partial line, symlink files and directories.
    tree = TMP / "snapshot"
    (tree / "p").mkdir(parents=True)
    path = tree / "p/a.jsonl"
    path.write_text('{"uuid":"s","type":"user","message":{"content":"snapshot"}}\n{"partial":')
    snapshot = transcripts.discover(tree)[0]
    with path.open("a") as stream:
        stream.write('true}\n{"type":"user","message":{"content":"appended"}}\n')
    assert [e.text for e in transcripts.load_events(snapshot, set())[0]] == ["snapshot"]
    (tree / "p/link.jsonl").symlink_to(path)
    (tree / "linked").symlink_to(tree / "p", target_is_directory=True)
    assert len(transcripts.discover(tree)) == 1
    assert list(transcripts.string_leaves({"z": ["last", 1], "a": {"b": "first"}})) == ["first", "last"]


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def worktree_fixture():
    # Equivalent linked-worktree metadata, without git init/add/commit/worktree add:
    # implementation lanes are forbidden from running any git write command.
    repo, sibling = TMP / "temp-repo", TMP / "temp-sibling"
    git = repo / ".git"
    (git / "objects").mkdir(parents=True)
    (git / "refs/heads").mkdir(parents=True)
    write(git / "HEAD", "ref: refs/heads/main\n")
    write(git / "config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n")
    admin = git / "worktrees/sibling"
    write(admin / "HEAD", "ref: refs/heads/sibling\n")
    write(admin / "commondir", "../..\n")
    write(admin / "gitdir", str(sibling / ".git") + "\n")
    write(sibling / ".git", "gitdir: " + str(admin) + "\n")
    # Verify Git itself recognizes the metadata with read-only commands.
    assert repo.resolve() in replay.common.git_worktree_roots(sibling)
    assert sibling.resolve() in replay.common.git_worktree_roots(repo)
    return repo, sibling


def containment():
    repo, sibling = worktree_fixture()
    link = TMP / "repo-link"
    link.symlink_to(ROOT, target_is_directory=True)
    for target in (ROOT / "replay-should-not-exist", sibling / "new", repo / "new", link / "new"):
        code, stdout, stderr = cli("--out", target)
        assert code == 2 and "refusing output path:" in stderr
        assert not stdout and not target.exists()
    # An existing output-file symlink cannot evade the guard.
    out = TMP / "symlink-file"
    out.mkdir()
    (out / "aggregate.json").symlink_to(ROOT / "replay-should-not-exist.json")
    assert cli("--out", out)[0] == 2
    assert not (out / "per-file.jsonl").exists()
    output, note = TMP / "private-output", TMP / "note.md"
    code, stdout, stderr = cli("--out", output, "--note", note, "--criteria-commit", "a" * 40)
    assert code == 0, stderr
    for value in [stdout, stderr, note.read_text()] + [(output / n).read_text() for n in
                   ("aggregate.json", "per-file.jsonl", "run-meta.json")]:
        assert "FIXTURE-SECRET-TEXT" not in value
        assert "a0123456789abcdef" not in value and "/work/alpha.py" not in value
    for prefix in ("Run command: ", "Criteria commit: " + "a" * 40, "P3 status: ",
                   "Runtime seconds: ", "Peak RSS MiB: ", "Source hash check: ",
                   "## Verdict", "Overall verdict: "):
        assert any(line.startswith(prefix) for line in note.read_text().splitlines())


def fake_p3():
    requests = list(local_scorer.LocalScorer.requests("Read", "i" * 10000, "r" * 50000))
    assert all(len(request["messages"][0]["content"]) < 8500 for request in requests)
    assert local_scorer.PROMPT_INPUT_CHARS == 1500 and local_scorer.PROMPT_RESULT_CHARS == 4000
    controls = "".join(chr(code) for code in (*range(32), 127) if code not in (9, 10))
    for result_text in ((controls * 300)[:8000], "\n\t" * 4000):
        requests = list(local_scorer.LocalScorer.requests("Read", "\n\t" * 5000, result_text))
        assert len(requests) == 2
        for request in requests:
            content = request["messages"][0]["content"]
            assert len(content) < 12000
            context = json.loads(content.split("\n")[1])
            assert context["input"] == "\n\t" * 750
            assert context["result"] == (" " * 4000 if result_text[0] == "\x00" else "\n\t" * 2000)
    for answer, expected in (((False, True), "keep"), ((True, False), "truncate"), ((False, False), "drop")):
        seq = unpinned()
        assert policies.decide("P3", seq, len(seq), {"scorer": lambda *a: answer}) == [expected]
    calls = []
    secret = 'password="s3cr3tvaluewithmorethan20chars"'
    for where in ("text", "input_text", "name"):
        seq = unpinned(**{where: secret})
        ctx = {"scorer": lambda *a: calls.append(a)}
        assert policies.decide("P3", seq, len(seq), ctx) == ["keep"]
        assert ctx["p3_secret_skips"] == 1 and calls == []
    # Secrets beyond both caps still prevent the scorer from seeing any text.
    for where in ("text", "input_text"):
        seq = unpinned(**{where: "padding\n" * 2000 + secret})
        ctx = {"scorer": lambda *a: calls.append(a)}
        assert policies.decide("P3", seq, len(seq), ctx) == ["keep"]
        assert ctx["p3_secret_skips"] == 1 and calls == []
    def broken(*args):
        raise RuntimeError("must not appear in artifacts")
    seq, ctx = unpinned(), {"scorer": broken}
    assert policies.decide("P3", seq, len(seq), ctx) == ["keep"] and ctx["p3_errors"] == 1
    for text in ("alpha", "beta", "gamma"):
        assert policies.fake_scorer("Bash", "input", text) == (
            hashlib.sha256(b"input").hexdigest()[0] in "01234567",
            hashlib.sha256(text.encode()).hexdigest()[0] in "0123")
    out = TMP / "fake"
    code, stdout, stderr = cli("--out", out, "--p3", "fake")
    assert code == 0 and "DEMONSTRATION" in stdout, stderr
    data = json.loads((out / "aggregate.json").read_text())
    assert "P3" in data["policies"] and "P3" not in data["verdict"]["arms"]
    # The cache stores only booleans under a digest of the actual screened prompt.
    class FakeLocal:
        requests = staticmethod(local_scorer.LocalScorer.requests)
        def __call__(self, *args):
            calls.append(args)
            return True, False
    cached = replay.CachedScorer(FakeLocal(), TMP / "cache", local_scorer.MODEL_DIGEST)
    assert cached("Read", "input", "output") == (True, False)
    assert cached("Read", "input", "output") == (True, False)
    assert len(calls) == 1
    cached("Read", "input changed", "output")
    assert len(calls) == 2
    assert all(json.loads(p.read_text()) == [True, False] for p in (TMP / "cache").glob("*.json"))
    # Exercise the local replay path without a model, socket or GPU. Every
    # unpinned result errors: basic contributes 1+5+9; each of main-copy,
    # partial-copy and subagent contributes 0+1+3, totaling 27 decisions.
    out, note = TMP / "p3-errors", TMP / "p3-errors.md"
    with patch.object(local_scorer, "preflight", return_value=None), \
         patch.object(local_scorer, "LocalServer") as server, \
         patch.object(local_scorer.LocalScorer, "__call__", side_effect=broken):
        server.return_value.__enter__.return_value.socket_path = TMP / "unused.sock"
        code, stdout, stderr = cli("--out", out, "--note", note, "--p3", "local")
    assert code == 0, (stdout, stderr)
    data = json.loads((out / "aggregate.json").read_text())
    assert data["p3"] == {"status": "errors", "errors": 27}
    assert data["policies"]["P3"]["pooled"]["p3_errors"] == 27
    assert data["policies"]["P3"]["pooled"]["bytes_removed"] == 0
    assert "P3" not in data["verdict"]["arms"]
    assert "P3 status: errors (27 scorer errors; not a verdict arm)" in note.read_text().splitlines()
    assert "| P3 | pooled |" in note.read_text()
    assert "must not appear in artifacts" not in (note.read_text() + stdout + stderr
                                                  + (out / "aggregate.json").read_text())


def executable(path, text):
    write(path, "#!" + sys.executable + "\n" + text)
    path.chmod(0o755)
    return path


def preflight():
    model = TMP / "synthetic.gguf"
    model.write_bytes(b"synthetic weights, never a real model")
    bindir = TMP / "preflight-bin"
    server = executable(bindir / "llama-server", "pass\n")
    nvidia = bindir / "nvidia-smi"
    def check(name, reason, **kwargs):
        out = TMP / ("preflight-" + name)
        code, stdout, stderr = cli("--out", out, "--p3", "local", "--p3-model", kwargs.get("model", model),
                                   "--p3-server", kwargs.get("server", server))
        assert code == 0 and stdout.splitlines()[0] == "P3 skipped: " + reason, (stdout, stderr)
        data = json.loads((out / "aggregate.json").read_text())
        assert set(data["policies"]) == {"P0", "P1", "P2"}
        assert data["p3"] == {"status": "skipped", "reason": reason}
    check("missing-model", "model file missing", model=TMP / "absent.gguf")
    check("digest", "model sha256 mismatch")
    # Patch only the pinned digest to exercise all remaining preflight branches
    # with a tiny synthetic file, without reading or acquiring model weights.
    with patch.object(local_scorer, "MODEL_DIGEST", hashlib.sha256(model.read_bytes()).hexdigest()), \
         patch.dict(os.environ, {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}):
        check("server", "server binary not found", server="missing-server")
        executable(nvidia, "raise SystemExit(1)\n")
        check("gpu-failed", "nvidia-smi failed")
        executable(nvidia, "print('0, 12287')\n")
        check("gpu-low", "no GPU with >= 12288 MiB free")
        executable(nvidia, "print('0, 1000\\n1, 12288')\n")
        assert local_scorer.preflight(model, str(server)) is None
        assert local_scorer.select_gpu() == ("1", None)
    health_readiness()


def health_readiness():
    """Readiness retry/cleanup must run even where AF_UNIX bind is denied."""
    fake = executable(TMP / "health-probe-server", "import time\ntime.sleep(30)\n")
    with patch.object(local_scorer, "select_gpu", return_value=("0", None)):
        for name, first in (("loading", 503), ("unreachable", OSError("synthetic connection failure"))):
            server = local_scorer.LocalServer(TMP / "synthetic.gguf", str(fake),
                                              TMP / ("health-" + name), startup_timeout=1)
            with patch.object(local_scorer, "get_unix", side_effect=[first, 200]) as probe, \
                 patch.object(local_scorer.time, "sleep", wraps=time.sleep) as pause:
                with server:
                    assert probe.call_count == 2 and server.process.poll() is None
                    pause.assert_called_once_with(0.05)
                    assert all(0 < call.kwargs["timeout"] <= 1 for call in probe.call_args_list)
            assert server.process.poll() is not None and not server.directory.exists()
        server = local_scorer.LocalServer(TMP / "synthetic.gguf", str(fake),
                                          TMP / "health-timeout", startup_timeout=.12)
        with patch.object(local_scorer, "get_unix", return_value=503) as probe:
            try:
                with server:
                    raise AssertionError("HTTP 503 was accepted as ready")
            except local_scorer.LocalError as error:
                assert str(error) == "local server startup timed out"
            assert probe.call_count >= 2
        assert server.process.poll() is not None and not server.directory.exists()
        try:
            os.kill(server.process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("server survived HTTP readiness timeout")


def unix_client_and_lifecycle():
    path = TMP / "http.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(path))
    except OSError as error:
        listener.close()
        print(f"SKIP: AF_UNIX bind denied ({error.errno}) — delegated to verifier-normal")
        return False
    listener.listen(2)
    failures, requests = [], []
    def serve():
        try:
            for probability in (.8, .2):
                conn, _ = listener.accept()
                with conn:
                    stream = conn.makefile("rb")
                    assert stream.readline().startswith(b"POST /v1/chat/completions ")
                    length = 0
                    while True:
                        line = stream.readline()
                        if line == b"\r\n":
                            break
                        if line.lower().startswith(b"content-length:"):
                            length = int(line.split(b":")[1])
                    requests.append(json.loads(stream.read(length)))
                    data = json.dumps({"model": local_scorer.MODEL_ALIAS, "choices": [{"logprobs": {
                        "content": [{"top_logprobs": [{"token": " A", "logprob": math.log(probability)},
                                                        {"token": "B", "logprob": math.log(1-probability)}]}]}}]}).encode()
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(data)).encode()
                                 + b"\r\nConnection: close\r\n\r\n" + data)
                    stream.close()
        except BaseException as error:
            failures.append(error)
        finally:
            listener.close()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    assert local_scorer.LocalScorer(path, timeout=3)("Read", "synthetic input", "synthetic output") == (True, False)
    thread.join(5)
    assert not thread.is_alive() and not failures
    assert len(requests) == 2
    assert all(r["max_tokens"] == 1 and r["top_logprobs"] == 20 and r["temperature"] == 0
               and r["chat_template_kwargs"] == {"enable_thinking": False} for r in requests)
    path.unlink()
    fake = executable(TMP / "binding-server", '''import os, socket, sys, time
assert "--offline" in sys.argv and "--no-webui" in sys.argv and "--no-slots" in sys.argv
assert os.environ["CUDA_VISIBLE_DEVICES"] == "2"
assert not any(k.startswith("LLAMA_ARG_") or k == "TYPESAFE_API_KEY" for k in os.environ)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[sys.argv.index("--host") + 1])
sock.listen(4)
while True:
    conn, _ = sock.accept()
    with conn:
        stream = conn.makefile("rb")
        assert stream.readline().startswith(b"GET /health ")
        while stream.readline() != b"\\r\\n":
            pass
        conn.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n")
        stream.close()
''')
    with patch.object(local_scorer, "select_gpu", return_value=("2", None)), \
         patch.dict(os.environ, {"LLAMA_ARG_HOST": "forbidden", "TYPESAFE_API_KEY": "synthetic"}):
        server = local_scorer.LocalServer(TMP / "synthetic.gguf", str(fake), TMP / "local-server", startup_timeout=3)
        with server:
            assert server.process.poll() is None
            pid = server.process.pid
            assert server.directory.stat().st_mode & 0o777 == 0o700
        assert server.process.poll() is not None and not server.directory.exists()
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("server survived exit")
        never = executable(TMP / "never-binding-server", "import time\ntime.sleep(30)\n")
        server = local_scorer.LocalServer(TMP / "synthetic.gguf", str(never), TMP / "timeout-server", startup_timeout=.15)
        try:
            with server:
                raise AssertionError("unready server accepted")
        except local_scorer.LocalError as error:
            assert str(error) == "local server startup timed out"
        assert server.process.poll() is not None and not server.directory.exists()
        try:
            os.kill(server.process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("server survived startup timeout")
        # BaseException during startup must also reap the child.
        interrupted = local_scorer.LocalServer(TMP / "synthetic.gguf", str(never), TMP / "interrupt-server")
        with patch.object(local_scorer, "connect_unix", side_effect=KeyboardInterrupt):
            try:
                interrupted.__enter__()
            except KeyboardInterrupt:
                pass
        assert interrupted.process.poll() is not None and not interrupted.directory.exists()
    return True


def static_egress():
    forbidden = {"urllib", "requests", "ssl", "ftplib", "smtplib", "http.server"}
    for path in sorted(MODULES.glob("*.py")):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or ""]
            for name in names:
                assert not any(name == x or name.startswith(x + ".") for x in forbidden)
                if name in ("socket", "http.client"):
                    assert path.name == "local_scorer.py"
            if isinstance(node, ast.Call) and ast.unparse(node.func) == "socket.socket":
                assert path.name == "local_scorer.py"
                assert node.args and ast.unparse(node.args[0]) == "socket.AF_UNIX"
    for action in (lambda: socket.socket(), lambda: socket.create_connection(("localhost", 80)),
                   lambda: socket.getaddrinfo("localhost", 80)):
        try:
            action()
        except AssertionError:
            pass
        else:
            raise AssertionError("network guard failed")


def source_read_only():
    copy = TMP / "old-fixtures"
    shutil.copytree(FIXTURES, copy)
    paths = sorted(copy.rglob("*.jsonl"))
    for path in paths:
        os.utime(path, (1, 1))
    before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    out = TMP / "readonly"
    assert cli("--projects", copy, "--out", out)[0] == 0
    after = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    assert before == after
    meta = json.loads((out / "run-meta.json").read_text())
    assert meta["source_hash_check"] == {"sampled": 7, "unchanged": 7}
    assert all(v["before"] == v["after"] for v in meta["source_hashes"].values())
    # Guard read-only sources even when output or note flags overlap the corpus.
    assert cli("--projects", copy, "--out", copy / "output")[0] == 2
    assert not (copy / "output").exists()
    assert cli("--projects", copy, "--out", TMP / "overlap", "--note", copy / "note.md")[0] == 2
    assert not (copy / "note.md").exists()
    assert not list(MODULES.rglob("__pycache__"))


def main():
    groups = [("identifier extraction", extraction), ("later-needed, epochs and pre-cut policies", later_needed),
              ("hand-computed P0/P1/P2", hand_computed), ("agentId hard rule", hard_rule),
              ("frozen verdict mechanics", verdicts), ("deterministic aggregates", determinism),
              ("dedup, normalization and snapshot discovery", normalization),
              ("output containment and aggregate privacy", containment),
              ("P3 fake scorer, screening and cache", fake_p3), ("P3 preflight skips and health readiness", preflight),
              ("AF_UNIX client and server lifecycle", unix_client_and_lifecycle),
              ("real local model", None), ("static egress and network guard", static_egress),
              ("read-only sources", source_read_only)]
    passed, skipped = 0, []
    with patch.object(socket, "socket", side_effect=unix_only), \
         patch.object(socket, "create_connection", side_effect=AssertionError("network forbidden")), \
         patch.object(socket, "getaddrinfo", side_effect=AssertionError("DNS forbidden")):
        for i, (name, function) in enumerate(groups, 1):
            if function is None:
                print("SKIP: real local model path not exercised by this suite (requires GPU + pinned GGUF + llama-server)")
                skipped.append("12 real local model")
            elif function() is False:
                skipped.append(f"{i} AF_UNIX bind denied")
            else:
                passed += 1
                print(f"ok {i} - {name}")
    print(f"PASS: {passed} compaction-replay test groups; SKIPPED: {', '.join(skipped) or 'none'}")


if __name__ == "__main__":
    main()
