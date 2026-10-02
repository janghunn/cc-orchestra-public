# Offline tool-result retention replay

Replay saved Claude Code transcripts to measure which later-needed identifiers
survive keep/truncate/drop policies. This is an offline evaluation, with no live
hook or runtime changes. Read the [protocol](protocol.md) and
[frozen criteria](criteria.md) before interpreting results.

From the repository root:

```bash
bash tests/test-compaction-replay.sh

# Synthetic demonstration only; P3 fake is never a verdict arm.
python3 eval/compaction-replay/replay.py \
  --projects eval/compaction-replay/fixtures/projects \
  --out /tmp/compaction-replay-demo --p3 fake

# Lead only, AFTER the separate criteria commit; private source corpus.
python3 eval/compaction-replay/replay.py --p3 local \
  --criteria-commit "$CRITERIA_COMMIT" \
  --note eval/compaction-replay/evidence/real-run.md
```

Before any real-corpus policy scoring, the lead commits **only** `criteria.md`
in a separate commit, records its full SHA as `CRITERIA_COMMIT`, and verifies it
is an ancestor of the evaluated checkout. Never adjust its thresholds after
seeing results. A fixture run without `--criteria-commit` prints `UNCOMMITTED`;
that is not acceptable real-run evidence.

Discovery defaults to `${CC_ORCH_CLAUDE_PROJECTS:-$HOME/.claude/projects}`.
Outputs default to
`${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/compaction-replay/`:
`aggregate.json`, `per-file.jsonl`, `run-meta.json`, and an optional `p3-cache/`.
Every private output is guarded against all Git worktrees, including symlink
aliases and sibling worktrees. `--out` selects another external directory.
Only an explicitly requested aggregate Markdown `--note` may be in a worktree.

No output includes transcript text or extracted tokens. Per-file identities are
hashed real paths; the tracked evidence is aggregates only. Source files are
opened read-only and a deterministic old-file sample is hashed before and after.
The note records command flags with path placeholders; supply the recorded seed,
bootstrap count, criteria commit and the same input snapshot to reproduce it.

P3 uses only an already-installed pinned GGUF and `llama-server`, and requires a
GPU with at least 12288 MiB free. Missing prerequisites produce `P3 skipped:
<reason>` while P0–P2 continue. Local scoring waits for HTTP 200 from `/health`
over the private AF_UNIX socket. Any scorer error sets P3 status to `errors`;
its metrics remain available, but it is excluded from the verdict. The suite
always reports that the real GPU/model path is untested; an AF_UNIX bind denial
is delegated explicitly to normal verification. No downloads, DNS or network
connections are used.
