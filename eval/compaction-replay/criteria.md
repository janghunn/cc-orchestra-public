# Frozen criteria — compaction replay evaluation

Status: FROZEN. The lead commits this file on its own before any policy is scored
on the real transcript corpus, and cites that commit in the delivery summary and
in `evidence/real-run.md`. Before freezing, only an aggregate census of the corpus
(file counts, record types, sizes, identifier syntax counts) was inspected; no
policy had been scored on real data. Changing any number below after the real
run invalidates the run.

## Arms

- P0 keep everything — reference only, never a verdict arm.
- P1 recency (last 10 results), P2 deterministic heuristics, P3 local-model
  keep/drop (optional). All share the pinned tail of the last 6 messages and the
  300-character truncation.
- P3 is a verdict arm only when the real local model ran (`--p3 local` with a
  passing preflight). A skipped P3 is reported as `P3 skipped: <reason>` and is
  not a result. Fake-scorer output is a demonstration and never a verdict arm.

## Hard rule (pre-registered by Tier 1)

An arm that loses any needed full agentId (`a` + 16 lowercase hex) at any
evaluated cut, in any stratum including real compaction boundaries, is
disqualified: verdict `do not pursue`, regardless of other numbers.

## Thresholds (point estimates; bootstrap intervals are descriptive only)

| metric | requirement |
|---|---|
| needed-token recall, `path` | >= 0.95 |
| needed-token recall, `sha` | >= 0.95 |
| needed-token recall, `error` | >= 0.90 |
| share of pre-cut tool-result text bytes removed | >= 0.30 |

Each recall threshold must hold pooled over all evaluated cuts AND separately in
each file-kind stratum (`main`, `subagent`). The bytes-removed threshold applies
to the pooled value.

## Minimum sample sizes

- Pooled: at least 30 files with >= 1 evaluated cut; at least 20 needed
  `agentid` instances; at least 100 needed instances of each of `path`, `sha`,
  `error`.
- Per file-kind stratum (`main`, `subagent`): at least 10 files with >= 1
  evaluated cut and at least 30 needed instances of each of `path`, `sha`,
  `error`.
- A cell below its minimum prints `INSUFFICIENT DATA`. The agentId hard rule
  still disqualifies on any observed loss even when the agentId count is below
  its minimum.

## Decision procedure (per arm, mechanical, in this order)

1. Any lost needed agentId -> `do not pursue` (reason `agentId lost`).
2. Any threshold failed in a cell with sufficient data -> `do not pursue`.
3. Any required cell insufficient -> `inconclusive`.
4. Otherwise -> `proceed to design discussion`.

Overall verdict: `proceed to design discussion` if at least one verdict arm
proceeds; otherwise `inconclusive` if at least one verdict arm is inconclusive;
otherwise `do not pursue`.

## Uncertainty

95% percentile bootstrap, resampling whole files with replacement, seed
`20261002`, B = 2000, linear interpolation of quantiles. Descriptive only.

## Scope of a pass

`proceed to design discussion` means only that a design discussion is
warranted. It never authorises a live compaction hook, a Claude Code mod, a
runtime change or any external service.
