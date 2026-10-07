#!/usr/bin/env bash
set -euo pipefail
export CC_ORCH_CLI_AUTO_UPDATE=0 # Fake providers: no network or package mutation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_DIR="$TMP/home"
FAKEBIN="$TMP/fakebin"
STATE="$TMP/state"
NAME="reloadt$$"
LIVE_PID=""

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $((++pass)) - $*"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' ($3)"; }
assert_not_has() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' ($3)"; }

stop_live() {
  if [[ -n "$LIVE_PID" ]]; then
    # The private cleanup signal also stops the TERM-ignoring fixture and reaps its sleeper.
    if [[ -e "$TMP/live-ready" ]]; then
      kill -USR1 "$LIVE_PID" 2>/dev/null || true
    else
      kill -KILL "$LIVE_PID" 2>/dev/null || true
    fi
    wait "$LIVE_PID" 2>/dev/null || true
    LIVE_PID=""
  fi
}
trap 'stop_live; rm -rf "$TMP"' EXIT

mkdir -p "$HOME_DIR/.claude/agents" "$FAKEBIN" "$STATE"
ln -s "$ROOT" "$HOME_DIR/.claude/orchestra"
ln -s "$ROOT/agents/orchestrator.md" "$HOME_DIR/.claude/agents/orchestrator.md"
cat > "$STATE/state" <<'EOF'
active=sonnet[1m]
pinned=0
reason=test
EOF
cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/claude-args"
EOF
cat > "$FAKEBIN/claude-live" <<EOF
#!/usr/bin/env bash
sleeper=""
cleanup() {
  if [[ -n "\$sleeper" ]]; then
    kill "\$sleeper" 2>/dev/null || true
    wait "\$sleeper" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 0' USR1
if [[ "\$1" = ignore ]]; then
  trap '' TERM
else
  trap 'echo TERM > "$TMP/live-signal"; exit 0' TERM
fi
: > "$TMP/live-ready"
while :; do sleep 0.2 & sleeper=\$!; wait "\$sleeper" || true; done
EOF
chmod +x "$FAKEBIN/claude" "$FAKEBIN/claude-live"

start_live() { # <cwd> <project-name> [term|ignore]; sets LIVE_PID
  [[ -z "$LIVE_PID" ]] || fail "previous live fixture was not stopped"
  rm -f "$TMP/live-signal" "$TMP/live-ready" "$TMP/claude-args"
  ( cd "$1" && exec bash "$FAKEBIN/claude-live" "${3:-term}" --agent orchestrator --name "orchestrator@$2" ) &
  LIVE_PID=$!
  for _ in $(seq 1 50); do
    if [[ -e "$TMP/live-ready" ]] && grep -qz -- '--agent' "/proc/$LIVE_PID/cmdline" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  fail "live fixture did not become ready"
}
run_reload() {
  RC=0
  OUT="$(cd "$TMP" && HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" CC_ORCH_STATE_DIR="$STATE" "$ROOT/bin/cc-orch" --no-rc "$@" 2>&1)" || RC=$?
}
assert_alive() {
  kill -0 "$LIVE_PID" 2>/dev/null || fail "$1: live process was stopped"
  [[ ! -e "$TMP/live-signal" ]] || fail "$1: TERM was sent"
  [[ ! -e "$TMP/claude-args" ]] || fail "$1: claude was launched"
}
assert_reloaded() {
  for _ in $(seq 1 50); do
    [[ -e "$TMP/live-signal" ]] && break
    sleep 0.1
  done
  assert_eq "$(cat "$TMP/live-signal" 2>/dev/null)" TERM "$1 TERM"
  assert_has "$(cat "$TMP/claude-args")" '-c' "$1 -c"
  wait "$LIVE_PID" 2>/dev/null || true
  ! kill -0 "$LIVE_PID" 2>/dev/null || fail "$1: still alive"
  LIVE_PID=""
  rm -f "$TMP/claude-args"
}
registry() { # <registry path> <status>...
  local path="$1" s
  shift
  mkdir -p "$(dirname "$path")"
  {
    printf '| slot | agentId | task | branch | dir | status | last update |\n|---|---|---|---|---|---|---|\n'
    for s in "$@"; do
      printf '| lead-alpha | a1b2c3d4e5f6 | T | orch/x | .orchestra/01/ | %s | now |\n' "$s"
    done
  } > "$path"
}
git_fixture() { # <repo> [linked worktree]; no writing Git commands needed
  local repo="$1" common="$1/.git" tree="${2:-}" admin
  mkdir -p "$common/objects" "$common/refs/heads"
  printf 'ref: refs/heads/main\n' > "$common/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' > "$common/config"
  if [[ -n "$tree" ]]; then
    admin="$common/worktrees/wt"
    mkdir -p "$tree" "$admin"
    printf 'ref: refs/heads/wt\n' > "$admin/HEAD"
    printf '../..\n' > "$admin/commondir"
    printf '%s/.git\n' "$tree" > "$admin/gitdir"
    printf 'gitdir: %s\n' "$admin" > "$tree/.git"
  fi
}

bash -n "$ROOT/bin/cc-orch"
ok "shell syntax"

mkdir -p "$TMP/plain/deep"
start_live "$TMP/plain/deep" "$NAME"
run_reload --reload "$NAME"
assert_eq "$RC" 1 "R1 missing registry"
assert_has "$OUT" 'no .orchestra/REGISTRY.md found' "R1 refusal"
assert_has "$OUT" 'checked:' "R1 checked paths"
assert_has "$OUT" "$TMP/plain/deep/.orchestra/REGISTRY.md" "R1 cwd"
assert_has "$OUT" "$TMP/plain/.orchestra/REGISTRY.md" "R1 parent"
expected=""
p="$TMP/plain/deep"
while :; do
  expected+="  $p/.orchestra/REGISTRY.md"$'\n'
  [[ "$p" = / ]] && break
  p="$(dirname "$p")"
done
assert_eq "$(printf '%s\n' "$OUT" | sed -n '\|^  /|p')" "${expected%$'\n'}" "R1 every checked path in order without duplicates"
assert_not_has "$OUT" 'gracefully stopping' "R1 no stop attempt"
assert_alive R1
ok "R1 missing registry refuses and lists all checked paths"

run_reload --force-reload "$NAME"
assert_eq "$RC" 0 "R2 forced missing registry"
assert_has "$OUT" '--force-reload: no REGISTRY.md found' "R2 override notice"
assert_reloaded R2
assert_has "$(cat "$STATE/projects/$NAME")" "dir=$TMP/plain/deep" "R2 saved process cwd"
ok "R2 force reload overrides a missing registry"

mkdir -p "$TMP/anc/sub/deeper"
REG="$TMP/anc/.orchestra/REGISTRY.md"
registry "$REG" RUNNING
start_live "$TMP/anc/sub/deeper" "$NAME"
run_reload --reload "$NAME"
assert_eq "$RC" 1 "R3 active ancestor"
assert_has "$OUT" "active lead rows in $REG" "R3 ancestor registry"
assert_has "$OUT" '| lead-alpha | a1b2c3d4e5f6 | T | orch/x | .orchestra/01/ | RUNNING | now |' "R3 active row"
assert_alive R3
stop_live
ok "R3 ancestor registry blocks an active lead"

registry "$REG" 'PASS (done)' 'CLOSED - merged' FAIL BLOCKED ACCEPTED 'ACCEPTED (user, 2026-10-02)' IDLE UNASSIGNED 'PASS: merged'
start_live "$TMP/anc/sub/deeper" "$NAME"
run_reload --reload "$NAME"
assert_eq "$RC" 0 "R4 terminal statuses"
assert_reloaded R4
ok "R4 annotated and bare terminal statuses allow reload"

for status in 'PASS-ish' 'ACCEPTED-ish' PASSED RUNNING ''; do
  registry "$REG" "$status"
  start_live "$TMP/anc/sub/deeper" "$NAME"
  run_reload --reload "$NAME"
  assert_eq "$RC" 1 "R5 active status '$status'"
  assert_has "$OUT" "active lead rows in $REG" "R5 refusal"
  assert_has "$OUT" "| lead-alpha | a1b2c3d4e5f6 | T | orch/x | .orchestra/01/ | $status | now |" "R5 active row"
  assert_alive R5
  stop_live
done
ok "R5 lookalikes, RUNNING and empty status block reload"

git_fixture "$TMP/repo" "$TMP/repo-wt"
[[ ! -e "$TMP/.orchestra" ]] || fail "R6 fixture ancestor unexpectedly has .orchestra"
registry "$TMP/repo/.orchestra/REGISTRY.md" RUNNING
start_live "$TMP/repo-wt" "$NAME"
run_reload --reload "$NAME"
assert_eq "$RC" 1 "R6 common dir"
assert_has "$OUT" "active lead rows in $TMP/repo/.orchestra/REGISTRY.md" "R6 main checkout registry"
assert_alive R6
stop_live
ok "R6 linked checkout finds the git common directory registry"

mkdir -p "$TMP/repo-wt/.orchestra"
mv "$TMP/repo/.orchestra/REGISTRY.md" "$TMP/repo-wt/.orchestra/REGISTRY.md"
start_live "$TMP/repo" "$NAME"
run_reload --reload "$NAME"
assert_eq "$RC" 1 "R7 worktree list"
assert_has "$OUT" "active lead rows in $TMP/repo-wt/.orchestra/REGISTRY.md" "R7 linked checkout registry"
assert_alive R7
stop_live
ok "R7 worktree list finds the linked checkout registry"

if [[ "$(id -u)" = 0 ]]; then
  echo "SKIP R8: root can read a chmod 000 registry"
else
  registry "$REG" RUNNING
  chmod 000 "$REG"
  start_live "$TMP/anc/sub/deeper" "$NAME"
  run_reload --reload "$NAME"
  assert_eq "$RC" 1 "R8 unreadable registry"
  assert_has "$OUT" "registry $REG exists but is not readable" "R8 refusal"
  assert_alive R8
  run_reload --force-reload "$NAME"
  assert_eq "$RC" 0 "R8 forced unreadable registry"
  assert_has "$OUT" "--force-reload: unreadable $REG; proceeding" "R8 override notice"
  assert_reloaded R8
  chmod 600 "$REG"
  ok "R8 unreadable registry refuses unless forced"
fi

mv "$TMP/repo-wt/.orchestra/REGISTRY.md" "$TMP/repo/.orchestra/REGISTRY.md"
git_fixture "$TMP/unrelated"
registry "$TMP/unrelated/.orchestra/REGISTRY.md" PASS
start_live "$TMP/repo-wt" "$NAME"
GIT_DIR="$TMP/unrelated/.git" GIT_WORK_TREE="$TMP/unrelated" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true run_reload --reload "$NAME"
assert_eq "$RC" 1 "R9 inherited git environment"
assert_has "$OUT" "active lead rows in $TMP/repo/.orchestra/REGISTRY.md" "R9 correct registry"
assert_not_has "$OUT" "$TMP/unrelated/.orchestra/REGISTRY.md" "R9 unrelated registry"
assert_alive R9
stop_live
ok "R9 inherited GIT variables cannot steer discovery"

registry "$REG" RUNNING
start_live "$TMP/anc/sub/deeper" "$NAME"
run_reload --force-reload "$NAME"
assert_eq "$RC" 0 "R10 forced active row"
assert_has "$OUT" "overriding active lead rows in $REG" "R10 override notice"
assert_reloaded R10
ok "R10 force reload overrides an active lead"

registry "$REG" 'PASS (done)'
start_live "$TMP/anc/sub/deeper" "$NAME" ignore
run_reload --reload "$NAME"
assert_eq "$RC" 1 "R11 TERM ignored"
assert_has "$OUT" 'did not stop after 10s; not sending SIGKILL' "R11 no SIGKILL"
assert_alive R11
stop_live
ok "R11 TERM-ignoring process survives reload timeout"

python3 - "$ROOT/bin/cc-orch" "$ROOT/bin/cc-orch-session" <<'PY'
import sys
from pathlib import Path

programs = [Path(path).read_bytes().split(b"awk -F'|' '", 1)[1].split(b"'", 1)[0]
            for path in sys.argv[1:]]
assert programs[0] == programs[1], 'reload and switch awk filters differ'
assert b'ACCEPTED' in programs[0], 'terminal filter lacks ACCEPTED'
PY
ok "R12 reload and switch awk filters are byte-identical and include ACCEPTED"

echo "PASS: $pass reload test groups"
