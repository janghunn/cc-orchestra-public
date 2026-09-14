---
name: orch-context-budget
description: How to trim an over-budget brief.md/plan.md/summary.md back under cc-orchestra's BRIEF_MAX_BYTES/PLAN_MAX_BYTES/SUMMARY_MAX_BYTES limits without losing the substance a downstream reader needs. Use when the harness's automated artifact-size check warns a file is over budget, or before writing a long plan/summary you suspect will be.
---

# Trimming an over-budget artifact

## The budgets
Read `model-policy.conf` for the current numbers rather than trusting these — at last check:
- `brief.md` — 12 KiB (`BRIEF_MAX_BYTES`)
- `plan.md` — 40 KiB (`PLAN_MAX_BYTES`)
- `summary.md` — 20 KiB (`SUMMARY_MAX_BYTES`)

The harness's automated artifact-size check warns (or errors, under `--strict`) when a file exceeds
its budget. The fix is never to silently truncate — it's to move detail somewhere a reader can
still find it.

## Where detail goes instead
- Raw evidence, full command transcripts, repeated investigation rounds → `evidence/` under the
  task directory, linked from `plan.md`'s Findings.
- Per-round review/fix history → `rounds/<n>.md`, linked from `summary.md`, with only the final
  outcome inline.
- A long list of file:line citations → keep the 3-5 most load-bearing inline, move the rest to a
  linked evidence file.

## What must stay inline, never moved
- The final `Approach`, `Changes`, `Do not touch`, and `Verification` sections of `plan.md` — a dev
  or gate reading only `plan.md` must be able to execute correctly without opening a linked file.
- The `summary.md` final report block itself (the one the lead returns as its last message) — this
  has its own hard cap (25 lines) independent of the file budget and is never trimmed by moving
  content elsewhere; it is written short from the start.

## Trimming without losing substance — order of operations
1. Cut repetition first — restated context, re-quoted brief text, restated evidence already
   implied by a `file:line` citation.
2. Collapse multiple investigation rounds that reached the same conclusion into one paragraph with
   a pointer to the raw rounds.
3. Move raw traces (full command output, full diffs already visible in `git diff`) to a linked
   file; keep only the verdict and the one line of output that proves it.
4. Only after 1-3, consider whether a section is genuinely out of scope for this file's audience
   (e.g. `plan.md` doesn't need the brief's full prose restated — a link back to `brief.md`
   suffices).

Re-run the harness's automated artifact-size check for the task directory after trimming to confirm
the size actually dropped under budget, not just that it looks shorter.
