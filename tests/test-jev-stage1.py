"""Synthetic Stage 1 contracts; no real log, policy or model is used."""

import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "eval/jev-shadow-stage1/analyze.py"
TMP = Path(sys.argv[1])
POLICY = TMP / "fixture-policy.conf"
POLICY.write_text('# Synthetic policy\n\nJEV_SHADOW_MIN_CONFIDENCE="0.6"\n'
                  'JEV_SHADOW_LOG="fixture.jsonl"\n', encoding="utf-8")
spec = importlib.util.spec_from_file_location("stage1_analyze", TOOL)
analyze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyze)
ENABLED = datetime.date(2026, 9, 22)
REVIEW = datetime.date(2026, 10, 6)
GROUPS = 0


def ok(message):
    global GROUPS
    GROUPS += 1
    print(f"ok {GROUPS} - {message}", flush=True)


def fixture(n=40, mechanical=10):
    return [{
        "id": f"private-record-sentinel-{i}", "thread_id": f"private-thread-sentinel-{i}",
        "task_name": f"private-task-sentinel-{i}", "brief": f"private-brief-sentinel-{i}",
        "timestamp": (datetime.datetime(2026, 9, 22, tzinfo=datetime.timezone.utc)
                      + datetime.timedelta(days=i % 15)).isoformat(),
        "mode": "implement", "status": "ok", "observation": "exact",
        "reasoning": i / max(n, 1), "duration_ms": i * 1000,
        "difficulty": "mechanical" if i < mechanical else "involved",
        "difficulty_confidence": 0.6, "attempts": 1, "codex_exit": 0,
        # Deliberately contradict the raw answer: stored suggestions must not count.
        "suggested_model": "not-a-mechanical-model", "suggested_reason": "low-confidence",
    } for i in range(n)]


def evaluate(rows, threshold=0.6, enabled=ENABLED, review=REVIEW):
    return analyze.evaluate(rows, threshold, enabled, review)


def statuses(result):
    return [result[f"criterion{i}"]["status"] for i in range(1, 5)]


def write_log(name, rows):
    path = TMP / (name + ".jsonl")
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return path


def cli(log, *args, policy=POLICY):
    # Every CLI invocation passes both paths, even when testing bad flags or files.
    return subprocess.run([sys.executable, str(TOOL), "--log", str(log), "--policy", str(policy),
                           *map(str, args)], capture_output=True, timeout=60,
                          env={**os.environ, "CC_ORCH_STATE_DIR": str(TMP)})


def reference_bootstrap(pairs, seed, resamples):
    """Independent O(n^2) ranks and explicit Pearson centering for a small oracle."""
    def correlation(sample):
        ranks = []
        for axis in (0, 1):
            values = [pair[axis] for pair in sample]
            ranks.append([1 + sum(other < value for other in values)
                          + (sum(other == value for other in values) - 1) / 2
                          for value in values])
        centered = [[value - sum(vector) / len(vector) for value in vector] for vector in ranks]
        variances = [sum(value ** 2 for value in vector) for vector in centered]
        if min(variances) == 0:
            return None
        numerator = sum(centered[0][i] * centered[1][i] for i in range(len(sample)))
        return numerator / math.sqrt(variances[0] * variances[1])

    rng, values, undefined = random.Random(seed), [], 0
    for _ in range(resamples):
        sample = []
        for _ in range(len(pairs)):
            sample.append(pairs[rng.randrange(len(pairs))])
        rho = correlation(sample)
        if rho is None:
            undefined += 1
        else:
            values.append(rho)
    values.sort()
    if not values:
        return None, None, undefined
    return values[int(0.025 * len(values))], values[int(0.975 * len(values)) - 1], undefined


assert analyze.average_ranks([10, 20, 20, 30]) == [1, 2.5, 2.5, 4]
# Ranks centered at 3 give dot product 7.25 and each squared norm 9.5.
assert abs(analyze.spearman([1, 2, 2, 3, 4], [2, 1, 3, 3, 5]) - 29 / 38) < 1e-12
assert analyze.spearman([1, 1, 1], [1, 2, 3]) is None
assert analyze.spearman([1, 2, 3], [1, 1, 1]) is None
assert analyze.spearman([], []) is None
ok("average ranks, hand-computed tied Spearman and zero variance")

pairs = [(0, 1), (0, 1), (1, 3), (2, 2)]
expected = reference_bootstrap(pairs, 20261006, 200)
first = analyze.bootstrap_interval(pairs, resamples=200)
assert first == expected == analyze.bootstrap_interval(pairs, resamples=200)
assert 0 < first[2] < 200
assert analyze.bootstrap_interval(pairs, seed=17, resamples=200) == reference_bootstrap(pairs, 17, 200)
assert analyze.bootstrap_interval([(0, 1)] * 4, resamples=200) == (None, None, 200)
assert analyze.bootstrap_interval([]) == (None, None, 10000)
assert analyze.bootstrap_interval(pairs) == reference_bootstrap(pairs, 20261006, 10000)
# A less discrete fixture keeps both percentiles away from the trivial [-1, 1].
varied_pairs = list(enumerate([5, 0, 3, 7, 2, 1, 8, 6, 4, 11, 10, 15, 9, 13, 12, 14]))
varied_expected = reference_bootstrap(varied_pairs, 20261006, 200)
assert -1 < varied_expected[0] < varied_expected[1] < 1
assert analyze.bootstrap_interval(varied_pairs, resamples=200) == varied_expected
ok("independent paired bootstrap oracle, seed, percentile indices and undefined counts")

rows = fixture()
rows[10].update(codex_exit=1, attempts=2)
passing = evaluate(rows)
assert statuses(passing) == ["met"] * 4
assert passing["criterion4"]["other_failures"] == 1  # OR, not two events.
assert passing["verdict"] == passing["alternative_verdict"] == "proceed to Stage 2 discussion"
ok("all criteria met, raw confidence threshold included and failure/retry union")

rows = fixture()
for row in rows:
    row["duration_ms"] = 40000 - row["duration_ms"]
result = evaluate(rows)
assert statuses(result) == ["met", "not met", "met", "met"]
assert result["criterion2"]["rho"] < 0.30
assert result["criterion2"]["excludes_zero"]  # A negative interval does not satisfy rho.
assert result["verdict"] == "do not adopt"
# Supplied interval isolates the second signal condition without searching a noisy fixture.
with patch.object(analyze, "bootstrap_interval", return_value=(-0.1, 0.9, 0)):
    result = evaluate(fixture())
assert result["criterion2"]["rho"] >= 0.30
assert statuses(result) == ["met", "not met", "met", "met"]
assert result["verdict"] == "do not adopt"
assert analyze.signal_status(40, 0.30, (0.01, 0.9)) == "met"
assert analyze.signal_status(40, 0.29999999, (0.01, 0.9)) == "not met"
assert analyze.signal_status(40, 0.8, (0, 0.9)) == "not met"
ok("signal fails independently on low rho or an interval containing zero; unrounded thresholds")

result = evaluate(fixture(60, 10))
assert statuses(result) == ["met", "met", "not met", "met"]
assert result["criterion3"]["mechanical"] == 10 and result["verdict"] == "do not adopt"
ok("savings alone fails below 20% with both risk groups large enough")

for field, value in (("codex_exit", -1), ("attempts", 2)):
    rows = fixture()
    rows[0][field] = value
    result = evaluate(rows)
    assert statuses(result) == ["met", "met", "met", "not met"]
    assert result["criterion4"]["mechanical_failures"] == 1
    assert result["verdict"] == "do not adopt"
ok("risk alone fails for nonzero exit and for retry, separately")

result = evaluate(fixture(30, 6))
assert statuses(result) == ["met", "met", "met", "insufficient"]
assert result["verdict"] == "inconclusive"
result = evaluate(fixture(30, 25))
assert result["criterion4"]["status"] == "insufficient"  # Small OTHER group also counts.
assert result["verdict"] == "inconclusive"
result = evaluate(fixture(40, 7))
assert statuses(result) == ["met", "met", "not met", "insufficient"]
assert result["verdict"] == "do not adopt"  # Insufficient C4 cannot mask a failed C3.
ok("either risk group below ten is insufficient; not-met still takes precedence")

result = evaluate(fixture(29, 10))
assert statuses(result) == ["not met", "met", "met", "met"]
assert result["verdict"] == "inconclusive"
result = evaluate(fixture(), review=datetime.date(2026, 10, 5))
assert result["criterion1"]["days"] == 13 and result["verdict"] == "inconclusive"
rows = fixture()
for row in rows:
    row["timestamp"] = "2026-10-01T00:00:00Z"
result = evaluate(rows)
assert result["criterion1"]["span_days"] == 0
assert result["verdict"] == "proceed to Stage 2 discussion"
assert result["alternative_verdict"] == "inconclusive"
rows.append({"mode": "resume", "status": "skipped:resume", "timestamp": "2026-09-01T00:00:00Z"})
assert evaluate(rows)["alternative_verdict"] == "proceed to Stage 2 discussion"
ok("sufficiency count/date boundaries and alternative span over all modes/statuses")

rows = fixture()
invalid = []
for field, values in (
    ("reasoning", [None, True, "0.3", float("inf"), float("nan")]),
    ("difficulty_confidence", [None, False, "0.8", float("-inf"), float("nan")]),
    ("duration_ms", [None, True, -1, 1.5]),
    ("codex_exit", [None, False, 1.0]),
    ("attempts", [None, True, -1, 1.5]),
    ("difficulty", [None, 7]),
):
    for value in values:
        invalid.append({**rows[0], field: value})
    missing = dict(rows[0])
    del missing[field]
    invalid.append(missing)
rows += [dict(rows[0], mode="resume"), dict(rows[0], status="skipped:unreadable"),
         dict(rows[0], observation="ambiguous"), *invalid]
result = evaluate(rows)
assert result["n"] == 40 and result["excluded"] == len(invalid)
assert result["implement"] == len(rows) - 1 and result["implement_ok"] == len(rows) - 2
assert result["exact_not_ok"] == 1 and statuses(result) == ["met"] * 4
assert analyze.valid_fields(dict(fixture()[0], reasoning=1, difficulty_confidence=1,
                                 duration_ms=0, attempts=0, difficulty="unknown"))
filtered_log = write_log("population", rows)
output = cli(filtered_log)
assert output.returncode == 0 and not output.stderr
assert f"excluded (invalid fields) {len(invalid)}".encode() in output.stdout
assert b"analysed (implement, ok, exact) 40" in output.stdout
ok("population/status filters and every required field's exclusion rules")

rows = fixture()
rows[0]["difficulty_confidence"] = 0.599999999
result = evaluate(rows)
assert result["criterion3"]["mechanical"] == 9
assert result["criterion4"]["all_mechanical"] == 10
assert result["criterion4"]["other"] == 31
assert result["criterion4"]["status"] == "insufficient"
result["threshold"] = 0.600000001
assert "JEV_SHADOW_MIN_CONFIDENCE=0.600000001" in analyze.render(result, "fixture", "hash", "policy")
changed_policy = TMP / "higher-threshold.conf"
changed_policy.write_text('JEV_SHADOW_MIN_CONFIDENCE=0.7\nJEV_SHADOW_LOG="unused.jsonl"\n')
output = cli(write_log("threshold", fixture()), policy=changed_policy)
assert output.returncode == 0 and b"confidence >= 0.7: 0/40 (0.0%)" in output.stdout
assert b"verdict: do not adopt\n" in output.stdout
ok("current policy re-maps raw confidence; low-confidence mechanical belongs to other")

empty_log = write_log("empty", [])
output = cli(empty_log)
assert output.returncode == 0 and not output.stderr
assert b"verdict: inconclusive\n" in output.stdout
assert output.stdout.count(b"-> insufficient") == 3
assert b"0/0 (n/a)" in output.stdout and b"span = n/a" in output.stdout
bad_log = TMP / "malformed.jsonl"
bad_log.write_bytes(b'not json\n[]\nnull\n\n\xff\n')
output = cli(bad_log)
assert output.returncode == 0 and not output.stderr
assert b"records: 0 \xc2\xb7 malformed lines: 5" in output.stdout
assert b"verdict: inconclusive\n" in output.stdout
rows = fixture()
for row in rows:
    row["reasoning"] = 1
output = cli(write_log("constant", rows))
assert output.returncode == 0 and b"spearman(reasoning, duration_ms) = undefined" in output.stdout
assert b"interval undefined (10000 resamples, seed 20261006, undefined 10000)" in output.stdout
assert b"verdict: do not adopt\n" in output.stdout
assert statuses(evaluate(fixture(9, 3))) == ["not met", "insufficient", "insufficient", "insufficient"]
ok("empty, all-malformed, small and constant-vector inputs")

assert analyze.timestamp_span([{}, {"timestamp": "bad"}, {"timestamp": 42}]) == (None, 3)
assert analyze.timestamp_span([{"timestamp": "2026-09-22"}, {}]) == (None, 1)
assert analyze.timestamp_span([{"timestamp": "2026-09-22T00:00:00"},
                               {"timestamp": "2026-10-06T09:00:00+09:00"}, {}]) == (14.0, 1)
assert analyze.timestamp_span([{"timestamp": "2026-09-22T00:00:01Z"},
                               {"timestamp": "2026-10-06T00:00:00Z"}])[0] < 14
ok("unparseable timestamp counts, insufficient timestamp count and UTC normalization")

log = write_log("repeatable", fixture())
before = (hashlib.sha256(log.read_bytes()).hexdigest(), log.stat().st_mtime_ns)
first, second = cli(log), cli(log)
assert first.returncode == second.returncode == 0 and not first.stderr and not second.stderr
assert first.stdout == second.stdout
assert f"log sha256: {before[0]}".encode() in first.stdout
assert b"verdict: proceed to Stage 2 discussion\n" in first.stdout
for row in rows + fixture():
    for field in ("id", "thread_id", "task_name", "brief"):
        assert row[field].encode() not in first.stdout + output.stdout
assert before == (hashlib.sha256(log.read_bytes()).hexdigest(), log.stat().st_mtime_ns)
assert hashlib.sha256(filtered_log.read_bytes()).hexdigest() == analyze.read_log(filtered_log)[2]
ok("two CLI runs byte-identical; stdout aggregate only; log sha256 and mtime unchanged")

policy_values, threshold = analyze.read_policy(POLICY)
assert threshold == 0.6 and policy_values["JEV_SHADOW_LOG"] == "fixture.jsonl"
# Check precedence as a pure path operation: never open a default or environment log.
with patch.dict(os.environ, {"CC_ORCH_STATE_DIR": str(TMP), "JEV_STAGE1_LOG": str(log)}):
    assert analyze.resolve_log_path(filtered_log, policy_values) == filtered_log
    assert analyze.resolve_log_path(None, policy_values) == log
with patch.dict(os.environ, {"CC_ORCH_STATE_DIR": str(TMP), "JEV_STAGE1_LOG": ""}):
    assert analyze.resolve_log_path(None, policy_values) == TMP / "fixture.jsonl"
    assert analyze.resolve_log_path(None, {"JEV_SHADOW_LOG": str(log)}) == log
with patch.dict(os.environ, {"CC_ORCH_STATE_DIR": "", "JEV_STAGE1_LOG": ""}), \
        patch.object(Path, "home", return_value=TMP):
    assert analyze.resolve_log_path(None, policy_values) == TMP / ".claude/orchestra-state/fixture.jsonl"
assert analyze.DEFAULT_POLICY == ROOT / "jev-policy.conf"
output = cli(log, "--enabled-date", "2026-09-23", "--review-date", "2026-10-06")
assert output.returncode == 0 and b"2026-09-23 -> 2026-10-06 = 13" in output.stdout
assert b"verdict: inconclusive\n" in output.stdout
ok("policy parsing, log precedence and fixed-date overrides")

bad_policy = TMP / "invalid-policy.conf"
bad_policy.write_text('JEV_SHADOW_MIN_CONFIDENCE=NaN\n')
for log_path, args, policy_path in (
    (TMP / "missing-log", (), POLICY),
    (TMP, (), POLICY),
    (empty_log, (), TMP / "missing-policy"),
    (empty_log, (), bad_policy),
    (empty_log, ("--unknown-flag",), POLICY),
    (empty_log, ("--review-date", "2026-02-30"), POLICY),
    (empty_log, ("--enabled-date", "20260922"), POLICY),
    (empty_log, ("--review-date",), POLICY),
):
    output = cli(log_path, *args, policy=policy_path)
    assert output.returncode == 2 and not output.stdout
    assert len(output.stderr.splitlines()) == 1 and output.stderr.startswith(b"analyze.py: ")
ok("unreadable inputs, invalid policy, flags and dates exit 2 with one stderr line")

print(f"PASS: {GROUPS} jev-stage1 test groups")
