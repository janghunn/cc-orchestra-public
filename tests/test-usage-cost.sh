#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT/bin/orch-usage-report"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CC_ORCH_CLI_AUTO_UPDATE=0
export CC_ORCH_CLAUDE_PROJECTS="$TMP/claude"
export CC_ORCH_CODEX_LOG="$TMP/codex.log"
export CC_ORCH_PRICING_POLICY="$ROOT/pricing-policy.conf"
LABEL='estimate at published API rates, not an account debit'
QUOTA='Codex calls here are billed against ChatGPT-plan quota, not per token: these dollar figures are a relative-load proxy only.'
BASE="$(date +%s -d '-4 hours')"

pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "missing '$2' ($3)"; }
assert_not_has() { [[ "$1" != *"$2"* ]] || fail "unexpected '$2' ($3)"; }
stamp() { date -Is -d "@$((BASE + $1))"; }
call() {
  printf '%s  %-11s  %s  exit=%s  %s\n' "$(stamp "$1")" "$2" "$3" "${5:-0}" "$4" >> "$CC_ORCH_CODEX_LOG"
}
event() {
  mkdir -p "$(dirname "$1")"
  printf '{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s,"reasoning_output_tokens":70,"cache_write_input_tokens":0}}\n' "$3" "$4" "$5" > "$1"
  touch -d "$(stamp "$2")" "$1"
}
run() {
  RUN_STATUS=0
  "$REPORT" "$@" > "$TMP/stdout" 2> "$TMP/stderr" || RUN_STATUS=$?
  RUN_OUTPUT="$(cat "$TMP/stdout")"
  RUN_ERROR="$(cat "$TMP/stderr")"
}
assert_success() { assert_eq "$RUN_STATUS" 0 "$1"; }
assert_row() { assert_has "$RUN_OUTPUT" "$1"$'\t'"$LABEL" 'complete model row'; }
fixture() {
  REPO="$TMP/$1"
  CC_ORCH_CODEX_LOG="$TMP/$1.log"
  CC_ORCH_PRICING_POLICY="$ROOT/pricing-policy.conf"
  mkdir -p "$REPO"
  : > "$CC_ORCH_CODEX_LOG"
}

# A: exact costs, incomplete coverage, a worktree root, and non-empty Claude output.
fixture repo
MAIN_REPO="$REPO"
MAIN_LOG="$CC_ORCH_CODEX_LOG"
call 0 implement gpt-6-astra@xhigh "$REPO" 1
call 60 implement gpt-6-astra@xhigh+fast-mode "$REPO"
call 180 review gpt-6.1-sol@high "$REPO"
call 300 verify gpt-6-luna@medium "$REPO"
call 420 investigate gpt-5.6-sol@high "$REPO/.orchestra/wt/lead-x"
event "$REPO/.orchestra/01-a/codex-implement.jsonl" 120 1000000 400000 100000
event "$REPO/.orchestra/01-a/codex-review.jsonl" 240 2000000 1500000 200000
event "$REPO/.orchestra/02-b/codex-verify.jsonl" 360 1000000 500000 1000000
event "$REPO/.orchestra/03-c/codex-investigate.jsonl" 480 1000 200 100
mkdir -p "$CC_ORCH_CLAUDE_PROJECTS/project/session/subagents"
cat > "$CC_ORCH_CLAUDE_PROJECTS/project/session.jsonl" <<'EOF'
{"type":"assistant","requestId":"a","effort":"high","message":{"model":"claude-sonnet","usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":10}}}
{"type":"assistant","requestId":"a","effort":"high","message":{"model":"claude-sonnet","usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30}}}
EOF
cat > "$CC_ORCH_CLAUDE_PROJECTS/project/session/subagents/agent-alpha.jsonl" <<'EOF'
{"type":"assistant","requestId":"b","message":{"model":"claude-opus","usage":{"input_tokens":200,"output_tokens":80}}}
EOF
printf '%s\n' '{"agentType":"lead-alpha"}' > "$CC_ORCH_CLAUDE_PROJECTS/project/session/subagents/agent-alpha.meta.json"
run --cost
assert_success main
MAIN_OUTPUT="$RUN_OUTPUT"
assert_row $'gpt-6-astra\t1\t1\t600000\t400000\t100000\t11.4000\t11.4000'
assert_row $'gpt-6.1-sol\t1\t0\t500000\t1500000\t200000\t3.1500\t16.5000'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_row $'gpt-5.6-sol\t1\t0\t800\t200\t100\trate-unknown\t0.0132'
assert_has "$RUN_OUTPUT" "observed: \$15.1050 ($LABEL)" observed
assert_has "$RUN_OUTPUT" "all-gpt-6-astra counterfactual: \$83.4000 ($LABEL)" counterfactual
assert_has "$RUN_OUTPUT" "difference (counterfactual - observed): \$68.2950 ($LABEL)" difference
assert_has "$RUN_OUTPUT" 'coverage: 3/5 calls priced (60.0%)' coverage
assert_has "$RUN_OUTPUT" $'unpriced\t1\t-\t-\t-\t-\t-\t-\t-' 'unpriced row'
assert_has "$RUN_OUTPUT" 'unpriced: 1 call(s) without surviving token data (gpt-6-astra 1)' unpriced
assert_has "$RUN_OUTPUT" 'rate unknown: 1 call(s) with tokens but no valid rate (gpt-5.6-sol 1)' unknown
assert_has "$RUN_OUTPUT" 'fast-mode: 1 priced call(s) ran in Fast mode' fast
assert_has "$RUN_OUTPUT" 'fast-mode observed: Standard-rate estimate, Fast multiplier unknown (gpt-6-astra)' 'observed fast'
assert_has "$RUN_OUTPUT" 'fast-mode counterfactual: Standard-rate estimate, Fast multiplier unknown (gpt-6-astra)' 'counterfactual fast'
assert_has "$RUN_OUTPUT" $'opus\tlead-alpha' 'Claude detail populated'
assert_eq "$(grep -Fc "$QUOTA" "$TMP/stdout")" 1 'quota caveat once'
assert_eq "$(grep -c 'rate unknown for gpt-5.6-sol' "$TMP/stderr")" 1 'one unknown-rate warning'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'note: long-context surcharges are not applied (per-request prompt sizes are not recorded)' 'last note'
python3 - "$TMP/stdout" "$LABEL" <<'PY'
import re, sys
from pathlib import Path
section = Path(sys.argv[1]).read_text().split('\nCodex estimated cost', 1)[1]
for line in section.splitlines():
    if re.search(r'\$-?\d+\.\d+|\t(?:\d+\.\d{4}|rate-unknown)(?:\t|$)', line):
        assert sys.argv[2] in line, line
rows = [line.split('\t')[0] for line in section.splitlines() if '\t' in line][1:-1]
assert rows == sorted(rows), rows
PY
ok 'exact cached-token arithmetic, labels, coverage, worktree attribution and quota caveat'

# G and D: executable old-version comparison and unchanged output prefix.
BASE_REV="${USAGE_REPORT_BASE_REV:-4f18fce}"
if git -C "$ROOT" cat-file -e "$BASE_REV:bin/orch-usage-report" 2>/dev/null; then
  git -C "$ROOT" show "$BASE_REV:bin/orch-usage-report" > "$TMP/old-usage-report"
  chmod +x "$TMP/old-usage-report"
  for days in default 1; do
    args=(); [ "$days" = default ] || args=(--days "$days")
    "$TMP/old-usage-report" "${args[@]}" > "$TMP/old-output"
    "$REPORT" "${args[@]}" > "$TMP/new-output"
    diff -u "$TMP/old-output" "$TMP/new-output" || fail "baseline output ($days)"
  done
  ok 'byte-for-byte baseline output for default and --days 1'
else
  echo 'skip - baseline revision unavailable'
fi
run
assert_success default
assert_not_has "$RUN_OUTPUT" 'estimated cost' 'opt-in only'
assert_eq "$MAIN_OUTPUT" "$RUN_OUTPUT"$'\n\n'"Codex estimated cost${MAIN_OUTPUT#*Codex estimated cost}" 'unchanged prefix'
run --cost --days 1
assert_success 'cost then days'
DAYS_OUTPUT="$RUN_OUTPUT"
run --days 1 --cost
assert_success 'days then cost'
assert_eq "$RUN_OUTPUT" "$DAYS_OUTPUT" 'argument order'
run --days 1
assert_success days
assert_has "$RUN_OUTPUT" 'last 1 day(s)' 'days applied'
for args in x missing; do
  if [ "$args" = missing ]; then run --days; else run --days "$args"; fi
  assert_eq "$RUN_STATUS" 2 'bad days status'
  assert_eq "$RUN_ERROR" 'usage: orch-usage-report [--days N] [--cost]' 'bad days usage'
done
run --ignored --cost
assert_success 'unknown arguments ignored'
assert_eq "$RUN_OUTPUT" "$MAIN_OUTPUT" 'unknown arguments preserve cost'
ok 'opt-in prefix, days validation and argument order'

# B: non-empty, empty and missing logs with no surviving events.
fixture no-events
call 0 intake gpt-6-astra@high "$REPO"
call 60 review gpt-6-sol@high "$REPO"
run --cost
assert_success 'zero priced'
assert_has "$RUN_OUTPUT" 'coverage: 0/2 calls priced (0.0%)' 'zero priced'
assert_has "$RUN_OUTPUT" "observed: \$0.0000 ($LABEL)" 'zero observed'
assert_not_has "$RUN_OUTPUT" 'fast-mode:' 'no priced Fast calls'
: > "$CC_ORCH_CODEX_LOG"
run --cost
assert_success 'empty log'
assert_has "$RUN_OUTPUT" 'coverage: 0/0 calls priced (0.0%)' 'empty log'
rm "$CC_ORCH_CODEX_LOG"
run --cost
assert_success 'missing log'
assert_has "$RUN_OUTPUT" 'coverage: 0/0 calls priced (0.0%)' 'missing log'
ok 'zero priced calls and empty or missing logs'

# C: policy degradation, missing counterfactual and independently applied Fast rates.
CC_ORCH_CODEX_LOG="$MAIN_LOG"
CC_ORCH_PRICING_POLICY="$TMP/missing-policy"
run --cost
assert_success 'missing policy'
assert_has "$RUN_ERROR" "orch-usage-report: warning: pricing policy not readable: $CC_ORCH_PRICING_POLICY; all rates unknown" 'missing policy warning'
assert_has "$RUN_OUTPUT" '(effective unknown; source unknown;' 'missing metadata'
assert_has "$RUN_OUTPUT" 'coverage: 0/5 calls priced (0.0%)' 'missing rates'
assert_eq "$(grep -c $'\trate-unknown\trate-unknown\t' "$TMP/stdout")" 4 'all token rows unknown'
assert_has "$RUN_OUTPUT" "all-gpt-6-astra counterfactual: rate unknown ($LABEL)" 'unknown counterfactual'
assert_has "$RUN_OUTPUT" "difference (counterfactual - observed): rate unknown ($LABEL)" 'unknown difference'
CC_ORCH_PRICING_POLICY="$TMP/malformed-policy"
sed 's@^RATE_gpt-6-luna=.*@RATE_gpt-6-luna=abc@' "$ROOT/pricing-policy.conf" > "$CC_ORCH_PRICING_POLICY"
run --cost
assert_success 'malformed rate'
assert_has "$RUN_ERROR" 'orch-usage-report: warning: pricing policy: malformed RATE_gpt-6-luna; rate unknown for gpt-6-luna' 'malformed warning'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\trate-unknown\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 2/5 calls priced (40.0%)' 'others still priced'
assert_has "$RUN_OUTPUT" "observed: \$14.5500 ($LABEL)" 'known subtotal'
CC_ORCH_PRICING_POLICY="$TMP/fast-policy"
cp "$ROOT/pricing-policy.conf" "$CC_ORCH_PRICING_POLICY"
printf '%s\n' 'FAST_MULTIPLIER_gpt-6-astra=2' >> "$CC_ORCH_PRICING_POLICY"
run --cost
assert_success 'Fast multiplier'
assert_row $'gpt-6-astra\t1\t1\t600000\t400000\t100000\t22.8000\t22.8000'
assert_has "$RUN_OUTPUT" 'fast-mode observed: policy Fast multiplier applied (gpt-6-astra)' 'observed multiplier'
assert_has "$RUN_OUTPUT" 'fast-mode counterfactual: policy Fast multiplier applied (gpt-6-astra)' 'counterfactual multiplier'
fixture fast-sol
call 0 review gpt-6.1-sol@high+fast-mode "$REPO"
event "$REPO/.orchestra/task/codex-review.jsonl" 60 2000000 1500000 200000
CC_ORCH_PRICING_POLICY="$TMP/fast-sol-policy"
cp "$ROOT/pricing-policy.conf" "$CC_ORCH_PRICING_POLICY"
printf '%s\n' 'FAST_MULTIPLIER_gpt-6.1-sol=2' >> "$CC_ORCH_PRICING_POLICY"
run --cost
assert_success 'separate Fast uncertainty'
assert_row $'gpt-6.1-sol\t1\t1\t500000\t1500000\t200000\t6.3000\t16.5000'
assert_has "$RUN_OUTPUT" 'fast-mode observed: policy Fast multiplier applied (gpt-6.1-sol)' 'Sol multiplier'
assert_has "$RUN_OUTPUT" 'fast-mode counterfactual: Standard-rate estimate, Fast multiplier unknown (gpt-6-astra)' 'Astra uncertainty'
ok 'missing or malformed rates and separate observed/counterfactual Fast multipliers'

# F: fallback ties, ambiguous ties, completion-order exclusion and sequential runs.
fixture fallback
call 0 implement gpt-6-astra@xhigh "$REPO" 1
call 0 implement 'gpt-6.1-sol@xhigh (fallback-from:gpt-6-astra)' "$REPO"
event "$REPO/.orchestra/task/codex-implement.jsonl" 60 2000000 1500000 200000
run --cost
assert_success fallback
assert_row $'gpt-6.1-sol\t1\t0\t500000\t1500000\t200000\t3.1500\t16.5000'
assert_has "$RUN_OUTPUT" 'unpriced: 1 call(s) without surviving token data (gpt-6-astra 1)' 'original attempt unpriced'
assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' fallback
fixture ambiguous
call 0 verify gpt-6-astra@high "$REPO"
call 0 verify gpt-6-luna@high "$REPO"
event "$REPO/.orchestra/task/codex-verify.jsonl" 60 1000000 400000 100000
run --cost
assert_success ambiguous
assert_has "$RUN_OUTPUT" 'ambiguous: 1 event file(s) could not be attributed to a single call; their calls stay unpriced' ambiguous
assert_has "$RUN_OUTPUT" 'coverage: 0/2 calls priced (0.0%)' ambiguous
fixture crossing
call 0 verify gpt-6-astra@high "$REPO"
call 720 review gpt-6-sol@high "$TMP/unrelated"
call 300 verify gpt-6-luna@high "$REPO"
event "$REPO/.orchestra/04-x/codex-verify.jsonl" 600 1000000 400000 100000
event "$REPO/.orchestra/05-y/codex-verify.jsonl" 1200 1000000 500000 1000000
run --cost
assert_success crossing
assert_row $'gpt-6-astra\t1\t0\t600000\t400000\t100000\t11.4000\t11.4000'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 2/3 calls priced (66.7%)' crossing
fixture sequential
call 0 verify gpt-6-astra@high "$REPO"
call 720 verify gpt-6-luna@high "$REPO"
event "$REPO/.orchestra/04-x/codex-verify.jsonl" 600 1000000 400000 100000
event "$REPO/.orchestra/05-y/codex-verify.jsonl" 1200 1000000 500000 1000000
run --cost
assert_success sequential
assert_row $'gpt-6-astra\t1\t0\t600000\t400000\t100000\t11.4000\t11.4000'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 2/2 calls priced (100.0%)' sequential
ok 'fallback tie, ambiguous tie, crossing overlap and sequential attribution'

# A workdir alias must not let overwritten events price both wrapper calls.
fixture symlink-repo
REPO_ALIAS="$TMP/symlink-repo-alias"
ln -s "$REPO" "$REPO_ALIAS"
call 0 verify gpt-6-astra@high "$REPO"
call 720 verify gpt-6-luna@high "$REPO_ALIAS"
event "$REPO/.orchestra/task/codex-verify.jsonl" 1200 1000000 0 0
run --cost
assert_success 'real and symlink workdirs'
assert_row $'gpt-6-luna\t1\t0\t1000000\t0\t0\t0.1000\t10.0000'
assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'one surviving physical event'
assert_has "$RUN_OUTPUT" "observed: \$0.1000 ($LABEL)" 'only Luna cost survives'
assert_has "$RUN_OUTPUT" 'unpriced: 1 call(s) without surviving token data (gpt-6-astra 1)' 'overwritten Astra remains unpriced'
assert_not_has "$RUN_OUTPUT" $'\ngpt-6-astra\t' 'no Astra token row'
# Distinct paths beneath the canonical root may also point to the same event.
ln -s "$REPO/.orchestra/task" "$REPO/.orchestra/task-alias"
run --cost
assert_success 'symlinked event directory'
assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'physical event deduplicated'
assert_has "$RUN_OUTPUT" "observed: \$0.1000 ($LABEL)" 'event alias adds no cost'
fixture symlink-only-repo
REPO_ALIAS="$TMP/symlink-only-workdir"
ln -s "$REPO" "$REPO_ALIAS"
call 0 verify gpt-6-luna@high "$REPO_ALIAS"
event "$REPO_ALIAS/.orchestra/task/codex-verify.jsonl" 60 1000000 0 0
run --cost
assert_success 'only symlink workdir logged'
assert_row $'gpt-6-luna\t1\t0\t1000000\t0\t0\t0.1000\t10.0000'
assert_has "$RUN_OUTPUT" 'coverage: 1/1 calls priced (100.0%)' 'symlink-only discovery'
assert_has "$RUN_OUTPUT" "observed: \$0.1000 ($LABEL)" 'symlink-only cost'
ok 'workdir and event aliases price each physical file once, including symlink-only discovery'

# A later invocation can overwrite events before its wrapper-log line is appended.
fixture pending-events
call 0 verify gpt-6-astra@high "$REPO"
touch -d "$(stamp 60)" "$CC_ORCH_CODEX_LOG"
TOKENS="$REPO/.orchestra/task/codex-verify.jsonl"
event "$TOKENS" 120 2000000 0 0
run --cost
assert_success 'event newer than wrapper-log snapshot'
assert_has "$RUN_OUTPUT" 'coverage: 0/1 calls priced (0.0%)' 'pending event stays unpriced'
assert_has "$RUN_OUTPUT" "observed: \$0.0000 ($LABEL)" 'no stale-model cost'
assert_has "$RUN_OUTPUT" 'pending: 1 event file(s) completed after the wrapper-log snapshot were not attributed' 'pending count'
assert_not_has "$RUN_OUTPUT" $'\ngpt-6-astra\t' 'no stale Astra token row'
for event_time in 59 60; do
  touch -d "$(stamp "$event_time")" "$TOKENS"
  run --cost
  assert_success 'event at or before wrapper-log snapshot'
  assert_row $'gpt-6-astra\t1\t0\t2000000\t0\t0\t20.0000\t20.0000'
  assert_has "$RUN_OUTPUT" 'coverage: 1/1 calls priced (100.0%)' 'snapshot control prices'
  assert_not_has "$RUN_OUTPUT" 'pending:' 'no pending event in control'
done
assert_not_has "$MAIN_OUTPUT" 'pending:' 'existing fixture events predate log snapshot'
ok 'events newer than the log snapshot stay pending; earlier and equal mtimes still price'

# Additional input boundaries: named lanes, paths with spaces, multiple turns,
# invalid usage, unknown tags, malformed log details and out-of-window claims.
fixture 'nested worktree'
WORKTREE="$REPO/.orchestra/wt/lead-x"
call 0 resume gpt-6-sol@high "$WORKTREE"
TOKENS="$WORKTREE/.orchestra/task/codex-resume-lane-a.jsonl"
event "$TOKENS" 60 1000000 400000 100000
printf '%s\n' 'invalid json' '[]' '{"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000}}' >> "$TOKENS"
touch -d "$(stamp 60)" "$TOKENS"
run --cost
assert_success 'nested named lane'
assert_row $'gpt-6-sol\t1\t0\t1200000\t800000\t200000\t4.5600\t22.8000'
for usage in '{"input_tokens":true,"cached_input_tokens":0,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":2,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":0,"output_tokens":-1}' \
    '{"input_tokens":1.5,"cached_input_tokens":0,"output_tokens":1}' \
    '{"input_tokens":1,"output_tokens":1}' null; do
  printf '{"type":"turn.completed","usage":%s}\n' "$usage" > "$TOKENS"
  touch -d "$(stamp 60)" "$TOKENS"
  run --cost
  assert_success 'invalid usage'
  assert_has "$RUN_OUTPUT" 'coverage: 0/1 calls priced (0.0%)' 'invalid usage'
done
printf '%s\n' '{"type":"thread.started"}' > "$TOKENS"
touch -d "$(stamp 60)" "$TOKENS"
event "$WORKTREE/.orchestra/task/codex-unknown.jsonl" 120 1000000 400000 100000
printf '%s\n' "$(stamp 0) intake gpt-6-astra@high no-exit-field" '9999-not-a-date verify gpt-6-luna@high exit=0 /missing' >> "$CC_ORCH_CODEX_LOG"
run --cost
assert_success 'no completed turn and malformed details'
assert_has "$RUN_OUTPUT" 'coverage: 0/3 calls priced (0.0%)' 'legacy denominator'
fixture window
call -864000 verify gpt-6-astra@high "$REPO"
call 0 verify gpt-6-luna@high "$REPO"
event "$REPO/.orchestra/old/codex-verify.jsonl" -863900 1000000 400000 100000
event "$REPO/.orchestra/new/codex-verify.jsonl" 60 1000000 500000 1000000
run --cost --days 1
assert_success 'all-log join'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 1/1 calls priced (100.0%)' 'window denominator'
ok 'usage validation, multiple turns, named lanes, nested roots and window boundaries'

# Policy text is data only; malformed numeric forms never become prices.
CC_ORCH_CODEX_LOG="$MAIN_LOG"
CC_ORCH_PRICING_POLICY="$TMP/policy-data"
for bad in 'NaN/0/1' 'Infinity/0/1' '-1/0/1' '1e2/0/1' '1/2' '1/2/3/4'; do
  cp "$ROOT/pricing-policy.conf" "$CC_ORCH_PRICING_POLICY"
  printf 'RATE_gpt-6-luna=%s\n' "$bad" >> "$CC_ORCH_PRICING_POLICY"
  run --cost
  assert_success 'invalid decimal form'
  assert_has "$RUN_OUTPUT" 'coverage: 2/5 calls priced (40.0%)' 'invalid decimal rate'
done
for bad in 0 -1 NaN 1e2; do
  cp "$ROOT/pricing-policy.conf" "$CC_ORCH_PRICING_POLICY"
  printf 'FAST_MULTIPLIER_gpt-6-astra=%s\n' "$bad" >> "$CC_ORCH_PRICING_POLICY"
  run --cost
  assert_success 'invalid multiplier'
  assert_has "$RUN_ERROR" 'malformed FAST_MULTIPLIER_gpt-6-astra; Fast multiplier unknown for gpt-6-astra' 'invalid multiplier warning'
  assert_has "$RUN_OUTPUT" 'fast-mode observed: Standard-rate estimate, Fast multiplier unknown (gpt-6-astra)' 'invalid multiplier fallback'
done
sed -e '/^PRICING_COUNTERFACTUAL_MODEL=/d' -e 's/^\(RATE_[^=]*\)=\(.*\)$/\1="\2"/' "$ROOT/pricing-policy.conf" > "$CC_ORCH_PRICING_POLICY"
printf '%s\n' 'FAST_MULTIPLIER_gpt-6-astra=' "IGNORED=\$(touch $TMP/executed-policy)" >> "$CC_ORCH_PRICING_POLICY"
run --cost
assert_success 'quoted values and default counterfactual'
assert_has "$RUN_OUTPUT" "observed: \$15.1050 ($LABEL)" 'quoted rates'
assert_not_has "$RUN_ERROR" 'Fast multiplier unknown' 'empty multiplier no warning'
[ ! -e "$TMP/executed-policy" ] || fail 'policy was executed'
sed '/^RATE_gpt-6-astra=/d' "$ROOT/pricing-policy.conf" > "$CC_ORCH_PRICING_POLICY"
run --cost
assert_success 'unknown counterfactual with priced calls'
assert_row $'gpt-6.1-sol\t1\t0\t500000\t1500000\t200000\t3.1500\trate-unknown'
assert_has "$RUN_OUTPUT" "observed: \$3.7050 ($LABEL)" 'observed remains known'
assert_has "$RUN_OUTPUT" "all-gpt-6-astra counterfactual: rate unknown ($LABEL)" 'unknown counterfactual total'
ok 'strict policy decimals, inert policy content, optional metadata and unknown counterfactual'

# E: syntax, no provider APIs and no prices embedded in runtime code.
# The unchanged Claude section has a local `requests` dict; check that word only
# in the cost addition, and all other forbidden dependencies across the script.
bash -n "$REPORT"
python3 - "$REPORT" <<'PY'
import ast, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
ast.parse(source)
PY
if grep -Eq 'urllib|http\.client|socket|requests|curl|wget|subprocess' <(sed -n '/^if sys.argv\[4\]/,$p' "$REPORT"); then
  fail 'provider/network dependency in cost code'
fi
if grep -Eq 'urllib|http\.client|socket|curl|wget|subprocess|10\.00|50\.00|0\.10' "$REPORT"; then
  fail 'provider/network dependency or hardcoded rate in report'
fi
assert_eq "$(grep -rl pricing-policy "$ROOT/bin" "$ROOT/lib" "$ROOT/hooks")" "$REPORT" 'pricing policy is report-only'
ok 'shell/Python syntax, local-only dependencies and report-only pricing policy'

# Sidecars use byte offsets even when the log text is identical or contains Unicode.
record() {
  python3 - "$CC_ORCH_CODEX_LOG" "$CC_ORCH_CODEX_RUNS" "$@" <<'PY'
import json, sys, uuid
from pathlib import Path
log, sidecar, index, source, inp, cached, out = sys.argv[1:]
lines = Path(log).read_bytes().splitlines(keepends=True)
index = int(index)
try:
    stat = Path(source).stat()
    mtime_ns, size = stat.st_mtime_ns, stat.st_size
except OSError:
    mtime_ns = size = None
row = dict(v=1, run_id=uuid.uuid4().hex, log_offset=sum(map(len, lines[:index])),
           log_line=lines[index].decode().rstrip('\n'), events=source,
           events_mtime_ns=mtime_ns, events_size=size,
           usage=dict(input_tokens=int(inp), cached_input_tokens=int(cached), output_tokens=int(out)))
with Path(sidecar).open('a') as stream:
    stream.write(json.dumps(row) + '\n')
PY
}
attribution() {
  assert_has "$RUN_OUTPUT" "attribution exact: $1 call(s) with token data joined by run identifier (" 'exact attribution'
  assert_has "$RUN_OUTPUT" "attribution estimated: $2 call(s) with token data matched by event-file time; legacy records without a run identifier (" 'estimated attribution'
}
export CC_ORCH_CODEX_RUNS="$TMP/crossing-runs.jsonl"
CC_ORCH_CODEX_LOG="$TMP/crossing.log"
CC_ORCH_PRICING_POLICY="$ROOT/pricing-policy.conf"
# The time matcher assigns these surviving events to the opposite models.
record 0 "$TMP/crossing/.orchestra/05-y/codex-verify.jsonl" 1000000 500000 1000000
record 2 "$TMP/crossing/.orchestra/04-x/codex-verify.jsonl" 1000000 400000 100000
run --cost
assert_success 'exact crossing'
assert_row $'gpt-6-astra\t1\t0\t500000\t500000\t1000000\t55.5000\t55.5000'
assert_row $'gpt-6-luna\t1\t0\t600000\t400000\t100000\t0.1140\t11.4000'
assert_has "$RUN_OUTPUT" 'coverage: 2/3 calls priced (66.7%)' 'exact crossing coverage'
attribution 2 0
assert_has "$RUN_OUTPUT" 'joined by run identifier (gpt-6-astra 1, gpt-6-luna 1)' 'exact model counts'
rm "$CC_ORCH_CODEX_RUNS"
run --cost
assert_success 'legacy crossing control'
assert_row $'gpt-6-astra\t1\t0\t600000\t400000\t100000\t11.4000\t11.4000'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 2/3 calls priced (66.7%)' 'legacy crossing coverage'
attribution 0 2
ok 'exact crossing attribution and unchanged legacy crossing control'

fixture mixed
CC_ORCH_CODEX_RUNS="$TMP/mixed-runs.jsonl"
call 0 verify gpt-6-astra@high "$REPO"
call 720 verify gpt-6-luna@high "$REPO"
event "$REPO/.orchestra/identified/codex-verify.jsonl" 900 1000000 400000 100000
event "$REPO/.orchestra/legacy/codex-verify.jsonl" 1200 1000000 500000 1000000
ln -s "$REPO/.orchestra/identified" "$REPO/.orchestra/alias"
record 0 "$REPO/.orchestra/alias/codex-verify.jsonl" 1000000 400000 100000
run --cost
assert_success mixed
assert_row $'gpt-6-astra\t1\t0\t600000\t400000\t100000\t11.4000\t11.4000'
assert_row $'gpt-6-luna\t1\t0\t500000\t500000\t1000000\t0.5550\t55.5000'
assert_has "$RUN_OUTPUT" 'coverage: 2/2 calls priced (100.0%)' 'mixed coverage'
attribution 1 1
ok 'mixed exact and legacy calls exclude consumed events by realpath'

for shape in fallback symlink-repo; do
  CC_ORCH_CODEX_LOG="$TMP/$shape.log"
  CC_ORCH_CODEX_RUNS="$TMP/$shape-runs.jsonl"
  tag=verify; [ "$shape" != fallback ] || tag=implement
  record 0 "$TMP/$shape/.orchestra/task/codex-$tag.jsonl" 1000000 400000 100000
  if [ "$shape" = fallback ]; then
    record 1 "$TMP/$shape/.orchestra/task/codex-$tag.jsonl" 2000000 1500000 200000
  else
    record 1 "$TMP/$shape/.orchestra/task/codex-$tag.jsonl" 1000000 0 0
  fi
  run --cost
  assert_success "exact overwritten $shape"
  assert_row $'gpt-6-astra\t1\t0\t600000\t400000\t100000\t11.4000\t11.4000'
  if [ "$shape" = fallback ]; then
    assert_row $'gpt-6.1-sol\t1\t0\t500000\t1500000\t200000\t3.1500\t16.5000'
  else
    assert_row $'gpt-6-luna\t1\t0\t1000000\t0\t0\t0.1000\t10.0000'
  fi
  assert_has "$RUN_OUTPUT" 'coverage: 2/2 calls priced (100.0%)' 'both overwritten calls priced'
  attribution 2 0
  rm "$CC_ORCH_CODEX_RUNS"
  run --cost
  assert_success "legacy overwritten $shape"
  assert_has "$RUN_OUTPUT" 'unpriced: 1 call(s) without surviving token data (gpt-6-astra 1)' 'legacy original unpriced'
  assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'legacy overwritten coverage'
  attribution 0 1
done
ok 'captured usage survives fallback and repeated workdir aliases'

fixture 'identical 한글 lines'
CC_ORCH_CODEX_RUNS="$TMP/identical-runs.jsonl"
call 0 verify gpt-6-astra@high "$REPO"
call 0 verify gpt-6-astra@high "$REPO"
TOKENS="$REPO/.orchestra/task/codex-verify.jsonl"
event "$TOKENS" 60 2000000 0 0
record 0 "$TMP/missing-first-events" 1000000 0 0
record 1 "$TOKENS" 2000000 0 0
run --cost
assert_success 'identical log lines'
assert_row $'gpt-6-astra\t2\t0\t3000000\t0\t0\t30.0000\t30.0000'
attribution 2 0
cp "$CC_ORCH_CODEX_RUNS" "$TMP/identical-complete"
head -1 "$TMP/identical-complete" > "$CC_ORCH_CODEX_RUNS"
run --cost
assert_success 'identical line without a record'
assert_row $'gpt-6-astra\t2\t0\t3000000\t0\t0\t30.0000\t30.0000'
attribution 1 1
ok 'byte-identical lines join their own offsets and an unidentified repeat remains legacy'

fixture generation
CC_ORCH_CODEX_RUNS="$TMP/generation-runs.jsonl"
call 0 verify gpt-6-astra@high "$REPO"
call 720 verify gpt-6-luna@high "$REPO"
TOKENS="$REPO/.orchestra/task/codex-verify.jsonl"
# Its mtime makes this file a legacy candidate for the later call if not excluded.
event "$TOKENS" 900 1000000 0 0
record 0 "$TOKENS" 1000000 0 0
run --cost
assert_success 'unchanged generation excluded'
assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'consumed generation unavailable'
attribution 1 0
assert_not_has "$RUN_OUTPUT" $'\ngpt-6-luna\t' 'no duplicate legacy tokens'
event "$TOKENS" 1200 20000000 0 0
run --cost
assert_success 'unidentified rewrite retained'
assert_row $'gpt-6-astra\t1\t0\t1000000\t0\t0\t10.0000\t10.0000'
assert_row $'gpt-6-luna\t1\t0\t20000000\t0\t0\t2.0000\t200.0000'
attribution 1 1
ok 'only the consumed event generation is excluded from legacy matching'

fixture orphans
CC_ORCH_CODEX_RUNS="$TMP/orphans-runs.jsonl"
call 0 verify gpt-6-luna@high "$REPO"
TOKENS="$REPO/.orchestra/task/codex-verify.jsonl"
event "$TOKENS" 60 1000000 0 0
record 0 "$TOKENS" 9000000 0 0
cp "$CC_ORCH_CODEX_RUNS" "$TMP/valid-record"
python3 - "$TMP/valid-record" "$CC_ORCH_CODEX_RUNS" <<'PY'
import json, sys
from pathlib import Path
row = json.loads(Path(sys.argv[1]).read_text())
bad = [dict(row, log_offset=999999), dict(row, run_id='wrong-text', log_line='different line'),
       dict(row, run_id='bool-offset', log_offset=True), dict(row, run_id='negative', log_offset=-1),
       dict(row, run_id='float-offset', log_offset=0.0), dict(row, run_id=''), dict(row, run_id=None),
       dict(row, run_id='bad-line', log_line=None), [], None]
Path(sys.argv[2]).write_text('invalid json\n' + ''.join(json.dumps(r) + '\n' for r in bad))
PY
run --cost
assert_success 'orphan and malformed sidecars'
assert_row $'gpt-6-luna\t1\t0\t1000000\t0\t0\t0.1000\t10.0000'
attribution 0 1
# The first valid record wins; duplicates cannot replace usage or claim another call.
cp "$TMP/valid-record" "$CC_ORCH_CODEX_RUNS"
record 0 "$TOKENS" 8000000 0 0
call 120 verify gpt-6-astra@high "$REPO"
python3 - "$TMP/valid-record" "$CC_ORCH_CODEX_RUNS" "$CC_ORCH_CODEX_LOG" <<'PY'
import json, sys
from pathlib import Path
row = json.loads(Path(sys.argv[1]).read_text())
lines = Path(sys.argv[3]).read_bytes().splitlines(keepends=True)
row.update(log_offset=len(lines[0]), log_line=lines[1].decode().rstrip('\n'))
with Path(sys.argv[2]).open('a') as stream:
    stream.write(json.dumps(row) + '\n')
PY
run --cost
assert_success 'duplicate records'
assert_row $'gpt-6-luna\t1\t0\t9000000\t0\t0\t0.9000\t90.0000'
assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'duplicate run id ignored'
attribution 1 0
for usage in '{"input_tokens":true,"cached_input_tokens":0,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":2,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":0,"output_tokens":-1}' \
    '{"input_tokens":1.5,"cached_input_tokens":0,"output_tokens":1}' \
    '{"input_tokens":1,"output_tokens":1}' null '[]'; do
  python3 - "$TMP/valid-record" "$CC_ORCH_CODEX_RUNS" "$usage" <<'PY'
import json, sys
from pathlib import Path
row = json.loads(Path(sys.argv[1]).read_text())
row['usage'] = json.loads(sys.argv[3])
Path(sys.argv[2]).write_text(json.dumps(row) + '\n')
PY
  run --cost
  assert_success 'invalid recorded usage'
  assert_has "$RUN_OUTPUT" 'coverage: 0/2 calls priced (0.0%)' 'invalid usage still claims its call and event'
  attribution 0 0
done
# A directory is unreadable as JSONL; malformed line separators disable exact joins.
CC_ORCH_CODEX_RUNS="$TMP"
run --cost
assert_success 'unreadable sidecar'
attribution 0 1
CC_ORCH_CODEX_RUNS="$TMP/valid-record"
python3 - "$CC_ORCH_CODEX_LOG" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
PY
run --cost
assert_success 'pathological line splitting'
attribution 0 1
ok 'orphan, malformed, duplicate and invalid-usage records fail safely'

# Exercise both real launchers with isolated, offline dependencies.
FAKEBIN="$TMP/run-fakebin"
WRAP_REPO="$TMP/wrapper work"
WRAP_TASK="$WRAP_REPO/.orchestra/task"
WRAP_STATE="$TMP/wrapper-state"
mkdir -p "$FAKEBIN" "$WRAP_TASK" "$TMP/run-home/.claude" "$TMP/run-catalog"
printf 'private-prompt-sentinel\n' > "$WRAP_TASK/plan.md"
printf 'private-brief-sentinel\n' > "$WRAP_TASK/brief.md"
cat > "$FAKEBIN/codex" <<'CODEX'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'codex-cli 0.159.0'; exit 0; fi
model="" output=""
while [ $# -gt 0 ]; do
  case "$1" in -m) shift; model="$1" ;; -o) shift; output="$1" ;; esac
  shift
done
printf '%s\n' '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}'
if [ "${FAKE_FALLBACK:-0}" = 1 ] && [ "$model" = gpt-6-astra ]; then
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":4000000,"cached_input_tokens":0,"output_tokens":0}}'
  printf '%s\n' 'ERROR: {"type":"error","error":{"message":"This model is not supported when using Codex with a ChatGPT account."}}' >&2
  exit 1
fi
printf '{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s}}\n' \
  "${FAKE_USAGE_IN:-1000000}" "${FAKE_USAGE_CACHED:-0}" "${FAKE_USAGE_OUT:-0}"
if [ -n "${FAKE_EXTRA_EVENTS:-}" ]; then printf '%s\n' "$FAKE_EXTRA_EVENTS"; fi
printf 'ok\n' > "$output"
if [ "${FAKE_LEGACY_APPEND:-0}" = 1 ]; then
  printf '%s\n' "$RACE_LINE" >> "$CC_ORCH_STATE_DIR/codex.log"
fi
CODEX
cat > "$FAKEBIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' 'Current session: 10% used' 'Current week (all models): 20% used' 'Current week (Fable): 20% used'
CLAUDE
cat > "$FAKEBIN/date" <<'DATE'
#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = -Is ]; then printf '%s\n' "$FROZEN_START"; else exec "$REAL_DATE" "$@"; fi
DATE
chmod +x "$FAKEBIN/"*
export REAL_DATE="$(command -v date)" FROZEN_START="$(date -Is)"
wrapper() {
  env -u CC_ORCH_BACKEND -u CC_ORCH_CODEX_ROUTE PATH="$FAKEBIN:$PATH" \
    HOME="$TMP/run-home" CODEX_HOME="$TMP/run-catalog" CLAUDE_BIN="$FAKEBIN/claude" \
    CC_ORCH_STATE_DIR="$WRAP_STATE" CC_ORCH_ALWAYS_FAST_MODE=0 \
    CC_ORCH_JEV_POLICY="$ROOT/jev-policy.conf" "$@" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err"
}
FAKE_USAGE_IN=1000000 wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol --lane repeat
FAKE_USAGE_IN=2000000 wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol --lane repeat
FAKE_USAGE_IN=3000000 wrapper "$ROOT/bin/codex-run-codex" implement "$WRAP_REPO" "$WRAP_TASK"
FAKE_FALLBACK=1 FAKE_USAGE_IN=5000000 wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK"
assert_has "$(cat "$TMP/wrapper.err")" MODEL_FALLBACK 'offline auto-routed fallback'
python3 - "$WRAP_STATE" "$WRAP_TASK" "$FROZEN_START" <<'PY'
import json, re, sys
from pathlib import Path
state, task, start = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
lines = (state / 'codex.log').read_bytes().splitlines(keepends=True)
raw = (state / 'codex-runs.jsonl').read_text()
records = [json.loads(line) for line in raw.splitlines()]
assert len(records) == len(lines) == 5, records
assert lines[0] == lines[1], lines
assert len({row['run_id'] for row in records}) == 5
offset = 0
keys = set(('v run_id attempt pid start end mode lane run_tag model effort fast_mode fallback_from '
            'exit workdir task_dir events events_mtime_ns events_size usage log_offset log_line').split())
for row, line in zip(records, lines):
    assert set(row) == keys, row
    assert re.fullmatch(r'[0-9a-f]{32}', row['run_id']), row
    assert row['log_line'].encode() + b'\n' == line
    assert row['log_offset'] == offset, row
    assert row['start'] == start and line.startswith(start.encode()), row
    assert row['task_dir'] == str(task), row
    assert row['events_mtime_ns'] > 0 and row['events_size'] > 0, row
    offset += len(line)
assert [r['usage']['input_tokens'] for r in records] == [1000000, 2000000, 3000000, 4000000, 5000000]
assert [r['attempt'] for r in records] == [1, 1, 1, 1, 2]
assert [r['fallback_from'] for r in records] == [None, None, None, None, 'gpt-6-astra']
assert records[0]['lane'] == records[1]['lane'] == 'repeat'
assert records[0]['run_tag'] == records[1]['run_tag'] == 'implement-repeat'
assert records[2]['model'] == 'gpt-6-astra'
assert records[3]['exit'] == 1 and records[4]['exit'] == 0
assert 'private-prompt-sentinel' not in raw and 'private-brief-sentinel' not in raw
assert 'You are' not in raw and 'FAKE_USAGE' not in raw and '--sandbox' not in raw
PY
CC_ORCH_CODEX_LOG="$WRAP_STATE/codex.log"
unset CC_ORCH_CODEX_RUNS
run --cost
assert_success 'real wrappers exact pricing'
assert_row $'gpt-6-astra\t2\t0\t7000000\t0\t0\t70.0000\t70.0000'
assert_row $'gpt-6.1-sol\t3\t0\t8000000\t0\t0\t16.0000\t80.0000'
assert_has "$RUN_OUTPUT" 'coverage: 5/5 calls priced (100.0%)' 'all attempts survive overwrites'
attribution 5 0
ok 'real runtime and Codex-only launchers preserve same-second repeats and fallback usage'

# Writer validation matches the reader and sums all valid completed turns.
WRAP_STATE="$TMP/writer-validation"
FAKE_USAGE_IN=100 FAKE_USAGE_CACHED=40 FAKE_USAGE_OUT=10 \
  FAKE_EXTRA_EVENTS=$'invalid json\n[]\n{"type":"turn.completed","usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":20}}' \
  wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol --fast-mode
for extra in null '{"input_tokens":true,"cached_input_tokens":0,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":2,"output_tokens":1}' \
    '{"input_tokens":1,"cached_input_tokens":0,"output_tokens":-1}' \
    '{"input_tokens":1.5,"cached_input_tokens":0,"output_tokens":1}' '{"input_tokens":1,"output_tokens":1}'; do
  FAKE_EXTRA_EVENTS="{\"type\":\"turn.completed\",\"usage\":$extra}" \
    wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol
done
python3 - "$WRAP_STATE/codex-runs.jsonl" <<'PY'
import json, sys
from pathlib import Path
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 7, rows
assert rows[0]['usage'] == dict(input_tokens=300, cached_input_tokens=90, output_tokens=30), rows[0]
assert rows[0]['fast_mode'] is True
assert all(r['usage'] is None for r in rows[1:]), rows
PY
WRAP_STATE="$TMP/unwritable-sidecar"
mkdir -p "$WRAP_STATE/codex-runs.jsonl"
wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol
assert_eq "$(wc -l < "$WRAP_STATE/codex.log" | tr -d ' ')" 1 'legacy log written despite sidecar failure'
assert_eq "$(grep -c '^codex-run: warning:' "$TMP/wrapper.err")" 1 'one sidecar warning'
assert_has "$(cat "$TMP/wrapper.err")" "codex-run: warning: run record not written to $WRAP_STATE/codex-runs.jsonl" 'sidecar failure warning'
ok 'writer validates every completed turn and sidecar failure preserves successful exit and log'

# An unlocked legacy writer can append identical text after a size snapshot.
# The stat shim reproduces the old defect; the descriptor-based writer bypasses it.
export REAL_STAT="$(command -v stat)"
cat > "$FAKEBIN/stat" <<'STAT'
#!/usr/bin/env bash
if [ "$#" = 3 ] && [ "$1" = -c ] && [ "$2" = %s ] && [[ "$3" == */codex.log ]]; then
  "$REAL_STAT" "$@"
  printf '%s\n' "$RACE_LINE" >> "$3"
  exit 0
fi
exec "$REAL_STAT" "$@"
STAT
chmod +x "$FAKEBIN/stat"
WRAP_REPO="$TMP/legacy 한글 race"
WRAP_TASK="$WRAP_REPO/.orchestra/task"
mkdir -p "$WRAP_TASK"
printf 'race fixture\n' > "$WRAP_TASK/plan.md"
printf 'race fixture\n' > "$WRAP_TASK/brief.md"
export RACE_LINE="$(printf '%s  %-11s  %s  exit=%s  %s' "$FROZEN_START" implement gpt-6.1-sol@high 0 "$WRAP_REPO")"
for foreign in 0 1; do
  WRAP_STATE="$TMP/legacy-race-$foreign"
  mkdir -p "$WRAP_STATE"
  : > "$WRAP_STATE/codex.log"
  # Also append independently of stat, before the real wrapper writes its line.
  FAKE_LEGACY_APPEND="$foreign" FAKE_USAGE_IN=6000000 \
    wrapper "$ROOT/bin/codex-run-runtime" implement "$WRAP_REPO" "$WRAP_TASK" --model sol --effort high
  python3 - "$WRAP_STATE" "$RACE_LINE" "$foreign" <<'PY'
import json, sys
from pathlib import Path
state, line, foreign = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
lines = (state / 'codex.log').read_bytes().splitlines(keepends=True)
record, = [json.loads(row) for row in (state / 'codex-runs.jsonl').read_text().splitlines()]
own_offset = sum(map(len, lines[:-1]))
assert record['log_offset'] == own_offset, f"record joined a foreign line: {record['log_offset']} != {own_offset}"
assert len(lines) == foreign + 1, lines
assert all(row == line.encode() + b'\n' for row in lines), lines
assert record['log_line'] == line
assert record['usage']['input_tokens'] == 6000000
if foreign:
    assert own_offset == len(line.encode()) + 1
    assert own_offset != len(line) + 1, 'fixture must exercise UTF-8 byte length'
PY
  CC_ORCH_CODEX_LOG="$WRAP_STATE/codex.log"
  run --cost
  assert_success 'legacy append race'
  assert_row $'gpt-6.1-sol\t1\t0\t6000000\t0\t0\t12.0000\t60.0000'
  attribution 1 0
  if [ "$foreign" = 1 ]; then
    assert_has "$RUN_OUTPUT" 'coverage: 1/2 calls priced (50.0%)' 'foreign identical line unpriced'
    assert_has "$RUN_OUTPUT" 'unpriced: 1 call(s) without surviving token data (gpt-6.1-sol 1)' 'foreign line cannot consume exact tokens'
  else
    assert_has "$RUN_OUTPUT" 'coverage: 1/1 calls priced (100.0%)' 'no stat race window'
  fi
done
ok 'legacy append races cannot claim the run identifier, including identical UTF-8 lines'

echo "PASS: $pass usage-cost test groups"
