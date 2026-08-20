#!/usr/bin/env bash
# Install this harness into ~/.claude and ~/.local/bin.
#
#   ./install.sh            # symlink the repo into place, then build the roster
#   ./install.sh --check    # report what is installed and whether it points here
#
# Symlinks, not copies: editing a template or prompt in the repo takes effect on the next run
# with no install step, and `git status` always tells the truth about what is live.
# The generated lead-*/dev-* roster files are real files in ~/.claude/agents (untracked).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"

link() { # link <source> <dest>
  local src="$1" dest="$2"
  if [[ -L "$dest" ]]; then
    local cur; cur="$(readlink -f "$dest")"
    [[ "$cur" == "$(readlink -f "$src")" ]] && { echo "  ok       $dest"; return; }
    echo "  relink   $dest (was -> $cur)"
  elif [[ -e "$dest" ]]; then
    local backup="${dest}.pre-cc-orchestra"
    echo "  backup   $dest -> $backup"
    mv "$dest" "$backup"
  else
    echo "  link     $dest"
  fi
  ln -sfn "$src" "$dest"
}

check() {
  local ok=0
  for pair in \
    "$CLAUDE_DIR/orchestra:$REPO_DIR" \
    "$CLAUDE_DIR/agents/orchestrator.md:$REPO_DIR/agents/orchestrator.md" \
    "$CLAUDE_DIR/agents/verifier.md:$REPO_DIR/agents/verifier.md" \
    "$CLAUDE_DIR/agents/verifier-normal.md:$REPO_DIR/agents/verifier-normal.md" \
    "$BIN_DIR/cc-orch:$REPO_DIR/bin/cc-orch" \
    "$BIN_DIR/codex-run:$REPO_DIR/bin/codex-run" \
    "$BIN_DIR/orch-model-guard:$REPO_DIR/bin/orch-model-guard" \
    "$BIN_DIR/orch-summary-check:$REPO_DIR/bin/orch-summary-check" \
    "$BIN_DIR/orch-usage-report:$REPO_DIR/bin/orch-usage-report"
  do
    local dest="${pair%%:*}" src="${pair#*:}"
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
      echo "  ok       $dest"
    else
      echo "  MISSING  $dest"; ok=1
    fi
  done
  local n; n="$(find "$CLAUDE_DIR/agents" -maxdepth 1 -type f \
    \( -name 'lead-*.md' -o -name 'dev-*.md' \) 2>/dev/null | wc -l)"
  echo "  roster   $n generated agent profiles (expect 22)"
  [[ "$n" -eq 22 ]] || ok=1

  if systemctl --user is-enabled orch-model-guard.timer >/dev/null 2>&1; then
    echo "  ok       model guard timer ($(systemctl --user is-active orch-model-guard.timer))"
  else
    echo "  MISSING  model guard timer"; ok=1
  fi
  if grep -q 'orch-model-notice.sh' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  ok       model notice hook in settings.json"
  else
    echo "  MISSING  model notice hook in settings.json"; ok=1
  fi
  echo "  model    $("$REPO_DIR/bin/orch-model-guard" active) active normal orchestrator profile"

  # Codex is the second provider (Tier 3 lane / Tier 4 gate) but an optional one: its absence
  # degrades the harness to Claude-only rather than breaking it, so WARN instead of failing.
  if command -v codex >/dev/null 2>&1; then
    # "Logged in using ChatGPT" goes to stderr, not stdout — capture both.
    if codex login status 2>&1 | grep -qi 'logged in'; then
      echo "  ok       codex CLI ($(codex --version 2>/dev/null), logged in) — sol/luna lanes live"
    else
      echo "  WARN     codex CLI present but not logged in — codex lanes will exit 4 (run: codex login)"
    fi
  else
    echo "  WARN     codex CLI not found — Tier 3/4 codex lanes disabled (Claude-only still works)"
  fi
  return $ok
}

if [[ "${1:-}" == "--check" ]]; then
  echo "cc-orchestra @ $REPO_DIR"
  check && echo "installed." || { echo "incomplete — run ./install.sh"; exit 1; }
  exit 0
fi

echo "cc-orchestra @ $REPO_DIR"
mkdir -p "$CLAUDE_DIR/agents" "$BIN_DIR"

link "$REPO_DIR"                        "$CLAUDE_DIR/orchestra"
link "$REPO_DIR/agents/orchestrator.md" "$CLAUDE_DIR/agents/orchestrator.md"
link "$REPO_DIR/agents/verifier.md"     "$CLAUDE_DIR/agents/verifier.md"
link "$REPO_DIR/agents/verifier-normal.md" "$CLAUDE_DIR/agents/verifier-normal.md"
link "$REPO_DIR/bin/cc-orch"            "$BIN_DIR/cc-orch"
link "$REPO_DIR/bin/codex-run"          "$BIN_DIR/codex-run"
link "$REPO_DIR/bin/orch-model-guard"   "$BIN_DIR/orch-model-guard"
link "$REPO_DIR/bin/orch-summary-check" "$BIN_DIR/orch-summary-check"
link "$REPO_DIR/bin/orch-usage-report"  "$BIN_DIR/orch-usage-report"

chmod +x "$REPO_DIR"/*.sh "$REPO_DIR/bin/"* "$REPO_DIR/hooks/"*.sh

echo
"$REPO_DIR/bin/orch-model-guard" check
"$REPO_DIR/build-roster.sh"

echo
echo "model guard:"
"$REPO_DIR/bin/orch-model-guard" install

echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: $BIN_DIR is not on your PATH — add it to use 'cc-orch' directly." ;;
esac
echo "done. try: cc-orch --help"
