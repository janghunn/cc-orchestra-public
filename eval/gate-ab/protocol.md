# Pre-registered gate A/B protocol

## Purpose and status — 2026-09-30

This protocol is fixed before any run or result from this A/B. It specifies two separate replay experiments to inform the default `implement` lane and the default Phase A investigation mode. The historical defect table is selection and ground-truth evidence, not an A/B result. Do not change policy from this protocol alone. Record any later amendment, timestamp, reason, and the data seen before making it; never silently change a threshold after reading quality results.

The source tree is `/home/janghun/cc-orchestra`. The historical corpus is `/home/janghun/.claude/orchestra-state/worktrees/cc-orchestra`; its `eval/gate-ab/tabulation.csv` is in this repository. Runs, transcripts, labels, and scores go in a **new** `.orchestra/<NN>-gate-ab-run/` directory, called `$AB` below. This document is a design; no arm has been run here.

## Hypotheses and nulls

* **H-impl:** with an identical frozen brief, plan, and base tree, a Claude developer arm ships fewer ground-truth defects than Codex Astra at no worse acceptance. **Null:** neither Claude arm meets the fixed quality, acceptance, and cost thresholds below.
* **H-inv:** the normal Opus lead investigating by itself produces a plan covering more rubric items than the same lead using `codex-run investigate`, and the gain justifies its Claude 5-hour-session cost. **Null:** the self-investigating arm misses the rubric or cost threshold below.

These are task-level, paired replay comparisons. They do not estimate the defect rate of all future tasks.

## Arms and deployed settings

| Code | Run | Model and effort | Input |
|---|---|---|---|
| X | `~/.claude/orchestra/bin/codex-run-runtime implement <clone> <task-dir> --model astra --effort xhigh` | Astra, xhigh | Base tree, frozen brief and plan; wrapper's standard implement prompt |
| S | `claude -p --agent dev-1 --effort high` | `sonnet[1m]`, high | Same tree, brief and plan; Phase C dev prompt below |
| O | `claude -p --agent dev-opus-1 --effort high` | `opus[1m]`, high | Same tree, brief and plan; same Phase C prompt |
| L-codex | `claude -p --agent route-lead-delta-normal --effort high` | `opus[1m]`, high | Base tree and brief; Phase A must call `codex-run investigate` |
| L-self | same lead agent and effort | `opus[1m]`, high | Same base tree and brief; `codex-run` forbidden, Read/Grep/Glob/Bash only |

Verify actual model and effort in each Claude session transcript and Codex event stream. **2026-09-30 routing note:** this task's own wrapper runs resolved to `gpt-6-sol` while Codex weekly usage was around 70%. X therefore passes `--model astra` explicitly and is valid only when its event stream shows `gpt-6-astra`. If Astra cannot be obtained, X waits for availability; Sol is never substituted. A run with a wrong model, effort, missing input, path leak, or unauthorized tool is invalid and replaced before scoring. Fix the prompt/fixture only through a dated amendment applied to every arm for that task.

The Phase C prompt from `templates/lead.md.tpl` is used **verbatim**, with `<abs>` and `<explicit list>` filled from each case's frozen plan (one case-specific list, identical for S and O):

> You are implementing the spec at `<abs>/plan.md`.
> Work in this checkout: `<abs worktree or repo path>` — all edits happen there.
> Your scope is exactly these files: `<explicit list>`.
> Do not run any git command that writes (commit, push, branch, switch, restore, stash) —
> I own the commits for this task.
> Write your report to `<abs>/impl-report-devN.md`. Follow your standard procedure.

The lead running the experiment fills `<abs>/plan.md` and `<abs worktree or repo path>` with the clone and task-dir absolute paths, `<explicit list>` with the plan's Changes list, and `devN` with the arm-local report name. There is no extra coding hint. This is **lane-as-deployed parity**, not prompt parity: X receives its production wrapper prompt; S and O receive the production dev instruction and their installed agent profiles. The installed dev profiles disallow `Agent` but permit `Edit`, so both Claude implementer arms allow `Edit` in step 5. Record hashes of the wrapper, template, agent profiles, CLI versions, and policy files at start.

For investigator arms, add one bounded instruction to the same lead profile: perform Phases A0, A, A1, B only; write `plan.md`; stop before B1, implementation, review, or gates. L-codex must make at least one substantive `codex-run investigate <clone> <task-dir> "<question>"` call in Phase A. L-self must not call `codex-run`, `codex`, another agent, or another model; its only tools are Read, Grep, Glob, and Bash, and it writes `plan.md` through Bash. The run is invalid if the transcript violates its arm rule. The fixed question is: “Investigate the brief's requested change, relevant code paths, existing tests, failure cases, and integration risks; design a complete plan with verification. Stop after Phase B.”

## Selection and frozen inputs

Eligibility requires a recoverable `brief.md`, a plan that can be frozen before implementation, a base commit and historical defect-bearing HEAD present in `/home/janghun/cc-orchestra` (`git cat-file -e '<sha>^{commit}'`), and at least one gate-caught diff defect in the final `eval/gate-ab/tabulation.csv`, the sole ground-truth source. Add one clean-first-pass task as a false-positive control. The table below gives verified, existing abbreviated SHAs; the setup step resolves them to full SHAs and aborts on ambiguity. `head` identifies the **historical first defective diff**, used to extract hidden regressions and to confirm selection; implementation arms start at `base` and never see `head`.

| Case | Corpus task | Base | Defective head | Selection / freeze |
|---|---|---|---|---|
| J01 | `ccorch/.orchestra/01-jev-advisory` | `401b303` | `18ab729` | `J01-d13`–`d20`; brief lines 1–64, plan before later round-4 amendments (line 454); audit earlier revision text for post-implementation edits |
| J02 | `ccorch/.orchestra/02-jev-phase0-eval` | `401b303` | `a423ed6` | `J02-d12`–`d16`; use plan as recorded, brief lines 1–53 (remove later round-3 approval); preserve pre-registration commit `011d80d` only as a fixture if needed, never as later source |
| C10 | `cc-orchestra/.orchestra/10-install-manifest-doctor` | `bd0637b` | `ecef3fc` | `C10-d8`,`C10-d9`; plan as recorded before implementation |
| C11 | `cc-orchestra/.orchestra/11-verifier-bash-allowlist` | `bd0637b` | `f7e7ae3` | `C11-d7`–`d11`; plan as recorded; remove brief's later round-3 preamble (lines 5–28) and approval (lines 103–105) |
| C13 | `cc-orchestra/.orchestra/13-secret-scan` | `bd0637b` | `550d473` | `C13-d1`,`C13-d2`; plan lines 1–224, dropping the later takeover amendment |
| S24 control | `self-hosting-24/.orchestra/24-fast-mode-gpt6-sol-allowlist` | `65ec602` | `49dfa8f` | Inventory says `clean-first-pass`; no ground-truth defect, measure acceptance and reproduced false blockers |

The six rows above are the **primary implementer list**. The **investigator list** is J02, C10, C13, using each case's base and frozen brief only. Alternates, in order, are C05 (`cc-orchestra/.orchestra/05-trivial-risk-tier`, `e07434a` → `df8ebd9`, rows `C05-d6` onward) and C12 (`cc-orchestra/.orchestra/12-runtime-safety-hooks`, `bd0637b` → `4b750d1`, rows `C12-d10` onward). Both SHAs were checked with `git cat-file -e`; C05 is usable only if its original brief can be reconstructed without the later round-4/5 preamble and its plan truncated before line 409. Replace an ineligible primary with the next eligible alternate **before** inspecting any A/B outcome, and record the substitution. If neither is eligible, report reduced sample instead of inventing a fixture.

For every task, freeze `brief.md` and `plan.md` before an arm sees the clone. A later amendment is removed at its heading and any later content; for example C13 ends at line 224, as in orch/23. Compare frozen content with historical artifact timestamps, `summary.md`, and the first implementation commit's parent. If a section above the cut line contains results, gate feedback, or a later fix, remove that section and document exact line spans in `$AB/freeze.tsv`. Hash the resulting files. Do not expose `tabulation.csv`, reviews, rounds, summary, or later commits to an arm. If a usable pre-implementation plan cannot be recovered, the case is ineligible.

## Isolation, history pruning, and leak check

Each arm/run gets a fresh `git clone --no-local` of the live repository. Use neutral IDs `r001`, `r002`, etc.; keep `$AB/map.tsv` (ID, case, arm, repetition, seed) **outside** all clones. The following is the complete setup helper to copy into `$AB/setup.sh` and run once per ID. Its inputs are a row of `$AB/map.tsv`, the table above, and frozen fixtures under `$AB/frozen/<case>/`; it does not copy `head` into an arm. The experimenter creates the fixture files and `freeze.tsv` first.

```bash
#!/usr/bin/env bash
# setup.sh r001 J02 implement|investigate BASE
set -euo pipefail
rid=$1 case_id=$2 mode=$3 base=$4
: "${AB:?set AB to the new gate-ab-run task directory}"
: "${CORPUS:?set CORPUS to the corpus root}"
src=/home/janghun/cc-orchestra
[[ $rid =~ ^r[0-9]{3}$ && $mode =~ ^(implement|investigate)$ ]]
git -C "$src" cat-file -e "${base}^{commit}"
base=$(git -C "$src" rev-parse "${base}^{commit}")
dst="$AB/clones/$rid"
test ! -e "$dst"                 # never overwrite a previous run
mkdir -p "$AB/clones"
git clone -q --no-local "$src" "$dst"
cd "$dst"
git checkout -q -B main "$base"
git remote remove origin
git for-each-ref --format='%(refname)' refs/heads refs/tags refs/remotes refs/stash refs/notes |
  while IFS= read -r ref; do
    case "$ref" in refs/heads/main) ;; *) git update-ref -d "$ref" ;; esac
  done
git reflog expire --expire=now --all
git gc -q --prune=now
test "$(git rev-parse HEAD)" = "$base"
test "$(git for-each-ref --format='%(refname)' | sort)" = refs/heads/main
test "$(git rev-list --all | tail -1)" != ''
task=$(awk -F '\t' -v c="$case_id" '$1==c {print $2}' "$AB/cases.tsv")
test -n "$task"
mkdir -p ".orchestra/$task"
cp "$AB/frozen/$case_id/brief.md" ".orchestra/$task/brief.md"
if [ "$mode" = implement ]; then
  cp "$AB/frozen/$case_id/plan.md" ".orchestra/$task/plan.md"
fi
printf '\n.orchestra/\n' >> .git/info/exclude
git status --porcelain > "$AB/$rid.initial-status"
test ! -s "$AB/$rid.initial-status"
printf '%s\t%s\t%s\t%s\n' "$rid" "$case_id" "$mode" "$base" >> "$AB/setup-log.tsv"
```

`cases.tsv` is `case<TAB>task-directory-name`, e.g. `C10<TAB>10-install-manifest-doctor`; the source path for each brief/plan is the Corpus task in the selection table. `main` is the sole ref after pruning. A later commit may still be present as an unreachable object before GC; `git gc --prune=now` and a scan of `git fsck --no-reflogs --unreachable` must show none of the selected future SHAs. Save `git rev-list --all`, refs, and `git fsck` outputs in `$AB/isolation/`. The cloned `.orchestra` fixture has only the two input files for implementers or only `brief.md` for investigators. Neutral ID and path names contain no arm label.

Keep arm output outside the clone where possible; never give an arm `$AB/map.tsv`, the source corpus, or the live checkout path. The only allowed external executable path is `~/.claude/orchestra/bin/*`. Copy this transcript scanner into `$AB/leak-check.py` and run it on every Claude result and Codex jsonl; inspect every hit, including shell command strings. It fails closed on known forbidden roots and on a missing Claude transcript; it also reports Codex calls for the investigator rule.

```python
#!/usr/bin/env python3
import glob, json, os, re, sys
from pathlib import Path
ab = Path(os.environ['AB']).resolve()
rid = sys.argv[1]
result = json.loads((ab / f'{rid}.result.json').read_text())
matches = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{result['session_id']}.jsonl"))
assert len(matches) == 1, (rid, 'Claude transcript missing or ambiguous')
bad = []
calls = []
for line in open(matches[0], errors='replace'):
    obj = json.loads(line)
    if obj.get('type') != 'assistant': continue
    for item in (obj.get('message') or {}).get('content', []):
        if item.get('type') != 'tool_use': continue
        value = json.dumps(item.get('input', {}))
        calls += re.findall(r'codex-run(?:-runtime)?\s+(\w+)', value)
        for fragment in ('/home/janghun/cc-orchestra',
                         '/orchestra-state/worktrees', '/.claude/projects',
                         str(ab / 'map.tsv'), str(ab / 'frozen')):
            if fragment in value: bad.append(fragment)
        for other in (ab / 'clones').glob('r[0-9][0-9][0-9]'):
            if other.name != rid and str(other) in value: bad.append(str(other))
print(rid, 'codex-calls=', calls, 'forbidden=', sorted(set(bad)))
assert not bad
```

Also scan Codex `codex-implement.jsonl` tool commands with the same forbidden fragments; the scanner above is for Claude transcripts. A match can be a harmless string literal, but it is still an invalid run unless the saved command trace proves no file was read from that path. Record model/effort and `codex-run` calls from every transcript. `L-codex` needs `investigate` and no other Codex mode; `L-self` needs zero calls.

## Blinding, fixed rubric, and judges

Export each implementation as `git diff <base>..HEAD` after the arm finishes. If the arm leaves uncommitted changes, the experimenter copies the clone to a quarantine directory, commits the working tree there under a neutral author, and exports from that snapshot; never ask an arm to commit. Strip commit messages, `impl-report*`, generated logs, and run labels. Reports are retained privately for audit, not shown to judges. Randomize filenames `b001.diff` etc. and hold `blind-map.tsv` outside the judge directory. For investigator arms, export only the anonymous `plan.md`. Each judge's case directory contains the frozen `brief.md` and `plan.md`, a read-only history-pruned `base/` checkout at that case's base SHA with no `.orchestra` or later refs, and the specified anonymous diff or plan next to `base/`. Judges work from that case directory and may read its baseline code; they never see arm labels or each other's verdicts. Hidden-test outputs remain with the experimenter unless a fixed rubric item explicitly makes one available to judges.

Before any run, generate each `$AB/rubric/<case>.md` by copying that case's rows **verbatim** from the “Fixed rubric items” appendix below; do not add or rewrite rubric items. Each defect gets a 0/1/2 item. Hidden repros, where built, must implement exactly the listed trigger and expected behavior. A field marked “not recorded — item scored by judges only (cannot trigger the decision alone)” remains uncertain; do not fill it from later intuition. Freeze rubric hashes before the pilot.

The **complete, pre-fixed item set** is the appendix below. Each ID refers to the corresponding `tabulation.csv` mechanism and cited source. Accepted and post-merge rows remain visible, but an item without a valid repro is judge-scored as uncertain and cannot alone trigger the default change.

| Case | Ground-truth item IDs and mechanisms |
|---|---|
| J01 | `d13` proxy/redirect egress; `d14` unbounded whole attempt; `d15` unsafe source name echo; `d16` source name resembling RISK AMENDED; `d17` wrong per-source aggregation; `d18` help journals; `d19` transformed credential missed; `d20` non-200 accepted; `d21` later H2 leaked; `d22` display path tail lost; `d23` placeholder suppresses cross-line credential; `d24` stripped-match cancellation (accepted); `d25` bare-CR cancellation (accepted); `d26` inline backticks open a false fence (post-merge). Prefix every ID with `J01-`. |
| J02 | `d10` unsupported Git `-z`; `d11` personal path in tracked data; `d12` ordinal-only label binding; `d13` process heading contaminates subtree; `d14` amendment heading becomes reason; `d15` defect prose dropped before evidence bullets; `d16` NUL secret-filter mismatch; `d17` concurrent `.pending` collision (accepted); `d18` output aliases input (accepted); `d19` inline backticks open a false fence (post-merge). Prefix every ID with `J02-`. |
| C10 | `d8` shared manifest staging; `d9` merged NDJSON accepted; `d10` FIFO hash hang (accepted). Prefix every ID with `C10-`. |
| C11 | `d7` process substitution hides command; `d8` shell `-c` value flags hide command; `d9` here-string bypass; `d10` `find -exec` callback bypass; `d11` unquoted heredoc expansion; `d12` safe `bash -n -c` denied; `d13` safe `command -p -v` denied; `d14` grouped curl pipeline bypass; `d15` `env -S` bypass; `d16` case token false positive; `d17` heredoc folding bypass; `d18` parser failure allowed; `d19` coproc bypass; `d20` dangling operator allowed; `d21` shell stdin bypass; `d22` unparenthesized function bypass; `d23` interpreter one-liner bypass; `d24` ssh/su/flock/watch wrapper bypass; `d25` `env -S` safe-string false positive; `d26` `git branch --list -- -D` false positive. `d19`–`d26` were accepted residuals. Prefix every ID with `C11-`. |
| C13 | `C13-d1` scanner uses installed checkout; `C13-d2` quoted JSON secret key missed. |
| S24 | No ground-truth item; count acceptance and reproduced new defects or false blockers. |

The investigator planning rubric is also fixed now. For J02, score design items `J02-d1` injection-scan path, `d2` later RISK changes, `d3` preregistered scoring, `d4` historical output guards, `d5` secret-pattern port, `d6` numerical/execution tests, `d7` leak-failing gate, `d8` no recommendation from mocks, `d9` refreshed corpus amendment, plus its implementation mechanisms `d10`–`d19` as anticipated risks/tests. For C10, score `C10-d1` upstream freshness, `d2` uncommitted render inputs, `d3` agents-dir override, `d4` fixture repair isolation, `d5` reversible path encoding, `d6` complete runtime publication, `d7` exact coverage/hash tests, `d11` legitimate quota roster drift, `d12` all-file `bash -n`, plus implementation items `d8`–`d10`. For C13, score `C13-d1` and `d2` as risks/tests. A planning item is applicable only if the frozen brief and baseline expose its mechanism; document an inapplicable item before reading plans and exclude it from both arms' denominator.

For a **review** finding, use orch/23's exact scale: **2** = mechanism correctly identified and a fix requested in this round; **1** = mechanism mentioned but dismissed, deferred, or partly correct; **0** = absent. For a **shipped diff**, invert the quality direction: **0 shipped** if a hidden repro passes and the defect is absent; **1 shipped** if the behavior is ambiguous or only partly exposed (flag for both judges); **2 shipped** if the repro fails in the ground-truth way. For a **plan**, score each planning item 0/0.5/1: absent, weak/incorrect, or explicitly and correctly handled in Changes/Tests/Risks/Amendments. Quote the scored text and cite file:line for every nonzero planning/review score. Ambiguous plan items receive 0.5 with a note. New defects count only after the experimenter reproduces them on the anonymous diff; false blockers are recorded separately.

Two independent read-only judges score **every** anonymous diff and plan: one Codex run (`codex exec -s read-only -m gpt-6-astra -c model_reasoning_effort=high` with the fixed rubric prompt), and one Claude Opus@high run (`claude -p --agent route-lead-delta-normal --effort high --allowedTools 'Read Grep Glob Bash' --disallowedTools 'Write Edit NotebookEdit Agent'`). Both produce per-item scores, cited evidence, and other suspected defects. Neither sees labels or the other score. Differences remain visible in the final table; the experimenter resolves only executable behavior, using the pre-frozen hidden repro. Primary M1/M2 use executable evidence when available, so a judge family preference cannot change them. For items without an executable repro, report both judges and treat a disagreement as uncertain; do not award a decisive quality threshold from a single-family judgment.

## Metrics and collection

* **M1 acceptance:** the task's frozen `Verification` block plus hidden tests extracted from historical fix rounds at the final merged commit. Run each hidden test on the historical defective HEAD (must fail for the intended reason) and historical fixed HEAD (must pass) in separate judge clones before use. Record unsupported/dependency-limited tests instead of silently dropping them. A run passes acceptance only if its own verification and all applicable hidden tests pass.
* **M2 ground-truth defects shipped:** per frozen rubric item and run, binary 1 if the reproduced defect remains (partial/uncertain items tracked separately). Summed across all runs and also shown by task. The historical table is the source of mechanisms, not a verdict on new diffs.
* **M3 new defects:** only independently reproduced, with a script and before/after output. Count separately from M2, then sum M2+M3 for the decision threshold. Track false blockers on S24.
* **M4 cost:** Primary Claude cost is each run's `--output-format json` (`total_cost_usd`, `usage`, `num_turns`, `duration_ms`) plus the per-run transcript token sum in step 7. Do not use `orch-usage-report` for headless Claude arm or judge cost: it counts a main transcript only when a qualifying lead/dev/verifier subagent child exists (`bin/orch-usage-report:36-53`), which these `claude -p --agent` runs lack. Use that report only for its Codex wrapper-run section. Codex tokens come from each run's `codex-implement.jsonl` or `codex-investigate.jsonl` `turn.completed.usage`, plus wrapper run counts from the run log. Capture `/home/janghun/cc-orchestra/bin/orch-model-guard lanes` immediately before/after each serialized wave, with timestamp and reset time. Report Claude session and Codex week percentage-point deltas, subtracting unrelated usage only when separately observed and auditable. If other users spend from the same pool, mark the delta contaminated.
* **M5 wall-clock:** monotonic start/end per run, excluding fixture preparation and judging; report wait time separately. Investigator primary metric is plan rubric coverage; also sample five asserted file:line claims per plan (or all if fewer) against the frozen clone, reporting accuracy, Claude/Codex tokens and cost, and wall-clock.

No outcome is pooled across tasks without displaying per-task scores and the clean control.

## Schedule, size, and stopping

Pilot one task (C10) through X/S/O and L-codex/L-self once, in serialized order, without scoring quality until fixture and cost checks are complete. Then six implementation tasks × three arms × two runs = **36 runs** and three investigator tasks × two arms × three runs = **18 runs** total, including pilot cells. Implementation wave 1 is one run per task-arm cell (18 runs); wave 2 is the second run per cell. Interleave arm order within each task by a stored random seed; serialize quota snapshots/waves so deltas can be attributed. If implementation wave-1 Claude CLI cost is **under $70** and the measured quota projection fits both stop lines, a **third implementation run per cell** may be added, but the decision and cost-only evidence must be written before opening wave-1 quality files. The extra 18 runs do not change thresholds. Keep all invalid runs and replacements in the accounting.

Abort a wave before dispatch if projected Codex week usage would exceed **90%** or Claude 5-hour session would exceed **80%** according to `orch-model-guard lanes`. Pause and await quota reset; do not route an arm to another model. Abort and investigate if any pilot run costs more than **3×** its preregistered estimate. Stop for an isolation leak or lost ground-truth fixture, correct it symmetrically, and rerun the affected cells. Do not use quality results to stop early.

## Fixed decisions

Move the default implementer from X to a Claude arm K (S or O) only if **all** hold:

1. K's M1 hidden-test-plus-acceptance pass count is at least X's.
2. K's total shipped defects (M2+M3, all runs) is at most `0.67 ×` X's, at least **two defects fewer** in absolute count, and lower on at least **two tasks**; **and** at least one ground-truth defect is shipped by X in a majority of its runs on one task while K ships it in none of its runs on that task.
3. K's measured mean Claude 5-hour-session cost per implementation run is at most **3 percentage points**.

Otherwise X remains default and K's result is evidence only for the escalation lane. Ties, a one-defect total advantage, an advantage confined to one task without the repeated-defect criterion, or a quality win failing the cost cap do not move the default. If both Claude arms qualify, choose the one with fewer defects; then higher acceptance; then lower measured session cost. If all tie, keep X. A clear X advantage remains evidence against the fresh-eyes escalation assumption.

Move the investigator default to L-self only if its mean paired plan-rubric score is at least **one point higher per run pair** than L-codex's and its mean Claude cost is at most **1.3×** L-codex's. Otherwise keep Codex investigation. If both arms score at most **1 total** on a probe, mark that probe non-discriminating (orch/23 rule); show it but do not let it satisfy the quality margin. Judge disagreement on non-executable items cannot by itself trigger a default change. Report both outcomes separately to the user; this protocol does not enact policy.

## Preregistered cost estimate

These are **planning estimates, not observed A/B costs**. Orch/23's `self-hosting-19/.orchestra/23-lead-normal-effort-measurement/evidence/ab/costs.json` has 24 headless lead runs totaling **$24.30**, mean **$1.012/run** and high-effort mean **$1.124/run**; these are short Phase B/D probes, so a full implementation or investigation may cost more. Across 46 historical `codex-implement*.jsonl` streams in the corpus, the median `turn.completed.usage` input+output is **774,152 tokens per stream** (cache-inclusive; not a billable-token estimate). The installed `codex.log` has **255 wrapper runs** since the current Codex week began on 2026-09-27 21:36 KST; `orch-model-guard lanes` showed **72%** week usage on 2026-09-30. A crude blended rate is `72/255 = 0.28` Codex weekly percentage points per wrapper call. It mixes modes, models, cache, and other projects: budget roughly **5 points** for 18 X implementation calls, **3 points** for nine L-codex investigations, plus judge calls and retries. The 90% stop line leaves only 18 points from that snapshot, so serialize and remeasure before each wave.

Claude's `$` and token records do **not** reveal 5-hour quota percentage points. A numeric conversion from orch/23's costs to that quota would be invented. The preregistered Claude cost band is therefore **un-calibrated: 0.5–3 session points per Claude run**, with 3 points/run the decision cap, 42 planned Claude arm runs (24 implementer + 18 investigator), or **21–126 points** in all. The upper end crosses the 80% wave stop; this experiment may require several 5-hour windows. The pilot replaces that band with measured before/after session-point deltas, which are the only admissible figures for the decision. The pilot's >3× stop uses the upper bound, **9 points**, for a Claude arm and the blended Codex estimate, **0.84 points**, for X; dollar and token anomalies are reported separately. Do not compare a Codex week point to a Claude session point as if they had equal value.

## Comparability and validity

Implementer arms compare diffs from an identical plan: the lead design is held fixed. Investigator arms compare plans from an identical brief using the same Opus lead model/effort; only the Phase A research route changes. These two experiments cannot be pooled or ranked against each other, and neither measures a full end-to-end lead task. X depends on its wrapper prompt; S/O depend on the installed dev template and profiles.

Replay leakage is the largest threat: later commits, fixes, reviews, and task directories could give away answers. History pruning, input-only `.orchestra`, neutral labels, forbidden-path instructions, transcript checks, and blinded judges reduce but do not eliminate it. Other threats are small and selected n, defect-rich cases, correlated tasks from one repository, family-biased judges, prompt asymmetry, historical test extraction bias, model/CLI version drift, Astra availability and Sol fallback, quota pressure affecting routing, nondeterminism, and potentially contaminated shared quota deltas. Publish invalid runs and uncertainty rather than hiding them.

## Exact later-run sequence

These numbered steps are commands for a **future** task, not commands executed for this protocol. Replace `<NN>` with its assigned task number and choose an unused directory. The experimenter records terminal output, timestamps, SHA256s, and the frozen map in `$AB/evidence/`. Commands 5–8 are repeated for the schedule above.

1. Create the run directory and verify source commits and current profiles:

   ```bash
   set -euo pipefail
   export AB="$HOME/.claude/orchestra-state/worktrees/cc-orchestra/self-hosting-<NN>/.orchestra/<NN>-gate-ab-run"
   export CORPUS=/home/janghun/.claude/orchestra-state/worktrees/cc-orchestra
   mkdir -p "$AB"/{clones,frozen,rubric,evidence,isolation,blind,judges}
   for sha in 401b303 18ab729 a423ed6 bd0637b ecef3fc f7e7ae3 550d473 65ec602 49dfa8f e07434a df8ebd9 4b750d1; do
     git -C /home/janghun/cc-orchestra cat-file -e "${sha}^{commit}"
   done
   sha256sum /home/janghun/cc-orchestra/templates/lead.md.tpl \
     /home/janghun/cc-orchestra/bin/codex-run \
     /home/janghun/cc-orchestra/bin/codex-run-runtime \
     /home/janghun/cc-orchestra/model-policy.conf \
     "$HOME/.claude/agents/dev-1.md" "$HOME/.claude/agents/dev-opus-1.md" \
     "$HOME/.claude/agents/route-lead-delta-normal.md" > "$AB/evidence/profile-sha256.txt"
   /home/janghun/cc-orchestra/bin/orch-model-guard lanes > "$AB/evidence/quota-before.txt"
   ```

2. Freeze briefs/plans using the cuts above. These commands produce the initial fixture; the experimenter must audit it for post-implementation information and document every additional removal in `$AB/freeze.tsv`. In particular, J01's “Revision 3” line is later metadata, and C11's brief was rewritten around its later approval. If that audit cannot recover pre-implementation inputs, substitute an alternate before any outcome is opened.

   ```bash
   cat > "$AB/cases.tsv" <<'EOF'
   J01	01-jev-advisory
   J02	02-jev-phase0-eval
   C10	10-install-manifest-doctor
   C11	11-verifier-bash-allowlist
   C13	13-secret-scan
   S24	24-fast-mode-gpt6-sol-allowlist
   EOF
   while IFS=$'\t' read -r case_id slug; do mkdir -p "$AB/frozen/$case_id"; done < "$AB/cases.tsv"
   J="$CORPUS/ccorch/.orchestra"
   C="$CORPUS/cc-orchestra/.orchestra"
   S="$CORPUS/self-hosting-24/.orchestra"
   sed -n '1,64p' "$J/01-jev-advisory/brief.md" > "$AB/frozen/J01/brief.md"
   sed -n '1,454p' "$J/01-jev-advisory/plan.md" | sed '/^Revision 3 (round 4 amendments at the end; one Codex lane owns every file)\.$/d' > "$AB/frozen/J01/plan.md"
   sed -n '1,53p' "$J/02-jev-phase0-eval/brief.md" > "$AB/frozen/J02/brief.md"
   cp "$J/02-jev-phase0-eval/plan.md" "$AB/frozen/J02/plan.md"
   cp "$C/10-install-manifest-doctor/brief.md" "$AB/frozen/C10/brief.md"
   cp "$C/10-install-manifest-doctor/plan.md" "$AB/frozen/C10/plan.md"
   sed -n '1,4p;29,102p;106,$p' "$C/11-verifier-bash-allowlist/brief.md" > "$AB/frozen/C11/brief.md"
   cp "$C/11-verifier-bash-allowlist/plan.md" "$AB/frozen/C11/plan.md"
   cp "$C/13-secret-scan/brief.md" "$AB/frozen/C13/brief.md"
   sed -n '1,224p' "$C/13-secret-scan/plan.md" > "$AB/frozen/C13/plan.md"
   cp "$S/24-fast-mode-gpt6-sol-allowlist/brief.md" "$AB/frozen/S24/brief.md"
   cp "$S/24-fast-mode-gpt6-sol-allowlist/plan.md" "$AB/frozen/S24/plan.md"
   find "$AB/frozen" -type f -print0 | sort -z | xargs -0 sha256sum > "$AB/evidence/frozen-sha256.txt"
   ```

   Make `$AB/freeze.tsv`; copy the case's “Fixed rubric items” appendix rows verbatim into `$AB/rubric/<case>.md` and hash each file. Extract hidden tests only for recorded triggers and expected behavior, into `$AB/hidden/<case>/`; each repro must fail on defective `head` and pass on the fixed historical commit. Write extraction and both outputs into `$AB/evidence/hidden-validation/`. Freeze these files **before** any pilot output is opened.

3. Randomize and freeze `$AB/map.tsv` (neutral ID, case, arm, repetition, seed); keep it outside clones. Copy the two inline helpers above to `$AB/setup.sh` and `$AB/leak-check.py` and make them executable. Confirm `$AB/cases.tsv` has `case<TAB>task-directory-name` and that each frozen fixture contains exactly the allowed files. Keep the map sealed until scoring is final.

4. Pilot C10 once through X, S, O, L-codex, L-self. For each ID run `AB="$AB" CORPUS="$CORPUS" bash "$AB/setup.sh" r001 C10 implement bd0637b` (change ID/mode per map), inspect isolation evidence, and snapshot `/home/janghun/cc-orchestra/bin/orch-model-guard lanes`. Dispatch each arm with step 5 or 6. Record CLI result, exit code, model, effort, cost and quota after each run. Apply the pilot stop rules before opening quality files.

5. Implementer dispatch, replacing `RID`, `TASK`, and `ARM` from the sealed map; use a fresh clone per command. `TASK` is `$AB/clones/$RID/.orchestra/<task-directory-name>`. Run one of:

   ```bash
   ~/.claude/orchestra/bin/codex-run-runtime implement "$AB/clones/$RID" "$TASK" --model astra --effort xhigh
   # S or O: DEV_AGENT is dev-1 or dev-opus-1. DEV_PROMPT is the filled verbatim Phase C quote.
   ( cd "$AB/clones/$RID" && claude -p --agent "$DEV_AGENT" --effort high \
       --output-format json --permission-mode dontAsk \
       --allowedTools 'Bash Read Grep Glob Write Edit' --disallowedTools 'Agent NotebookEdit' \
       --max-budget-usd 30 "$DEV_PROMPT" < /dev/null ) \
       > "$AB/$RID.result.json" 2> "$AB/$RID.stderr.log"
   ```

6. Investigator dispatch. `INV_PROMPT` is the fixed question plus the Phase A0–B stop and arm rule above. Use the same lead profile and effort for both; the L-self prompt forbids Codex calls and its transcript must show none. Store each result by neutral ID:

   ```bash
   TOOLS='Bash Read Grep Glob Write'
   if [ "$ARM" = L-self ]; then TOOLS='Bash Read Grep Glob'; fi
   ( cd "$AB/clones/$RID" && claude -p --agent route-lead-delta-normal --effort high \
       --output-format json --permission-mode dontAsk \
       --allowedTools "$TOOLS" --disallowedTools 'Agent Edit NotebookEdit' \
       --max-budget-usd 30 "$INV_PROMPT" < /dev/null ) \
       > "$AB/$RID.result.json" 2> "$AB/$RID.stderr.log"
   ```

7. After each serialized wave: run `AB="$AB" python3 "$AB/leak-check.py" "$RID"` for every Claude run; scan Codex jsonl for the same forbidden paths; check actual models, effort, and investigator Codex calls; save `/home/janghun/cc-orchestra/bin/orch-model-guard lanes` snapshots. Rerun invalid cells only after a symmetric amendment. For each Claude arm RID, append one line to `$AB/evidence/claude-usage.tsv` with columns `rid,total_cost_usd,num_turns,duration_ms,cli_usage_json,input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens`:

   ```bash
   python3 - "$AB" "$RID" >> "$AB/evidence/claude-usage.tsv" <<'PY'
   import json, sys
   from pathlib import Path
   ab, rid = Path(sys.argv[1]), sys.argv[2]
   result = json.loads((ab / f'{rid}.result.json').read_text())
   matches = list(Path.home().glob(f".claude/projects/*/{result['session_id']}.jsonl"))
   assert len(matches) == 1, (rid, 'missing or ambiguous transcript')
   main = matches[0]
   files = [main, *sorted((main.parent / main.stem / 'subagents').glob('agent-*.jsonl'))]
   keys = ('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')
   totals = {key: 0 for key in keys}
   for path in files:
       for line in path.open(errors='replace'):
           obj = json.loads(line)
           if obj.get('type') != 'assistant':
               continue
           usage = (obj.get('message') or {}).get('usage') or {}
           for key in keys:
               totals[key] += int(usage.get(key) or 0)
   values = [rid, result['total_cost_usd'], result['num_turns'], result['duration_ms'],
             json.dumps(result.get('usage') or {}, sort_keys=True, separators=(',', ':')),
             *(totals[key] for key in keys)]
   print('\t'.join(map(str, values)))
   PY
   ```

   Apply the same transcript-sum method to each judge's `$AB/judges/$BLIND.claude.json` for separate judge-cost accounting. For Codex wrapper-run counts only, run `CC_ORCH_CLAUDE_PROJECTS="$AB/no-claude-sessions" CC_ORCH_CODEX_LOG="$AB/codex.log" /home/janghun/cc-orchestra/bin/orch-usage-report --days 1` after copying the wrapper log; retain raw `turn.completed.usage` records. The report's Claude section is deliberately unused because of its qualifying-child filter (`bin/orch-usage-report:36-53`).

8. After all valid runs: export anonymous diffs (`git diff <base>..HEAD` from each committed/quarantined snapshot) and anonymous plans; strip reports, commit metadata, and run labels. For each case, copy `$AB/frozen/<case>/brief.md` and `plan.md` to `$AB/blind/<case>/`, and make `$AB/blind/<case>/base` a read-only checkout at that case's base SHA using the same `setup.sh` history pruning. Reserve a distinct neutral setup ID (for example `r901` for J01) outside the arm ID range; `CASE` and `BASE_SHA` come from the selection table. The setup clone's `.orchestra` fixture is removed from the blind copy. Verify the base SHA and sole `main` ref before giving judges access:

   ```bash
   # Set CASE=J01, BASE_SHA=401b303, BASE_RID=r901; use a unique BASE_RID per case.
   AB="$AB" CORPUS="$CORPUS" bash "$AB/setup.sh" "$BASE_RID" "$CASE" implement "$BASE_SHA"
   mkdir -p "$AB/blind/$CASE/base"
   cp "$AB/frozen/$CASE/brief.md" "$AB/frozen/$CASE/plan.md" "$AB/blind/$CASE/"
   cp -a "$AB/clones/$BASE_RID/." "$AB/blind/$CASE/base/"
   rm -rf "$AB/blind/$CASE/base/.orchestra"
   test ! -e "$AB/blind/$CASE/base/.orchestra"
   test "$(git -C "$AB/blind/$CASE/base" rev-parse HEAD)" = \
     "$(git -C /home/janghun/cc-orchestra rev-parse "${BASE_SHA}^{commit}")"
   test "$(git -C "$AB/blind/$CASE/base" for-each-ref --format='%(refname)')" = refs/heads/main
   chmod -R a-w "$AB/blind/$CASE/base"
   ```

   Place each `bNNN.diff` or `bNNN.plan.md` next to `base/` in its case directory. Keep hidden-test outputs in `$AB/evidence/`, outside the judge bundle, unless a fixed rubric item expressly permits one. Hash the blind bundle. Run both read-only judges from the case directory against the specified blind file and `$AB/rubric/<case>.md`; store outputs in `$AB/judges/`. For each anonymous label and case, the judge invocation is:

   ```bash
   # Set BLIND=b001 and CASE=C10 from the sealed blind queue (no arm labels).
   JUDGE_PROMPT=$(printf 'Score only the anonymous artifact %s.diff or %s.plan.md in this case directory. Read brief.md, plan.md, and baseline code under base/ as needed. Give each rubric item a score, evidence, and any new suspected defect. Do not infer the arm. Read only.\n\n%s\n' \
     "$BLIND" "$BLIND" "$(cat "$AB/rubric/$CASE.md")")
   codex exec --ephemeral --skip-git-repo-check -s read-only -C "$AB/blind/$CASE" \
     -m gpt-6-astra -c model_reasoning_effort=high \
     -o "$AB/judges/$BLIND.codex.md" "$JUDGE_PROMPT"
   ( cd "$AB/blind/$CASE" && claude -p --agent route-lead-delta-normal --effort high \
       --output-format json --permission-mode dontAsk \
       --allowedTools 'Read Grep Glob Bash' --disallowedTools 'Write Edit NotebookEdit Agent' \
       "$JUDGE_PROMPT" < /dev/null ) > "$AB/judges/$BLIND.claude.json"
   ```

   Execute frozen hidden repros and each task's Verification block in separate judge clones. Score M1–M5 and investigator coverage in `$AB/scores.csv`, with columns `blind,case,m1_pass,m2_count,m3_count,plan_points,claims_correct,claims_checked,claude_cost_usd,claude_session_points,codex_input_tokens,codex_output_tokens,codex_week_points,wall_seconds,uncertain_items,evidence`. Every defect count links a repro or both judge records. Recount defect totals, pass counts, and cost means independently from that CSV before opening `blind-map.tsv`.

9. Unblind only after both judge files and the recount are frozen. Join `$AB/scores.csv` to `$AB/map.tsv`, calculate per-task and aggregate thresholds exactly as stated above, and write `$AB/decision.md` with raw counts, denominators, rejected/invalid runs, judge disagreements, quota contamination, and any amendment. Report the decision to the user; a later authorized policy task would implement it.

## Fixed rubric items

This appendix is the rubric to copy verbatim, not a list of suggestions. Each evidence cell names the matching `tabulation.csv` row, then a file and line in that row's cited corpus artifacts, then a historical fix commit or test name where the cited record names one. Paths are relative to the corpus root. To keep the table readable, `J1/` expands to `ccorch/.orchestra/01-jev-advisory/`, `J2/` to `ccorch/.orchestra/02-jev-phase0-eval/`, `C10/` to `cc-orchestra/.orchestra/10-install-manifest-doctor/`, `C11/` to `cc-orchestra/.orchestra/11-verifier-bash-allowlist/`, `C13/` to `cc-orchestra/.orchestra/13-secret-scan/`, `CT/` to `cc-orchestra/tests/`, and `S21/` to `self-hosting-20/.orchestra/21-fix-strip-fences-python-copies/`. These are citation abbreviations only; they are not paths shown to arms. C13 has no design-stage CSV rows, so its two diff rows are also its investigator planning items. J02 and C10 planning additionally reuse their diff rows as anticipated risks/tests; each ID remains one item.

| id | mechanism | minimal input or trigger | expected correct behavior | historical evidence |
|---|---|---|---|---|
| J01-d13 | Proxy or redirect can send a bearer request to an unpinned destination | Bearer request with ambient proxy or HTTP redirect | No bearer request leaves the pinned destination | `J01-d13`; `J1/summary.md:10`; fix `7209e94` |
| J01-d14 | Per-attempt timeout does not bound the whole request | A server extends work beyond one attempt deadline | Whole attempt ends at its deadline | `J01-d14`; `J1/summary.md:10`; fix `7209e94` |
| J01-d15 | Unsanitized scan source name echoes unsafe text | not recorded — item scored by judges only (cannot trigger the decision alone) | Source-name text is sanitized before output | `J01-d15`; `J1/summary.md:10`; fix `7209e94` |
| J01-d16 | Source name can affect RISK AMENDED parsing | Scan source name containing `RISK AMENDED` | Name cannot become a live amendment declaration | `J01-d16`; `J1/summary.md:10`; fix `c4cc84d` |
| J01-d17 | Scan aggregation misreports a source | Scan with multiple named sources | Report attributes each result to its actual source | `J01-d17`; `J1/summary.md:10`; fix `c4cc84d` |
| J01-d18 | Help call writes a journal record | Invoke help without a scan | Help exits without a journal entry | `J01-d18`; `J1/summary.md:10`; fix `c4cc84d` |
| J01-d19 | Egress filter misses transformed credential | Source name or state containing a credential with CR, Unicode space, or zero-width separator | Skip before transmission and reveal no credential value | `J01-d19`; `J1/plan.md:496-505`; fix `23868aa` |
| J01-d20 | Non-200 response parsed as success | Mock HTTP 201 or 202 with schema-valid body | Report unavailable HTTP status, not a Jev answer | `J01-d20`; `J1/plan.md:509-511`; fix `23868aa` |
| J01-d21 | Repeated Acceptance heading leaks later text | Brief with a second `## Acceptance` heading | Only the first Acceptance section is transmitted | `J01-d21`; `J1/plan.md:570-573`; test `test_section_stops_at_repeated_header`, fix `6944532` |
| J01-d22 | Long display name loses distinguishing tail | Two source paths longer than 120 characters that differ at the tail | Display names retain distinguishing tail | `J01-d22`; `J1/plan.md:574-576`; fix `6944532` |
| J01-d23 | Placeholder suppresses cross-line credential | Placeholder on one LF line and credential assembled across later LF lines | Cross-line credential is filtered regardless of other-line placeholder | `J01-d23`; `J1/summary.md:31`; test `test_placeholder_does_not_suppress_cross_line`, fix `094b211` |
| J01-d24 | Per-line count cancels newly assembled credential | `token="<16 chars>\n<16 chars> token="<32 chars>" # changeme` | Assembled first credential is filtered even when counts match | `J01-d24`; `J1/codex-review.md:2`; accepted, no fix |
| J01-d25 | Bare CR hides credential behind placeholder | `example\rtoken = "<32 chars>"` in one LF line | Bare-CR credential is filtered | `J01-d25`; `J1/summary.md:20`; accepted, no fix |
| J01-d26 | Inline triple backticks open a false fence | `` ```x``` names the flag`` followed by real `RISK: critical` | Inline span does not hide later RISK text | `J01-d26`; `S21/evidence/repro.py:20-28`; test `test_inline_code_is_not_a_fence_opener`, fix `aaa5ae6` |
| J02-d1 | Injection-scan execution path missing | Plan promises injection scoring but adapter has only `lint_brief` | Scan dispatch handles synthetic input and cached scan responses | `J02-d1`; `J2/plan-review-codex.md:2`; plan amendment |
| J02-d2 | Later RISK changes not preserved | Plan records only initial `declared_risk` | Dataset records sourced transitions and missing observations | `J02-d2`; `J2/plan-review-codex.md:3`; plan amendment |
| J02-d3 | Scoring protocol partly unregistered | Threshold/negative population/ambiguous labels/skip/bootstrap unspecified | Freeze those choices before any scoring | `J02-d3`; `J2/plan-review-codex.md:4`; plan amendment |
| J02-d4 | Historical-data output guard incomplete | `run_eval.py --out` points inside historical data | Reject unsafe output before creating a file | `J02-d4`; `J2/plan-review-codex.md:5`; plan amendment |
| J02-d5 | Secret-pattern port loses whitespace matches | Assignment with vertical tab, form feed, or CR | Python filter matches scanner behavior and preserves line bounds | `J02-d5`; `J2/plan-review-codex.md:6`; plan amendment |
| J02-d6 | Scorer tests lack numerical assertions | Fixture with known confusion matrix or threshold boundary | Assert metrics, verdict, cache resume, and secret-skip behavior | `J02-d6`; `J2/plan-review-codex.md:7`; plan amendment |
| J02-d7 | Historical-text gate masks leaks | Historical-content overlap under a check whose failure is suppressed by `true` | Leak or command failure makes gate fail | `J02-d7`; `J2/plan-review-codex.md:8`; plan amendment |
| J02-d8 | Mock scores can drive deployment advice | Hash-derived mock adapter results | Mark demonstration and exclude from enablement verdict | `J02-d8`; `J2/plan-review-codex.md:9`; plan amendment |
| J02-d9 | Corpus amendment is stale | Eighth task brief now exists | Refresh counts and record snapshot provenance | `J02-d9`; `J2/plan-review-codex.md:10`; plan amendment |
| J02-d10 | Git 2.34 rejects worktree `--porcelain -z` | Linked worktree enumeration on Git 2.34.1 | Discover linked worktrees instead of silently returning none | `J02-d10`; `J2/summary.md:16-18`; mutation-tested in `tests/test-jev-eval.sh` |
| J02-d11 | Dataset builder embeds personal project paths | Build tracked dataset from historical task paths | Tracked output has no personal historical-project paths | `J02-d11`; `J2/summary.md:16-18`; fix commit not recorded |
| J02-d12 | Ordinal-only labels attach to changed reasons | Rebuild changes reason text but retains `#r01` | Bind labels to reason text/hash and reject stale binding | `J02-d12`; `J2/summary.md:9-18`; fix `6ed36c4` |
| J02-d13 | Process heading contaminates reason subtree | Process-looking heading above audit amendments | Genuine amendments are not all classified as process | `J02-d13`; `J2/summary.md:9-18`; fix `6ed36c4` |
| J02-d14 | Bare amendment heading becomes reason | `## Amendments` in source text | Heading itself is not an audit reason | `J02-d14`; `J2/summary.md:9-18`; fix `6ed36c4` |
| J02-d15 | Defect prose before evidence bullets is dropped | Defect-stating prose followed by evidence bullets | Keep the defect prose as a reason | `J02-d15`; `J2/summary.md:9-18`; fix `6dc2d71` |
| J02-d16 | Python secret filter misses NUL assignment | `token\0= "<32 chars>"` | Filter matches Bash scanner's NUL-sensitive result | `J02-d16`; `J2/summary.md:9-18`; fix `6dc2d71` |
| J02-d17 | Concurrent cache fills collide | Six concurrent mock runs sharing one cache key | No run aborts before response output | `J02-d17`; `J2/summary.md:35-38`; accepted, no fix |
| J02-d18 | Worklist output aliases input | `--emit-worklist --out <dataset path>` | Reject alias rather than overwrite dataset | `J02-d18`; `J2/summary.md:39-40`; accepted, no fix |
| J02-d19 | Inline triple backticks open a false fence in eval parser | `` ```x``` inline`` before real RISK declaration or amendment | Later RISK text remains visible to eval parser | `J02-d19`; `S21/evidence/repro.py:20-29`; test `parser_tests`, fix `aaa5ae6` |
| C10-d1 | Local HEAD misses advanced upstream | Manifest commit and local HEAD at A, tracking ref at B | Report offline upstream freshness mismatch | `C10-d1`; `C10/plan-review-codex.md:2`; plan amendment |
| C10-d2 | Uncommitted render edits leave false OK | Edit template or policy without committing | Detect input drift despite unchanged HEAD | `C10-d2`; `C10/plan-review-codex.md:3`; plan amendment |
| C10-d3 | Doctor ignores agents-dir override | Build with `CC_ORCH_AGENTS_DIR` only, then run doctor | Doctor reads that directory's manifest | `C10-d3`; `C10/plan-review-codex.md:4`; plan amendment |
| C10-d4 | Repair can rewrite real HOME roster | Inspect fixture/custom manifest with repair option | Repair cannot mutate unrelated real HOME roster | `C10-d4`; `C10/plan-review-codex.md:5`; plan amendment |
| C10-d5 | Manifest path encoding truncates characters | Destination containing quote or backslash | Encode reversibly or reject before writing, never truncate | `C10-d5`; `C10/plan-review-codex.md:6`; plan amendment |
| C10-d6 | Runtime manifest published incomplete | Interrupt runtime builder after base entries, before route entries | No incomplete manifest appears healthy | `C10-d6`; `C10/plan-review-codex.md:7`; plan amendment |
| C10-d7 | All-clear test lacks coverage/hash assertions | Empty or missing-entry manifest in an all-clear fixture | Test fails unless coverage, uniqueness, metadata, and hashes match | `C10-d7`; `C10/plan-review-codex.md:8`; plan amendment |
| C10-d8 | Shared manifest staging races | Two concurrent builders write one `$MANIFEST.building` | Producer-unique staging prevents incomplete publication | `C10-d8`; `C10/summary.md:33-37`; fix `b203806`, `tests/test-orch-doctor.sh` |
| C10-d9 | Merged NDJSON objects accepted | Two JSON objects on one physical manifest line | Reject malformed merged line | `C10-d9`; `C10/summary.md:38-40`; fix `b203806`, `tests/test-orch-doctor.sh` |
| C10-d10 | FIFO replacement hangs hashing | Replace tracked destination with a named pipe | Do not block indefinitely reading a FIFO | `C10-d10`; `C10/summary.md:42-49`; accepted, no fix |
| C10-d11 | Quota switch causes legitimate drift | `orch-model-guard set` changes generated model after install | Document expected DRIFTED or track legitimate mutation without blessing others | `C10-d11`; `C10/plan-review-codex.md:9`; plan amendment |
| C10-d12 | Multi-file `bash -n` checks only first file | `bash -n` followed by several script paths | Syntax-check each named script independently | `C10-d12`; `C10/plan-review-codex.md:10`; plan amendment |
| C11-d7 | Process substitution hides later mutation | `cat <(printf safe); rm -rf x` | Deny later destructive command | `C11-d7`; `CT/test-verifier-bash-guard.sh:138`; fix `4a7f8d4` |
| C11-d8 | Shell option value hides `-c` code | `bash -o pipefail -c "rm -rf x"` | Deny destructive shell code | `C11-d8`; `CT/test-verifier-bash-guard.sh:139`; fix `4a7f8d4` |
| C11-d9 | Shell here-string bypasses inspection | `bash <<< "rm -rf x"` | Deny executed destructive stdin | `C11-d9`; `CT/test-verifier-bash-guard.sh:140`; fix `4a7f8d4` |
| C11-d10 | `find -exec` shell hides callback | `find . -maxdepth 0 -exec bash -c "rm -rf x" \;` | Deny destructive callback | `C11-d10`; `CT/test-verifier-bash-guard.sh:141`; fix `4a7f8d4` |
| C11-d11 | Unquoted heredoc expands substitution | `cat <<EOF` body containing `$(rm -rf x)` | Deny destructive expansion before consumer runs | `C11-d11`; `CT/test-verifier-bash-guard.sh:142`; fix `4a7f8d4` |
| C11-d12 | Syntax-only shell falsely denied | `bash -n -c "rm -rf x"` | Allow syntax-only check without executing code | `C11-d12`; `CT/test-verifier-bash-guard.sh:143`; fix `4a7f8d4` |
| C11-d13 | Command lookup falsely denied | `command -p -v /bin/rm` | Allow lookup-only invocation | `C11-d13`; `CT/test-verifier-bash-guard.sh:144`; fix `4a7f8d4` |
| C11-d14 | Grouped curl pipeline bypasses guard | `(curl http://x) \| sh` | Deny download piped to shell through groups | `C11-d14`; `C11/summary.md:29-30`; fix `7d997b7` |
| C11-d15 | GNU `env -S` hides command | `env -S 'rm -rf x'` | Deny split-string destructive command | `C11-d15`; `C11/summary.md:29-30`; fix `7d997b7` |
| C11-d16 | Case pattern false positive | `case x in a) true;; rm) true;; esac` | Do not execute or classify pattern token as command | `C11-d16`; `C11/summary.md:29-31`; fix `7d997b7` |
| C11-d17 | Heredoc folding hides following command | Folded heredoc terminator followed by `rm -rf x` | Deny exposed destructive command | `C11-d17`; `C11/summary.md:29-31`; fix `7d997b7` |
| C11-d18 | Parser failure permits unknown shell | Nested case pattern inside command substitution followed by mutation | Deny when parsing/classification is uncertain | `C11-d18`; `C11/summary.md:32-35`; fix `1d76250` |
| C11-d19 | `coproc` hides destructive command | `coproc rm target` | Deny mutation concealed by `coproc` | `C11-d19`; `C11/codex-review.md:2`; accepted, no code fix |
| C11-d20 | Dangling boolean operator allowed | `printf safe &&` | Deny incomplete shell syntax | `C11-d20`; `C11/codex-review.md:3`; accepted, no code fix |
| C11-d21 | Shell stdin bypasses body inspection | `bash - <<< "rm target"` | Deny destructive stdin code | `C11-d21`; `C11/summary.md:107-108`; accepted, no code fix |
| C11-d22 | Function body hides mutation | `function f { rm target; }; f` | Deny destructive function body | `C11-d22`; `C11/summary.md:109`; accepted, no code fix |
| C11-d23 | Interpreter one-liners bypass Bash denylist | `perl -e`, `python -c`, or `node -e` writing a file | not recorded — item scored by judges only (cannot trigger the decision alone) | `C11-d23`; `C11/summary.md:113-114`; accepted, no code fix |
| C11-d24 | ssh/su/flock/watch hide inner mutation | `ssh host cmd`, `su -c`, `flock`, or `watch` wrapping mutation | not recorded — item scored by judges only (cannot trigger the decision alone) | `C11-d24`; `C11/summary.md:113-114`; accepted, no code fix |
| C11-d25 | `env -S` safe string falsely denied | `env -S` with a literal harmless string | Allow harmless literal without false destructive classification | `C11-d25`; `C11/summary.md:115-116`; accepted, no code fix |
| C11-d26 | `git branch --list -- -D` falsely denied | `git branch --list -- "-D*"` | Allow list-only invocation | `C11-d26`; `C11/summary.md:115-116`; accepted, no code fix |
| C13-d1 | Checker scans installed checkout | Invoke installed checker from task worktree with committed secret while install stays on main | Scan caller task repository and report its secret | `C13-d1`; `C13/rounds/round-1/codex-review.md:2`; fix `c2a50c2` |
| C13-d2 | Quoted JSON secret key not matched | Add `{"token":"AbCdEf0123456789AbCdEf0123456789"}` | Detect the JSON property assignment | `C13-d2`; `C13/rounds/round-1/codex-review.md:3`; fix `c2a50c2` |
