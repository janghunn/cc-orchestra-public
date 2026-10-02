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

echo "PASS: $pass usage-cost test groups"
