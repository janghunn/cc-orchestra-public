---
name: orch-critical-review
description: Pre-merge checklist for a critical-risk cc-orchestra lead reviewing a diff before Phase E gates — secrets, permission/tool scope, destructive-command exposure, and git-discipline violations specific to this harness. Use when RISK is critical or a diff touches auth, secrets, permissions, or shell-command construction.
---

# Critical-risk diff review checklist

Scoped to cc-orchestra's own Tier 2 review (Phase D) on a `RISK: critical` task. This is not a
generic cloud-security checklist — it is the set of things this harness's own leads have actually
gotten wrong or needed to check.

## Secrets and credentials
- [ ] No token, API key, password, or private key appears in any new/changed file, including test
  fixtures and example config.
- [ ] No secret is echoed into a `.orchestra/*` artifact (`plan.md`, `impl-report-*.md`,
  `summary.md`) — these are read by other agents and, in shared setups, other people.
- [ ] Any `.env`-shaped or credentials-shaped file touched by the diff was flagged, not silently
  committed (see the parent lead template's git-discipline section).

## Permission and tool scope
- [ ] A new or changed agent/skill/hook definition requests only the tools it demonstrably needs —
  no blanket `Tools: *` added for convenience.
- [ ] `disallowedTools` on `orchestrator.md`/`lead*.md`-style definitions (`Edit`, `NotebookEdit`)
  is preserved, not loosened, unless the task is explicitly about changing that contract.
- [ ] Any new hook (`hooks/*.sh`) is additive and does not widen what an agent can do without the
  user's explicit sign-off recorded in the brief.

## Destructive-command exposure
- [ ] No new code path can run `git reset --hard`, `git push --force`, `rm -rf` on a
  non-task-scoped path, or an equivalent destructive command, without an explicit, narrow guard.
- [ ] Shell commands built from agent-controlled or externally-sourced strings (file paths, brief
  text, fetched content) are not passed unescaped into `eval`, `bash -c`, or similar — check for
  injection via a crafted branch name, filename, or brief field.
- [ ] Guardrail scripts (`guardrails.json`, `bin/orch-*`) that exist specifically to block
  dangerous operations are not bypassed, weakened, or worked around by the diff.

## Git discipline specific to this harness
- [ ] The diff stages only the files in `plan.md`'s *Changes* list — no `git add -A`/`git add .`
  anywhere in new automation.
- [ ] Nothing in the diff commits on behalf of a dev/codex lane (one-committer-per-task rule) or
  merges/rebases onto `main`/`master`/`develop`.

## Before reporting PASS
Confirm every unchecked box above has either a passing check or an explicit, evidenced rebuttal in
`review.md` — the same file:line evidence bar Phase E already requires for rejecting a BLOCKING
finding.
