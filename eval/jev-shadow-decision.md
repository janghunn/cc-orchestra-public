# Jev shadow: pre-registered decision criteria

Status: written before any shadow data was analysed. Shadow logging was enabled on this installation in commit 67a36d0.
Amend only by appending a dated correction; never edit a criterion after looking at results.

## What the shadow log can and cannot show

Dispatch always uses the model chosen by the existing routing (normally Astra). Jev's suggestion is only recorded.
So the log can show whether Jev's difficulty classification tracks observed difficulty proxies at the model that
actually ran (duration, retries, failure). It can NOT show whether a cheaper model would have succeeded, because that
was never tried. Adopting downgrades therefore needs a second, live experiment (Stage 2) that this document does not authorise.

## Stage 1: observational review (earliest 2026-10-06)

Data: `codex-shadow.jsonl`, implement mode, records whose observation is `exact`, read with `orch-jev shadow-report`
and, for the statistics below, directly from the log fields (difficulty, difficulty_confidence, reasoning, duration_ms, attempts, codex_exit).

1. Sufficiency. At least 14 days of use and at least 30 exact-observed records. Otherwise the verdict is `inconclusive`;
   extend up to 8 weeks total. Any group compared below must hold at least 10 records, else it is reported as insufficient.
2. Signal. Spearman correlation between `reasoning` and `duration_ms` is at least 0.30 and its 95% bootstrap interval excludes 0.
3. Savings potential. Records where Jev suggested the `mechanical` tier with confidence at or above the policy threshold
   are at least 20% of exact-observed records. Below that, downgrades would not matter.
4. No hidden risk. The failure-or-retry rate (codex_exit != 0 or attempts > 1) among `mechanical` records is not higher
   than among all other records.

Verdicts: all four met -> `proceed to Stage 2 discussion`. Any not met with enough data -> `do not adopt`, turn shadow off
(`JEV_SHADOW_ENABLED=0`), keep the code. Insufficient data after 8 weeks -> `inconclusive`, turn shadow off.
A pass never means "safe to switch models"; it only justifies designing Stage 2.

## Stage 2 (not authorised here)

Needs a separate written approval and its own brief. Sketch: route only `mechanical` suggestions above the confidence
threshold to a cheaper model for a fixed small number of calls, compare their gate outcomes with the usual model, and stop at
the first gate failure attributable to the model.

## Privacy reminder

While shadow is on, the `brief.md` of each first-run implement call (without its Risk section) is sent to the Jev API
after the egress guard, capped by `JEV_SHADOW_MAX_BYTES`. Turn it off with `JEV_SHADOW_ENABLED=0`.

## 2026-10-06: Stage 1 result

Stage 1 was run mechanically per the criteria above on the task-start snapshot (324 records, 78 exact-observed
implement records). Verdict: `do not adopt` (criterion 3: 1.3% confident-mechanical vs the 20% threshold).
Under the alternative first-to-last-span reading of "14 days", the verdict would be `inconclusive`.
See [jev-shadow-stage1/report-2026-10-06.md](jev-shadow-stage1/report-2026-10-06.md).
Turning shadow off as prescribed is a separate change awaiting user approval and has not been made.
No criterion above was edited.
2026-10-06: JEV_SHADOW_ENABLED set to 0 in jev-policy.conf per this rule; code kept.
