# Working on cc-orchestra itself

cc-orchestra is a self-hosting, multi-agent delivery harness. This guide is for coding
agents editing the harness's own source in a task checkout.

Read [GLOSSARY.md](GLOSSARY.md) for the harness's own terms and where one word has several meanings.

## Directory map

| Path | Contents |
|---|---|
| `bin/` | Launchers, lane wrappers, routing and diagnostic commands; `bin/codex-run-runtime` is the runtime Codex lane wrapper. |
| `agents/` | Per-agent-type prompts, including `agents/orchestrator.md`; these are role definitions, not directory-wide guidance. |
| `skills/` | Reusable workflow instructions for dispatch, acceptance criteria and verification. |
| `hooks/` | Session context, status, model notices and workflow guards. |
| `lib/` | Shared shell and Python support for runtime commands. |
| `templates/` | Source templates for generated lead, developer and verifier profiles. |
| `.orchestra/` | Task briefs, plans, implementation reports and gate evidence. |

## Authoritative policy

| File | Responsibility |
|---|---|
| `model-policy.conf` | Model/effort defaults, quota fallback, lane defaults and artifact/gate budgets. |
| `budget-policy.conf` | Runtime pressure thresholds and dispatch routing. |
| `guardrails.json` | Orchestrator session permissions and hooks. |
| `jev-policy.conf` | Jev advisory and shadow-routing settings. |
| `codex-policy.json` | Codex-only role routing and concurrency settings. |

Change policy at its source instead of hard-coding independent values in runtime scripts
or hand-editing generated profiles. Runtime scripts read the policies;
`build-roster.sh` and `build-roster-runtime.sh` generate the agent roster from policy and
templates. See `OPERATIONS.md` for installation and runtime details.

## Task branches and artifacts

Use the assigned task branch `orch/<NN>-<slug>` and matching artifact directory
`.orchestra/<NN>-<slug>/`. Read that task's `brief.md` and `plan.md` before implementation;
honor their scope and verification requirements.

The canonical artifact contract is in `README.md`, under "작업 산출물":

| Artifact (relative to the task directory) | Author | Purpose |
|---|---|---|
| `brief.md` | Orchestrator | Goal, scope, acceptance, verification and risk. |
| `codex-intake.md` | Codex | Ownership, test and risk map before implementation. |
| `plan.md` | Lead | Findings and final implementation design. |
| `codex-investigation.md` | Codex | Investigation evidence. |
| `plan-review-codex.md` | Codex | Independent design cross-check. |
| `impl-report-codex[-lane].md` | Codex | Implementation and test report. |
| `impl-report-devN.md` | Claude dev | Exception implementation report. |
| `review.md` | Lead | Final review of the actual diff. |
| `codex-verdict.md` | Codex | Executable verification. |
| `codex-review.md` | Codex | Independent semantic/regression review. |
| `verdict.md` | Claude verifier | Fallback or additional critical-task verification. |
| `summary.md` | Orchestrator (lead's returned block, verbatim; Codex-only leads write it) | Final status and gate evidence. |

These are artifact names and patterns, not files required to exist for every task;
the task's workflow and risk determine which are produced.

## Installed runtime verification

For changes to installed runtime pieces, use the install/check pairing from
`OPERATIONS.md` ("Install or upgrade") and `README.md` before considering the change live:

```bash
./install.sh
./install.sh --check
```

Re-run `./install.sh --check` after installing changes. A source edit alone does not
establish that the installed runtime is current. Follow the task's verification commands
as well; installation checks do not replace them.

## Live checkout guardrail

`/home/janghun/cc-orchestra` is the live installed checkout, also reached through
`~/.claude/orchestra`. In orchestrator/Tier-1 sessions, `guardrails.json` deliberately denies
direct edits with `"Edit(//home/janghun/cc-orchestra/**)"` and
`"Edit(//home/janghun/.claude/orchestra/**)"`. Both the real path and symlink are covered
so the running hierarchy cannot rewrite its own instructions mid-run.
Do self-hosting work in the assigned isolated checkout and hand changes back through
the task branch.

There is no root `CLAUDE.md` because Claude Code >= 2.1.277 reads `AGENTS.md` natively; restore a `CLAUDE.md` containing `@AGENTS.md` if an older Claude Code version or a restricted context that cannot load `AGENTS.md` directly needs support.
