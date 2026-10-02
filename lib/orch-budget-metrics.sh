# Runtime budget normalization and model tables. Sourced by orch-model-guard-runtime.

# Compute all windows in one Python process. The result is cached in budget-state and normally
# refreshed by the Claude status-line tap or the once-per-minute Codex rollout scan.
compute_metrics_text() {
  python3 -c '
import sys
path, now_s, watch_s, tight_s, critical_s, near_s, uw_s, ut_s, uc_s = sys.argv[1:]
data={}
try:
    for raw in open(path, encoding="utf-8"):
        raw=raw.rstrip("\n")
        if "=" in raw:
            k,v=raw.split("=",1); data[k]=v
except FileNotFoundError:
    pass
now=int(now_s); watch=float(watch_s); tight=float(tight_s); critical=float(critical_s)
near=int(near_s); uw=float(uw_s); ut=float(ut_s); uc=float(uc_s)
ranks={"healthy":0,"watch":1,"tight":2,"critical":3,"unknown":-1}
def evaluate(pct_key, reset_key, window):
    try: pct=float(data.get(pct_key,""))
    except Exception: return ("unknown",-1,"?","?","?")
    try: reset=int(float(data.get(reset_key,"")))
    except Exception: reset=0
    if reset <= 0:
        state="critical" if pct>=uc else "tight" if pct>=ut else "watch" if pct>=uw else "healthy"
        return (state,ranks[state],"?","?","?")
    remaining=reset-now
    if remaining < 0: return ("unknown",-1,"?",str(remaining),"?")
    remaining=min(window,remaining)
    rem_time=remaining/window
    elapsed=max(0.0,1.0-rem_time)
    ratio=max(0.0,100.0-pct)/100.0/max(rem_time,1e-9)
    projected=pct/max(elapsed,0.05)
    if pct>=100: state="critical"
    elif remaining<=near: state="healthy"
    elif ratio<critical: state="critical"
    elif ratio<tight: state="tight"
    elif ratio<watch: state="watch"
    else: state="healthy"
    return (state,ranks[state],f"{ratio:.3f}",str(remaining),f"{projected:.1f}")
vals=[evaluate("claude_five_pct","claude_five_resets_at",18000),
      evaluate("claude_week_pct","claude_week_resets_at",604800),
      evaluate("codex_pct","codex_resets_at",604800)]
for v in vals: print("|".join(map(str,v)))
claude=[(vals[0],"five"),(vals[1],"week")]
claude.sort(key=lambda item:(item[0][1], -(float(item[0][2]) if item[0][2] not in ("?","") else 1e9)), reverse=True)
best, limiting=claude[0]
print("|".join((best[0],str(best[1]),best[2],limiting)))
' "$BUDGET_STATE" "$(now_epoch)" "$BUDGET_WATCH_RATIO" "$BUDGET_TIGHT_RATIO" \
    "$BUDGET_CRITICAL_RATIO" "$((BUDGET_NEAR_RESET_MINUTES * 60))" \
    "$BUDGET_UNKNOWN_WATCH_PCT" "$BUDGET_UNKNOWN_TIGHT_PCT" "$BUDGET_UNKNOWN_CRITICAL_PCT"
}

recompute_metrics() {
  local -a lines
  mapfile -t lines < <(compute_metrics_text)
  [ "${#lines[@]}" -ge 4 ] || return 1
  local f_state f_rank f_ratio f_remain f_projected
  local w_state w_rank w_ratio w_remain w_projected
  local x_state x_rank x_ratio x_remain x_projected
  local c_state c_rank c_ratio c_limiting
  IFS='|' read -r f_state f_rank f_ratio f_remain f_projected <<< "${lines[0]}"
  IFS='|' read -r w_state w_rank w_ratio w_remain w_projected <<< "${lines[1]}"
  IFS='|' read -r x_state x_rank x_ratio x_remain x_projected <<< "${lines[2]}"
  IFS='|' read -r c_state c_rank c_ratio c_limiting <<< "${lines[3]}"
  budget_set \
    claude_five_state "$f_state" claude_five_rank "$f_rank" claude_five_ratio "$f_ratio" \
    claude_five_remain "$f_remain" claude_five_projected "$f_projected" \
    claude_week_state "$w_state" claude_week_rank "$w_rank" claude_week_ratio "$w_ratio" \
    claude_week_remain "$w_remain" claude_week_projected "$w_projected" \
    claude_state "$c_state" claude_rank "$c_rank" claude_ratio "$c_ratio" claude_limiting "$c_limiting" \
    codex_state "$x_state" codex_rank "$x_rank" codex_ratio "$x_ratio" \
    codex_remain "$x_remain" codex_projected "$x_projected" metrics_asof_epoch "$(now_epoch)"
}

# Populates CLAUDE_* and CODEX_* from cached metrics. Recalculate only when the clock has advanced
# enough for reset-time headroom to materially change.
load_metrics() {
  local metrics_at key value
  metrics_at="$(bget metrics_asof_epoch)"
  if ! is_numeric "$metrics_at" || \
     [ $(( $(now_epoch) - ${metrics_at%.*} )) -gt "$BUDGET_METRICS_MAX_AGE_SECONDS" ]; then
    recompute_metrics || true
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      claude_five_state) CLAUDE_FIVE_STATE="$value" ;;
      claude_five_rank) CLAUDE_FIVE_RANK="$value" ;;
      claude_five_ratio) CLAUDE_FIVE_RATIO="$value" ;;
      claude_five_remain) CLAUDE_FIVE_REMAIN="$value" ;;
      claude_five_projected) CLAUDE_FIVE_PROJECTED="$value" ;;
      claude_week_state) CLAUDE_WEEK_STATE="$value" ;;
      claude_week_rank) CLAUDE_WEEK_RANK="$value" ;;
      claude_week_ratio) CLAUDE_WEEK_RATIO="$value" ;;
      claude_week_remain) CLAUDE_WEEK_REMAIN="$value" ;;
      claude_week_projected) CLAUDE_WEEK_PROJECTED="$value" ;;
      claude_state) CLAUDE_STATE="$value" ;;
      claude_rank) CLAUDE_RANK="$value" ;;
      claude_ratio) CLAUDE_RATIO="$value" ;;
      claude_limiting) CLAUDE_LIMITING="$value" ;;
      codex_state) CODEX_STATE="$value" ;;
      codex_rank) CODEX_RANK="$value" ;;
      codex_ratio) CODEX_RATIO="$value" ;;
      codex_remain) CODEX_REMAIN="$value" ;;
      codex_projected) CODEX_PROJECTED="$value" ;;
    esac
  done < "$BUDGET_STATE"
  : "${CLAUDE_FIVE_STATE:=unknown}" "${CLAUDE_FIVE_RANK:=-1}" "${CLAUDE_FIVE_RATIO:=?}" "${CLAUDE_FIVE_REMAIN:=?}" "${CLAUDE_FIVE_PROJECTED:=?}"
  : "${CLAUDE_WEEK_STATE:=unknown}" "${CLAUDE_WEEK_RANK:=-1}" "${CLAUDE_WEEK_RATIO:=?}" "${CLAUDE_WEEK_REMAIN:=?}" "${CLAUDE_WEEK_PROJECTED:=?}"
  : "${CLAUDE_STATE:=unknown}" "${CLAUDE_RANK:=-1}" "${CLAUDE_RATIO:=?}" "${CLAUDE_LIMITING:=none}"
  : "${CODEX_STATE:=unknown}" "${CODEX_RANK:=-1}" "${CODEX_RATIO:=?}" "${CODEX_REMAIN:=?}" "${CODEX_PROJECTED:=?}"
  resolve_codex_pin
}

# Apply policy only to the effective routing tier; cached metrics keep the real pressure.
resolve_codex_pin() {
  CODEX_EFFECTIVE_STATE="$CODEX_STATE"; CODEX_EFFECTIVE_RANK="$CODEX_RANK"
  CODEX_PIN_ACTIVE=0; CODEX_PIN_UNTIL_EPOCH=""; CODEX_PIN_NOTE=""
  local pin="${CODEX_PRESSURE_PIN:-}" until="${CODEX_PRESSURE_PIN_UNTIL:-}" until_epoch=""
  local absolute_date='^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$'
  [ -n "$pin" ] || return 0
  if [ "$pin" != healthy ]; then
    CODEX_PIN_NOTE="ignored: CODEX_PRESSURE_PIN='$pin' is not supported (only 'healthy'); Codex routing stays dynamic"
  elif [ -n "$until" ]; then
    if [[ "$until" =~ ^[0-9]+$ ]]; then
      until_epoch="$until"
    elif [[ "$until" =~ $absolute_date ]]; then
      until_epoch="$(date -d "$until" +%s 2>/dev/null)" || until_epoch=""
    fi
    if [ -z "$until_epoch" ]; then
      CODEX_PIN_NOTE="ignored: CODEX_PRESSURE_PIN_UNTIL='$until' is not an epoch or date; Codex routing stays dynamic"
    elif [ "$(now_epoch)" -ge "$until_epoch" ]; then
      CODEX_PIN_NOTE="expired at $(human_reset "$until_epoch") (ignored); Codex routing is dynamic"
      return 0
    fi
  fi
  if [ -n "$CODEX_PIN_NOTE" ]; then
    if [ "${CODEX_PIN_WARNED:-0}" != 1 ]; then
      printf 'orch-model-guard: %s\n' "$CODEX_PIN_NOTE" >&2
      CODEX_PIN_WARNED=1
    fi
    return 0
  fi
  CODEX_PIN_ACTIVE=1; CODEX_PIN_UNTIL_EPOCH="$until_epoch"
  CODEX_EFFECTIVE_STATE=healthy; CODEX_EFFECTIVE_RANK=0
}

human_reset() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then date -d "@$v" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$v"; else echo "?"; fi
}

human_duration() {
  local s="${1:-}"
  [[ "$s" =~ ^-?[0-9]+$ ]] || { echo "?"; return; }
  [ "$s" -lt 0 ] && { echo "expired"; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"; elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

compact_budget() {
  ensure_budget; load_metrics
  if [ "$CODEX_PIN_ACTIVE" = 1 ]; then
    printf 'claude=%s(5h:%s%%/%s,7d:%s%%/%s) codex=healthy(pinned; real=%s, 7d:%s%%/%s)' \
      "$CLAUDE_STATE" "$(bget claude_five_pct || true)" "$(human_duration "$CLAUDE_FIVE_REMAIN")" \
      "$(bget claude_week_pct || true)" "$(human_duration "$CLAUDE_WEEK_REMAIN")" \
      "$CODEX_STATE" "$(bget codex_pct || true)" "$(human_duration "$CODEX_REMAIN")"
    return
  fi
  printf 'claude=%s(5h:%s%%/%s,7d:%s%%/%s) codex=%s(7d:%s%%/%s)' \
    "$CLAUDE_STATE" "$(bget claude_five_pct || true)" "$(human_duration "$CLAUDE_FIVE_REMAIN")" \
    "$(bget claude_week_pct || true)" "$(human_duration "$CLAUDE_WEEK_REMAIN")" \
    "$CODEX_STATE" "$(bget codex_pct || true)" "$(human_duration "$CODEX_REMAIN")"
}

codex_route_values() { # mode state -> model effort allow
  local mode="$1" state="$2" upper_mode upper_state model_var effort_var allow_var model effort allow
  upper_mode="$(printf '%s' "$mode" | tr '[:lower:]-' '[:upper:]_')"
  upper_state="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
  model_var="CODEX_AUTO_${upper_mode}_${upper_state}_MODEL"
  effort_var="CODEX_AUTO_${upper_mode}_${upper_state}_EFFORT"
  allow_var="CODEX_AUTO_${upper_mode}_${upper_state}_ALLOW"
  model="${!model_var:-}"; effort="${!effort_var:-}"; allow="${!allow_var:-1}"
  if [ -z "$model" ] || [ -z "$effort" ]; then
    case "$mode" in
      implement) model="$CODEX_IMPL_MODEL"; effort="$CODEX_IMPL_EFFORT" ;;
      investigate) model="$CODEX_INVESTIGATE_MODEL"; effort="$CODEX_INVESTIGATE_EFFORT" ;;
      intake) model="$CODEX_INTAKE_MODEL"; effort="$CODEX_INTAKE_EFFORT" ;;
      review|plan-review) model="$CODEX_REVIEW_MODEL"; effort="$CODEX_REVIEW_EFFORT" ;;
      verify) model="$CODEX_VERIFY_MODEL"; effort="$CODEX_VERIFY_EFFORT" ;;
      *) return 1 ;;
    esac
  fi
  printf '%s|%s|%s\n' "$model" "$effort" "$allow"
}

profile_values() { # profile -> model|effort|suffix
  case "$1" in
    light) printf '%s|%s|-light\n' "$LEAD_LIGHT_MODEL" "$LEAD_LIGHT_EFFORT" ;;
    normal) printf '%s|%s|\n' "$LEAD_NORMAL_MODEL" "$LEAD_NORMAL_EFFORT" ;;
    critical) printf '%s|%s|-critical\n' "$LEAD_CRITICAL_MODEL" "$LEAD_CRITICAL_EFFORT" ;;
    critical-xhigh) printf '%s|%s|-critical-xhigh\n' "$LEAD_DEEP_MODEL" "$LEAD_DEEP_EFFORT" ;;
    *) return 1 ;;
  esac
}
