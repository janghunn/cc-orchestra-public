# Offline brief evaluation

This harness compares brief linting with a free acceptance-item heuristic. It
keeps reason categories separate because brief text alone cannot reveal whether
a repository path exists, an environment is configured, or an earlier test
already fails. RISK results compare declarations with recorded transitions.
Injection results use a small synthetic set and are weak evidence.

Python's standard library and Git are the only dependencies. Run these commands
from the checkout root. First have the lead commit `criteria.md` separately;
commit ownership remains with the lead. Record the criteria commit before any
real-data scoring. CI wiring deferred.

```bash
bash tests/test-jev-eval.sh
export JEV_EVAL_ROOTS="/path/to/project/.orchestra:/path/to/another-project/.orchestra"
python3 eval/jev-phase0/build_dataset.py --stats-only
python3 eval/jev-phase0/build_dataset.py
python3 eval/jev-phase0/labels.py --emit-worklist
```

Select historical roots with `--roots` or the colon-separated `JEV_EVAL_ROOTS`
environment variable. Explicit `--roots` takes precedence; empty environment
entries are ignored. There are no built-in roots. If neither option supplies
any roots, the builder exits 2 with guidance and creates no dataset. For example:

```bash
python3 eval/jev-phase0/build_dataset.py --roots /path/to/project/.orchestra --stats-only
```

The default output directory is
`${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/jev-eval`. To isolate a run,
set `CC_ORCH_STATE_DIR` to an absolute directory outside every Git worktree.
Every private artifact is checked before creation, including symlink targets,
registered sibling worktrees and cache entries. Git is queried read-only.
Task discovery uses direct children, skips the literal child `wt`, follows
task symlinks and reports realpath collisions. Builder stdout contains counts
and a timestamp, never historical text. Configured roots that are missing
contribute zero records.

Have Codex propose labels from the private worklist and have the lead label it
independently. Each private proposal/adjudication JSONL row is:

```json
{"reason_id":"example/task#r01","reason_sha256":"copy the hash from the worklist","category":"other","evidence_span":"exact substring of the reason"}
```

Allowed categories are `criterion-unverifiable`, `repo-fact-mismatch`,
`scope-overlap`, `process`, `other`, and `ambiguous`. Evidence is a verbatim span,
without adding quotation characters that are absent from the source. The two
sets must cover all reasons. Only headings containing `amendment` select plan
sections; each section ends at the next heading. A section's own heading decides
whether it is an audit amendment or a mid-task/process amendment. Structural
ancestor headings never affect that decision. Process amendment sections are
excluded from reasons. Enumerated sections emit their items and preceding
substantive prose paragraphs as separate reasons. Empty, punctuation-only or
heading-restatement preambles are discarded; prose-only sections emit one reason. Disagreements
retain both labels and become ambiguous. Final labels preserve source path and line.
Copy each worklist entry's `reason_sha256` unchanged into both independent label
files. Ingestion and scoring compare it with the SHA-256 hash of the current
reason text. Missing hashes, changed reasons, and labels for absent reason IDs
abort scoring; regenerate and review labels after rebuilding a changed dataset.

```bash
EVAL_DIR="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/jev-eval"
python3 eval/jev-phase0/labels.py --ingest \
  --proposal "$EVAL_DIR/proposal.jsonl" --adjudication "$EVAL_DIR/adjudication.jsonl"
python3 eval/jev-phase0/run_eval.py --dry-run
python3 eval/jev-phase0/run_eval.py --mode mock --task both
python3 eval/jev-phase0/score.py
```

Only the agreement note may be written inside the checkout. Its default is
`eval/jev-phase0/agreement-note.md`, and it contains counts, agreement rate and
kappa without any evidence spans or task identities. The worklist, labels,
dataset, responses, cache and score report must stay outside the checkout.
The report prints only aggregate results. All mock reports explicitly deny
being enablement decisions. Do not commit any historical data or per-task
outputs. The tracked injection set is entirely hand-written.

The driver uses `lint` requests for the dataset and `scan` requests for the
tracked synthetic set. `--limit` limits the combined sequence (lint first).
Cache keys include adapter version, task, execution mode and exact input text.
A rerun reconstructs the same responses from successful cached calls; cache
hits do not consume the live rate limit. The default is 60 requests/minute,
with a hard maximum of 300. Dry-run sends nothing and writes nothing; it reports
the candidate request count, secret-skip count, and gross input cost for
sendable text, without discounting cached requests. The estimate uses
`len(text)/4` input tokens at $0.042 per million, excluding output costs.
The scanner's secret-shaped literal rule runs before every request, including
mock requests. It records only the first matching line number, never the match.

## Stage 2 adapter contract

Only `adapter.py` needs a transport implementation. The public functions are
`lint_brief(brief_text, *, mode)` and `scan_text(text, *, mode)`. Both return
`flagged`, a finite normalized `score` between zero and one, `raw`, and
`findings`. `raw` and `findings` must never include credentials. Stage 2 should
write temporary inputs, invoke `bin/orch-jev lint-brief <tmpfile>` or
`bin/orch-jev scan <tmpfile>` via `subprocess.run` with a timeout, normalize
stdout, and remove temporary files. Increment `ADAPTER_VERSION` whenever
transport, parsing or score semantics change. The driver owns privacy gates,
cache and request spacing; the scorer owns thresholds.

For now, live functions raise `AdapterNotReady`. Live CLI mode requires both
`--mode live` and `--live`; only `--live` permits reading `TYPESAFE_API_KEY`.
This implementation makes no live calls. After Stage 2 lands, the authorized
operator can run:

```bash
python3 eval/jev-phase0/run_eval.py --mode live --live --dry-run
python3 eval/jev-phase0/run_eval.py --mode live --live --task both --rpm 60
python3 eval/jev-phase0/score.py
```

The frozen protocol specifies eligibility, abstentions, paired bootstrap
intervals, operating points and decision precedence in `criteria.md`. The
bootstrap seed is 20260921 with 2000 replicates. RISK source lines are preserved,
including repeated plan/summary events; agreement definitions and the minimum
of five escalation events are stated in that protocol.
