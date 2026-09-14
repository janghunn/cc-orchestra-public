#!/usr/bin/env bash
# Generate the named model/effort profiles into ~/.claude/agents.
#
# Human-facing slots stay lead-alpha/dev-1. Profile-suffixed agent type names select the model
# and effort without changing the registry/addressing contract.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${CC_ORCH_AGENTS_DIR:-$HOME/.claude/agents}"
MANIFEST="${CC_ORCH_MANIFEST:-$AGENTS_DIR/.install-manifest.json}"
REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
LEAD_SLOTS=(alpha bravo charlie delta)
DEV_SLOTS=(1 2 3)

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

mkdir -p "$AGENTS_DIR" "$(dirname "$MANIFEST")"
if [[ "${CC_ORCH_MANIFEST_NO_COMMIT:-0}" == 1 ]]; then
  MANIFEST_TMP="${CC_ORCH_MANIFEST_STAGING:?CC_ORCH_MANIFEST_STAGING is required with CC_ORCH_MANIFEST_NO_COMMIT=1}"
else
  MANIFEST_TMP="$MANIFEST.tmp.$$"
  trap 'rm -f "$MANIFEST_TMP"' EXIT
  : > "$MANIFEST_TMP"
fi

# shellcheck source=/dev/null
. "$REPO_DIR/model-policy.conf"

ACTIVE_CONTROL="$("$REPO_DIR/bin/orch-model-guard" active 2>/dev/null || true)"
ACTIVE_CONTROL="${ACTIVE_CONTROL:-$PRIMARY_MODEL}"

# When the Fable bucket is exhausted, the guard moves every control profile to Opus. Otherwise
# each profile retains its distinct Sonnet/Opus/Fable model.
LIGHT_MODEL="$LEAD_LIGHT_MODEL"
NORMAL_MODEL="$LEAD_NORMAL_MODEL"
if [[ "$ACTIVE_CONTROL" == "$FALLBACK_MODEL" ]]; then
  LIGHT_MODEL="$FALLBACK_MODEL"
  NORMAL_MODEL="$FALLBACK_MODEL"
elif [[ "$ACTIVE_CONTROL" != "$PRIMARY_MODEL" ]]; then
  # A manually pinned custom model is intentionally global until `set auto`/`set primary`.
  LIGHT_MODEL="$ACTIVE_CONTROL"
  NORMAL_MODEL="$ACTIVE_CONTROL"
fi

render() { # render <template> <slot> <agent-name> <profile> <model> <effort> <outfile>
  local tpl="$1" slot="$2" agent_name="$3" profile="$4" model="$5" effort="$6" out="$7" upper
  local dest output_sha template_sha
  upper="$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')"
  sed -e "s/__SLOTUP__/${upper}/g" \
      -e "s/__SLOT__/${slot}/g" \
      -e "s/__AGENT_NAME__/${agent_name}/g" \
      -e "s/__PROFILE__/${profile}/g" \
      -e "s|__MODEL__|${model}|g" \
      -e "s/__EFFORT__/${effort}/g" \
      "$tpl" > "$out"
  dest="$out"
  [[ "$dest" == /* ]] || dest="$PWD/$dest"
  output_sha="$(sha256_of "$out")"
  template_sha="$(sha256_of "$tpl")"
  printf '{"dest":"%s","template":"%s","template_sha256":"%s","sha256":"%s","commit":"%s"}\n' \
    "$(json_escape "$dest")" "$(json_escape "${tpl#"$REPO_DIR/"}")" \
    "$template_sha" "$output_sha" "$REPO_COMMIT" >> "$MANIFEST_TMP"
  printf '  %-34s %s @ %s\n' "$(basename "$out")" "$model" "$effort"
}

mkdir -p "$AGENTS_DIR"

echo "leads:"
for slot in "${LEAD_SLOTS[@]}"; do
  render "$REPO_DIR/templates/lead.md.tpl" "$slot" "lead-$slot-light" "light" \
    "$LIGHT_MODEL" "$LEAD_LIGHT_EFFORT" "$AGENTS_DIR/lead-$slot-light.md"
  render "$REPO_DIR/templates/lead.md.tpl" "$slot" "lead-$slot" "normal" \
    "$NORMAL_MODEL" "$LEAD_NORMAL_EFFORT" "$AGENTS_DIR/lead-$slot.md"
  critical_model="$LEAD_CRITICAL_MODEL"; deep_model="$LEAD_DEEP_MODEL"
  if [[ "$ACTIVE_CONTROL" == "$FALLBACK_MODEL" ]]; then
    critical_model="$FALLBACK_MODEL"; deep_model="$FALLBACK_MODEL"
  elif [[ "$ACTIVE_CONTROL" != "$PRIMARY_MODEL" ]]; then
    critical_model="$ACTIVE_CONTROL"; deep_model="$ACTIVE_CONTROL"
  fi
  render "$REPO_DIR/templates/lead.md.tpl" "$slot" "lead-$slot-critical" "critical" \
    "$critical_model" "$LEAD_CRITICAL_EFFORT" "$AGENTS_DIR/lead-$slot-critical.md"
  render "$REPO_DIR/templates/lead.md.tpl" "$slot" "lead-$slot-critical-xhigh" "critical-xhigh" \
    "$deep_model" "$LEAD_DEEP_EFFORT" "$AGENTS_DIR/lead-$slot-critical-xhigh.md"
done

echo "devs:"
for slot in "${DEV_SLOTS[@]}"; do
  render "$REPO_DIR/templates/dev.md.tpl" "$slot" "dev-$slot" "sonnet-fallback" \
    "$DEV_MODEL" "$DEV_EFFORT" "$AGENTS_DIR/dev-$slot.md"
  render "$REPO_DIR/templates/dev.md.tpl" "$slot" "dev-opus-$slot" "opus-fresh-eyes" \
    "$DEV_FRESH_MODEL" "$DEV_FRESH_EFFORT" "$AGENTS_DIR/dev-opus-$slot.md"
done

if grep -rlE '__(SLOT|MODEL|EFFORT|PROFILE|AGENT_NAME)' "$AGENTS_DIR"/lead-*.md \
     "$AGENTS_DIR"/dev-*.md 2>/dev/null | grep -q .; then
  echo "ERROR: unsubstituted placeholder left in generated roster:" >&2
  grep -rlE '__(SLOT|MODEL|EFFORT|PROFILE|AGENT_NAME)' "$AGENTS_DIR"/lead-*.md \
    "$AGENTS_DIR"/dev-*.md >&2
  exit 1
fi

if [[ "${CC_ORCH_MANIFEST_NO_COMMIT:-0}" != 1 ]]; then
  mv "$MANIFEST_TMP" "$MANIFEST"
fi

echo
echo "roster written to $AGENTS_DIR (22 generated profiles)"
