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

The command returns an immutable agent type such as `route-lead-bravo-normal`, plus its model and
effort. `build-roster-runtime.sh` generates all 16 slot/profile combinations, and the legacy quota
guard never rewrites the `route-lead-*` namespace. Usage changes therefore choose among already
cached agent types rather than rewriting definitions.

Codex model and effort are resolved automatically on each new `codex-run` invocation:

```text
healthy   implement -> Sol xhigh
watch     implement -> Sol high
tight     implement -> Terra high
critical  implement -> withheld; Claude fallback

healthy   review -> Sol high
watch     review -> Sol medium
tight     review -> Terra high
critical  review -> Luna high (gate reserve)
```

The complete table is in `budget-policy.conf`. Explicit flags always win:

```bash
codex-run ... --model sol --effort xhigh
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

An isolated scope test confirmed that a project- or user-settings `PreToolUse` hook applies both
to top-level Bash calls and to Bash calls made by Task/Agent-spawned subagents. Subagent payloads
include `agent_id` and `agent_type`; the guard itself needs only the exact `tool_name: "Bash"`
check. Consequently, registration can protect leads spawned by the currently running
orchestrator even when their agent definitions are stale. Claude Code normally watches settings
changes, but hot reload is still a runtime behavior: if an existing session does not observe the
new registration, restart that session. Once registered, edits to the referenced script are read
on subsequent calls.

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
            "command": "bash '/mnt/c/janghun/Moaga/cc-orch/hooks/orch-poll-guard.sh' || true",
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

The detector is intentionally narrow. It denies only a real `while` or `until` loop that combines
all of: `sleep`, an `.orchestra/` or `codex-*.md`/`codex-*.jsonl` target, and a file-watch primitive
such as `[`, `test`, `grep`, `cat`, `stat`, or `find`. Quoted prose and heredoc bodies are ignored,
except that a shell `-c` payload is treated as executable code. Ordinary one-shot sleeps, direct
artifact reads, and loops over unrelated paths remain allowed. Known accepted false negatives are
`for` loops, loops split across multiple Bash calls, and polling of non-orchestra paths; prompt
guidance remains the first line of defense. The remaining false-positive risk is a legitimate
maintenance loop that happens to match all three structural signals.

If the guard causes a false positive, disable it immediately for all sessions:

```bash
mkdir -p ~/.claude/orchestra-state
touch ~/.claude/orchestra-state/poll-guard.off
```

Remove the file to re-enable the guard. To roll back permanently, remove this `PreToolUse` entry
from settings; the script can remain on disk.

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
