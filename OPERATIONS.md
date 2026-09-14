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
A known lead with an unresolved slot may use the `.orchestra/wt/<slot>` checkout suffix.
Unknown actors, including ordinary orchestrator calls, bypass evaluation.

The guard classifies `commit`, `merge`, `rebase`, `cherry-pick`, `revert`, `reset`, `am`, `apply`,
`add`, `rm`, `mv`, `stash`, and `restore` as index writes; `checkout`, `switch`, `branch` with
`-f/-D/-m/-M`, and `tag` with `-f/-d` as ref moves; and `push` separately. It denies only:

- **R1:** a lead/dev index write or bare/protected-ref push from `main`, `master`, `develop`, or
  `trunk`. An explicit non-protected push refspec is allowed by R1, as is switching away from a
  base branch to create a task branch.
- **R2:** a known lead mutating a checkout on another active lead's registered branch.
- **R3:** a known lead mutating another active slot's `.orchestra/wt/<slot>` checkout.
- **R4:** a known lead mutating the registry-owning shared checkout while at least two lead rows
  are active. The denial names other slots and suggests
  `git worktree add <repo>/.orchestra/wt/<slot> -b <your branch>`.

The registry `dir` is an artifact directory, resolved against the repository root, not ownership
of a checkout. Branch ownership uses the checkout HEAD and registry branch; Git worktree metadata
also locates the shared registry from linked checkouts. Each invocation has its own target:
`cd`/`pushd` and `git -C` are tracked through command chains. Quoted prose, comments, and heredoc
bodies are inert. Unknown targets such as `cd -`, unexpanded variables, or explicit
`--git-dir`/`--work-tree` overrides fail open. Read-only/unclassified commands and missing or
malformed registries do not block. Complex shell evaluation is not a complete shell interpreter.

`hooks/orch-stop-gate.sh` is registered on **SubagentStop**, with matcher `(route-)?lead-.*`;
`Stop` is for the main session. It checks the last assistant transcript message only when it
contains a `STATUS: PASS`, `FAIL`, or `BLOCKED` line (optionally prefixed with a lead label) and a
`GATES:` line. Ordinary mid-task messages do not run a checker. `stop_hook_active: true` bypasses
the gate to prevent a stop loop. The registry row selected by agent ID, then slot, supplies the
task directory even if `ARTIFACTS:` names another task. Only without a registry task does an
existing `ARTIFACTS:` directory containing `brief.md` qualify as a fallback.

The checker is resolved through `CC_ORCH_SUMMARY_CHECK` (an executable path for operators/tests),
then the hook's own repository `bin/orch-summary-check`, `$HOME/.local/bin/orch-summary-check`,
then `PATH`. It runs with `--strict <task-dir>`: exit 0 allows silently; exit 1 blocks with the
first 1,500 bytes of checker output, the exact rerun command, and the off-switch. An unresolved
task/checker, exit 2, or execution failure allows with a `systemMessage` warning, the same warning
on stderr, and a journal record. An absent/unreadable transcript has no observable claim and
allows silently. A fallback directory's `brief.md` check is structural validation, not proof
that the task belongs to the reporting lead.

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
Records use one bounded append write. Only above 2 MiB does an exclusive trim lock permit retaining
about 1 MiB via a temporary file and atomic rename; appenders coordinate with rotation so records
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
