# Deferred candidates from the status sync (2026-10-07)

This file follows the entry shape and append-only rules of ../IMPROVEMENT-CANDIDATES.md. Each entry is a proposal for a human to weigh; none is approved. Code references were checked in the task-74 checkout at `6474020`; historical measurements and unverified live behaviour are labelled below.

### 2026-10-07 — Re-enable `orch-gc apply` after scan fixes and deletion review
- **Source:** Task 64 (`orch/64-orch-gc`, merge `6474020`); current `bin/orch-gc:725`; preserved deletion implementation at `fb7e67e:bin/orch-gc:762` on that branch.
- **Summary:** The shipped command scans and classifies checkouts, but `apply` refuses with exit 1 and deletes nothing. Re-enabling it needs a separate follow-up after the scan fixes.
- **Critical assessment (cc-orchestra-specific):** `bin/orch-gc:725` is an unconditional refusal; `fb7e67e` still contains `delete_item`, fd-relative `rmtree` and the old apply path, verified with `git show`. That code is reference material, not evidence that deletion is now safe. Scan fixes, dry-run overrides and codex-runs fallback are in progress, orch/71..73; no separate candidates for those fixes are added here. Re-check the corrected scan and deletion path before enabling apply; no deletion was exercised for this sync.
- **Status:** NEW

### 2026-10-07 — Add the missing shell suites to runtime CI
- **Source:** Task 64's deferred CI finding; `.github/workflows/runtime-tests.yml:18` through its final step and the current `tests/test-*.sh` inventory.
- **Summary:** Runtime CI does not run `tests/test-orch-gc.sh`, `tests/test-accepted-status.sh`, `tests/test-compact-context.sh`, `tests/test-compaction-replay.sh`, `tests/test-diff-triage.sh`, `tests/test-install-dry-run.sh`, `tests/test-jev-eval.sh`, `tests/test-jev-stage1.sh` or `tests/test-mods-observer.sh`.
- **Critical assessment (cc-orchestra-specific):** These nine scripts are absent from the workflow and its listed suites' shell-suite calls, so their task-local checks do not establish ongoing CI coverage. A filename-only comparison also flags `tests/test-usage-cost.sh`, but that suite already runs through `tests/test-policy.sh:1903` and is not a coverage gap. Select any local-model or Claude CLI prerequisites deliberately when adding jobs; this sync checked source wiring, not a hosted Actions run.
- **Status:** NEW

### 2026-10-07 — Repair registry noise that keeps finished clones at CAUTION
- **Source:** Task 64 summary and sibling checkout evidence `self-hosting-64/.orchestra/64-orch-gc/evidence/realhost-scan-r5.txt:40`; current registry parsing/classification at `bin/orch-gc:354` and `:598`.
- **Summary:** The task-64 summary reports collapsed registry rows for clones 44–63. Its final saved scan is narrower: clones 44–47 are SAFE, while 48–63 are CAUTION; most of the latter say `no registry row`, and clone 57 also has unmerged work. Repair registry records before interpreting those classifications as cleanup eligibility.
- **Critical assessment (cc-orchestra-specific):** The parser accepts one seven-field row per line (`bin/orch-gc:356`); malformed mentions add CAUTION (`:603`), missing matches add CAUTION (`:621`), and unrecognised/open statuses add DANGER (`:616`). This supports conservative handling of registry noise, not weakening the guard. The blanket claim that all clones 44–63 currently have CAUTION because of collapsed rows is unverified: the saved final scan contradicts that range, and this sync did not read or repair the live registry or run a new host scan.
- **Status:** NEW

### 2026-10-07 — Retire the unused `LANES_CODEX_SPARE_PCT` setting
- **Source:** Task 62 (`orch/62-lanes-single-algorithm`, merge `ee42ec2`, included in `91a39bb`); `model-policy.conf:55`, `bin/orch-model-guard:303`, `bin/orch-policy-rev:16`.
- **Summary:** `LANES_CODEX_SPARE_PCT=90` remains in model-policy.conf after legacy lanes delegated its decision to runtime lanes. Remove the unused setting and update the surrounding percent-rule explanation in a policy revision change.
- **Critical assessment (cc-orchestra-specific):** A runtime-code search finds no consumer of the setting; its definition remains in model-policy.conf and a negative assertion remains in `tests/test-runtime.sh:676`. Dispatch uses runtime pressure ranks and the pin (`lib/orch-budget-commands.sh:117`). `bin/orch-policy-rev` hashes model-policy.conf, so even retiring the stale comment changes the revision and requires roster regeneration/installation. This is policy cleanup, not a change to the current dispatch decision.
- **Status:** NEW

### 2026-10-07 — Separate `install.sh --check` from budget refresh writes
- **Source:** Task 65 (`orch/65-install-dry-run`, merge `afcef0a`, included in `6474020`); `install.sh:423`, `lib/orch-budget-metrics.sh:162`, `lib/orch-budget-state.sh:164`.
- **Summary:** The hybrid install check calls `orch-model-guard-runtime budget --compact`, which refreshes usage/state; it is not a read-only inspection of installed files.
- **Critical assessment (cc-orchestra-specific):** The call reaches `ensure_budget`: a stale Claude snapshot invokes the legacy `check`, and Codex usage refresh can write the budget snapshot/lock through `budget_set` (`lib/orch-budget-state.sh:6`, `:172`, `:175`). This behaviour is documented at `OPERATIONS.md:98`; the dry-run implementation does not remove it. Decide whether check should display cached usage or omit the poll, preserving separate refresh commands. Verified by tracing current code only; no live install/check was run for this sync.
- **Status:** NEW

### 2026-10-07 — Verify the mods observer in one opt-in live session
- **Source:** Task 66 (`orch/66-mods-observer`, merge `6aa591e`, included in `6474020`); `mods/orch-spawn-observer/README.md:59` and `hooks/register.mjs:124`/`:163` within that plugin.
- **Summary:** Live alias resolution, the spawn/step agentId join and profile effort reaching `turn.step` remain unverified. A follow-up can load `claude --plugin-dir <repo>/mods/orch-spawn-observer` for one opt-in session and inspect `spawn-observer.jsonl`.
- **Critical assessment (cc-orchestra-specific):** Current code joins spawn results to steps by agentId and records the step input's effort; its README explicitly distinguishes stubbed CLI/Node checks from live evidence (`mods/orch-spawn-observer/README.md:63`). Check an actual managed profile's expected model/effort against those records, keeping missing fields unknown; input effort is not proof of the final executed effort. This sync inspected code and documentation only and did not start a live plugin session or claim enforcement.
- **Status:** NEW
