# Offline compaction replay protocol

This evaluation measures observed later reuse, not task completion or latent
importance. A pass never authorises a live hook. The exact mechanical verdict is
defined by [criteria.md](criteria.md), frozen in a separate lead-owned commit
before real-corpus scoring. Only aggregate census counts were inspected before
freezing; no policy had been scored. There is no summary arm.

## Corpus, discovery and read-only snapshots

Read `${CC_ORCH_CLAUDE_PROJECTS:-$HOME/.claude/projects}` (or `--projects`) using
`*/*.jsonl` for main sessions and `*/*/subagents/*.jsonl` for subagents. Skip
symlinked files and directories. Each physical file is its own context and replay
unit, including each subagent file. A light streaming pass obtains the earliest
timestamp. Process files in `(earliest timestamp, path)` order. Snapshot each
file's size at discovery; both passes read at most that many bytes in binary
read-only mode, ignoring an incomplete trailing line. Parse errors are counted,
without printing source text. `--limit-files` takes the first N discovered files.

Hold only the current file's events in memory. Only the set of previously seen
user/assistant UUID strings crosses files during normalization; aggregate
numeric per-file statistics are retained for whole-file bootstrap resampling.
Before running, deterministically sample up to 20 files whose discovery mtime is
at least 600 seconds older than run start, using the requested seed. Hash these
sources before and after; record only hashed file identities, digests and counts
in `run-meta.json`. A changed sampled file makes the CLI exit 2. A sample with
zero eligible files is reported as 0/0, never as proof of immutability.

## Normalization and deduplication

Replay physical append order. Parent-UUID leaf traversal loses parallel tool
results: the census found 1,650 parallel-tool forks out of 1,665 fork parents;
leaf traversal dropped 12% of main and 2% of subagent user/assistant records.

Record identity is `uuid`; block identity is `(uuid, position in that line)`.
Keep the first record with a UUID within a file. Count subsequent occurrences as
`dup_records_in_file`, and count content differences as `dup_conflicts`. The
census found 45 within-file UUID repeats. `message.id` is not a deduplication key:
23,660 IDs repeat across legitimate split blocks. It only groups assistant
blocks into a message for tail pinning. Missing `apiBlockIndex` is immaterial.
`tool_use_id` links a result to an earlier call within the file; it is not an
identity key (15 conflicting cross-file result contents were observed).

Skip a file when all its user/assistant UUIDs were seen in earlier files, counting
`files_skipped_copy`. A file with unidentified user/assistant records cannot be
classified as fully copied. The census found one fully copied main file (2,280
records). Replay partially copied files in full, including copied consumers;
count copied UUID-bearing records as `copied_records`. The census found 21 such
records in two subagent files. This small known overlap is included in scores;
excluding it could hide a loss. Full-copy records do not inflate this partial
overlap count.

Exclude user records marked `isMeta`, `isCompactSummary`, or
`isVisibleInTranscriptOnly` entirely, including as later uses. Ignore thinking,
attachments, other system records and bookkeeping. This omits possible retained
information and is conservative for the needed-token count. Real compaction is
`type=system, subtype=compact_boundary`, with `compactMetadata`, usually a null
`parentUuid` and a `logicalParentUuid`. The census found 13 occurrences, 12
distinct UUIDs, in 10 files (8 main, 2 subagent), and 13 summary records. Summary
parents need not be the boundary (an attachment can intervene).

Normalized event kinds are:

- `result`: each user `tool_result` block, with tool ID, joined tool name (`?` if
  missing), paired input text, error flag, text, nontext count and copied flag.
- `assistant_text`: each assistant text block.
- `tool_input`: each assistant tool-use block. Recursively concatenate string
  leaf values of input, with sorted dictionary keys, list order preserved and
  `\n` separators; include neither keys nor a prefix. Record the tool name.
- `user_text`: user string content or each user text block.
- `boundary`: a real compact-boundary position, with no text.

Assistant `msg_key`s use `message.id` (record identity fallback if absent); user
keys use their UUID. Role namespaces prevent accidental cross-role collisions.
Results whose content is a string use that string. List content joins only
`type=text` strings with `\n`; image, document and tool-reference payloads are
excluded and counted in `nontext_result_blocks`. All byte measurements are
UTF-8 bytes of this normalized text, not serialized JSON or image bytes.

## Identifier extraction

Classes are `agentid`, `path`, `sha`, `error`. Agent, SHA and path tokens are
case-sensitive sets per event, extracted identically from results, assistant
text, tool inputs and user text. Compiled regexes live in `identifiers.py`.

- Token boundaries: an agentId or SHA must not be preceded or followed by
  `[0-9A-Za-z_-]`; UUID segments and prefixes of longer hashes are excluded.
- `agentid`: `a[0-9a-f]{16}` with those boundaries.
- `sha`: `[0-9a-f]{7,40}` with those boundaries, containing at least one digit
  and one letter `a-f`, and not an agentId match. Hex-looking words remain a
  possible false positive; this limitation affects all policies equally.
- `path`: absolute `/` followed by at least two components (`/seg/seg[/...]`),
  or relative `seg(/seg)+`, where segment characters are
  `[A-Za-z0-9._@%+~-]`. A relative path qualifies if its last segment has an
  extension (`.` followed by 1–8 alphanumeric characters), it has at least two
  slashes, or its last segment contains `-`, `_` or a digit. Thus
  `bin/codex-run-runtime` and `tests/test-jev.sh` count, but `and/or`, `w/o` and
  plain-letter `src/foo` do not. This narrower scope is intentional. Do not
  start a match preceded by `[A-Za-z0-9._~-]` or `:` + `/`; never match inside a
  `scheme://...` URL. Prevent restarting inside another path. Strip trailing
  `.,:;)]}'"` characters and require at least four characters.
- `error`: candidate result lines are split on `\n` and stripped, with
  `12 <= len <= 300` and the regex
  `(?i)\b(error|exception|traceback|fatal|failed|failure|panic|denied|refused|not found|no such file)\b`.
  An exact candidate line occurs in any other event when it is a case-sensitive
  substring of the event text; retained result text uses the same substring rule.

## Cuts, epochs and later-needed tokens

For T result events, T >= 8 produces synthetic cuts immediately after result
ordinals `floor(q*T)`, using 1-based ordinals and q = 0.25, 0.50, 0.75; deduplicate
equal synthetic ordinals. Every boundary contributes a separate `real` cut at
its event index, even if a synthetic cut shares that index. Index c splits
events into `[0,c)` and `[c,end)`.

The pre-cut context starts immediately after the last earlier real boundary,
or at file start. A real cut at b evaluates the epoch ending at b; it does not
use the new epoch. Events from older epochs are neither policy subjects nor
retained content. Ignore preserved-message metadata, a conservative omission.
Post-cut uses may occur anywhere in the rest of the file.

Candidates originate in pre-cut results within the epoch. For each class,
classify each candidate token once per file/cut into four total statuses:

1. `rederivable`: its first occurrence in the epoch is not a result, or it
   occurs in any pre-cut assistant text, tool input or user text. Those contents
   are always retained by every policy.
2. `resurfaced`: otherwise its first post-cut occurrence is another result.
3. `not_used`: otherwise it has no post-cut occurrence.
4. `needed`: otherwise its first post-cut occurrence is assistant text, tool
   input or user text, and its first epoch occurrence was a pre-cut result.

There are four statuses: `needed` and the three non-needed outcomes above; all four are reported.
Error matching stops once re-derivability or the first
post-cut occurrence determines its classification. Token sets are
policy-independent. A needed token is retained only if extraction finds it in
some retained pre-cut result text (substring match for an exact error line).

## Policies

Outcomes are `keep` (all text), `truncate` (first 300 Python characters, then
measure UTF-8 bytes), and `drop` (empty text). All P1–P3 policies keep results
whose message key appears among the last six distinct message keys before the
cut, inside the current epoch. All policy decisions use only that epoch's
pre-cut events; post-cut changes cannot change decisions.

- **P0:** keep everything, with zero bytes removed and recall 1.0 wherever
  needed > 0; executable assertions enforce this reference invariant.
- **P1:** keep the last ten pre-cut results plus pinned results; drop the rest.
- **P2:** for each non-pinned result, use the first matching rule:
  1. tool in `Agent`, `Task`, `SendMessage`, `ListAgents`, `TaskOutput`: keep;
  2. paired input contains `REGISTRY`: keep;
  3. result contains an agentId token: keep;
  4. the next non-result event after it **and before c** is user text: keep;
  5. error flag is true or at least one error candidate line exists: keep;
  6. result UTF-8 bytes <= 2048: keep;
  7. `(distinct paths + distinct SHAs) * 1024 / bytes >= 4`: keep;
  8. tool in `Read`, `WebFetch`, `WebSearch`, `Glob`, `Grep`, `ToolSearch`: drop;
  9. otherwise truncate.
- **P3:** before any scorer receives text, use the existing Jev `scan_record`
  on the tool name, paired input and result independently. Any secret-shaped
  field keeps the result without a call and increments `p3_secret_skips`. Ask
  `scorer(name,input,result) -> (keep_call,keep_verbatim)`. Verbatim means keep;
  otherwise call means truncate; otherwise drop. Exceptions keep the result
  and increment `p3_errors`, without logging exception or prompt text.

The deterministic fake scorer keeps verbatim iff the first hex character of
SHA-256(result text) is in `0123`, and keeps the call iff SHA-256(input text)
starts in `01234567`. `--p3 fake` is labelled **DEMONSTRATION** and excluded from
verdict arms. P0 is always a reference, never a verdict arm. Only a successfully
started `--p3 local` may enter the verdict as P3. P3 failure/skip is not a score.

## Local P3 preflight, lifecycle and caching

Default model is
`${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/models/Qwen3-8B-Q8_0.gguf`;
default server is `llama-server`. `--p3-model` and `--p3-server` override them.
Preflight returns the first failure in this order:

1. `model file missing`;
2. `model sha256 mismatch` against
   `408b955510e196121c1c375201744783b5c9a43c7956d73fc78df54c66e883d6`
   (hash only an existing file);
3. `server binary not found`, using `shutil.which`;
4. `nvidia-smi failed` for a failed/malformed
   `nvidia-smi --query-gpu=index,memory.free --format=csv,noheader,nounits`, or
   `no GPU with >= 12288 MiB free`.

Print exactly `P3 skipped: <reason>` and continue P0–P2. Never download weights or
install a server. Select the first suitable GPU and expose just that index via
`CUDA_VISIBLE_DEVICES`. Remove `LLAMA_ARG_*` and `TYPESAFE_API_KEY` from the child
environment. Create a private 0700 socket directory inside the guarded output
directory. Launch with its cwd there, `--host <socket name>`, `--offline`,
`-ngl 999`, `--jinja`, `--reasoning-budget 0`, `--no-webui`, `--no-slots`,
`-c 8192`, `-np 1`; suppress server output. Wait for AF_UNIX readiness with a
deadline. A startup failure records `P3 skipped: local server startup failed`.

Always terminate only this run's Popen PID, wait up to ten seconds, then kill
that PID if necessary. The startup path has a `finally` cleanup covering timeout,
exceptions and KeyboardInterrupt, as does normal context-manager exit. Remove
the socket and its directory. Never kill by name or process pattern.

The AF_UNIX HTTP client is copied from `bin/orch-jev-local`, with TCP reconnect
disabled. Ask two A/B questions (A = yes), with `max_tokens=1`, `temperature=0`,
`logprobs=true`, `top_logprobs=20`, and
`chat_template_kwargs.enable_thinking=false`. Normalize A/B top-logprob mass;
A probability >= 0.5 is true. Malformed responses raise a conservative scorer
error. The prompt treats supplied tool text as data, not instructions.
Local prompts include only the first 2000 characters of input text
(`PROMPT_INPUT_CHARS`) and the first 6000 characters of result text
(`PROMPT_RESULT_CHARS`) to limit context use. Secret screening in
`policies.decide` still examines the full tool name, input and result texts.

Cache booleans only under `<out>/p3-cache/<sha256>.json`. The key covers the exact
screened request prompts and pinned model digest; screening precedes every cache
lookup. No raw prompt or response text is written to the cache.

## Metrics and verdict

Pool instances over file/cut units. Report needed, retained, recall (undefined
and rendered `n/a` for needed = 0), the three non-needed counts, lost agentIds,
pre-cut result bytes, removed bytes and removed share. Truncation removes bytes
after the first 300 characters, not after byte 300. Report P3 error/secret-skip
counts as result decisions over cuts. File counts count a file once per cell
when it has at least one evaluated cut.

Report pooled and separate strata for file kind (`main`, `subagent`), cut kind
(`synthetic`, `real`), and whole-file result-count bucket (`8-49`, `50-199`,
`>=200`, `<8` real-only). Compute 95% percentile bootstrap intervals for recall
and removed share, resampling whole contributing files with replacement within
each cell, seed 20261002, B=2000, with linear-interpolated quantiles. Undefined
replicate ratios are omitted; all-undefined intervals are `n/a`. The CLI seed and
B are overridable and recorded in metadata. Intervals are descriptive only.

The pure verdict function applies the frozen criteria in order: any needed
agentId lost disqualifies, even with insufficient data; otherwise a failed
threshold in a sufficiently sampled cell disqualifies; otherwise any required
insufficient cell gives `inconclusive`; otherwise `proceed to design discussion`.
Recall cells require both the specified file count and token count. The pooled
byte-share threshold requires the pooled file count and a nonzero byte total.
The overall verdict proceeds if any eligible arm proceeds, otherwise is
inconclusive if any arm is inconclusive, otherwise is `do not pursue`.

## Privacy, determinism and egress

Nothing in this evaluation may open a network connection. The only socket permitted is an AF_UNIX stream socket to a llama-server this run started itself.

Only `local_scorer.py` imports socket or HTTP client support; there are no
network-service clients. Tests guard TCP and DNS for their entire Python run,
use invented AF_UNIX servers, and statically check all evaluation imports.
AF_UNIX bind denial is printed explicitly and delegated to normal verification.
The real-model path always has an explicit suite skip, not a simulated pass.

Never print or write transcript text, extracted identifiers or exception text.
Per-file outputs use `sha256(realpath)[:16]`. Guard every private output path,
directory, cache entry and socket with Jev's `assert_out_of_tree` before creation.
It checks the current checkout, sibling worktrees and destination repositories
after resolving symlinks. Load Jev helpers by file path under unique names
`jev_common` and `jev_secrets`, avoiding the stdlib `secrets` collision.

`aggregate.json` has no path text, timestamp, PID, hostname or runtime data;
sort serialized keys and use seeded `random.Random` instances. Changing only
the seed can change only aggregate bootstrap fields. `per-file.jsonl` contains
hashed identities and numeric aggregates. `run-meta.json` holds runtime, start
time, peak RSS from `resource.getrusage`, seed, B, criteria commit, command flags
with private paths replaced by placeholders, and source-hash evidence. Script
entry modules set `sys.dont_write_bytecode = True` before other imports. Compile
verification redirects bytecode to temporary storage.

An explicit `--note PATH` is the only in-tree output exception: write an
aggregate-only Markdown report, including required evidence line prefixes,
strata, bootstrap intervals, verdict table, runtime, RSS and hash-check counts.
The renderer receives aggregates and run metadata only, never events or tokens.
The lead owns `evidence/real-run.md`; implementation-lane tests do not read real
transcripts or generate real-run evidence.
