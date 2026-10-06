# Jev shadow Stage 1 review

`analyze.py` applies the [pre-registered decision criteria](../jev-shadow-decision.md)
to a shadow log using only Python's standard library. It opens inputs read-only,
prints aggregates, and makes no network requests or configuration changes.

```bash
python3 eval/jev-shadow-stage1/analyze.py --log /path/to/log.jsonl --policy jev-policy.conf
bash tests/test-jev-stage1.sh
```

The policy defaults to the repository's `jev-policy.conf`. Log precedence is
`--log`, `JEV_STAGE1_LOG`, then the policy's `JEV_SHADOW_LOG` under
`CC_ORCH_STATE_DIR` (default `~/.claude/orchestra-state`); an absolute policy log
path is used directly. `--enabled-date` and `--review-date` override the fixed
defaults `2026-09-22` and `2026-10-06`. Every verdict exits 0; input errors exit 2.

The task's committed analysis plan fixes these choices (A–G):

- **A — Population:** implement, ok, exact records with finite numeric reasoning
  and confidence, integer duration >= 0, integer exit, integer attempts >= 0,
  and string difficulty; booleans are not numbers. Invalid fields are counted
  as exclusions; malformed JSON lines and non-objects are counted separately.
- **B — Sufficiency:** at least 14 calendar days since enabling and 30 analysed
  records. Also report the first-to-last timestamp span over all valid objects
  and the resulting alternative verdict. Unparseable timestamps are counted;
  fewer than two gives `n/a`. Offset-free timestamps are interpreted as UTC.
- **C — Signal:** Spearman uses average ranks for ties. Resample record pairs
  10,000 times with `random.Random(20261006)` and `randrange(n)`. Drop undefined
  correlations, then take sorted indices `int(.025 * B)` and `int(.975 * B) - 1`
  for the 95% interval, where B is the number defined. Require rho >= 0.30 and an
  interval excluding zero; fewer than 10 records is insufficient.
- **D — Savings:** require >= 20% raw mechanical answers with confidence >= the
  current policy's `JEV_SHADOW_MIN_CONFIDENCE`; ignore stored model suggestions.
  Fewer than 10 records is insufficient.
- **E — Risk:** compare `codex_exit != 0 or attempts > 1` for that confident
  mechanical group against the remaining analysed records. Require the
  mechanical rate to be no higher; either group below 10 is insufficient.
  Also count mechanical answers regardless of confidence, for information only.
- **F — Verdict:** failed sufficiency gives `inconclusive`; otherwise any
  criterion 2–4 not met gives `do not adopt`, all met gives
  `proceed to Stage 2 discussion`, and remaining insufficiency gives
  `inconclusive`. A pass never authorises a model switch.
- **G — Degeneracy and output:** empty/all-malformed logs are inconclusive;
  zero-variance rho and an interval with no defined resamples are `undefined`.
  Compare unrounded values; print rho/bounds to four decimals and shares/rates
  to one decimal. Identical inputs produce identical output.

Output and reports are aggregate only: no task text, task names, ids, thread ids,
or per-record rows. Per-record working files must stay outside every worktree;
the tests create synthetic fixtures under a temporary directory and always pass
explicit fixture log/policy paths. The log cannot show whether a cheaper model
would have succeeded.
