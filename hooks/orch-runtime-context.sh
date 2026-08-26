#!/usr/bin/env bash
# UserPromptSubmit hook that injects live provider/model routing into already-running cc-orch
# sessions. Ordinary quota/reset changes therefore apply at the next dispatch without reload.
set -uo pipefail

[ -n "${CC_ORCH_PROJECT:-}" ] || exit 0
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STATE_DIR="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}"
payload="$(cat)"

# Settings may include this hook from more than one scope. Emit once for a prompt id.
prompt_id="$(printf '%s' "$payload" | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("prompt_id") or "")
except Exception: pass
' 2>/dev/null)"
if [ -n "$prompt_id" ]; then
  prompt_hash="$(printf '%s' "$prompt_id" | sha256sum | awk '{print $1}')"
  stamp="$STATE_DIR/runtime-context/$prompt_hash"
  mkdir -p "$(dirname "$stamp")" 2>/dev/null
  ( set -o noclobber; : > "$stamp" ) 2>/dev/null || exit 0
  find "$(dirname "$stamp")" -type f -mtime +1 -delete 2>/dev/null || true
fi

budget="$("$REPO_DIR/bin/orch-model-guard-runtime" budget --compact 2>/dev/null)"
dispatch="$("$REPO_DIR/bin/orch-model-guard-runtime" lanes 2>/dev/null | sed -n '1p')"
context="cc-orchestra runtime routing is LIVE; no cc-orch reload is needed for usage/reset changes. Current: ${budget:-unknown}; ${dispatch:-dispatch=codex-first}. Before spawning each new lead, run '$REPO_DIR/bin/orch-model-guard-runtime route lead <low|normal|critical> [deep] <alpha|bravo|charlie|delta>' and spawn the returned agent_type (route-lead-*). For Codex work invoke '$REPO_DIR/bin/codex-run-runtime' with the normal codex-run arguments; it resolves Sol/Terra/Luna and effort for each new call unless explicit model/effort/critical/fast flags were supplied. Do not replace an already-running lead solely because a budget window moved; apply policy at the next dispatch boundary."
python3 - "$context" <<'PY'
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": sys.argv[1],
    }
}, ensure_ascii=False))
PY
