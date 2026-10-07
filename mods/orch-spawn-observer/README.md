# Spawn observer mod

An observe-only prototype for cc-orchestra. It records each spawned agent's model and
step effort against the current generated profile, with a `match`, `mismatch`, `unmanaged`,
or `unknown` verdict. It never denies, rewrites, or blocks a spawn on policy grounds: every
hook forwards the original event once and preserves the engine's result, stream, and errors.
Observer failures are swallowed. No processes are launched and no prompts or output are logged.

## Events and comparison

- `agent.spawn` starts a fresh read of `<config>/agents/<agent_type>.md` without delaying
  the underlying spawn. `<config>` is `CLAUDE_CONFIG_DIR`, or `$HOME/.claude`. Top-level
  frontmatter `model` and `effort` are the comparison source; this mod never runs a router.
- `turn.step` joins the first step by `agentId`. Spawn has no effort field. The answering
  model is the result's `usage.model`, falling back to the step input model, then the spawn
  result model. Effort is the step input as it reached this hook, **not** a confirmed
  post-execution value. `step_effort` is the effort the request names when it reaches this
  hook; whether the engine adjusts it later is not observed. A later mod can also rewrite
  effort without this record seeing it. cc-orchestra installs no other mods.
- `session.start` caches the host version. Versions below 2.1.287 or an unavailable
  `agent.spawn` disable observation with one debug log line. Unparseable versions remain
  observable. If only `turn.step` is unavailable, effort stays unobserved.
- `session.end` flushes remaining spawns with effort unobserved. Pending and early-step
  buffers each hold at most 64 entries; pending overflow flushes the oldest spawn. A bounded
  set remembers the last 256 recorded agent IDs to ignore later steps. Main-loop steps do
  no I/O. If an early step is still streaming when the spawn returns, its hook takes over
  recording after the stream ends; the spawn hook does not wait for that stream.

Model aliases compare by family (`fable`, `opus`, `sonnet`, `haiku`); other models compare
case-insensitively after removing a trailing context suffix such as `[1m]`. `inherit` resolves
against the parent model. Effort compares exactly after lowercasing and trimming. Names outside
`[A-Za-z0-9_-]{1,64}` (including plugin agent names with `:`) are unmanaged and never read as paths.

## Records and verdicts

The JSONL file is `$CC_ORCH_STATE_DIR/spawn-observer.jsonl`, defaulting to
`$HOME/.claude/orchestra-state/spawn-observer.jsonl`. With neither variable set, nothing is written.
Every string is limited to 200 characters. Records contain only:

| Fields | Meaning |
| --- | --- |
| `ts`, `observer`, `host_version` | ISO observation time, `orch-spawn-observer@0.1.0`, host version if available |
| `session_id`, `agent_id`, `agent_type`, `fork`, `teammate` | Spawn identifiers and flags; teammate is null when the host omits it |
| `parent_model`, `requested_model`, `requested_effort` | Parent and requested model; requested effort is always null (no spawn parameter) |
| `effective_model`, `step_model`, `answered_model` | Best available model, step input model, and result `usage.model` |
| `step_effort`, `effort_source`, `effort_observed` | First-step input effort, `turn.step-input` or null, and whether a step was observed |
| `expected_model`, `expected_effort`, `profile` | Profile expectation and `found`, `missing`, `unmanaged-name`, `malformed`, or `unreadable` |
| `verdict`, `reasons` | Comparison and its reasons |
| `source`, `denied` | `agent.spawn+turn.step`, `agent.spawn`, `session.end`, or `pending-overflow`; whether an earlier handler/core denied the spawn |

`match` means all pinned values agree. `mismatch` means at least one differs, even if another
value is unknown. `unmanaged` means the agent name/file is unmanaged or the profile pins
nothing. `unknown` means a profile could not be parsed/read or a pinned value was not observed.
No prompt, description, cwd, name, tool-use ID, deny text, environment value, or agent output
is copied to the record. A missing effort remains unknown instead of guessing its default.

## Requirements and runtime limits

Requires Claude Code >= 2.1.287. The reference was checked against types from 2.1.287 and
CLI 2.1.292; the lead's CLI probes used stubbed events. Node tests exercise this implementation
without the host. `claude plugin validate/test` for this plugin is a separate verifier check.

**Not verified at runtime:** no live session has loaded this mod to establish whether the spawn
result resolves aliases to full model IDs, whether a real subagent's first step carries the
same agent ID as its spawn result, or whether the step's effort comes from its agent profile.
Other Claude Code builds have not been checked. Result usage identifies the answering model
according to the types; effort has no authoritative result field and later mods may change it.
Teammates and forks are recorded and compared like any other agent type; their live behavior
has not been separately verified.

The file API has no append or atomic write. Writes in one module instance are serialized;
two Claude Code processes writing at the same instant can lose a line, and readers can see a
partial write. A failed existence check or read skips the write, preserving earlier records.
Write failures produce at most one debug log line per session. Above 1 MiB, only the newest
whole lines totalling at most 512 KiB are kept. Hot reload drops pending spawns and early steps;
an interrupted session can also lose pending observations.

## Manual loading and checking

`install.sh` does not install this prototype, and cc-orchestra sets neither loading mechanism.
For one session, substitute the absolute repository path:

```bash
claude --plugin-dir /absolute/path/to/cc-orchestra/mods/orch-spawn-observer
```

Alternatively include that absolute plugin path in `CLAUDE_CODE_PLUGIN_DIRS` (paths separated
by `:` on Unix). These are the two mechanisms documented in the
[mods reference](https://code.claude.com/docs/en/plugins/mods/reference.md).
When loaded, `/plugin` shows `1 mod active · orch-spawn-observer`.
Checking the files and stubbed runtime does not require enabling a live session:

```bash
claude plugin validate mods/orch-spawn-observer
claude plugin test mods/orch-spawn-observer
bash tests/test-mods-observer.sh
# Optional combined node and CLI checks:
MODS_OBSERVER_CLAUDE=1 bash tests/test-mods-observer.sh
```

Read mismatches with ordinary tools (substitute `CC_ORCH_STATE_DIR` if set):

```bash
jq -c 'select(.verdict=="mismatch")' ~/.claude/orchestra-state/spawn-observer.jsonl
```

## Removal

Stop passing `--plugin-dir`, or remove the plugin path from `CLAUDE_CODE_PLUGIN_DIRS`, and
start a new session. Optionally delete `spawn-observer.jsonl` from the selected state directory.
