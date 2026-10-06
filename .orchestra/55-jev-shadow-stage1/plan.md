# Plan: Jev shadow Stage 1 review   (lead-alpha)

## Baseline

- Repo/clone: `/home/janghun/.claude/orchestra-state/worktrees/cc-orchestra/self-hosting-55`, branch
  `orch/55-jev-shadow-stage1`, GIT MODE inplace (as briefed). HEAD at start `359c121b1d13e6fc22001fb0e7dbd8c25c7b4f17`
  (= `origin/local/installed-main`; `git diff origin/local/installed-main..HEAD --stat` is empty). Tree clean.
- `bash tests/test-jev-eval.sh` → `PASS: 17 jev-eval test groups` (rc 0). `bash tests/test-jev.sh` → `OK`,
  `JEV-TESTS: 0 test(s) skipped — none` (rc 0). Python 3.13.12.
- Real log (private, mode 600, read-only for this task): `/home/janghun/.claude/orchestra-state/codex-shadow.jsonl`,
  240745 bytes, mtime `2026-10-03 12:42:13.863064967 +0900`,
  sha256 `1c6a58ec07f3dafafbce8aa6554cf94766fa0e2d77fb34d1ee5c7668cd4491c0`.

## Findings (scoping only — no criterion statistic has been computed)

- `eval/jev-shadow-decision.md` (commit 8d12ee6, 2026-09-22) defines criteria 1-4 and the verdicts. Shadow logging
  was enabled by commit `67a36d0` at `2026-09-22 07:01:55 +0900`.
- Record schema: `bin/orch-jev:518-532` (`SHADOW_KEYS`, `SHADOW_TYPES`). `reasoning` is Jev's Noul probability
  (float), `difficulty` one of `mechanical|routine|involved|novel` (`bin/orch-jev:53`), `difficulty_confidence` float.
  `observation` is set by `shadow_observe` (`bin/orch-jev:643-700`); `shadow_observe` also runs for records whose
  `status` is `skipped:unreadable` etc., so `observation=exact` does not imply a Jev answer.
- Threshold `JEV_SHADOW_MIN_CONFIDENCE=0.6` in both the clone's and the installed `jev-policy.conf`.
- Scoping counts I re-derived (they match Tier 1): 324 well-formed records, 0 malformed; 98 `mode=implement`
  (226 `resume`); of implement, 84 `status=ok` (others: skipped:explicit-flags 8, dry-run 3, unreadable 2,
  invalid-args 1); of ok, 78 `observation=exact`, 6 `ambiguous`. 2 implement records are `exact` with a non-ok status
  (no Jev answer). Difficulty among the 78: involved 63, routine 6, mechanical 5, novel 4. No null `reasoning`,
  `duration_ms`, `codex_exit`, `attempts`, `difficulty_confidence` among the 78. All records' timestamps span
  `2026-09-21T22:00:50Z` .. `2026-10-03T03:42:13Z` (UTC).

## Analysis plan (pre-registered — fixed before any criterion is computed on the real log)

Every interpretive choice the decision document leaves open is fixed here. Nothing below may be changed after the
real-log run; a correction would go into an appended, dated amendment.

A. **Population.** "Exact-observed records" = records with `mode == "implement"`, `status == "ok"` and
   `observation == "exact"`. A record of that population is *excluded* (and counted as excluded) if any of these is not
   valid: `reasoning` finite number (int/float, not bool); `duration_ms` int >= 0 (not bool); `codex_exit` int (not
   bool); `attempts` int >= 0 (not bool); `difficulty` string; `difficulty_confidence` finite number (not bool).
   The analysed set has size `n`. "All other records" in criterion 4 = analysed records not in the mechanical group.
   Implement records that are `exact` but not `ok` are reported as a count only and are not analysed. Malformed lines
   (invalid JSON or not an object) are counted, never fatal.

B. **Criterion 1 — "14 days of use".** Primary reading: calendar days from the enabling commit date 2026-09-22 to the
   review date 2026-10-06 (`(review − enabled).days`, = 14 with the defaults); met iff >= 14 **and** `n >= 30`. Both
   dates are constants with flags `--enabled-date` / `--review-date` (defaults 2026-09-22 / 2026-10-06) — never the
   current clock, so the output is deterministic. Alternative reading, reported alongside: first-to-last record span
   over **all well-formed records in the log** (any mode/status), in days as `(max − min timestamp seconds) / 86400`
   (2 decimals), met iff >= 14 and `n >= 30`. The script also prints the verdict that would result under the
   alternative reading, so "would it change the verdict" is answered mechanically.

C. **Criterion 2 — signal.** Spearman rho between `reasoning` and `duration_ms` over the analysed set: average
   (1-based) ranks for ties, rho = Pearson correlation of the two rank vectors; undefined if either rank vector has
   zero variance. Bootstrap: `random.Random(20261006)`; 10,000 resamples; each resample draws `n` record indices with
   `rng.randrange(n)` (records resampled as (reasoning, duration_ms) pairs); undefined resample rhos are dropped and
   counted. Percentile 95% interval over the `B` defined values sorted ascending `s`:
   lower = `s[int(0.025 * B)]`, upper = `s[int(0.975 * B) - 1]` (for B = 10000: s[250], s[9749]).
   Met iff rho >= 0.30 and the interval excludes 0 (lower > 0 or upper < 0). Not met if rho is undefined or the
   rule fails. Insufficient iff `n < 10`.

D. **Criterion 3 — savings potential.** Numerator = analysed records with `difficulty == "mechanical"` and
   `difficulty_confidence >= JEV_SHADOW_MIN_CONFIDENCE`, the value read from `jev-policy.conf` at analysis time
   (default: the repo's `jev-policy.conf`; `--policy` overrides). This uses the raw answer, not the stored
   `suggested_*` fields, matching `shadow-report`'s re-mapping. Share = numerator / n; met iff share >= 0.20.
   Insufficient iff `n < 10`.

E. **Criterion 4 — no hidden risk.** Mechanical group = exactly the criterion-3 numerator records. Other group = the
   rest of the analysed set. Failure-or-retry = `codex_exit != 0 or attempts > 1`. Met iff
   rate(mechanical) <= rate(other) ("not higher"). **Insufficient** if either group holds fewer than 10 records —
   never met. Rates printed with their group sizes. Informational only (no effect on any verdict): count of analysed
   records with `difficulty == "mechanical"` regardless of confidence.

F. **Verdict (mechanical, literal).** If criterion 1 is not met → `inconclusive`. Else if any of criteria 2-4 is
   `not met` → `do not adopt`. Else if all of 2-4 are `met` → `proceed to Stage 2 discussion`. Else (some
   `insufficient`, none `not met`) → `inconclusive`. Rationale: the document says "any not met with enough data →
   do not adopt"; "enough data" is criterion 1 (whose failure the document itself maps to `inconclusive`), while a
   criterion-4 group below 10 is reported as insufficient and cannot be counted as met. A pass never authorises a
   model switch; no configuration is changed by this task regardless of verdict.

G0. **Degenerate inputs.** Empty or all-malformed log → n = 0: criteria 2-4 `insufficient`, criterion 1 not met,
   verdict `inconclusive`, exit 0. Fewer than 2 parseable record timestamps (`datetime.fromisoformat`; unparseable
   ones are skipped and counted) → span prints `n/a` and the alternative reading of criterion 1 is not met. Zero
   defined bootstrap resamples → interval prints `undefined` and criterion 2 is `not met` (when n >= 10).

G. **Numerics and output.** Thresholds are compared on unrounded values; rho and interval bounds print with 4
   decimals, shares/rates as `k/n (x.x%)`. Output is aggregate only: no ids, thread ids, timestamps of individual
   records, task names or per-record rows. Repeated runs on the same inputs are byte-identical.

## Approach

`eval/jev-shadow-stage1/analyze.py` (stdlib only) implements A-G as pure functions plus a `main`. A synthetic test
`tests/test-jev-stage1.sh` drives it. Codex writes the code and tests against synthetic data only (it cannot read the
private log). After my diff review and commit, **I** run `analyze.py` against the real log, save its stdout
(aggregate only) to `<task-dir>/evidence/real-run.txt`, then the same Codex thread writes
`report-2026-10-06.md` and the appended section of `eval/jev-shadow-decision.md` from that file.

## Rejected

- Reusing `orch-jev shadow-report` output: it prints counts per tier but none of the statistics (Spearman, bootstrap)
  and applies the `none` tier differently; the doc names it plus direct log fields — analyze.py reads the fields.
- Wall-clock review date: makes output non-deterministic. Rejected.
- numpy/scipy: brief requires stdlib only.

## Changes

1. `eval/jev-shadow-stage1/analyze.py` (new). CLI:
   `python3 eval/jev-shadow-stage1/analyze.py [--log PATH] [--policy PATH] [--enabled-date YYYY-MM-DD] [--review-date YYYY-MM-DD]`.
   Log path precedence: `--log`, then env `JEV_STAGE1_LOG`, then `<state>/<JEV_SHADOW_LOG from policy>` (relative
   paths resolved under `<state>`; `<state>` = env `CC_ORCH_STATE_DIR` or `~/.claude/orchestra-state`), i.e. the same
   default as `orch-jev`. Policy default: `<repo root>/jev-policy.conf` resolved from `__file__`. Parse policy lines
   `KEY=VALUE` (strip surrounding double quotes, ignore blank/comment lines). Opens the log read-only, never writes
   any file, no network, no subprocess. Exit 0 on success (any verdict); exit 2 with one stderr line on unreadable
   log/policy, bad flag or date. Expose importable functions at least: `average_ranks(values)`,
   `spearman(xs, ys)` (returns float or None), `bootstrap_interval(pairs, seed=20261006, resamples=10000)` (returns
   (lower, upper, undefined_count)), `evaluate(records, threshold, enabled_date, review_date)` (returns a dict of
   per-criterion results and verdicts), `render(...)`. Output lines (exact labels; values illustrative):
   ```
   Jev shadow Stage 1 review — criteria from eval/jev-shadow-decision.md
   log: <path>
   log sha256: <hex>
   policy: <path> · JEV_SHADOW_MIN_CONFIDENCE=0.6
   records: <N> · malformed lines: <M>
   population: implement <a> · implement+ok <b> · analysed (implement, ok, exact) <n> · excluded (invalid fields) <e> · exact but not ok (not analysed) <c>
   criterion 1 sufficiency: days 2026-09-22 -> 2026-10-06 = 14 (>= 14) · records <n> (>= 30) -> met
     alternative reading: first-to-last record span = 11.24 days (>= 14) -> not met
   criterion 2 signal: n <n> · spearman(reasoning, duration_ms) = 0.1234 (>= 0.30) · 95% bootstrap interval [0.0123, 0.2345] (10000 resamples, seed 20261006, undefined 0) · excludes 0: yes -> not met
   criterion 3 savings potential: mechanical with confidence >= 0.6: <k>/<n> (x.x%) (>= 20%) -> not met
   criterion 4 no hidden risk: failure-or-retry mechanical <f>/<m> (x.x%) vs other <g>/<o> (y.y%) (each group >= 10; mechanical not higher) -> insufficient
     informational: analysed records with difficulty mechanical regardless of confidence = <q>
   verdict: <proceed to Stage 2 discussion | do not adopt | inconclusive>
   verdict under the alternative 14-day reading: <...>
   limit: the log cannot show whether a cheaper model would have succeeded; a pass never authorises a model switch.
   ```
   Undefined rho prints `undefined`; an empty group prints `0/0 (n/a)`.
2. `eval/jev-shadow-stage1/README.md` (new, short): purpose, the command, the pre-registered choices A-G in brief
   (pointing to the decision doc), privacy rule (aggregate only; per-record working files never inside a worktree),
   the test command.
3. `tests/test-jev-stage1.sh` (new; may embed a python heredoc like `tests/test-jev-eval.sh`, or add
   `tests/test-jev-stage1.py`). Synthetic fixtures written under a `mktemp -d` dir; always passes `--log` and
   `--policy` (a fixture policy) and sets `CC_ORCH_STATE_DIR` to the temp dir so the real log is never touched. Must
   cover (each an assertion that would fail against a wrong implementation):
   - `average_ranks([10, 20, 20, 30]) == [1, 2.5, 2.5, 4]`; Spearman with ties equals a hand-computed value to 1e-12
     (e.g. xs=[1,2,2,3,4], ys=[2,1,3,3,5]); `spearman` returns None for a constant vector.
   - Bootstrap determinism: two `bootstrap_interval` calls give identical tuples; two CLI runs give byte-identical
     stdout.
   - Bootstrap correctness: the test re-implements procedure C independently (seeded `random.Random`, `randrange`
     draws, its own rank/Pearson code) for a small fixture with a modest resample count (e.g. 200) and asserts
     `bootstrap_interval(..., resamples=200)` returns the same (lower, upper, undefined) — so a fixed or wrong interval
     fails. Also a fixture whose resamples include constant vectors asserts a non-zero undefined count.
   - Separate not-met fixtures per criterion, each otherwise passing: (2a) rho < 0.30; (2b) rho >= 0.30 but the
     interval contains 0 (small noisy sample) — or, if hard to construct, a unit test on the decision function with
     a supplied interval; (3) confident mechanical share < 20% (with a C4-sized group made of other tiers so only C3
     fails is not required — C3 failing alone is enough); (4a) mechanical failure rate higher via `codex_exit != 0`
     only; (4b) higher via `attempts > 1` only. Each → that criterion `not met`, verdict `do not adopt`.
   - Degenerate: empty log file → exit 0, `verdict: inconclusive`; constant `reasoning` → rho `undefined`.
   - Met fixture (>= 30 analysed, >= 20% confident mechanical, both C4 groups >= 10, strong positive monotone
     reasoning/duration, mechanical rate <= other) → all four `met`, `verdict: proceed to Stage 2 discussion`.
   - Not-met fixture (enough data, mechanical share < 20% or mechanical failure rate higher) → `do not adopt`.
   - Insufficient-group fixture (criteria 1-3 met, mechanical group 5..9) → criterion 4 `insufficient`,
     `verdict: inconclusive`.
   - Criterion-1 fixture (< 30 analysed) → `inconclusive`; and a fixture whose record span < 14 days shows the
     alternative-reading verdict differing from the primary.
   - Population filter: resume, non-ok, ambiguous records and an invalid-field record do not enter `n`; the
     excluded count is printed.
   - Privacy: stdout contains none of the fixtures' `id` / `thread_id` strings; fixture log sha256 unchanged after runs.
4. `eval/jev-shadow-stage1/report-2026-10-06.md` (new, written after the real run, from `<task-dir>/evidence/real-run.txt`
   only): aggregate numbers for criteria 1-4, both readings of "14 days" and the alternative verdict, the
   confident-mechanical count and share, failure-or-retry rates with group sizes, the verdict, the analysis-plan
   commit SHA, the log sha256, the command, and a plain statement that the log cannot show whether a cheaper model
   would have succeeded. States that turning shadow off (as the document prescribes for `do not adopt` /
   final `inconclusive`) is a separate change awaiting user approval and was not done.
5. `eval/jev-shadow-decision.md`: append only, at the end, a section `## 2026-10-06: Stage 1 result` with the verdict
   and a link to `jev-shadow-stage1/report-2026-10-06.md`. No existing line changes.
6. `.orchestra/55-jev-shadow-stage1/plan.md` (this file) is committed (force-added; `.orchestra/` is excluded via
   `.git/info/exclude`) because acceptance criterion 1 requires the analysis plan to be committed before the real run.

## Do not touch

`jev-policy.conf`, `bin/orch-jev`, any routing/dispatch file, the real log, any file not listed in Changes,
`/home/janghun/cc-orchestra`, `./install.sh`.

## Tests

`bash tests/test-jev-stage1.sh` (new), plus existing `bash tests/test-jev-eval.sh` and `bash tests/test-jev.sh`.

## Verification

Codex-runnable (synthetic data only):
1. `bash tests/test-jev-stage1.sh` → exit 0.
2. `bash tests/test-jev-eval.sh` and `bash tests/test-jev.sh` → exit 0.
3. `python3 -m py_compile eval/jev-shadow-stage1/analyze.py`; `grep -E '^(import|from) ' eval/jev-shadow-stage1/analyze.py`
   shows stdlib modules only.
4. Running analyze.py twice on a synthetic log (`--log`, `--policy` to fixtures) gives byte-identical stdout.
5. `git diff origin/local/installed-main..HEAD --stat` lists only: `eval/jev-shadow-stage1/{analyze.py,README.md,report-2026-10-06.md}`,
   `tests/test-jev-stage1.sh` (+ optional `tests/test-jev-stage1.py`), `eval/jev-shadow-decision.md`,
   `.orchestra/55-jev-shadow-stage1/plan.md`. `git diff origin/local/installed-main..HEAD -- jev-policy.conf` empty.
   `git diff origin/local/installed-main..HEAD -- eval/jev-shadow-decision.md | grep '^-' | grep -v '^---'` empty and all
   `+` lines come after the original last line.
6. The commit that first adds `.orchestra/55-jev-shadow-stage1/plan.md` (with section "Analysis plan") is an
   ancestor of the commit that adds `report-2026-10-06.md`.
7. The report contains no per-record rows/ids (inspect), and its numbers equal the corresponding lines of
   `.orchestra/55-jev-shadow-stage1/evidence/real-run.txt`.

## Verification — delegated to verifier-normal

The real log is outside the Codex sandbox; Codex does not run or grade these.
- R1 (acceptance 2, real data): `python3 eval/jev-shadow-stage1/analyze.py` (default path = real log) run twice →
  byte-identical stdout, all criterion lines and the verdict line present; output equals `evidence/real-run.txt`.
- R2 (acceptance 3): every number in `eval/jev-shadow-stage1/report-2026-10-06.md` matches that output.
- R0 (acceptance 1): `.orchestra/55-jev-shadow-stage1/evidence/pre-run.txt`, written by the lead immediately before
  the first real-log run, records the date/time, `HEAD`, the analysis-plan commit SHA, and the sha256 of the
  "## Analysis plan" section both in that commit (`git show <sha>:.orchestra/55-jev-shadow-stage1/plan.md`) and in
  the working tree; the two hashes must match, and the plan commit must be HEAD or an ancestor of HEAD at run time.
  The real-run output file's mtime must be later than the plan commit's committer date.
- R3 (acceptance 6): `sha256sum` and `stat -c %y` of `/home/janghun/.claude/orchestra-state/codex-shadow.jsonl`
  equal the Baseline values above after the runs.

## Risks

- Accidental privacy leak in output/report → privacy assertion in tests, my review of the report text.
- Float nondeterminism: none expected (fixed order sums, seeded MT); verified by repeated runs.
- `.orchestra/` commit is unusual for this repo (excluded locally); only plan.md is added, flagged in the summary.

## Cross-check (plan-review-codex.md, ISSUES 3)

- MUST "test statistical correctness beyond repeatability" → accepted: added the independent bootstrap re-computation
  test and per-criterion not-met fixtures (Changes 3).
- MUST "verify commitment before execution" → accepted: added `evidence/pre-run.txt` and delegated check R0.
- CONSIDER "degenerate inputs" → accepted: added G0 and the degenerate tests.

## Running record

- 2026-10-06: Phase A scoping done; baselines green; dispatch=codex-first.
