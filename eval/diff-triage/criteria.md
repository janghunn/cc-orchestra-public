# Frozen criteria: offline diff risk-triage evaluation

**Frozen pre-registration.** This file must be committed alone before any
real-corpus scoring. The lead creates and records that commit; the evaluation
records its SHA. These criteria are fixed before observing scorer results.

The question is whether ranking files in a diff helps a lead read defective files
earlier. Any verdict, including `worth designing an advisory hint`, authorises no
gate, no change to review policy and no runtime change. A hint would only be an
input to the lead.

## Population and independent unit

The population is the recoverable subset of findings in
`eval/gate-ab/tabulation.csv`, linked to git history by
`eval/diff-triage/manifest.tsv`. Use one diff per task: the manifest's base commit
to its round-1 gated head, with `head_round = r1`. Do not treat successive rounds
of a task as independent diffs. The clean control S24 is not included because it
has no defect.

Manifest statuses are `P` (protocol base/head evidence), `G` (gate or summary SHA
evidence), `H` (history-only candidate) and `U` (head not recoverable). Commit
identifiers must resolve unambiguously to full SHAs. Each recoverable diff's fix
is the first commit after head on the task's history whose subject starts with
`fix(`; it must satisfy `git merge-base --is-ancestor head fix`.

Exclude rows before file mapping, counting each exclusion by reason in this
order:

1. Design-stage rows: `design-stage`.
2. Rows with disposition `rejected`: `rejected`.
3. Tasks absent from the manifest: `task-not-in-manifest`.
4. Manifest status `U`: `head-not-recoverable`.
5. Rows not first reported at the gated head (`first_round != head_round`),
   including later-round and post-merge findings:
   `not-first-reported-at-head`. Their presence at that head is unproven.

Only eligible diff-stage findings first reported at the head supply labels.
Accepted findings are eligible; rejected findings are not.

## File evidence and confidence

Let F be the head diff's file set from `git diff --name-only -M base head`, using
head-side paths. Intersect all file evidence with F.

**E1 citation:** extract repository-relative paths only from the cited line
ranges of existing source files. Sources are semicolon-separated references
resolved as `$GATE_AB_ROOT/<path>`; `path:N` selects line N and `path:N-M` selects
lines N through M inclusive. Use this path regex, strip any trailing `:line`, and
retain only paths in F:

```text
(?<![\w./-])((?:[\w.-]+/)*[\w.-]+\.(?:py|sh|md|json|jsonl|conf|toml|yml|yaml|txt|csv)|bin/[\w.-]+|hooks/[\w.-]+)(?::\d+)?
```

Missing source files contribute no evidence and are counted. Sources without a
line bound feed E1-unbounded, never E1; they can support only low confidence.

**E2 fix:** inspect `git diff -M head fix`. For each changed file in F,
E2-strong means its patch removes or modifies text present at head: at least one
removed content line (`-`, excluding the `---` file header). E2-weak means pure
additions. This distinction depends on patch shape, not path class.

Assign each eligible row files and confidence using the first matching rule:

1. If E1 ∩ (E2-strong ∪ E2-weak) is non-empty, use that intersection: `high`.
2. Otherwise, if E2-strong is non-empty, use E2-strong: `medium`. This is
   fix-derived and row-imprecise when a fix bundles several findings; the
   diff-level union is exact for that round.
3. Otherwise, if E1 is non-empty, use E1: `low`, because the citation lacks fix
   corroboration.
4. Otherwise, if E2-weak ∪ (E1-unbounded ∩ F) is non-empty, use those files: `low`.
5. Otherwise exclude the row: `no-in-diff-file-evidence`.

For manifest status `H`, cap the resulting confidence at `low`.

## Ranking universes and strata

Scorers see and score every file in F, including tests. S2's coverage feature
uses test changes in the same diff. For the primary evaluation, restrict each
arm's order to F' = F minus test-path files, preserving relative order. The test
path rule is the first class rule in S2 below. Regression-test rewrites extend
coverage and do not establish that the test file was defective.

| Stratum | Ranking universe | Defective file set |
|---|---|---|
| Primary | F' | D = (union of files from high- and medium-confidence rows) ∩ F' |
| High-only, descriptive | F' | D_h = (union of files from high-confidence rows) ∩ F' |
| Sensitivity, descriptive | F, including tests | D' = union of files from all mapped rows, including low confidence |

A diff is usable in a stratum if and only if N = size of that stratum's universe
is at least 3 and its defective set satisfies 1 ≤ |D| < N (using D_h or D' for
the corresponding stratum). Assess usability separately for each stratum.

The verdict uses primary diffs only. Sensitivity, high-only and series J/C/S
groups are descriptive. Report usable counts separately; series groups do not
provide independent evidence for a verdict.

## Scorer input and leakage boundary

Scorers receive only canonical JSON bytes built from `(repo, base, head)`, never
tabulation text, source reports, fix commits, labels or later history. All inputs
are built and scored before evaluation labels are read.

The input schema is `diff-triage-input/1`, with a `files` array sorted by path.
Each file has `path`, `old_path` (null unless renamed), `status`, `added`,
`removed`, `binary` and `patch`. Use rename-aware git diffs, with external diff
and text conversion disabled, and three context lines for patches. Include
`diff --git` headers; decode patch text as UTF-8 with replacement for errors.
Binary files have `added = removed = 0`, `binary = true` and an empty patch.
Serialize with
`json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")`.
No commit SHAs, case IDs or task names are added to the input.

## Arms and ordering

S0 is seeded random order; S1 is change size; S2 is the deterministic heuristic;
S3 is an optional local-model scorer. Candidates are S2 and, only if run for
real, S3. A skipped S3 is reported as `S3 skipped: <reason>`, never as a result,
and is excluded from candidate comparisons and verdicts.

**S1:** score = added + removed lines; binary files score 0.

**S2:** integer score = class + logic + security + policy − covered.

Class uses the first matching row:

| Class | Path rule | Value |
|---|---|---|
| Test | Prefix `tests/` or `test/`, or basename matching `test_*`, `test-*`, `*_test.*`, `*.test.*` | 0 |
| Runtime | Prefix `bin/`, `hooks/`, `lib/`; or basename in {`guardrails.json`, `install.sh`, `build-roster.sh`, `build-roster-runtime.sh`, `sync-to.sh`}; or basename containing `policy` with extension `.conf` or `.json` | 3 |
| Prompt | Prefix `agents/`, `templates/`, `skills/` | 1 |
| Docs | Extension `.md`, `.txt`, `.rst`, `.ko.md` | 0 |
| Code | Extension `.py`, `.sh`, `.js`, `.ts`, `.go`, `.rs`, `.rb`, `.pl`, `.bash` | 2 |
| Config | Extension `.json`, `.jsonl`, `.conf`, `.toml`, `.yml`, `.yaml`, `.ini`, `.cfg` | 1 |
| Other | Anything else | 1 |

Logic applies only to runtime, code, test and config classes. Count added patch
lines (`+`, excluding `+++` headers) whose content after stripping is non-blank
and does not start with `#`, `//`, `/*`, `*`, `--` or `;`. Add 1 if the count is
at least 1, and 1 more if it is at least 20. Docs, prompt and other classes get 0.

Security adds 1 if any added content line matches this case-insensitive regex:

```text
\b(subprocess|shell=True|os\.system|eval|exec|chmod|chown|sudo|rm\s+-rf|curl|wget|socket|token|secret|password|credential|api[_-]?key|permission|allow|deny|sandbox|guard)\b|--force
```

Policy adds 1 if the basename contains `policy` or equals `guardrails.json`.

Covered is 1 if the file is not a test path and some test-path file in the same
diff has an added content line containing this file's stem (basename up to the
first `.`), with stem length at least 3. Otherwise covered is 0.

**S3:** score = P(A), in [0, 1], for the local Choice prompt
`A = yes, read this file first / B = no`. The prompt contains only that file's
path and patch, with the patch truncated to 12000 characters. Use the existing
pinned Qwen3-8B local setup only if the model and `llama-server` already exist
and a GPU has at least 12288 MiB free. Start and stop a task-owned server on that
GPU with a task-private AF_UNIX socket; terminate only its PID. No network
contact of any kind is permitted; the sole permitted socket is the AF_UNIX
client to that server. Run the real evaluation under `unshare -rn`.

Order scored arms by descending score, breaking ties by descending S1 score and
then ascending path in byte order. S1's own ties use ascending path. Each arm
yields a strict total order.

**S0:** seed = 20260921. For each r in 0..999, order files by the ascending hex
digest of
`sha256(f"{seed}:{r}:{path}".encode() + sha256(input_bytes).digest())`, breaking
equal-key ties by ascending path in byte order. Restrict each order to the
stratum's universe before computing metrics. S0's per-diff metric is the mean
of that metric across all 1000 orders.

## Metrics and paired comparisons

For each usable diff, N is the number of files in its ranking universe and D
is its defective set. Set k20 = max(1, ceil(0.2·N)). Compute:

- recall@k = |D ∩ top-k| / |D| for k in {1, 3, k20}, capping k at N.
- First rank: the 1-based rank of the first defective file.
- Normalized first rank = (first rank − 1) / (N − |D|).

The primary metric is **recall@k20**. All other metrics are descriptive.
Aggregate metrics by an equally weighted mean over usable diffs, not over
findings or files.

For primary comparisons, use a paired bootstrap over usable primary diffs:
seed 20260921, 2000 replicates, sampling diff indices with replacement using
`random.Random(seed)` and `choices`. Use the same sampled indices for every
arm. The statistic is mean candidate − mean reference in recall@k20. Compare
each candidate against S1 and against S0, using S0's per-diff mean metrics.

The 95% confidence interval is the 2.5th and 97.5th percentiles of the sorted
replicate values with linear interpolation: for percentile fraction p and B
replicates, h = (B − 1)·p, interpolate between indices floor(h) and ceil(h).
The reported mean delta uses the original usable diffs.

Report groups `primary`, `sensitivity`, `series J`, `series C` and `series S`;
non-primary comparisons remain descriptive. For any group with fewer than
10 usable diffs, print `INSUFFICIENT DATA` instead of confidence intervals.

## Verdict precedence

Apply the first matching rule using only primary recall@k20 comparisons:

1. Fewer than 10 usable primary diffs → `inconclusive`, with reason
   `fewer than 10 usable diffs`.
2. Some candidate has mean Δ(candidate − S1) ≥ 0.10 **and**
   CI-low(candidate − S1) > 0 **and** CI-low(candidate − S0) > 0 →
   `worth designing an advisory hint`.
3. Every candidate has CI-high(candidate − S1) < 0.10 → `do not build`.
4. Otherwise → `inconclusive`.

No verdict authorises a gate, a review-policy change or a runtime change. Any
future hint would only be an input to the lead.
