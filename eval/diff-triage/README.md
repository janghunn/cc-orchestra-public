# Offline diff triage evaluation

Test whether a file-ranking hint could help a lead read a diff. This is an
advisory-hint feasibility experiment, never a gate. Even `worth designing an
advisory hint` authorises no review-policy or runtime change.

Read [criteria.md](criteria.md) for the frozen rules and
[protocol.md](protocol.md) for evidence mapping, isolation and limitations.
The criteria must be committed alone before scoring any real corpus.
Dependencies: Python 3 standard library and git. S3 additionally needs the
already-installed pinned GGUF, llama-server and a GPU with 12288 MiB free.
Nothing is downloaded. Missing S3 assets produce a skip, not a result.

## Run

Run from the checkout root. Choose a private output directory outside **every**
git worktree. `GATE_AB_ROOT` must contain the source prefixes recorded by the gate
corpus; the builder never guesses a root or rewrites source prefixes.

```bash
export GATE_AB_ROOT=/path/to/corpus-root
export CC_ORCH_STATE_DIR=/path/to/private-state
unshare -rn python3 eval/diff-triage/build_labels.py
unshare -rn python3 eval/diff-triage/run_eval.py --s3 auto
```

Output defaults to `${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/diff-triage`.
Override it with `--out`; when using a different label directory also pass
`--labels-dir` to the runner. Use `--s3 off` to evaluate S0/S1/S2 only. The frozen
seed is 20260921; `--seed` can select a reproducibility experiment's seed.

The lead can explicitly save aggregate evidence with:

```bash
unshare -rn python3 eval/diff-triage/build_labels.py \
  --note eval/diff-triage/evidence/label-counts.md
unshare -rn python3 eval/diff-triage/run_eval.py --s3 auto \
  --note eval/diff-triage/evidence/real-run.md
```

Per-row labels, per-diff results and caches stay private. Notes redact path
arguments and report aggregate statistics only. The runner records the criteria
commit, per-arm metrics, paired bootstrap deltas, usable counts, S3 status,
read-only fingerprints, runtime, memory and the mechanical verdict. With fewer
than ten usable primary diffs the verdict is `inconclusive`.

## Outputs and validation

- `labels.jsonl`: provenance, then every corpus row's mapping or exclusion.
- `diffs.jsonl`: provenance, then each diff's universes, defective files and usability.
- `results.jsonl`: per-diff arm orders and stratum metrics; S0 metrics average 1000 orders.

Exit 0 means execution succeeded, irrespective of the scientific verdict.
Exit 2 means invalid input, provenance or output containment. Exit 3 means the
read-only fingerprint changed. No score is a gate result. Stale label provenance
requires rebuilding labels from the current manifest and tabulation.

```bash
bash tests/test-diff-triage.sh
```

The suite builds synthetic throwaway repositories under `/tmp`, with no real
corpus scoring. It checks hand-computed scores, exact input bytes, leakage,
determinism, mapping, containment, provenance, paired bootstrap, verdicts,
read-only behavior and the S3 process lifecycle with fake transport. It prints
`S3 real local-model path: SKIPPED (fake transport only in tests)`.
