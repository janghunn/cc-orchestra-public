# cc-orchestra runtime operations and budget routing

This layer keeps the existing orchestration engine intact and adds two capabilities around it:

1. persistent task sessions backed by `tmux` and optional git worktrees;
2. reset-time-aware routing across a Claude Max subscription and a ChatGPT Pro Codex subscription.

The original repository executables stay at their current paths and are not rewritten. The public
commands installed in `~/.local/bin` point at runtime facades:

```text
cc-orch          -> bin/cc-orch-runtime          -> existing bin/cc-orch
codex-run         -> bin/codex-run-runtime       -> existing bin/codex-run
orch-model-guard -> bin/orch-model-guard-runtime -> existing bin/orch-model-guard
```

This split keeps the original harness easy to review and lets `CC_ORCH_AUTO_ROUTE=0` bypass
Codex automatic routing for an explicit invocation.

## Install or upgrade

```bash
git pull
./install.sh
./install.sh --check

tests/test-policy.sh
tests/test-runtime.sh
```

For work on cc-orchestra itself, read [AGENTS.md](AGENTS.md). New-server setup is covered in
[BOOTSTRAP.ko.md](BOOTSTRAP.ko.md).

The main installed paths are:

```text
~/.claude/orchestra                         -> repo
~/.claude/agents/orchestrator.md
~/.claude/agents/verifier.md
~/.claude/agents/verifier-normal.md
~/.claude/agents/route-lead-*.md

~/.local/bin/cc-orch                       -> bin/cc-orch-runtime
~/.local/bin/codex-run                     -> bin/codex-run-runtime
~/.local/bin/orch-model-guard              -> bin/orch-model-guard-runtime
~/.local/bin/orch-summary-check
~/.local/bin/orch-usage-report
~/.local/bin/orch-archive
```

The installer also configures the legacy Fable guard timer, Claude 5h/7d status-line quota tap,
live routing `UserPromptSubmit` hook, and structural stale-policy notice hook. The optional
poll guard is documented under [PreToolUse poll guard](#pretooluse-poll-guard-opt-in);
verifier guards are activated through agent frontmatter, as described under
[Verifier Bash command guard](#verifier-bash-command-guard).

Installation runs the existing model guard and adds a Claude status-line tap. The tap receives
structured `rate_limits.five_hour` and `rate_limits.seven_day` values, saves percentages and reset
epochs, and then invokes the previous status-line command. Uninstalling the guard restores the
previous status-line configuration.

After the first installation of this branch, reload an existing cc-orch session once so Claude
caches the 16 new `route-lead-*` agent types. Ordinary quota/reset movement after that does not
require another reload.

`build-roster-runtime.sh` records all 38 rendered profiles in the NDJSON manifest
`${CC_ORCH_AGENTS_DIR:-$HOME/.claude/agents}/.install-manifest.json` (override with
`CC_ORCH_MANIFEST`), including destination, source template, both SHA-256 hashes, and repo commit.
Run `~/.claude/orchestra/bin/orch-doctor [manifest-path]` to check for missing files, changed
output, stale templates, or a repo-version mismatch; it exits 0 when all entries match, 1 for
problems, and 2 when the manifest is absent or invalid. Its optional upstream note uses only
the local tracking ref, without fetching, so it cannot detect remote changes that have never
been fetched. Running `build-roster.sh` alone tracks only its 22 profiles; existing route files
remain on disk but leave the manifest until the runtime builder runs again. A quota-driven
`orch-model-guard set` switch intentionally changes rendered files without updating the manifest,
so affected `lead-*.md` files show expected `DRIFTED` results until the next roster rebuild.

## Persistent sessions and worktrees

Create a task in its own branch, worktree, and detached tmux session:

```bash
cc-orch session new auth-refactor ~/projects/api
```

Useful variants:

```bash
cc-orch session new payment-fix ~/projects/api --profile critical
cc-orch session new docs ~/projects/site --inplace
cc-orch session new cache ~/projects/api --branch orch/cache-v2 --base develop
cc-orch session new batch ~/projects/worker --no-attach
```

Manage sessions from any SSH login on the same server:

```bash
cc-orch session list
cc-orch session status auth-refactor
cc-orch session attach auth-refactor
cc-orch session shell auth-refactor
cc-orch session stop auth-refactor
cc-orch session restart auth-refactor
cc-orch session remove auth-refactor
```

`restart` continues the last Claude conversation with `-c`. `remove` deletes a stopped clean
worktree and its local registry entry, but deliberately keeps the task branch. A running or dirty
worktree requires an explicit `--force`.

State lives under:

```text
~/.claude/orchestra-state/sessions/
~/.claude/orchestra-state/worktrees/
```

Override the worktree root with `CC_ORCH_WORKTREE_ROOT`.

For Git repositories, the default branch is `orch/<session-name>`, based on the current branch
or `HEAD`, and the worktree is under `~/.claude/orchestra-state/worktrees/<project>/<session-name>`.
Use `--branch` / `--base` to override these, or `--reuse-branch` to use an existing branch:

```bash
cc-orch session new cache ~/projects/api --branch orch/cache-v2 --reuse-branch
cc-orch session new main ~/projects/api --project-name api --inplace
cc-orch session path main
```

`--inplace` keeps the existing checkout, useful for research, large datasets, conda/GPU environments,
and existing build artifacts. Separate sessions for parallel features isolate branches, indexes,
worktrees, and tmux processes. A session named `main` uses tmux `ccorch-main`; its launcher name
includes project and session, such as `api-main`.
Detach without stopping Claude with `Ctrl-b, d`; use `/exit` inside Claude to end it normally.
SSH disconnection leaves the tmux session running. `stop` keeps the registry, branch, and worktree.

### Direct launch and Remote Control

```bash
cc-orch api ~/projects/api
cc-orch --no-rc api ~/projects/api
cc-orch --profile critical api ~/projects/api
cc-orch --profile deep api ~/projects/api
cc-orch --model opus[1m] --effort high api ~/projects/api
cc-orch session new main ~/projects/api --project-name api --inplace --no-rc
```

Remote Control is enabled by default as `--remote-control orch-<project-name>`; managed sessions
include the session name, for example `orch-api-main`. It lets a terminal, phone, or another machine
control the same conversation. Usually keep Tier 1 normal and raise individual task risks instead
of making the entire orchestrator critical/deep.

Session creation/restart checks Claude Code and Codex against npm `latest` and completes any
update and version check before launch. Codex-only checks only Codex; backend switches check the
target CLI before stopping the old session. The current npm global prefix installation is supported.
Lookup or installation failure prevents launch; already-running processes are not restarted.
`CC_ORCH_CLI_AUTO_UPDATE=0` explicitly skips this for offline reproduction or fake-provider tests.

## Runtime budget model

The guard normalizes usage by time left until reset:

```text
headroom ratio = remaining quota fraction / remaining time fraction
```

A ratio of `1.0` means usage is exactly on pace. A ratio below `1.0` means future usage must slow
down to reach reset. High usage immediately before reset is therefore not treated the same as
high usage several days before reset.

Inspect the live result:

```bash
orch-model-guard budget
orch-model-guard lanes
```

Example:

```text
claude  healthy
  5h    used=90% headroom=6.000 reset=... in 5m
  7d    used=80% headroom=1.400 reset=... in 1d
codex   tight
  7d    used=90% headroom=0.117 reset=... in 6d

dispatch=codex-first
```

Codex headroom `(1-0.90)/(6/7)=0.117` is ≥ `BUDGET_CRITICAL_RATIO=0.10` and <
`BUDGET_TIGHT_RATIO=0.30`, so it is tight; tight is below `BUDGET_CODEX_SPARING_MIN_RANK=3`
(critical), so dispatch stays codex-first.

Claude data comes from the status-line tap. Codex data comes from the newest
`rate_limits.primary` object in `~/.codex/sessions/**/rollout-*.jsonl`; no extra model call is
made.

The status-line fields are `rate_limits.five_hour.used_percentage` / `.resets_at` and
`rate_limits.seven_day.used_percentage` / `.resets_at`; Codex uses
`rate_limits.primary.used_percent` / `.resets_at`. Claude evaluates both 5h and 7d windows,
takes the worse pressure, and breaks equal-rank ties by lower headroom. Fable's separate weekly
usage also protects the deep-reasoning reserve.

Current thresholds in `budget-policy.conf` deliberately favor using the subscriptions:

| Pressure | Headroom ratio | Usage fallback when reset is unknown |
|---|---|---|
| healthy | >= 0.55 | < 88% |
| watch | >= 0.30 and < 0.55 | >= 88% and < 96% |
| tight | >= 0.10 and < 0.30 | >= 96% and < 99% |
| critical | < 0.10 | >= 99% |

A window with at most 10 minutes to reset is healthy unless already 100% used. With half the
window remaining, the usage boundaries are 72.5%, 85%, and 95%; with 10% remaining they are
94.5%, 97%, and 99%. Equality stays in the lower-pressure tier. Thus the same usage can permit
more work near reset. Half the quota and half the time remaining gives headroom `1.0`;
a ratio above `1.0` means more room to spend.

## Dynamic routing

### Claude lead profiles

| Risk | healthy | watch | tight | critical |
|---|---|---|---|---|
| low / trivial | light: Sonnet medium | light: Sonnet medium | light: Sonnet medium | light: Sonnet medium |
| normal | normal: Opus high | normal: Opus high | light: Sonnet medium | light: Sonnet medium |
| critical | critical: Opus xhigh | critical: Opus xhigh | normal: Opus high | normal: Opus high |
| critical + deep | critical-xhigh: Fable xhigh | critical: Opus xhigh | normal: Opus high | normal: Opus high |

`deep` is reserved for an explicit user request or genuinely competing designs, such as security
or core algorithms. Plain critical keeps Opus 5.5 xhigh through watch and lowers effort to high at
tight. When Fable weekly usage reaches 85% (`BUDGET_FABLE_RESERVE_PCT=85`), only profiles
resolving to Fable (currently `critical-xhigh`) fall back to Opus `normal`. Plain critical is
unaffected by Fable usage;
its effort follows `CLAUDE_ROUTE_CRITICAL_*`. The same model-based rule applies to global
Fable exhaustion.

Lead selection is resolved at each new task boundary:

```bash
orch-model-guard route lead low alpha
orch-model-guard route lead normal bravo
orch-model-guard route lead critical charlie
orch-model-guard route lead critical deep delta
```

`RISK: trivial` has no route of its own; route it as `low`
(`orch-model-guard route lead low <slot>`). It differs from `low` only in gate policy: there is no
Codex verify/review or Claude verifier, and the lead reports
`GATES: self-check only (trivial) — <what was checked>`. `orch-summary-check --strict` enforces
that line. See "Choosing RISK" in `agents/orchestrator.md` for the applicability rules.

For trivial declarations, `brief.md` must have exactly one unfenced column-zero `RISK:` line,
written `RISK: trivial` without indentation or a bullet. A reason may follow only a dash.
`plan.md` allows at most one `RISK AMENDED` line. Another tier conflicts only on a separate
unfenced column-zero declaration beginning with a field marker, optionally preceded by one dash;
ordinary prose and fenced examples do not conflict. The self-check `GATES:` explanation must
contain at least one ASCII letter or digit identifying a command, file, or count.
See [README gate policy](README.md#gate-정책) for applicability and the low-to-trivial amendment.

`STATUS: ACCEPTED` means the user reviewed the actual gate results and accepted them; it is
never a PASS. Only the user can authorise it; Tier 1 records
`USER ACCEPTED: <YYYY-MM-DD> — <what was accepted and why>` at column 0 in `brief.md`, outside
fenced blocks. `GATES:` must still explicitly state the actual results. With that record,
gate-claim failures and an unapproved round-cap overrun become `ACCEPTED EXCEPTION:` lines;
structural errors, contradicted PASS claims, and a missing `USER ACCEPTED:` record stay errors
under `--strict`. The security scan stays advisory. A successful strict check ends with
`CHECK: PASS (accepted with exceptions: n, risk=...)`, distinguishable from a clean PASS.

For non-trivial tasks, `orch-summary-check --strict` cross-checks positive `GATES:` claims
against artifacts in the task directory:

- `codex-verify PASS`: `codex-verdict.md`, first non-blank line `CODEX-VERDICT: PASS`.
- `codex-review CLEAR|NONBLOCKING`: `codex-review.md`, first non-blank line
  `CODEX-REVIEW: CLEAR` or `CODEX-REVIEW: BLOCKING 0 / NONBLOCKING <m>`.
- `codex-auditor PASS` (Codex backend): `codex-audit.md`, first non-blank line `CODEX-AUDIT: PASS`.
- `claude-verifier PASS`: the newest file by mtime among `verdict.md`, `verdict-*.md`,
  `verifier-verdict.md`, `verifier-verdict-*.md`, `verifier-normal-verdict.md`, and
  `verifier-normal-verdict-*.md`. It must contain `VERDICT: PASS` or
  `VERIFIER-VERDICT: PASS` (optionally a Markdown heading), or a `## Verdict` heading whose
  next non-blank line starts with `PASS` (Markdown emphasis and `PASS.` are accepted).

`verifier-normal` uses the dispatched path `<task-dir>/verdict.md` or `verdict-<n>.md` for a
later run, with exactly `VERDICT: PASS`, `VERDICT: FAIL`, or `VERDICT: INCONCLUSIVE` as its
first line, followed by evidence. A nonstandard basename is replaced with `verdict.md` in
the same directory, or the smallest unused `verdict-<n>.md` with n >= 2 if that file exists;
the verifier reports the actual path and the substitution in `CONCERNS`.

Only top-level files count; archived files under `evidence/` or `rounds/` are ignored.
All matching verifier files are considered; the newest mtime wins, and equal mtimes choose
the last basename in version order. More than 1000 matching files produces an error under
`--strict` (a warning otherwise) without parsing a verdict; archive old runs under `evidence/`.
The last recognised verdict header wins, or the last recognised verdict section if there is
no header. Header names are case-insensitive for the Claude verifier;
artifact verdict tokens are case-sensitive. Template alternatives such as
`VERDICT: PASS | FAIL | INCONCLUSIVE` are not verdicts. After an artifact verdict token (or
review counts), only whitespace or an annotation beginning with `—`, `–`, `-`, `(`, `:`, `;`,
`,`, or `.` is accepted; bare trailing prose such as `PASS but only as an example` is rejected.
ASCII `-` requires at least one preceding whitespace character: `PASS - 12/12` is accepted,
while `PASS-FAIL`, `PASS-ish`, and `CLEAR-BLOCKING 1` are rejected. The other delimiters may
follow the token directly or after whitespace.
Files over 1 MiB are not parsed.
Fenced blocks are ignored in the summary and Claude verifier; Codex artifacts require the
header itself as their first non-blank line. A line-start inline backtick span does not open a
fence: a run of 3+ backticks with another backtick later on that line cannot hide later declarations.
The last `GATES:` line outside fences is used,
with complete status tokens rather than prefixes. Claims must begin a segment separated by
`·`, `;`, or `,`; prefixed text such as `no codex-verify PASS` is not a claim.
Missing or contradicting artifacts produce
errors with `--strict` and warnings otherwise. Trivial self-checks and low-risk review waivers
retain their policy. To clear a failure, correct the summary or supply the matching artifact;
the stop gate's documented `stop-gate.off` switch remains available.

The command returns an immutable agent type such as `route-lead-bravo-normal`, plus its model and
effort. `build-roster-runtime.sh` generates all 16 slot/profile combinations, and the legacy quota
guard never rewrites the `route-lead-*` namespace. Usage changes therefore choose among already
cached agent types rather than rewriting definitions.

`orch-summary-check` also prints a separate advisory security scan of added lines in committed
changes from the current branch's merge base with local `main` (or `origin/main`) to `HEAD`.
Run it from the task worktree, even when the executable is installed in another checkout or
the task artifacts are stored in the orchestrator's checkout. Outside a Git checkout, it falls
back to the repository containing the task directory; it never scans the installation by default.
It checks `.md`, `.json`, `.conf`, `.sh`, `.py`, and files directly inside any `bin/` directory for secret-shaped literals, instructions to
bypass confirmation, and broad Bash permission strings. Findings are warn-only and never change
PASS/FAIL or gate error/warning counts, including with `--strict`; unavailable Git bases are
reported as skipped, not clean. Secret-bearing lines are redacted from diagnostics. To scan
full on-disk files, run `bin/orch-security-scan --files <file>...` (exit 0 for
no findings, 1 for findings).
Scanning `bin/orch-security-scan` itself produces two expected instruction-phrase findings
on its pattern definition and diagnostic label lines. These remain advisory and have no
exemption in the scanner.

### Tier-1 orchestrator

Normal runtime-managed Tier 1 stays `sonnet[1m] @ high` for intent, decomposition, briefs,
lead assignment, registry/status tracking, and reporting; costly design and review go to lower tiers.
A legacy `active=opus[1m]` fallback does not change this normal runtime profile.
`orch-model-guard active` reports legacy compatibility state, which can differ from the live model.
Check the actual process:

```bash
ps -eo pid,args | grep '[c]laude.*--agent orchestrator'
```

A normal session shows `--model sonnet[1m] --effort high`.

### Codex model and effort

Codex model and effort are resolved automatically on each new `codex-run` invocation:

| Mode | healthy | watch | tight | critical |
|---|---|---|---|---|
| `intake` | Astra high (fallback Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` low |
| `investigate` | Astra high (fallback Sol high) | `gpt-6.1-sol` high | `gpt-6.1-sol` medium | **withheld** |
| `implement` | Astra xhigh (fallback Sol xhigh) | `gpt-6.1-sol` high | `gpt-6.1-sol` high | **withheld** |
| `review` | Astra high (fallback Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium |
| `plan-review` | Astra high (fallback Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium |
| `verify` | Astra high (fallback Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` low |

The complete table is in `budget-policy.conf`. Auto-routed healthy calls emit
`CODEX-RUN: MODEL_FALLBACK` and use the lane's plain default (`gpt-6.1-sol`) when Astra is unavailable;
explicit Astra requests instead exit 6 with `CODEX-RUN: MODEL_UNAVAILABLE`. Set
`CC_ORCH_CODEX_CATALOG_CHECK=0` to disable the live/cached catalog pre-flight. Explicit flags always win:

```bash
codex-run ... --model sol --effort xhigh
codex-run ... --model astra
codex-run ... --critical
codex-run ... --fast-mode
codex-run ... --mech
```

WATCH/TIGHT/CRITICAL routes use `gpt-6.1-sol`; the plain defaults, the healthy
Astra-unavailable fallback, and `--model sol` also mean `gpt-6.1-sol`. `--model luna`, `--mech`, and
`--fast` mean `gpt-6-luna`. `--model terra` still means `gpt-5.6-terra` for explicit requests;
there is no GPT-6 Terra. Legacy `gpt-6-sol` (GPT-6 Sol) remains accepted by full slug, and
resumed threads keep it. Full slugs (e.g. `--model gpt-5.6-sol`)
pass through, and resume keeps a thread's recorded model. Healthy Astra (`gpt-6-astra`) availability
is checked using the account/CLI live catalog and `~/.codex/models_cache.json`.
A cache whose `client_version` is older than the `codex` on PATH never reports Astra absent;
it is treated as unknown (proceed; a real rejection is still classified at run time).
At critical pressure, automatic investigate/implement are withheld to reserve quota for
cross-family review and executable verification; Claude/Explore investigation and Claude dev
implementation remain fallback options. Intake, review, plan-review, and verify stay available.
The separate Luna lanes are documented in `templates/lead.md.tpl`.

### Fast mode

`CODEX_ALWAYS_FAST_MODE=1` enables Fast mode for supported automatically selected Astra/Sol/Terra
calls. `--fast-mode` keeps the selected model and effort and requests the official Fast service
tier for that invocation. `gpt-6.1-sol` (plain default / `sol`), `gpt-6-sol`, `gpt-5.6-sol`, `gpt-6-astra`, and
`gpt-5.6-terra` pass the wrappers' Fast-mode and explicit `--effort ultra` allowlists.
Luna (`gpt-6-luna`, `gpt-5.6-luna`) is rejected by both: it tops out at `max`, and Fast mode is not a Luna knob.
`ultra` is never selected implicitly; it requires an explicit user request and `--effort ultra`.
`--mech` and legacy `--fast` are explicit Luna lanes, distinct from Fast mode.
`resume` preserves the existing thread's context/model rather than forcing a new automatic route.

Disable automatic Codex routing for one command or shell:

```bash
CC_ORCH_AUTO_ROUTE=0 codex-run ...
export CC_ORCH_AUTO_ROUTE=0
```

### Codex command reference

All automatic Codex calls go through the `codex-run` facade:

```bash
codex-run intake      <workdir> <task-dir> "<goal>"
codex-run investigate <workdir> <task-dir> "<question>"
codex-run implement   <workdir> <task-dir>
codex-run implement   <workdir> <task-dir> --lane b
codex-run implement   <workdir> <task-dir> --mech
codex-run resume      <workdir> <task-dir> "<follow-up>" [--lane b]
codex-run plan-review <workdir> <task-dir> [--critical]
codex-run verify      <workdir> <task-dir> [--critical]
codex-run review      <workdir> <task-dir> --base <branch> [--critical]
codex-run status      <task-dir>
```

Use `--model astra` / `--model <slug>`, `--effort`, or `--critical` for explicit overrides;
`--dry-run` prints the assembled command without running a model.

### Provider dispatch

`orch-model-guard lanes` defaults to `codex-first` through healthy/watch/tight: Claude already
pays the control cost, so heavy execution uses the separate Codex pool. Pressure first reduces
Codex model/effort, before switching provider. `codex-sparing` starts only at the critical reserve
boundary (`BUDGET_CODEX_SPARING_MIN_RANK=3`) when Codex is more constrained than Claude.
If both are critical, `BUDGET_PROVIDER_SWITCH_MARGIN` compares their headroom. Claude critical
with Codex below critical stays `codex-first`. Sparing preserves Codex review/verify quota.

### Codex pressure pin

`budget-policy.conf` ships with `CODEX_PRESSURE_PIN="healthy"` and `CODEX_PRESSURE_PIN_UNTIL=""` (no expiry).
This selects the healthy Codex rows (Astra, Fast on) and keeps dispatch `codex-first` regardless of Codex pressure; Claude routing is unchanged.
The hook/compact status shows `codex=healthy(pinned; real=watch, …)`; `budget`, `lanes` and the `route codex` reason also mark the pin and real state, which remains recorded in `budget-state`.
Only `healthy` is accepted: invalid values warn on stderr and leave routing dynamic.
`CODEX_PRESSURE_PIN_UNTIL` accepts epoch seconds or an absolute local `YYYY-MM-DD[ HH:MM[:SS]]` date/time; at or after expiry the pin is ignored. Invalid or relative dates warn and leave routing dynamic.
Explicit `--model`, `--effort`, `--critical` and `--fast` flags still win.
The review/verify reserve is gone while pinned; exhausted quota fails at the provider with existing exit-code handling. Missing Astra falls back per `model-policy.conf`.
No `cc-orch --reload` is needed: the policy is read per invocation and excluded from the policy revision. Set `CODEX_PRESSURE_PIN=""` to restore dynamic routing.

## Jev advisory sidecar (optional, hybrid mode only)

`orch-jev` adds a third-model advisory signal from TypeSafe AI's Jev. Invoke it explicitly;
it is never a gate and never edits task files. Humans and agents decide how to use its advice.
The installed checkout exposes it at `~/.claude/orchestra/bin/orch-jev`; from a checkout,
use `bin/orch-jev`. Python 3's standard library is sufficient.

```bash
export TYPESAFE_API_KEY=<your-key>
# Alternatively, put the key in <state>/jev.key, then chmod 600 <state>/jev.key.
~/.claude/orchestra/bin/orch-jev lint-brief <brief.md>
~/.claude/orchestra/bin/orch-jev risk <brief.md>
~/.claude/orchestra/bin/orch-jev scan <file>...
~/.claude/orchestra/bin/orch-jev scan - <file>  # stdin and files may be combined
```

`<state>` is `${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}`. The environment key takes
precedence; an empty value falls back to `jev.key`. A key file with group/other permissions is
ignored with a warning; use `chmod 600`. Unreadable key files also fail open. The client never
copies the key into output, logs, or generated files.

`lint-brief` sends numbered Acceptance items and the Verification section, asking one question
per item. `risk` sends the brief with its Risk section, tier declarations, and DEEP REASONING
lines removed. `scan` sends text chunks with source names and line ranges in one shared request.
Only named input files or stdin are read, alongside the policy, question template, and key file.
Every source is checked for secret-shaped literals before truncation: a matching source is
skipped in full. Size and item/chunk limits bound what leaves the machine, with explicit notes.

Known limits of the egress guard (accepted, not fixed): (a) count cancellation at `secret_shaped()` in bin/orch-jev — in an adversarially constructed document, one placeholder-suppressed single-line assignment can cancel one credential that is only assembled across lines, so that cross-line value is sent; (b) a placeholder marker separated from a credential by a bare carriage return inside one LF line suppresses the hit. The existing Bash scanner (bin/orch-security-scan) shares the same class of misses. scan reads only the files you name (or stdin), and everything that passes the guard is sent to the Jev API, so do not point it at files you would not send there.

The default limits are 24,000 serialized state bytes, 20 items, and 24 chunks of 4,000 bytes.

The destination is `https://api.typesafe.ai`: one HTTPS POST per invocation, with at most one
retry. Redirects and other hosts are refused; loopback endpoints are permitted for offline tests.
All advisory outcomes exit 0; invalid command arguments exit 2. Failures print
`JEV: unavailable — <class>`. Classes include disabled, codex-only backend, config, no key,
template, auth, validation, rate limit, overloaded, redirect, other HTTP status, timeout, network,
malformed response, and schema. Retriable failures use at most two timeout periods plus 0.5 s
backoff (default timeout 6 s, roughly 12.5 s total); other failures return immediately.
Proxy environment variables are ignored, so connections are direct and a required proxy can cause a fail-open network error.

Every output line starts with `JEV:`. `risk` only suggests a higher tier with sufficient
confidence; its lines never form a tier declaration. Do not paste Jev output into a `RISK:` line.
`scan` supplements the existing regex security scanner; its advice cannot replace that check.
`jev-policy.conf` controls enablement, timeout, thresholds, caps, and journaling. It is read at
runtime and is outside `orch-policy-rev`; the model must be pinned to `jev-X.Y.Z` (default
`jev-1.13.0`). Question wording lives under `templates/jev/`.

`<state>/jev.log` is a mode-600 metadata-only journal: time, command, outcome, attempts, latency,
model, question count, and token usage. It contains no input text, source names, answers, or key;
set JEV_JOURNAL=0 in jev-policy.conf to disable it (the switch is read from that file only, not from the environment). Journal failures do not affect the advisory result.
Codex-only mode does not use it: `cc-orch-codex` sessions set `CC_ORCH_BACKEND=codex`, and the
tool refuses to call out.

### Codex-routing shadow mode (opt-in, log only)

Shadow mode is off by default (`JEV_SHADOW_ENABLED=0`) and runs only in hybrid mode;
Codex-only dispatch never starts it. When enabled, `codex-run-runtime` starts a detached
worker for eligible first-run `implement` calls and never waits for it. Dispatch, arguments,
stdout/stderr, exit codes, and `codex.log` remain unchanged, including when Jev is unavailable.
With the flag off, there is no shadow process, network request, or log write.

Use the sidecar's key setup above and set `JEV_SHADOW_ENABLED=1` in `jev-policy.conf`
(or the policy file selected by `CC_ORCH_JEV_POLICY`); `JEV_ENABLED=1` must also be set.
These are policy-file settings, not environment switches. The default mapping and limits are:

```bash
JEV_SHADOW_ENABLED=1
JEV_SHADOW_MAP_MECHANICAL="gpt-6-luna@medium"
JEV_SHADOW_MAP_ROUTINE="gpt-6-astra@high"
JEV_SHADOW_MAP_INVOLVED="gpt-6-astra@xhigh"
JEV_SHADOW_MAP_NOVEL="gpt-6-astra@xhigh"
JEV_SHADOW_MIN_CONFIDENCE=0.6
JEV_SHADOW_MAX_BYTES=12000
JEV_SHADOW_TIMEOUT_SECONDS=5700
JEV_SHADOW_LOG="codex-shadow.jsonl"
```

The only task content sent to Jev is `<task-dir>/brief.md`, with its `## Risk` section and
`RISK:` / `DEEP REASONING:` lines removed. The existing egress guard checks the raw brief
before truncation and the transformed request before sending; a match skips the call with
`skipped:secret-shaped`. Brief text is capped at `JEV_SHADOW_MAX_BYTES` UTF-8 bytes, with
`truncated=true` recorded when shortened. No `plan.md`, workdir code, or source-path metadata
is read for the request or sent. Policy, key, and question templates use the sidecar's existing
handling; the worker separately observes local `codex.log` and `.codex-session` metadata.

Jev classifies difficulty (`mechanical < routine < involved < novel`) and the probability of
needing extended non-local reasoning (Noul); it never chooses model names. The mapping is
ours: mechanical uses the existing `--mech` pair, routine lowers the healthy default's effort
one step, and involved/novel keep the healthy default. Below `JEV_SHADOW_MIN_CONFIDENCE`, no
pair is suggested (`suggested_reason=low-confidence`). Edit `JEV_SHADOW_MAP_*` in the policy
to change suggestions without a restart or any change to actual routing.

Records append to `<state>/codex-shadow.jsonl` with mode 600, separately from `jev.log` and
`codex.log`. `JEV_SHADOW_LOG` can override the path; relative paths are under `<state>`.
Each record has these fixed fields and contains no task text, file paths, or key:

```text
timestamp, id, lane, thread_id, mode, status, jev_model, difficulty, difficulty_confidence,
reasoning, suggested_model, suggested_effort, suggested_reason, initial_model, initial_effort,
initial_fast_mode, final_model, final_effort, final_fast_mode, final_fallback_from, attempts,
observation, explicit_flags, pressure, codex_exit, duration_ms, jev_latency_ms, jev_attempts,
input_tokens, truncated
```

`id` is `<lane>:<facade-pid>:<t0>`; unavailable answers or execution details are null.
`initial_*` records the facade's routed pair, while `final_*` and `attempts` reflect observed
execution, including fallback. `codex_exit` is the raw Codex exit from `codex.log`, not
`codex-run`'s exit. Concurrent calls in the same second and workdir can prevent attribution
(`observation=ambiguous`); observation can also be `exact`, `none`, or `timeout`. The worker
stops observing after `JEV_SHADOW_TIMEOUT_SECONDS`. A non-`ok` status or log-write failure
produces at most one `JEV: shadow <id> — <status>` diagnostic in `<state>/guard.log`, never
on the dispatch terminal. The shadow path does not write `jev.log`.

```bash
~/.claude/orchestra/bin/orch-jev shadow-report
~/.claude/orchestra/bin/orch-jev shadow-report --log <path>
```

The report re-applies the current policy mapping to stored raw answers without calling Jev.
It prints counts and rates only: agreement, lower/higher suggestions, skipped/unavailable
reasons, and failures/retries per suggested tier. Comparisons require `observation=exact`
and known suggested/final pairs; failure/retry rates use only exact observations with a known
exit. Other records count as unobserved. Buckets with fewer than 10 records are marked
` — fewer than 10 records`; those with fewer than 10 exact observations with a known exit are
marked ` — fewer than 10 observed`. Both markers may appear. It ends with `counts only — this report draws no conclusion.`

Coverage is limited to the facade: direct core `bin/codex-run` calls and Codex-only dispatch
produce no shadow record. With shadow enabled, `resume`, explicit
`--model` / `--effort` / `--mech` / `--fast` / `--escalate`, `--dry-run`, and withheld calls
are recorded as `skipped:resume`, `skipped:explicit-flags`, `skipped:dry-run`, or
`skipped:withheld`, without a Jev call or execution observation. Disabled or unavailable
automatic routing is recorded as `skipped:no-route`. Other modes are not recorded.
A worker started with malformed arguments (for example an invalid `--lane` name or an empty
task dir) records `skipped:invalid-args` without calling Jev.

### Local llama.cpp scan second opinion (opt-in, log only)

This companion is off by default and supports hybrid sessions. With `JEV_LOCAL_ENABLED=1`,
`orch-jev scan` hands its prepared request and Jev's answers to a detached
`bin/orch-jev-local worker` after the TypeSafe call, including unavailable outcomes. It never
waits for that worker. The companion changes no stdout, stderr, exit code, or `jev.log`
record from orch-jev and influences no gate or routing decision. With the flag off, the
companion starts no process and creates no file or log. `lint-brief` and `risk` never hand off.

Install the tested llama.cpp build and acquire the pinned model once. Replace `<env>` and
`<state>` with absolute paths; `<state>` is `CC_ORCH_STATE_DIR`, or
`~/.claude/orchestra-state` when unset. The tested package is conda-forge
`llama.cpp-10588-cuda130`; other builds may reject the launch flags.

```bash
conda create -y -p <env> -c conda-forge "llama.cpp=10588=cuda130_hd5b56ce_0"
mkdir -p <state>/models && curl -fL -o <state>/models/Qwen3-8B-Q8_0.gguf https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q8_0.gguf
```

Set `JEV_LOCAL_SERVER_BIN` in `jev-policy.conf` to `<env>/bin/llama-server`, then start:

```bash
~/.claude/orchestra/bin/orch-jev-local serve
```

`serve` verifies the model's SHA-256 before starting the server. A missing model prints an
acquisition hint and exits 1; a mismatch also exits 1. The harness never downloads a model
or starts a server automatically. `serve` stays in the foreground: run it under tmux or a
systemd user service. It reserves about **10.5 GiB of resident VRAM** on the GPU selected by
`JEV_LOCAL_GPU` (default 0), with a 16k context and one slot. It sets
`CUDA_DEVICE_ORDER=PCI_BUS_ID` and removes `LLAMA_ARG_*` environment overrides. Once the
server is running, set `JEV_LOCAL_ENABLED=1`. The shipped defaults are:

```bash
JEV_LOCAL_ENABLED=0
JEV_LOCAL_SOCKET="jev-local/llama.sock"
JEV_LOCAL_MODEL_PATH="models/Qwen3-8B-Q8_0.gguf"
JEV_LOCAL_MODEL_DIGEST="408b955510e196121c1c375201744783b5c9a43c7956d73fc78df54c66e883d6"
JEV_LOCAL_SERVER_BIN="llama-server"
JEV_LOCAL_GPU="0"
JEV_LOCAL_TIMEOUT_SECONDS=10
JEV_LOCAL_DEADLINE_SECONDS=60
JEV_LOCAL_LOG="jev-local.jsonl"
```

The worker receives exactly the prepared request sent to Jev, after both egress guards,
plus Jev's numeric answers. It repeats the post-transformation guard before inference.
It talks only to a Unix socket: no network connection, proxy, or redirects. `serve` creates
the socket's directory (default `<state>/jev-local`) and sets it to mode 0700, so use a
dedicated directory for the socket. The directory is owned by the operator, so it is not
reachable from browsers or other local users. `TYPESAFE_API_KEY` is removed from the worker and server environments.
The model file, socket, and log paths resolve relative to `<state>` unless absolute.

The worker appends one record to `<state>/jev-local.jsonl` (mode 0600), separate from
`jev.log`; `JEV_LOCAL_LOG` overrides the path. Its fixed fields are:

```text
timestamp, id, status, model, jev_model, jev_outcome, chunks, local_p, jev_p,
min_option_mass, requests, latency_ms, prompt_tokens, cached_tokens
```

There is no text, source names, line ranges or prompts in the log. `id` is
`<orch-jev pid>:<t0>` (the handoff timestamp in whole Unix seconds; `unknown` for invalid
handoffs); unknown values are null. `local_p` and `jev_p` preserve chunk order. Status is
`ok`, `skipped:secret-shaped`, or `unavailable:` followed by `handoff`, `config`, `server`,
`socket-denied`, `timeout`, `deadline`, `http <code>`, `malformed response`, `model-mismatch`,
`no-option`, `non-option`, `option-mass-unknown`, `network`, or `internal error`.
The worker writes no `guard.log` or other file; a failed log append is silently dropped.
Every local response must identify the alias `jev-local-<first 16 SHA-256 characters>`
set by `serve`. This detects model mismatches; it is not attestation against a process
that deliberately echoes the alias. The private socket directory is the access boundary.

```bash
~/.claude/orchestra/bin/orch-jev-local report
~/.claude/orchestra/bin/orch-jev-local report --log <path>
```

The report reads stored probabilities and re-applies the current `JEV_SCAN_THRESHOLD`
using `p >= threshold`. It prints status counts, chunk and record flag agreement, mean
absolute probability difference, and local latency median/p95. Comparisons require both
local and Jev outcomes to be `ok`; fewer than 10 comparable records are marked. It ends
with `counts only — this report draws no conclusion.` There is no local threshold or
advice output from the worker.

Codex-only mode never hands off. In a hybrid Codex sandbox, the Unix socket is denied
(`unavailable:socket-denied`) and the state-directory log write is denied too, so nothing
is recorded. Supported contexts are the user's shell and Claude lead/dev Bash. A stopped
server yields `unavailable:server`, never a delay waiting for the worker in orch-jev.
The phase-0 synthetic injection set measured local FPR **0.375** versus Jev **0.00**;
this signal is for data collection only.

## What changes without reload

The following are read at each dispatch or invocation and apply immediately:

- Claude/Codex percentages and reset times;
- `budget-policy.conf` thresholds and model tables;
- `orch-model-guard lanes` provider choice;
- the next immutable `route-lead-*` profile;
- the next Codex model/effort.

An already-running model process is not hot-swapped mid-turn:

- the Tier-1 orchestrator keeps the model selected by its normal launch;
- a running lead keeps its current model and context;
- new policy applies at the next lead or Codex dispatch boundary.

`cc-orch --reload` remains appropriate after structural prompt/template/agent-definition changes
(`agents/*.md`, `templates/*.tpl`, and structural `model-policy.conf` settings).
The prompt hook distinguishes that case from ordinary budget movement.

Changing lead model/effort tiers in `model-policy.conf` also requires rebuilding the rendered
`~/.claude/agents/lead-*.md` and `~/.claude/agents/route-lead-*.md` roster: run `./install.sh` (which calls
`build-roster-runtime.sh`), then `./install.sh --check`, then `cc-orch --reload <project>`.
Reload alone does not regenerate the roster. A managed session can instead exit with `/exit`
and use `cc-orch session restart <name>` to continue the conversation.

With a live session, reload discovers `.orchestra/REGISTRY.md` like the hooks: git toplevel
and its ancestors, process cwd and its ancestors, the git common directory's parent, then
linked worktrees. The first existing file wins. Any active lead row refuses reload. Terminal
statuses are `PASS`, `FAIL`, `BLOCKED`, `ACCEPTED`, `CLOSED`, `IDLE`, and `UNASSIGNED`, optionally followed
by a character outside `[A-Za-z0-9_-]` and an annotation, such as `PASS (done)` or
`CLOSED - merged`; `PASS-ish` and empty statuses are active. A missing or unreadable registry,
or an unresolvable process cwd, also refuses reload. Missing-registry diagnostics list every
path checked; unreadable-registry diagnostics name the file, and unresolved-cwd diagnostics
identify the process. `--force-reload` is the only override. Reload sends SIGTERM and never
SIGKILL. `cc-orch-session switch` uses the same terminal-status rule, with `--force` as its override.

## PreToolUse poll guard (opt-in)

Running sessions can retain stale cached agent definitions and therefore keep issuing manual
`sleep` loops that poll background gate result files even after their prompt templates are fixed.
The opt-in `hooks/orch-poll-guard.sh` defense intercepts those Bash calls. Hook scripts are read
from disk for each call, so script updates do not depend on the agent-definition cache.

An isolated scope test using project-local settings confirmed that `PreToolUse` applies both to
top-level Bash calls and to Bash calls made by Task/Agent-spawned subagents. Application from
user/global settings was not directly measured; it is inferred from the shared hook engine.
Subagent payloads include `agent_id` and `agent_type`; the guard itself needs only the exact
`tool_name: "Bash"` check. On that inference, registration can protect leads spawned by the
currently running orchestrator even when their agent definitions are stale. Claude Code normally
watches settings changes, but hot reload is still a runtime behavior: if an existing session does
not observe the new registration, restart that session. Once registered, edits to the referenced
script are read on subsequent calls.

This task does not register the hook automatically. To opt in, merge this entry into Claude
settings without replacing existing hooks (replace the repository path if this checkout moves):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/absolute/path/to/cc-orch/hooks/orch-poll-guard.sh' || true",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

The `|| true` is mandatory. Denials are emitted as JSON with exit status 0, so the normalizer does
not hide them; it only keeps a damaged or syntactically broken hook script from blocking every
Bash call.

The detector is intentionally narrow. A `while` or `until` keyword must be at command position,
and its live command text must combine `sleep` with a file-watch primitive such as `[`, `test`,
`grep`, `cat`, `stat`, or `find`. Comments and heredoc bodies are inert and can never contribute
to a denial. Ordinary quoted data is also excluded from loop, sleep, and primitive matching; it
may only satisfy the `.orchestra/` or `codex-*.md`/`codex-*.jsonl` TARGET signal inside an otherwise
live loop. Executable quoted payloads (command substitution inside double quotes and the first
quoted payload after standalone shell `-c`) remain code. Heredoc delimiters support word, dot,
and hyphen characters; quoted/commented heredoc-like text and here-strings (`<<<`) are not openers.
Combined short options such as `-lc` remain a known false negative. Other accepted false negatives
are `for` loops, loops split across multiple Bash calls, `eval`/`$'…'`/process-substitution payloads,
and polling of non-orchestra paths; prompt guidance remains the first line of defense. The residual
false-positive risk is a legitimate live loop whose unquoted text carries all required signals.

Measured Python inspection latency is approximately 28–65 ms per matched Bash tool call.

If the guard causes a false positive, disable it immediately for all sessions:

```bash
mkdir -p ~/.claude/orchestra-state
touch ~/.claude/orchestra-state/poll-guard.off
```

Remove the file to re-enable the guard. To roll back permanently, remove this `PreToolUse` entry
from settings; the script can remain on disk.

## Verifier Bash command guard

`verifier` and `verifier-normal` register `hooks/orch-verifier-bash-guard.sh` in their own
`PreToolUse` frontmatter, with a `Bash` matcher. Installation already links these definitions
into `~/.claude/agents/` and the repository into `~/.claude/orchestra/`, where the hook command
resolves the script independently of the task working directory. No separate `settings.json`
registration or opt-in is needed. The hook applies only to these verifier definitions.
See Claude Code's [hooks in subagent frontmatter](https://code.claude.com/docs/en/sub-agents#hooks-in-subagent-frontmatter)
and [agent definition reload behavior](https://code.claude.com/docs/en/sub-agents#write-subagent-files).
Edits normally take effect on the next delegation; restart if the agents directory was newly
created, the definition is in an added directory, or the session disables slash commands.

The agents' Bash command policies list the denied mutation families and allowed inspection/test
examples. The guard checks command positions, quoted verbs, common neutral wrappers, and shell
heredocs while allowing arbitrary legitimate verification runners. It emits deny JSON with a
reason and always exits 0. Bash parsing/classification failures deny the command by default with
a clear parsing-failure reason, including errors encountered during recursive inspection.
Malformed/non-Bash hook events and external failures that prevent the Python inspector from
running retain pass-through handling; the frontmatter's `|| true` also covers shell startup
errors. There is no `.off` file; operational changes require editing the agent frontmatter directly.

This is defense in depth, not a shell sandbox: obfuscated `eval`, encoded payloads, unknown
wrappers, and commands inside test scripts can bypass text inspection. The assigned verdict
path is absent from the hook input, so the restriction on writing only that file remains
instruction-enforced; `echo`/`printf`/`tee` writes to another single file are not mechanically
distinguishable. Run `bash tests/test-verifier-bash-guard.sh` to exercise the hook's deny/allow
decisions and installed-path wiring without a live agent session.

Known residual gaps are explicitly accepted under this defense-in-depth scope:

The guard's fundamental architecture is extract-commands-then-deny-if-denylisted; any shell construct the lexer does not know how to extract commands from yields zero extracted commands, which defaults to allow -- this is a structural property of a denylist-based approach over an expressive grammar, not a fixable one-off bug, and a real fix would mean inverting to an allowlist-of-recognized-shell-grammar architecture, which is out of scope for this task.

- Explicit stdin shell invocation, such as `bash - <<< "rm target"`, can bypass heredoc/here-string
  inspection. The unparenthesized declaration `function f { rm target; }; f` can also bypass inspection.
- Interpreter one-liners (`perl -e`, `python -c`, `node -e`) and command wrapping through
  `ssh host cmd`, `su -c`, `flock`, or `watch` remain outside reliable enforcement.
- `coproc rm target` is allowed because the lexer does not recognize `coproc` as a
  command-position introducer, so the destructive command inside it is never extracted/classified.
- Dangling/incomplete `&&` or `||` at the end of an otherwise-valid command, such as
  `printf safe &&`, is syntactically invalid Bash that a real shell would reject. The lexer
  accepts it without error and extracts no meaningful trailing command, so nothing is denied.
- Known false positives remain: `env -S` may interpret a literal safe string as executable code;
  `git branch --list -- "-D*"` may be misread as a deletion. Parsing failures are denied even if
  the input is actually safe, including failures in speculative `env -S` inspection.

These disclosed gaps do not authorize verifier mutations. The verdict-only writing instruction
and the command policy still apply when the hook misses an operation.

## Runtime safety hooks

Installation registers independent hooks in user settings and in the session guardrails.
`bash install.sh --safety-hooks-only` merges just these registrations, without installing links,
changing executable bits, or contacting systemd. It honors `CC_ORCH_SETTINGS` (default:
`$HOME/.claude/settings.json`), preserves unrelated entries, and updates an existing hook command
when the checkout path changes; re-running it also restores each hook's intended matcher and timeout
and collapses duplicate registrations (recognised by the `hooks/<name>` path segment) to one entry.
Commands retain `|| true`; timeouts are 10 seconds for
`PreToolUse` and 30 seconds for `SubagentStop`. The checked-in `guardrails.json` uses the existing
`/home/janghun/cc-orchestra/hooks/` prefix; adjust it for a different installation location.

`hooks/orch-worktree-guard.sh` examines Bash Git commands against the existing
`.orchestra/REGISTRY.md`. A lead row is active when its status is nonempty and not exactly
`PASS`, `FAIL`, `BLOCKED`, `CLOSED`, `IDLE`, or `UNASSIGNED`; `PASS (worktree)` remains active.
Identity first uses an active row's `agentId`: exact equality or a prefix with at least eight
characters. Otherwise it recognizes `(route-)?lead-(alpha|bravo|charlie|delta)` with an optional
`light`, `normal`, `critical`, or `critical-xhigh` suffix, or `dev(-opus)?-<positive integer>`.
Unknown actors, including ordinary orchestrator calls, bypass evaluation.

The guard classifies `commit`, `merge`, `rebase`, `cherry-pick`, `revert`, `reset`, `am`, `apply`,
`add`, `rm`, `mv`, `stash`, and `restore` as index writes; `checkout`, `switch`, `branch` with
`-f/-D/-m/-M`, and `tag` with `-f/-d` as ref moves; and `push` separately. It denies only:

- **R1:** a lead/dev index write or bare/unresolved-ref push from `main`, `master`, `develop`, or
  `trunk`. Pushes explicitly targeting any of those protected destinations, or using `--all`
  or `--mirror`, are denied regardless of the checked-out branch. Wildcard destinations are
  protected only when they can match a protected branch: `refs/heads/*` and `*` do, while
  `orch/*` and `releases/*` do not. R1 allows an explicit non-protected push refspec, bare and
  tag-only (`--tags`) pushes from task branches, and switching away from a base branch to create
  a task branch. Non-protected wildcard pushes from task branches remain allowed.
- **R2:** a known lead mutating a checkout on another active lead's registered branch.
- **R3:** a known lead mutating another active slot's `.orchestra/wt/<slot>` checkout.
- **R4:** a known lead mutating the registry-owning shared checkout while at least two lead rows
  are active. The denial names other slots and suggests
  `git worktree add <repo>/.orchestra/wt/<slot> -b <your branch>`.

The registry `dir` is an artifact directory, resolved against the repository root, not ownership
of a checkout. Branch ownership uses the checkout HEAD and registry branch; Git worktree metadata
also locates the shared registry from linked checkouts. Each invocation has its own target.
The guard tracks the effective branch after a branch-changing `checkout`/`switch` segment, keyed
by resolved checkout root so `cd` and `git -C` aliases share the override. Creation flags
`checkout -b/-B` and `switch -c/-C` supply the new branch; a plain branch argument must resolve
as a local `refs/heads/` branch. Path checkouts, detached SHAs, and ambiguous forms do not update
the branch model. Thus a single in-place lead can create a task branch and commit in one call,
while switching to `develop` before committing triggers R1; shared-checkout rules still apply.

Directory and effective-branch changes follow one conditional-execution rule. A `cd`/`pushd`
or branch-changing `checkout`/`switch` preceded by `&&` or `||` retains both the previous and
new values as candidates. A first-segment change, or one after `;` or newline, is unconditional
and replaces the corresponding candidates. Each later Git invocation evaluates every candidate
cwd and every candidate branch for its resolved checkout; any violating combination denies the
call and reports the rule that fired. Unresolvable conditional changes introduce no new candidate.
Thus `false && git switch -c orch/new; git commit` cannot hide a protected branch, while
unconditional `git switch -c orch/new && git commit` and `cd <own-worktree> && git commit`
retain their legitimate allow paths. A missing or non-directory target leaves the modeled cwd
unchanged, matching Bash's failed directory change.
Leading `~/` and bare `~` resolve through `$HOME`; `~user` remains unresolvable.
Quoted prose, comments, and heredoc bodies are inert. Unknown targets such as `cd -`, unexpanded variables, or explicit
`--git-dir`/`--work-tree` overrides fail open. Read-only/unclassified commands and missing or
malformed registries do not block. Complex shell evaluation is not a complete shell interpreter.

`hooks/orch-stop-gate.sh` is registered on **SubagentStop**, with matcher `(route-)?lead-.*`;
`Stop` is for the main session. It checks the last assistant transcript message only when it
contains a `STATUS: PASS`, `FAIL`, `BLOCKED`, or `ACCEPTED` line (optionally prefixed with a lead label) and a
`GATES:` line. Prose such as “I will report the STATUS: PASS when done” does not claim a result.
Ordinary mid-task messages do not run a checker. Any truthy `stop_hook_active`
value (including boolean `true`, string `"true"`, or numeric `1`) bypasses the gate to prevent a
stop loop. The registry row selected by agent ID, then slot, supplies the task directory even if
`ARTIFACTS:` names another task. An `ARTIFACTS:` fallback is considered only when no registry
can be found at all. If a registry exists without a task row for this lead, the hook warns and
never validates an unrelated artifact directory. The fallback must be an existing directory
containing `brief.md` whose resolved path stays inside the Git repository root derived from
payload `cwd`; an unknown repository root or an outside path, including a symlink escape, warns.

When the resolved task directory exists but has no `summary.md`, the hook emits only an
informational `systemMessage`: `summary.md not saved yet; Tier 1 saves the returned block and
runs orch-summary-check --strict <dir>`. It journals a `note`, writes nothing to stderr,
and does not invoke the checker.

The checker is resolved through `CC_ORCH_SUMMARY_CHECK` (an executable path for operators/tests),
then the hook's own repository `bin/orch-summary-check`, `$HOME/.local/bin/orch-summary-check`,
then `PATH`. It runs with `--strict <task-dir>` and reads the task's own `summary.md` STATUS
line, accepting a `[lead-x]` prefix. Exit 0 allows silently when the transcript and recorded
statuses agree; disagreement, including an unavailable recorded status, produces a warning.
Like the checker, the hook reads the `summary.md` STATUS line outside fenced blocks.
Exit 1 blocks a transcript claiming `PASS` or `ACCEPTED`, including when summary.md records `BLOCKED`
or `FAIL`. The block includes the first 1,500 bytes of checker output, the exact rerun command,
and the off-switch. A transcript claiming `BLOCKED` or `FAIL` is never blocked: a failing check
produces a warning carrying checker output so honest escalation can finish.
An unresolved task/checker, exit 2, or execution failure also allows with a `systemMessage`
warning, the same warning on stderr, and a journal record. An absent/unreadable transcript has no observable claim and
allows silently. Repository containment and `brief.md` checks are structural validation, not
proof that the fallback task belongs to the reporting lead. Missing Python fails open silently;
intentional gate warnings still reach stderr, stdout JSON, and the journal.

Both hooks always exit 0; decisions travel in JSON. Disable them independently with:

```bash
state_dir="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}"
touch "$state_dir/worktree-guard.off"
touch "$state_dir/stop-gate.off"
# Remove the corresponding .off file to re-enable a hook.
tail -n 30 "$state_dir/safety-hooks.log"
```

The journal path is `${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/safety-hooks.log`.
Evaluated Git invocations and detected claims append an ISO timestamp, hook/event, actor identity,
decision (`allow`, `deny`, `block`, `warn`, `note`, or `skip`), and one-line reason. Fast paths do not log.
Bash payloads without both a bare `git` token and a mutation keyword return before starting Python
or Git. Records use one bounded append write. Only above 2 MiB does an exclusive trim lock permit
retaining about 1 MiB via a temporary file and atomic rename; appenders coordinate with rotation so records
are not lost to the replaced inode. Lock contention skips trimming.

Limitation: Claude Code 2.1.270's documented `SubagentStop` payload has not been measured in this
repository. `PreToolUse` subagent identity was measured; stop-event identity/transcript behavior
still needs a live-session check. Inspect the journal after a known gate claim: a missing record
may mean an unsupported payload, a hook that did not fire, or an off-switch. `systemMessage`
display on `SubagentStop` is also unconfirmed; stderr and the journal preserve warnings.

### Compaction recovery hook

`hooks/orch-compact-context.sh` runs on `SessionStart` with matcher `compact`, registered in
`guardrails.json` and user settings (also by `--safety-hooks-only`), with timeout 10 and `|| true`.
Guardrails and the installer write the identical unquoted command for the default `/home/janghun/cc-orchestra` path.
Locally on 2.1.287, an identical command registered in two settings files ran once, while differently quoted
variants ran twice, so installations at another path must keep the guardrails string identical to the installed one.
It requires `CC_ORCH_PROJECT`, skips subagent payloads, and is disabled by `$state_dir/compact-context.off`
(`state_dir=${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}`). It reads local files only and fails open.
The labelled data contains registry rows with full agentIds, the slot board, optional `DIRECTIVES.md`, and fixed notes.
Open versus terminal rows follow the reload rule: `PASS`, `FAIL`, `BLOCKED`, `ACCEPTED`, `CLOSED`, `IDLE`,
or `UNASSIGNED` followed by `[^A-Za-z0-9_-]` or end of string are terminal; an empty status is open.
The entire JSON stdout is capped at 6144 UTF-8 bytes: drop oldest terminal rows first, then directive
lines from the end, then oldest open rows; keep the board. Directive lines over 1000 characters are omitted whole.
Live routing is excluded because computing it can start a usage refresh; the next prompt restores it.
[Hook documentation](https://code.claude.com/docs/en/hooks) documents `SessionStart` matcher `compact`
and `additionalContext`. On 2.1.287, a headless manual `/compact` locally showed
PreCompact → SessionStart(compact) → PostCompact, with recovered context after the compact boundary.
Automatic compaction remains unverified live. Running sessions need `cc-orch --reload <project>` or a
relaunch to pick up the hook because guardrails are read at startup. Install with `./install.sh`,
then run `./install.sh --check` to verify the installed runtime.

## Archive (orch-archive)

`orch-archive` archives cc-orch sessions, task directories (including unfinished work and
nested historical copies), registries, linked Claude transcripts and referenced Codex rollouts.
Native Codex rollouts without a cc-orch link are counted but not copied. Generated structure
is English; historical prose, including Korean registry cells, is preserved verbatim.

The private local git vault defaults to `~/orchestra-vault`; lossless compressed raw files
live outside git at `~/.claude/orchestra-archive/raw` (directories 0700, files 0600).
Sources are never modified, moved or deleted. Live logs use byte-offset watermarks for
complete lines; any unterminated tail is also preserved separately. Snapshots are immutable,
and the cumulative catalog retains tasks whose source checkout was deleted.

```bash
orch-archive                       # read-only plan; creates nothing
orch-archive plan --json --top 20
orch-archive plan --json --measure-thumbnails   # also encodes thumbnails in memory; writes nothing
orch-archive apply                 # writes locally and commits changes in the vault
orch-archive apply --no-commit
orch-archive verify
orch-archive show cc-orchestra--38-orch-archive
```

`archive-policy.conf` controls storage paths, discovery bases, inclusion switches and size
limits. `ORCH_ARCHIVE_POLICY` selects an override policy. Path overrides are
`ORCH_ARCHIVE_VAULT`, `ORCH_ARCHIVE_RAW`, `ORCH_ARCHIVE_ALLOWLIST`,
`ORCH_ARCHIVE_STATE_DIRS`, `ORCH_ARCHIVE_CLAUDE_PROJECTS`, `ORCH_ARCHIVE_CODEX_HOME`
(then `CODEX_HOME`) and `ORCH_ARCHIVE_EXTRA_BASES`. Policy is parsed as data, never sourced.
Vault/raw overlap or destinations inside source roots are rejected.

Every text-like file is copied into the raw store. Payload files default to a 16 MiB per-file
and 256 MiB total per-task budget; if total payload exceeds the task budget, all payload in
that snapshot is manifest-only. Change `PAYLOAD_FILE_MAX_BYTES` and `PAYLOAD_TASK_MAX_BYTES`
before apply (`0` means unlimited), or set `INCLUDE_PAYLOAD=0`. Every omitted payload file
is listed with its size and reason; the plan reports sizes before and after compression, plus
vault bytes split into artifacts, notes, catalog and other files. Generated task/root manifests
live only in the raw store as deterministic gzip blobs, counted under `raw.manifests`; task
and project notes reference their blob path, uncompressed SHA-256 and length. Catalog snapshots
hold counts and manifest pointers. `verify` checks the pointers and manifest JSON. Artifact copies
are restored from verified raw blobs at write time, so plans retain lengths and pointers.

Checkpoint files are never copied or content-hashed. `CHECKPOINT_EXTENSIONS` defaults to
`.pt .pth .ckpt .safetensors .onnx .engine .trt .h5 .npz .npy` (case-insensitive; empty disables).
Their paths, sizes and UTC mtimes appear in task notes; the report lists checkpoint counts,
bytes and largest tasks. Checkpoints do not consume the payload budget.

PNG files are archived as small JPEG thumbnails, never as originals. `IMAGE_EXTENSIONS`
defaults to `.png` (only `.png` is supported; empty disables the image path, and PNGs then
follow the payload limits above). The original PNG bytes are never copied into the vault or
the raw store: each image yields at most one baseline JPEG thumbnail under
`artifacts/tasks/<task>/thumbs/` (roots: `artifacts/roots/<project>/<hash>/thumbs/`), keyed by
the source content so identical images share one file. Alpha is composited onto white and
EXIF, ICC and text metadata are dropped. The encoder is detected at run time: Pillow if
importable (imported lazily), else `ffmpeg`, else none; `THUMB_ENCODER=auto|pillow|ffmpeg|none`
forces a choice. With no encoder the image is recorded as metadata only (`no-encoder`) and the
report prints `no image encoder` once. Defaults: `THUMB_MAX_EDGE=512` px longest edge,
`THUMB_QUALITY=70`, `THUMB_MAX_BYTES=65536` per thumbnail, `THUMB_MAX_PIXELS=100000000`
(larger sources are metadata only, `over-pixel-cap`, and are never decoded) and
`THUMB_EMBED_MAX=8` Obsidian embeds in the task note, with `THUMB_MAX_PER_TASK=48` thumbnails
per task (0 disables thumbnails). A thumbnail above the byte cap is retried
with lower quality, then smaller sizes; if none fits it is metadata only (`thumbnail-over-cap`).
Every file named `.png` first gets a structural check (signature, IHDR, chunk CRCs, chunks
through IEND). A file that fails it (`not-png`, `bad-header`, `bad-chunk-crc`, `truncated`) is
a source error (`invalid-image`, exit **4**) and the run continues; so is pixel data that
looks valid but cannot be decoded (`decode-failed`, metadata only). The task note and catalog
record, per sampled image, the relative path, size, UTC mtime, source SHA-256, pixel dimensions, thumbnail
path, size and dimensions, encoder id and version, and the parameters used. The SHA-256 (and the
full chunk-CRC read) is computed only for sources within `PAYLOAD_FILE_MAX_BYTES`; larger
sources are validated by a seek-only chunk walk and keep no hash. Each task gets at most
`THUMB_MAX_PER_TASK` (48) thumbnails chosen at evenly spaced positions of its sorted PNG list
(first and last included when the sample has at least two images; a sample of one selects the first).
The rest are metadata only (`not-sampled`), summarized per folder in the note and listed per file
in the raw-store manifest. All PNGs still undergo validation; invalid sampled files leave empty
slots, and the sample is not refilled. The budget reserves `min(n, THUMB_MAX_PER_TASK) × THUMB_MAX_BYTES`
for `n` PNGs, never their source bytes. Selection and reservation apply separately to each task
location and root scan. Only one decoded image is held in memory at a time.

Thumbnails are idempotent per machine, not across machines: an image is re-encoded only when its
source (hash, size, mtime), the encoder id/version or the parameters change; JPEG output differs
between encoders and Pillow versions, so a different tool re-encodes and overwrites that
thumbnail in the vault (git keeps the history). `plan` encodes nothing and reports such images
as `pending`; `plan --measure-thumbnails` encodes them in memory (nothing is written) and adds
`images_measurement` (encoded/reused counts, encode seconds, wall seconds, peak RSS) to the
printed report only, never to a stored file.

Unreadable or vanished sources are skipped without aborting the run. `source_errors` reports
the exact count and a bounded list of guarded paths, reasons and errno values (`--top` controls
the list). Plan and apply exit **4** if any source errors occurred; apply still writes the
successful sources and commits. Restore access or the missing source and rerun. Exit 0 means
success without source errors; existing usage/policy, verify and lock-busy statuses are unchanged.

The existing advisory secret scanner guards all vault-bound text; false positives and false
negatives are possible. Withheld content stays in the private raw store. `_meta/withheld.md`
lists hashes and locations, never matched content. To release an item, append
`sha256:<full hash from the report>` to `~/.claude/orchestra-archive/allowlist.txt`
(or the configured allow-list) and re-run apply. Raw logs are lossless and are not scanned.
The full-text backstop honors released values in both raw and JSON-escaped metadata while
rejecting other secret-shaped lines.
The tool makes no network or model calls, configures no remote, and never pushes.

The managed `.obsidian/graph.json` is regenerated on apply and excludes artifacts, metadata
and dashboards from the graph. Frontmatter and `.base` dashboards use JSON-compatible YAML
flow syntax, validated with the Python standard library. Obsidian rendering was not visually
verified; Bases needs Obsidian >= 1.9.0.

### Open limitations (not re-gated)

- Withheld session conf values have no raw backup: a secret-shaped value in a session conf,
  named-launch record or `project.json` is redacted in the vault catalog, and the source file
  itself is not copied to the raw store. The value is unrecoverable once the source is deleted;
  allow-listing it later cannot restore it (`lib/orch_archive.py`, `Archive.build` session loop;
  final review finding).
- The payload-limit fix for secret-shaped filenames landed after the last gate and is not
  gated (`lib/orch_archive.py`, `Archive.scan_files`).
- The PLTE-required check for indexed PNGs landed after the last gate and is not gated
  (`lib/orch_archive.py`, `png_info`).
- `.orchestra/wt` and `.orchestra/archive` containers are skipped as a whole with their byte
  totals reported. Only nested `.orchestra` roots inside them are archived; loose files such
  as `archive/<x>/handoff/` are not copied.
- Codex-only installs (`install_codex_only`) do not link `orch-archive`.
- Obsidian rendering (graph colors and Bases dashboards) has not been checked visually.
- Thumbnails, once written, stay in the vault's git history like other artifacts; changing the
  encoder or parameters adds new versions, and old versions are not pruned.
- The per-file `sampled: false` flag lives in the immutable snapshot manifest. Changing
  `THUMB_MAX_PER_TASK` later updates the catalog, note and folder summary, but not the flags
  in manifests already written for that snapshot.
- `plan` without `--measure-thumbnails` cannot detect pixel-data corruption (reported as
  `pending`); only `apply` or the measuring plan decodes. Sources above `PAYLOAD_FILE_MAX_BYTES`
  get no chunk-CRC check and no hash before encoding.
- A 16-bit RGB PNG with a tRNS key is matched on the key's high bytes (Pillow decodes it to 8 bits),
  so samples differing from the key only in the low byte may also turn white; 16-bit gray keys
  are matched exactly.
- Only PNG is supported; `.bmp`, `.tif` and other raster formats follow the payload limits.
- Pillow 9.0.1 compatibility is by construction (no newer-only calls) and has not been run;
  Obsidian embed rendering of the thumbnails has not been checked visually.

## Tuning

`model-policy.conf` owns static role/profile model and effort defaults;
`budget-policy.conf` owns pressure-based Claude profiles, Codex model/effort, and provider choice.

Edit `budget-policy.conf`. It is excluded from `orch-policy-rev`, so tuning does not invalidate
the prompt cache.

Important controls:

```text
BUDGET_WATCH_RATIO
BUDGET_TIGHT_RATIO
BUDGET_CRITICAL_RATIO
BUDGET_NEAR_RESET_MINUTES
BUDGET_PROVIDER_SWITCH_MARGIN
BUDGET_CODEX_SPARING_MIN_RANK
BUDGET_FABLE_RESERVE_PCT
CLAUDE_ROUTE_*_PROFILE
CODEX_AUTO_<MODE>_<PRESSURE>_{MODEL,EFFORT,ALLOW}
```

Use `orch-model-guard budget` after a change to verify the resulting pressure and routing before
starting a large task.

## Status and regression checks

```bash
orch-model-guard status
orch-model-guard route lead normal alpha
orch-model-guard route codex implement
```

`status` combines the legacy Fable guard and runtime budget; `budget` reports pressure/headroom
and reset times; `lanes` reports the provider decision and reason. The route commands preview
the next lead profile/model/effort or Codex model/effort/allow result.

```bash
bash tests/test-policy.sh
bash tests/test-runtime.sh
bash tests/test-tier1-runtime.sh
bash tests/test-notice-runtime.sh
```

These cover model-policy profiles, reset-aware pressure, Claude/Codex routing, Fast compatibility,
provider reserves, normal Tier 1 Sonnet, stale-policy notice false positives, managed tmux/worktree
lifecycle, status-line preservation, and runtime-hook JSON contracts.

### Estimated Codex cost (orch-usage-report --cost)

Run `orch-usage-report --days 7 --cost` for an estimate at published API rates, not an account debit.
Calls consume ChatGPT-plan quota; dollar amounts are a relative-load proxy only.
`pricing-policy.conf` records rates, effective date and source URL; override with `CC_ORCH_PRICING_POLICY`. It never affects routing.
The Astra counterfactual re-prices the same observed tokens; Astra would use different token counts.
Unpriced calls lack surviving token data; coverage counts calls with tokens and a valid rate over all calls in the window.
Fast multipliers are unknown by default (Standard-rate estimates); per-request long-context surcharges are not applied.
Attribution uses event-file mtimes and wrapper log order. Same-mode runs in one root with crossing intervals can be swapped when no other wrapper call starts between their completions.
Copied or touched task directories can give event files newer mtimes and attribute their tokens to newer calls.
Token-to-call matching is an estimate: `codex.log` has no event-file or run identifier.
`codex-run` writes the event file before its `codex.log` line; another call appending between these writes can cause the completing call to be priced under the other call's model.
Exact matching needs a deferred `codex-run` log change; `orch-jev` parses the line with a full-line regex.
