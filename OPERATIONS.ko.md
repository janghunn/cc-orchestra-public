# cc-orchestra 런타임 운영 및 예산 라우팅 가이드

> 영문 원본: `OPERATIONS.md`

이 런타임 계층은 기존 cc-orchestra 오케스트레이션 엔진은 그대로 유지하면서, 그 위에 다음 두 가지 기능을 추가합니다.

1. `tmux`와 선택적 Git worktree를 이용한 **지속형 작업 세션**
2. Claude Max 구독과 ChatGPT Pro Codex 구독의 **리셋 시각을 고려한 동적 라우팅**

기존 저장소의 실행 파일은 원래 위치에 그대로 유지되며, 직접 덮어쓰지 않습니다. `~/.local/bin`에 설치되는 공개 명령은 다음과 같이 런타임 facade를 거쳐 기존 실행 파일을 호출합니다.

```text
cc-orch          -> bin/cc-orch-runtime          -> 기존 bin/cc-orch
codex-run         -> bin/codex-run-runtime       -> 기존 bin/codex-run
orch-model-guard -> bin/orch-model-guard-runtime -> 기존 bin/orch-model-guard
```

이 구조 덕분에 기존 harness의 동작을 쉽게 검토할 수 있고, 특정 Codex 호출에서 자동 라우팅을 끄고 싶을 때는 `CC_ORCH_AUTO_ROUTE=0`으로 우회할 수 있습니다.

## 설치 또는 업그레이드

```bash
git pull
./install.sh
./install.sh --check

bash tests/test-policy.sh
bash tests/test-runtime.sh
```

설치 과정에서는 기존 model guard를 설정하고, Claude 사용량을 읽기 위한 status-line tap도 추가합니다. 이 tap은 Claude Code가 제공하는 구조화된 `rate_limits.five_hour` 및 `rate_limits.seven_day` 값을 받아 사용률과 리셋 시각(epoch)을 저장한 뒤, 기존에 사용하던 status-line 명령도 계속 호출합니다. Guard를 제거하면 설치 전의 status-line 설정으로 복구됩니다.

이 런타임 기능을 처음 설치한 뒤 이미 실행 중이던 cc-orch 세션이 있다면, 새로 생성된 16개의 `route-lead-*` agent type을 Claude Code가 캐시하도록 **한 번만 reload**하는 것이 좋습니다. 그 이후에는 일반적인 사용량 변화나 리셋 시각 변화 때문에 다시 reload할 필요가 없습니다.

## 지속형 세션과 worktree

작업별로 별도 브랜치, worktree, detached tmux 세션을 한 번에 만들 수 있습니다.

```bash
cc-orch session new auth-refactor ~/projects/api
```

자주 사용하는 변형은 다음과 같습니다.

```bash
cc-orch session new payment-fix ~/projects/api --profile critical
cc-orch session new docs ~/projects/site --inplace
cc-orch session new cache ~/projects/api --branch orch/cache-v2 --base develop
cc-orch session new batch ~/projects/worker --no-attach
```

같은 서버라면 어느 SSH 접속에서든 세션을 관리할 수 있습니다.

```bash
cc-orch session list
cc-orch session status auth-refactor
cc-orch session attach auth-refactor
cc-orch session shell auth-refactor
cc-orch session stop auth-refactor
cc-orch session restart auth-refactor
cc-orch session remove auth-refactor
```

`restart`는 Claude에 `-c`를 넘겨 **마지막 대화를 이어서 재시작**합니다.

`remove`는 정지되어 있고 변경 사항이 없는(clean) worktree와 로컬 세션 등록 정보만 삭제하며, **작업 브랜치는 의도적으로 남겨둡니다.** 실행 중이거나 dirty 상태인 worktree를 제거하려면 명시적으로 `--force`를 사용해야 합니다.

세션 상태는 기본적으로 다음 경로에 저장됩니다.

```text
~/.claude/orchestra-state/sessions/
~/.claude/orchestra-state/worktrees/
```

worktree 저장 루트를 바꾸고 싶다면 `CC_ORCH_WORKTREE_ROOT`를 설정합니다.

### `--inplace`와 기본 worktree 모드 선택

Git 저장소에서는 별도 옵션이 없으면 작업별 worktree를 만드는 것이 기본입니다. 기존 프로젝트 디렉터리 자체에서 그대로 작업하고 싶다면 `--inplace`를 사용합니다.

```bash
cc-orch session new main ~/projects/api --project-name api --inplace
```

일반적으로 다음처럼 선택하면 편합니다.

- 하나의 프로젝트를 계속 이어서 작업: `--inplace`
- 여러 기능을 병렬로 개발: 기본 worktree 모드
- SSH 연결이 끊겨도 작업을 계속 유지: `cc-orch session ...` 사용

## 런타임 예산 모델

Guard는 단순 사용률만 보는 대신 **리셋까지 남은 시간에 비해 quota가 얼마나 남았는지**를 정규화합니다.

```text
headroom ratio = 남은 quota 비율 / 리셋까지 남은 시간 비율
```

여기서 headroom ratio는 앞으로 얼마나 여유 있게 사용할 수 있는지를 나타내는 지표입니다.

- `1.0`: 현재 소비 속도가 리셋 시점까지 정확히 맞는 수준
- `1.0`보다 큼: 현재 속도로 사용해도 상대적으로 여유가 있음
- `1.0`보다 작음: 리셋 전에 quota를 소진하지 않으려면 앞으로 사용 속도를 줄여야 함

따라서 **리셋 5분 전의 90% 사용량**과 **리셋 6일 전의 90% 사용량**은 같은 위험도로 취급되지 않습니다.

현재 상태는 다음 명령으로 확인합니다.

```bash
orch-model-guard budget
orch-model-guard lanes
```

예시:

```text
claude  healthy
  5h    used=90% headroom=6.000 reset=... in 5m
  7d    used=80% headroom=1.400 reset=... in 1d
codex   critical
  7d    used=90% headroom=0.117 reset=... in 6d

dispatch=codex-sparing
```

Claude 사용량은 status-line tap에서 가져옵니다. Codex 사용량은 `~/.codex/sessions/**/rollout-*.jsonl` 중 가장 최신 파일에 있는 `rate_limits.primary` 객체에서 읽습니다. **사용량 확인을 위해 별도의 모델 호출을 추가로 수행하지 않습니다.**

## 압박 상태: healthy / watch / tight / critical

각 quota window는 headroom ratio에 따라 다음 네 단계로 분류됩니다.

```text
healthy   여유 있음
watch     사용 속도를 관찰할 단계
tight     사용량 절약이 필요한 단계
critical  남은 quota를 핵심 작업에만 보존할 단계
```

기본 경계값은 `budget-policy.conf`의 다음 항목으로 제어합니다.

```text
BUDGET_WATCH_RATIO
BUDGET_TIGHT_RATIO
BUDGET_CRITICAL_RATIO
```

Claude는 5시간 window와 7일 window를 각각 평가한 뒤 **더 압박이 큰 쪽**을 전체 Claude 상태로 사용합니다.

## 동적 라우팅

### Claude lead 선택

새 작업을 시작할 때마다 lead profile을 다시 결정합니다.

```bash
orch-model-guard route lead low alpha
orch-model-guard route lead normal bravo
orch-model-guard route lead critical charlie
orch-model-guard route lead critical deep delta
```

`RISK: trivial`에는 별도 route가 없으므로 `low`로 라우팅한다
(`orch-model-guard route lead low <slot>`). `low`와의 차이는 gate 정책뿐이다. Codex
verify/review와 Claude verifier를 실행하지 않고 lead가
`GATES: self-check only (trivial) — <what was checked>`를 보고한다.
`orch-summary-check --strict`가 이 형식을 강제한다. 적용 기준은
`agents/orchestrator.md`의 "Choosing RISK"를 참고한다.

이 명령은 `route-lead-bravo-normal` 같은 **고정된(immutable) agent type**과 해당 모델 및 effort를 반환합니다.

`build-roster-runtime.sh`는 4개 slot × 4개 profile 조합, 총 16개의 `route-lead-*` agent를 미리 생성합니다. 기존 legacy quota guard는 이 `route-lead-*` namespace를 다시 쓰지 않습니다.

즉 사용량 상태가 바뀔 때 agent 정의 파일 자체를 수정하는 것이 아니라, **이미 Claude Code가 캐시한 여러 agent type 중 다음 작업에 맞는 것을 선택**합니다.

### Tier-1 orchestrator

일반적인 `normal` cc-orch 세션의 Tier-1 orchestrator는 **Sonnet @ high**로 유지합니다. Tier-1은 사용자 의도 파악, 작업 분해, 상태 추적과 라우팅에 집중하고, 무거운 설계·구현·검토는 아래 단계의 Claude lead와 Codex lane에 분배합니다.

이미 실행 중인 Tier-1 모델은 quota 상태가 변해도 실행 도중 hot-swap하지 않습니다.

### Codex 모델과 effort 선택

새 `codex-run` 호출마다 모델과 effort를 자동으로 다시 결정합니다.

대표적인 구현(implement) 정책은 다음과 같습니다.

```text
healthy   implement -> Astra xhigh (Fast; Astra를 쓸 수 없으면 Sol xhigh)
watch     implement -> Sol high
tight     implement -> Terra high
critical  implement -> 보류(withheld); Claude fallback 사용
```

리뷰(review)는 독립적인 cross-family gate를 보존하기 위해 critical에서도 완전히 끄지 않습니다.

```text
healthy   review -> Astra high (Fast; Astra를 쓸 수 없으면 Sol high)
watch     review -> Sol medium
tight     review -> Terra high
critical  review -> Terra medium (gate reserve)
```

전체 라우팅 표는 `budget-policy.conf`에 있습니다.
자동 라우팅된 healthy 호출은 `CODEX-RUN: MODEL_FALLBACK`을 출력하며, Astra를 사용할 수 없으면 해당 lane의 일반적인 Sol/Terra 기본값으로 폴백합니다. Astra를 명시적으로 요청하면 대신 `MODEL_UNAVAILABLE`과 함께 종료 코드 6으로 종료합니다. `CC_ORCH_CODEX_CATALOG_CHECK=0`으로 설정하면 live/cached catalog 사전 확인을 비활성화할 수 있습니다.

명시적으로 전달한 옵션은 자동 라우팅보다 항상 우선합니다.

```bash
codex-run ... --model sol --effort xhigh
codex-run ... --critical
codex-run ... --fast-mode
codex-run ... --mech
```

특정 명령 한 번만 자동 Codex 라우팅을 끄려면:

```bash
CC_ORCH_AUTO_ROUTE=0 codex-run ...
```

현재 shell 전체에서 끄려면:

```bash
export CC_ORCH_AUTO_ROUTE=0
```

## provider 간 dispatch 결정

`orch-model-guard lanes`는 Claude와 Codex의 현재 quota 압박을 비교해 다음 중 하나를 선택합니다.

```text
dispatch=codex-first
dispatch=codex-sparing
```

- `codex-first`: 기본 정책. 무거운 조사·구현·검증을 Codex 쪽에 적극적으로 배분
- `codex-sparing`: Codex quota 압박이 Claude보다 더 큰 경우 Codex를 절약하고, 남은 quota를 독립적인 review/verify gate에 우선 보존

이 판단도 단순 사용률이 아니라 리셋까지 남은 시간을 포함한 headroom을 사용합니다.

## reload 없이 즉시 반영되는 항목

다음 값은 각 dispatch 또는 호출 시점마다 다시 읽으므로 바로 반영됩니다.

- Claude/Codex 사용률과 리셋 시각
- `budget-policy.conf`의 임계값과 모델 테이블
- `orch-model-guard lanes`의 provider 선택 결과
- 다음 작업에 사용할 `route-lead-*` profile
- 다음 Codex 호출의 model/effort

반면 이미 실행 중인 모델 프로세스를 turn 도중 교체하지는 않습니다.

- Tier-1 orchestrator는 실행할 때 선택된 모델을 계속 사용
- 이미 실행 중인 lead는 현재 모델과 context를 유지
- 새 정책은 **다음 lead 생성 또는 다음 Codex 호출 경계**부터 적용

`cc-orch --reload`는 prompt, template, agent 정의처럼 **구조적인 설정이 바뀐 경우**에 사용합니다. UserPromptSubmit hook은 이런 구조 변경과 단순 quota 변화를 구분합니다.

## PreToolUse 수동 폴링 방지 hook (선택 사항)

이미 실행 중인 세션은 오래된 agent 정의를 캐시하고 있을 수 있습니다. 따라서 prompt template을
고친 뒤에도 background gate 결과 파일을 `sleep` 루프로 수동 확인하는 명령이 계속 발생할 수
있습니다. 선택형 방어선인 `hooks/orch-poll-guard.sh`는 이런 Bash 호출을 가로챕니다. Hook
스크립트는 호출할 때마다 디스크에서 다시 읽으므로 agent 정의 cache와 무관하게 갱신됩니다.

Project-local settings를 사용한 격리 범위 실증 테스트에서 `PreToolUse` hook은 최상위 Bash
호출뿐 아니라 Task/Agent로 생성된 subagent의 Bash 호출에도 적용되었습니다. User/global
settings에서의 적용은 직접 측정하지 않았으며, 동일한 hook engine을 공유한다는 점에서 추론한
것입니다. Subagent payload에는 `agent_id`와 `agent_type`이 포함되지만, 이 guard는 정확한
`tool_name: "Bash"` 여부만 검사합니다. 이 추론에 따르면 agent 정의가 오래된 현재 orchestrator가
새로 만드는 lead도 등록 즉시 보호할 수 있습니다. Claude Code는 일반적으로 settings 변경을
감시하지만 hot reload는 실행 환경의 동작이므로, 기존 세션이 새 등록을 인식하지 않으면 그 세션을
재시작하십시오. 등록 이후에는 참조된 스크립트의 수정이 다음 호출부터 읽힙니다.

이 작업은 hook을 자동 등록하지 않습니다. 사용하려면 아래 항목을 기존 hook을 덮어쓰지 않도록
Claude settings에 병합하십시오. Checkout 위치가 바뀌면 repository 경로도 바꾸어야 합니다.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/absolute/path/to/cc-orch/hooks/orch-poll-guard.sh' || true",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

`|| true`는 필수입니다. 차단은 종료 코드 0과 JSON으로 전달되므로 이 normalizer가 차단을
숨기지 않습니다. 대신 hook 파일이 손상되거나 shell 문법 오류가 생겼을 때 모든 Bash 호출이
막히는 것을 방지합니다.

탐지 범위는 의도적으로 좁습니다. `while` 또는 `until` keyword가 command 위치에 있어야 하며,
그 live command text 안에 `sleep`과 `[`, `test`, `grep`, `cat`, `stat`, `find` 같은 파일 감시
primitive가 함께 있어야 합니다. Comment와 heredoc 본문은 inert text이므로 차단 신호에 절대
기여하지 않습니다. 일반적인 quoted data도 loop, sleep, primitive 탐지에서는 제외되며, live
loop 안에서 `.orchestra/` 또는 `codex-*.md`/`codex-*.jsonl` TARGET 신호만 충족할 수 있습니다.
Double quote 안의 command substitution과 독립된 shell `-c` 다음의 첫 번째 quoted payload는
실행 코드로 취급합니다. Heredoc delimiter는 word, 점, hyphen 문자를 지원하며, quote/comment 안의
heredoc 형태 텍스트와 here-string(`<<<`)은 opener가 아닙니다. `-lc` 같은 결합형 short option은
알려진 false negative입니다. 그 밖의 허용된 false negative는 `for` loop, 여러 Bash 호출로
나뉜 loop, `eval`/`$'…'`/process-substitution payload, orchestra 외 경로 polling입니다. Prompt
지침이 여전히 첫 번째 방어선입니다. 필요한 신호를 unquoted text로 모두 가진 정상 live loop가
남아 있는 false positive 위험입니다.

측정된 Python 검사 지연은 matcher에 걸린 Bash tool 호출마다 약 28–65 ms입니다.

오탐이 발생하면 모든 세션에서 즉시 끌 수 있습니다.

```bash
mkdir -p ~/.claude/orchestra-state
touch ~/.claude/orchestra-state/poll-guard.off
```

다시 켜려면 위 파일을 삭제합니다. 영구 rollback은 settings에서 이 `PreToolUse` 항목을
삭제하면 되며, hook 스크립트 파일은 디스크에 남아 있어도 됩니다.

## Verifier Bash 명령 guard

`verifier`와 `verifier-normal`은 각자 frontmatter의 `PreToolUse`에 `Bash` matcher로
`hooks/orch-verifier-bash-guard.sh`를 등록합니다. 기존 설치 과정에서 agent 정의는
`~/.claude/agents/`에, repository는 `~/.claude/orchestra/`에 연결되므로 task 작업 디렉터리와
무관하게 hook 경로를 찾습니다. 별도의 `settings.json` 등록이나 opt-in은 필요하지 않으며,
이 hook은 두 verifier 정의에만 적용됩니다.
Claude Code의 [subagent frontmatter hook 문서](https://code.claude.com/docs/en/sub-agents#hooks-in-subagent-frontmatter)와
[agent 정의 갱신 동작](https://code.claude.com/docs/en/sub-agents#write-subagent-files)을 참고하십시오.
수정은 보통 다음 위임부터 반영됩니다. Agents 디렉터리를 새로 만들었거나, 추가 디렉터리의
정의를 수정했거나, slash command를 비활성화한 세션이라면 재시작이 필요합니다.

각 agent의 Bash 명령 정책에 금지된 변경 명령군과 허용된 조회·테스트 예시가 있습니다.
Guard는 command 위치, 따옴표로 감싼 명령어, 일반적인 중립 wrapper, shell로 전달되는
heredoc을 검사하며 정상적인 검증 runner는 계속 허용합니다. 차단 시 이유가 포함된 deny JSON을
출력하고 항상 0으로 종료하며, parsing/runtime 오류는 fail-open으로 처리합니다. Frontmatter의
`|| true`는 shell 시작 오류도 처리합니다. `.off` 파일은 없으며 운영상 변경하려면 agent
frontmatter를 직접 수정해야 합니다.

이 기능은 심층 방어이며 shell sandbox가 아닙니다. 난독화한 `eval`, 인코딩된 payload, 알 수
없는 wrapper, 테스트 스크립트 내부 명령은 텍스트 검사를 우회할 수 있습니다. Hook 입력에는
지정된 verdict 경로가 없으므로 해당 파일만 쓰라는 경계는 여전히 지시로 강제됩니다.
`echo`/`printf`/`tee`로 다른 단일 파일을 쓰는 행위는 정상 verdict 쓰기와 기계적으로 구분할 수
없습니다. `bash tests/test-verifier-bash-guard.sh`는 실제 agent 세션 없이 hook의 차단·허용
결정과 설치 경로 연결을 검증합니다.

## 설정 튜닝

라우팅 정책을 조정하려면 `budget-policy.conf`를 수정합니다.

이 파일은 `orch-policy-rev` 계산에서 제외되어 있으므로, quota threshold나 모델 배분표를 조정하는 것만으로 prompt cache가 무효화되지는 않습니다.

주요 설정값은 다음과 같습니다.

```text
BUDGET_WATCH_RATIO
BUDGET_TIGHT_RATIO
BUDGET_CRITICAL_RATIO
BUDGET_NEAR_RESET_MINUTES
BUDGET_PROVIDER_SWITCH_MARGIN
BUDGET_FABLE_RESERVE_PCT
CLAUDE_ROUTE_*_PROFILE
CODEX_AUTO_<MODE>_<PRESSURE>_{MODEL,EFFORT,ALLOW}
```

큰 작업을 시작하기 전에 정책을 바꿨다면 다음 명령으로 실제 pressure와 routing 결과를 확인하는 것이 좋습니다.

```bash
orch-model-guard budget
orch-model-guard lanes
```

## 자주 쓰는 운영 명령 요약

현재 quota와 라우팅 상태 확인:

```bash
orch-model-guard budget
orch-model-guard lanes
orch-model-guard status
```

managed session 확인 및 접속:

```bash
cc-orch session list
cc-orch session status main
cc-orch session attach main
```

Claude Code는 종료하지 않고 tmux에서만 빠져나오기:

```text
Ctrl-b, d
```

Claude Code 자체를 정상 종료:

```text
/exit
```

종료된 managed session의 이전 대화를 이어서 실행:

```bash
cc-orch session restart main
```

설치 상태 점검:

```bash
./install.sh --check
```

실제로 실행 중인 Tier-1 모델 확인:

```bash
ps -eo pid,args | grep '[c]laude.*--agent orchestrator'
```

일반적인 normal 세션이라면 `--model sonnet[1m] --effort high`가 표시되는 것이 정상입니다.
