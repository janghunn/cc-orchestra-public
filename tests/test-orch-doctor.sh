#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CC_ORCH_STATE_DIR="$TMP/state"
unset CC_ORCH_MANIFEST CC_ORCH_MANIFEST_NO_COMMIT
DOCTOR="$ROOT/bin/orch-doctor"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $((++pass)) - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1' ($3)"; }
assert_has() { printf '%s\n' "$1" | grep -qF -- "$2" || fail "missing '$2' ($3)"; }
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
hash() { sha256sum < "$1" | awk '{print $1}'; }
fixture_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
fixture_entry() { # dest template template-sha output-sha commit
  printf '{"dest":"%s","template":"%s","template_sha256":"%s","sha256":"%s","commit":"%s"}\n' \
    "$(fixture_escape "$1")" "$(fixture_escape "$2")" "$3" "$4" "$5"
}
run_doctor() {
  rc=0
  out="$("$DOCTOR" "$@" 2>&1)" || rc=$?
}
assert_complete() {
  local manifest="$1" count="$2" line dest template
  assert_eq "$(wc -l < "$manifest" | tr -d '[:space:]')" "$count" "manifest entry count"
  assert_eq "$(sed -n 's/.*"dest":"\([^"]*\)".*/\1/p' "$manifest" | sort -u | wc -l | tr -d '[:space:]')" \
    "$count" "unique destinations"
  while IFS= read -r line; do
    dest="$(field "$line" dest)"
    template="$(field "$line" template)"
    [[ "$dest" == /* ]] || fail "destination must be absolute: $dest"
    [[ "$template" == templates/*.tpl ]] || fail "template must be repo-relative: $template"
    assert_eq "$(field "$line" sha256)" "$(hash "$dest")" "installed bytes: $dest"
    assert_eq "$(field "$line" template_sha256)" "$(hash "$ROOT/$template")" "template bytes: $template"
    assert_eq "$(field "$line" commit)" "$COMMIT" "render commit"
  done < "$manifest"
}

bash -n "$DOCTOR"
ok "doctor shell syntax"

CC_ORCH_AGENTS_DIR="$TMP/core-agents" "$ROOT/build-roster.sh" >/dev/null
assert_complete "$TMP/core-agents/.install-manifest.json" 22
CC_ORCH_AGENTS_DIR="$TMP/core-agents" run_doctor
assert_eq "$rc" 0 "core all-clear and CC_ORCH_AGENTS_DIR default"
assert_has "$out" 'SUMMARY: 22 entries, 22 ok, 0 missing, 0 drifted, 0 stale-template, 0 repo-version-mismatch' "core summary"
ok "standalone manifest: 22 unique entries with independent output/template hashes"

CC_ORCH_AGENTS_DIR="$TMP/runtime-agents" "$ROOT/build-roster-runtime.sh" >/dev/null
MANIFEST="$TMP/runtime-agents/.install-manifest.json"
assert_complete "$MANIFEST" 38
run_doctor "$MANIFEST"
assert_eq "$rc" 0 "runtime all-clear"
assert_eq "$(printf '%s\n' "$out" | grep -c '^OK ')" 38 "runtime OK count"
if printf '%s\n' "$out" | grep -Eq '^(MISSING|DRIFTED|STALE-TEMPLATE|REPO-VERSION-MISMATCH) '; then
  fail "fresh runtime install has problem markers"
fi
assert_has "$out" 'SUMMARY: 38 entries, 38 ok, 0 missing, 0 drifted, 0 stale-template, 0 repo-version-mismatch' "runtime summary"
[[ ! -e "$MANIFEST.building" ]] || fail "runtime staging file left after publish"
ok "runtime manifest: 38 unique entries with independent hashes and all-clear"

CC_ORCH_AGENTS_DIR="$TMP/runtime-agents" "$ROOT/build-roster.sh" >/dev/null
assert_complete "$MANIFEST" 22
[[ -f "$TMP/runtime-agents/route-lead-alpha-light.md" ]] || fail "standalone rebuild removed route profile"
ok "standalone rebuild replaces tracked set with 22 entries and preserves route files"

printf A > "$TMP/A"
printf B > "$TMP/B"
A_SHA="$(hash "$TMP/A")"
B_SHA="$(hash "$TMP/B")"
TEMPLATE=templates/lead.md.tpl
TEMPLATE_SHA="$(hash "$ROOT/$TEMPLATE")"
OLD_COMMIT=deadbeedeadbeedeadbeedeadbeedeadbeedeadbeed
fixture_entry "$TMP/never-created" "$TEMPLATE" "$TEMPLATE_SHA" "$A_SHA" "$COMMIT" > "$TMP/missing.json"
fixture_entry "$TMP/A" "$TEMPLATE" "$TEMPLATE_SHA" "$B_SHA" "$COMMIT" > "$TMP/drifted.json"
fixture_entry "$TMP/A" "$TEMPLATE" "$B_SHA" "$A_SHA" "$COMMIT" > "$TMP/stale.json"
fixture_entry "$TMP/A" "$TEMPLATE" "$TEMPLATE_SHA" "$A_SHA" "$OLD_COMMIT" > "$TMP/mismatch.json"
for item in missing:MISSING drifted:DRIFTED stale:STALE-TEMPLATE mismatch:REPO-VERSION-MISMATCH; do
  run_doctor "$TMP/${item%%:*}.json"
  assert_eq "$rc" 1 "${item%%:*} fixture exit"
  assert_has "$out" "${item#*:} $TMP/" "${item%%:*} classification"
  ok "synthetic ${item%%:*} fixture"
done
cat "$TMP/missing.json" "$TMP/drifted.json" "$TMP/stale.json" "$TMP/mismatch.json" > "$TMP/combined.json"
run_doctor "$TMP/combined.json"
assert_eq "$rc" 1 "combined fixture exit"
for marker in MISSING DRIFTED STALE-TEMPLATE REPO-VERSION-MISMATCH; do
  assert_has "$out" "$marker $TMP/" "combined fixture"
done
assert_has "$out" 'SUMMARY: 4 entries, 0 ok, 1 missing, 1 drifted, 1 stale-template, 1 repo-version-mismatch' "combined summary"
ok "all four synthetic problems in one manifest"

fixture_entry "$TMP/never-created" "$TEMPLATE" "$B_SHA" "$B_SHA" "$OLD_COMMIT" > "$TMP/precedence.json"
fixture_entry "$TMP/A" "$TEMPLATE" "$B_SHA" "$B_SHA" "$OLD_COMMIT" >> "$TMP/precedence.json"
fixture_entry "$TMP/A" "$TEMPLATE" "$B_SHA" "$A_SHA" "$OLD_COMMIT" >> "$TMP/precedence.json"
run_doctor "$TMP/precedence.json"
assert_eq "$rc" 1 "classification precedence exit"
assert_has "$out" 'SUMMARY: 3 entries, 0 ok, 1 missing, 1 drifted, 1 stale-template, 0 repo-version-mismatch' "classification precedence"
ok "classification precedence: missing, output drift, template drift, commit mismatch"

ESCAPED_AGENTS="$TMP/"'agents "quoted" \ and \"mixed"'
CC_ORCH_AGENTS_DIR="$ESCAPED_AGENTS" "$ROOT/build-roster-runtime.sh" >/dev/null
run_doctor "$ESCAPED_AGENTS/.install-manifest.json"
assert_eq "$rc" 0 "builder destination escaping"
assert_has "$out" "OK $ESCAPED_AGENTS/lead-alpha.md" "core writer path round-trip"
assert_has "$out" "OK $ESCAPED_AGENTS/route-lead-alpha-light.md" "runtime writer path round-trip"
# A copied doctor provides a disposable repo-relative template namespace without editing repo templates.
FIXTURE_REPO="$TMP/fixture-repo"
ESCAPED_TEMPLATE='templates/lead "quoted" \ and \"mixed".tpl'
mkdir -p "$FIXTURE_REPO/bin" "$FIXTURE_REPO/templates"
cp "$DOCTOR" "$FIXTURE_REPO/bin/orch-doctor"
printf A > "$FIXTURE_REPO/$ESCAPED_TEMPLATE"
fixture_entry "$ESCAPED_AGENTS/lead-alpha.md" "$ESCAPED_TEMPLATE" "$A_SHA" \
  "$(hash "$ESCAPED_AGENTS/lead-alpha.md")" unknown > "$TMP/escaped.json"
DOCTOR="$FIXTURE_REPO/bin/orch-doctor" run_doctor "$TMP/escaped.json"
assert_eq "$rc" 0 "quoted/backslashed destination and template round-trip"
assert_has "$out" "OK $ESCAPED_AGENTS/lead-alpha.md" "fixture path round-trip"
ok "quotes and backslashes round-trip through both builders and doctor paths"

CC_ORCH_AGENTS_DIR="$TMP/custom-agents" CC_ORCH_MANIFEST="$TMP/custom/manifest.json" \
  "$ROOT/build-roster-runtime.sh" >/dev/null
assert_complete "$TMP/custom/manifest.json" 38
CC_ORCH_MANIFEST="$TMP/custom/manifest.json" run_doctor
assert_eq "$rc" 0 "CC_ORCH_MANIFEST override"
CC_ORCH_MANIFEST="$TMP/does-not-exist" run_doctor "$TMP/custom/manifest.json"
assert_eq "$rc" 0 "explicit manifest overrides environment"
ok "custom manifest path and argument precedence"

# Fail precisely between the core and runtime renders, when the staged manifest has 22 entries.
mkdir -p "$TMP/fail-bin"
cat > "$TMP/fail-bin/sed" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    s/__AGENT_NAME__/route-lead-*)
      cmp -s "$CC_ORCH_MANIFEST" "$CC_ORCH_TEST_PUBLISHED" || exit 91
      [[ "$(wc -l < "$CC_ORCH_MANIFEST.building")" -eq 22 ]] || exit 92
      echo 'injected route render failure after 22 staged entries' >&2
      exit 93
      ;;
  esac
done
exec "$CC_ORCH_TEST_SED" "$@"
SH
chmod +x "$TMP/fail-bin/sed"
cp "$TMP/custom/manifest.json" "$TMP/published-before.json"
REAL_SED="$(command -v sed)"
rc=0
out="$(PATH="$TMP/fail-bin:$PATH" CC_ORCH_TEST_SED="$REAL_SED" \
  CC_ORCH_TEST_PUBLISHED="$TMP/published-before.json" \
  CC_ORCH_AGENTS_DIR="$TMP/failure-agents" CC_ORCH_MANIFEST="$TMP/custom/manifest.json" \
  "$ROOT/build-roster-runtime.sh" 2>&1)" || rc=$?
assert_eq "$rc" 93 "injected runtime failure exit"
assert_has "$out" 'injected route render failure after 22 staged entries' "failure reached runtime render"
cmp -s "$TMP/custom/manifest.json" "$TMP/published-before.json" || fail "failed runtime build published a partial manifest"
[[ ! -e "$TMP/custom/manifest.json.building" ]] || fail "failed runtime staging file not cleaned up"
ok "runtime render failure preserves previously published complete manifest"

run_doctor "$TMP/does-not-exist"
assert_eq "$rc" 2 "absent manifest exit"
assert_has "$out" 'ERROR: manifest not found or unreadable:' "absent manifest error"
: > "$TMP/empty.json"
run_doctor "$TMP/empty.json"
assert_eq "$rc" 2 "empty manifest exit"
printf '{}\n' > "$TMP/invalid.json"
run_doctor "$TMP/invalid.json"
assert_eq "$rc" 2 "invalid manifest exit"
ok "missing, empty, and malformed manifests fail with setup exit 2"

echo "PASS: $pass orch-doctor test groups"
