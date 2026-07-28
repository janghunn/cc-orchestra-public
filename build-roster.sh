#!/usr/bin/env bash
# Generate the named agent roster into ~/.claude/agents from the shared templates.
#
# Why a generator: each lead and dev needs its own agent definition so it has a stable slot
# identity, but the four leads are otherwise identical. Rather than hand-maintaining four
# near-identical prompts, edit templates/lead.md.tpl and re-run this.
#
# Generated files are NOT tracked in git — the templates are the source of truth.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$HOME/.claude/agents"
LEAD_SLOTS=(alpha bravo charlie delta)
DEV_SLOTS=(1 2 3)

# Leads render with whatever model the guard has settled on, so re-running this while the
# fallback is active does not quietly put the tier back on a model with no quota left.
LEAD_MODEL="$("$REPO_DIR/bin/orch-model-guard" active 2>/dev/null || true)"
LEAD_MODEL="${LEAD_MODEL:-fable[1m]}"

render() { # render <template> <slot> <outfile>
  local tpl="$1" slot="$2" out="$3" upper
  upper="$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')"
  sed -e "s/__SLOTUP__/${upper}/g" -e "s/__SLOT__/${slot}/g" -e "s|__MODEL__|${LEAD_MODEL}|g" "$tpl" > "$out"
  printf '  %s\n' "$(basename "$out")"
}

mkdir -p "$AGENTS_DIR"

echo "leads:  (model: $LEAD_MODEL)"
for slot in "${LEAD_SLOTS[@]}"; do
  render "$REPO_DIR/templates/lead.md.tpl" "$slot" "$AGENTS_DIR/lead-${slot}.md"
done

echo "devs:"
for slot in "${DEV_SLOTS[@]}"; do
  render "$REPO_DIR/templates/dev.md.tpl" "$slot" "$AGENTS_DIR/dev-${slot}.md"
done

# Fail loudly if a placeholder survived — a stray __SLOT__ would ship a broken agent name, and
# a stray __MODEL__ an agent Claude Code cannot start.
if grep -rlE '__(SLOT|MODEL)' "$AGENTS_DIR" 2>/dev/null | grep -q .; then
  echo "ERROR: unsubstituted placeholder left in:" >&2
  grep -rlE '__(SLOT|MODEL)' "$AGENTS_DIR" >&2
  exit 1
fi

echo
echo "roster written to $AGENTS_DIR"
