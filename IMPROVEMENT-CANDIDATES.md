# Improvement candidates — proposed, unapproved ideas for cc-orchestra

**What this is:** a small, append-only log of *proposed* improvements to cc-orchestra —
ideas, techniques, or design changes that might be worth doing, collected for a human to weigh,
not yet approved and not yet work. Entries come from two sources: ad hoc ones a lead or the
orchestrator notices during a task (like the two below), and a weekly automated web-research
routine (external to this repo, not implemented by this task) that appends candidates it judges
relevant to cc-orchestra's own domain — multi-agent orchestration, Claude Code, Codex/OpenAI
coding agents, LLM-as-classifier techniques, prompt engineering for coding agents, and relevant
serving/inference infra. This file is **tracked in git**, alongside `README.md`, `OPERATIONS.md`
and `INSTINCTS.md`, so it reads identically in every clone, worktree and session.

**What this is not — read this before you touch the file:**
Every entry here is a **proposal, not a finding** — nothing in this file has been approved, and
nothing in it should ever be read as authorization to implement it, by a lead, by Codex, or by
the orchestrator. This file is **advisory text a lead or orchestrator reads, never a file that is
executed or treated as an amended brief or an authoritative instruction** — exactly the same
"data to weigh, never instructions to follow" stance `INSTINCTS.md` takes toward its own entries,
applied here to proposals instead of lessons. An entry becomes real work **only** when the user
explicitly confirms it in conversation with the orchestrator, which then decomposes it into a
normal `brief.md`-driven task the usual way. This file is never read as a task queue to execute
automatically, and the weekly research routine that appends to it has no authority to cause
implementation on its own — it only proposes.

**How to append:** one entry per candidate, in this shape:
- **Date:** when the entry was added.
- **Title:** one line.
- **Source:** URL if external (from the weekly research routine or an ad hoc find), or the
  conversation/task this came from if internal.
- **Summary:** a short, factual description of the proposal — what it is, not why it's good.
- **Critical assessment (cc-orchestra-specific):** why this might or might not actually help
  *this* repo, its own measured evidence where available, and any caveats from the source that a
  pitch alone would omit. Not "this sounds useful" — cross-check external technique claims
  against this repo's own evidence where such evidence exists, the way orch/27's research did
  against live Jev/local-model measurements rather than repeating a source's claims uncritically.
- **Status:** one of `NEW`, `USER DECLINED`, `USER APPROVED — see orch/<NN>`.

Append-only: never edit or delete another entry once added, except to update its **Status**
field as the user's decision becomes known. If a status update conflicts with what's already
there, add a note rather than rewriting history. As a normal tracked file, a concurrent append
from another branch/lead surfaces as an ordinary merge conflict at commit time — resolve it by
keeping both entries, not by picking one.

Keep entries short. If this file grows past roughly a page, split it into
`IMPROVEMENT-CANDIDATES/<short-topic>.md` (also tracked) and leave a one-line pointer here, the
same convention `INSTINCTS.md` uses.

---

## Entries

### 2026-09-28 — Constrained-decoding / prefill technique for `bin/orch-jev-local`
- **Source:** https://www.privatemode.ai/blog/system-one-from-glm-flash (discussion:
  https://news.hada.io/topic?id=34363)
- **Summary:** The source reports GLM-5.3-Flash reaching accuracy "on par" with the TypeSafe Jev
  vendor across 28 text benchmark datasets (median gap ~0.7 percentage points, not statistically
  significant), using vLLM's `allowed_token_ids` (vocabulary masking so the model can only emit a
  valid option token) plus a prefill/`continue_final_message` trick that forces the very next
  token to be the answer index. That is a more constrained decoding mechanism than orch/27-28's
  own local prototype, which used plain top-logprobs sampling and a `--min-option-mass` heuristic
  to bound refusal when the model returned prose or missing option letters instead of a clean
  letter token. orch/28's own local-model measurement (Qwen3-8B via llama.cpp, opt-in log-only
  `bin/orch-jev-local`, now present at repo root) found a 37.5% false-positive rate on the
  scan/injection set versus TypeSafe Jev's 0% on the same set. The hypothesis: the *decoding
  technique*, not necessarily the model, was a limiting factor, and a similar constrained-decoding
  approach (llama.cpp grammar or logit-bias constraints, if supported for this use case) applied
  to the existing local pipeline might close some of that gap without changing models or infra.
- **Critical assessment (cc-orchestra-specific):** The source itself flags two caveats worth
  weighing before investigating this at all: the source's own pricing has GLM-5.3-Flash costing
  roughly 4x more per decision overall than Jev (about EUR 62 vs EUR 16 per million decisions,
  list prices) — its input-token overhead alone only undercuts Jev's below about 21 options and
  exceeds it above that, but that token-count crossover does not overturn the overall per-decision
  cost gap. It is also markedly less robust to option/label renaming (swings up to
  20 points vs under 3 for Jev and alternatives) — so any pitch here is about the *decoding
  technique*, never a recommendation to adopt GLM-5.3-Flash itself. Separately, and specific to
  this repo: `bin/orch-jev-local` is currently opt-in and log-only (`JEV_LOCAL_ENABLED` off by
  default, per orch/28's summary), so nothing currently depends on closing this accuracy gap — a
  37.5%-FPR log-only second opinion is a low-stakes place to prototype a decoding-constraint
  change before it could ever gate anything. Whether llama.cpp actually exposes an equivalent to
  vLLM's `allowed_token_ids` + `continue_final_message` (grammar constraints, `logit_bias`, or a
  forced-prefill call shape) for the resident server orch-jev-local already talks to over a Unix
  socket is unverified and should be the first thing checked before any implementation work, not
  assumed from the vLLM-specific source.
- **Status:** NEW

### 2026-09-28 — `plan.md` size/structure discipline review
- **Source:** "Plan Mode is Dead",
  https://www.aymannadeem.com/artificial/intelligence,/developer/tools/2026/09/24/plan-mode-is-dead.html
  (discussion: https://news.hada.io/topic?id=34304)
- **Summary:** The article argues that detailed upfront AI-authored planning documents are
  becoming a liability as coding-agent models improve, favoring a more iterative
  understand-act-inspect cycle instead. Its own context is a single human reviewing an AI's plan
  before approving implementation — materially different from how cc-orchestra actually uses
  `plan.md`: a machine-read handoff contract between the lead, Codex implementation, the
  critical-tier design cross-check, and the final verifier, not a document a human approves before
  work starts. Both orch/27's and orch/28's `plan.md` nearly hit the `PLAN_MAX_BYTES` cap during
  multi-round critical gate work: orch/27's finished at 40,923 bytes and orch/28's at 40,667 bytes,
  against a 40,960-byte cap (`model-policy.conf:96`) — neither actually exceeded it, but orch/27
  came within 37 bytes and orch/28 within 293 bytes of it. Both tasks' `.orchestra/` directories already contain and actively
  use `evidence/` and `rounds/` subdirectories, the split `README.md`'s "작업 산출물" section
  documents ("긴 로그는 `evidence/`, 반복 라운드는 `rounds/`에 둔다.").
- **Critical assessment (cc-orchestra-specific):** The article's conclusion should **not** be
  imported wholesale — cc-orchestra's `plan.md` serves readers (Codex, a critical-tier reviewer,
  a zero-context verifier) that a single-human-review workflow doesn't have to satisfy, so
  shrinking or removing it outright is not obviously right just because upfront planning is
  reportedly less load-bearing for a solo human reviewer. The narrower, actually-investigable
  question this repo's own evidence supports: since both sampled critical tasks *did* use
  `evidence/`/`rounds/` and still nearly filled the budget, is the split being applied
  consistently enough (i.e., is content that belongs in `evidence/`/`rounds/` sometimes staying
  inline), or does `plan.md`'s own growth pattern in multi-round critical work need better
  in-line guidance about what belongs where? This is a two-data-point sample (orch/27, orch/28)
  from the same conversation's related tasks — not enough evidence on its own to justify a
  guidance change; before any implementation, more critical-task `plan.md` samples should be
  checked for the same near-cap pattern.
- **Status:** NEW

### 2026-09-29 — Re-sweep the Sonnet-tier effort defaults on Sonnet 5.5
- **Source:** https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5
  ("Calibrate effort", "Steer initiative and scope"); noticed during orch/30.
- **Summary:** `sonnet[1m]` now resolves to Claude Sonnet 5.5. The vendor guide says its effort
  levels are recalibrated versus Sonnet 5 (the same level no longer gives the same amount of
  thinking), recommends a fresh sweep against one's own evals instead of carrying settings over,
  and says that at `low` and `medium` it is more likely to stop and check in before finishing a
  long agentic task. The proposal: re-measure the four Sonnet-tier defaults in
  `model-policy.conf` — `ORCH_EFFORT="high"`, `LEAD_LIGHT_EFFORT="medium"`, `DEV_EFFORT="high"`,
  `VERIFIER_FALLBACK_EFFORT="high"` — on Sonnet 5.5, with orch/23's pre-registered-threshold A/B
  method.
- **Critical assessment (cc-orchestra-specific):** Nothing is currently observed to be wrong
  with any of the four; this is a staleness concern, not a defect. None of them has a recorded
  measurement: orch/19 compared the critical `verifier` at xhigh vs max and orch/23 the normal
  lead at medium vs high, both on Opus 5.5 (`INSTINCTS.md` entries and those tasks' plans), so
  there is no measured Sonnet 5 setting being "carried over", and the recalibration argument
  alone does not say which way any value should move. Cost is real: orch/23's 24 headless lead
  runs cost $24.30 plus a lead's time and still landed 0.001 from its threshold; four roles at a
  similar sample size is several times that, drawn from the shared Claude 5h bucket the harness
  is most constrained by, and three runs per arm per case gave only weak signals on rare catches.
  The medium check-in point bears mostly on `LEAD_LIGHT_EFFORT` (light/trivial leads run long
  agentic turns), but `templates/lead.md.tpl`'s "Finishing the task" section (orch/22) already
  targets that failure, so a sweep should score premature check-ins explicitly before calling
  medium too low. `DEV_EFFORT` matters less while `dev-*` is a narrow exception lane behind
  Codex. `ORCH_EFFORT` is the weakest target: Tier 1 mixes interactive chat with multistep tool
  use, for which the guide gives different starting points, so a sweep there is a latency/cost
  question more than a quality one. If approved, start with the light lead.
- **Status:** NEW

### 2026-09-29 — Re-examine the deep (Fable) lead profile
- **Source:** benchmark survey of Claude and OpenAI models by effort level and harness role,
  2026-09-29 (conversation; user chose to record it). Figures checked against
  https://artificialanalysis.ai/models/claude-opus-5-5 and
  https://artificialanalysis.ai/models/claude-sonnet-5-5 (Artificial Analysis, "AA"); the repo
  figures come from `model-policy.conf` and `.orchestra/*/summary.md`.
- **Summary:** `critical-xhigh` (`LEAD_DEEP_MODEL="fable[1m]"`, xhigh) is the only profile that
  spends Fable, the harness's binding weekly bucket. On AA's Intelligence Index v4.3.2 at max
  effort, Opus 5.5 scores 58 at $5.98 per task (checked on its AA page) and Sonnet 5.5 scores 56 at
  $7.60 (checked). GPT-6 Astra 53 at $3.26 and Fable 5.1 53 at $7.63 are **not** checked: Fable
  appears only in a screenshot of an AA graphic reposted on Threads, not on an AA page, and the Astra
  figure was not re-opened. Fable's per-token price is about 2.5x Opus 5.5's per `model-policy.conf`
  (its comment says Opus is 40% of Fable's price); the AA page shows Opus at $4/$20 per million
  input/output, and I did not verify Fable's list price independently. The proposal: decide whether
  the deep profile is still worth its price, using a pre-registered A/B in the orch/19 and orch/23
  style, Opus 5.5@max vs Fable@xhigh on one design-heavy task.
- **Critical assessment (cc-orchestra-specific):** A lower index does not show Fable is worse at the
  deep role. The index is 10 evaluations (AA-Briefcase, GDPval-AA, AutomationBench-AA,
  Terminal-Bench 4.0, SciCode, HLE, GDPval pdf, CritPt, AA-Omniscience, AA-LCR, per the Opus AA
  page) and none of them measures long-horizon design, which is what `critical-xhigh` leads do. The
  repo has almost no evidence either way: of the 40 `summary.md` files across the task clones I
  could find, exactly one reports `CLAUDE PROFILE: critical-xhigh fable@xhigh` (orch/27); orch/28
  ran `critical opus@xhigh`, and eight older tasks ran `critical fable@high`, which is a different
  profile and an earlier Fable version. One data point cannot support keeping or dropping the
  profile. The existing `model-policy.conf` comment already says Opus 5.5 matches or beats Fable on
  Anthropic's published benchmarks at 40% of the price, so the open question is only whether an
  unbenchmarked design-heavy task shows a gap; a single task will be a weak signal, and orch/23
  needed 24 runs and still landed 0.001 from its threshold. Cost falls on the Fable bucket, not the
  shared Claude 5h bucket.
- **Status:** NEW

### 2026-09-29 — Measure normal-risk leads on Sonnet 5.5 instead of Opus 5.5
- **Source:** benchmark survey, 2026-09-29 (conversation). Checked against
  https://artificialanalysis.ai/articles/claude-sonnet-5-5 and the two AA model pages (all at max
  effort), plus https://www.coderabbit.ai/blog/sonnet-5-5-model-review and
  https://www.coderabbit.ai/blog/opus-5-5-model-review.
- **Summary:** `LEAD_NORMAL_MODEL="opus[1m]"` at `high` carries normal-risk leads. The proposal is to
  measure Sonnet 5.5 in that role, reusing orch/23's method with Sonnet 5.5@high vs Opus 5.5@high.
  AA figures, Sonnet 5.5 vs Opus 5.5, all checked against AA: index 56 vs 58; AA-Briefcase 1811 vs
  1822 Elo; GDPval-AA 1844 vs 1846; AutomationBench-AA 71% vs 70%; Terminal-Bench 4.0 (AA-measured)
  64% vs 60%; AA-Omniscience 54% vs 66% (effort not stated for this one); HLE and SciCode about 6
  points lower for Sonnet (also effort not stated). Sonnet used about 193k output tokens per task,
  which AA calls the highest it has measured and about 60% above Opus 5.5 (max), so at max Sonnet
  costs more per task ($7.60 vs $5.98) despite a lower per-token price ($2/$10 vs $4/$20). AA says
  its Sonnet numbers came from a pre-release build with a structured-output bug that Anthropic
  expected to leave results unchanged or slightly understated, and that it would re-run; I did not
  check whether that re-run has been published.
- **Critical assessment (cc-orchestra-specific):** The possible gain is relief on the shared
  Claude 5h bucket, and no source compares the two at the same effort per task. CodeRabbit's
  independent result points against Sonnet on hard reviews but rests on 13 cases, which it says is a
  small set: Sonnet 5.5 caught 6 of 13 at 41.2% actionable precision; Opus 5.5 caught 8 (standard,
  66.7% precision) and 10 (max, 52.0%). CodeRabbit also notes that higher effort did not consistently
  find more bugs and that Opus standard and max caught different ones. Sonnet's effort in that test
  is not stated in the summary I read. In this repo, `LEAD_NORMAL_EFFORT` stays governed by
  orch/23's pre-registered result (kept at high; medium missed the cost threshold by 0.001), and
  orch/23 found real leads spend much of their budget on re-reading and waiting (one historical
  lead spent 222 of 260 requests waiting), where effort does not cut cost. It also found no lead at
  either effort caught three defects that Codex review caught historically, so a weaker lead model
  leans further on the Codex gates. The orch/30 candidate above (re-sweeping Sonnet-tier effort
  defaults) overlaps: both need Sonnet 5.5's recalibrated effort levels measured, so a sweep
  should be planned once, not twice.
- **Status:** NEW

### 2026-09-29 — Move the Codex mechanical/fast lanes to GPT-6 Luna, after verification
- **Source:** benchmark survey, 2026-09-29 (conversation). Checked against
  https://developers.openai.com/api/docs/pricing and
  https://artificialanalysis.ai/articles/gpt-6-sol-and-luna-push-the-cost-efficiency-frontier.
- **Summary:** `CODEX_MECH_MODEL` and `CODEX_FAST_MODEL` in `model-policy.conf` are both
  `gpt-5.6-luna`. OpenAI's pricing page (checked) lists GPT-6 Luna at $0.10 input, $0.01 cached
  input, $0.50 output per million tokens, against $0.20 / $0.02 / $1.20 for GPT-5.6 Luna. The AA
  article (checked; the direction is resolved) compares GPT-6 Luna (max) with GPT-5.6 Luna (max):
  cost per task $0.07 vs $0.18; Coding Agent Index 41, down 2 points (so 43 for GPT-5.6 Luna, which
  is implied rather than quoted); GDPval-AA v2.1 down about 75 Elo for Luna. In the same article
  Sol drops about 100 Elo on GDPval-AA, and the article says Intelligence Index and Coding Agent
  Index scores overall remain level with GPT-5.6. The overall AA index of 37 for GPT-6 Luna max was
  not re-checked. So the cheaper model is slightly worse on AA's coding index; the saving is real
  but not free.
- **Critical assessment (cc-orchestra-specific):** Luna is used for bulk mechanical edits
  (`--mech`) and small review lanes (`--fast`), where the saving is on the Codex pool, which is not
  the constrained bucket, so the benefit is modest. The bigger risk is `INSTINCTS.md`'s "A routed
  model slug needs matching wrapper capability coverage" lesson (orch/24): every place naming
  `gpt-5.6-luna` must be checked before a slug change. Found by grep, excluding `.orchestra/`:
  `model-policy.conf:80` and `:87`; `bin/codex-run:97` (help text) and `:108` (slug map for `luna`);
  `bin/codex-run:238-239` (comment and `ultra` gate: "luna tops out at max", ultra allowed only for
  sol/terra/astra); `bin/codex-run:565-566` (resume metadata records `lane=thread|model|effort` and a
  resume continues the recorded thread model, so existing Luna threads keep the old slug);
  `bin/codex-run-runtime:26-31` (`fast_compatible_model` allowlist, which has no Luna entry of
  either generation, so `--fast-mode` on Luna is refused today); `bin/orch-jev:34` (default
  `JEV_SHADOW_MAP_MECHANICAL`) and `:540` (`MODEL_RANK`, which has no `gpt-6-luna` key);
  `jev-policy.conf:37`; `OPERATIONS.md:475` and `OPERATIONS.ko.md:505`; `templates/lead.md.tpl:120`;
  `skills/orch-lane-dispatch/SKILL.md:37`; `tests/test-jev-shadow.py:204,274,294,303`;
  `tests/test-policy.sh:148,193,196` (model catalog fixtures with luna's `max` effort). Whether a
  `gpt-6-luna` slug exists in this account's Codex model catalog was not checked; `codex-run` has an
  Astra-specific catalog gate, and I did not read whether an equivalent would be needed. First step
  of any follow-up: confirm the scores on the AA pages, then check the catalog, then the list above.
- **Status:** NEW

### 2026-09-29 — Test whether normal-risk Codex-written diffs need a cross-family check
- **Source:** benchmark survey, 2026-09-29 (conversation). Outside evidence:
  https://www.greptile.com/blog/model-inversion,
  https://www.sonarsource.com/blog/openai-gpt-6-astra-an-evaluation/, and arXiv 2603.25773
  (not opened; its claim is second-hand and unverified).
- **Summary:** As documented, low/normal risk gates are `codex-run verify` PASS plus `codex-run
  review` CLEAR/NONBLOCKING (`README.md` "Gate 정책" table; `agents/orchestrator.md` risk-tier text;
  `README.md` Tier 4 line). Codex writes the diff by default, so Codex both writes and gates it; the
  lead's own Phase D diff review is the only Claude-family check, and the Claude Opus@max verifier
  is added only at critical. The proposal: test whether a Claude-family check on normal-risk Codex
  diffs would catch defects the Codex gates miss. Outside evidence, all weak: Greptile's
  vendor-run study (1,000 pull requests, Opus 4.7 vs GPT 5.5) found GPT caught 62.0% of
  high-severity bugs in Claude-authored code and Claude 60.0% in GPT-authored code, and said each
  model did better on the other's code, calling the effect experimental; the 53.7% and 50.5%
  same-model comparison figures were not visible in what I read and are unverified. arXiv 2603.25773
  reportedly says diverse panels reduce but do not remove correlated misses. Sonar's independent
  Java study (4,444 tasks) has GPT-6 Astra passing 85.85% vs 81.99% for GPT-5.6 Sol at medium effort,
  while critical-bug density rose from 33 to 70 per million lines (+89%); that is about Astra's own
  code quality, not cross-family review.
- **Critical assessment (cc-orchestra-specific):** None of this shows a gap in the normal-risk
  gate. The public evidence covers older model generations, is partly vendor-run, and neither
  Greptile nor Sonar tests this harness's gate shape. This repo's own history cuts both ways:
  orch/23 found that leads at either effort missed three defects that Codex review had caught
  historically, so the Codex gate adds real value; orch/19 found a gate-skip bug (in
  `bin/orch-summary-check` `strip_fences`) that the historical max Opus verifier, Codex verify and
  Codex review had all missed, which shows the gates share blind spots but not that a cross-family
  check would have closed them, since the Opus verifier is Claude-family and missed it too. Adding
  a Claude verifier to normal risk would spend the shared 5h bucket the harness is most constrained
  by. The narrow follow-up: tabulate, from the repo's own historical task artifacts, which gate
  caught which defect and which gate missed it, before changing any gate.
- **Status:** NEW

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
