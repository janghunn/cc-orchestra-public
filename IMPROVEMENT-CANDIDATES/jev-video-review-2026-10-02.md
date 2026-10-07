# Jev-video review candidates (2026-10-02)

This file follows the entry shape and append-only rules of ../IMPROVEMENT-CANDIDATES.md.

### 2026-10-02 — `fast-jev-compaction`: model-scored deletion of tool results at compaction
- **Source:** https://www.youtube.com/watch?v=nU0dsSJkPZw (2026-09-29, "Jev use cases" video; repo `tamaratran/fast-jev-compaction`); evaluated in orch/44 and orch/46.
- **Summary:** The repo proposes scoring old tool results with a fast model and deleting the low-scoring ones before or during compaction, so the remaining context stays within budget.
- **Critical assessment (cc-orchestra-specific):** The repo's README publishes no latency, cost or quality measurement for the compaction tool. The part that matters here is that Tier 1 loses orchestration state (agentIds, board, directives) at compaction, so orch/44 added a deterministic `SessionStart(compact)` recovery hook that re-injects the registry, board and directives without any model call; it is merged. orch/46 then replayed tool-result retention policies against the local transcript corpus (442 files found, 377 evaluated, 1136 cuts; `eval/compaction-replay/evidence/real-run.md` in that task) and returned `do not pursue` for scored deletion: a recency-only policy lost 26 needed agentIds, and the heuristic policy missed the pre-registered byte and recall thresholds (path recall 0.908, sha recall 0.935, bytes removed 0.296). The local-model arm (P3) was skipped because the host had no GGUF file, no llama-server and no usable GPU, so a model-scored policy itself was never run; the verdict rests on the two deterministic policies. Caveat: the replay measures whether needed identifiers survive, not downstream task quality.
- **Status:** USER APPROVED — see orch/44

### 2026-10-02 — `jev-codex-router`: per-call Jev routing of Codex requests
- **Source:** https://www.youtube.com/watch?v=nU0dsSJkPZw (repo `0xNatoshi/jev-codex-router`); evaluated in orch/45 and orch/03 (Jev shadow).
- **Summary:** The repo routes each Codex request to a model tier chosen by a Jev difficulty classification, to cut token cost.
- **Critical assessment (cc-orchestra-specific):** The router's "-60%" figure is an offline simulation of 237 turns with no quality measurement, by the repo's own disclaimer. Live per-call routing was not adopted here, for three reasons: cc-orchestra already routes at lane level (astra/sol/luna by unit type, `model-policy.conf`); a Codex lane keeps one resumable thread, and switching model per call would drop the thread's prompt-cache (KV) prefix and mix models inside one thread; and there is no quality measurement showing a cheaper tier is adequate for a given call. The observability half was approved: orch/45 added `orch-usage-report --cost`, a counterfactual Codex cost view (ACCEPTED with a documented limit: token-to-call matching is an estimate because `codex.log` carries no run identifier). Pricing inputs live in `pricing-policy.conf`, not here. Shadow-mode state, counts only: 73 ok records, with difficulty involved 58, routine 6, mechanical 5, novel 4. The pre-registered Stage 1 review (`eval/jev-shadow-decision.md`) needs 14 days and 30 exact-observed records and is not due before 2026-10-06; no verdict is drawn here.
- **Status:** USER APPROVED — see orch/45

### 2026-10-02 — `jev-review`: Jev review as a diff gate
- **Source:** https://www.youtube.com/watch?v=nU0dsSJkPZw (repo `devagrawal09/jev-review`); evaluated in orch/47.
- **Summary:** The repo uses Jev to triage or rank what a reviewer should look at in a code diff.
- **Critical assessment (cc-orchestra-specific):** The README publishes no latency, cost or quality measurement. orch/47 ran an offline comparison of diff risk-triage scorers on the harness's own gate corpus (`eval/diff-triage/`): only 12 usable diffs, verdict `inconclusive` (S2 minus S1 recall@k20 -0.017 with interval [-0.172, 0.206]; S2 minus S0 0.231 with interval [0.068, 0.402]); the local-model scorer (S3) was skipped for lack of a model, llama-server and GPU. The sample is too small to separate the scorers, and labels partly come from bundled fixes, so the result neither supports nor rules out the idea. Using Jev review as a gate was not adopted. The task was ACCEPTED with a known limit: on git 2.42 or later a bare clone can read `.gitattributes` from HEAD, so later attributes could leak into historical diffs (not reproducible on the host's git 2.34.1; this repo has never had a `.gitattributes`).
- **Status:** USER APPROVED — see orch/47

### 2026-10-02 — Claude Code "mods" as a future enforcement layer for pin/route policy
- **Source:** https://code.claude.com/docs/en/plugins/mods/reference.md (Claude Code 2.1.287 documentation).
- **Summary:** The docs describe mods, function hooks loaded as a plugin and hot-reloaded in a session: `turn.step` can change model or effort per request, `agent.spawn` can set a model or deny a spawn, `session.compact` can skip compaction, and `session.measure` reports usage.
- **Critical assessment (cc-orchestra-specific):** Today model/effort pinning and spawn limits are enforced by generated agent profiles and prompt text, which a running agent can in principle disregard; a mod acting on `agent.spawn` or `turn.step` would enforce the same policy in the runtime instead. Caveats: the surface is documented as experimental and its types can differ per build, so anything built on it needs a version check; it applies to Claude Code only, not Codex lanes; this repo has not tried it, so none of the above is measured here.
- **Status:** NEW

### 2026-10-02 — Exact token-to-call matching via a run identifier in `codex.log`
- **Source:** orch/45 (`orch-usage-report --cost`) deferred finding and its documented estimate limit.
- **Summary:** Record a run identifier (or the events-file path) in each `codex.log` line written by the Codex wrapper, so usage events can be joined to calls exactly rather than by time proximity.
- **Critical assessment (cc-orchestra-specific):** orch/45's cost view attributes tokens to calls by matching, and a race between the wrapper writing its artifact and its log line makes the match an estimate; the user accepted that as a documented limit. An identifier would remove the race. Caveat: `bin/orch-jev` parses the `codex.log` line with a full-line regex, so adding a field changes the line shape and needs a parser compatibility check (and a test) before any change. The benefit is accuracy of an observability report only; no routing decision currently depends on it.
- **Status:** NEW
- **Status note (2026-10-07):** implemented on orch/68-codex-log-run-id (awaiting merge) as a `<state>/codex-runs.jsonl` sidecar; `codex.log` is unchanged.
