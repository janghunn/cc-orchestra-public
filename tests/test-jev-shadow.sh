#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
python3 "$ROOT/tests/test-jev-shadow.py"
pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "missing '$2' ($3)"; }
export HOME="$TMP/home" CODEX_HOME="$TMP/codex-home" CC_ORCH_STATE_DIR="$TMP/state"
export CC_ORCH_JEV_TEMPLATES="$ROOT/templates/jev" CC_ORCH_ALWAYS_FAST_MODE=1
unset TYPESAFE_API_KEY CC_ORCH_BACKEND CC_ORCH_CODEX_ROUTE CC_ORCH_AUTO_ROUTE
mkdir -p "$HOME/.claude" "$CODEX_HOME" "$CC_ORCH_STATE_DIR" "$TMP/work" "$TMP/task"
WORK="$TMP/work"; TASK="$TMP/task"; HARNESS="$TMP/harness"
mkdir -p "$HARNESS/bin" "$HARNESS/lib"
cp "$ROOT/bin/codex-run-runtime" "$ROOT/bin/orch-jev" "$HARNESS/bin/"
cp "$ROOT/budget-policy.conf" "$HARNESS/"
cp "$ROOT/lib/"*.sh "$HARNESS/lib/"
cat > "$HARNESS/bin/codex-run" <<'CORE'
#!/usr/bin/env bash
printf '%s\nroute=%s\n' "$*" "${CC_ORCH_CODEX_ROUTE:-}" > "$TEST_ARGS"
exit "${FAKE_CORE_EXIT:-0}"
CORE
cat > "$HARNESS/bin/orch-model-guard-runtime" <<'GUARD'
#!/usr/bin/env bash
if [ "${FAKE_GUARD_ERROR:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GUARD_WITHHOLD:-0}" = 1 ]; then
  printf '%s\n' allow=0 pressure=critical reason=x
elif [ "${FAKE_GUARD_INCOMPLETE:-0}" = 1 ]; then
  echo allow=1
else
  printf '%s\n' model=gpt-6-astra effort=xhigh allow=1 pressure=healthy
fi
GUARD
chmod +x "$HARNESS/bin/"*
for enabled in 0 1; do
  printf '%s\n' "JEV_SHADOW_ENABLED=$enabled" JEV_SHADOW_TIMEOUT_SECONDS=1 JEV_TIMEOUT_SECONDS=1 > "$TMP/policy-$enabled"
done
export CC_ORCH_JEV_POLICY="$TMP/policy-0" TEST_ARGS="$TMP/args"
printf '# Task\nAdd a fixture.\n' > "$TASK/brief.md"
printf '# Plan\nRun the fixture.\n' > "$TASK/plan.md"
BASELINE=0
if [ "${SHADOW_BASELINE_REV+x}" = x ]; then
  baseline_rev="$SHADOW_BASELINE_REV"
else
  rev="$(git -C "$ROOT" log --format=%H --diff-filter=A -1 -- tests/test-jev-shadow.sh 2>/dev/null)" || rev=""
  if [ -n "$rev" ]; then baseline_rev="${rev}^"; else baseline_rev=339eae6; fi
fi
baseline_source="$baseline_rev:bin/codex-run-runtime"
printf 'baseline facade: %s\n' "$baseline_source"
if git -C "$ROOT" show "$baseline_source" > "$HARNESS/bin/codex-run-runtime.baseline" 2> "$TMP/baseline-error"; then
  chmod +x "$HARNESS/bin/codex-run-runtime.baseline"
  BASELINE=1
else
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    fail "baseline facade unavailable in CI ($(cat "$TMP/baseline-error"))"
  fi
  echo "skip: baseline facade unavailable ($(cat "$TMP/baseline-error"))"
fi
capture() {
  local label="$1" facade="$2"; shift 2
  : > "$TEST_ARGS"
  local rc=0
  "$facade" "$@" > "$TMP/$label.out" 2> "$TMP/$label.err" || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
  cp "$TEST_ARGS" "$TMP/$label.args"
}
compare() {
  local a="$1" b="$2" field
  for field in out err rc args; do
    cmp "$TMP/$a.$field" "$TMP/$b.$field" || fail "$a vs $b: $field differs"
  done
}
wait_records() {
  python3 - "$CC_ORCH_STATE_DIR/codex-shadow.jsonl" "$1" <<'PY'
import json, sys, time
from pathlib import Path
path, expected = Path(sys.argv[1]), int(sys.argv[2])
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    try:
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        if len(rows) == expected:
            break
    except (OSError, ValueError):
        pass
    time.sleep(0.05)
else:
    raise SystemExit(f"FAIL: expected {expected} shadow records at {path}")
PY
}
check_orphans() {
  python3 - "$TMP" "${1:-10}" <<'PY'
import sys, time
from pathlib import Path
needle, wait = sys.argv[1].encode(), float(sys.argv[2])
deadline = time.monotonic() + wait
while True:
    found = []
    for path in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            command = path.read_bytes()
            if b'orch-jev' in command and needle in command:
                found.append(path.parent.name)
        except OSError:
            pass
    if not found:
        break
    if time.monotonic() >= deadline:
        raise SystemExit('FAIL: orphan shadow workers: ' + ', '.join(found))
    time.sleep(0.05)
PY
}
# Flag off must not start even an instrumented replacement for the worker.
cp "$HARNESS/bin/orch-jev" "$TMP/orch-jev.real"
printf '#!/usr/bin/env bash\ntouch "$SHADOW_MARKER"\n' > "$HARNESS/bin/orch-jev"
export SHADOW_MARKER="$TMP/marker"
"$HARNESS/bin/codex-run-runtime" implement "$WORK" "$TASK"
sleep 1.5
[ ! -e "$SHADOW_MARKER" ] || fail "off spawned worker"
[ ! -e "$CC_ORCH_STATE_DIR/codex-shadow.jsonl" ] || fail "off wrote shadow log"
[ ! -e "$CC_ORCH_STATE_DIR/guard.log" ] || fail "off wrote diagnostic"
cp "$TMP/orch-jev.real" "$HARNESS/bin/orch-jev"
ok "off: no worker or log write"

# Original, off and on must be byte-identical for every facade branch.
for scenario in normal lane explicit fast dry withheld resume review no-route guard-error incomplete codex-only policy-directory policy-fifo empty-workdir empty-task-dir; do
  export CC_ORCH_STATE_DIR="$TMP/harness-$scenario"
  mkdir -p "$CC_ORCH_STATE_DIR"
  call=(implement "$WORK" "$TASK")
  expected=unavailable:no\ key
  export FAKE_GUARD_WITHHOLD=0 FAKE_GUARD_ERROR=0 FAKE_GUARD_INCOMPLETE=0 CC_ORCH_ALWAYS_FAST_MODE=1 FAKE_CORE_EXIT=7
  unset CC_ORCH_AUTO_ROUTE CC_ORCH_BACKEND
  case "$scenario" in
    lane) call+=(--lane b) ;;
    explicit) call+=(--model sol); expected=skipped:explicit-flags ;;
    fast) call+=(--fast-mode); export CC_ORCH_ALWAYS_FAST_MODE=0 ;;
    dry) call+=(--dry-run --model sol); expected=skipped:dry-run ;;
    withheld) export FAKE_GUARD_WITHHOLD=1; expected=skipped:withheld ;;
    resume) call=(resume "$WORK" "$TASK" msg); expected=skipped:resume ;;
    review) call=(review "$WORK" "$TASK"); expected=none ;;
    no-route) export CC_ORCH_AUTO_ROUTE=0; expected=skipped:no-route ;;
    guard-error) export FAKE_GUARD_ERROR=1; expected=skipped:no-route ;;
    incomplete) export FAKE_GUARD_INCOMPLETE=1; expected=skipped:no-route ;;
    codex-only) export CC_ORCH_BACKEND=codex; expected=none ;;
    policy-directory) mkdir "$TMP/policy-directory"; expected=none ;;
    policy-fifo) mkfifo "$TMP/policy-fifo"; expected=none ;;
    empty-workdir) call[1]=""; expected=skipped:invalid-args ;;
    empty-task-dir) call[2]=""; expected=skipped:invalid-args ;;
  esac
  export CC_ORCH_JEV_POLICY="$TMP/policy-0"
  if [ "$BASELINE" = 1 ]; then capture baseline "$HARNESS/bin/codex-run-runtime.baseline" "${call[@]}"; fi
  capture off "$HARNESS/bin/codex-run-runtime" "${call[@]}"
  if [ "$BASELINE" = 1 ]; then compare baseline off; fi
  export CC_ORCH_JEV_POLICY="$TMP/policy-1"
  case "$scenario" in
    policy-directory|policy-fifo)
      export CC_ORCH_JEV_POLICY="$TMP/$scenario"
      capture on timeout 5 "$HARNESS/bin/codex-run-runtime" "${call[@]}"
      ;;
    *) capture on "$HARNESS/bin/codex-run-runtime" "${call[@]}" ;;
  esac
  compare off on
  if [ "$expected" != none ]; then wait_records 1; fi
  check_orphans
  python3 - "$CC_ORCH_STATE_DIR" "$scenario" "$expected" <<'PY'
import json, sys
from pathlib import Path
state, scenario, expected = Path(sys.argv[1]), *sys.argv[2:]
if expected == 'none':
    assert not (state / 'codex-shadow.jsonl').exists()
else:
    rows = [json.loads(line) for line in (state / 'codex-shadow.jsonl').read_text().splitlines()]
    assert len(rows) == 1, rows
    row = rows[0]
    assert row['status'] == expected, row
    assert row['mode'] == ('resume' if scenario == 'resume' else 'implement'), row
    assert row['lane'] == ('b' if scenario == 'lane' else 'implement'), row
    if scenario in ('normal', 'lane', 'fast'):
        assert (row['initial_model'], row['initial_effort'], row['pressure']) == ('gpt-6-astra', 'xhigh', 'healthy'), row
        assert row['initial_fast_mode'] is True, row
    assert not (state / 'jev.log').exists()
PY
  ok "baseline/off/on byte identity and record: $scenario"
done
unset CC_ORCH_AUTO_ROUTE CC_ORCH_BACKEND FAKE_GUARD_WITHHOLD FAKE_GUARD_ERROR FAKE_GUARD_INCOMPLETE
export CC_ORCH_ALWAYS_FAST_MODE=1 FAKE_CORE_EXIT=0

# Probe once and keep the fake server alive for all transport timing cases. Its request
# log keeps only whether Authorization matched, never the header value itself.
cat > "$TMP/server.py" <<'PY'
import http.server, json, socket, sys, time
from pathlib import Path
base = Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        mode = self.path.strip('/')
        body = self.rfile.read(int(self.headers['Content-Length']))
        expected = 'shadow-key-' + 'sentinel'
        assert expected.encode() not in body
        with (base / 'requests').open('a') as stream:
            stream.write(json.dumps({'body': json.loads(body), 'auth_ok': self.headers.get('Authorization') == 'Bearer ' + expected}) + '\n')
        try:
            if mode == 'hang': time.sleep(5)
            self.send_response(int(mode) if mode.isdigit() else 200)
            self.end_headers()
            self.wfile.write(b'not json')
        except (BrokenPipeError, ConnectionResetError): pass
try:
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    with socket.socket() as unused:
        unused.bind(('127.0.0.1', 0))
        refused = unused.getsockname()[1]
    (base / 'ports').write_text(f'{server.server_port} {refused}\n')
except OSError as error:
    (base / 'bind-error').write_text(str(error))
    sys.exit(0)
server.serve_forever()
PY
python3 "$TMP/server.py" "$TMP" &
SERVER_PID=$!
for ((i=0;i<100;i++)); do
  [ -s "$TMP/ports" ] || [ -s "$TMP/bind-error" ] || { sleep 0.05; continue; }
  break
done
behaviours=(no-key)
if [ -s "$TMP/ports" ]; then
  read -r port refused < "$TMP/ports"
  behaviours+=(hang refused 401 429 529 malformed)
else
  [ -s "$TMP/bind-error" ] || fail "fake server did not start"
  echo "skip: loopback bind denied — $(cat "$TMP/bind-error")"
  wait "$SERVER_PID"; SERVER_PID=""
fi
for behaviour in "${behaviours[@]}"; do
  export CC_ORCH_STATE_DIR="$TMP/timing-$behaviour"
  mkdir -p "$CC_ORCH_STATE_DIR"
  cp "$TMP/policy-1" "$TMP/timing-policy"
  export CC_ORCH_JEV_POLICY="$TMP/timing-policy"
  unset TYPESAFE_API_KEY
  expected='unavailable:no key'
  if [ "$behaviour" != no-key ]; then
    export TYPESAFE_API_KEY="shadow-key-sentinel"
    endpoint="http://127.0.0.1:$port/$behaviour"
    case "$behaviour" in
      hang) expected=unavailable:timeout ;;
      refused) endpoint="http://127.0.0.1:$refused/"; expected=unavailable:network ;;
      401) expected='unavailable:auth (HTTP 401)' ;;
      429) expected='unavailable:rate limit (HTTP 429)' ;;
      529) expected='unavailable:overloaded (HTTP 529)' ;;
      malformed) expected='unavailable:malformed response' ;;
    esac
    printf 'JEV_ENDPOINT="%s"\n' "$endpoint" >> "$TMP/timing-policy"
  fi
  : > "$TMP/times-off"; : > "$TMP/times-on"
  for enabled in 0 1; do
    printf 'JEV_SHADOW_ENABLED=%s\n' "$enabled" >> "$TMP/timing-policy"
    if [ "$enabled" = 1 ]; then on_start="$EPOCHREALTIME"; fi
    for ((i=0;i<5;i++)); do
      start="$EPOCHREALTIME"
      "$HARNESS/bin/codex-run-runtime" implement "$WORK" "$TASK" > "$TMP/timing.out" 2> "$TMP/timing.err"
      end="$EPOCHREALTIME"
      if [ "$enabled" = 0 ]; then label=off; else label=on; fi
      printf '%s %s\n' "$start" "$end" >> "$TMP/times-$label"
    done
  done
  wait_records 5
  check_orphans 6
  python3 - "$TMP" "$behaviour" "$expected" "$on_start" "$EPOCHREALTIME" <<'PY'
import json, sys
from pathlib import Path
base, behaviour, expected = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if behaviour == 'hang': assert float(sys.argv[5]) - float(sys.argv[4]) < 6
def minimum(label):
    return min(float(end) - float(start) for start, end in
               (line.split() for line in (base / ('times-' + label)).read_text().splitlines()))
off, on = minimum('off'), minimum('on')
print(f'timing {behaviour}: min_off={off:.6f}s min_on={on:.6f}s added={on - off:.6f}s')
assert on - off < .150
state = base / ('timing-' + behaviour)
rows = [json.loads(line) for line in (state / 'codex-shadow.jsonl').read_text().splitlines()]
assert len(rows) == 5
assert all(row['status'] == expected for row in rows), rows
for path in (state / 'codex-shadow.jsonl', state / 'guard.log', base / 'requests'):
    if path.exists(): assert 'shadow-key-sentinel' not in path.read_text()
if (base / 'requests').exists():
    assert all(json.loads(line)['auth_ok'] for line in (base / 'requests').read_text().splitlines())
PY
  ok "non-blocking timing, status, privacy, no orphans: $behaviour"
done
unset TYPESAFE_API_KEY

# Real facade and core, PATH-shim Codex. Sleep briefly so session snapshots precede completion.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN" "$TMP/catalog" "$TMP/unknown-catalog"
cat > "$TMP/catalog/models_cache.json" <<'JSON'
{"fetched_at":"2026-09-04T08:00:00Z","models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"xhigh"}],"additional_speed_tiers":["fast"]},{"slug":"gpt-5.6-sol","supported_reasoning_levels":[{"effort":"xhigh"}],"additional_speed_tiers":["fast"]}]}
JSON
cat > "$FAKEBIN/codex" <<'CORE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FAKE_CODEX_ARGS"
model="" output=""
while [ $# -gt 0 ]; do
  case "$1" in -m) shift; model="${1:-}" ;; -o) shift; output="${1:-}" ;; esac
  shift || true
done
sleep 0.4
if [ "${FAKE_CODEX_ERROR_STYLE:-}" = failure ]; then
  echo 'ERROR: stream disconnected' >&2
  exit 1
fi
if [ "${FAKE_CODEX_ERROR_STYLE:-}" = not-supported ] && [ "$model" = gpt-6-astra ]; then
  printf '%s\n' 'ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"This model is not supported when using Codex with a ChatGPT account."}}' >&2
  exit 1
fi
printf '%s\n' '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}'
printf 'ok\n' > "$output"
CORE
cat > "$FAKEBIN/claude" <<'CORE'
#!/usr/bin/env bash
printf '%s\n' 'Current session: 10% used' 'Current week (all models): 20% used' 'Current week (Fable): 20% used'
CORE
chmod +x "$FAKEBIN/"*
export PATH="$FAKEBIN:$PATH" CLAUDE_BIN="$FAKEBIN/claude" FAKE_CODEX_ARGS="$TEST_ARGS"
for scenario in success failure fallback; do
  export CODEX_HOME="$TMP/catalog" FAKE_CODEX_ERROR_STYLE="$scenario"
  if [ "$scenario" = fallback ]; then export CODEX_HOME="$TMP/unknown-catalog" FAKE_CODEX_ERROR_STYLE=not-supported; fi
  export CC_ORCH_STATE_DIR="$TMP/real-$scenario"
  for enabled in 0 1; do
    rm -rf "$CC_ORCH_STATE_DIR"
    mkdir -p "$CC_ORCH_STATE_DIR"
    rm -f "$TASK/.codex-session"
    cp "$TMP/policy-$enabled" "$TMP/real-policy"
    printf 'JEV_SHADOW_TIMEOUT_SECONDS=5\n' >> "$TMP/real-policy"
    export CC_ORCH_JEV_POLICY="$TMP/real-policy"
    capture "real-$enabled" "$ROOT/bin/codex-run-runtime" implement "$WORK" "$TASK"
    if [ "$enabled" = 1 ]; then wait_records 1; check_orphans; fi
  done
  compare real-0 real-1
  python3 - "$CC_ORCH_STATE_DIR" "$TASK" "$scenario" <<'PY'
import json, re, sys
from pathlib import Path
state, task, scenario = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
lines = (state / 'codex.log').read_text().splitlines()
row, = [json.loads(line) for line in (state / 'codex-shadow.jsonl').read_text().splitlines()]
last = re.search(r'  (\S+)@([^ +]+)(\+fast-mode)?(?: \(fallback-from:(\S+)\))?  exit=(-?\d+)', lines[-1])
assert last, lines
assert (row['final_model'], row['final_effort']) == (last[1], last[2]), row
assert row['final_fast_mode'] == bool(last[3]), row
assert row['codex_exit'] == int(last[5]), row
assert row['attempts'] == len(lines) == (2 if scenario == 'fallback' else 1), row
assert row['observation'] == 'exact', row
if scenario != 'failure':
    session = (task / '.codex-session').read_text().split('=', 1)[1].split('|')[0]
    assert row['thread_id'] == session, row
if scenario == 'fallback': assert row['final_fallback_from'] == 'gpt-6-astra', row
PY
  if [ "$scenario" = fallback ]; then assert_has "$(cat "$TMP/real-1.err")" MODEL_FALLBACK "real fallback"; fi
  ok "real core off/on argv, stdout, stderr, exit, final observation: $scenario"
done
bash -n "$ROOT/bin/codex-run-runtime"
python3 -m py_compile "$ROOT/bin/orch-jev"
ok "shell and Python syntax"
echo "all $pass Jev shadow e2e checks passed"
