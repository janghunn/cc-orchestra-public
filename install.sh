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
    "$BIN_DIR/cc-orch:$REPO_DIR/bin/cc-orch"
  do
    local dest="${pair%%:*}" src="${pair#*:}"
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
      echo "  ok       $dest"
    else
      echo "  MISSING  $dest"; ok=1
    fi
  done
  local n; n=$(ls "$CLAUDE_DIR"/agents/lead-*.md "$CLAUDE_DIR"/agents/dev-*.md 2>/dev/null | wc -l)
  echo "  roster   $n generated agent files (expect 7)"
  [[ "$n" -eq 7 ]] || ok=1
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
link "$REPO_DIR/bin/cc-orch"            "$BIN_DIR/cc-orch"

chmod +x "$REPO_DIR"/*.sh "$REPO_DIR/bin/cc-orch"

echo
"$REPO_DIR/build-roster.sh"

echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: $BIN_DIR is not on your PATH — add it to use 'cc-orch' directly." ;;
esac
echo "done. try: cc-orch --help"
