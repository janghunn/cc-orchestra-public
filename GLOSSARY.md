# cc-orchestra glossary

Terms the harness uses with a specific meaning, each with the file that defines it. If a definition here disagrees with the cited file, the file wins; fix this page. English only; the Korean docs are the `*.ko.md` files.

## Roles and addressing

- **orchestrator / Tier 1** — The top-level agent that talks to the user, splits a request into tasks, assigns each to a lead slot, tracks them, and never writes product code. Defined in `agents/orchestrator.md`.
- **Tier 2 / 3 / 4** — Tier 2 is the leads, Tier 3 is implementation (Codex lanes by default, `dev-*` as exceptions), Tier 4 is verification gates. See the tier diagram at the top of `agents/orchestrator.md`.
- **lead** — The Tier 2 agent that owns exactly one task end to end: investigates, writes `plan.md`, dispatches implementation, reviews the diff, runs the gates. Template: `templates/lead.md.tpl`.
- **slot** — A named seat for a lead (`lead-alpha`, `lead-bravo`, `lead-charlie`, `lead-delta`) or a dev (`dev-1` to `dev-3`). The slot name is the human-facing label. `agents/orchestrator.md`, README "Git / worktree 원칙".
- **agentId** — The `a…` id returned when an agent is spawned. `SendMessage` routes by agentId, not by slot name, so Tier 1 records it in the registry the moment a lead starts. `agents/orchestrator.md`.
- **registry** — `.orchestra/REGISTRY.md` in the project, one row per task (slot, full agentId, task, branch, dir, status, last update). It is the source of truth for routing. `agents/orchestrator.md`.
- **DIRECTIVES** — `.orchestra/DIRECTIVES.md`: one dated line per standing directive the user stated explicitly, changed only on the user's word. Re-injected after compaction by `hooks/orch-compact-context.sh`. `agents/orchestrator.md`.

## Work and artifacts

- **brief** — `brief.md`, written by Tier 1: goal, scope, acceptance, verification, risk. README "작업 산출물".
- **intake** — The read-only `codex-run intake` call Tier 1 uses to map ownership, tests and risk before writing a brief; its output is `codex-intake.md`. `agents/orchestrator.md`.
- **plan** — `plan.md`, written by the lead: findings and the final design a developer with no context could execute. `templates/lead.md.tpl` (Phase B).
- **summary** — `summary.md`: the lead's final report block, saved verbatim by Tier 1. Leads cannot write it. `templates/lead.md.tpl` (Phase G), README "작업 산출물".
- **task directory** — `.orchestra/<NN>-<slug>/`, holding a task's artifacts. README "작업 산출물".
- **round** — One implement-then-verify cycle after a gate fails. The cap is 2 for trivial/low/normal and 3 for critical, plus one more only if `brief.md` contains `EXTRA GATE ROUND: approved`. `templates/lead.md.tpl` (Phase F), README "Gate 정책".

## Lanes, gates and risk

- **lane** — A route for Tier 3 work. The Codex lanes (`codex-run implement`, `--mech`, a named `--lane <name>`) are the default; a Claude **dev** (`dev-1` to `dev-3`, `dev-opus-*`) is used only for a recorded exception. `templates/lead.md.tpl` ("Provider lanes").
- **gate** — An independent Tier 4 check that must pass before a task reports PASS: `codex-verify` (executes the contract), `codex-review` (hunts semantic defects) and, for critical risk, `claude-verifier` (the Opus `verifier`). `README.md` "Gate 정책", `templates/lead.md.tpl` (Phase E).
- **RISK** — The brief's risk level: `trivial` (lead self-check only), `low` and `normal` (Codex verify plus review), `critical` (also the Opus verifier). `README.md` "Gate 정책", `agents/orchestrator.md`.
- **profile (lead profile)** — Which model and effort a lead runs on: `light`, `normal`, `critical`, `critical-xhigh`. Chosen per task from risk and quota pressure; table in `OPERATIONS.md` "Dynamic routing", values in `model-policy.conf`.
- **pressure** — A quota state (healthy, watch, tight, critical) computed from usage and time to reset; it drives routing and dispatch. `OPERATIONS.md` "Dynamic routing", `budget-policy.conf`.
- **pin (Codex pressure pin)** — `CODEX_PRESSURE_PIN="healthy"` in `budget-policy.conf` holds Codex routing on the healthy rows regardless of real usage. The real state is still recorded. `OPERATIONS.md` "Codex pressure pin".
- **PASS vs ACCEPTED** — `PASS` means the required gates passed. `ACCEPTED` is a status only the user can cause, after seeing the gate results; it is an acceptance with exceptions, not a PASS and not a merge approval. `agents/orchestrator.md`, `OPERATIONS.md`.

## Places things live

- **archive: vault vs raw store** — `orch-archive` keeps readable text and notes in a private git **vault** (default `~/orchestra-vault`) and lossless compressed copies in a **raw store** outside git (`~/.claude/orchestra-archive/raw`). `OPERATIONS.md` "Archive", `archive-policy.conf`.
- **session** — A persistent, named `cc-orch session`: a tmux session, usually with its own git worktree and branch. `OPERATIONS.md` "Persistent sessions and worktrees".
- **worktree** — A separate working folder of the same git repo on its own branch. A session's worktree lives under `~/.claude/orchestra-state/worktrees/<project>/<session-name>`; a lead may also use `<repo>/.orchestra/wt/lead-<slot>`. `OPERATIONS.md`, `templates/lead.md.tpl` (Phase A0).
- **task clone** — The isolated checkout a self-hosting task works in, handed back through the task branch `orch/<NN>-<slug>` instead of editing the live install. `AGENTS.md` "Live checkout guardrail".

## Same word, different meaning

- **task** — In the harness, a unit of work with a brief and a directory under `.orchestra/` and a branch `orch/<NN>-<slug>`. Tier 1 also mirrors the task list into `TodoWrite` items (`agents/orchestrator.md`, "Decompose"), which are only checklist entries. A Claude Code background task is a separate runtime concept and is not defined by this repo.
- **session** — A `cc-orch session` (tmux plus worktree, see above) versus a single Claude conversation or a Codex thread inside it. A conversation can be compacted while the session continues (`OPERATIONS.md`, "Compaction recovery hook").
- **profile** — A lead profile (`light`/`normal`/`critical`/`critical-xhigh`, from `model-policy.conf`) versus the `cc-orch --profile` choice for the Tier 1 session (`normal`, `critical`, `deep`, in `bin/cc-orch`). The names overlap but are different sets.
- **route** — Model routing (`orch-model-guard route lead <risk> <slot>`, which picks a lead profile; `OPERATIONS.md`) versus the `route-lead-*` agent types, which are the immutable rendered agents it returns. Related, but one is a decision and the other a file.
- **pin** — The Codex pressure pin above versus `orch-model-guard set <model>`, which forces and pins the Claude model (`bin/orch-model-guard` usage text). Separate settings.
- **slot** — A named lead or dev seat (above) versus the "one slot" of the local Jev model server in `OPERATIONS.md`; unrelated.
- **round** — A fix round after a failed gate (above), not a round trip to the orchestrator (the template's "full round trip" is ordinary English).
- **gate** — Tier 4 verification (above), not the `orch-stop-gate.sh` hook in `hooks/`, which is a runtime safety stop-gate (`hooks/orch-stop-gate.sh`).
