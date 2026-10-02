# Historical gate evidence for the implementer/investigator A/B

This directory records which review or verification gate reported each concrete defect in the cc-orchestra task corpus. The data informs the proposed A/B in [protocol.md](protocol.md); it does not choose a default lane. No A/B arm was run here.

## Sources and method

The corpus root is `/home/janghun/.claude/orchestra-state/worktrees/cc-orchestra`. The frozen list in `self-hosting-36/.orchestra/36-gate-tabulation-ab-design/evidence/corpus.txt` has 44 included task directories; [inventory.csv](inventory.csv) lists all 44 and the exclusions. Four Codex crawl batches wrote `rows-A.csv` through `rows-D.csv` under that task's `evidence/` directory. [tabulation.csv](tabulation.csv) merges them, while [tabulation.md](tabulation.md) explains the row contract, anchor cases, reconciliation, and the generated tables.

Each CSV row is a design, diff, or post-merge finding with a recorded disposition. It separates first and independent reporters from gates that ran without a report and gates that did not run. Detailed `rounds/` evidence wins over `summary.md` when they disagree. A later-task report is attributed to the introducing task's defect but is kept distinct from its original gate results. Attribution comes from surviving records, not fresh reruns of every old gate.

## Headline counts

Among 168 non-rejected Codex-written diff and post-merge defects, 45 were reported only by Claude-family checks, including later-task checks. Of those 45, Codex verify or review ran over and missed 29; the other 16 were caught before any Codex gate ran. Among those 29 Codex-missed findings, 28 were critical-risk, 1 normal-risk, 0 low-risk, and 0 trivial-risk; normal-risk tasks do not run the Opus verifier. “Claude-only” therefore includes lead catches made before Codex gates ran. Of 116 Codex-written defects reported only by Codex-family gates, a Claude-family check ran over and missed 97. Among 1 comparable Claude-written defect, 0 were reported only by Codex gates. The matrix and row IDs in `tabulation.md` show the underlying attribution. These counts describe reported defects, not a defect rate per implementation or a model ranking.

The sample is small and dependent: tasks share this repository and reviewers, gates and model/effort settings changed across eras, and Codex-written diffs dominate the observed defects. The one Claude-written defect gives almost no reverse-family evidence. Some early rounds survive only in summaries, which are marked with lower confidence in the CSV.

## Verify

From the repository root, run `python3 eval/gate-ab/recount.py check`. Set `GATE_AB_ROOT` if the corpus is available at another path. The stdlib-only checker validates source paths, the gate partition, inventory counts, and exact agreement between each generated Markdown block and the CSV. `python3 eval/gate-ab/recount.py render` prints the four derived blocks.

A file-level triage evaluation built on this corpus lives in [../diff-triage/](../diff-triage/README.md).

## Open limitations (not re-gated)

At the final gate on `5bcf30b`, Codex verify passed 6/6 and Codex review returned BLOCKING 1 / NONBLOCKING 1. The user accepted the outcome after the round cap. The two subsequent fixes below have not had another gate run.

- [Protocol M4 cost](protocol.md#metrics-and-collection): the review found that mixed-arm wave quota snapshots could not establish mean Claude session percentage points per S or O run. The per-run measurement fix was made after the final gate and is ungated.
- [`recount.py check`](recount.py): the review found that a CSV row with the wrong field count caused a traceback. Field-count reporting was fixed after the final gate and is ungated.
- [Protocol blinding and judges](protocol.md#blinding-fixed-rubric-and-judges), step 8: judges run in a per-case directory containing other arms' anonymized artifacts. Arm labels are hidden, but that shared directory remains a documented limitation.
- `lead-review-unrecorded` appears on 13 rows: `C10-d8`–`C10-d10`, `C13-d1`–`C13-d2`, `C14-d5`–`C14-d11`, and `S18-d1`. Their `lead-diff-review` gate is counted as not run, making recorded lead misses a lower bound.
- `C10-d8`/`C10-d9` have medium-confidence summary-only round attribution. `J02-d12`–`J02-d16` rely on a historical lead transcript outside the CSV corpus root; its line references are in their notes.
- The Claude-written comparison has one non-rejected diff-defect row, `C14-d11`. It does not support a reverse-family inference.
