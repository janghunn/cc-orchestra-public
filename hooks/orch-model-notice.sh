#!/usr/bin/env bash
# UserPromptSubmit hook — the one gap orch-model-guard cannot close by itself.
#
# A running session is frozen at process start in two ways, both measured on 2.1.197 and 2.1.220
# with a gated probe (swap a marker in an agent file, verify it on disk, then spawn again):
#
#   1. The session's own model cannot be changed from outside — no settings file, agent file or
#      hook moves it. Only /model, typed by the user, or a restart.
#   2. Agent definitions in ~/.claude/agents/ are cached at session start, NOT re-read per spawn.
#      A lead-* spawned an hour after the guard rewrote its file still uses the model, prompt and
#      effort that were on disk when the session started.
#
# (2) is why /model alone is not a fix: it moves Tier 1 only, and this session's lead-* keep
# spawning on the model with no quota left. A restart is the only thing that moves both tiers.
#
# This hook is what tells them, in the session, at the moment they type. It stays silent in
# every other session and while Tier 1 and the guard agree.
#
# Registered in two places on purpose. ~/.claude/settings.json is on Claude Code's watch list,
# so a hook added there reaches sessions that are ALREADY RUNNING; guardrails.json is read at
# startup only, but is guaranteed to load for every session cc-orch launches. Whichever channel
# a given session honours, the notice arrives once — see the prompt_id stamp below.
# Install/remove the settings.json half with: orch-model-guard install | uninstall
STATE="$HOME/.claude/orchestra-state/state"
[ -r "$STATE" ] || exit 0

active="$(sed -n 's/^active=//p' "$STATE" | head -1)"
[ -n "$active" ] || exit 0

family() { # fable[1m] / claude-opus-5 / opus -> fable|opus|sonnet|haiku
  case "$1" in
    *fable*)  echo fable ;;
    *opus*)   echo opus ;;
    *sonnet*) echo sonnet ;;
    *haiku*)  echo haiku ;;
    *)        echo "" ;;
  esac
}

# --- is this an orchestrator session? ----------------------------------------------------
# cc-orch exports CC_ORCH_MODEL; sessions launched before that existed are identified from the
# claude process's own argv, walking up because the hook runs under a shell.
launch_model="${CC_ORCH_MODEL:-}"
if [ -z "$launch_model" ]; then
  pid="$PPID"
  for _ in 1 2 3 4 5 6; do
    [ -r "/proc/$pid/cmdline" ] || break
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$args" in
      *"--agent orchestrator"*)
        launch_model="$(printf '%s' "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p')"
        break ;;
    esac
    pid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$pid" ] && [ "$pid" != "0" ] || break
  done
fi
[ -n "$launch_model" ] || exit 0

# --- what is this session actually running right now? -------------------------------------
# argv is not enough: it still says fable[1m] after the user has run /model. The transcript's
# last assistant message carries the model that was really used, so the notice self-silences
# one turn after the switch instead of nagging forever.
payload="$(cat)"
transcript="$(printf '%s' "$payload" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')"
live=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  live="$(tail -c 400000 "$transcript" | grep -o '"model":"[^"]*"' | tail -1 | cut -d'"' -f4)"
fi
[ -n "$live" ] || live="$launch_model"

want="$(family "$active")"
have="$(family "$live")"
[ -n "$want" ] && [ -n "$have" ] || exit 0
[ "$want" = "$have" ] && exit 0

# Both registrations may be live at once. The prompt is the natural unit: whoever gets here
# first for this prompt speaks, the other exits silently. mkdir is the atomic primitive.
stamp_dir="$HOME/.claude/orchestra-state/notice"
prompt_id="$(printf '%s' "$payload" | sed -n 's/.*"prompt_id":"\([^"]*\)".*/\1/p')"
if [ -n "$prompt_id" ]; then
  mkdir -p "$stamp_dir" 2>/dev/null
  mkdir "$stamp_dir/$prompt_id" 2>/dev/null || exit 0
  # Keep the directory from growing forever; anything older than a day is long since answered.
  find "$stamp_dir" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rmdir {} + 2>/dev/null
fi

reason="$(sed -n 's/^reason=//p' "$STATE" | head -1)"

msg="⚠️  모델 가드: Tier 1/2는 이제 ${active} 입니다 (${reason}).\\n"
msg="${msg}    이 세션은 ${live} 로 고정돼 있고, 이 세션이 띄우는 lead-* 도 계속 ${live} 로 뜹니다\\n"
msg="${msg}    — 에이전트 정의는 세션 시작 시점에 캐시되므로 파일을 바꿔도 안 바뀝니다.\\n"
msg="${msg}    →  cc-orch <project>   로 재시작하세요. 두 계층을 다 옮기는 유일한 방법입니다.\\n"
msg="${msg}       /model ${active} 는 이 세션만 옮기고 lead-* 는 ${live} 에 남습니다 (임시 조치)."

ctx="시스템 상태 변경: 모델 가드가 Tier 1/2 모델을 ${active} 로 전환했다 (${reason}). "
ctx="${ctx}단, 이 세션은 ${live} 로 실행 중이고 에이전트 정의는 세션 시작 시점에 캐시되므로, "
ctx="${ctx}이 세션이 앞으로 띄우는 lead-* 도 ${live} 로 뜬다 — 파일이 바뀌어도 반영되지 않는다. "
ctx="${ctx}답변 첫 줄에서 사용자에게 알릴 것: 두 계층을 모두 옮기려면 'cc-orch <project>' 재시작이 필요하고, "
ctx="${ctx}'/model ${active}' 는 이 세션만 옮기는 임시 조치라는 점. 진행 중 작업이 있으면 그것을 마친 뒤 재시작을 권할 것."

printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$msg" "$ctx"
