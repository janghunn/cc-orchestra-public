---
name: orch-verification-loop
description: What cc-orchestra's own Tier-4 gates (codex-run verify, codex-run review, the Claude verifier) actually require to pass, and the failure patterns leads hit most often in real gate rounds. Use when launching Phase E gates, interpreting a FAIL/INCONCLUSIVE/BLOCKING verdict, or deciding whether a round counts against the retry budget.
---

# Tier-4 verification loop, working notes

## What each gate actually checks
- `codex-run verify` — runs the plan's Verification command(s) from zero context and reports a
  PASS/FAIL/INCONCLUSIVE `codex-verdict.md`. It does not read `review.md`, `impl-report-*.md`, or
  `summary.md` — if it needs those to understand what to run, the plan's Verification section was
  underspecified; fix the plan, not the gate.
- `codex-run review` — hunts semantic defects in the diff against `plan.md`'s intent; reports
  `CODEX-REVIEW: CLEAR | BLOCKING n` with findings. `NONBLOCKING` findings do not fail the gate but
  are worth recording as deferred findings if genuinely out of scope.
- Claude `verifier`/`verifier-normal` — independent, evidence-only, read-only except its own
  verdict file. Never share its own opinion with the codex gates or vice versa; each must reach its
  verdict from a clean slate.

## PASS requires, by risk
- low/normal: `codex-verdict.md` reporting PASS **and** review CLEAR or all BLOCKING findings
  rebutted with evidence.
- critical: the above **plus** the Opus `verifier`'s independent PASS. All three green, no partial
  credit — a 2-of-3 pass is not a critical PASS.
- trivial: no Tier 4 dispatch at all; see the lead template's self-check pattern instead.

## Common failure patterns seen in real rounds
- **Verification command doesn't exist or tests the wrong thing** — caught by `codex-verify`
  returning FAIL/INCONCLUSIVE with "command not found" or "ran successfully but proves nothing
  about the stated goal". Fix: tighten `plan.md`'s Verification section, don't retry blind.
- **Review BLOCKING on scope** — the diff touched a file outside `plan.md`'s Changes list. Fix at
  Phase D (your own review) before the diff ever reaches Phase E; a scope BLOCKING at Phase E means
  Phase D missed it.
- **INCONCLUSIVE from environment drift** — a gate can't reproduce because of a missing dependency
  or an untracked local file the plan didn't mention. Note it as a plan gap, not a code bug, and
  don't spend a round "fixing" code that isn't broken.
- **Rejecting a BLOCKING finding without evidence** — `review.md` needs file:line evidence to
  reject a BLOCKING claim, and you get at most two such rejections per task. Spend them only when
  you are certain; a wrong rejection burns a retry round later.

## Retry budget
A FAIL/BLOCKING from any gate is a failed round for the whole set, not just the gate that failed —
rerun the entire gate set after fixing, never just the one that complained. Cap: 2 rounds for
trivial/low/normal, 3 for critical, unless `brief.md` has `EXTRA GATE ROUND: approved`.
