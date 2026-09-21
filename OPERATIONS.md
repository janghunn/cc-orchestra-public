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
codex   critical
  7d    used=90% headroom=0.117 reset=... in 6d

dispatch=codex-sparing
```

Claude data comes from the status-line tap. Codex data comes from the newest
`rate_limits.primary` object in `~/.codex/sessions/**/rollout-*.jsonl`; no extra model call is
made.

## Dynamic routing

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

The command returns an immutable agent type such as `route-lead-bravo-normal`, plus its model and
effort. `build-roster-runtime.sh` generates all 16 slot/profile combinations, and the legacy quota
guard never rewrites the `route-lead-*` namespace. Usage changes therefore choose among already
cached agent types rather than rewriting definitions.

`orch-summary-check` also prints a separate advisory security scan of added lines in committed
changes from the current branch's merge base with local `main` (or `origin/main`) to `HEAD`.
Run it from the task worktree, even when the executable is installed in another checkout or
the task artifacts are stored in the orchestrator's checkout. Outside a Git checkout, it falls
back to the repository containing the task directory; it never scans the installation by default.
It checks `.md`, `.json`, `.conf`, and `.sh` files for secret-shaped literals, instructions to
bypass confirmation, and broad Bash permission strings. Findings are warn-only and never change
PASS/FAIL or gate error/warning counts, including with `--strict`; unavailable Git bases are
reported as skipped, not clean. Secret-bearing lines are redacted from diagnostics. To scan
full on-disk files, run `bin/orch-security-scan --files <file>...` (exit 0 for
no findings, 1 for findings).

Codex model and effort are resolved automatically on each new `codex-run` invocation:

```text
healthy   implement -> Astra xhigh (Fast; Sol xhigh when Astra is unavailable)
watch     implement -> Sol high
tight     implement -> Terra high
critical  implement -> withheld; Claude fallback

healthy   review -> Astra high (Fast; Sol high when Astra is unavailable)
watch     review -> Sol medium
tight     review -> Terra high
critical  review -> Terra medium (gate reserve)
```

The complete table is in `budget-policy.conf`. Auto-routed healthy calls emit
`CODEX-RUN: MODEL_FALLBACK` and use the lane's plain Sol/Terra default when Astra is unavailable;
explicit Astra requests instead exit 6 with `MODEL_UNAVAILABLE`. Set
`CC_ORCH_CODEX_CATALOG_CHECK=0` to disable the live/cached catalog pre-flight. Explicit flags always win:

```bash
codex-run ... --model sol --effort xhigh
codex-run ... --model astra
codex-run ... --critical
codex-run ... --fast-mode
codex-run ... --mech
```

Disable automatic Codex routing for one command or shell:

```bash
CC_ORCH_AUTO_ROUTE=0 codex-run ...
export CC_ORCH_AUTO_ROUTE=0
```

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

Known limits of the egress guard (accepted, not fixed): (a) count cancellation at bin/orch-jev:164 — in an adversarially constructed document, one placeholder-suppressed single-line assignment can cancel one credential that is only assembled across lines, so that cross-line value is sent; (b) a placeholder marker separated from a credential by a bare carriage return inside one LF line suppresses the hit. The existing Bash scanner (bin/orch-security-scan) shares the same class of misses. scan reads only the files you name (or stdin), and everything that passes the guard is sent to the Jev API, so do not point it at files you would not send there.

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
JEV_SHADOW_MAP_MECHANICAL="gpt-5.6-luna@medium"
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
exit. Other records count as unobserved. Buckets with fewer than 10 such observations are
marked `fewer than 10 records`. It ends with `counts only — this report draws no conclusion.`

Coverage is limited to the facade: direct core `bin/codex-run` calls and Codex-only dispatch
produce no shadow record. With shadow enabled, `resume`, explicit
`--model` / `--effort` / `--mech` / `--fast` / `--escalate`, `--dry-run`, and withheld calls
are recorded as `skipped:resume`, `skipped:explicit-flags`, `skipped:dry-run`, or
`skipped:withheld`, without a Jev call or execution observation. Disabled or unavailable
automatic routing is recorded as `skipped:no-route`. Other modes are not recorded.

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

`cc-orch --reload` remains appropriate after structural prompt/template/agent-definition changes.
The prompt hook distinguishes that case from ordinary budget movement.

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

Installation registers two independent hooks in user settings and in the session guardrails.
`bash install.sh --safety-hooks-only` merges just these registrations, without installing links,
changing executable bits, or contacting systemd. It honors `CC_ORCH_SETTINGS` (default:
`$HOME/.claude/settings.json`), preserves unrelated entries, and updates an existing hook command
when the checkout path changes. Commands retain `|| true`; timeouts are 10 seconds for
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
contains a `STATUS: PASS`, `FAIL`, or `BLOCKED` line (optionally prefixed with a lead label) and a
`GATES:` line. Prose such as “I will report the STATUS: PASS when done” does not claim a result.
Ordinary mid-task messages do not run a checker. Any truthy `stop_hook_active`
value (including boolean `true`, string `"true"`, or numeric `1`) bypasses the gate to prevent a
stop loop. The registry row selected by agent ID, then slot, supplies the task directory even if
`ARTIFACTS:` names another task. An `ARTIFACTS:` fallback is considered only when no registry
can be found at all. If a registry exists without a task row for this lead, the hook warns and
never validates an unrelated artifact directory. The fallback must be an existing directory
containing `brief.md` whose resolved path stays inside the Git repository root derived from
payload `cwd`; an unknown repository root or an outside path, including a symlink escape, warns.

The checker is resolved through `CC_ORCH_SUMMARY_CHECK` (an executable path for operators/tests),
then the hook's own repository `bin/orch-summary-check`, `$HOME/.local/bin/orch-summary-check`,
then `PATH`. It runs with `--strict <task-dir>` and reads the task's own `summary.md` STATUS
line, accepting a `[lead-x]` prefix. Exit 0 allows silently when the transcript and recorded
statuses agree; disagreement, including an unavailable recorded status, produces a warning.
Exit 1 blocks only a transcript claiming `PASS`, including when summary.md records `BLOCKED`
or `FAIL`. The block includes the first 1,500 bytes of checker output, the exact rerun command,
and the off-switch. A transcript claiming `BLOCKED` or `FAIL` is never blocked: a failing check
or missing summary produces a warning carrying checker output so honest escalation can finish.
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
decision (`allow`, `deny`, `block`, `warn`, or `skip`), and one-line reason. Fast paths do not log.
Bash payloads without both a bare `git` token and a mutation keyword return before starting Python
or Git. Records use one bounded append write. Only above 2 MiB does an exclusive trim lock permit
retaining about 1 MiB via a temporary file and atomic rename; appenders coordinate with rotation so records
are not lost to the replaced inode. Lock contention skips trimming.

Limitation: Claude Code 2.1.270's documented `SubagentStop` payload has not been measured in this
repository. `PreToolUse` subagent identity was measured; stop-event identity/transcript behavior
still needs a live-session check. Inspect the journal after a known gate claim: a missing record
may mean an unsupported payload, a hook that did not fire, or an off-switch. `systemMessage`
display on `SubagentStop` is also unconfirmed; stderr and the journal preserve warnings.

## Tuning

Edit `budget-policy.conf`. It is excluded from `orch-policy-rev`, so tuning does not invalidate
the prompt cache.

Important controls:

```text
BUDGET_WATCH_RATIO
BUDGET_TIGHT_RATIO
BUDGET_CRITICAL_RATIO
BUDGET_NEAR_RESET_MINUTES
BUDGET_PROVIDER_SWITCH_MARGIN
BUDGET_FABLE_RESERVE_PCT
CLAUDE_ROUTE_*_PROFILE
CODEX_AUTO_<MODE>_<PRESSURE>_{MODEL,EFFORT,ALLOW}
```

Use `orch-model-guard budget` after a change to verify the resulting pressure and routing before
starting a large task.
