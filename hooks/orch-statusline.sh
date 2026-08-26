#!/usr/bin/env bash
# Claude status-line tap: persist exact 5h/7d percentages and reset epochs, then preserve the
# user's previous status-line output. Runs locally and consumes no model tokens.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STATE_DIR="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}"
PREVIOUS="$STATE_DIR/statusline.previous.json"
GUARD="$REPO_DIR/bin/orch-model-guard-runtime"
payload="$(cat)"

[ -z "$payload" ] || printf '%s' "$payload" | "$GUARD" ingest-claude >/dev/null 2>&1 || true

previous_command=""
if [ -r "$PREVIOUS" ]; then
  previous_command="$(python3 - "$PREVIOUS" <<'PY'
import json, sys
try:
    obj=json.load(open(sys.argv[1], encoding="utf-8"))
    if isinstance(obj, dict) and obj.get("type") == "command": print(obj.get("command") or "")
except Exception:
    pass
PY
)"
fi

if [ -n "$previous_command" ] && [[ "$previous_command" != *orch-statusline.sh* ]]; then
  if printf '%s' "$payload" | timeout 3 bash -lc "$previous_command"; then exit 0; fi
fi

# No prior status line (or it failed): provide a compact, useful default.
printf '%s' "$payload" | python3 -c '
import json, sys, time
try: o=json.load(sys.stdin)
except Exception: raise SystemExit
m=(o.get("model") or {}).get("display_name") or (o.get("model") or {}).get("id") or "Claude"
rl=o.get("rate_limits") or {}
def part(label, key):
    w=rl.get(key) or {}; p=w.get("used_percentage"); r=w.get("resets_at")
    if p is None: return None
    reset="?"
    if r:
        left=max(0, int(r)-int(time.time()))
        reset=(f"{left//3600}h{(left%3600)//60:02d}m" if left>=3600 else f"{left//60}m")
    return f"{label}:{float(p):.0f}%/{reset}"
parts=[x for x in (part("5h","five_hour"),part("7d","seven_day")) if x]
print(f"[{m}] " + (" ".join(parts) if parts else "cc-orch budget: waiting for rate limits"))
'
