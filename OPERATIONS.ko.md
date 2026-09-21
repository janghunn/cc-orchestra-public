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

`build-roster-runtime.sh`는 렌더링한 38개 프로필의 대상 경로, 원본 템플릿, 양쪽 SHA-256 해시와 저장소 커밋을 `${CC_ORCH_AGENTS_DIR:-$HOME/.claude/agents}/.install-manifest.json`에 NDJSON으로 기록합니다(`CC_ORCH_MANIFEST`로 경로 변경 가능). `~/.claude/orchestra/bin/orch-doctor [manifest-path]`로 파일 누락, 출력 변경, 오래된 템플릿, 저장소 버전 불일치를 확인할 수 있으며, 모두 일치하면 0, 문제가 있으면 1, 매니페스트가 없거나 잘못되었으면 2로 종료합니다. 선택적으로 표시되는 upstream 안내는 fetch 없이 로컬 추적 ref만 비교하므로 아직 fetch하지 않은 원격 변경은 감지하지 못합니다. `build-roster.sh`만 실행하면 매니페스트는 22개 프로필만 추적하며, 기존 route 파일은 디스크에 남지만 runtime builder를 다시 실행할 때까지 추적 대상에서 빠집니다. Quota에 따른 `orch-model-guard set` 전환은 매니페스트 갱신 없이 렌더링된 파일을 의도적으로 변경하므로, 해당 `lead-*.md`의 `DRIFTED` 표시는 다음 roster 재빌드까지 예상되는 정상 동작입니다.

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

## Jev 자문 사이드카 (선택 사항, hybrid 모드 전용)

`orch-jev`는 TypeSafe AI의 Jev를 통해 세 번째 모델의 자문 신호를 제공합니다.
명시적으로 호출할 때만 동작하며 gate가 아니고 작업 파일을 수정하지 않습니다.
판단은 사람과 agent가 내립니다. 설치 후 경로는 `~/.claude/orchestra/bin/orch-jev`이며,
checkout 안에서는 `bin/orch-jev`를 사용합니다. Python 3 표준 라이브러리만 필요합니다.

```bash
export TYPESAFE_API_KEY=<your-key>
# 파일을 쓰려면 <state>/jev.key에 키를 넣고 chmod 600 <state>/jev.key를 실행합니다.
~/.claude/orchestra/bin/orch-jev lint-brief <brief.md>
~/.claude/orchestra/bin/orch-jev risk <brief.md>
~/.claude/orchestra/bin/orch-jev scan <file>...
~/.claude/orchestra/bin/orch-jev scan - <file>  # stdin과 파일을 함께 지정할 수 있습니다.
```

`<state>`는 `${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}`입니다. 환경 변수의 키가
우선이며 빈 값이면 `jev.key`를 확인합니다. group/other 권한이 있는 키 파일은 경고 후
무시하므로 `chmod 600`을 적용합니다. 읽을 수 없는 키 파일도 fail-open 처리합니다.
클라이언트는 키를 출력, 로그, 생성 파일에 복사하지 않습니다.

`lint-brief`는 Acceptance의 번호 항목과 Verification 섹션을 전송하고 항목마다 질문합니다.
`risk`는 Risk 섹션, 등급 선언, DEEP REASONING 줄을 제거한 brief를 전송합니다.
`scan`은 텍스트 chunk, source 이름, 줄 범위를 하나의 요청으로 전송합니다.
입력은 지정한 파일 또는 stdin만 읽으며, 설정·질문 template·키 파일도 별도로 읽습니다.
자르기 전에 각 원본 전체에서 secret 형태의 literal을 검사하고, 발견된 source 전체를
제외합니다. 크기와 항목/chunk 상한을 적용한 경우 명시적인 note를 출력합니다.
기본 상한은 직렬화한 state 24,000 bytes, 항목 20개, 4,000 bytes chunk 24개입니다.

목적지는 `https://api.typesafe.ai`이며 호출당 HTTPS POST 하나와 최대 한 번의 재시도를
사용합니다. redirect와 다른 host는 거부하며 offline test용 loopback endpoint만 예외입니다.
자문 결과와 오류는 exit 0, 잘못된 명령 인자는 exit 2입니다. 실패 시
`JEV: unavailable — <class>`를 출력합니다. class는 disabled, codex-only backend, config,
no key, template, auth, validation, rate limit, overloaded, redirect, 기타 HTTP status,
timeout, network, malformed response, schema입니다. 재시도 대상은 timeout 두 번과
0.5 s backoff 이내로 처리합니다. 기본 timeout 6 s이면 총 약 12.5 s이며,
재시도 대상이 아닌 오류는 즉시 반환합니다.
proxy 환경 변수는 무시하고 직접 연결하므로 proxy가 필수인 환경에서는 network 오류로 fail-open 처리될 수 있습니다.

모든 출력 줄은 `JEV:`로 시작합니다. `risk`는 confidence가 충분할 때 더 높은 등급만
제안하며 등급 선언을 만들지 않습니다. Jev 출력을 `RISK:` 줄에 붙여 넣지 마세요.
`scan`은 기존 정규식 security scanner를 보완하며 해당 검사를 대체하지 않습니다.
`jev-policy.conf`에서 활성화, timeout, 임계값, 상한, journal을 조정합니다. 호출 시마다
읽으며 `orch-policy-rev`에 포함되지 않습니다. 모델은 `jev-X.Y.Z`로 고정해야 하고
기본값은 `jev-1.13.0`입니다. 질문 문구는 `templates/jev/`에 있습니다.

`<state>/jev.log`는 mode 600의 metadata 전용 journal입니다. 시간, 명령, 결과, 시도 횟수,
latency, model, 질문 수, token 사용량만 남기며 입력 본문, source 이름, 답변, 키는 없습니다.
`JEV_JOURNAL=0`으로 끌 수 있고 journal 기록 실패는 자문 결과에 영향을 주지 않습니다.
Codex-only 모드는 사용하지 않습니다. `cc-orch-codex` 세션은 `CC_ORCH_BACKEND=codex`를
설정하며, 이때 도구는 외부 호출을 거부합니다.

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
출력하고 항상 0으로 종료합니다. Bash parsing/classification 실패는 재귀 검사 중 발생한 오류를
포함해 명확한 parsing 실패 이유와 함께 기본적으로 차단합니다. 잘못된 형식 또는 Bash가 아닌
hook event와 Python 검사기 자체가 실행되지 못하는 외부 오류는 기존 pass-through 처리를
유지합니다. Frontmatter의 `|| true`는 shell 시작 오류도 처리합니다. `.off` 파일은 없으며
운영상 변경하려면 agent frontmatter를 직접 수정해야 합니다.

이 기능은 심층 방어이며 shell sandbox가 아닙니다. 난독화한 `eval`, 인코딩된 payload, 알 수
없는 wrapper, 테스트 스크립트 내부 명령은 텍스트 검사를 우회할 수 있습니다. Hook 입력에는
지정된 verdict 경로가 없으므로 해당 파일만 쓰라는 경계는 여전히 지시로 강제됩니다.
`echo`/`printf`/`tee`로 다른 단일 파일을 쓰는 행위는 정상 verdict 쓰기와 기계적으로 구분할 수
없습니다. `bash tests/test-verifier-bash-guard.sh`는 실제 agent 세션 없이 hook의 차단·허용
결정과 설치 경로 연결을 검증합니다.

이 심층 방어 범위에서 다음 알려진 잔여 공백을 명시적으로 수용합니다.

이 guard는 기본적으로 명령을 추출한 뒤 차단 목록에 있는 경우에만 거부하는 구조이므로, lexer가 명령 추출 방법을 모르는 shell 구문에서는 명령이 하나도 추출되지 않아 기본적으로 허용되며, 이는 표현력이 풍부한 문법에 차단 목록을 적용하는 방식의 구조적 특성으로 개별 버그 수정으로 해결할 수 없고, 근본적으로 해결하려면 인식 가능한 shell 문법만 허용하는 허용 목록 기반 구조로 전환해야 하지만 이는 이 작업의 범위 밖입니다.

- `bash - <<< "rm target"`처럼 stdin을 명시한 shell 호출은 heredoc/here-string 검사를
  우회할 수 있습니다. 괄호 없는 `function f { rm target; }; f` 선언도 검사를 우회할 수 있습니다.
- `perl -e`, `python -c`, `node -e` 인터프리터 한 줄 코드와 `ssh host cmd`, `su -c`,
  `flock`, `watch`를 통한 명령 wrapping은 여전히 신뢰할 수 있는 강제 범위 밖에 있습니다.
- `coproc rm target`은 lexer가 `coproc`을 명령 위치를 여는 키워드로 인식하지 못하므로
  허용됩니다. 따라서 그 안의 파괴적 명령은 추출되거나 분류되지 않습니다.
- `printf safe &&`처럼 그 외에는 유효한 명령 끝에 `&&` 또는 `||`가 매달린 불완전한 입력은
  실제 shell이 거부하는 잘못된 Bash 문법입니다. 하지만 lexer는 오류 없이 받아들이고 의미 있는
  후속 명령을 추출하지 않으므로 아무것도 차단하지 않습니다.
- 알려진 오탐도 남아 있습니다. `env -S`는 안전한 리터럴 문자열을 실행 코드로 취급해 차단할 수
  있고, `git branch --list -- "-D*"`는 branch 삭제로 오인될 수 있습니다. `env -S`의 추정 검사
  오류를 포함한 parsing 실패는 실제로 안전한 입력이어도 기본적으로 차단합니다.

이러한 한계의 공개는 verifier의 변경 작업을 허용한다는 뜻이 아닙니다. Hook이 작업을 놓쳐도
verdict 파일만 쓰라는 지시와 명령 정책은 그대로 적용됩니다.

## 런타임 안전 hook

설치 시 독립적인 안전 hook 두 개를 user settings와 session guardrails에 등록합니다.
`bash install.sh --safety-hooks-only`는 이 등록만 병합하며 symlink 설치, 실행 권한 변경,
systemd 호출은 수행하지 않습니다. `CC_ORCH_SETTINGS`로 settings 경로를 지정할 수 있으며,
기본값은 `$HOME/.claude/settings.json`입니다. 기존의 관련 없는 항목을 보존하고 checkout
경로가 바뀌면 해당 hook command만 현재 경로로 갱신합니다. 등록 command의 `|| true`는
유지해야 합니다. Timeout은 `PreToolUse` 10초, `SubagentStop` 30초입니다. 저장소의
`guardrails.json`은 기존 `/home/janghun/cc-orchestra/hooks/` 경로를 사용하므로 다른 위치에
설치한 경우 그 경로를 조정하십시오.

`hooks/orch-worktree-guard.sh`는 Bash의 Git 명령과 기존 `.orchestra/REGISTRY.md`를
비교합니다. 상태가 비어 있지 않고 정확히 `PASS`, `FAIL`, `BLOCKED`, `CLOSED`, `IDLE`,
`UNASSIGNED` 중 하나가 아닌 lead 행을 active로 봅니다. `PASS (worktree)`는 active입니다.
호출자 식별은 active 행의 `agentId` 일치를 우선합니다. 전체 값이 같거나, 짧은 쪽이 8자
이상인 접두사 관계이면 일치합니다. 그다음 `(route-)?lead-(alpha|bravo|charlie|delta)`와
선택적인 `light`, `normal`, `critical`, `critical-xhigh` 접미사, 또는
`dev(-opus)?-<양의 정수>` 형식을 인식합니다. 식별되지 않은 호출자와 일반적인
orchestrator 호출은 평가를 건너뜁니다.

`commit`, `merge`, `rebase`, `cherry-pick`, `revert`, `reset`, `am`, `apply`, `add`, `rm`,
`mv`, `stash`, `restore`를 index 변경으로 분류합니다. `checkout`, `switch`,
`branch -f/-D/-m/-M`, `tag -f/-d`는 ref 이동이며 `push`는 별도 분류입니다. 차단 규칙은
다음 네 가지입니다.

- **R1:** lead/dev가 `main`, `master`, `develop`, `trunk`에서 index를 변경하거나 대상이
  생략되었거나 확정되지 않은 push를 실행하면 차단합니다. 이 보호 branch를 대상으로 명시한
  push와 `--all`, `--mirror` push는 현재 checkout branch와 무관하게 차단합니다. Wildcard
  대상도 보호 branch 이름과 일치할 수 있을 때만 보호 대상으로 봅니다. `refs/heads/*`와
  `*`는 해당하지만 `orch/*`, `releases/*`는 해당하지 않습니다. 보호 대상이 아닌 refspec을
  명시한 push, 작업 branch에서의 bare push와 tag 전용 `--tags` push, 작업 branch를 만들기
  위한 switch는 R1에서 허용합니다. 작업 branch에서 보호 대상이 아닌 wildcard push도
  계속 허용합니다.
- **R2:** slot이 확인된 lead가 다른 active lead의 등록 branch에 있는 checkout을 변경하면
  차단합니다.
- **R3:** slot이 확인된 lead가 다른 active slot의 `.orchestra/wt/<slot>` checkout을
  변경하면 차단합니다.
- **R4:** active lead 행이 둘 이상인데 slot이 확인된 lead가 registry를 소유한 공유
  checkout을 변경하면 차단합니다. 메시지에 다른 slot과
  `git worktree add <repo>/.orchestra/wt/<slot> -b <your branch>` 명령을 안내합니다.

Registry의 `dir`는 artifact 디렉터리이며 저장소 root 기준으로 해석합니다. Checkout
소유권은 현재 HEAD와 등록 branch, slot 경로로 판단합니다. Git worktree metadata를 통해
분리된 checkout에서도 공유 registry를 찾습니다. Branch를 바꾸는 `checkout`/`switch`
이후에는 해당 segment에서 바뀐 branch를 기준으로 평가합니다. 해석한 checkout root를 키로
사용하므로 `cd`와 `git -C`로 같은 checkout에 접근해도 변경 상태를 공유합니다.
`checkout -b/-B`, `switch -c/-C`는 새 branch 이름을 사용하고, 일반 branch 인자는 실제
local `refs/heads/`로 확인된 경우에만 반영합니다. 파일 checkout, detached SHA, 모호한
형식은 branch 모델을 바꾸지 않습니다. 단독 in-place lead가 한 호출에서 작업 branch를
만들고 commit하는 것은 허용하지만, `develop`으로 이동한 뒤 commit하면 R1이 차단합니다.
공유 checkout 충돌 규칙은 계속 적용됩니다.

작업 디렉터리와 effective branch 변경에는 하나의 조건부 실행 규칙을 적용합니다.
`&&` 또는 `||` 뒤의 `cd`/`pushd`나 branch를 바꾸는 `checkout`/`switch`는 이전 값과 새
값을 모두 후보로 유지합니다. 첫 segment나 `;` 또는 개행 뒤의 변경은 무조건 실행되는
것으로 보고 해당 후보를 대체합니다. 이후 Git 호출은 모든 cwd 후보와 각 checkout의
모든 branch 후보 조합을 평가하며, 하나라도 규칙을 위반하면 해당 규칙을 명시해 차단합니다.
해석할 수 없는 조건부 변경은 새 후보를 추가하지 않습니다. 따라서
`false && git switch -c orch/new; git commit`으로 보호 branch를 숨길 수 없지만,
무조건 실행되는 `git switch -c orch/new && git commit`과
`cd <own-worktree> && git commit`의 정상 작업은 계속 허용합니다. 디렉터리 대상이 없거나
디렉터리가 아니면 Bash의 실패한 이동처럼 기존 cwd를 유지합니다. 선두의 `~/`와 단독 `~`는
`$HOME`으로 확장하며 `~user`는 계속 확정할 수 없는 대상으로 취급합니다.
따옴표 안의 설명, 주석, heredoc 본문은
명령으로 취급하지 않습니다. `cd -`, 확장되지 않은 변수, `--git-dir`/`--work-tree` 등으로
대상을 확정할 수 없거나 registry가 없거나 잘못된 경우에는 허용합니다. 읽기 전용 또는
분류되지 않은 명령도 허용합니다. 복잡한 shell 문법 전체를 해석하는 parser는 아닙니다.

`hooks/orch-stop-gate.sh`는 matcher `(route-)?lead-.*`인 **SubagentStop**에 등록합니다.
`Stop`은 main session용 event입니다. 마지막 assistant transcript 메시지에
`STATUS: PASS`, `FAIL`, `BLOCKED` 행과 `GATES:` 행이 모두 있을 때만 검사합니다. STATUS
앞의 lead label은 허용하며 일반적인 작업 중간 보고는 checker를 실행하지 않습니다.
`I will report the STATUS: PASS when done`처럼 앞으로 보고할 내용을 설명하는 문장도
결과 claim으로 취급하지 않습니다.
`stop_hook_active`가 truthy이면 반복 차단을 막기 위해 즉시 허용합니다. Boolean `true`뿐
아니라 문자열 `"true"`와 숫자 `1`도 포함합니다. Task 디렉터리는
registry의 agent ID 일치 행, slot 일치 행 순으로 선택하며 `ARTIFACTS:`가 다른 task를
가리켜도 registry를 우선합니다. Registry 자체를 찾지 못한 경우에만 `ARTIFACTS:`를
fallback으로 검토합니다. Registry가 있는데 이 lead의 task 행이 없으면 경고하며 다른
artifact 디렉터리를 검사하지 않습니다. Fallback은 `brief.md`가 있는 실제 디렉터리여야
하며, 해석한 경로가 payload `cwd`에서 찾은 Git 저장소 root 안에 있어야 합니다. 저장소
root를 알 수 없거나 symlink 등을 통해 root 밖으로 나가는 경로이면 경고합니다.

Checker는 `CC_ORCH_SUMMARY_CHECK`의 실행 파일 경로, hook 자신의 저장소에 있는
`bin/orch-summary-check`, `$HOME/.local/bin/orch-summary-check`, `PATH` 순서로 찾습니다.
Override는 운영 점검과 테스트에 사용할 수 있습니다. `--strict <task-dir>`로 실행하고
해당 task의 `summary.md` STATUS 행도 읽으며 `[lead-x]` 접두사를 허용합니다. Exit 0이면
transcript와 summary의 상태가 같을 때 조용히 허용하고, 다르거나 기록된 상태를 읽을 수
없으면 경고합니다. Exit 1에서는 transcript가 `PASS`를 주장할 때만 차단합니다. Summary가
`BLOCKED`나 `FAIL`인데 transcript가 `PASS`인 경우에도 반드시 차단하며 checker 출력의 처음
1,500바이트, 정확한 재실행 명령, off-switch 경로를 제공합니다. Transcript가 `BLOCKED`
또는 `FAIL`이면 차단하지 않습니다. 실제 gate 실패나 summary 부재는 checker 출력을 담은
경고로 전달하여 정직한 실패 보고와 escalation을 끝낼 수 있게 합니다. Task/checker를 찾지
못하거나 exit 2 또는 실행 오류가 발생한 경우도 `systemMessage`, stderr, journal에 경고를
남기고 허용합니다.
Transcript가 없거나 읽을 수 없으면 확인 가능한 claim이 없으므로 조용히 허용합니다.
저장소 내부 경로와 `brief.md` 확인만으로 fallback task의 소유권까지 증명하지는 않습니다.
Python이 없으면 오류 출력 없이 허용하며, 의도적인 gate 경고는 계속 stderr, stdout JSON,
journal에 전달합니다.

두 hook 모두 exit 0을 반환하며 차단 여부는 JSON으로 전달합니다. 각각 다음과 같이
비활성화하고 journal을 확인할 수 있습니다.

```bash
state_dir="${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}"
touch "$state_dir/worktree-guard.off"
touch "$state_dir/stop-gate.off"
# 다시 활성화하려면 해당 .off 파일을 삭제합니다.
tail -n 30 "$state_dir/safety-hooks.log"
```

Journal 경로는 `${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}/safety-hooks.log`입니다.
실제로 평가한 Git 호출과 감지한 gate claim에만 ISO 시각, hook/event, 호출자 정보,
판정(`allow`, `deny`, `block`, `warn`, `skip`), 한 줄 사유를 기록합니다. Fast path는
기록하지 않습니다. Bash payload에 독립된 `git` 토큰과 변경 키워드가 모두 있지 않으면
Python이나 Git을 시작하기 전에 반환합니다. 각 행은 크기를 제한한 단일 append로 씁니다.
파일이 2 MiB를 넘을 때만
배타적 trim lock을 얻어 약 1 MiB를 임시 파일과 atomic rename으로 보존합니다. Append와
교체도 동기화하여 교체된 inode에 기록이 남아 사라지는 상황을 막습니다. Trim lock이
사용 중이면 이번 정리는 건너뜁니다.

제한 사항: Claude Code 2.1.270의 문서상 `SubagentStop` payload는 이 저장소에서 아직 실측하지
않았습니다. `PreToolUse`의 subagent identity는 실측했지만 stop event의 identity와
transcript 전달은 실제 세션에서 확인해야 합니다. Gate claim 이후 위 명령으로 journal을
확인하십시오. 기록이 없으면 지원되지 않는 payload, hook 미호출, off-switch 등을 확인해야
합니다. `SubagentStop`에서 `systemMessage`가 표시되는지도 미확인 상태이므로 stderr와
journal에도 경고를 보존합니다.

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
