#!/usr/bin/env bash
# Install cc-orchestra into ~/.claude and ~/.local/bin.
#
#   ./install.sh                         # install/relink cc-orchestra runtime layer
#   ./install.sh --check                 # verify links, profiles, hooks, provider CLIs
#   ./install.sh --bootstrap             # fresh-host bootstrap: deps, CLIs, auth, install, tests
#   ./install.sh --bootstrap --skip-auth # install everything except interactive provider login
#
# Original repository commands remain untouched. Public ~/.local/bin commands point at runtime
# facades, which delegate to the original implementations after applying the operational layer.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="${CC_ORCH_BIN_DIR:-$HOME/.local/bin}"
RUNTIME_HOOK="$REPO_DIR/hooks/orch-runtime-context.sh"

MODE=install
SKIP_AUTH=0
SKIP_TESTS=0

usage() {
  cat <<'EOF'
usage:
  ./install.sh
  ./install.sh --check
  ./install.sh --safety-hooks-only
  ./install.sh --codex-only
  ./install.sh --bootstrap [--skip-auth] [--skip-tests]

modes:
  --codex-only   install Codex launchers without Claude, usage polling, or a timer
  --safety-hooks-only  merge only the runtime safety and compaction-recovery hooks into Claude settings
  --check       inspect the current cc-orchestra installation without changing it
  --bootstrap   prepare a fresh Linux user after the repository has been cloned:
                install missing system dependencies, Claude Code, Codex CLI,
                complete provider logins, install cc-orchestra, and run regression tests

options:
  --skip-auth   with --bootstrap, do not launch interactive Claude/Codex login flows
  --skip-tests  with --bootstrap, skip repository regression tests
  -h, --help    show this help

Notes:
  * GitHub authentication and cloning this private repository happen before --bootstrap.
  * --bootstrap never copies or stores provider passwords/tokens itself. Authentication is
    delegated to the official Claude Code and Codex CLI login flows.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      [[ "$MODE" == install ]] || { echo "ERROR: choose only one mode." >&2; exit 2; }
      MODE=check
      ;;
    --bootstrap)
      [[ "$MODE" == install ]] || { echo "ERROR: choose only one mode." >&2; exit 2; }
      MODE=bootstrap
      ;;
    --safety-hooks-only)
      [[ "$MODE" == install ]] || { echo "ERROR: choose only one mode." >&2; exit 2; }
      MODE=safety-hooks-only
      ;;
    --skip-auth) SKIP_AUTH=1 ;;
    --codex-only)
      [[ "$MODE" == install ]] || { echo "ERROR: choose only one mode." >&2; exit 2; }
      MODE=codex-only
      ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$MODE" != bootstrap && ( "$SKIP_AUTH" == 1 || "$SKIP_TESTS" == 1 ) ]]; then
  echo "ERROR: --skip-auth/--skip-tests are only valid with --bootstrap." >&2
  exit 2
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok       %s\n' "$*"; }
info() { printf '  info     %s\n' "$*"; }
warn() { printf '  WARN     %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

install_safety_hooks() {
  python3 - "${CC_ORCH_SETTINGS:-$CLAUDE_DIR/settings.json}" "$REPO_DIR" <<'PY'
import json, os, shlex, sys, tempfile
SAFETY_HOOKS = (
    ("PreToolUse", "Bash", "orch-worktree-guard.sh", 10),
    ("SubagentStop", "(route-)?lead-.*", "orch-stop-gate.sh", 30),
    ("SessionStart", "compact", "orch-compact-context.sh", 10),
)

def is_safety_hook(hook, basename):
    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
        return False
    try:
        tokens = shlex.split(hook["command"])
    except ValueError:
        return False
    path = "hooks/" + basename
    return any(token == path or token.endswith("/" + path) for token in tokens)

path, repo = sys.argv[1:]
path = os.path.abspath(path)
os.makedirs(os.path.dirname(path), exist_ok=True)
settings = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as source:
        settings = json.load(source)
hooks = settings.setdefault("hooks", {})
for event, matcher, basename, timeout in SAFETY_HOOKS:
    entries = hooks.setdefault(event, [])
    if not isinstance(entries, list):
        raise SystemExit(f"settings hooks.{event} must be a list")
    command = "bash " + shlex.quote(os.path.join(repo, "hooks", basename)) + " || true"
    matches = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            continue
        for hook in entry["hooks"]:
            if is_safety_hook(hook, basename):
                matches.append((entry, hook))
    if not matches:
        entries.append({"matcher": matcher, "hooks": [
            {"type": "command", "command": command, "timeout": timeout}
        ]})
        continue
    kept_entry, kept_hook = next(
        (match for match in matches if match[0].get("matcher") == matcher), matches[0])
    kept_hook["command"] = command
    kept_hook["type"] = "command"
    kept_hook["timeout"] = timeout
    for entry, hook in matches:
        if hook is kept_hook:
            continue
        entry["hooks"][:] = [item for item in entry["hooks"] if item is not hook]
        if not entry["hooks"]:
            entries[:] = [item for item in entries if item is not entry]
    if kept_entry.get("matcher") != matcher:
        if len(kept_entry["hooks"]) == 1:
            kept_entry["matcher"] = matcher
        else:
            # Preserve the matcher and position of any co-located user hooks.
            kept_entry["hooks"][:] = [item for item in kept_entry["hooks"] if item is not kept_hook]
            entries.append({"matcher": matcher, "hooks": [kept_hook]})
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

claude_auth_status() {
  command -v claude >/dev/null 2>&1 || return 1
  local out
  out="$(claude auth status 2>&1 || true)"
  printf '%s\n' "$out" | grep -Eq \
    '"loggedIn"[[:space:]]*:[[:space:]]*true|Login method:[[:space:]].+|logged[ -]?in'
}

codex_auth_status() {
  command -v codex >/dev/null 2>&1 || return 1
  codex login status 2>&1 | grep -qi 'logged in'
}

check() {
  local rc=0 pair dest src
  for pair in \
    "$CLAUDE_DIR/orchestra:$REPO_DIR" \
    "$CLAUDE_DIR/agents/orchestrator.md:$REPO_DIR/agents/orchestrator.md" \
    "$CLAUDE_DIR/agents/verifier-normal.md:$REPO_DIR/agents/verifier-normal.md" \
    "$BIN_DIR/cc-orch:$REPO_DIR/bin/cc-orch-runtime" \
    "$BIN_DIR/codex-run:$REPO_DIR/bin/codex-run-runtime" \
    "$BIN_DIR/orch-model-guard:$REPO_DIR/bin/orch-model-guard-runtime" \
    "$BIN_DIR/orch-summary-check:$REPO_DIR/bin/orch-summary-check" \
    "$BIN_DIR/orch-usage-report:$REPO_DIR/bin/orch-usage-report" \
    "$BIN_DIR/orch-archive:$REPO_DIR/bin/orch-archive"
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

  # verifier.md is generated from templates/verifier.md.tpl + model-policy.conf. Validate it by
  # re-rendering with the real builder into a throwaway directory and comparing bytes, so this
  # check can never drift from render(). CC_ORCH_STATE_DIR is redirected because the builder
  # calls orch-model-guard, which creates its state directory; --check must stay read-only.
  local vdest="$CLAUDE_DIR/agents/verifier.md" vtmp vmodel veffort
  # shellcheck source=/dev/null
  . "$REPO_DIR/model-policy.conf"
  if [[ -L "$vdest" ]]; then
    echo "  STALE    $vdest is a legacy repo symlink; re-run ./install.sh to generate it"; rc=1
  elif [[ ! -f "$vdest" ]]; then
    echo "  MISSING  $vdest (generated from templates/verifier.md.tpl)"; rc=1
  else
    if ! vtmp="$(mktemp -d)" || [[ -z "$vtmp" ]]; then
      echo "  MISSING  cannot allocate a temporary directory to validate $vdest"; rc=1
    else
      if CC_ORCH_AGENTS_DIR="$vtmp" CC_ORCH_MANIFEST="$vtmp/.install-manifest.json" \
           CC_ORCH_STATE_DIR="$vtmp/state" \
           "$REPO_DIR/build-roster.sh" >/dev/null 2>&1 && [[ -f "$vtmp/verifier.md" ]]; then
        if cmp -s "$vtmp/verifier.md" "$vdest"; then
          echo "  ok       $vdest ($VERIFIER_CRITICAL_MODEL @ $VERIFIER_CRITICAL_EFFORT from model-policy.conf)"
        else
          vmodel="$(sed -n 's/^model: //p' "$vdest" | head -1)"
          veffort="$(sed -n 's/^effort: //p' "$vdest" | head -1)"
          echo "  STALE    $vdest is ${vmodel:-?} @ ${veffort:-?}; model-policy.conf says $VERIFIER_CRITICAL_MODEL @ $VERIFIER_CRITICAL_EFFORT — re-run ./install.sh"
          rc=1
        fi
      else
        echo "  MISSING  cannot render templates/verifier.md.tpl to validate $vdest"; rc=1
      fi
      rm -rf "$vtmp"
    fi
  fi

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

  for hook in orch-worktree-guard.sh orch-stop-gate.sh orch-compact-context.sh; do
    if grep -q "$hook" "${CC_ORCH_SETTINGS:-$CLAUDE_DIR/settings.json}" 2>/dev/null; then
      echo "  ok       $hook in settings.json"
    else
      echo "  MISSING  $hook in settings.json"; rc=1
    fi
  done

  if command -v tmux >/dev/null 2>&1; then
    echo "  ok       tmux ($(tmux -V 2>/dev/null)) — managed sessions enabled"
  else
    echo "  WARN     tmux not found — direct cc-orch works; 'cc-orch session' does not"
  fi

  if command -v claude >/dev/null 2>&1; then
    if claude_auth_status; then
      echo "  ok       Claude Code ($(claude --version 2>/dev/null | head -1), logged in)"
    else
      echo "  MISSING  Claude Code is installed but not authenticated (run: claude auth login)"
      rc=1
    fi
  else
    echo "  MISSING  Claude Code CLI not found — cc-orch cannot launch"
    rc=1
  fi

  if command -v codex >/dev/null 2>&1; then
    if codex_auth_status; then
      echo "  ok       codex CLI ($(codex --version 2>/dev/null), logged in)"
    else
      echo "  WARN     codex CLI present but not logged in (run: codex login)"
    fi
  else
    echo "  WARN     codex CLI not found — Claude-only fallback remains available"
  fi
  return "$rc"
}

ensure_local_bin_path() {
  mkdir -p "$BIN_DIR"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
  esac

  local line='export PATH="$HOME/.local/bin:$PATH"' rc
  for rc in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$rc"
    if ! grep -Fqx "$line" "$rc" 2>/dev/null; then
      {
        echo
        echo "# cc-orchestra / provider CLIs"
        echo "$line"
      } >> "$rc"
    fi
  done
}

sudo_prefix() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf ''
  elif command -v sudo >/dev/null 2>&1; then
    printf 'sudo'
  else
    die "missing system packages and sudo is unavailable; install dependencies as root first"
  fi
}

install_missing_system_dependencies() {
  [[ "$(uname -s)" == Linux ]] || die "--bootstrap currently supports Linux hosts only"

  local -a missing=() packages=()
  command -v curl >/dev/null 2>&1 || { missing+=(curl); packages+=(curl); }
  command -v tmux >/dev/null 2>&1 || { missing+=(tmux); packages+=(tmux); }
  command -v git >/dev/null 2>&1 || { missing+=(git); packages+=(git); }
  command -v python3 >/dev/null 2>&1 || { missing+=(python3); packages+=(python3); }
  command -v ssh >/dev/null 2>&1 || { missing+=(ssh); packages+=(openssh-client); }

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "system dependencies already present: curl tmux git python3 ssh"
    return
  fi

  info "missing system commands: ${missing[*]}"
  local sudo_cmd; sudo_cmd="$(sudo_prefix)"

  if command -v apt-get >/dev/null 2>&1; then
    info "installing packages with apt-get: ${packages[*]}"
    $sudo_cmd apt-get update
    $sudo_cmd apt-get install -y "${packages[@]}" ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    local -a dnf_packages=()
    local p
    for p in "${packages[@]}"; do
      [[ "$p" == openssh-client ]] && p=openssh-clients
      dnf_packages+=("$p")
    done
    info "installing packages with dnf: ${dnf_packages[*]}"
    $sudo_cmd dnf install -y "${dnf_packages[@]}" ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    local -a apk_packages=()
    local p
    for p in "${packages[@]}"; do
      [[ "$p" == openssh-client ]] && p=openssh-client
      apk_packages+=("$p")
    done
    info "installing packages with apk: ${apk_packages[*]}"
    $sudo_cmd apk add "${apk_packages[@]}" ca-certificates bash
  else
    die "no supported package manager found (apt-get, dnf, apk)"
  fi

  local cmd
  for cmd in curl tmux git python3 ssh; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is still unavailable after package installation"
  done
}

ensure_provider_clis() {
  ensure_local_bin_path

  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>/dev/null | head -1)"
  else
    info "installing Claude Code with Anthropic's native installer"
    curl -fsSL https://claude.ai/install.sh | bash
    hash -r
    command -v claude >/dev/null 2>&1 || die "Claude installer finished but 'claude' is not on PATH"
    ok "Claude Code installed: $(claude --version 2>/dev/null | head -1)"
  fi

  if command -v codex >/dev/null 2>&1; then
    ok "Codex CLI already installed: $(codex --version 2>/dev/null)"
  else
    info "installing Codex CLI with OpenAI's standalone installer"
    curl -fsSL https://chatgpt.com/codex/install.sh | env CODEX_NON_INTERACTIVE=1 sh
    hash -r
    command -v codex >/dev/null 2>&1 || die "Codex installer finished but 'codex' is not on PATH"
    ok "Codex CLI installed: $(codex --version 2>/dev/null)"
  fi
}

ensure_provider_auth() {
  if [[ "$SKIP_AUTH" == 1 ]]; then
    warn "provider authentication skipped (--skip-auth)"
    return
  fi
  [[ -t 0 ]] || die "--bootstrap authentication requires an interactive terminal; rerun with a TTY or use --skip-auth"

  if claude_auth_status; then
    ok "Claude Code authentication already active"
  else
    info "Claude Code login is required. Complete the official browser/device flow."
    if ! claude auth login; then
      warn "'claude auth login' failed; falling back to an interactive Claude session"
      say "  Complete login, then type /exit so bootstrap can continue."
      claude
    fi
    claude_auth_status || die "Claude Code still reports that it is not logged in"
    ok "Claude Code login complete"
  fi

  if codex_auth_status; then
    ok "Codex CLI authentication already active"
  else
    info "Codex login is required. Sign in with the ChatGPT account you want cc-orchestra to use."
    codex login
    codex_auth_status || die "Codex CLI still reports that it is not logged in"
    ok "Codex CLI login complete"
  fi
}

install_repo() {
  echo "cc-orchestra @ $REPO_DIR"
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: Python 3 is required." >&2; exit 1; }
  mkdir -p "$CLAUDE_DIR/agents" "$BIN_DIR"

  link "$REPO_DIR"                              "$CLAUDE_DIR/orchestra"
  link "$REPO_DIR/agents/orchestrator.md"       "$CLAUDE_DIR/agents/orchestrator.md"
  link "$REPO_DIR/agents/verifier-normal.md"    "$CLAUDE_DIR/agents/verifier-normal.md"
  link "$REPO_DIR/bin/cc-orch-runtime"           "$BIN_DIR/cc-orch"
  link "$REPO_DIR/bin/codex-run-runtime"         "$BIN_DIR/codex-run"
  link "$REPO_DIR/bin/orch-model-guard-runtime"  "$BIN_DIR/orch-model-guard"
  link "$REPO_DIR/bin/orch-summary-check"        "$BIN_DIR/orch-summary-check"
  link "$REPO_DIR/bin/orch-usage-report"         "$BIN_DIR/orch-usage-report"
  link "$REPO_DIR/bin/orch-archive"              "$BIN_DIR/orch-archive"
  link "$REPO_DIR/bin/cc-orch-codex"             "$BIN_DIR/cc-orch-codex"
  link "$REPO_DIR/bin/codex-run-codex"           "$BIN_DIR/codex-run-codex"
  link "$REPO_DIR/bin/orch-codex-route"          "$BIN_DIR/orch-codex-route"

  chmod +x "$REPO_DIR"/*.sh "$REPO_DIR/bin/"* "$REPO_DIR/hooks/"*.sh

  echo
  "$REPO_DIR/bin/orch-model-guard-runtime" check
  "$REPO_DIR/build-roster-runtime.sh"

  echo
  echo "model guard and reset-time taps:"
  "$REPO_DIR/bin/orch-model-guard-runtime" install
  install_runtime_hook
  install_safety_hooks

  echo
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "NOTE: $BIN_DIR is not on PATH — add it to use cc-orch directly." ;;
  esac
  echo "done. try: cc-orch session --help; orch-model-guard budget"
}

install_codex_only() {
  command -v python3 >/dev/null || die 'Python 3 is required'
  command -v codex >/dev/null || die 'Codex CLI is required; install and log in before using this mode'
  mkdir -p "$BIN_DIR"
  link "$REPO_DIR/bin/cc-orch-codex" "$BIN_DIR/cc-orch"
  link "$REPO_DIR/bin/cc-orch-codex" "$BIN_DIR/cc-orch-codex"
  link "$REPO_DIR/bin/codex-run-codex" "$BIN_DIR/codex-run"
  link "$REPO_DIR/bin/codex-run-codex" "$BIN_DIR/codex-run-codex"
  link "$REPO_DIR/bin/orch-codex-route" "$BIN_DIR/orch-codex-route"
  link "$REPO_DIR/bin/orch-summary-check" "$BIN_DIR/orch-summary-check"
  echo 'Codex-only launchers installed. No Claude settings, agents or timer changed.'
  echo 'Start: cc-orch-codex <project-name> [project-dir]'
}

run_regression_tests() {
  [[ "$SKIP_TESTS" == 0 ]] || { info "regression tests skipped (--skip-tests)"; return; }
  local test
  for test in \
    tests/test-policy.sh \
    tests/test-runtime.sh \
    tests/test-poll-guard.sh \
    tests/test-verifier-bash-guard.sh \
    tests/test-tier1-runtime.sh \
    tests/test-notice-runtime.sh \
    tests/test-worktree-guard.sh \
    tests/test-stop-gate.sh \
    tests/test-compact-context.sh \
    tests/test-hook-wiring.sh
  do
    [[ -f "$REPO_DIR/$test" ]] || continue
    info "running $test"
    bash "$REPO_DIR/$test"
  done
  ok "cc-orchestra regression tests passed"
}

bootstrap() {
  say "cc-orchestra fresh-host bootstrap @ $REPO_DIR"
  say
  say "[1/6] System dependencies"
  install_missing_system_dependencies

  say
  say "[2/6] PATH"
  ensure_local_bin_path
  ok "$BIN_DIR is active for this shell and persisted in ~/.profile + ~/.bashrc"

  say
  say "[3/6] Provider CLIs"
  ensure_provider_clis

  say
  say "[4/6] Provider authentication"
  ensure_provider_auth

  say
  say "[5/6] cc-orchestra install"
  install_repo

  say
  say "[6/6] Verification"
  echo "cc-orchestra @ $REPO_DIR"
  check
  run_regression_tests

  say
  say "bootstrap complete."
  say "Next:"
  say "  cc-orch session new main /path/to/project --project-name <name> --inplace"
  say "  orch-model-guard budget"
}

case "$MODE" in
  codex-only)
    install_codex_only
    ;;
  safety-hooks-only)
    install_safety_hooks
    ;;
  check)
    echo "cc-orchestra @ $REPO_DIR"
    check && echo "installed." || { echo "incomplete — run ./install.sh --bootstrap (fresh host) or ./install.sh (repo setup)"; exit 1; }
    ;;
  bootstrap)
    bootstrap
    ;;
  install)
    install_repo
    ;;
esac
