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
