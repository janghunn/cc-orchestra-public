#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/bin/orch-summary-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TASK="$TMP/task"
pass=0
fail() { printf 'FAIL: %s\n%s\n' "$*" "${OUT:-}" >&2; exit 1; }
has() { grep -qF -- "$1" <<< "$OUT" || fail "missing '$1'"; }
lacks() { if grep -qF -- "$1" <<< "$OUT"; then fail "unexpected '$1'"; fi; }
last_line() { [ "$(tail -1 <<< "$OUT")" = "$1" ] || fail "expected final line '$1'"; }

summary() { # <status line, or empty> <gates>
  {
    [ -z "$1" ] || printf '%s\n' "$1"
    cat <<'SUMMARY'
CLAUDE PROFILE: normal opus@high
PROMOTIONS: none
DISPATCH: codex-first
INVESTIGATION: codex
LANES: codex
ROUNDS: 1
SUMMARY
    printf 'GATES: %s\n' "$2"
  } > "$TASK/summary.md"
}
base() {
  rm -rf "$TASK"
  mkdir -p "$TASK"
  cat > "$TASK/brief.md" <<'BRIEF'
RISK: normal
USER ACCEPTED: 2026-10-02 — accept inconclusive verify
BRIEF
  printf '# Plan\n' > "$TASK/plan.md"
  printf 'CODEX-REVIEW: CLEAR\n' > "$TASK/codex-review.md"
  printf 'CODEX-VERDICT: PASS\n' > "$TASK/codex-verdict.md"
  summary 'STATUS: ACCEPTED' 'codex-verify INCONCLUSIVE · codex-review CLEAR'
}
check() { # <exit> <label> [non-strict]
  local status=0
  if [ "${3:-}" = non-strict ]; then
    OUT="$("$CHECKER" "$TASK" 2>&1)" || status=$?
  else
    OUT="$("$CHECKER" --strict "$TASK" 2>&1)" || status=$?
  fi
  [ "$status" = "$1" ] || fail "$2: expected exit $1, got $status"
  pass=$((pass + 1))
  printf 'ok %s - %s\n' "$pass" "$2"
}

for gates in pending 'codex-review CLEAR'; do
  base
  summary 'STATUS: ACCEPTED' "$gates"
  check 1 'ACCEPTED requires an explicit verification result'
  has 'ERROR: STATUS: ACCEPTED requires GATES to state the actual codex-verify result'
done

base
check 0 'authorised INCONCLUSIVE verification is an accepted exception'
has 'NOTE:  STATUS: ACCEPTED authorised by brief.md USER ACCEPTED (2026-10-02); this is not a PASS'
has 'ACCEPTED EXCEPTION: executable verification did not PASS and has no explicit Claude fallback'
last_line 'CHECK: PASS (accepted with exceptions: 1, risk=normal)'

base
summary 'STATUS: ACCEPTED' 'codex-verify FAIL · codex-review BLOCKING 1'
check 0 'failed verification and blocking review count separately'
has 'ACCEPTED EXCEPTION: executable verification did not PASS and has no explicit Claude fallback'
has 'ACCEPTED EXCEPTION: adversarial review is not CLEAR/NONBLOCKING (only low risk may waive it)'
last_line 'CHECK: PASS (accepted with exceptions: 2, risk=normal)'

base
sed -i 's/ROUNDS: 1/ROUNDS: 3/' "$TASK/summary.md"
check 0 'round cap is an additional accepted exception'
has 'ACCEPTED EXCEPTION: ROUNDS=3 exceeds normal cap=2 without EXTRA GATE ROUND: approved'
last_line 'CHECK: PASS (accepted with exceptions: 2, risk=normal)'

base
summary '[lead-x] STATUS: ACCEPTED' 'codex-verify INCONCLUSIVE · codex-review CLEAR'
check 0 'lead-prefixed ACCEPTED is recognised'
last_line 'CHECK: PASS (accepted with exceptions: 1, risk=normal)'

for authorization in \
  '' \
  '  USER ACCEPTED: 2026-10-02 — accepted' \
  $'```\nUSER ACCEPTED: 2026-10-02 — accepted\n```' \
  $'~~~\nUSER ACCEPTED: 2026-10-02 — accepted\n~~~' \
  '## USER ACCEPTED: 2026-10-02 — accepted' \
  '- USER ACCEPTED: 2026-10-02 — accepted' \
  '**USER ACCEPTED:** 2026-10-02 — accepted' \
  'user accepted: 2026-10-02 — accepted' \
  'USER ACCEPTED: 2026-13-02 — accepted' \
  'USER ACCEPTED: 2026-10-02 —   '; do
  base
  printf 'RISK: normal\n%s\n' "$authorization" > "$TASK/brief.md"
  check 1 'missing or malformed brief authorisation stays an error'
  has "ERROR: STATUS: ACCEPTED requires a column-0 'USER ACCEPTED:"
  has 'ERROR: executable verification did not PASS and has no explicit Claude fallback'
  lacks 'ACCEPTED EXCEPTION:'
done

base
summary 'STATUS: ACCEPTED' 'codex-verify PASS · codex-review CLEAR'
printf 'CODEX-VERDICT: FAIL\n' > "$TASK/codex-verdict.md"
check 1 'ACCEPTED does not excuse a contradicted Codex PASS'
has "ERROR: GATES claims codex-verify PASS but codex-verdict.md first line is 'CODEX-VERDICT: FAIL'"

base
summary 'STATUS: ACCEPTED' 'codex-verify INCONCLUSIVE · codex-review CLEAR · claude-verifier PASS'
printf 'VERDICT: FAIL\n' > "$TASK/verdict.md"
check 1 'ACCEPTED does not excuse a contradicted Claude PASS'
has 'ERROR: GATES claims claude-verifier PASS but verdict.md verdict is FAIL'

base
sed -i '/^GATES:/d' "$TASK/summary.md"
check 1 'missing GATES remains structural'
has 'ERROR: summary lacks GATES'

for status in 'STATUS: PASS' 'STATUS: BLOCKED' '' 'STATUS: ACCEPTED-ish' 'STATUS: ACCEPTEDX'; do
  base
  summary "$status" 'codex-verify INCONCLUSIVE · codex-review CLEAR'
  check 1 'non-ACCEPTED status retains gate errors despite user authorisation'
  has 'ERROR: executable verification did not PASS and has no explicit Claude fallback'
  lacks 'ACCEPTED EXCEPTION:'
  lacks 'STATUS: ACCEPTED authorised'
done

base
summary 'STATUS: PASS' 'codex-verify PASS · codex-review CLEAR'
check 0 'clean PASS output is unchanged'
last_line 'CHECK: PASS (risk=normal)'
lacks 'ACCEPTED EXCEPTION:'

base
summary $'```\nSTATUS: ACCEPTED\n```\nSTATUS: PASS' 'codex-verify INCONCLUSIVE · codex-review CLEAR'
check 1 'fenced ACCEPTED example does not authorise real PASS'
has 'ERROR: executable verification did not PASS and has no explicit Claude fallback'
lacks 'ACCEPTED EXCEPTION:'

base
summary $'STATUS: ACCEPTED\nSTATUS: PASS' 'codex-verify INCONCLUSIVE · codex-review CLEAR'
check 1 'last fence-free STATUS controls acceptance'
has 'ERROR: executable verification did not PASS and has no explicit Claude fallback'
lacks 'ACCEPTED EXCEPTION:'

base
summary $'STATUS: PASS\nSTATUS: ACCEPTED\n~~~\nSTATUS: PASS\n~~~' 'codex-verify INCONCLUSIVE · codex-review CLEAR'
check 0 'last fence-free ACCEPTED ignores a later fenced status'
last_line 'CHECK: PASS (accepted with exceptions: 1, risk=normal)'

base
sed -i '/^PROMOTIONS:/d' "$TASK/summary.md"
check 0 'non-strict warnings retain the accepted exception count' non-strict
has 'WARN:  summary lacks PROMOTIONS'
last_line 'CHECK: WARN (1 warning(s); accepted with exceptions: 1)'

base
sed -i 's/RISK: normal/RISK: critical/' "$TASK/brief.md"
sed -i 's/normal opus@high/critical opus@high/' "$TASK/summary.md"
check 1 'critical ACCEPTED requires an explicit Claude result'
has 'ERROR: STATUS: ACCEPTED requires GATES to state the actual claude-verifier result'
printf 'GATES: codex-verify FAIL · codex-review BLOCKING 1 · claude-verifier FAIL\n' >> "$TASK/summary.md"
check 0 'critical Claude failure can be accepted explicitly'
has 'ACCEPTED EXCEPTION: critical risk requires claude-verifier PASS'
last_line 'CHECK: PASS (accepted with exceptions: 3, risk=critical)'

base
sed -i 's/RISK: normal/RISK: critical/' "$TASK/brief.md"
summary 'STATUS: ACCEPTED' 'codex-verify FAIL · codex-review BLOCKING 1 · codex-auditor INCONCLUSIVE'
printf 'BACKEND: codex\nCODEX PROFILE: critical\n' >> "$TASK/summary.md"
check 0 'Codex backend gate failures use their own exception labels'
has 'ACCEPTED EXCEPTION: Codex-only executable verification must PASS'
has 'ACCEPTED EXCEPTION: Codex-only review must be CLEAR/NONBLOCKING'
has 'ACCEPTED EXCEPTION: critical Codex-only risk requires codex-auditor PASS'
last_line 'CHECK: PASS (accepted with exceptions: 3, risk=critical)'
sed -i 's/ · codex-auditor INCONCLUSIVE//' "$TASK/summary.md"
check 1 'critical Codex ACCEPTED requires an explicit auditor result'
has 'ERROR: STATUS: ACCEPTED requires GATES to state the actual codex-auditor result'

fallback() {
  base
  summary 'STATUS: PASS' 'codex-verify unavailable · codex-review unavailable · claude-verifier PASS'
}
for name in verifier-normal-verdict.md verdict.md verdict-2.md; do
  fallback
  printf 'VERDICT: PASS\nFull evidence.\n' > "$TASK/$name"
  check 0 "Claude fallback discovers $name"
  last_line 'CHECK: PASS (risk=normal)'
done

fallback
printf 'VERDICT: FAIL\n' > "$TASK/verifier-normal-verdict.md"
printf 'VERDICT: PASS\n' > "$TASK/verifier-normal-verdict-2.md"
touch -t 202610020000 "$TASK/verifier-normal-verdict.md"
touch -t 202610020001 "$TASK/verifier-normal-verdict-2.md"
check 0 'newer numbered verifier-normal verdict takes precedence'
last_line 'CHECK: PASS (risk=normal)'

fallback
printf 'VERDICT: FAIL\n' > "$TASK/verifier-normal-verdict.md"
check 1 'verifier-normal FAIL contradicts the fallback claim'
has 'ERROR: GATES claims claude-verifier PASS but verifier-normal-verdict.md verdict is FAIL'

fallback
printf 'The commands completed successfully.\n' > "$TASK/verifier-normal-verdict.md"
check 1 'verifier-normal prose without a verdict has a clear diagnostic'
has 'ERROR: GATES claims claude-verifier PASS but verifier-normal-verdict.md has no recognised verdict'

fallback
check 1 'missing verifier diagnostic includes both compatibility names'
has 'no verifier verdict file (verdict.md, verdict-*.md, verifier-verdict.md, verifier-verdict-*.md, verifier-normal-verdict.md, verifier-normal-verdict-*.md)'

base
sed -i '/^USER ACCEPTED:/d' "$TASK/brief.md"
summary 'STATUS: PASS' 'codex-verify PASS (criteria 3,5 delegated to verifier-normal) · codex-review CLEAR · claude-verifier FAIL'
printf 'VERDICT: PASS\n' > "$TASK/verdict.md"
check 1 'D1 delegated criteria require a passing Claude claim even when Codex passes'
has 'ERROR: GATES delegates criteria to verifier-normal but claude-verifier did not PASS'

summary 'STATUS: PASS' 'codex-verify PASS (criteria 3,5 delegated to verifier-normal) · codex-review CLEAR · claude-verifier PASS'
check 0 'D2 delegated criteria with a passing Claude claim and verdict pass'
last_line 'CHECK: PASS (risk=normal)'

rm "$TASK/verdict.md"
check 1 'D3 delegated Claude PASS requires a verdict file'
has 'ERROR: GATES claims claude-verifier PASS but no verifier verdict file'

printf 'VERDICT: INCONCLUSIVE\n' > "$TASK/verdict.md"
check 1 'D4 delegated Claude PASS rejects an INCONCLUSIVE verdict'
has 'ERROR: GATES claims claude-verifier PASS but verdict.md verdict is INCONCLUSIVE'

summary 'STATUS: PASS' 'codex-verify INCONCLUSIVE (criteria 3,5 delegated …) · codex-review CLEAR · claude-verifier PASS'
printf 'VERDICT: PASS\n' > "$TASK/verdict.md"
check 0 'D5 elided delegation with a passing Claude fallback passes'
last_line 'CHECK: PASS (risk=normal)'

summary 'STATUS: PASS' 'codex-verify PASS · codex-review CLEAR · claude-verifier FAIL'
check 0 'D6 non-delegated Codex PASS still permits a Claude FAIL claim'
last_line 'CHECK: PASS (risk=normal)'
summary 'STATUS: PASS' 'codex-verify PASS · codex-review CLEAR'
rm "$TASK/verdict.md"
check 0 'D6 non-delegated Codex PASS still needs no Claude verdict'
last_line 'CHECK: PASS (risk=normal)'

for fence in '```' '~~~'; do
  base
  printf 'RISK: normal\n%s\nEXTRA GATE ROUND: approved\n%s\n' "$fence" "$fence" > "$TASK/brief.md"
  summary 'STATUS: PASS' 'codex-verify PASS · codex-review CLEAR'
  sed -i 's/ROUNDS: 1/ROUNDS: 3/' "$TASK/summary.md"
  check 1 "E1/E2 extra-round approval inside $fence does not count"
  has 'ERROR: ROUNDS=3 exceeds normal cap=2 without EXTRA GATE ROUND: approved'
done

base
printf 'RISK: normal\n  EXTRA GATE ROUND: approved\n' > "$TASK/brief.md"
summary 'STATUS: PASS' 'codex-verify PASS · codex-review CLEAR'
sed -i 's/ROUNDS: 1/ROUNDS: 3/' "$TASK/summary.md"
check 1 'E3 indented extra-round approval does not count'
has 'ERROR: ROUNDS=3 exceeds normal cap=2 without EXTRA GATE ROUND: approved'

printf 'RISK: normal\nEXTRA GATE ROUND: approved\n' > "$TASK/brief.md"
check 0 'E4 column-0 unfenced extra-round approval counts'
last_line 'CHECK: PASS (risk=normal)'

cat > "$TASK/brief.md" <<'BRIEF'
RISK: normal
## Amendment 1
EXTRA GATE ROUND: approved
## Amendment 2
EXTRA GATE ROUND: approved
BRIEF
sed -i 's/ROUNDS: 3/ROUNDS: 4/' "$TASK/summary.md"
check 0 'E5 task-36 amendment headings preserve column-0 approvals'
lacks 'exceeds normal cap='

cat > "$TASK/brief.md" <<'BRIEF'
RISK: normal
- Amendment 1 (follow-up): EXTRA GATE ROUND: approved
EXTRA GATE ROUND: approved
USER ACCEPTED: 2026-10-02 — accept the follow-up
BRIEF
check 0 'E6 task-38 bullet and column-0 approval permit extra rounds'
lacks 'exceeds normal cap='

sed -i '/^EXTRA GATE ROUND:/d' "$TASK/brief.md"
check 1 'E7 task-38 bullet alone does not approve extra rounds'
has 'ERROR: ROUNDS=4 exceeds normal cap=2 without EXTRA GATE ROUND: approved'

echo "PASS: $pass accepted-status cases"
