# Real-run provenance and interpretation

The lead ran these commands from the clone root on 2026-10-02 at commit
`2e59193`:

```bash
export GATE_AB_ROOT=<corpus root>
unshare -rn python3 eval/diff-triage/build_labels.py --note eval/diff-triage/evidence/label-counts.md
/usr/bin/time -v unshare -rn python3 eval/diff-triage/run_eval.py --s3 auto --note eval/diff-triage/evidence/real-run.md
```

Label building exited 0. Evaluation exited 0; wall time was `0:01.21` and
maximum RSS was `31036 KiB`.
Private outputs used the default
`${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/diff-triage`.
The script-generated aggregates are in [label-counts.md](label-counts.md) and
[real-run.md](real-run.md).

The following corpus SHA-256 hashes were identical before and after the run:

| File | SHA-256 |
|---|---|
| `eval/gate-ab/tabulation.csv` | `2c874529d069e78c719ebf8174d6c0caddf84a58301eb0869e4f800255e617e2` |
| `eval/gate-ab/inventory.csv` | `7f5935c9d18561e746ef67d000d14928c02586c98f9a16d6a0f138047cc812a0` |

Criteria commit: `4174cde`, containing `criteria.md` alone, before scoring.

Verdict: **inconclusive (primary thresholds not resolved)**, with 12 usable
primary diffs. Primary recall@k20 paired comparisons (95% confidence intervals):

| Comparison | Mean delta | CI |
|---|---:|---|
| S2-S1 | -0.0167 | [-0.1722, 0.2056] |
| S2-S0 | 0.2318 | [0.0621, 0.4090] |

Rule 1 does not apply because there are at least 10 usable primary diffs.
S2 is the only candidate. Rule 2 does not apply because its mean delta against
S1 is -0.0167 < 0.10. Rule 3 does not apply because its CI-high against S1 is
0.2056 >= 0.10. Rule 4 therefore yields the recorded inconclusive verdict.

```text
S3 skipped: configured GGUF absent; llama-server unavailable; GPU with at least 12288 MiB free unavailable
```

This is a skip, not a result.

`recount.py check` with `GATE_AB_ROOT` set exited 1 both at baseline and after:
314 lines each, all `missing source cc-orchestra/...`. This is pre-existing;
that corpus prefix no longer exists on disk.

No verdict authorises a gate or review-policy change.
