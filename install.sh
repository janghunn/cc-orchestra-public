#!/usr/bin/env bash
# Install cc-orchestra into ~/.claude and ~/.local/bin.
#
#   ./install.sh            # symlink, generate base + runtime lead roster, install hooks
#   ./install.sh --check    # verify links, profiles, hooks, and provider CLIs
#
# Original repository commands remain untouched. Public ~/.local/bin commands point at runtime
# facades, which delegate to the original implementations after applying the operational layer.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
RUNTIME_HOOK="$REPO_DIR/hooks/orch-runtime-context.sh"

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

install_runtime_hook() {
  python3 - "$CLAUDE_DIR/settings.json" "$RUNTIME_HOOK" <<'PY'
import json, os, sys, tempfile
path, command = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
settings = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        settings = json.load(fh)
hooks = settings.setdefault("hooks", {})
entries = hooks.setdefault("UserPromptSubmit", [])
if not isinstance(entries, list):
    raise SystemExit("settings hooks.UserPromptSubmit must be a list")
found = False
for entry in entries:
    if not isinstance(entry, dict):
        continue
    for hook in entry.get("hooks", []):
        if isinstance(hook, dict) and hook.get("command") == command:
            found = True
if not found:
    entries.append({"hooks": [{"type": "command", "command": command}]})
fd, tmp = tempfile.mkstemp(prefix="settings.", dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(settings, out, ensure_ascii=False, indent=2)
        out.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

check() {
  local rc=0 pair dest src
  for pair in \
    "$CLAUDE_DIR/orchestra:$REPO_DIR" \
    "$CLAUDE_DIR/agents/orchestrator.md:$REPO_DIR/agents/orchestrator.md" \
    "$CLAUDE_DIR/agents/verifier.md:$REPO_DIR/agents/verifier.md" \
    "$CLAUDE_DIR/agents/verifier-normal.md:$REPO_DIR/agents/verifier-normal.md" \
    "$BIN_DIR/cc-orch:$REPO_DIR/bin/cc-orch-runtime" \
    "$BIN_DIR/codex-run:$REPO_DIR/bin/codex-run-runtime" \
    "$BIN_DIR/orch-model-guard:$REPO_DIR/bin/orch-model-guard-runtime" \
    "$BIN_DIR/orch-summary-check:$REPO_DIR/bin/orch-summary-check" \
    "$BIN_DIR/orch-usage-report:$REPO_DIR/bin/orch-usage-report"
  do
    dest="${pair%%:*}"; src="${pair#*:}"
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
      echo "  ok       $dest"
    else
      echo "  MISSING  $dest"; rc=1
    fi
  done

  local base routed
  base="$(find "$CLAUDE_DIR/agents" -maxdepth 1 -type f \
    \( -name 'lead-*.md' -o -name 'dev-*.md' \) 2>/dev/null | wc -l)"
  routed="$(find "$CLAUDE_DIR/agents" -maxdepth 1 -type f -name 'route-lead-*.md' \
    2>/dev/null | wc -l)"
  echo "  roster   $base base profiles (expect 22), $routed runtime routes (expect 16)"
  [[ "$base" -eq 22 && "$routed" -eq 16 ]] || rc=1

  if command -v systemctl >/dev/null 2>&1 && \
     systemctl --user is-enabled orch-model-guard.timer >/dev/null 2>&1; then
    echo "  ok       model guard timer ($(systemctl --user is-active orch-model-guard.timer))"
  else
    echo "  info     no user-systemd timer; runtime wrappers/status line refresh on demand"
  fi
  if grep -q 'orch-model-notice.sh' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  ok       structural policy hook in settings.json"
  else
    echo "  MISSING  structural policy hook in settings.json"; rc=1
  fi
  if grep -q 'orch-runtime-context.sh' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  ok       live runtime routing hook in settings.json"
  else
    echo "  MISSING  live runtime routing hook in settings.json"; rc=1
  fi
  if grep -q 'orch-statusline.sh' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  ok       Claude 5h/7d reset tap in settings.json"
  else
    echo "  MISSING  Claude reset tap in settings.json"; rc=1
  fi
  echo "  budget   $("$REPO_DIR/bin/orch-model-guard-runtime" budget --compact 2>/dev/null || echo unavailable)"

  if command -v tmux >/dev/null 2>&1; then
    echo "  ok       tmux ($(tmux -V 2>/dev/null)) — managed sessions enabled"
  else
    echo "  WARN     tmux not found — direct cc-orch works; 'cc-orch session' does not"
  fi

  if command -v codex >/dev/null 2>&1; then
    if codex login status 2>&1 | grep -qi 'logged in'; then
      echo "  ok       codex CLI ($(codex --version 2>/dev/null), logged in)"
    else
      echo "  WARN     codex CLI present but not logged in (run: codex login)"
    fi
  else
    echo "  WARN     codex CLI not found — Claude-only fallback remains available"
  fi
  return "$rc"
}

if [[ "${1:-}" == "--check" ]]; then
  echo "cc-orchestra @ $REPO_DIR"
  check && echo "installed." || { echo "incomplete — run ./install.sh"; exit 1; }
  exit 0
fi

echo "cc-orchestra @ $REPO_DIR"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: Python 3 is required." >&2; exit 1; }
mkdir -p "$CLAUDE_DIR/agents" "$BIN_DIR"

link "$REPO_DIR"                           "$CLAUDE_DIR/orchestra"
link "$REPO_DIR/agents/orchestrator.md"    "$CLAUDE_DIR/agents/orchestrator.md"
link "$REPO_DIR/agents/verifier.md"        "$CLAUDE_DIR/agents/verifier.md"
link "$REPO_DIR/agents/verifier-normal.md" "$CLAUDE_DIR/agents/verifier-normal.md"
link "$REPO_DIR/bin/cc-orch-runtime"       "$BIN_DIR/cc-orch"
link "$REPO_DIR/bin/codex-run-runtime"     "$BIN_DIR/codex-run"
link "$REPO_DIR/bin/orch-model-guard-runtime" "$BIN_DIR/orch-model-guard"
link "$REPO_DIR/bin/orch-summary-check"    "$BIN_DIR/orch-summary-check"
link "$REPO_DIR/bin/orch-usage-report"     "$BIN_DIR/orch-usage-report"

chmod +x "$REPO_DIR"/*.sh "$REPO_DIR/bin/"* "$REPO_DIR/hooks/"*.sh

echo
"$REPO_DIR/bin/orch-model-guard-runtime" check
"$REPO_DIR/build-roster-runtime.sh"

echo
echo "model guard and reset-time taps:"
"$REPO_DIR/bin/orch-model-guard-runtime" install
install_runtime_hook

echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: $BIN_DIR is not on PATH — add it to use cc-orch directly." ;;
esac
echo "done. try: cc-orch session --help; orch-model-guard budget"
