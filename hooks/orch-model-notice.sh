#!/usr/bin/env bash
# UserPromptSubmit hook: tell a running orchestra session when its cached policy is stale.
# Claude Code caches the session model/effort and all agent definitions at process start, so a
# restart is the only complete reload. /model changes Tier 1 only.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STATE="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/state"
[ -r "$STATE" ] || exit 0
# shellcheck source=/dev/null
. "$REPO_DIR/model-policy.conf"

active="$(sed -n 's/^active=//p' "$STATE" | head -1)"
[ -n "$active" ] || active="$PRIMARY_MODEL"

family() {
  case "$1" in
    *fable*) echo fable ;; *opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;;
    *) echo "" ;;
  esac
}

# cc-orch exports these. Older sessions are recovered from the ancestor argv where possible.
launch_model="${CC_ORCH_MODEL:-}"
launch_effort="${CC_ORCH_EFFORT:-unknown}"
launch_profile="${CC_ORCH_PROFILE:-normal}"
if [ -z "$launch_model" ]; then
  pid="$PPID"
  for _ in 1 2 3 4 5 6; do
    [ -r "/proc/$pid/cmdline" ] || break
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$args" in
      *"--agent orchestrator"*)
        launch_model="$(printf '%s' "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p')"
        launch_effort="$(printf '%s' "$args" | sed -n 's/.*--effort \([^ ]*\).*/\1/p')"
        break ;;
    esac
    pid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$pid" ] && [ "$pid" != "0" ] || break
  done
fi
[ -n "$launch_model" ] || exit 0

# Mirror the launcher exactly. Runtime-managed normal Tier-1 sessions stay on PRIMARY_MODEL even
# when the legacy Fable guard is globally on Opus. That legacy fallback still protects explicit
# critical/deep sessions. A normal runtime session may still use an explicit --model override.
runtime_normal=0
if [ "${CC_ORCH_RUNTIME_ROUTING:-0}" = "1" ] && [ "$launch_profile" = "normal" ]; then
  runtime_normal=1
  desired_model="$PRIMARY_MODEL"
elif [ "$active" = "$FALLBACK_MODEL" ]; then
  desired_model="$FALLBACK_MODEL"
elif [ "$active" != "$PRIMARY_MODEL" ]; then
  desired_model="$active"
else
  case "$launch_profile" in
    critical) desired_model="$LEAD_CRITICAL_MODEL" ;;
    deep)     desired_model="$LEAD_DEEP_MODEL" ;;
    *)        desired_model="$PRIMARY_MODEL" ;;
  esac
fi
case "$launch_profile" in
  critical) desired_effort="$LEAD_CRITICAL_EFFORT" ;;
  deep)     desired_effort="$LEAD_DEEP_EFFORT" ;;
  *)        desired_effort="$ORCH_EFFORT" ;;
esac
if [ "${CC_ORCH_MODEL_OVERRIDE:-0}" = "1" ] && \
   { [ "$runtime_normal" = "1" ] || [ "$active" != "$FALLBACK_MODEL" ]; }; then
  desired_model="$launch_model"
fi
if [ "${CC_ORCH_EFFORT_OVERRIDE:-0}" = "1" ]; then
  desired_effort="$launch_effort"
fi

payload="$(cat)"
transcript="$(printf '%s' "$payload" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')"
live_model=""; live_effort=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  tail_text="$(tail -c 400000 "$transcript")"
  live_model="$(printf '%s' "$tail_text" | grep -o '"model":"[^"]*"' | tail -1 | cut -d'"' -f4)"
  live_effort="$(printf '%s' "$tail_text" | grep -o '"effort":"[^"]*"' | tail -1 | cut -d'"' -f4)"
fi
[ -n "$live_model" ] || live_model="$launch_model"
[ -n "$live_effort" ] || live_effort="$launch_effort"

current_rev="$("$REPO_DIR/bin/orch-policy-rev" "$REPO_DIR")"
policy_stale=0
launch_rev="${CC_ORCH_POLICY_REV:-missing}"
if [ "$launch_rev" != "$current_rev" ]; then
  policy_stale=1
  # Before the path-independent revision was introduced, cc-orch hashed sha256sum's complete
  # output. That output embeds ~/.claude/orchestra pathnames, while this hook runs through the
  # real repository path. Accept the installed-path legacy value so live sessions do not need
  # a disruptive one-time restart merely to adopt the bug fix.
  legacy_rev="$("$REPO_DIR/bin/orch-policy-rev" --legacy "$HOME/.claude/orchestra" 2>/dev/null)"
  [ -n "$legacy_rev" ] && [ "$launch_rev" = "$legacy_rev" ] && policy_stale=0
fi

want="$(family "$desired_model")"; have="$(family "$live_model")"
[ -n "$want" ] && [ -n "$have" ] || exit 0
[ "$want" = "$have" ] && [ "$desired_effort" = "$live_effort" ] && \
  [ "$policy_stale" = "0" ] && exit 0

# The hook is registered in two settings sources. Speak once per prompt.
stamp_dir="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/notice"
prompt_id="$(printf '%s' "$payload" | sed -n 's/.*"prompt_id":"\([^"]*\)".*/\1/p')"
if [ -n "$prompt_id" ]; then
  mkdir -p "$stamp_dir" 2>/dev/null
  mkdir "$stamp_dir/$prompt_id" 2>/dev/null || exit 0
  find "$stamp_dir" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rmdir {} + 2>/dev/null
fi

reason="$(sed -n 's/^reason=//p' "$STATE" | head -1)"
project="${CC_ORCH_PROJECT:-<project>}"
cache_state="current"; [ "$policy_stale" = "1" ] && cache_state="stale"
msg="⚠️  cc-orchestra 정책 변경: ${launch_profile} orchestrator는 ${desired_model}@${desired_effort} 이어야 합니다 (${reason}).\n"
msg="${msg}    현재 세션은 ${live_model}@${live_effort}, policy-cache=${cache_state} 입니다.\n"
msg="${msg}    agent 정의도 시작 시 캐시되므로 /model만으로는 lead 프로필이 갱신되지 않습니다.\n"
msg="${msg}    → 진행 중 lead가 없다면: cc-orch --reload ${project}"

ctx="cc-orchestra의 현재 ${launch_profile} 프로필은 ${desired_model}@${desired_effort}이지만 이 세션은 ${live_model}@${live_effort}이고 policy cache가 ${cache_state}이다. agent 정의는 시작 시 캐시되므로 /model만으로는 불충분하다. 답변 첫 줄에서 알리고, 진행 중 lead가 없을 때 'cc-orch --reload ${project}'로 대화를 이어 재시작하라고 안내할 것."
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$msg" "$ctx"
