#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0 # Fake providers: no network or package mutation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $((++pass)) - $*"; }
field() { sed -n "s/^$2: //p" "$1" | head -1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { printf '%s' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }
assert_not_has() { ! printf '%s' "$1" | grep -qF -- "$2" || fail "unexpected '$2' ($3)"; }
run() {
  RUN_STATUS=0
  RUN_OUTPUT="$("$@" 2>&1)" || RUN_STATUS=$?
}

export PYTHONPYCACHEPREFIX="$TMP/pycache"
export CC_ORCH_STATE_DIR="$TMP/state"
export PYTHONPATH="$ROOT/eval/jev-phase0"
export TEST_ROOT="$ROOT" TEST_TMP="$TMP"
bash -n "${BASH_SOURCE[0]}"
python3 -m py_compile "$ROOT"/eval/jev-phase0/*.py
ok 'shell syntax and Python compilation'

cat > "$TMP/check.py" <<'PY'
import dataclasses
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
import uuid

import adapter
import baseline
import build_dataset as builder
import common
import labels
import run_eval
import score
import secrets

ROOT = Path(os.environ["TEST_ROOT"])
TMP = Path(os.environ["TEST_TMP"])
MODULES = ROOT / "eval/jev-phase0"


def cli(module, *args):
    return subprocess.run([sys.executable, str(MODULES / module), *map(str, args)],
                          capture_output=True, text=True, timeout=90)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def task(root, name, brief="## Acceptance\n1. Be useful.\nRISK: normal\n", summary=None, plan=None):
    directory = root / name
    write(directory / "brief.md", brief)
    if summary is not None:
        write(directory / "summary.md", summary)
    if plan is not None:
        write(directory / "plan.md", plan)
    return directory


def response(record, value, mode="mock"):
    return {"id": record["id"], "task": "lint", "mode": mode, "status": "ok",
            "score": value, "input_sha256": common.sha256_text(record["brief_text"])}


def fixture(positive=10, clean=10):
    records, final, responses = [], [], []
    for i in range(positive + clean):
        is_positive = i < positive
        record = {"id": f"f/{i}", "brief_text": f"Synthetic evaluation brief {i}",
                  "verdict": "amended" if is_positive else "clean",
                  "acceptance_items": ["Check `fixture.txt`."],
                  "declared_risk": "normal", "risk_events": [], "reasons": []}
        if is_positive:
            reason = {"reason_id": f"f/{i}#r01", "text": "An unclear criterion.",
                      "source_path": str(TMP / "fixture-summary.md"), "source_line": 2}
            record["reasons"] = [reason]
            final.append({"reason_id": reason["reason_id"], "category": "criterion-unverifiable",
                          "reason_sha256": common.sha256_text(reason["text"])})
        records.append(record)
        responses.append(response(record, 0.8 if is_positive else 0.1))
    return records, final, responses


def guard_tests():
    name = "refusal-" + uuid.uuid4().hex
    destinations = [ROOT / name, ROOT / "eval/jev-phase0" / name]
    alias = TMP / "checkout-link"
    alias.symlink_to(ROOT, target_is_directory=True)
    destinations.append(alias / name)
    for destination in destinations:
        commands = [("build_dataset.py", "--out", destination),
                    ("labels.py", "--emit-worklist", "--out", destination),
                    ("labels.py", "--ingest", "--out", destination),
                    ("run_eval.py", "--out", destination),
                    ("run_eval.py", "--cache", destination),
                    ("score.py", "--out", destination)]
        for command in commands:
            result = cli(*command)
            assert result.returncode == 2, (command[0], result.returncode)
            assert "refusing to write inside the git work tree:" in result.stderr
            assert not destination.exists()
    roots = common.git_worktree_roots(ROOT)
    assert ROOT.resolve() in roots
    for root in roots:
        destination = root / name
        try:
            common.assert_out_of_tree(destination)
        except common.OutOfTreeError:
            pass
        else:
            raise AssertionError("sibling worktree was accepted")
        assert not destination.exists()
    main_repo = TMP / "worktree-main"
    linked = TMP / "registered linked worktree"
    for args in (("init", str(main_repo)),
                 ("-C", str(main_repo), "commit", "--allow-empty", "-m", "fixture"),
                 ("-C", str(main_repo), "worktree", "add", "--detach", str(linked), "HEAD")):
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args],
                       check=True, capture_output=True, timeout=30)
    assert linked.resolve() in common.git_worktree_roots(main_repo), \
        "registered linked worktree missing from Git discovery"
    destination = linked / "out.jsonl"
    try:
        common.assert_out_of_tree(destination)
    except common.OutOfTreeError:
        pass
    else:
        raise AssertionError("registered linked worktree output was accepted")
    assert not destination.exists()
    with patch.dict(os.environ, {"CC_ORCH_STATE_DIR": ""}):
        assert common.state_dir() == Path.home() / ".claude/orchestra-state"


def discovery_tests():
    root = TMP / "roots"
    first = task(root, "direct")
    task(first, "subunit")
    hidden = root / "wt/lead/.orchestra"
    task(hidden, "duplicate")
    target = task(hidden, "linked")
    (root / "linked-task").symlink_to(target, target_is_directory=True)
    records, stats = builder.build_dataset([root])
    assert {r["task"] for r in records} == {"direct", "linked-task"}
    assert stats["excluded_wt"] == 2 and stats["excluded_subunit"] == 1
    assert stats["total"] == 2 and stats["realpath_collisions"] == 0
    (root / "linked-again").symlink_to(target, target_is_directory=True)
    records, stats = builder.build_dataset([root, root])
    assert len(records) == 2 and stats["realpath_collisions"] == 4


def parser_tests():
    root = TMP / "parsing"
    plan = ("# Amendments\n1. A criterion lacks a check.\n"
            "## Amendment B (mid-task, from orchestrator)\n- A new instruction.\n"
            "### Amendment follow-up\n- More new instructions.\n"
            "# Changes\n- Ordinary implementation work.\n")
    summary = "BRIEF AUDIT: amended (first reason\n  continues here\n  and ends here)\nRESULT: done\n"
    directory = task(root, "wrapped", summary=summary, plan=plan)
    task(root, "no-summary", plan="# Amendments\n- This cannot manufacture a verdict.")
    task(root, "no-audit", summary="RESULT: done\n", plan=plan)
    records, stats = builder.build_dataset([root])
    record = next(r for r in records if r["task"] == "wrapped")
    assert record["verdict"] == "amended" and record["verdict_line_no"] == 1
    assert record["verdict_reason"] == "(first reason continues here and ends here)"
    assert "A new instruction." not in record["plan_amendment_text"]
    assert not any("A new instruction." in r["text"] for r in record["reasons"])
    assert any("More new instructions." in r["text"] for r in record["reasons"])
    assert [kind for kind, _ in builder.amendment_sections(plan)] == ["audit", "process", "audit"]
    assert stats["per_verdict"]["unknown"] == 2
    for i, reason in enumerate(record["reasons"], 1):
        assert reason["reason_id"] == f"parsing/wrapped#r{i:02d}"
        assert Path(reason["source_path"]).is_file() and reason["source_line"] > 0
    assert builder.audit_verdict("brief audit: CLEAN\n\nBRIEF AUDIT: amended")[0] == "clean"
    assert builder.audit_verdict("BRIEF AUDIT: amended one\n\nnot part of the reason")[2] == "one"
    fenced = "````python\nRISK: critical\n```\nRISK: low\n````\n- RISK: **normal**\n"
    assert builder.declared_risk(fenced) == "normal"
    assert common.strip_fences("~~~\nRISK: low\n~~~ tail\nRISK: low\n~~~\nRISK: normal").endswith("RISK: normal")
    assert common.strip_fences("RISK: low\0") == ""
    assert builder.acceptance_items("# Acceptance\n1. Do this\n   continuation\n2) Check 7\n# Next\n") == ["Do this continuation", "Check 7"]
    assert builder.acceptance_items("##Acceptance\n- Check 3\n## Next\n") == ["Check 3"]
    assert builder.acceptance_items("# Other\n- no criteria") == []
    # Independent labels retain disagreements and exact source locations.
    reasons = [{"reason_id": f"r{i}", "text": "quoted evidence", "source_path": str(directory / "summary.md"),
                "source_line": i + 1} for i in range(3)]
    a = [{"reason_id": f"r{i}", "category": category, "evidence_span": "quoted",
          "reason_sha256": common.sha256_text(reasons[i]["text"])}
         for i, category in enumerate(("other", "other", "process"))]
    b = [{"reason_id": f"r{i}", "category": category, "evidence_span": "evidence",
          "reason_sha256": common.sha256_text(reasons[i]["text"])}
         for i, category in enumerate(("other", "process", "process"))]
    final = labels.reconcile(reasons, a, b)
    assert [r["category"] for r in final] == ["other", "ambiguous", "process"]
    note = labels.agreement_note(final)
    assert "Raw agreement rate: 0.666667" in note and "Cohen's kappa: 0.400000" in note
    assert "quoted evidence" not in note and str(directory) not in note
    records_path = TMP / "label-dataset.jsonl"
    common.write_jsonl(records_path, [{"verdict": "amended", "reasons": reasons}])
    common.write_jsonl(TMP / "a.jsonl", a)
    common.write_jsonl(TMP / "b.jsonl", b)
    result = cli("labels.py", "--emit-worklist", "--dataset", records_path, "--out", TMP / "worklist.jsonl")
    assert result.returncode == 0 and len(common.read_jsonl(TMP / "worklist.jsonl")) == 3
    assert all(row["reason_sha256"] == common.sha256_text(row["text"])
               for row in common.read_jsonl(TMP / "worklist.jsonl"))
    result = cli("labels.py", "--ingest", "--dataset", records_path,
                 "--proposal", TMP / "a.jsonl", "--adjudication", TMP / "b.jsonl",
                 "--out", TMP / "labels.jsonl", "--agreement-note", TMP / "agreement.md")
    assert result.returncode == 0 and common.read_jsonl(TMP / "labels.jsonl") == final
    assert all(row["reason_sha256"] == row["labeler_a"]["reason_sha256"] ==
               row["labeler_b"]["reason_sha256"] for row in final)
    a[0]["evidence_span"] = "absent span"
    try:
        labels.reconcile(reasons, a, b)
    except ValueError:
        pass
    else:
        raise AssertionError("unsourced evidence accepted")


def numerical_tests():
    truth = [True, True, True, False, False, False]
    predictions = [True, True, False, True, False, False]
    metrics = score.confusion(truth, predictions)
    assert [metrics[k] for k in ("tp", "fp", "fn", "tn")] == [2, 1, 1, 2]
    assert metrics["precision"] == metrics["recall"] == metrics["f1"] == 2 / 3
    assert metrics["fpr"] == 1 / 3
    rows = [{"truth": y, "model": float(p), "baseline": float(i == 0)}
            for i, (y, p) in enumerate(zip(truth, predictions))]
    point, _ = score.paired_metrics(rows, b=30)
    assert point["baseline_f1"] == 0.5
    assert math.isclose(point["f1_delta"], 1 / 6, abs_tol=1e-15)
    boundary = [{"truth": True, "model": 0.50, "baseline": 0.34}]
    assert score.point_estimates(boundary)["model_recall"] == 1
    assert score.point_estimates(boundary)["baseline_recall"] == 1
    boundary[0]["model"] = math.nextafter(0.5, 0)
    assert score.point_estimates(boundary)["model_recall"] == 0
    for text in ("Run `check`", "Read dir/file.ext", "Read check.py", "Reach 4 cases", "Print 'done'", 'Print "done"'):
        assert not baseline.item_is_unverifiable(text)
    assert baseline.item_is_unverifiable("Keep the design elegant")
    assert baseline.score_brief({"acceptance_items": []}) is None
    assert baseline.score_brief({"acceptance_items": ["Be clear", "Reach 4"]}) == 0.5
    assert baseline.predict({"acceptance_items": ["Be clear", "Reach 4"]}, 0.5)
    records, final, responses = fixture(2, 2)
    final[1]["category"] = "repo-fact-mismatch"
    groups, _, _, counts = score.populations(records, final, score.response_index(responses))
    assert sum(r["truth"] for r in groups["criterion-unverifiable"]) == 1
    assert sum(r["truth"] for r in groups["repo-fact-mismatch"]) == 1
    assert sum(r["truth"] for r in groups["process"]) == 0
    assert len(groups["criterion-unverifiable"]) == 4
    final[1]["category"] = "ambiguous"
    groups, _, _, counts = score.populations(records, final, score.response_index(responses[:-1]))
    assert counts["ambiguous_briefs"] == 1 and counts["missing_lint_predictions"] == 1
    assert len(groups["criterion-unverifiable"]) == 2
    records[0]["acceptance_items"] = []
    groups, _, _, counts = score.populations(records, final, score.response_index(responses))
    assert counts["empty_acceptance_briefs"] == 1 and len(groups["criterion-unverifiable"]) == 2


def verdict_tests():
    assert score.decide(10, 0.20, 10, 0.50, 0.10) == "pass"
    assert score.decide(10, 0.21, 10, 0.50, 0.10) == "do not enable lint-brief"
    assert score.decide(10, 0.20, 10, 0.49, 0.10) == "do not enable lint-brief"
    assert score.decide(10, 0.20, 10, 0.50, 0.09) == "do not enable lint-brief"
    assert score.decide(9, 0, 10, 1, 1) == "inconclusive"
    assert score.decide(10, 0, 9, 1, 1) == "inconclusive"
    assert score.decide(9, 0, 10, 0.4, 1) == "do not enable lint-brief"
    records, final, responses = fixture()
    report = score.render_report(records, final, responses, [], b=30)
    assert report.startswith("# DEMONSTRATION (mock adapter)")
    assert report.endswith("not-an-enablement-decision\n")
    # Fabricated response metadata tests decision logic; no live adapter is used.
    for r in responses:
        r["mode"] = "live"
    assert score.render_report(records, final, responses, [], b=30).endswith("\npass\n")
    for r in responses[10:]:
        r["score"] = 0.9
    assert score.render_report(records, final, responses, [], b=30).endswith("\ndo not enable lint-brief\n")
    records, final, responses = fixture(9, 9)
    for r in responses:
        r["mode"] = "live"
    assert score.render_report(records, final, responses, [], b=30).endswith("\ninconclusive\n")


def bootstrap_tests():
    rows = [{"truth": i < 10, "model": float(i % 3 == 0), "baseline": float(i % 4 == 0)}
            for i in range(20)]
    first = score.paired_metrics(rows)
    second = score.paired_metrics(rows)
    assert json.dumps(first, sort_keys=True) == json.dumps(second, sort_keys=True)
    assert all(0 <= lo <= hi <= 1 for key, (lo, hi) in first[1].items() if key != "f1_delta")
    equal = [dict(row, baseline=row["model"]) for row in rows]
    assert score.paired_metrics(equal)[1]["f1_delta"] == (0.0, 0.0)
    records, final, responses = fixture(2, 2)
    report = score.render_report(records, final, responses, [], b=30)
    for line in report.splitlines():
        if line.startswith(("| precision |", "| recall |", "| f1 |")):
            assert line.count("95% CI") == 2
    assert "Bootstrap seed: 20260921" in report
    # Exercise the production CLI and its frozen B=2000, all on private fixtures.
    paths = [TMP / name for name in ("scoring-data.jsonl", "scoring-labels.jsonl", "scoring-responses.jsonl")]
    for path, rows in zip(paths, (records, final, responses)):
        common.write_jsonl(path, rows)
    result = cli("score.py", "--dataset", paths[0], "--labels", paths[1], "--responses", paths[2],
                 "--out", TMP / "report.md")
    assert result.returncode == 0 and "B=2000" in result.stdout
    assert "95% CI" in result.stdout and result.stdout == (TMP / "report.md").read_text()


def insufficient_tests():
    records, final, responses = fixture(3, 5)
    report = score.render_report(records, final, responses, [], b=30)
    assert "criterion-unverifiable\n\nEligible briefs: 8; positives: 3.\nINSUFFICIENT DATA (n=3, need >=10)" in report
    assert "Clean denominator: 5\nINSUFFICIENT DATA (n=5, need >=10)" in report
    assert "significant" not in report.lower()
    assert score.WEAK_EVIDENCE in report


def risk_tests():
    root = TMP / "risk"
    for i in range(6):
        before, after = ("normal", "critical") if i < 4 else ("low", "normal")
        plan = f"# Plan\n```\nRISK AMENDED: low -> critical\n```\nRISK AMENDED: {before} → {after}\n"
        task(root, str(i), plan=plan)
    records, _ = builder.build_dataset([root])
    assert all(r["risk_observed"] and len(r["risk_events"]) == 1 for r in records)
    assert all(r["risk_events"][0]["source_line"] == 5 for r in records)
    counts = score.risk_counts(records)
    assert counts["events"] == counts["escalations"] == counts["comparable_events"] == 6
    assert counts["declared_matches_from"] == 4 and counts["declared_matches_to"] == 2
    report = score.render_report(records, [], [], [], b=10)
    risk_section = report.split("## RISK declarations and recorded transitions\n")[1].split("## Injection scan")[0]
    assert "INSUFFICIENT DATA" not in risk_section and "events: 6" in risk_section
    report = score.render_report(records[:4], [], [], [], b=10)
    assert "INSUFFICIENT DATA (n=4, need >=5)" in report


def secret_tests():
    literal = "AbCdEf0123456789" * 2
    aws = "AKIA" + "0123456789ABCDEF"
    cases = [(aws, True), ("example " + aws, True), (aws.lower(), False),
             ('secret = "' + literal + '"', True),
             ('secret = "' + literal + '" # placeholder', False),
             ('secret = "' + literal + "'", True)]
    cases.extend(('token' + ws + '= "' + literal + '"', True) for ws in " \t\v\f\r")
    for i, (line, expected) in enumerate(cases):
        path = TMP / f"secret-case-{i}.conf"
        # Bytes preserve CR exactly; the scanner splits on LF.
        path.write_bytes((line + "\n").encode())
        assert common.read_text(path) == line + "\n"
        result = subprocess.run([str(ROOT / "bin/orch-security-scan"), "--files", str(path)],
                                capture_output=True, text=True, check=False)
        assert result.returncode == (1 if expected else 0)
        assert ("hardcoded-secret" in result.stdout) == secrets.is_secret_shaped(line) == expected
        assert secrets.scan_record("harmless\n" + line) == ((True, 2) if expected else (False, None))
    request = {"id": "secret", "task": "lint", "text": 'token = "' + literal + '"'}
    with patch.object(adapter, "lint_brief", side_effect=AssertionError("privacy gate bypassed")):
        stats = run_eval.execute([request], mode="mock", cache=TMP / "secret-cache", out=TMP / "secret-out.jsonl")
    assert stats["skipped_secret_shaped"] == 1 and stats["adapter_calls"] == 0
    row = common.read_jsonl(TMP / "secret-out.jsonl")[0]
    assert row["status"] == "skipped_secret_shaped" and literal not in json.dumps(row)
    root = TMP / "secret-source"
    directory = task(root, "carriage-return")
    (directory / "brief.md").write_bytes(('token\r= "' + literal + '"\n').encode())
    records, _ = builder.build_dataset([root])
    with patch.object(adapter, "lint_brief", side_effect=AssertionError("CR lost during extraction")):
        stats = run_eval.execute(run_eval.requests_for(records, [], "lint"), mode="mock",
                                 cache=TMP / "cr-cache", out=TMP / "cr-out.jsonl")
    assert stats["skipped_secret_shaped"] == 1


def cache_tests():
    requests = [{"id": "cached", "task": "lint", "text": "A harmless synthetic request."},
                {"id": "scan", "task": "scan", "text": "A synthetic scanning request."}]
    cache, output = TMP / "cache", TMP / "responses.jsonl"
    with patch.object(adapter, "lint_brief", wraps=adapter.lint_brief) as lint, \
         patch.object(adapter, "scan_text", wraps=adapter.scan_text) as scan:
        first = run_eval.execute(requests, mode="mock", cache=cache, out=output)
        assert lint.call_count == scan.call_count == 1
    first_bytes = output.read_bytes()
    with patch.object(adapter, "lint_brief", side_effect=AssertionError("lint cache miss")), \
         patch.object(adapter, "scan_text", side_effect=AssertionError("scan cache miss")):
        second = run_eval.execute(requests, mode="mock", cache=cache, out=output)
    assert first["adapter_calls"] == second["cache_hits"] == 2
    assert second["adapter_calls"] == 0 and first_bytes == output.read_bytes()
    assert run_eval.cache_key("lint", "mock", "same") != run_eval.cache_key("scan", "mock", "same")
    assert run_eval.cache_key("lint", "mock", "same") != run_eval.cache_key("lint", "live", "same")
    original = run_eval.cache_key("lint", "mock", "same")
    with patch.object(adapter, "ADAPTER_VERSION", "changed"):
        assert original != run_eval.cache_key("lint", "mock", "same")
    # A failed second call leaves the first cached result reusable on resume.
    partial_cache, partial_out = TMP / "partial-cache", TMP / "partial.jsonl"
    with patch.object(adapter, "scan_text", side_effect=RuntimeError("interrupted")):
        try:
            run_eval.execute(requests, mode="mock", cache=partial_cache, out=partial_out)
        except RuntimeError:
            pass
        else:
            raise AssertionError("interruption not exercised")
    assert not partial_out.exists()
    with patch.object(adapter, "lint_brief", side_effect=AssertionError("partial cache lost")):
        resumed = run_eval.execute(requests, mode="mock", cache=partial_cache, out=partial_out)
    assert resumed["cache_hits"] == resumed["adapter_calls"] == 1


def dry_run_tests():
    records, _, _ = fixture(1, 0)
    dataset = TMP / "dry-dataset.jsonl"
    common.write_jsonl(dataset, records)
    output, cache = TMP / "dry-output.jsonl", TMP / "dry-cache"
    requests = run_eval.requests_for(records, [], "lint")
    with patch.object(adapter, "lint_brief", side_effect=AssertionError("dry-run made a call")):
        stats = run_eval.execute(requests, mode="mock", cache=cache, out=output, dry_run=True)
    assert stats["requests"] == 1
    assert stats["estimated_input_tokens"] == len(records[0]["brief_text"]) / 4
    assert stats["estimated_input_cost_usd"] == len(records[0]["brief_text"]) / 4 * 0.042 / 1_000_000
    assert not cache.exists() and not output.exists()
    result = cli("run_eval.py", "--dry-run", "--task", "lint", "--dataset", dataset,
                 "--cache", cache, "--out", output)
    assert result.returncode == 0 and "requests=1" in result.stdout and "estimated_input_cost=$" in result.stdout
    result = cli("run_eval.py", "--mode", "live")
    assert result.returncode == 2 and result.stderr == "run_eval.py: live mode requires --live\n"
    result = cli("run_eval.py", "--rpm", "301", "--dataset", dataset)
    assert result.returncode == 2
    # Mock mode must not even attempt to read the API key.
    original = os.environ.get
    def getenv(key, *args):
        assert key != "TYPESAFE_API_KEY"
        return original(key, *args)
    with patch.object(os.environ, "get", side_effect=getenv):
        run_eval.main(["--dry-run", "--task", "lint", "--dataset", str(dataset),
                       "--cache", str(cache), "--out", str(output)])


def leak_tests():
    sentinel = "private-fixture-" + uuid.uuid4().hex
    root, output = TMP / "sentinel-root", TMP / "sentinel-dataset.jsonl"
    task(root, "one", brief=sentinel + "\n## Acceptance\n1. Be nice.\n")
    result = cli("build_dataset.py", "--roots", root, "--out", output)
    assert result.returncode == 0 and sentinel in output.read_text()
    assert sentinel not in result.stdout and sentinel not in result.stderr
    stats = json.loads(result.stdout)
    assert stats["total"] == 1 and stats["without_verdict"] == 1
    encoded = sentinel.encode()
    for directory, children, files in os.walk(ROOT):
        children[:] = [child for child in children if child != ".git"]
        for name in files:
            path = Path(directory) / name
            if path.is_file():
                assert encoded not in path.read_bytes(), "fixture text escaped its private artifacts"


def injection_tests():
    rows = common.read_jsonl(MODULES / "injection-set.jsonl")
    assert len(rows) >= 30 and len({r["id"] for r in rows}) == len(rows)
    assert sum(r["label"] == "directive" for r in rows) >= 15
    assert sum(r["label"] == "benign" for r in rows) >= 15
    for row in rows:
        assert row["label"] in ("directive", "benign") and row["note"] and row["text"]
        assert ("api" + "key_") not in json.dumps(row)
        assert not secrets.scan_record(json.dumps(row))[0]
    result = cli("run_eval.py", "--task", "scan", "--cache", TMP / "scan-cache",
                 "--out", TMP / "scan-responses.jsonl")
    assert result.returncode == 0
    responses = common.read_jsonl(TMP / "scan-responses.jsonl")
    assert len(responses) == len(rows) and all(r["task"] == "scan" and r["mode"] == "mock" for r in responses)
    report = score.render_report([], [], responses, rows, b=30)
    assert "eligible: 32; missing: 0; skipped: 0" in report
    assert score.WEAK_EVIDENCE in report


def root_config_tests():
    output = TMP / "root-config.jsonl"
    with patch.dict(os.environ):
        os.environ.pop("JEV_EVAL_ROOTS", None)
        result = cli("build_dataset.py", "--out", output)
        assert result.returncode == 2
        assert result.stderr == "build_dataset.py: pass --roots or set JEV_EVAL_ROOTS\n"
        assert not result.stdout and not output.exists()
    for value in ("", "::"):
        with patch.dict(os.environ, {"JEV_EVAL_ROOTS": value}):
            result = cli("build_dataset.py", "--out", output)
        assert result.returncode == 2 and "pass --roots or set JEV_EVAL_ROOTS" in result.stderr
        assert not result.stdout and not output.exists()
    first, second = TMP / "configured-first", TMP / "configured-second"
    task(first, "one")
    task(second, "two")
    with patch.dict(os.environ, {"JEV_EVAL_ROOTS": f":{first}::{second}:"}):
        result = cli("build_dataset.py", "--out", output)
        assert result.returncode == 0 and json.loads(result.stdout)["total"] == 2
        assert {row["id"] for row in common.read_jsonl(output)} == {
            "configured-first/one", "configured-second/two"}
        result = cli("build_dataset.py", "--roots", first, "--out", output)
        assert result.returncode == 0 and json.loads(result.stdout)["total"] == 1
        assert [row["id"] for row in common.read_jsonl(output)] == ["configured-first/one"]
    # Assemble the denylist without embedding its private names in this file.
    forbidden = ("pave" + "splat", "mog" + "splat", "je" + "pags",
                 "tele_" + "project", "pilot" + "mv")
    # Include pending source additions as well as already tracked harness files.
    tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--",
                                       "eval/jev-phase0/", "tests/test-jev-eval.sh"])
    paths = {ROOT / os.fsdecode(name) for name in tracked.split(b"\0") if name}
    paths.update(MODULES.iterdir())
    paths.add(ROOT / "tests/test-jev-eval.sh")
    for path in paths:
        if path.is_file():
            content = path.read_bytes()
            assert not any(name.encode() in content for name in forbidden), \
                f"private project name found in {path.name}"


def amendment_extraction_tests():
    root = TMP / "amendment-boundaries"
    plan = ("# Plan (round 2)\n## Amendments\nThis preamble is not a separate reason.\n"
            "1. First audit correction.\n2. Second audit correction.\n3. Third audit correction.\n"
            "### Implementation details\n- Unrelated implementation work.\n"
            "## Orchestrator notes\n- Unrelated operational instructions.\n"
            "## Amendment (mid-task, round 3)\n- New instructions after the audit.\n")
    directory = task(root, "enumerated", summary="BRIEF AUDIT: amended\n", plan=plan)
    record = builder.task_record(root, directory)
    assert [r["text"] for r in record["reasons"]] == [
        "First audit correction.", "Second audit correction.", "Third audit correction."]
    assert [r["source_line"] for r in record["reasons"]] == [4, 5, 6]
    assert [kind for kind, _ in builder.amendment_sections(plan)] == ["audit", "process"]
    for excluded in ("Unrelated implementation", "Unrelated operational", "New instructions"):
        assert excluded not in record["plan_amendment_text"]
    prose = "## Amendment: unclear acceptance\nThe acceptance statement has no observable outcome.\n"
    directory = task(root, "prose", summary="BRIEF AUDIT: amended\n", plan=prose)
    record = builder.task_record(root, directory)
    assert len(record["reasons"]) == 1
    assert record["reasons"][0]["text"] == (
        "Amendment: unclear acceptance The acceptance statement has no observable outcome.")
    assert record["reasons"][0]["source_line"] == 1
    for own_heading in ("Amendment mid-task", "Amendment from orchestrator", "Amendment ruling",
                        "Amendment course correction", "Amendment post-gate", "Amendment round 4"):
        sections = builder.amendment_sections(f"# {own_heading}\n- Process change.\n")
        assert [kind for kind, _ in sections] == ["process"]
    nested = ("# Plan (orchestrator, round 2)\n## Amendment mid-task\n- Process change.\n"
              "### Amendments\n- Independent audit correction.\n### Implementation\n- Not a reason.\n"
              "## Amendments\n- Another audit correction.\n")
    directory = task(root, "nested", summary="BRIEF AUDIT: amended\n", plan=nested)
    record = builder.task_record(root, directory)
    assert [r["text"] for r in record["reasons"]] == [
        "Independent audit correction.", "Another audit correction."]
    for empty in ("## Amendments\n", "## Amendments\n---\n...\n",
                  "## Amendments\n1. ---\n2. !!!\n3. \n"):
        directory = task(root, "empty", summary="BRIEF AUDIT: amended (---)\n", plan=empty)
        assert builder.task_record(root, directory)["reasons"] == []


def label_binding_tests():
    records, _, responses = fixture()
    sources = labels.worklist(records)
    proposal = [{"reason_id": row["reason_id"], "reason_sha256": row["reason_sha256"],
                 "category": "criterion-unverifiable", "evidence_span": row["text"]}
                for row in sources]
    final = labels.reconcile(sources, proposal, [dict(row) for row in proposal])
    for row in responses:
        row["mode"] = "live"  # Synthetic metadata only; no adapter is called.
    assert score.render_report(records, final, responses, [], b=10).endswith("\npass\n")
    reason = records[0]["reasons"][0]
    original = reason["text"]
    reason["text"] = "Changed reason text after labeling."
    # Even a retained stale hash on the dataset must not override its actual text.
    reason["reason_sha256"] = common.sha256_text(original)
    with patch.object(score, "decide", side_effect=AssertionError("stale labels produced a verdict")):
        try:
            score.render_report(records, final, responses, [], b=10)
        except ValueError as error:
            assert "reason_sha256 mismatch" in str(error)
        else:
            raise AssertionError("changed reason text accepted stale labels")
    dataset, label_file, response_file, output = [TMP / name for name in
        ("binding-dataset.jsonl", "binding-labels.jsonl", "binding-responses.jsonl", "binding-report.md")]
    for path, rows in ((dataset, records), (label_file, final), (response_file, responses)):
        common.write_jsonl(path, rows)
    result = cli("score.py", "--dataset", dataset, "--labels", label_file,
                 "--responses", response_file, "--out", output)
    assert result.returncode == 2 and "score.py: label reason_sha256 mismatch" in result.stderr
    assert reason["text"] not in result.stderr and not result.stdout and not output.exists()
    reason["text"] = original
    for excluded in (False, True):
        records[0]["verdict"] = "unknown" if excluded else "amended"
        for problem, message in (("missing", "missing reason_sha256"),
                                 ("mismatch", "reason_sha256 mismatch"),
                                 ("orphan", "reason_id is absent from the current dataset")):
            bad = [dict(row) for row in final]
            if problem == "missing":
                del bad[0]["reason_sha256"]
            elif problem == "mismatch":
                bad[0]["reason_sha256"] = "0" * 64
            else:
                bad[0]["reason_id"] = "absent/reason#r01"
            try:
                score.populations(records, bad, {})
            except ValueError as error:
                assert message in str(error)
            else:
                raise AssertionError("unbound label was silently accepted or skipped")
    for labeler in (0, 1):
        for missing in (False, True):
            pair = [[dict(row) for row in proposal] for _ in range(2)]
            if missing:
                del pair[labeler][0]["reason_sha256"]
            else:
                pair[labeler][0]["reason_sha256"] = "0" * 64
            try:
                labels.reconcile(sources, *pair)
            except ValueError as error:
                assert "reason_sha256" in str(error)
            else:
                raise AssertionError("ingestion accepted an unbound proposal or adjudication")


globals()[sys.argv[1] + "_tests"]()
PY

python3 "$TMP/check.py" guard
ok 'all private artifact outputs refuse worktrees and symlinks before creation'
python3 "$TMP/check.py" discovery
ok 'literal wt exclusion, subunits, symlink inclusion and realpath collisions'
python3 "$TMP/check.py" parser
ok 'verdicts, wrapped reasons, process amendments and independent label agreement'
python3 "$TMP/check.py" numerical
ok 'known confusion matrices, thresholds, paired delta and category separation'
python3 "$TMP/check.py" verdict
ok 'pass, do-not-enable, inconclusive and forced mock demonstration verdicts'
python3 "$TMP/check.py" bootstrap
ok 'paired bootstrap intervals, production replicate count and deterministic seed'
python3 "$TMP/check.py" insufficient
ok 'small category and clean denominators suppress conclusions'
python3 "$TMP/check.py" risk
ok 'six sourced RISK transitions, agreement counts and four-event insufficiency'
python3 "$TMP/check.py" secret
ok 'scanner parity including five whitespace characters and pre-adapter skip'
python3 "$TMP/check.py" cache
ok 'resume reuses lint and scan caches without additional calls'
run python3 "$TMP/check.py" dry_run
assert_eq "$RUN_STATUS" 0 'dry-run checks'
assert_has "$RUN_OUTPUT" 'estimated_input_cost=$' 'dry-run dollar estimate'
ok 'dry-run count and cost, request cap, live opt-in and key access guard'
python3 "$TMP/check.py" leak
ok 'fixture sentinel stays outside the checkout and stdout is counts only'
python3 "$TMP/check.py" injection
ok 'synthetic injection fixture validation and scan scoring path'
python3 "$TMP/check.py" root_config
ok 'explicit and environment root selection, missing-root guidance and private-name exclusion'
python3 "$TMP/check.py" amendment_extraction
ok 'own-heading amendment selection, exact list counts, prose fallback and empty-reason rejection'
python3 "$TMP/check.py" label_binding
ok 'reason hashes bind both labelers and abort stale, missing-hash or orphaned-label scoring'

echo "PASS: $pass jev-eval test groups"
