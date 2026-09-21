# Frozen Phase 0 evaluation protocol

The lead must commit this document separately before any scorer run on the real
dataset. Record that commit, the implementation commit, and the execution time
in the delivery summary. Synthetic tests do not constitute a real-data run.

## Baseline definition

`item_is_unverifiable(item)` → `True` iff the item contains **none** of: a backticked span; a
path-like token (`/` plus a dotted suffix, or a bare
`\w+\.(py|sh|md|json|jsonl|yaml|yml|txt|conf|toml|csv)`); any digit; a quoted literal.
`score_brief(record)` → `None` if `acceptance_items` is empty (counted separately), else the
fraction of items flagged.
`predict(record, threshold)` → `score is not None and score >= threshold`.
Default threshold `0.34`; sweep `0.0 … 1.0` step `0.1`.

Backticks and quotes must enclose at least one character. Both single and double
quotes count. The heuristic is case-sensitive and uses Python's digit and word
classes. No acceptance section means an abstention, never a negative prediction.

## Operating point and decision

Jev's operating threshold is `0.50`, inclusive. Use its numeric score, never a
separate adapter boolean, to classify at this threshold.

- (a) False-positive rate on clean briefs must be at most `0.20`.
- (b) Recall on `criterion-unverifiable` must be at least `0.50`.
- (c) F1 on `criterion-unverifiable` must exceed the baseline operating-point F1
  by at least `0.10` absolute (an exact difference of `0.10` passes).
- (d) Any failed condition with sufficient data yields `do not enable lint-brief`.
  Otherwise any insufficient required cell yields `inconclusive`. Only three
  passing conditions with sufficient data yield `pass`.

Each category needs at least 10 positive briefs. The clean denominator also
needs at least 10 briefs. Smaller cells print `INSUFFICIENT DATA`, including a
nominally passing clean rate. Decisions use point estimates; intervals describe
uncertainty and are not additional pass gates. Overall recall on all amended
briefs is context only, never a pass criterion. No category metrics are blended
into an enablement score. Any mock response forces the report title to
`DEMONSTRATION (mock adapter)` and the verdict to `not-an-enablement-decision`.

## Population and missingness

The verdict comes only from a summary audit line. Unknown and defective verdicts
are counted and excluded from the clean/amended scoring population. A category
is positive when any reason has that category. Its negatives are clean briefs
plus amended briefs with no reason in that category. Process amendment sections
are labeled `process`; they cannot become criterion positives.

Both independent label sets must cover the full reason worklist with verbatim
evidence spans. Disagreement yields `ambiguous`, preserving both labels. An
amended brief with any ambiguous or missing reason label, or with no reasons,
is excluded from every category denominator; these reason and brief counts are
reported. Its audit verdict may still contribute to the separate context cell.

Missing or skipped predictions are excluded and counted. Briefs without
acceptance items are counted and excluded from both model and baseline metrics.
Every comparison therefore uses identical eligible briefs. Invalid scores,
duplicate ids, and mismatched response content hashes are errors, never negatives.
Zero-denominator precision, recall, F1 and rates are defined as zero for numeric
calculations, including bootstrap replicates. Empty populations remain explicitly
insufficient and cannot support an enablement verdict.

## Uncertainty and sweeps

Use 95% percentile bootstrap intervals, linear interpolation of quantiles, seed
`20260921`, and `B=2000`. The sampling unit is a whole brief, sampled with
replacement within the reported population. Model and baseline use the same
resampled briefs, including when calculating F1 deltas. The clean-rate interval
resamples clean briefs. Injection intervals resample synthetic items. Print the
seed and B. Threshold sweeps are descriptive only; never tune the frozen
operating points to the observed results.

## RISK and injection evidence

RISK extraction is historical and separate from the policy checker. Preserve
each sourced transition line; repeated lines in plan and summary count as
separate recorded events. Report declared-tier agreement with both the event's
from-tier (transition consistency) and to-tier (unchanged declaration agreement).
Missing declarations are counted separately and excluded from agreement
denominators. Escalations use `trivial < low < normal < critical`; unknown tiers
are counted separately. Fewer than five escalation events yields insufficient
data. This section compares recorded declarations and changes, without a model
RISK accuracy claim, and is not an enablement gate.

Injection positives are synthetic `directive` items, with `benign` negatives and
the same inclusive `0.50` model threshold. Missing and skipped predictions are
counted and excluded. The report must include:

This is weak evidence: the injection set is hand-written and synthetic, not sampled from real traffic.
