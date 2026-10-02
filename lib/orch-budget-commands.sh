# Runtime routing commands and install integration. Sourced by orch-model-guard-runtime.

# True when a lead profile resolves to the Fable model, i.e. when it actually draws the Fable
# weekly bucket that the reserve/exhaustion guards in cmd_route exist to protect. Matches on the
# model family the way hooks/orch-model-notice.sh's family() does, so any fable* variant counts.
# An unresolvable profile returns false; cmd_route hard-fails on it two lines later anyway.
profile_uses_fable() {
  local m
  m="$(profile_values "$1" 2>/dev/null | cut -d'|' -f1)" || return 1
  case "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" in
    *fable*) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_route() {
  local kind="${1:-}" arg="${2:-}" extra="${3:-}" slot="${4:-}"
  local state profile var values model effort suffix allow fable active pinned agent_type
  ensure_budget; load_metrics
  state="$CLAUDE_STATE"; [ "$state" = unknown ] && state=healthy
  case "$kind" in
    lead)
      case "$arg" in low|normal|critical) ;; *) echo "usage: orch-model-guard route lead <low|normal|critical> [deep] [slot]" >&2; return 2 ;; esac
      # For non-deep routes the third argument may be the slot. Deep routes use the fourth.
      if [ -n "$extra" ] && [ "$extra" != deep ] && [ "$extra" != yes ] && [ "$extra" != true ]; then
        slot="$extra"; extra=""
      fi
      if [ -n "$slot" ]; then
        case "$slot" in alpha|bravo|charlie|delta) ;; *) echo "invalid lead slot '$slot'" >&2; return 2 ;; esac
      fi
      if [ "$arg" = low ]; then
        profile=light
      elif [ "$arg" = normal ]; then
        var="CLAUDE_ROUTE_NORMAL_$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')_PROFILE"
        profile="${!var:-normal}"
      elif [ "$extra" = deep ] || [ "$extra" = yes ] || [ "$extra" = true ]; then
        var="CLAUDE_ROUTE_DEEP_$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')_PROFILE"
        profile="${!var:-critical-xhigh}"
      else
        var="CLAUDE_ROUTE_CRITICAL_$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')_PROFILE"
        profile="${!var:-critical}"
      fi
      # 2026-09-23: Both guards below protect the Fable weekly bucket. Since critical leads moved
      # to Opus 5.5 (model-policy.conf), profile names no longer say which profiles draw Fable, so
      # key on the resolved model instead: a profile whose model is not Fable is not conserving
      # anything by being downgraded here, and pressure-based effort tuning is the route table's
      # job, not this guard's.
      fable="$(lget fable_pct)"
      if is_numeric "$fable" && awk -v p="$fable" -v t="$BUDGET_FABLE_RESERVE_PCT" 'BEGIN { exit !(p >= t) }'; then
        profile_uses_fable "$profile" && profile=normal
      fi
      active="$(lget active)"; pinned="$(lget pinned)"
      # Global Fable exhaustion rewrites lead-*.md but not the immutable route-lead-* agents, so a
      # Fable-backed profile must still be steered away from here.
      if [ "$pinned" != 1 ] && [ "$active" = "$FALLBACK_MODEL" ]; then
        profile_uses_fable "$profile" && profile=normal
      fi
      values="$(profile_values "$profile")" || return 2
      IFS='|' read -r model effort suffix <<< "$values"
      if [ -n "$slot" ]; then agent_type="route-lead-$slot-$profile"; else agent_type="route-lead-{slot}-$profile"; fi
      echo "kind=lead"
      echo "profile=$profile"
      echo "agent_type=$agent_type"
      echo "agent_suffix=$suffix"
      echo "model=$model"
      echo "effort=$effort"
      echo "allow=1"
      echo "pressure=$CLAUDE_STATE"
      echo "reason=Claude limiting window=$CLAUDE_LIMITING; runtime policy is applied at dispatch"
      ;;
    orchestrator)
      case "$arg" in
        ""|normal)
          model="$PRIMARY_MODEL"; effort="$ORCH_EFFORT"
          ;;
        critical|deep)
          if [ "$arg" = deep ]; then values="$(cmd_route lead critical deep)"; else values="$(cmd_route lead critical)"; fi
          model="$(printf '%s\n' "$values" | sed -n 's/^model=//p')"
          effort="$(printf '%s\n' "$values" | sed -n 's/^effort=//p')"
          ;;
        *) echo "usage: orch-model-guard route orchestrator <normal|critical|deep>" >&2; return 2 ;;
      esac
      active="$(lget active)"; pinned="$(lget pinned)"
      if [ "$pinned" = 1 ] && [ -n "$active" ]; then model="$active"; fi
      echo "kind=orchestrator"
      echo "model=$model"
      echo "effort=$effort"
      echo "allow=1"
      echo "pressure=$CLAUDE_STATE"
      echo "reason=running Tier-1 model is stable; budget routing applies at lead/Codex boundaries"
      ;;
    codex)
      case "$arg" in implement|investigate|intake|review|plan-review|verify) ;; *) echo "usage: orch-model-guard route codex <mode>" >&2; return 2 ;; esac
      state="$CODEX_EFFECTIVE_STATE"; [ "$state" = unknown ] && state=healthy
      values="$(codex_route_values "$arg" "$state")" || return 2
      IFS='|' read -r model effort allow <<< "$values"
      echo "kind=codex"
      echo "mode=$arg"
      echo "model=$model"
      echo "effort=$effort"
      echo "allow=$allow"
      if [ "$CODEX_PIN_ACTIVE" = 1 ]; then
        echo "pressure=healthy"
        printf 'reason=Codex pressure pinned to healthy by CODEX_PRESSURE_PIN (real=%s); weekly headroom ratio=%s; reset=%s' \
          "$CODEX_STATE" "$CODEX_RATIO" "$(human_reset "$(bget codex_resets_at)")"
        if [ -n "$CODEX_PIN_UNTIL_EPOCH" ]; then printf ' pin-until=%s' "$(human_reset "$CODEX_PIN_UNTIL_EPOCH")"; fi
        echo
      else
        echo "pressure=$CODEX_STATE"
        echo "reason=Codex weekly headroom ratio=${CODEX_RATIO}; reset=$(human_reset "$(bget codex_resets_at)")"
      fi
      ;;
    *) echo "usage: orch-model-guard route <lead|orchestrator|codex> ..." >&2; return 2 ;;
  esac
}

cmd_lanes() {
  ensure_budget; load_metrics
  local hint=codex-first why="Codex owns heavy work; Claude already pays for orchestration"
  local c_ratio="$CLAUDE_RATIO" x_ratio="$CODEX_RATIO"
  local sparing_rank="${BUDGET_CODEX_SPARING_MIN_RANK:-3}"
  if [ "$CODEX_EFFECTIVE_RANK" -ge "$sparing_rank" ] && [ "$CODEX_EFFECTIVE_RANK" -gt "$CLAUDE_RANK" ]; then
    hint=codex-sparing
    why="Codex pressure ($CODEX_STATE) reached the provider reserve boundary; reserve it for gates"
  elif [ "$CODEX_EFFECTIVE_RANK" -ge "$sparing_rank" ] && [ "$CODEX_EFFECTIVE_RANK" -eq "$CLAUDE_RANK" ] && \
       is_numeric "$x_ratio" && is_numeric "$c_ratio"; then
    if awk -v x="$x_ratio" -v c="$c_ratio" -v m="$BUDGET_PROVIDER_SWITCH_MARGIN" \
       'BEGIN { exit !(x + m < c) }'; then
      hint=codex-sparing
      why="Codex has materially less reset-time headroom than Claude at the reserve boundary"
    fi
  fi
  if [ "$CLAUDE_RANK" -ge 3 ] && [ "$CODEX_EFFECTIVE_RANK" -lt 3 ]; then
    hint=codex-first
    why="Claude is critical; spend the separate Codex pool"
  fi
  echo "dispatch=$hint"
  echo "claude: pressure=$CLAUDE_STATE limiting=$CLAUDE_LIMITING 5h=$(bget claude_five_pct)% reset=$(human_reset "$(bget claude_five_resets_at)") 7d=$(bget claude_week_pct)% reset=$(human_reset "$(bget claude_week_resets_at)")"
  if [ "$CODEX_PIN_ACTIVE" = 1 ]; then
    echo "codex:  pressure=healthy(pinned; real=$CODEX_STATE) 7d=$(bget codex_pct)% reset=$(human_reset "$(bget codex_resets_at)")"
    why+="; Codex pressure pinned to healthy by CODEX_PRESSURE_PIN (real=$CODEX_STATE), so Codex pressure cannot trigger codex-sparing"
  else
    echo "codex:  pressure=$CODEX_STATE 7d=$(bget codex_pct)% reset=$(human_reset "$(bget codex_resets_at)")"
  fi
  echo "reason: $why; codex-run auto-selects model/effort per invocation"
}

cmd_budget() {
  if [ "${1:-}" = --compact ]; then compact_budget; echo; return; fi
  ensure_budget; load_metrics
  echo "runtime budget policy (no cc-orch reload required for new dispatches)"
  echo "claude  $CLAUDE_STATE (limiting: $CLAUDE_LIMITING)"
  echo "  5h    used=$(bget claude_five_pct)% headroom=${CLAUDE_FIVE_RATIO} reset=$(human_reset "$(bget claude_five_resets_at)") in $(human_duration "$CLAUDE_FIVE_REMAIN") source=$(bget claude_source)"
  echo "  7d    used=$(bget claude_week_pct)% headroom=${CLAUDE_WEEK_RATIO} reset=$(human_reset "$(bget claude_week_resets_at)") in $(human_duration "$CLAUDE_WEEK_REMAIN")"
  if [ "$CODEX_PIN_ACTIVE" = 1 ]; then
    printf 'codex   healthy (pinned by CODEX_PRESSURE_PIN; real=%s' "$CODEX_STATE"
    if [ -n "$CODEX_PIN_UNTIL_EPOCH" ]; then printf '; until %s' "$(human_reset "$CODEX_PIN_UNTIL_EPOCH")"; fi
    echo ')'
  else
    echo "codex   $CODEX_STATE"
  fi
  echo "  7d    used=$(bget codex_pct)% headroom=${CODEX_RATIO} reset=$(human_reset "$(bget codex_resets_at)") in $(human_duration "$CODEX_REMAIN") source=$(bget codex_source)"
  if [ "$CODEX_PIN_ACTIVE" != 1 ] && [ -n "$CODEX_PIN_NOTE" ]; then echo "  pin   $CODEX_PIN_NOTE"; fi
  echo
  cmd_lanes
}

register_statusline() { # install|uninstall
  python3 - "$1" "$STATUSLINE_HOOK" "$SETTINGS" "$STATUSLINE_PREVIOUS" "$BUDGET_STATUSLINE_REFRESH_SECONDS" <<'PY'
import json, os, sys, tempfile
mode, hook, settings_path, previous_path, refresh = sys.argv[1:]
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as fh: settings = json.load(fh)
    except Exception as exc:
        raise SystemExit(f"cannot parse {settings_path}: {exc}")
current = settings.get("statusLine")
ours = isinstance(current, dict) and "orch-statusline.sh" in str(current.get("command", ""))
if mode == "install":
    if not ours:
        os.makedirs(os.path.dirname(previous_path), exist_ok=True)
        with open(previous_path, "w", encoding="utf-8") as fh:
            json.dump(current, fh, ensure_ascii=False, indent=2); fh.write("\n")
        os.chmod(previous_path, 0o600)
    replacement = dict(current) if isinstance(current, dict) else {}
    replacement.update({"type":"command", "command":f"bash {hook!r}"})
    replacement.setdefault("refreshInterval", int(refresh))
    settings["statusLine"] = replacement
elif mode == "uninstall":
    if ours:
        previous = None
        if os.path.exists(previous_path):
            try:
                with open(previous_path, encoding="utf-8") as fh: previous = json.load(fh)
            except Exception: previous = None
        if previous is None: settings.pop("statusLine", None)
        else: settings["statusLine"] = previous
    try: os.unlink(previous_path)
    except FileNotFoundError: pass
else:
    raise SystemExit("bad mode")
fd, tmp = tempfile.mkstemp(prefix="settings.", dir=os.path.dirname(settings_path), text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(settings, out, ensure_ascii=False, indent=2); out.write("\n")
    os.replace(tmp, settings_path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

cmd_check() {
  "$CORE" check
  sync_legacy_claude || true
  refresh_codex_usage || true
}

cmd_status() {
  "$CORE" status
  echo
  cmd_budget
}

cmd_install() {
  "$CORE" install
  register_statusline install
  echo "  status   Claude 5h/7d reset-time tap -> $STATUSLINE_HOOK"
}

cmd_uninstall() {
  register_statusline uninstall
  "$CORE" uninstall
}
