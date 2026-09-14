# Runtime budget snapshot/state helpers. Sourced by orch-model-guard-runtime.
bget() { [ -r "$BUDGET_STATE" ] && sed -n "s/^$1=//p" "$BUDGET_STATE" | head -1; }
lget() { [ -r "$LEGACY_STATE" ] && sed -n "s/^$1=//p" "$LEGACY_STATE" | head -1; }
now_epoch() { printf '%s\n' "${CC_ORCH_NOW_EPOCH:-$(date +%s)}"; }

budget_set() { # budget_set key value [key value...]
  local tmp="$BUDGET_STATE.$$.tmp" key value line
  local -a order=()
  declare -A updates=()
  while [ $# -gt 0 ]; do
    key="$1"; value="$2"; shift 2
    value="${value//$'\n'/ }"
    if [[ ! -v "updates[$key]" ]]; then order+=("$key"); fi
    updates["$key"]="$value"
  done
  exec 9>"$BUDGET_LOCK"
  flock 9
  : > "$tmp"
  if [ -r "$BUDGET_STATE" ]; then
    while IFS= read -r line; do
      key="${line%%=*}"
      [[ -v "updates[$key]" ]] || printf '%s\n' "$line" >> "$tmp"
    done < "$BUDGET_STATE"
  fi
  for key in "${order[@]}"; do printf '%s=%s\n' "$key" "${updates[$key]}" >> "$tmp"; done
  chmod 600 "$tmp"
  mv -f "$tmp" "$BUDGET_STATE"
  flock -u 9
}

is_numeric() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

cmd_ingest_claude() {
  local payload
  payload="$(cat)"
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | python3 -c '
import fcntl, json, os, sys, tempfile
path, lock_path, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    obj = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
rl = obj.get("rate_limits") or {}
five = rl.get("five_hour") or {}
week = rl.get("seven_day") or {}
if five.get("used_percentage") is None and week.get("used_percentage") is None:
    raise SystemExit(0)
def clean_pct(v):
    if v is None: return ""
    try: return ("%.2f" % float(v)).rstrip("0").rstrip(".")
    except Exception: return ""
def clean_epoch(v):
    try: return str(int(v)) if v is not None else ""
    except Exception: return ""
updates = {
    "claude_five_pct": clean_pct(five.get("used_percentage")),
    "claude_five_resets_at": clean_epoch(five.get("resets_at")),
    "claude_week_pct": clean_pct(week.get("used_percentage")),
    "claude_week_resets_at": clean_epoch(week.get("resets_at")),
    "claude_asof_epoch": str(now),
    "claude_source": "statusline",
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(lock_path, "a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    data = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1); data[k] = v
    data.update(updates)
    fd, tmp = tempfile.mkstemp(prefix="budget.", dir=os.path.dirname(path), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            for k in sorted(data): out.write(f"{k}={data[k]}\n")
        os.chmod(tmp, 0o600); os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
' "$BUDGET_STATE" "$BUDGET_LOCK" "$(now_epoch)"
  recompute_metrics >/dev/null 2>&1 || true
}

newest_rollout() {
  [ -d "$CODEX_SESSIONS" ] || return 1
  local now today yesterday d f
  now="$(now_epoch)"
  today="$(date -d "@$now" +%Y/%m/%d 2>/dev/null)"
  yesterday="$(date -d "@$((now - 86400))" +%Y/%m/%d 2>/dev/null)"
  for d in "$CODEX_SESSIONS/$today" "$CODEX_SESSIONS/$yesterday"; do
    [ -d "$d" ] || continue
    f="$(ls -t "$d"/rollout-*.jsonl 2>/dev/null | head -1)"
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  f="$(find "$CODEX_SESSIONS" -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
       | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  return 1
}

refresh_codex_usage() {
  local f mtime age line out pct resets checked checked_home now
  now="$(now_epoch)"
  checked="$(bget codex_checked_epoch)"; checked_home="$(bget codex_checked_home)"
  if [ "$checked_home" = "$CODEX_SESSIONS" ] && is_numeric "$checked" && \
     [ $((now - ${checked%.*})) -lt "$BUDGET_CODEX_REFRESH_SECONDS" ]; then
    return 0
  fi
  f="$(newest_rollout)" || { budget_set codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS"; return 1; }
  mtime="$(stat -c %Y "$f" 2>/dev/null)" || { budget_set codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS"; return 1; }
  age=$(( now - mtime ))
  [ "$age" -le $((BUDGET_CODEX_STALE_HOURS * 3600)) ] || { budget_set codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS"; return 1; }
  line="$(grep '"rate_limits"' "$f" 2>/dev/null | tail -1)"
  [ -n "$line" ] || { budget_set codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS"; return 1; }
  out="$(printf '%s' "$line" | python3 -c '
import json, sys
def find(node):
    if isinstance(node, dict):
        rl = node.get("rate_limits")
        if isinstance(rl, dict): return rl
        for value in node.values():
            hit = find(value)
            if hit is not None: return hit
    elif isinstance(node, list):
        for value in node:
            hit = find(value)
            if hit is not None: return hit
    return None
try:
    rl = find(json.load(sys.stdin)) or {}
    primary = rl.get("primary") or {}
    pct = primary.get("used_percent")
    if pct is None: raise ValueError
    print(("%.2f" % float(pct)).rstrip("0").rstrip("."), primary.get("resets_at") or "")
except Exception:
    raise SystemExit(1)
' 2>/dev/null)" || { budget_set codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS"; return 1; }
  pct="${out%% *}"; resets="${out#* }"; [ "$resets" = "$out" ] && resets=""
  budget_set codex_pct "$pct" codex_resets_at "$resets" codex_asof_epoch "$mtime" \
             codex_checked_epoch "$now" codex_checked_home "$CODEX_SESSIONS" codex_source rollout
  recompute_metrics >/dev/null 2>&1 || true
}

sync_legacy_claude() {
  local asof age five week checked epoch
  asof="$(bget claude_asof_epoch)"
  if is_numeric "$asof"; then
    age=$(( $(now_epoch) - ${asof%.*} ))
    [ "$age" -le $((BUDGET_CLAUDE_STALE_MINUTES * 60)) ] && return 0
  fi
  five="$(lget session_pct)"; week="$(lget all_pct)"; checked="$(lget checked_at)"
  is_numeric "$five" || five=""
  is_numeric "$week" || week=""
  [ -n "$five$week" ] || return 1
  epoch="$(date -d "$checked" +%s 2>/dev/null)" || epoch="$(now_epoch)"
  budget_set claude_five_pct "$five" claude_five_resets_at "" \
             claude_week_pct "$week" claude_week_resets_at "" \
             claude_asof_epoch "$epoch" claude_source usage-panel
  recompute_metrics >/dev/null 2>&1 || true
}

ensure_budget() {
  if [ "${CC_ORCH_BACKEND:-claude}" = codex ]; then
    refresh_codex_usage || true
    return 0
  fi
  local asof
  asof="$(bget claude_asof_epoch)"
  if ! is_numeric "$asof" || [ $(( $(now_epoch) - ${asof%.*} )) -gt $((BUDGET_CLAUDE_STALE_MINUTES * 60)) ]; then
    "$CORE" check >/dev/null 2>&1 || true
  fi
  sync_legacy_claude || true
  refresh_codex_usage || true
}
