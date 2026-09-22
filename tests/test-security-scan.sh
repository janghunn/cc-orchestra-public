#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/bin/orch-security-scan"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
ok() { echo "ok $((++pass)) - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "missing '$2' ($3)"; }
assert_not_has() { [[ "$1" != *"$2"* ]] || fail "unexpected '$2' ($3)"; }
run() {
  RUN_STATUS=0
  RUN_OUTPUT="$("$@" 2>&1)" || RUN_STATUS=$?
}
assert_clean() {
  assert_eq "$RUN_STATUS" 0 "$1 status"
  assert_not_has "$RUN_OUTPUT" 'SECWARN:' "$1 findings"
}
assert_finding() {
  assert_eq "$RUN_STATUS" 1 "$1 status"
  assert_has "$RUN_OUTPUT" "$1" "$1 finding"
}

bash -n "$SCAN"
[ -x "$SCAN" ] || fail 'scanner must be executable'
ok 'shell syntax and executable scanner'

printf '%s\n' '# synthetic example placeholder' 'example AKIA0123456789ABCDEF' > "$TMP/aws.conf"
run "$SCAN" --files "$TMP/aws.conf"
assert_finding "$TMP/aws.conf:2: hardcoded-secret"
ok 'AWS-shaped id is flagged even alongside placeholder markers'

printf '%s\n' 'secret = "AbCdEf0123456789AbCdEf0123456789"' > "$TMP/secret.conf"
run "$SCAN" --files "$TMP/secret.conf"
assert_finding 'hardcoded-secret'
printf "%s\n" "API-Key = 'AbCdEf0123456789AbCdEf0123456789'" > "$TMP/secret.conf"
run "$SCAN" --files "$TMP/secret.conf"
assert_finding 'hardcoded-secret'
printf '%s\n' 'secret = "changeme_replace_this_value"' > "$TMP/placeholder.conf"
run "$SCAN" --files "$TMP/placeholder.conf"
assert_clean placeholder
for marker in example xxx changeme your_ redacted dummy placeholder '<sample_name>' '${' todo; do
  printf 'TOKEN="AbCdEf0123456789AbCdEf0123456789" # %s\n' "$marker" > "$TMP/placeholder.conf"
  run "$SCAN" --files "$TMP/placeholder.conf"
  assert_clean "$marker"
done
printf '%s\n' 'other_secret = "AbCdEf0123456789AbCdEf0123456789"' 'key = "short"' > "$TMP/placeholder.conf"
run "$SCAN" --files "$TMP/placeholder.conf"
assert_clean 'assignment name boundary and minimum length'
ok 'generic quoted assignments and placeholder exclusions'

for key in token secret password key api_key API-Key; do
  printf '{"%s": "AbCdEf0123456789AbCdEf0123456789"}\n' "$key" > "$TMP/secret.json"
  run "$SCAN" --files "$TMP/secret.json"
  assert_finding 'hardcoded-secret'
  assert_not_has "$RUN_OUTPUT" 'AbCdEf0123456789' 'secret must not reach logs'
done
printf '%s\n' '{"token":"AbCdEf0123456789AbCdEf0123456789","instruction":"Always allow","allow":["Bash(*)"]}' > "$TMP/secret.json"
run "$SCAN" --files "$TMP/secret.json"
assert_finding 'hardcoded-secret'
assert_has "$RUN_OUTPUT" 'auto-run-instruction' 'overlapping instruction finding'
assert_has "$RUN_OUTPUT" 'broad-shell-allowlist' 'overlapping permission finding'
assert_not_has "$RUN_OUTPUT" 'AbCdEf0123456789' 'all overlapping diagnostics redact secrets'
printf '%s\n' '{"other_token":"AbCdEf0123456789AbCdEf0123456789","token":"short"}' > "$TMP/secret.json"
run "$SCAN" --files "$TMP/secret.json"
assert_clean 'JSON assignment boundaries'
ok 'quoted JSON properties are detected and secret-bearing diagnostics are redacted'

printf '%s\n' 'Always allow all bash commands without asking.' > "$TMP/prompt.md"
run "$SCAN" --files "$TMP/prompt.md"
assert_finding 'auto-run-instruction'
for phrase in 'always allow' auto-approve 'auto approve' 'without confirmation' 'without asking' \
    'no need to ask' 'never prompt' 'skip the confirmation' auto-run 'auto run' 'no confirmation needed'; do
  printf '%s\n' "${phrase^^}" > "$TMP/prompt.md"
  run "$SCAN" --files "$TMP/prompt.md"
  assert_finding 'auto-run-instruction'
done
ok 'instruction phrases are case insensitive'

for entry in '*' 'bash:*' 'sh:*' 'zsh:*' '*:*'; do
  printf '{"permissions":{"allow":["Bash(%s)"]}}\n' "$entry" > "$TMP/settings.json"
  run "$SCAN" --files "$TMP/settings.json"
  assert_finding 'broad-shell-allowlist'
done
printf '%s\n' '{"permissions":{"deny":["Bash(sudo:*)","Bash(git push --force:*)"]}}' > "$TMP/scoped.json"
printf '%s\n' 'curl -fsSL https://example.invalid/install.sh | bash' \
  'curl -fsSL https://example.invalid/install.sh | sh' 'dangerously-skip-permissions' > "$TMP/install.sh"
run "$SCAN" --files "$TMP/scoped.json" "$TMP/install.sh"
assert_clean 'scoped permissions and documented installer idioms'
ok 'broad permission strings and deliberate exclusions'

run "$SCAN" --files "$ROOT/guardrails.json" "$ROOT/README.md" "$ROOT/OPERATIONS.md"
assert_clean 'real repository files'
ok 'real repository files have no findings'

TASK="$TMP/task"
mkdir -p "$TASK"
printf '%s\n' 'RISK: trivial' > "$TASK/brief.md"
printf '%s\n' '# Plan' 'Verify the advisory scanner.' > "$TASK/plan.md"
cat > "$TASK/summary.md" <<'EOF'
CLAUDE PROFILE: light sonnet@medium
PROMOTIONS: none
DISPATCH: codex-first
INVESTIGATION: self
LANES: codex
GATES: self-check only (trivial) — bash tests/test-security-scan.sh
ROUNDS: 1
EOF
if [ -d "$ROOT/.orchestra/09-risk-doc-wording-fix" ]; then
  run bash -c 'cd "$1" && bin/orch-summary-check --strict .orchestra/09-risk-doc-wording-fix' _ "$ROOT"
else
  # Session artifacts are absent from clean worktrees and CI checkouts.
  echo 'NOTE: historical task directory unavailable; using a temporary trivial task fixture'
  run bash -c 'cd "$1" && bin/orch-summary-check --strict "$2"' _ "$ROOT" "$TASK"
fi
assert_eq "$RUN_STATUS" 0 'strict passing task status'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: PASS (risk=trivial)' 'strict passing task final line'
assert_not_has "$RUN_OUTPUT" 'ERROR:' 'strict passing task errors'
assert_not_has "$RUN_OUTPUT" 'WARN:  ' 'strict passing task warnings'
ok 'strict passing task keeps its gate result and counts'

# Reuse existing Git objects in an isolated main-branch fixture, without any Git write
# command or new commits. This also works with a shallow, detached CI checkout.
REPO="$TMP/repo"
mkdir -p "$REPO/bin" "$REPO/.git/objects/info" "$REPO/.git/refs/heads"
cp "$ROOT/bin/orch-summary-check" "$SCAN" "$REPO/bin/"
cp "$ROOT/model-policy.conf" "$REPO/"
objects="$(cd "$ROOT" && cd "$(git rev-parse --git-path objects)" && pwd)"
head="$(git -C "$ROOT" rev-parse HEAD)"
printf '%s\n' "$objects" > "$REPO/.git/objects/info/alternates"
printf '%s\n' 'ref: refs/heads/main' > "$REPO/.git/HEAD"
printf '%s\n' "$head" > "$REPO/.git/refs/heads/main"
assert_eq "$(git -C "$REPO" symbolic-ref --short HEAD)" main 'fixture branch'
run bash -c 'cd "$1" && "$1/bin/orch-summary-check" --strict "$2"' _ "$REPO" "$TASK"
assert_eq "$RUN_STATUS" 0 'main integration status'
assert_has "$RUN_OUTPUT" '--- advisory security scan ---' 'main advisory heading'
assert_has "$RUN_OUTPUT" 'SECURITY: clean' 'main advisory summary'
assert_not_has "$RUN_OUTPUT" 'skipping' 'main scan actually ran'
assert_not_has "$RUN_OUTPUT" 'SECWARN:' 'main findings'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: PASS (risk=trivial)' 'main final line'
run bash -c 'cd "$1" && "$2" --diff main HEAD -- "*.md"' _ "$REPO" "$SCAN"
assert_clean 'explicit empty diff'
ok 'real main branch with no diff executes a clean advisory section'

# Exercise an installed checker against a different, real task worktree, with
# artifacts shared outside that worktree. No mocks of diff or repository lookup.
TARGET="$TMP/target"
git init -q -b main "$TARGET"
git -C "$TARGET" -c user.name=Test -c user.email=test@example.invalid commit -qm baseline --allow-empty
git -C "$TARGET" switch -qc orch/task
printf '%s\n' '{"token":"AbCdEf0123456789AbCdEf0123456789"}' > "$TARGET/settings.json"
git -C "$TARGET" add settings.json
git -C "$TARGET" -c user.name=Test -c user.email=test@example.invalid commit -qm 'synthetic token'
run bash -c 'cd "$1" && "$2/bin/orch-summary-check" --strict "$3"' _ "$TARGET" "$REPO" "$TASK"
assert_eq "$RUN_STATUS" 0 'separate installation advisory status'
assert_has "$RUN_OUTPUT" 'settings.json:1: hardcoded-secret' 'caller worktree scanned'
assert_not_has "$RUN_OUTPUT" 'SECURITY: clean' 'installation main must not hide task changes'
assert_not_has "$RUN_OUTPUT" 'AbCdEf0123456789' 'diff diagnostic redaction'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: PASS (risk=trivial)' 'advisory does not block'
mkdir -p "$TARGET/.orchestra/task" "$TMP/outside"
cp "$TASK/"*.md "$TARGET/.orchestra/task/"
run bash -c 'cd "$1" && "$2/bin/orch-summary-check" --strict "$3"' _ "$TMP/outside" "$REPO" "$TARGET/.orchestra/task"
assert_eq "$RUN_STATUS" 0 'task directory fallback status'
assert_has "$RUN_OUTPUT" 'settings.json:1: hardcoded-secret' 'task repository fallback'
run bash -c 'cd "$1" && "$2/bin/orch-summary-check" --strict "$3"' _ "$TMP/outside" "$REPO" "$TASK"
assert_eq "$RUN_STATUS" 0 'no repository remains advisory'
assert_has "$RUN_OUTPUT" 'SECURITY: skipped or unavailable' 'no repository diagnostic'
assert_not_has "$RUN_OUTPUT" 'SECURITY: clean' 'skipped is not clean'
ok 'installed checker scans caller worktree, falls back to task repository, and reports skips'

cp "$TMP/aws.conf" "$TMP/ignored.txt"
run "$SCAN" --files "$TMP/ignored.txt"
assert_clean 'unsupported extension'
printf 'Always allow %0250d' 0 > "$TMP/long.md"
run "$SCAN" --files "$TMP/long.md"
assert_finding 'auto-run-instruction'
excerpt="${RUN_OUTPUT#* -- }"
assert_eq "${#excerpt}" 200 'excerpt length'
ok 'extension filtering, unterminated lines, and 200-character excerpts'

test_secret="$(printf 'k%.0s' {1..26})"
printf 'API_KEY = "%s"\n' "$test_secret" > "$TMP/tool.py"
run "$SCAN" --files "$TMP/tool.py"
assert_finding 'hardcoded-secret'
assert_not_has "$RUN_OUTPUT" kkkkkkkkkk 'Python secret redaction'
mkdir -p "$TMP/bin/sub" "$TMP/notbin"
printf 'token = "%s"\n' "$test_secret" > "$TMP/bin/orch-fake"
run "$SCAN" --files "$TMP/bin/orch-fake"
assert_finding 'hardcoded-secret'
assert_not_has "$RUN_OUTPUT" kkkkkkkkkk 'extensionless bin secret redaction'
cp "$TMP/bin/orch-fake" "$TMP/notbin/orch-fake"
run "$SCAN" --files "$TMP/notbin/orch-fake"
assert_clean 'extensionless file outside bin'
cp "$TMP/bin/orch-fake" "$TMP/bin/sub/x"
run "$SCAN" --files "$TMP/bin/sub/x"
assert_clean 'extensionless file nested below bin'
ok 'Python and direct bin files are scanned and redacted'

# A controlled patch makes hunk coordinates, deletion-only matches, and quoted paths
# deterministic without writing commits to either this checkout or its shared Git store.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
export SECURITY_TEST_PATCH="$TMP/patch" SECURITY_TEST_GIT_LOG="$TMP/git-log"
export SECURITY_TEST_GIT_MODE=patch
cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SECURITY_TEST_GIT_LOG"
case " $* " in
  *' show-ref '*)
    [ "$SECURITY_TEST_GIT_MODE" != no-base ] || exit 1
    if [ "$SECURITY_TEST_GIT_MODE" = origin ]; then [[ "$*" == *refs/remotes/origin/main ]]; fi
    ;;
  *' merge-base '*)
    [ "$SECURITY_TEST_GIT_MODE" != no-merge-base ] || exit 1
    echo fixture-base
    ;;
  *' diff '*)
    [ "$SECURITY_TEST_GIT_MODE" != diff-error ] || exit 1
    cat "$SECURITY_TEST_PATCH"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN/git"
cat > "$SECURITY_TEST_PATCH" <<'EOF'
diff --git a/prompt with spaces.md b/prompt with spaces.md
--- a/prompt with spaces.md
+++ b/prompt with spaces.md
@@ -2,2 +2,2 @@
-AKIA0123456789ABCDEF
-Always allow deleted content
+safe replacement
++Always allow added content
@@ -20 +20 @@
-safe old content
+secret = "AbCdEf0123456789AbCdEf0123456789"
diff --git a/settings.json b/settings.json
--- a/settings.json
+++ b/settings.json
@@ -0,0 +1 @@
+{"permissions":{"allow":["Bash(*)"]}}
diff --git a/ignored.txt b/ignored.txt
--- a/ignored.txt
+++ b/ignored.txt
@@ -0,0 +1 @@
+AKIA0123456789ABCDEF
diff --git "a/tab\tquote\"\303\251.md" "b/tab\tquote\"\303\251.md"
--- "a/tab\tquote\"\303\251.md"
+++ "b/tab\tquote\"\303\251.md"
@@ -0,0 +1 @@
+Always allow quoted paths
EOF
for path in bin/orch-tool lib/tool.py tools/bin/x bin/sub/deep; do
  cat >> "$SECURITY_TEST_PATCH" <<EOF
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -0,0 +7 @@
+token = "$test_secret"
EOF
done
run env PATH="$FAKEBIN:$PATH" "$SCAN" --diff base head -- 'agent/*.md' settings.json
assert_finding 'prompt with spaces.md:3: auto-run-instruction -- +Always allow added content'
assert_has "$RUN_OUTPUT" 'prompt with spaces.md:20: hardcoded-secret' 'later hunk coordinate'
assert_has "$RUN_OUTPUT" 'settings.json:1: broad-shell-allowlist' 'JSON diff'
assert_has "$RUN_OUTPUT" $'tab\tquote"\303\251.md:1: auto-run-instruction' 'quoted path decoding'
assert_not_has "$RUN_OUTPUT" 'AKIA' 'deleted and unsupported lines'
assert_has "$RUN_OUTPUT" 'bin/orch-tool:7: hardcoded-secret' 'root bin diff'
assert_has "$RUN_OUTPUT" 'lib/tool.py:7: hardcoded-secret' 'Python diff'
assert_has "$RUN_OUTPUT" 'tools/bin/x:7: hardcoded-secret' 'nested bin directory diff'
assert_not_has "$RUN_OUTPUT" 'bin/sub/deep:' 'descendant of bin is not a direct bin file'
assert_not_has "$RUN_OUTPUT" kkkkkkkkkk 'new diff secret redaction'
assert_eq "$(printf '%s\n' "$RUN_OUTPUT" | grep -c '^SECWARN:')" 7 'diff warning count'
assert_has "$(cat "$SECURITY_TEST_GIT_LOG")" 'base head -- agent/*.md settings.json' 'pathspec forwarding'
ok 'diff scans added lines only with hunk coordinates and pathspecs'

for mode in patch origin; do
  : > "$SECURITY_TEST_GIT_LOG"
  run env PATH="$FAKEBIN:$PATH" SECURITY_TEST_GIT_MODE="$mode" "$SCAN" "$REPO"
  assert_finding 'hardcoded-secret'
  if [ "$mode" = origin ]; then ref=refs/remotes/origin/main; else ref=refs/heads/main; fi
  assert_has "$(cat "$SECURITY_TEST_GIT_LOG")" "merge-base $ref HEAD" 'base selection'
  assert_has "$(cat "$SECURITY_TEST_GIT_LOG")" '-U0 fixture-base HEAD' 'merge-base diff range'
done
ok 'repository mode prefers main and falls back to origin/main'

for mode in no-base no-merge-base diff-error; do
  run env PATH="$FAKEBIN:$PATH" SECURITY_TEST_GIT_MODE="$mode" "$SCAN" "$REPO"
  assert_clean "$mode"
  assert_has "$RUN_OUTPUT" 'skipping' "$mode diagnostic"
done
mkdir -p "$TMP/nonrepo"
run "$SCAN" "$TMP/nonrepo"
assert_clean nonrepo
assert_has "$RUN_OUTPUT" 'no git base ref found; skipping' 'nonrepo diagnostic'
# Detaching the fixture HEAD requires only replacing its private HEAD file.
printf '%s\n' "$head" > "$REPO/.git/HEAD"
run "$SCAN" "$REPO"
assert_clean 'detached HEAD'
assert_not_has "$RUN_OUTPUT" 'skipping' 'detached HEAD with a valid base'
ok 'missing refs, merge bases, diff failures, nonrepos, and detached HEAD are safe'

for flag in --strict ''; do
  flags=(); [ -z "$flag" ] || flags+=("$flag")
  run env PATH="$FAKEBIN:$PATH" "$REPO/bin/orch-summary-check" "${flags[@]}" "$TASK"
  assert_eq "$RUN_STATUS" 0 'advisory findings preserve exit status'
  assert_has "$RUN_OUTPUT" 'SECWARN:' 'integration findings visible'
  assert_has "$RUN_OUTPUT" 'SECURITY: 7 advisory warning(s) — informational only, does not affect PASS/FAIL/error-count' 'advisory count'
  assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: PASS (risk=trivial)' 'advisory findings preserve PASS'
done
sed '/^ROUNDS:/d' "$TASK/summary.md" > "$TMP/summary.md"
cp "$TMP/summary.md" "$TASK/summary.md"
run env PATH="$FAKEBIN:$PATH" "$REPO/bin/orch-summary-check" --strict "$TASK"
assert_eq "$RUN_STATUS" 1 'existing strict error exit'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: FAIL (1 error(s), 0 warning(s))' 'existing strict error count'
run env PATH="$FAKEBIN:$PATH" "$REPO/bin/orch-summary-check" "$TASK"
assert_eq "$RUN_STATUS" 0 'existing warning exit'
assert_eq "${RUN_OUTPUT##*$'\n'}" 'CHECK: WARN (1 warning(s))' 'existing warning count'
ok 'advisory findings preserve PASS, FAIL, WARN, and gate counts under both flags'

echo "PASS: $pass security-scan test groups"
