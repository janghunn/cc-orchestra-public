# Offline file-level triage protocol

This measures advisory-hint feasibility on one repository. It is never a gate.
The [frozen criteria](criteria.md), committed alone before real-corpus scoring,
define all scores, metrics, confidence rules and verdict thresholds. No outcome
authorises a policy or runtime change.

## Sources and recoverable population

`../gate-ab/tabulation.csv` supplies finding rows; `manifest.tsv` binds each task
to one base → round-1 gated head diff, full commit identifiers, its first later
`fix(` commit and evidence pointers. Protocol pointers beginning `eval/` are
relative to this checkout; all other pointers are relative to `GATE_AB_ROOT`.
`git-history` means a history-only candidate. The builder verifies commit
existence, base/head ancestry, fix ancestry and subject, and that no earlier
`fix(` commit lies between head and the selected fix.

Manifest statuses: P = protocol pair, G = gate/summary evidence, H = history
only, U = unrecoverable head. S24 is a clean control without a defect and is
excluded. U rows remain in the manifest for explicit exclusion accounting.
J08 has a verified gated head but no task fix commit: its summary records a
recipe-only correction with no code change. Its fix is `-`, so only citation
evidence can map it, at low confidence. Do not substitute a later unrelated
repository fix. C15 is U; its pointer records the investigation's candidate
pair, not a recovered round-1 working tree.

Each row receives the first applicable exclusion: `design-stage`, `rejected`,
`task-not-in-manifest`, `head-not-recoverable`, or
`not-first-reported-at-head` (later-round or post-merge, or `first_round` differing
from the manifest's `head_round`). Accepted findings remain eligible.

## File mapping

Let F be the head-side paths in `git diff --name-only -M base head`.

E1 extracts repository paths only within each source's cited line bounds:
`path:N` is one line and `path:N-M` is inclusive. Source files resolve literally
under `GATE_AB_ROOT`; no prefix remapping occurs. Use the exact path regex in
criteria.md, remove a trailing line number, and intersect with F. Missing files
supply no evidence. Report the number of distinct missing files encountered in
eligible rows. Unbounded citations feed E1-unbounded, never E1.

E2 inspects the selected head → fix diff. Files in F with removed content are
E2-strong; pure additions are E2-weak. Binary changes with no textual evidence
and pure renames with no content changes supply neither. If the fix renames a
file, map its old path back to the evaluated head.

Use the first matching rule:

1. E1 ∩ (E2-strong ∪ E2-weak): that intersection, high confidence.
2. E2-strong: those files, medium confidence.
3. E1: those files, low confidence.
4. E2-weak ∪ E1-unbounded: those files, low confidence.
5. No files: exclude as `no-in-diff-file-evidence`.

H caps every mapped row at low confidence. All sets are restricted to F.
Bundled fixes are row-imprecise; their file union is the diff-level evidence.

Primary ranking uses F' = F minus test paths (criteria.md's first S2 class
rule); labels D are the high/medium union intersected with F'. High-only uses
the high union and F'. Sensitivity uses all mapped confidence levels and F,
including tests. Each stratum is usable only when N ≥ 3 and 1 ≤ |D| < N.
Scorers still see tests for coverage features; restriction preserves order.
The verdict uses primary only. High-only, sensitivity and J/C/S series are
descriptive; groups smaller than ten print `INSUFFICIENT DATA`.

## Scorer isolation and egress

Scorers accept only canonical `diff-triage-input/1` JSON bytes: sorted head-diff
file paths, rename/status information, line counts and patches. No task IDs,
commit identifiers, finding text, sources, fix commits, labels or later history
are supplied to scorers. The runner reads only the provenance header up front
to locate the corpus files for fingerprinting. It builds and scores every input
before reading any label records. S0 averages 1000 deterministic permutations; S1 and S2 are
frozen deterministic scorers. S3 is a candidate only after a complete real run.

There is **no network contact of any kind**; the only permitted socket is the
AF_UNIX client to a task-started local llama-server; no TypeSafe or other
external API. The real run is executed under `unshare -rn`.

S3 requires the policy's existing GGUF, an existing server executable, a GPU
with at least 12288 MiB free, and an unused task-private socket. Policy is parsed
as data. A private copy overrides both the GPU and socket, and is passed through
`CC_ORCH_JEV_POLICY`. The existing foreground launcher verifies the model digest
and runs offline. Startup waits at most 120 seconds; cleanup terminates and
reaps only the owned PID (TERM, 30-second wait, then KILL if needed). No process
name matching is used. Missing resources or failed scoring yield
`S3 skipped: <reason>` and exclude the entire S3 arm. Tests use fake transport
and a sleeping process; they do not establish real local-model accuracy.

## Private outputs and read-only guarantees

Dependencies are Python 3's standard library and git. Scripts disable bytecode
before local imports. With optional locks disabled, history reads use one cached
shared bare clone per source repository in a guarded temporary directory, isolated
from external attributes and removed at process exit. Fingerprints inspect the real
repository; evaluation never edits its corpus, HEAD, refs or worktree.
Before/after fingerprints include corpus hashes, HEAD, refs, and status including
untracked and ignored paths. A changed fingerprint exits 3 before writing a note.
The builder reports corpus hashes; the runner reports full fingerprints, elapsed
time and SELF/CHILDREN peak RSS in KiB.

Every private output is guarded by the existing `jev-phase0/common.py`
`assert_out_of_tree`, including registered sibling worktrees and symlinks.
Directories are created with mode 0700; files are written at mode 0600 through
exclusive, no-follow temporary files and atomic replacement. Existing output-file
symlinks are refused. Private outputs and temporary S3 policy/socket state stay
outside every worktree. No corpus finding text is copied into tracked artifacts.

`labels.jsonl` contains per-row decisions, reasons, confidence, files and methods.
`diffs.jsonl` contains per-diff universes, labels and usability. Both start with
provenance binding the manifest and tabulation hashes, mapping version, repo HEAD,
source root and tabulation location. The runner recomputes hashes and refuses
missing or stale provenance. `results.jsonl` contains per-diff arm orders and
stratum metrics; S0 also includes all 1000 orders, with its first order in `order`
and metrics averaged over all orders.

Only explicit `--note` writes may enter `eval/diff-triage/evidence/*.md`.
Notes contain aggregate counts/metrics, fingerprints and criteria commit only.
Command path arguments are elided to keep source locations out of tracked notes;
README.md documents the executable invocation. Compare fingerprints before the
intentional note write. Neither script writes notes by default.

## Limitations

C-series source reports are missing at their literal corpus-root locations.
History-only heads are capped low. Later-round presence is unproven and excluded.
Pure-addition fixes supply weak evidence unless corroborated by bounded citations.
Citation context can mention non-defective files, and a bundled fix can touch
several findings. Tests are excluded from the primary universe because added
regression coverage does not make them defective. The corpus is from one
repository, so this is not an accuracy claim for other repositories or a basis
for changing gates or review policy.
