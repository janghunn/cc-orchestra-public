---
name: orch-lane-dispatch
description: Quick-reference for choosing between Codex lanes (astra/sol/luna) and Claude dev exceptions when dispatching Tier 3 implementation work in cc-orchestra, including the six recognized dev exceptions and the --fast vs --fast-mode distinction. Use before spawning a Codex implement/review/verify call or a dev Agent call, or when a summary needs its LANES field filled in with an exception tag.
---

# Choosing a Tier 3 lane

## Default: Codex implements
One work unit → `codex-run implement`. A second, file-disjoint concurrent unit → add
`--lane <short-name>` and record the lane assignment in `plan.md`. Cap: 2 concurrent Codex
implement threads per task.

## The six dev exceptions (and only these)
A Claude `dev-N` is justified only by one of:
1. **Fallback** — Codex exit 3 (quota) or 4 (auth) on this unit. (Exit 6 is model-unavailable —
   retry `--model sol|terra` first, that's not a dev exception.)
2. **Context** — the unit needs more than Sol's 272k window; devs have 1M.
3. **Steering** — needs turn-by-turn correction mid-build; Codex `resume` is coarser (one message
   per exchange, no partial-progress visibility).
4. **GPU** — the Codex sandbox can't reach the required device/local runtime.
5. **Fresh eyes** — Codex failed the *same* unit twice; use `dev-opus-N`, not a normal Sonnet dev.
   `--escalate` (Sol @ max) is the intermediate step to try before this.
6. **Sparing** — `orch-model-guard lanes` reports `dispatch=codex-sparing`.

Every dev dispatch needs its exception tag recorded on `summary.md`'s `LANES` field. A dev used
without one of these six tags is worth the orchestrator questioning.

## `--fast` vs `--fast-mode` — different knobs
- `--fast` downgrades the model to Luna @ high. Use for small/fallback review or investigate work
  where full Astra/Sol depth isn't needed.
- `--fast-mode` keeps the resolved Astra/Sol/Terra model and effort, but turns on Codex's official
  Fast service tier for that call. Costs more Codex credit — only use it when latency is the
  actual bottleneck under `dispatch=codex-first`, never under `codex-sparing`.

Record whichever you used in the relevant summary field (`LANES`, `INVESTIGATION`, or `GATES`) as
`model@effort+fast-mode`, and record an Astra→Sol fallback as
`gpt-5.6-sol@xhigh (fallback-from:gpt-6-astra)`.

## Exit code cheat sheet
| exit | meaning | action |
|---|---|---|
| 3 | quota | implement → dev fallback; review/verify → retry `--fast` once |
| 4 | auth | note in summary, fall through to Claude fallback |
| 5 | timeout | note in summary, fall through to Claude fallback |
| 6 | model unavailable | retry with `--model sol|terra` before anything else |
