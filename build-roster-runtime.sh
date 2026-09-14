#!/usr/bin/env bash
# Build the existing roster, then add immutable runtime-routed lead profiles.
#
# The legacy guard may rewrite lead-*.md for backwards compatibility. Runtime profiles use the
# route-lead-* namespace, so quota/reset changes select among agent types already cached by
# Claude Code instead of requiring a cc-orch reload.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$REPO_DIR/build-roster.sh"
AGENTS_DIR="${CC_ORCH_AGENTS_DIR:-$HOME/.claude/agents}"
MANIFEST="${CC_ORCH_MANIFEST:-$AGENTS_DIR/.install-manifest.json}"
REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
LEAD_SLOTS=(alpha bravo charlie delta)

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 < "$1" | awk '{print $NF}'
  else
    echo "ERROR: SHA-256 requires sha256sum, shasum, or openssl" >&2
    return 1
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

[[ -x "$CORE" ]] || { echo "build-roster-runtime: missing $CORE" >&2; exit 2; }
mkdir -p "$AGENTS_DIR" "$(dirname "$MANIFEST")"
MANIFEST_TMP="$MANIFEST.building.$$"
trap 'rm -f "$MANIFEST_TMP"' EXIT
: > "$MANIFEST_TMP"
CC_ORCH_MANIFEST_NO_COMMIT=1 CC_ORCH_MANIFEST_STAGING="$MANIFEST_TMP" "$CORE"

# shellcheck source=/dev/null
. "$REPO_DIR/model-policy.conf"

render_route() { # slot profile model effort
  local slot="$1" profile="$2" model="$3" effort="$4" name out upper
  local dest output_sha template_sha
  name="route-lead-$slot-$profile"
  out="$AGENTS_DIR/$name.md"
  upper="$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')"
  sed -e "s/__SLOTUP__/${upper}/g" \
      -e "s/__SLOT__/${slot}/g" \
      -e "s/__AGENT_NAME__/${name}/g" \
      -e "s/__PROFILE__/${profile}/g" \
      -e "s|__MODEL__|${model}|g" \
      -e "s/__EFFORT__/${effort}/g" \
      -e 's|~/.claude/orchestra/bin/codex-run|~/.claude/orchestra/bin/codex-run-runtime|g' \
      -e 's|~/.claude/orchestra/bin/orch-model-guard|~/.claude/orchestra/bin/orch-model-guard-runtime|g' \
      "$REPO_DIR/templates/lead.md.tpl" > "$out"
  dest="$out"
  [[ "$dest" == /* ]] || dest="$PWD/$dest"
  output_sha="$(sha256_of "$out")"
  template_sha="$(sha256_of "$REPO_DIR/templates/lead.md.tpl")"
  printf '{"dest":"%s","template":"%s","template_sha256":"%s","sha256":"%s","commit":"%s"}\n' \
    "$(json_escape "$dest")" "$(json_escape 'templates/lead.md.tpl')" \
    "$template_sha" "$output_sha" "$REPO_COMMIT" >> "$MANIFEST_TMP"
  printf '  %-42s %s @ %s\n' "$(basename "$out")" "$model" "$effort"
}

mkdir -p "$AGENTS_DIR"
echo
echo "runtime-routed leads (immutable; not rewritten by the legacy quota guard):"
for slot in "${LEAD_SLOTS[@]}"; do
  render_route "$slot" light "$LEAD_LIGHT_MODEL" "$LEAD_LIGHT_EFFORT"
  render_route "$slot" normal "$LEAD_NORMAL_MODEL" "$LEAD_NORMAL_EFFORT"
  render_route "$slot" critical "$LEAD_CRITICAL_MODEL" "$LEAD_CRITICAL_EFFORT"
  render_route "$slot" critical-xhigh "$LEAD_DEEP_MODEL" "$LEAD_DEEP_EFFORT"
done

if grep -rlE '__(SLOT|MODEL|EFFORT|PROFILE|AGENT_NAME)' "$AGENTS_DIR"/route-lead-*.md \
     2>/dev/null | grep -q .; then
  echo "ERROR: unsubstituted placeholder left in runtime route roster" >&2
  exit 1
fi

mv "$MANIFEST_TMP" "$MANIFEST"

echo "runtime route roster written to $AGENTS_DIR (16 stable lead profiles)"
