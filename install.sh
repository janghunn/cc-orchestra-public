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
DRY_RUN=0
SKIP_AUTH=0
SKIP_TESTS=0

usage() {
  cat <<'EOF'
usage:
  ./install.sh
  ./install.sh --dry-run [--codex-only|--safety-hooks-only]
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
  --dry-run     preview install actions without writes to install targets; temporary profile
                rendering uses a safe directory under $TMPDIR or /tmp, removed before exit
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
    --dry-run) DRY_RUN=1 ;;
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

if [[ "$DRY_RUN" == 1 && "$MODE" == bootstrap ]]; then
  echo 'ERROR: --dry-run does not preview --bootstrap (system packages, provider installers, logins); run ./install.sh --dry-run to preview the install step.' >&2
  exit 2
fi
if [[ "$DRY_RUN" == 1 && "$MODE" == check ]]; then
  echo 'ERROR: --dry-run and --check cannot be combined; --check inspects, --dry-run previews.' >&2
  exit 2
fi

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
  if [[ "$DRY_RUN" == 1 ]]; then
    dest="$(plan_path "$dest")"
    if [[ -L "$dest" ]]; then
      local current; current="$(readlink -f "$dest" || readlink "$dest")"
      if [[ "$current" == "$(readlink -f "$src")" ]]; then
        plan unchanged "$dest -> $src"
      else
        plan relink "$dest -> $src (was -> $current)"
      fi
    elif [[ -e "$dest" ]]; then
      plan backup-then-replace "$dest -> $dest.pre-cc-orchestra"
    else
      plan create "$dest -> $src"
    fi
    return
  fi
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
  python3 - "${CC_ORCH_SETTINGS:-$CLAUDE_DIR/settings.json}" "$REPO_DIR" "${1:-repair}" <<'PY'
import copy, json, os, re, shlex, sys, tempfile
SAFETY_HOOKS = (
    ("PreToolUse", "Bash", "orch-worktree-guard.sh", 10),
    ("SubagentStop", "(route-)?lead-.*", "orch-stop-gate.sh", 30),
    ("SessionStart", "compact", "orch-compact-context.sh", 10),
)

OUR_SHAPE = re.compile(
    r"bash (?:(?P<plain>/[\w@%+=:,./-]*)|'(?P<quoted>/[^'\x00-\x1f\x7f]*)')"
    r"(?P<or_true>[ \t]*\|\|[ \t]*true)?(?:[ \t]+#[^\n]*)?", re.ASCII)
# Shapes ever written: install.sh 4b750d1 ("bash " + shlex.quote(path) + " || true"), guardrails.json
# 4b750d1 (bash '<path>' || true) and f4053e3 (bash <path> || true); tests also use no-or-true and '||true'.

def our_shape(hook, basename, command):
    """Match object (or True for the exact canonical command) when this is our one-line hook."""
    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
        return None
    if hook["command"] == command:
        return True
    match = OUR_SHAPE.fullmatch(hook["command"])
    if match and (match["plain"] or match["quoted"]).endswith("/hooks/" + basename):
        return match
    return None

path, repo = sys.argv[1:3]
mode = sys.argv[3] if len(sys.argv) > 3 else "repair"
path = os.path.abspath(path)
if mode == "check":
    settings = {}
    reason = ""
    try:
        with open(path, encoding="utf-8") as source:
            settings = json.load(source)
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError):
        reason = " (unreadable settings)"
    except ValueError:
        reason = " (invalid JSON)"
    if not isinstance(settings, dict):
        settings = {}
        reason = " (settings must be a JSON object)"
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        reason = " (hooks must be a JSON object)"
    rc = 0
    for event, matcher, basename, timeout in SAFETY_HOOKS:
        entries = hooks.get(event, [])
        event_reason = reason
        if not isinstance(entries, list):
            entries = []
            event_reason = f" (hooks.{event} must be a list)"
        command = "bash " + shlex.quote(os.path.join(repo, "hooks", basename)) + " || true"
        matches = [(entry, hook) for entry in entries
                   if isinstance(entry, dict) and isinstance(entry.get("hooks"), list)
                   for hook in entry["hooks"] if our_shape(hook, basename, command)]
        if not matches:
            print(f"  MISSING  {basename} in settings.json{event_reason}")
            rc = 1
            continue
        problems = []
        if len(matches) > 1:
            problems.append(f"{len(matches)} registrations (expect 1)")
        for entry, hook in matches:
            if entry.get("matcher") != matcher:
                problems.append(f"matcher {json.dumps(entry.get('matcher'))} (expect {json.dumps(matcher)})")
            result = our_shape(hook, basename, command)
            if hook.get("type") != "command" or not (result is True or result["or_true"]):
                problems.append("command is not the fail-open 'bash … || true' command form")
        if problems:
            problems.append("re-run ./install.sh --safety-hooks-only to repair")
            for problem in problems:
                print(f"  STALE    {basename} under {event}: {problem}")
            rc = 1
        else:
            print(f"  ok       {basename} in settings.json")
    raise SystemExit(rc)

if mode != "plan":
    os.makedirs(os.path.dirname(path), exist_ok=True)
settings = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as source:
            settings = json.load(source)
    except (OSError, ValueError) as exc:
        if mode != "plan":
            raise
        print(f"{'merge-json':20s} {path} ERROR: {exc} (the install would stop here)")
        raise SystemExit(1)
elif mode == "plan":
    print(f"{'create':20s} {path}")
hooks = settings.setdefault("hooks", {})
if mode == "plan":
    original_hooks = copy.deepcopy(hooks)
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
            if our_shape(hook, basename, command):
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
if mode == "plan":
    for event, matcher, basename, timeout in SAFETY_HOOKS:
        before = original_hooks.get(event, [])
        command = "bash " + shlex.quote(os.path.join(repo, "hooks", basename)) + " || true"
        matches = [hook for entry in before if isinstance(entry, dict)
                   and isinstance(entry.get("hooks"), list)
                   for hook in entry["hooks"] if our_shape(hook, basename, command)]
        action = "unchanged" if before == hooks[event] else "canonicalise" if matches else "add"
        print(f"{'merge-json':20s} {path} hooks.{event}[{matcher}]: {action} {basename}")
        unrelated = sum(1 for entry in before if isinstance(entry, dict)
                        and isinstance(entry.get("hooks"), list)
                        for hook in entry["hooks"] if not our_shape(hook, basename, command))
        if unrelated:
            print(f"{'merge-json':20s} {path} hooks.{event}: keep {unrelated} unrelated hook(s)")
    raise SystemExit(0)
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
    "$BIN_DIR/orch-archive:$REPO_DIR/bin/orch-archive" \
    "$BIN_DIR/orch-gc:$REPO_DIR/bin/orch-gc"
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

  install_safety_hooks check || rc=1

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

# Dry-run helpers only inspect install targets. The roster builder is confined to disposable storage.
plan() { printf '%-20s %s\n' "$1" "$2"; }

plan_path() { python3 -c '
import os, sys
def physical(path, planned=()):
    planned = {os.path.realpath(p) for p in planned}
    current = "/" if os.path.isabs(path) else os.getcwd()
    parts = path.split("/")
    for index, part in enumerate(parts):
        if part in ("", "."):
            continue
        if part == "..":
            if os.path.islink(current):
                target = os.path.realpath(current)
                if os.path.isdir(target) or target in planned:
                    current = os.path.dirname(target)
                    continue
            if os.path.lexists(current) and not os.path.isdir(current):
                return current + "/" + "/".join(parts[index:])
            current = os.path.dirname(current)
        else:
            current = os.path.join(current, part)
    return current
print(physical(sys.argv[1], sys.argv[2:]))' "$1" "${!PLANNED_DIRS[@]}"; }

declare -A PLANNED_DIRS=()
plan_dir() {
  local dir; dir="$(plan_path "$1")"
  if [[ ! -d "$dir" && ( -e "$dir" || -L "$dir" ) ]]; then
    plan error "$dir (exists and is not a directory; the install would stop here)"
    exit 1
  fi
  [[ -z "${PLANNED_DIRS[$dir]:-}" ]] || return 0
  if [[ -d "$dir" ]]; then
    plan unchanged "${dir%/}/"
  else
    plan_dir "$(dirname "$dir")"
    plan create "${dir%/}/"
  fi
  PLANNED_DIRS[$dir]=1
}

dry_run_install_rest() {
  local bin poll refresh
  bin="${CLAUDE_BIN:-$(command -v claude || true)}"
  poll="$(. "$REPO_DIR/model-policy.conf"; printf '%s' "$POLL_MINUTES")"
  refresh="$(. "$REPO_DIR/budget-policy.conf"; printf '%s' "${BUDGET_STATUSLINE_REFRESH_SECONDS:-60}")"
  python3 - "$REPO_DIR" "$BIN_DIR" "$bin" "$poll" <<'PY'
import glob, json, os, pathlib, shutil, stat, subprocess, sys, tempfile
def physical(path, planned=()):
    planned = {os.path.realpath(p) for p in planned}
    current = '/' if os.path.isabs(path) else os.getcwd()
    parts = path.split('/')
    for index, part in enumerate(parts):
        if part in ('', '.'):
            continue
        if part == '..':
            if os.path.islink(current):
                target = os.path.realpath(current)
                if os.path.isdir(target) or target in planned:
                    current = os.path.dirname(target)
                    continue
            if os.path.lexists(current) and not os.path.isdir(current):
                return current + '/' + '/'.join(parts[index:])
            current = os.path.dirname(current)
        else:
            current = os.path.join(current, part)
    return current

planned = set()
def remember(path):
    directory = pathlib.Path(physical(path, planned))
    planned.update(os.path.realpath(p) for p in (directory, *directory.parents))

repo, bin_dir, claude, poll = sys.argv[1:]
# Guard facades resolve their own script path; the installer and roster keep the logical path.
guard_repo = os.path.realpath(repo)
home = os.environ['HOME']
# Resolve each override against directories created by earlier install steps.
remember(home + '/.claude/agents')
bin_dir = physical(bin_dir, planned)
remember(bin_dir)
initial_dirs = planned.copy()
state = physical(os.environ.get('CC_ORCH_STATE_DIR') or home + '/.claude/orchestra-state', planned)
remember(state)
raw_agents = os.environ.get('CC_ORCH_AGENTS_DIR') or home + '/.claude/agents'
agents = physical(raw_agents, planned)
remember(agents)
manifest = physical(os.environ.get('CC_ORCH_MANIFEST') or agents + '/.install-manifest.json', planned)
remember(os.path.dirname(manifest))
units = physical(os.environ.get('CC_ORCH_UNIT_DIR') or home + '/.config/systemd/user', planned)
if os.access(claude, os.X_OK):
    remember(units)
h = os.path.abspath(home + '/.claude/settings.json')
raw_settings = os.environ.get('CC_ORCH_SETTINGS') or h
s = physical(raw_settings, planned)
# Only the initial mkdir calls were reported by bash; report later directories below.
planned = initial_dirs

def plan(action, detail):
    print(f'{action:20s} {detail}', flush=True)

def plan_dir(path):
    path = physical(path, planned)
    if os.path.lexists(path) and not os.path.isdir(path):
        plan('error', path + ' (exists and is not a directory; the install would stop here)')
        raise SystemExit(1)
    # An unresolved .. must recurse to its blocking component before deduplication.
    if '..' not in path.split('/') and os.path.realpath(path) in planned:
        return
    if os.path.isdir(path):
        plan('unchanged', path.rstrip('/') + '/')
        planned.add(os.path.realpath(path))
        return
    plan_dir(os.path.dirname(path))
    plan('create', path.rstrip('/') + '/')
    planned.add(os.path.realpath(path))

mask = os.umask(0)
os.umask(mask)
unchanged = 0
for path in sorted(glob.glob(repo + '/*.sh') + glob.glob(repo + '/bin/*') + glob.glob(repo + '/hooks/*.sh')):
    old = stat.S_IMODE(os.stat(path).st_mode)
    new = old | (0o111 & ~mask)
    if new != old:
        plan('chmod', f'{path} ({old:04o} -> {new:04o})')
    else:
        unchanged += 1
plan('unchanged', f'chmod +x ({unchanged} files already executable)')
plan_dir(state)
backend_codex = (os.environ.get('CC_ORCH_BACKEND') or 'claude') == 'codex'
if backend_codex:
    plan('state-dependent', state + '/ (CC_ORCH_BACKEND=codex: Codex budget refresh only)')
else:
    plan('state-dependent', state + '/ (orch-model-guard check: polls Claude usage; refreshes .lock state guard.log last-usage.txt budget-state .budget.lock)')
    plan('state-dependent', agents + '/lead-*.md (a quota switch rewrites model lines)')
plan_dir(agents)
plan_dir(os.path.dirname(manifest))

# Resolve symlinks before choosing scratch space: even create+delete would change target metadata.
targets = [os.path.realpath(p) for p in
           (home, state, agents, os.path.dirname(manifest), units, bin_dir,
            os.path.dirname(h), os.path.dirname(s), os.path.dirname(os.path.abspath(raw_settings)), repo)]
base = next((os.path.realpath(p) for p in (os.environ.get('TMPDIR') or '/tmp', '/tmp')
             if os.path.isdir(p) and os.access(p, os.W_OK | os.X_OK)
             and not any(os.path.commonpath((os.path.realpath(p), t)) == t for t in targets)), None)

def compare(path, data, mode=None, through=False):
    exists = os.path.lexists(path)
    equal = False
    if os.path.isfile(path):
        equal = pathlib.Path(path).read_bytes() == data
        if not through:
            equal = equal and not os.path.islink(path) and stat.S_IMODE(os.stat(path).st_mode) == mode
    action = 'unchanged' if equal else 'replace' if exists else 'create'
    detail = ''
    if action == 'replace':
        detail = (f' (writes through symlink to {os.path.realpath(path)})'
                  if through and os.path.islink(path) else ' (replaced, no backup)')
    return action, path + detail

if base is None:
    plan('state-dependent', agents + '/ (profiles not pre-rendered: no temporary directory outside the install targets)')
else:
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix='cc-orchestra-plan.', dir=base)
        scratch_agents = tmp + '/agents'
        scratch_manifest = scratch_agents + '/.install-manifest.json'
        os.mkdir(tmp + '/state')
        if os.access(state + '/state', os.R_OK):
            shutil.copyfile(state + '/state', tmp + '/state/state')
        env = dict(os.environ, CC_ORCH_AGENTS_DIR=scratch_agents,
                   CC_ORCH_MANIFEST=scratch_manifest, CC_ORCH_STATE_DIR=tmp + '/state', TMPDIR=tmp)
        env.pop('CC_ORCH_MANIFEST_NO_COMMIT', None)
        env.pop('CC_ORCH_MANIFEST_STAGING', None)
        rendered = subprocess.run(['bash', repo + '/build-roster-runtime.sh'], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if rendered.returncode:
            raise ValueError(rendered.stderr.strip() or f'builder exit {rendered.returncode}')
        # Manifest order is render order, including core profiles before route profiles.
        with open(scratch_manifest, encoding='utf-8') as entries:
            for line in entries:
                path = agents + '/' + os.path.basename(json.loads(line)['dest'])
                if os.path.isdir(path):
                    plan('error', f'{path} (a directory occupies this generated profile; the roster builder fails here and the install stops before units and settings)')
                    raise SystemExit(1)
        counts = dict(create=0, replace=0, unchanged=0)
        profiles = sorted(pathlib.Path(scratch_agents).glob('*.md'))
        for profile in profiles:
            action, detail = compare(agents + '/' + profile.name, profile.read_bytes(),
                                     stat.S_IMODE(profile.stat().st_mode), profile.name.startswith('route-lead-'))
            counts[action] += 1
            if action != 'unchanged':
                plan(action, detail)
        leads = sum(p.name.startswith('lead-') for p in profiles)
        plan('generate-profiles', f'{agents}/ ({len(profiles)} profiles: {counts["create"]} create, '
             f'{counts["replace"]} replace, {counts["unchanged"]} unchanged; {leads} lead-*.md and '
             'the manifest use the current guard state — state-dependent)')
        # Match the builder's spelling, including logical PWD and its JSON escaping.
        builder_agents = raw_agents
        if not os.path.isabs(builder_agents):
            pwd = os.environ.get('PWD', '')
            try:
                logical = os.path.isabs(pwd) and os.path.samefile(pwd, '.')
            except OSError:
                logical = False
            builder_agents = (pwd if logical else os.getcwd()) + '/' + builder_agents
        def json_escape(value):
            return value.replace('\\', '\\\\').replace('"', '\\"')
        data = pathlib.Path(scratch_manifest).read_text()
        for old, new in ((scratch_manifest, manifest), (scratch_agents, builder_agents)):
            data = data.replace(json_escape(old), json_escape(new))
        plan(*compare(manifest, data.encode(), stat.S_IMODE(os.stat(scratch_manifest).st_mode)))
    except (OSError, ValueError) as exc:
        plan('state-dependent', f'{agents}/ (profiles could not be pre-rendered: {str(exc).replace(chr(10), "; ")})')
    finally:
        if tmp is not None:
            shutil.rmtree(tmp)

if backend_codex:
    plan('error', 'orch-model-guard install (CC_ORCH_BACKEND=codex refuses it; the real install stops here: no units, hooks or status line)')
    raise SystemExit(1)
if not os.access(claude, os.X_OK):
    plan('unchanged', 'orch-model-guard install (claude not on PATH: skips units and the notice hook)')
else:
    plan_dir(units)
    source = pathlib.Path(guard_repo + '/bin/orch-model-guard').read_text()
    for ext in ('service', 'timer'):
        path = units + '/orch-model-guard.' + ext
        marker = '  cat > "$UNIT_DIR/orch-model-guard.' + ext + '" <<EOF\n'
        if marker not in source or '\nEOF\n' not in source.split(marker, 1)[1]:
            plan('replace', path + ' (content not previewed)')
            continue
        body = source.split(marker, 1)[1].split('\nEOF\n', 1)[0] + '\n'
        body = body.replace('$(dirname "$bin")', os.path.dirname(claude) or '.').replace('$REPO_DIR', guard_repo).replace('${POLL_MINUTES}', poll)
        plan(*compare(path, body.encode(), through=True))
    detail = ('systemctl --user daemon-reload; enable --now' if shutil.which('systemctl') else
              'systemctl not found; the install will report an error here')
    plan('enable-unit', f'orch-model-guard.timer ({detail})')
PY
  dry_run_settings "$bin" "$refresh"
  # The settings planner already reports creation of a missing settings file.
  install_safety_hooks plan | sed '/^create /d'
}

dry_run_settings() {
  python3 - "$REPO_DIR" "$BIN_DIR" "$1" "$2" <<'PY'
import copy, json, os, pathlib, sys
def physical(path, planned=()):
    planned = {os.path.realpath(p) for p in planned}
    current = '/' if os.path.isabs(path) else os.getcwd()
    parts = path.split('/')
    for index, part in enumerate(parts):
        if part in ('', '.'):
            continue
        if part == '..':
            if os.path.islink(current):
                target = os.path.realpath(current)
                if os.path.isdir(target) or target in planned:
                    current = os.path.dirname(target)
                    continue
            if os.path.lexists(current) and not os.path.isdir(current):
                return current + '/' + '/'.join(parts[index:])
            current = os.path.dirname(current)
        else:
            current = os.path.join(current, part)
    return current

planned_dirs = set()
# Account for mkdir -p in real-install order, including shared ancestors.
def remember(path):
    directory = pathlib.Path(physical(path, planned_dirs))
    planned_dirs.update(os.path.realpath(p) for p in (directory, *directory.parents))

repo, bin_dir, claude, refresh = sys.argv[1:]
guard_repo = os.path.realpath(repo)
home = os.environ['HOME']
remember(home + '/.claude/agents')
bin_dir = physical(bin_dir, planned_dirs)
remember(bin_dir)
state = physical(os.environ.get('CC_ORCH_STATE_DIR') or home + '/.claude/orchestra-state', planned_dirs)
remember(state)
agents = physical(os.environ.get('CC_ORCH_AGENTS_DIR') or home + '/.claude/agents', planned_dirs)
remember(agents)
manifest = physical(os.environ.get('CC_ORCH_MANIFEST') or agents + '/.install-manifest.json', planned_dirs)
remember(os.path.dirname(manifest))
units = physical(os.environ.get('CC_ORCH_UNIT_DIR') or home + '/.config/systemd/user', planned_dirs)
if os.access(claude, os.X_OK):
    remember(units)
h = os.path.abspath(home + '/.claude/settings.json')
raw_settings = os.environ.get('CC_ORCH_SETTINGS') or h
s = physical(raw_settings, planned_dirs)
s_lex = os.path.abspath(raw_settings)
settings = {}
created = set()

def plan(action, detail):
    print(f'{action:20s} {detail}')

def plan_dir(path):
    path = physical(path, planned_dirs)
    if os.path.lexists(path) and not os.path.isdir(path):
        plan('error', path + ' (exists and is not a directory; the install would stop here)')
        raise SystemExit(1)
    if '..' not in path.split('/') and (os.path.realpath(path) in planned_dirs or os.path.isdir(path)):
        return
    plan_dir(os.path.dirname(path))
    plan('create', path + '/')
    remember(path)

def load(path):
    if path not in settings:
        settings[path] = {}
        if os.path.exists(path):
            with open(path, encoding='utf-8') as source:
                settings[path] = json.load(source)
    return settings[path]

def create(path):
    plan_dir(os.path.dirname(path))
    if not os.path.exists(path) and path not in created:
        plan('create', path)
        created.add(path)

path = s
try:
    current = load(s)
    if os.access(claude, os.X_OK):
        if os.path.realpath(os.path.dirname(s)) not in planned_dirs and not os.path.isdir(os.path.dirname(s)):
            plan('merge-json', s + ' hooks.UserPromptSubmit: skipped orch-model-notice.sh (parent directory missing; orch-model-guard install cannot write it — existing behaviour)')
        else:
            if os.path.exists(s):
                plan_dir(home + '/.claude/backups')
                plan('backup-then-replace', s + ' -> ' + home + '/.claude/backups/settings.json.<timestamp>.bak')
            create(s)
            hooks = current.setdefault('hooks', {})
            before = copy.deepcopy(hooks.get('UserPromptSubmit', []))
            removed = [e for e in before if any('orch-model-notice.sh' in hook.get('command', '') for hook in e.get('hooks', []))]
            kept = [e for e in before if e not in removed]
            canonical = {'matcher': '*', 'hooks': [{'type': 'command', 'command': "bash '%s'" % (guard_repo + '/hooks/orch-model-notice.sh'), 'timeout': 10}]}
            after = kept + [canonical]
            hooks['UserPromptSubmit'] = after
            action = 'unchanged' if before == after else 'replace' if removed else 'add'
            detail = ''
            if action == 'replace':
                detail = f' ({len(removed)} entries removed; entry re-appended last; order changes or registration canonicalised)'
                other = sum('orch-model-notice.sh' not in hook.get('command', '') for e in removed for hook in e.get('hooks', []))
                if other:
                    detail += f' (WARNING: removed entries also carried {other} other hook(s))'
            plan('merge-json', f'{s} hooks.UserPromptSubmit: {action} orch-model-notice.sh{detail}; keep {len(kept)} other UserPromptSubmit entries')
    if not os.path.dirname(raw_settings):
        # register_statusline calls makedirs(dirname(raw_settings)); the facade continues on failure.
        plan('merge-json', s + ' statusLine: unchanged (settings path has no parent component; registration fails before writing)')
    else:
        lexical_parent = os.path.dirname(s_lex)
        plan_dir(os.path.dirname(s))
        def device(path):
            while not os.path.exists(path):
                path = os.path.dirname(path)
            return os.stat(path).st_dev
        same_device = device(lexical_parent) == device(os.path.dirname(s))
        registers = (os.path.isdir(lexical_parent) or os.path.realpath(lexical_parent) in planned_dirs) and same_device
        cur = current.get('statusLine')
        ours = isinstance(cur, dict) and 'orch-statusline.sh' in str(cur.get('command', ''))
        replacement = dict(cur) if isinstance(cur, dict) else {}
        replacement.update(type='command', command='bash ' + repr(guard_repo + '/hooks/orch-statusline.sh'))
        replacement.setdefault('refreshInterval', int(refresh))
        detail = 'unchanged (already orch-statusline.sh)' if replacement == cur else 'replace ' + str(cur.get('command', 'none') if isinstance(cur, dict) else 'none')
        previous = state + '/statusline.previous.json'
        if not ours:
            detail += f' (previous saved to {previous})'
        if registers:
            create(s)
            plan('merge-json', s + ' statusLine: ' + detail)
            current['statusLine'] = replacement
        elif not same_device:
            plan('merge-json', f'{s} statusLine: unchanged (registration writes its temporary file in {lexical_parent}/, on a different filesystem from {s}; os.replace fails after saving the previous value)')
        else:
            plan('merge-json', f'{s} statusLine: unchanged (registration writes its temporary file in {lexical_parent}/, which is missing; it fails after saving the previous value)')
        if not ours:
            plan('replace' if os.path.lexists(previous) else 'create', previous)
    path = h
    current = load(h)
    create(h)
    entries = current.setdefault('hooks', {}).setdefault('UserPromptSubmit', [])
    if not isinstance(entries, list):
        raise ValueError('settings hooks.UserPromptSubmit must be a list')
    command = repo + '/hooks/orch-runtime-context.sh'
    found = any(isinstance(hook, dict) and hook.get('command') == command
                for entry in entries if isinstance(entry, dict) for hook in entry.get('hooks', []))
    if not found:
        entries.append({'hooks': [{'type': 'command', 'command': command}]})
    plan('merge-json', h + ' hooks.UserPromptSubmit: ' + ('unchanged' if found else 'add') + ' orch-runtime-context.sh')
    # Safety repair uses an absolute path and can create S even if guard registration failed.
    create(s_lex)
except (OSError, ValueError, AttributeError, TypeError) as exc:
    plan('merge-json', f'{path} ERROR: {exc} (the install would stop here)')
    raise SystemExit(1)
PY
}

install_repo() {
  [[ "$DRY_RUN" == 1 ]] || echo "cc-orchestra @ $REPO_DIR"
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: Python 3 is required." >&2; exit 1; }
  if [[ "$DRY_RUN" == 1 ]]; then
    plan_dir "$CLAUDE_DIR/agents"
    plan_dir "$BIN_DIR"
  else
    mkdir -p "$CLAUDE_DIR/agents" "$BIN_DIR"
  fi

  link "$REPO_DIR"                              "$CLAUDE_DIR/orchestra"
  link "$REPO_DIR/agents/orchestrator.md"       "$CLAUDE_DIR/agents/orchestrator.md"
  link "$REPO_DIR/agents/verifier-normal.md"    "$CLAUDE_DIR/agents/verifier-normal.md"
  link "$REPO_DIR/bin/cc-orch-runtime"           "$BIN_DIR/cc-orch"
  link "$REPO_DIR/bin/codex-run-runtime"         "$BIN_DIR/codex-run"
  link "$REPO_DIR/bin/orch-model-guard-runtime"  "$BIN_DIR/orch-model-guard"
  link "$REPO_DIR/bin/orch-summary-check"        "$BIN_DIR/orch-summary-check"
  link "$REPO_DIR/bin/orch-usage-report"         "$BIN_DIR/orch-usage-report"
  link "$REPO_DIR/bin/orch-archive"              "$BIN_DIR/orch-archive"
  link "$REPO_DIR/bin/orch-gc"                   "$BIN_DIR/orch-gc"
  link "$REPO_DIR/bin/cc-orch-codex"             "$BIN_DIR/cc-orch-codex"
  link "$REPO_DIR/bin/codex-run-codex"           "$BIN_DIR/codex-run-codex"
  link "$REPO_DIR/bin/orch-codex-route"          "$BIN_DIR/orch-codex-route"

  if [[ "$DRY_RUN" == 1 ]]; then
    dry_run_install_rest
    return
  fi

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
  if [[ "$DRY_RUN" == 1 ]]; then plan_dir "$BIN_DIR"; else mkdir -p "$BIN_DIR"; fi
  link "$REPO_DIR/bin/cc-orch-codex" "$BIN_DIR/cc-orch"
  link "$REPO_DIR/bin/cc-orch-codex" "$BIN_DIR/cc-orch-codex"
  link "$REPO_DIR/bin/codex-run-codex" "$BIN_DIR/codex-run"
  link "$REPO_DIR/bin/codex-run-codex" "$BIN_DIR/codex-run-codex"
  link "$REPO_DIR/bin/orch-codex-route" "$BIN_DIR/orch-codex-route"
  link "$REPO_DIR/bin/orch-summary-check" "$BIN_DIR/orch-summary-check"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo 'codex-only: no Claude settings, agents or timer would change.'
    return
  fi
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

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "cc-orchestra dry-run @ $REPO_DIR — no changes made"
fi

case "$MODE" in
  codex-only)
    install_codex_only
    ;;
  safety-hooks-only)
    if [[ "$DRY_RUN" == 1 ]]; then
      plan_dir "$(python3 -c 'import os, sys; print(os.path.dirname(os.path.abspath(sys.argv[1])))' "${CC_ORCH_SETTINGS:-$CLAUDE_DIR/settings.json}")"
      install_safety_hooks plan
    else
      install_safety_hooks
    fi
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
