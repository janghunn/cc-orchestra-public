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

cc-orchestra 자체를 수정할 때는 [AGENTS.md](AGENTS.md)를 읽습니다.
새 서버 준비는 [BOOTSTRAP.ko.md](BOOTSTRAP.ko.md)를 참고하십시오.

설치되는 주요 경로:

```text
~/.claude/orchestra                         -> repo
~/.claude/agents/orchestrator.md
~/.claude/agents/verifier.md
~/.claude/agents/verifier-normal.md
~/.claude/agents/route-lead-*.md

~/.local/bin/cc-orch                       -> bin/cc-orch-runtime
~/.local/bin/codex-run                     -> bin/codex-run-runtime
~/.local/bin/orch-model-guard              -> bin/orch-model-guard-runtime
~/.local/bin/orch-summary-check
~/.local/bin/orch-usage-report
~/.local/bin/orch-archive
```

이 밖에 Fable legacy guard timer, Claude 5h/7d status-line quota tap, live runtime routing
`UserPromptSubmit` hook, structural stale-policy notice hook을 설치합니다.
선택형 poll guard는 [수동 폴링 방지 hook](#pretooluse-수동-폴링-방지-hook-선택-사항),
agent frontmatter로 자동 활성화되는 verifier guard는
[Verifier Bash 명령 guard](#verifier-bash-명령-guard)를 참고하십시오.

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

기본 branch는 `orch/<session-name>`, base는 현재 branch 또는 `HEAD`이며,
worktree는 `~/.claude/orchestra-state/worktrees/<project>/<session-name>`에 생성됩니다.
`--branch` / `--base`로 바꾸거나, 기존 branch를 다시 붙일 때 `--reuse-branch`를 사용합니다.

```bash
cc-orch session new cache ~/projects/api --branch orch/cache-v2 --reuse-branch
cc-orch session path main
```

`--inplace`는 연구 코드, 대형 데이터, conda/GPU 환경, 기존 build artifact를 그대로
사용할 때 편합니다. 병렬 feature별 세션은 branch/index/worktree/tmux를 분리합니다.
`main` 세션의 tmux 이름은 `ccorch-main`, launcher 이름은 `api-main`처럼 project와
session을 포함합니다. SSH가 끊겨도 tmux는 계속 실행됩니다. `stop`은 registry, branch,
worktree를 유지합니다. `Ctrl-b, d`로 detach하고 Claude 안의 `/exit`로 정상 종료합니다.

### 직접 실행과 Remote Control

```bash
cc-orch api ~/projects/api
cc-orch --no-rc api ~/projects/api
cc-orch --profile critical api ~/projects/api
cc-orch --profile deep api ~/projects/api
cc-orch --model opus[1m] --effort high api ~/projects/api
cc-orch session new main ~/projects/api --project-name api --inplace --no-rc
```

Remote Control은 기본적으로 `--remote-control orch-<project-name>`으로 켜집니다.
Managed session은 `orch-api-main`처럼 session 이름도 포함하며, 터미널·휴대폰·다른
머신에서 동일 대화를 제어할 수 있습니다. 보통 Tier 1은 normal로 유지하고 개별 task의
risk로 lead profile을 올립니다.

세션 생성·재시작 시 Claude Code와 Codex CLI의 npm `latest` 버전을 확인합니다.
업데이트와 버전 검증이 끝난 뒤 실행하며, 조회나 설치에 실패하면 시작하지 않습니다.
Codex-only는 Codex만 확인하고 backend 전환은 기존 세션 중단 전에 대상 CLI를 확인합니다.
현재 npm global prefix의 CLI 설치를 지원하며, 실행 중 프로세스는 자동 재시작하지 않습니다.
오프라인 재현·가짜 provider 테스트는 `CC_ORCH_CLI_AUTO_UPDATE=0`으로 검사를 생략할 수 있습니다.

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
codex   tight
  7d    used=90% headroom=0.117 reset=... in 6d

dispatch=codex-first
```

Codex headroom `(1-0.90)/(6/7)=0.117`은 `BUDGET_CRITICAL_RATIO=0.10` 이상이고
`BUDGET_TIGHT_RATIO=0.30` 미만이므로 tight이며, tight는
`BUDGET_CODEX_SPARING_MIN_RANK=3`(critical)보다 낮으므로 dispatch는 codex-first를 유지합니다.

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

Status-line 필드는 `rate_limits.five_hour.used_percentage` / `.resets_at`,
`rate_limits.seven_day.used_percentage` / `.resets_at`이며 Codex는
`rate_limits.primary.used_percent` / `.resets_at`을 사용합니다. Claude의 두 window가
같은 pressure이면 headroom이 더 낮은 쪽을 limiting window로 봅니다. Fable 전용 주간
사용률도 별도로 읽어 deep reasoning reserve를 보호합니다.

현재 정책은 subscription을 적극적으로 사용하도록 다음 경계값을 사용합니다.

| Pressure | Headroom ratio | reset을 모를 때 사용률 fallback |
|---|---|---|
| healthy | >= 0.55 | < 88% |
| watch | >= 0.30 and < 0.55 | >= 88% and < 96% |
| tight | >= 0.10 and < 0.30 | >= 96% and < 99% |
| critical | < 0.10 | >= 99% |

리셋까지 10분 이하이면 이미 100%를 소진한 경우 외에는 healthy입니다.
Window의 절반이 남으면 사용률 경계는 72.5%, 85%, 95%, 10%가 남으면 94.5%, 97%, 99%이며,
경계와 같을 때는 낮은 pressure에 속합니다. 같은 사용률도 reset에 가까우면 더 적극적으로
사용할 수 있습니다. Quota와 시간이 각각 절반 남으면 headroom은 `1.0`입니다.

## 동적 라우팅

### Claude lead 선택

| Risk | healthy | watch | tight | critical |
|---|---|---|---|---|
| low / trivial | light: Sonnet medium | light: Sonnet medium | light: Sonnet medium | light: Sonnet medium |
| normal | normal: Opus high | normal: Opus high | light: Sonnet medium | light: Sonnet medium |
| critical | critical: Opus xhigh | critical: Opus xhigh | normal: Opus high | normal: Opus high |
| critical + deep | critical-xhigh: Fable xhigh | critical: Opus xhigh | normal: Opus high | normal: Opus high |

`deep`은 사용자의 명시적 요청이나 보안·핵심 알고리즘처럼 여러 설계가 실제로 경쟁하는
경우에만 사용합니다. Plain critical은 watch까지 Opus 5.5 xhigh를 유지하고 tight부터
high로 effort를 낮춥니다. Fable 주간 사용률이 85%(`BUDGET_FABLE_RESERVE_PCT=85`)
이상이면 실제 모델이 Fable인 profile(현재 `critical-xhigh`)만 Opus `normal`로 낮춥니다.
Plain critical은 Fable 사용률의
영향을 받지 않으며 effort는 `CLAUDE_ROUTE_CRITICAL_*`를 따릅니다. 전역 Fable 소진
상태에서도 같은 모델 기준 규칙을 적용합니다.

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

Trivial 선언은 `brief.md`의 fenced block 밖 0열에 `RISK: trivial`로 쓰며 들여쓰기나
bullet을 쓰면 안 되고, fence 밖에서 `RISK:`로 시작하는 유일한 줄이어야 한다.
사유는 대시 뒤에만 쓸 수 있고 `plan.md`에는 `RISK AMENDED` 줄이 최대 하나만 있어야 한다.
다른 tier는 fence 밖 0열에서 선택적으로 대시 하나 뒤에 필드 마커로 시작하는 별도
선언형 줄인 경우에만 충돌하며 일반 문장이나 fenced 예시의 언급은 충돌로 보지 않는다.
Self-check의 `GATES:` 설명에는 명령·파일·숫자를 나타내는 ASCII 영문자나 숫자가
하나 이상 있어야 한다. 적용 범위와 low→trivial 변경은 [README Gate 정책](README.md#gate-정책)을 참고한다.

`STATUS: ACCEPTED`는 사용자가 실제 gate 결과를 검토하고 수락했다는 뜻이며 PASS가 아니다.
사용자만 승인할 수 있고, Tier 1이 `brief.md`의 fenced block 밖 0열에
`USER ACCEPTED: <YYYY-MM-DD> — <what was accepted and why>` 형식으로 수락 내용과 이유를
기록한다. `GATES:`에는 실제 결과를 명시해야 한다. 이 기록이 있으면 gate 주장 실패와
승인 없는 round 상한 초과는 `ACCEPTED EXCEPTION:` 행으로 출력한다. 구조 오류, artifact와
모순되는 PASS 주장, `USER ACCEPTED:` 기록 누락은 `--strict`에서 계속 오류다. 보안 검사는
기존처럼 자문으로 유지된다. Strict 검사가 성공하면 마지막 행은
`CHECK: PASS (accepted with exceptions: n, risk=...)`이며 일반 PASS와 구분된다.

trivial이 아닌 작업에서는 `orch-summary-check --strict`가 양성 `GATES:` 주장을
작업 디렉터리의 artifact와 대조한다.

- `codex-verify PASS`: `codex-verdict.md`의 첫 번째 비어 있지 않은 줄이 `CODEX-VERDICT: PASS`.
- `codex-review CLEAR|NONBLOCKING`: `codex-review.md`의 첫 번째 비어 있지 않은 줄이
  `CODEX-REVIEW: CLEAR` 또는 `CODEX-REVIEW: BLOCKING 0 / NONBLOCKING <m>`.
- `codex-auditor PASS` (Codex backend): `codex-audit.md`의 첫 번째 비어 있지 않은 줄이 `CODEX-AUDIT: PASS`.
- `claude-verifier PASS`: `verdict.md`, `verdict-*.md`, `verifier-verdict.md`,
  `verifier-verdict-*.md`, `verifier-normal-verdict.md`, `verifier-normal-verdict-*.md` 중
  mtime이 가장 최신인 파일에 `VERDICT: PASS` 또는
  `VERIFIER-VERDICT: PASS`가 있어야 한다(Markdown 제목도 허용). 또는 `## Verdict`
  제목 다음의 첫 번째 비어 있지 않은 줄이 `PASS`로 시작해야 한다(Markdown 강조와 `PASS.` 허용).

`verifier-normal`은 dispatch에서 받은 `<task-dir>/verdict.md` 또는 후속 실행의
`verdict-<n>.md`에 기록한다. 첫 줄은 정확히 `VERDICT: PASS`, `VERDICT: FAIL`,
`VERDICT: INCONCLUSIVE` 중 하나이며 뒤에 근거를 쓴다. 다른 basename이 주어지면 같은
디렉터리의 `verdict.md`로 바꾸고, 이미 있으면 n >= 2 중 가장 작은 미사용 번호의
`verdict-<n>.md`를 쓴다. 실제 경로를 보고하고 `CONCERNS`에 경로 대체를 명시한다.

최상위 파일만 검사하며 `evidence/`, `rounds/`의 보관 파일은 제외한다. 이름 패턴에 맞는 모든
verifier 파일 중 mtime이 가장 최신인 것을 선택하고, mtime이 같으면 version 정렬상 마지막 이름을 선택한다.
일치하는 파일이 1000개를 넘으면 verdict를 파싱하지 않고 `--strict`에서는 오류, 그 외에는
경고를 낸다. 이전 실행 파일은 `evidence/` 아래로 보관한다.
인식된 verdict header 중 마지막 것이 우선하며, header가 없으면 마지막으로 인식된 verdict
section을 사용한다. Claude verifier의 header 이름은 대소문자를 구분하지 않지만 artifact의
verdict token은 구분한다. `VERDICT: PASS | FAIL | INCONCLUSIVE` 같은 선택지 template은
verdict로 인정하지 않는다. Artifact의 verdict token(또는 review 개수) 뒤에는 공백만 있거나,
공백 다음에 `—`, `–`, `-`, `(`, `:`, `;`, `,`, `.`로 시작하는 주석만 허용한다(공백은 선택 사항).
`PASS but only as an example`처럼 바로 이어지는 일반 문장은 거부한다.
ASCII `-` 앞에는 반드시 공백 문자가 하나 이상 있어야 한다. `PASS - 12/12`는 허용하지만
`PASS-FAIL`, `PASS-ish`, `CLEAR-BLOCKING 1`은 거부한다. 나머지 구분자는 token에 바로
붙거나 공백 뒤에 와도 된다.
1 MiB를 넘는 파일은 파싱하지 않는다. Summary와 Claude verifier의
fenced block은 무시하며, Codex artifact는 첫 번째 비어 있지 않은 줄 자체가 header여야 한다.
줄 앞의 inline backtick span은 fence를 열지 않는다. 3개 이상 backtick 뒤 같은 줄에
backtick이 더 있으면 이후 선언을 fence 안으로 숨길 수 없다.
Fence 밖의 마지막 `GATES:` 줄을 사용하고 status는 접두사가 아닌 완전한 token으로 판정한다.
각 주장은 `·`, `;`, `,`로 구분한 구간의 시작에 있어야 하며 `no codex-verify PASS`처럼
앞에 다른 문구가 붙으면 주장으로 인정하지 않는다.
Artifact 누락이나 모순은 `--strict`에서는 오류, 그 외에는 경고다. Trivial self-check와 low-risk
review waiver 정책은 유지된다. 실패를 해소하려면 summary를 수정하거나 일치하는 artifact를
제공한다. Stop gate에 문서화된 `stop-gate.off` switch도 계속 사용할 수 있다.

`orch-summary-check`의 별도 자문 보안 검사는 현재 branch와 local `main`(없으면 `origin/main`)의
merge base부터 `HEAD`까지 커밋된 변경의 추가 줄을 검사한다. 설치 checkout과 task artifact
위치가 달라도 작업 worktree에서 실행한다. Git checkout 밖에서는 task 디렉터리의 저장소를
사용한다. `.md`, `.json`, `.conf`, `.sh`, `.py`와 모든 `bin/` 디렉터리 바로 아래 파일에서
credential 형태의 literal, 확인 절차를 생략하는 지시, 광범위한 Bash 권한 문자열을 검사한다.
발견 사항은 자문이며 `--strict`에서도 PASS/FAIL과 gate 오류·경고 수에 영향을 주지 않는다.
Git 기준점을 사용할 수 없으면 skipped로 보고하며 credential이 있는 줄은 출력에서 가린다.
전체 파일 검사는 `bin/orch-security-scan --files <file>...`로 실행한다(발견 없음 0, 발견 있음 1).
`bin/orch-security-scan` 자체의 pattern 정의와 진단 label 줄에서는 예상된 지시 문구 일치가
두 건 나온다. 이 결과도 자문이며 scanner 코드에서 예외 처리하지 않는다.

이 명령은 `route-lead-bravo-normal` 같은 **고정된(immutable) agent type**과 해당 모델 및 effort를 반환합니다.

`build-roster-runtime.sh`는 4개 slot × 4개 profile 조합, 총 16개의 `route-lead-*` agent를 미리 생성합니다. 기존 legacy quota guard는 이 `route-lead-*` namespace를 다시 쓰지 않습니다.

즉 사용량 상태가 바뀔 때 agent 정의 파일 자체를 수정하는 것이 아니라, **이미 Claude Code가 캐시한 여러 agent type 중 다음 작업에 맞는 것을 선택**합니다.

### Tier-1 orchestrator

일반적인 `normal` cc-orch 세션의 Tier-1 orchestrator는 **Sonnet @ high**로 유지합니다. Tier-1은 사용자 의도 파악, 작업 분해, 상태 추적과 라우팅에 집중하고, 무거운 설계·구현·검토는 아래 단계의 Claude lead와 Codex lane에 분배합니다.

이미 실행 중인 Tier-1 모델은 quota 상태가 변해도 실행 도중 hot-swap하지 않습니다.

Legacy guard가 `active=opus[1m]`여도 runtime-managed normal Tier 1은
`sonnet[1m] @ high`를 유지합니다. `orch-model-guard active`는 legacy compatibility
상태이므로 실제 프로세스 모델과 다를 수 있습니다. Brief 작성, lead 배정, registry와
결과 보고도 Tier 1의 책임입니다.

### Codex 모델과 effort 선택

새 `codex-run` 호출마다 모델과 effort를 자동으로 다시 결정합니다.

| Mode | healthy | watch | tight | critical |
|---|---|---|---|---|
| `intake` | Astra high (폴백 Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` low |
| `investigate` | Astra high (폴백 Sol high) | `gpt-6.1-sol` high | `gpt-6.1-sol` medium | **withheld** |
| `implement` | Astra xhigh (폴백 Sol xhigh) | `gpt-6.1-sol` high | `gpt-6.1-sol` high | **withheld** |
| `review` | Astra high (폴백 Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium |
| `plan-review` | Astra high (폴백 Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium |
| `verify` | Astra high (폴백 Sol high) | `gpt-6.1-sol` medium | `gpt-6.1-sol` medium | `gpt-6.1-sol` low |

전체 라우팅 표는 `budget-policy.conf`에 있습니다.
자동 라우팅된 healthy 호출은 `CODEX-RUN: MODEL_FALLBACK`을 출력하며, Astra를 사용할 수 없으면 해당 lane의 일반 기본값(`gpt-6.1-sol`)으로 폴백합니다. Astra를 명시적으로 요청하면 대신 `CODEX-RUN: MODEL_UNAVAILABLE`과 함께 종료 코드 6으로 종료합니다. `CC_ORCH_CODEX_CATALOG_CHECK=0`으로 설정하면 live/cached catalog 사전 확인을 비활성화할 수 있습니다.

명시적으로 전달한 옵션은 자동 라우팅보다 항상 우선합니다.

```bash
codex-run ... --model sol --effort xhigh
codex-run ... --critical
codex-run ... --fast-mode
codex-run ... --mech
```

WATCH/TIGHT/CRITICAL 라우팅은 `gpt-6.1-sol`을 사용합니다.
일반 기본값, healthy에서 Astra를 쓸 수 없을 때의 폴백, `--model sol`도 `gpt-6.1-sol`을 뜻합니다.
`--model luna`, `--mech`, `--fast`는 `gpt-6-luna`를 뜻합니다. `--model terra`는 여전히
`gpt-5.6-terra`를 명시적으로 선택하며, GPT-6 Terra는 없습니다. 기존 `gpt-6-sol`(GPT-6 Sol)은
전체 slug로 계속 사용할 수 있고, 재개한 thread는 해당 모델을 유지합니다.
전체 slug(예: `--model gpt-5.6-sol`)는 그대로 전달하며, resume은 thread에 기록된 모델을 유지합니다.
Healthy의 Astra(`gpt-6-astra`) 가용성은 계정/CLI별 live catalog와
`~/.codex/models_cache.json`으로 확인합니다.
캐시의 `client_version`이 PATH의 `codex`보다 오래되면 Astra를 absent로 보고하지 않고
unknown으로 취급해 진행합니다(실제 거부는 실행 시 분류합니다).
Critical에서는 cross-family review와 실행
검증 quota를 보존하려고 자동 investigate/implement를 보류합니다. 조사는 Claude/Explore,
구현은 Claude dev fallback을 사용할 수 있고 intake/review/plan-review/verify는 유지합니다.
별도 Luna lane은 `templates/lead.md.tpl`의 lane 표를 참고하십시오.

### Fast mode

`CODEX_ALWAYS_FAST_MODE=1`이므로 자동으로 선택된 지원 Astra/Sol/Terra 호출은 Fast mode를
사용합니다. `--fast-mode`는 선택된 model/effort를 유지하고 해당 호출만 공식 Fast tier로
실행합니다. `gpt-6.1-sol`(일반 기본값 / `sol`), `gpt-6-sol`, `gpt-5.6-sol`, `gpt-6-astra`, `gpt-5.6-terra`는 wrapper의
Fast-mode와 명시적 `--effort ultra` allowlist에 모두 포함됩니다.
Luna(`gpt-6-luna`, `gpt-5.6-luna`)는 두 allowlist 모두에서 제외됩니다. 최대 effort는 `max`이며 Fast mode는 Luna용 옵션이 아닙니다.
`ultra`는 자동 선택하지 않으며 사용자의 명시적 요청에 따라 `--effort ultra`로 지정합니다.
`--mech`와 legacy `--fast`는 별도의 명시적 Luna 경량 경로입니다.
`resume`은 기존 thread의 context/model 연속성을 우선하여 새 자동 route를 강제하지 않습니다.

특정 명령 한 번만 자동 Codex 라우팅을 끄려면:

```bash
CC_ORCH_AUTO_ROUTE=0 codex-run ...
```

현재 shell 전체에서 끄려면:

```bash
export CC_ORCH_AUTO_ROUTE=0
```

### Codex 명령

모든 자동 Codex 실행은 `codex-run` facade를 통합니다.

```bash
codex-run intake      <workdir> <task-dir> "<goal>"
codex-run investigate <workdir> <task-dir> "<question>"
codex-run implement   <workdir> <task-dir>
codex-run implement   <workdir> <task-dir> --lane b
codex-run implement   <workdir> <task-dir> --mech
codex-run resume      <workdir> <task-dir> "<follow-up>" [--lane b]
codex-run plan-review <workdir> <task-dir> [--critical]
codex-run verify      <workdir> <task-dir> [--critical]
codex-run review      <workdir> <task-dir> --base <branch> [--critical]
codex-run status      <task-dir>
```

`--model astra` / `--model <slug>`, `--effort`, `--critical`로 명시적으로 지정할 수 있고,
`--dry-run`은 모델 실행 없이 조합된 명령만 출력합니다.

## provider 간 dispatch 결정

`orch-model-guard lanes`는 Claude와 Codex의 현재 quota 압박을 비교해 다음 중 하나를 선택합니다.

```text
dispatch=codex-first
dispatch=codex-sparing
```

- `codex-first`: 기본 정책. 무거운 조사·구현·검증을 Codex 쪽에 적극적으로 배분
- `codex-sparing`: Codex quota 압박이 Claude보다 더 큰 경우 Codex를 절약하고, 남은 quota를 독립적인 review/verify gate에 우선 보존

이 판단도 단순 사용률이 아니라 리셋까지 남은 시간을 포함한 headroom을 사용합니다.

Codex가 healthy/watch/tight이면 `codex-first`를 유지하며 provider를 바꾸기 전에
Codex 내부 model/effort를 낮춥니다. Claude는 이미 control cost를 지불하므로 무거운
실행에는 별도 Codex pool을 사용합니다. `codex-sparing`은 critical reserve boundary
(`BUDGET_CODEX_SPARING_MIN_RANK=3`)에서 Codex가 Claude보다 압박이 클 때 시작합니다.
둘 다 critical이면 `BUDGET_PROVIDER_SWITCH_MARGIN`으로 headroom 차이를 비교합니다.
Claude만 critical이고 Codex는 그 아래이면 `codex-first`를 유지합니다.

### Codex pressure pin (압력 고정)

`budget-policy.conf`는 `CODEX_PRESSURE_PIN="healthy"`, `CODEX_PRESSURE_PIN_UNTIL=""`(만료 없음)으로 제공됩니다.
Codex healthy 행(Astra, Fast 켜짐)을 선택하고 실제 Codex 압력과 관계없이 `codex-first`를 유지합니다. Claude 라우팅은 그대로입니다.
hook/compact 상태에는 `codex=healthy(pinned; real=watch, …)`가 표시되며, `budget`, `lanes`, `route codex`의 reason에도 고정 여부와 실제 상태가 표시됩니다. 실제 상태는 `budget-state`에 계속 기록됩니다.
`healthy`만 허용하며, 잘못된 값은 stderr 경고를 출력하고 동적 라우팅으로 처리합니다.
`CODEX_PRESSURE_PIN_UNTIL`은 epoch 초 또는 로컬 절대 날짜/시간 `YYYY-MM-DD[ HH:MM[:SS]]`을 받으며, 해당 시각부터 고정을 무시합니다. 잘못된 날짜나 상대 날짜는 경고 후 동적으로 처리합니다.
명시적인 `--model`, `--effort`, `--critical`, `--fast` 플래그가 계속 우선합니다.
고정 중에는 review/verify 예비 quota가 보존되지 않습니다. quota가 소진되면 provider에서 실패하고 기존 exit-code 처리를 따릅니다. Astra가 없으면 `model-policy.conf`에 따라 fallback합니다.
정책을 호출마다 읽고 policy revision에서 제외하므로 `cc-orch --reload`는 필요 없습니다. `CODEX_PRESSURE_PIN=""`로 바꾸면 동적 라우팅이 복구됩니다.

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

egress guard의 알려진 한계(수정하지 않고 수용): (a) `secret_shaped()` in bin/orch-jev의 count cancellation — 의도적으로 구성된 문서에서 placeholder로 억제된 한 줄 assignment 하나가 여러 줄에 걸쳐서만 조립되는 credential 하나를 상쇄할 수 있어 그 cross-line 값이 전송됩니다. (b) 한 LF 줄 안에서 placeholder 표식과 credential 사이에 bare CR이 있으면 탐지가 억제됩니다. 기존 Bash scanner(bin/orch-security-scan)도 같은 종류를 놓칩니다. scan은 사용자가 지정한 파일(또는 stdin)만 읽으며 guard를 통과한 내용은 모두 Jev API로 전송되므로, 그곳에 보내지 않을 파일은 지정하지 마세요.

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
jev-policy.conf에서 JEV_JOURNAL=0으로 끌 수 있고(환경 변수가 아니라 이 파일에서만 읽음) journal 기록 실패는 자문 결과에 영향을 주지 않습니다.
Codex-only 모드는 사용하지 않습니다. `cc-orch-codex` 세션은 `CC_ORCH_BACKEND=codex`를
설정하며, 이때 도구는 외부 호출을 거부합니다.

### Codex 라우팅 shadow 모드 (선택 사항, 로그만 기록)

Shadow 모드는 기본적으로 꺼져 있고(`JEV_SHADOW_ENABLED=0`) hybrid 모드에서만 동작합니다.
Codex-only dispatch는 shadow를 시작하지 않습니다. 활성화하면 `codex-run-runtime`이
대상인 최초 `implement` 호출에 detached worker를 시작하고 기다리지 않습니다.
Jev를 사용할 수 없어도 dispatch, 인자, stdout/stderr, exit code, `codex.log`는 그대로입니다.
플래그가 꺼져 있으면 shadow process, network 요청, 로그 기록이 없습니다.

키는 위 사이드카와 동일하게 설정하고, `jev-policy.conf`(또는 `CC_ORCH_JEV_POLICY`로
지정한 정책 파일)에서 `JEV_SHADOW_ENABLED=1`로 바꿉니다. `JEV_ENABLED=1`도 필요합니다.
이 값들은 환경 변수가 아니라 정책 파일에서 읽습니다. 기본 매핑과 상한은 다음과 같습니다.

```bash
JEV_SHADOW_ENABLED=1
JEV_SHADOW_MAP_MECHANICAL="gpt-6-luna@medium"
JEV_SHADOW_MAP_ROUTINE="gpt-6-astra@high"
JEV_SHADOW_MAP_INVOLVED="gpt-6-astra@xhigh"
JEV_SHADOW_MAP_NOVEL="gpt-6-astra@xhigh"
JEV_SHADOW_MIN_CONFIDENCE=0.6
JEV_SHADOW_MAX_BYTES=12000
JEV_SHADOW_TIMEOUT_SECONDS=5700
JEV_SHADOW_LOG="codex-shadow.jsonl"
```

Jev로 전송하는 작업 내용은 `<task-dir>/brief.md`에서 `## Risk` 섹션과
`RISK:` / `DEEP REASONING:` 줄을 제거한 본문뿐입니다. 기존 egress guard가 자르기 전
원본 전체와 전송 전 변환된 요청을 검사하며, 탐지되면 `skipped:secret-shaped`로 건너뜁니다.
Brief 본문은 UTF-8 기준 `JEV_SHADOW_MAX_BYTES` 이내로 제한하고, 줄이면
`truncated=true`를 기록합니다. `plan.md`, workdir의 코드, source 경로 metadata는
요청을 위해 읽거나 전송하지 않습니다. 정책·키·질문 template은 기존 사이드카와 동일하게
처리하며, worker는 실행 관찰을 위해 로컬 `codex.log`와 `.codex-session` metadata를 별도로 읽습니다.

Jev는 난이도(`mechanical < routine < involved < novel`)와 확장된 비국소적 추론이 필요한
확률(Noul)만 판단하며 모델 이름을 고르지 않습니다. 매핑은 우리가 관리합니다.
mechanical은 기존 `--mech` pair, routine은 healthy 기본값보다 effort 한 단계 아래,
involved/novel은 healthy 기본값을 사용합니다. Confidence가 `JEV_SHADOW_MIN_CONFIDENCE`보다
낮으면 pair를 제안하지 않습니다(`suggested_reason=low-confidence`). 정책의
`JEV_SHADOW_MAP_*`를 수정하면 재시작 없이 제안이 바뀌며 실제 라우팅에는 영향을 주지 않습니다.

기록은 `jev.log`, `codex.log`와 별도로 `<state>/codex-shadow.jsonl`에 append하며
권한은 mode 600입니다. `JEV_SHADOW_LOG`로 경로를 바꿀 수 있고 상대 경로는 `<state>`
기준입니다. 각 record는 다음 고정 필드를 가지며 작업 본문, 파일 경로, 키를 담지 않습니다.

```text
timestamp, id, lane, thread_id, mode, status, jev_model, difficulty, difficulty_confidence,
reasoning, suggested_model, suggested_effort, suggested_reason, initial_model, initial_effort,
initial_fast_mode, final_model, final_effort, final_fast_mode, final_fallback_from, attempts,
observation, explicit_flags, pressure, codex_exit, duration_ms, jev_latency_ms, jev_attempts,
input_tokens, truncated
```

`id`는 `<lane>:<facade-pid>:<t0>`이며, 알 수 없는 답변이나 실행 정보는 null입니다.
`initial_*`는 facade가 라우팅한 pair이고 `final_*`와 `attempts`는 fallback을 포함해
관찰한 실행 결과입니다. `codex_exit`는 `codex-run`의 exit가 아니라 `codex.log`에 남은
원시 Codex exit입니다. 같은 초에 같은 workdir에서 동시에 호출하면 실행 주체를 구분하지
못할 수 있습니다(`observation=ambiguous`). 그 밖의 observation 값은 `exact`, `none`,
`timeout`입니다. Worker는 `JEV_SHADOW_TIMEOUT_SECONDS` 이후 관찰을 중단합니다.
상태가 `ok`가 아니거나 로그 기록에 실패하면 `<state>/guard.log`에
`JEV: shadow <id> — <status>` 진단을 최대 한 줄 남기며 dispatch 터미널에는 출력하지 않습니다.
Shadow 경로는 `jev.log`에 기록하지 않습니다.

```bash
~/.claude/orchestra/bin/orch-jev shadow-report
~/.claude/orchestra/bin/orch-jev shadow-report --log <path>
```

보고서는 Jev를 다시 호출하지 않고 저장된 원시 답변에 현재 정책 매핑을 다시 적용합니다.
일치, 더 낮거나 높은 제안, skipped/unavailable 사유, 제안 tier별 실패·재시도의 건수와
비율만 출력합니다. 비교에는 `observation=exact`이고 제안·최종 pair가 모두 있는 기록을,
실패·재시도 비율에는 exact이고 exit가 알려진 기록만 사용합니다. 나머지는 unobserved로
집계합니다. Bucket의 전체 기록이 10개 미만이면 ` — fewer than 10 records`를,
exact이고 exit가 알려진 기록이 10개 미만이면 ` — fewer than 10 observed`를 표시합니다.
두 표시는 함께 나타날 수 있습니다.
마지막 줄은 `counts only — this report draws no conclusion.`입니다.

대상은 facade 경로로 한정됩니다. Core `bin/codex-run` 직접 호출과 Codex-only dispatch는
shadow record를 만들지 않습니다. Shadow가 켜져 있을 때 `resume`, 명시적
`--model` / `--effort` / `--mech` / `--fast` / `--escalate`, `--dry-run`, withheld 호출은
각각 `skipped:resume`, `skipped:explicit-flags`, `skipped:dry-run`, `skipped:withheld`로
기록하며 Jev 호출과 실행 관찰은 하지 않습니다. 자동 라우팅이 꺼져 있거나 사용할 수 없으면
`skipped:no-route`로 기록합니다. 다른 모드는 기록하지 않습니다.
잘못된 인자(예: 유효하지 않은 `--lane` 이름이나 빈 task dir)로 시작된 worker는
Jev를 호출하지 않고 `skipped:invalid-args`로 기록합니다.

### 로컬 llama.cpp scan 세컨드 오피니언 (선택 사항, 로그만 기록)

이 보조 기능은 기본적으로 꺼져 있으며 hybrid 세션을 지원합니다. `JEV_LOCAL_ENABLED=1`이면
`orch-jev scan`은 TypeSafe 호출 후 준비된 요청과 Jev의 답변을 분리된
`bin/orch-jev-local worker`에 전달합니다. TypeSafe를 사용할 수 없는 결과도 포함하며,
worker를 기다리지 않습니다. 이 기능은 orch-jev의 stdout, stderr, exit code, `jev.log`
record를 바꾸지 않으며 gate나 라우팅 결정에도 영향을 주지 않습니다. 플래그가 꺼져 있으면
이 기능은 프로세스를 시작하거나 파일·로그를 만들지 않습니다. `lint-brief`와 `risk`는
worker에 요청을 전달하지 않습니다.

검증된 llama.cpp 빌드를 설치하고 고정된 모델을 한 번 내려받으세요. `<env>`와 `<state>`를
절대 경로로 바꾸세요. `<state>`는 `CC_ORCH_STATE_DIR`이며, 미설정 시
`~/.claude/orchestra-state`입니다. 검증된 패키지는 conda-forge의
`llama.cpp-10588-cuda130`이며 다른 빌드는 실행 플래그를 거부할 수 있습니다.

```bash
conda create -y -p <env> -c conda-forge "llama.cpp=10588=cuda130_hd5b56ce_0"
mkdir -p <state>/models && curl -fL -o <state>/models/Qwen3-8B-Q8_0.gguf https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q8_0.gguf
```

`jev-policy.conf`의 `JEV_LOCAL_SERVER_BIN`을 `<env>/bin/llama-server`로 지정한 뒤 실행합니다.

```bash
~/.claude/orchestra/bin/orch-jev-local serve
```

`serve`는 서버를 시작하기 전에 모델의 SHA-256을 검증합니다. 모델이 없으면 획득 방법을
출력하고 exit 1로 끝나며, 해시가 달라도 exit 1입니다. 하네스는 모델을 자동으로 내려받거나
서버를 자동으로 시작하지 않습니다. `serve`는 foreground에서 실행되므로 tmux나 systemd
사용자 서비스에서 실행하세요. `JEV_LOCAL_GPU`가 지정한 GPU(기본 0)에 약 **10.5 GiB의
상주 VRAM**을 사용하며 context는 16k, slot은 하나입니다.
`CUDA_DEVICE_ORDER=PCI_BUS_ID`를 설정하고 `LLAMA_ARG_*` 환경 변수 override를 제거합니다.
서버 실행 후 `JEV_LOCAL_ENABLED=1`로 설정하세요. 배포 기본값은 다음과 같습니다.

```bash
JEV_LOCAL_ENABLED=0
JEV_LOCAL_SOCKET="jev-local/llama.sock"
JEV_LOCAL_MODEL_PATH="models/Qwen3-8B-Q8_0.gguf"
JEV_LOCAL_MODEL_DIGEST="408b955510e196121c1c375201744783b5c9a43c7956d73fc78df54c66e883d6"
JEV_LOCAL_SERVER_BIN="llama-server"
JEV_LOCAL_GPU="0"
JEV_LOCAL_TIMEOUT_SECONDS=10
JEV_LOCAL_DEADLINE_SECONDS=60
JEV_LOCAL_LOG="jev-local.jsonl"
```

Worker는 두 egress guard를 통과하여 Jev에 보낸 것과 정확히 같은 준비된 요청 및 Jev의
숫자 답변을 받습니다. 추론 전에 변환 후 guard를 다시 실행합니다. Unix socket으로만
통신하며 네트워크 연결, proxy, redirect를 사용하지 않습니다. `serve`는 socket 디렉터리
(기본 `<state>/jev-local`)를 생성하고 mode 0700으로 설정하므로 socket 전용 디렉터리를
사용하세요. 디렉터리는 운영자가 소유하므로 브라우저나 다른 로컬 사용자가 접근할 수 없습니다.
Worker와 서버 환경에서 `TYPESAFE_API_KEY`를 제거합니다. 모델 파일, socket, 로그의
상대 경로는 `<state>` 기준으로 해석합니다.

Worker는 `jev.log`와 별도로 `<state>/jev-local.jsonl`(mode 0600)에 record 하나를 append하며,
`JEV_LOCAL_LOG`로 경로를 바꿀 수 있습니다. 고정 필드는 다음과 같습니다.

```text
timestamp, id, status, model, jev_model, jev_outcome, chunks, local_p, jev_p,
min_option_mass, requests, latency_ms, prompt_tokens, cached_tokens
```

로그에는 본문, source 이름, 줄 범위, prompt가 없습니다. `id`는
`<orch-jev pid>:<t0>`(요청 전달 시각을 Unix 초 정수로 표시하며, 잘못된 전달 데이터는
`unknown`)이고 알 수 없는 값은 null입니다. `local_p`와 `jev_p`는 chunk 순서를 유지합니다.
Status는 `ok`, `skipped:secret-shaped`, 또는 `unavailable:` 뒤에 `handoff`, `config`,
`server`, `socket-denied`, `timeout`, `deadline`, `http <code>`, `malformed response`,
`model-mismatch`, `no-option`, `non-option`, `option-mass-unknown`, `network`, `internal error`가
붙는 형태입니다. Worker는 `guard.log`나 다른 파일을 쓰지 않으며 로그 append가 실패하면
조용히 버립니다. 모든 로컬 응답은 `serve`가 설정한 alias인
`jev-local-<SHA-256 앞 16자>`를 반환해야 합니다. 이는 모델 불일치를 탐지하는 것이며,
의도적으로 alias를 그대로 반환하는 프로세스에 대한 attestation은 아닙니다. 비공개 socket
디렉터리가 접근 경계입니다.

```bash
~/.claude/orchestra/bin/orch-jev-local report
~/.claude/orchestra/bin/orch-jev-local report --log <path>
```

보고서는 저장된 확률에 현재 `JEV_SCAN_THRESHOLD`를 `p >= threshold`로 다시 적용합니다.
Status 건수, chunk 및 record의 탐지 일치 건수, 확률의 평균 절대 차이, 로컬 지연 시간의
median/p95를 출력합니다. 비교에는 로컬과 Jev 결과가 모두 `ok`인 기록만 사용하며,
비교 가능한 기록이 10개 미만이면 표시합니다. 마지막 줄은
`counts only — this report draws no conclusion.`입니다. Worker에는 별도의 로컬 threshold나
조언 출력이 없습니다.

Codex-only 모드는 worker에 요청을 전달하지 않습니다. Hybrid Codex sandbox에서는 Unix
socket이 거부되고(`unavailable:socket-denied`), state 디렉터리의 로그 쓰기도 거부되므로
아무 기록도 남지 않습니다. 지원되는 실행 환경은 사용자 shell과 Claude lead/dev Bash입니다.
서버가 중지되어 있으면 `unavailable:server`가 되며 orch-jev는 worker를 기다리느라 지연되지
않습니다. Phase-0 합성 injection set의 FPR은 로컬 **0.375**, Jev **0.00**이었으므로
이 신호는 데이터 수집용으로만 사용합니다.

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

`agents/*.md`, `templates/*.tpl`, structural `model-policy.conf` 설정이 이 구조 변경에
해당합니다. `model-policy.conf`의 lead model/effort를 바꾸면
`~/.claude/agents/lead-*.md`, `~/.claude/agents/route-lead-*.md`도 재생성해야 합니다. `./install.sh`(내부에서 `build-roster-runtime.sh` 호출)와
`./install.sh --check` 뒤 `cc-orch --reload <project>`를 실행하십시오.
Reload만으로 roster는 재생성되지 않습니다. Managed session은 `/exit` 뒤
`cc-orch session restart <name>`으로 기존 대화를 이어 재시작할 수도 있습니다.

실행 중인 세션을 reload할 때는 hook과 같은 순서로 `.orchestra/REGISTRY.md`를 찾는다.
Git toplevel과 그 상위 디렉터리, 프로세스 cwd와 그 상위 디렉터리, git common directory의
상위 디렉터리, linked worktree 순서이며 처음 발견한 파일을 사용한다. Active lead 행이 하나라도
있으면 거부한다. Terminal status는 `PASS`, `FAIL`, `BLOCKED`, `ACCEPTED`, `CLOSED`, `IDLE`, `UNASSIGNED`이며,
뒤에 `[A-Za-z0-9_-]` 밖의 문자와 주석을 붙일 수 있다(`PASS (done)`, `CLOSED - merged`).
`PASS-ish`와 빈 status는 active다. Registry가 없거나 읽을 수 없거나 프로세스 cwd를 확인할 수
없어도 거부한다. Registry가 없으면 검사한 경로를 모두 나열하고, 읽을 수 없으면 해당 파일을,
cwd를 확인할 수 없으면 해당 프로세스를 알린다. 유일한 override는 `--force-reload`다.
Reload는 SIGTERM만 보내며 SIGKILL은 보내지 않는다. `cc-orch-session switch`도 같은 terminal
status 규칙을 사용하고 override는 `--force`다.

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

설치 시 독립 hook들을 user settings와 session guardrails에 등록합니다.
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
`STATUS: PASS`, `FAIL`, `BLOCKED`, `ACCEPTED` 행과 `GATES:` 행이 모두 있을 때만 검사합니다. STATUS
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

확정된 task 디렉터리는 있지만 `summary.md`가 없으면 `summary.md not saved yet; Tier 1
saves the returned block and runs orch-summary-check --strict <dir>`라는 안내만
`systemMessage`로 출력합니다. Journal에는 `note`로 기록하고 stderr에는 아무것도 쓰지
않으며 checker도 실행하지 않습니다.

Checker는 `CC_ORCH_SUMMARY_CHECK`의 실행 파일 경로, hook 자신의 저장소에 있는
`bin/orch-summary-check`, `$HOME/.local/bin/orch-summary-check`, `PATH` 순서로 찾습니다.
Checker와 마찬가지로 hook도 fenced block 밖의 `summary.md` STATUS 행을 읽습니다.
Override는 운영 점검과 테스트에 사용할 수 있습니다. `--strict <task-dir>`로 실행하고
해당 task의 `summary.md` STATUS 행도 읽으며 `[lead-x]` 접두사를 허용합니다. Exit 0이면
transcript와 summary의 상태가 같을 때 조용히 허용하고, 다르거나 기록된 상태를 읽을 수
없으면 경고합니다. Exit 1에서는 transcript가 `PASS` 또는 `ACCEPTED`를 주장하면 차단합니다. Summary가
`BLOCKED`나 `FAIL`인데 transcript가 `PASS` 또는 `ACCEPTED`인 경우에도 반드시 차단하며 checker 출력의 처음
1,500바이트, 정확한 재실행 명령, off-switch 경로를 제공합니다. Transcript가 `BLOCKED`
또는 `FAIL`이면 차단하지 않습니다. 실제 gate 실패는 checker 출력을 담은
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
판정(`allow`, `deny`, `block`, `warn`, `note`, `skip`), 한 줄 사유를 기록합니다. Fast path는
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

### 컴팩션 복구 hook

`hooks/orch-compact-context.sh`는 `SessionStart`의 `compact` matcher로 실행되며,
`guardrails.json`과 user settings에 등록됩니다(`--safety-hooks-only`도 포함). Timeout은 10초이고 `|| true`를 유지합니다.
기본 `/home/janghun/cc-orchestra` 경로에서는 guardrails와 installer가 따옴표 없는 동일한 command 문자열을 기록합니다.
2.1.287 로컬 실험에서 두 settings 파일에 등록한 동일 command는 한 번, 따옴표가 다른 변형은 두 번 실행되었으므로,
다른 경로에 설치할 때도 guardrails 문자열을 설치된 문자열과 동일하게 유지해야 합니다.
`CC_ORCH_PROJECT`가 있어야 하며 subagent payload는 건너뜁니다. `$state_dir/compact-context.off`로 끕니다.
`state_dir=${CC_ORCH_STATE_DIR:-$HOME/.claude/orchestra-state}`이며 로컬 파일만 읽고 오류 시 조용히 허용합니다.
라벨이 붙은 데이터에는 전체 agentId를 가진 registry 행, slot board, 선택적인 `DIRECTIVES.md`, 고정 안내가 들어갑니다.
Open/terminal 구분은 reload 규칙을 따릅니다. `PASS`, `FAIL`, `BLOCKED`, `ACCEPTED`, `CLOSED`, `IDLE`,
`UNASSIGNED` 뒤가 `[^A-Za-z0-9_-]` 또는 문자열 끝이면 terminal이며 빈 상태는 open입니다.
JSON stdout 전체를 UTF-8 6144바이트로 제한합니다. 오래된 terminal 행, 파일 끝의 directive 행,
오래된 open 행 순서로 통째로 제외하며 board는 유지합니다. 1000자를 넘는 directive 행도 통째로 제외합니다.
Live routing 계산은 usage refresh를 시작할 수 있어 제외하며 다음 prompt에서 다시 제공됩니다.
[Hook 문서](https://code.claude.com/docs/en/hooks)는 `SessionStart`의 `compact` matcher와
`additionalContext`를 명시합니다. 2.1.287 headless 수동 `/compact` 실험에서
PreCompact → SessionStart(compact) → PostCompact 순서와 compact boundary 뒤의 복구 context를 관찰했습니다.
자동 compaction은 live 검증하지 않았습니다. Guardrails는 시작 시 읽으므로 실행 중인 세션은
`cc-orch --reload <project>` 또는 재실행이 필요합니다. `./install.sh`로 설치한 뒤
`./install.sh --check`로 설치된 runtime을 확인하십시오.

## 아카이브 (orch-archive)

`orch-archive`는 cc-orch 세션, 진행 중인 작업과 중첩된 과거 복사본을 포함한 작업 디렉터리,
레지스트리, 연결된 Claude transcript 및 작업에서 참조한 Codex rollout을 보관한다.
cc-orch 연결이 없는 native Codex rollout은 개수와 용량만 보고한다. 생성되는 구조는 영어이며
한국어 레지스트리 셀을 포함한 과거 원문은 번역 없이 그대로 보존한다.

비공개 로컬 git vault 기본 경로는 `~/orchestra-vault`이다. 무손실 압축 원본 로그는 git 밖의
`~/.claude/orchestra-archive/raw`에 저장한다(디렉터리 0700, 파일 0600).
원본은 수정·이동·삭제하지 않는다. 실행 중 로그는 byte-offset watermark로 완성된 줄을
복사하고 줄바꿈 없는 꼬리도 별도로 보존한다. 스냅샷은 불변이며 누적 catalog는 원본
checkout이 삭제된 작업도 유지한다.

```bash
orch-archive                       # 읽기 전용 계획; 파일 생성 없음
orch-archive plan --json --top 20
orch-archive plan --json --measure-thumbnails   # thumbnail을 메모리에서 인코딩해 측정; 파일은 쓰지 않음
orch-archive apply                 # 로컬 저장 및 vault 변경 commit
orch-archive apply --no-commit
orch-archive import --host render --source-vault /copies/render-vault --source-raw /copies/render-raw
orch-archive verify
orch-archive show cc-orchestra--38-orch-archive
```

`archive-policy.conf`에서 저장 경로, 탐색 기반 디렉터리, 포함 여부, 크기 한도를 설정한다.
`ORCH_ARCHIVE_POLICY`로 override 정책을 선택한다. 경로 환경 변수는
`ORCH_ARCHIVE_VAULT`, `ORCH_ARCHIVE_RAW`, `ORCH_ARCHIVE_ALLOWLIST`,
`ORCH_ARCHIVE_STATE_DIRS`, `ORCH_ARCHIVE_CLAUDE_PROJECTS`, `ORCH_ARCHIVE_CODEX_HOME`
(다음 순위 `CODEX_HOME`), `ORCH_ARCHIVE_EXTRA_BASES`이다. 정책을 shell로 실행하지 않는다.
vault/raw 경로의 겹침과 원본 루트 내부의 저장 경로는 거부한다.

모든 텍스트 파일은 raw 저장소에 복사한다. 비텍스트 payload 기본 한도는 파일당 16 MiB,
작업당 합계 256 MiB이다. 작업 한도 초과 시 해당 스냅샷의 모든 payload를 manifest에만
기록한다. apply 전에 `PAYLOAD_FILE_MAX_BYTES`와 `PAYLOAD_TASK_MAX_BYTES`를 변경할 수 있다
(`0`은 무제한). `INCLUDE_PAYLOAD=0`으로 payload 복사를 끌 수 있다. 제외 파일은 크기와
사유를 모두 기록하며 계획 보고서에는 압축 전후 용량과 artifacts, notes,
catalog, other별 vault 용량을 표시한다. 생성한 작업·루트 manifest는 raw 저장소의
결정적인 gzip blob에만 저장하며 `raw.manifests`로 집계한다. 작업·프로젝트 노트는
blob 경로, 압축 전 SHA-256과 길이를 참조하고 catalog 스냅샷에는 개수와 manifest
포인터를 기록한다. `verify`는 포인터와 manifest JSON을 검증한다. artifact는 쓰기 시 검증한 raw blob에서
복원하므로 계획에는 길이와 포인터만 유지한다.

checkpoint 파일은 복사하거나 내용 해시를 계산하지 않는다. `CHECKPOINT_EXTENSIONS` 기본값은
`.pt .pth .ckpt .safetensors .onnx .engine .trt .h5 .npz .npy`이며 대소문자를 구분하지 않는다
(빈 값이면 이 분류를 끈다). 작업 노트에는 경로·크기·UTC mtime만 기록하며 보고서에는
개수·용량·상위 작업을 표시한다. checkpoint는 payload 한도 합계에서 제외한다.

PNG 파일은 원본이 아니라 작은 JPEG thumbnail로 보관한다. `IMAGE_EXTENSIONS` 기본값은
`.png`이다(`.png`만 지원하며, 비우면 이미지 처리를 끄고 PNG는 위의 payload 한도를 따른다).
원본 PNG 바이트는 vault와 raw 저장소 어디에도 복사하지 않는다. 이미지마다 baseline JPEG
thumbnail 하나만 `artifacts/tasks/<task>/thumbs/`(루트는
`artifacts/roots/<project>/<hash>/thumbs/`)에 저장하며, 원본 내용 해시를 키로 쓰므로 내용이 같은
이미지는 파일 하나를 공유한다. alpha는 흰색 위에 합성하고 EXIF, ICC, text 메타데이터는
버린다. 인코더는 실행 시점에 탐지한다. importable하면 Pillow(필요할 때만 import), 없으면
`ffmpeg`, 둘 다 없으면 인코더 없음이다. `THUMB_ENCODER=auto|pillow|ffmpeg|none`으로 강제할
수 있다. 인코더가 없으면 해당 이미지는 metadata만 기록하고(`no-encoder`) 보고서에
`no image encoder`를 한 번 표시한다. 기본값: 긴 변 `THUMB_MAX_EDGE=512` px,
`THUMB_QUALITY=70`, thumbnail당 `THUMB_MAX_BYTES=65536`, `THUMB_MAX_PIXELS=100000000`
(초과하면 디코딩하지 않고 metadata만 기록, `over-pixel-cap`), 작업 노트의 Obsidian embed
`THUMB_EMBED_MAX=8`개, 작업당 thumbnail은 `THUMB_MAX_PER_TASK=48`개(0이면 생성하지 않음).
바이트 한도를 넘으면 품질을 낮추고 그다음 크기를 줄여 다시 시도하며
모두 실패하면 metadata만 기록한다(`thumbnail-over-cap`). `.png` 파일은 먼저 구조 검사(시그니처,
IHDR, chunk CRC, IEND까지의 chunk)를 거친다. 통과하지 못한 파일(`not-png`, `bad-header`,
`bad-chunk-crc`, `truncated`)은 원본 오류(`invalid-image`, 종료 코드 **4**)로 기록하고 실행은
계속한다. 구조는 정상이지만 디코딩할 수 없는 픽셀 데이터도 마찬가지다(`decode-failed`, metadata만
기록). 작업 노트와 catalog에는 표본으로 선택한 이미지마다 상대 경로, 크기, UTC mtime, 원본 SHA-256, 픽셀
크기, thumbnail 경로·바이트 수·픽셀 크기, 인코더 id와 버전, 사용한 파라미터를 기록한다. SHA-256과
전체 chunk CRC 검사는 `PAYLOAD_FILE_MAX_BYTES` 이내의 원본에만 수행하며, 더 큰 원본은 seek만
하는 chunk 순회로 검증하고 해시를 남기지 않는다. 각 작업은 정렬한 PNG 목록에서 균등 간격으로
최대 `THUMB_MAX_PER_TASK`(48)개를 선택해 thumbnail을 만든다(표본이 두 개 이상이면 처음과
마지막을 포함하며, 한 개이면 첫 이미지만 선택). 나머지는 metadata만 기록하며(`not-sampled`),
노트에는 폴더별 요약을, raw 저장소의 manifest에는 파일별 정보를 남긴다. 모든 PNG를 검증하며,
선택한 파일이 잘못되었어도 다른 이미지로 표본을 채우지 않는다. PNG가 n개이면 예산은 원본 크기가
아니라 `min(n, THUMB_MAX_PER_TASK) × THUMB_MAX_BYTES`를 예약한다. 표본 선택과 예산 예약은
각 작업 위치와 루트 스캔에 따로 적용하며, 한 번에 이미지 하나만 메모리에 디코딩한다.

thumbnail의 멱등성은 한 머신 안에서만 보장한다. 원본(해시·크기·mtime), 인코더 id/버전,
파라미터 중 하나가 바뀔 때만 다시 인코딩한다. JPEG 출력은 인코더와 Pillow 버전마다 다르므로
도구가 바뀌면 다시 인코딩해 vault의 해당 thumbnail을 덮어쓴다(이력은 git에 남는다). `plan`은
인코딩하지 않고 이런 이미지를 `pending`으로 보고하며, `plan --measure-thumbnails`는 메모리에서
인코딩하고(파일은 쓰지 않음) 출력 보고서에만 `images_measurement`(인코딩/재사용 개수, 인코딩
시간, 전체 시간, 최대 RSS)를 추가한다. 저장 파일에는 넣지 않는다.

읽을 수 없거나 사라진 원본은 실행을 중단하지 않고 건너뛴다. `source_errors`는 정확한
개수와 보호된 경로·사유·errno의 제한된 목록을 보고한다(`--top`으로 목록 크기 설정).
원본 오류가 하나라도 있으면 plan과 apply는 종료 코드 **4**를 반환한다. apply는 성공한
원본을 저장하고 commit한다. 접근 권한이나 사라진 원본을 복구한 뒤 다시 실행한다.
오류 없이 성공하면 종료 코드 0이며 기존 사용법·정책, verify, lock-busy 상태는 유지한다.

기존 advisory secret scanner로 vault에 들어가는 모든 텍스트를 검사한다. 오탐과 누락이
가능하다. 보류된 내용은 비공개 raw 저장소에 남는다. `_meta/withheld.md`는 해시와 위치만
기록하며 탐지된 원문을 표시하지 않는다. 해제하려면 보고서의 전체 해시를
`sha256:<해시>` 형식으로 `~/.claude/orchestra-archive/allowlist.txt`(또는 설정한 경로)에
추가하고 apply를 다시 실행한다. raw 로그는 무손실 보존되며 검사하지 않는다.
전체 텍스트 backstop은 해제한 값의 원문과 JSON-escaped metadata를 허용하며,
그 외 secret-shaped 줄은 거부한다.
네트워크·모델 호출, remote 설정, push는 하지 않는다.

관리 파일 `.obsidian/graph.json`은 apply마다 재생성하며 artifacts, metadata, dashboard를
graph에서 제외한다. frontmatter와 `.base`는 Python 표준 라이브러리로 검증 가능한
JSON-compatible YAML flow 형식이다. Obsidian 렌더링은 시각적으로 검증하지 않았다.
Bases에는 Obsidian >= 1.9.0이 필요하다.

### 다른 호스트의 아카이브 가져오기

먼저 `apply`로 로컬 catalog를 만든 뒤 다른 호스트의 vault와 raw 저장소의 읽기 전용
복사본을 `import`에 지정한다. 두 원본 디렉터리는 서로 겹치거나 로컬 저장 경로와
겹칠 수 없다. 호스트 이름은 소문자·숫자와 구간 사이의 단일 하이픈으로 이루어진
1–32자이다(`[a-z0-9]+(?:-[a-z0-9]+)*`). `local`은 예약어이다.

프로젝트·작업·세션의 id, 경로, 링크에는 `<host>--` 접두사를 붙이며 frontmatter의
`host`와 `host/<host>` 태그도 추가한다. 모델 id는 유지하고 모든 호스트의 작업을
모아서 표시한다. `_meta/hosts/<host>.md`에는 원본 수량, catalog 해시, 로컬 정책으로
보류한 항목을 기록한다. 입력 blob의 gzip 무결성과 압축 전 SHA-256을 검증하고 새
blob만 결정적으로 재압축한다. 기존 blob은 다시 쓰지 않는다. 원본 이력은
`sources/<host>/`에 저장하므로 호스트별 inode/device watermark가 섞이지 않는다.

기존 로컬 파일과 catalog 레코드는 유지한다. 모델 노트, index, dashboard, graph 설정과
catalog 등 공유 페이지는 기존 내용을 포함하는 상위 집합으로만 다시 생성한다.
가져온 텍스트는 로컬 allow-list로 다시 판단한다. 보류 텍스트는 placeholder로 바꾸거나
artifact 복사를 생략하고, 원본 raw 내용은 raw 저장소에 유지한다. `--dry-run --json`은
디렉터리·잠금·파일을 만들지 않고 추가 항목과 충돌을 보고한다. `--top N`은 보고서의
표본 수를 제한하고 `--no-commit`은 vault commit을 생략한다. 변경 없는 재실행은 내용과
commit을 추가하지 않는다. 호스트를 가져오는 순서가 달라도 vault/raw 바이트는 같다.
이후 로컬 `apply`도 가져온 레코드를 동결 상태로 보존한다.

종료 코드: `0` 성공, `4` 구조 오류로 거부(아카이브 내용은 쓰지 않음) 또는 로컬 정책에
따른 보류(안전한 결과는 저장), `2` 사용법·정책 오류, `3` 잠금 사용 중, `1` 최종 secret
검사 실패이다. 구조 오류는 내용을 쓰기 전에 보고하며, dry-run이 아닌 경우 raw 잠금
파일은 만들어질 수 있다.

현재 제한:

- 연쇄 import는 거부한다. 입력은 단일 호스트의 version-1 catalog여야 한다.
- 같은 호스트는 원본이 그대로일 때만 다시 가져올 수 있다. 기존 파일·레코드를 바꿀
  변경은 거부한다. 명시적인 refresh 모드가 생기기 전에는 새 호스트 이름을 사용한다.
- 입력 vault/raw는 노트 링크와 원본 이력을 포함한 `verify`를 통과해야 한다.
- 현재 root manifest에 없는 과거 root artifact는 manifest 해시 검증 없이 복사하며
  `artifacts_unverified`로 집계한다.
- 쓰는 도중 중단되면 일부만 저장될 수 있다. 재실행할 수 있지만 파일 전체를 아우르는
  transaction은 없다.
- import 이후 `show`의 짧은 작업 이름이 모호해질 수 있다. 전체 `<host>--…` id를 쓴다.
- 가져온 노트는 이 호스트의 thumbnail/embed 정책으로 렌더링한다.
- 로컬에서 발견한 프로젝트·세션 id가 가져온 id와 같으면 `apply`가 중단된다.

### 남은 제한 사항 (재검증 안 됨)

- 보류된 세션 conf 값에는 raw 백업이 없다. 세션 conf, named-launch record 또는
  `project.json`의 secret-shaped 값은 vault catalog에서 가려지며 원본 파일 자체는
  raw 저장소에 복사하지 않는다. 원본이 삭제되면 값을 복구할 수 없고, 나중에
  allow-list에 추가해도 복원되지 않는다(`lib/orch_archive.py`, `Archive.build` 세션 루프;
  최종 리뷰 지적 사항).
- secret-shaped 파일명의 payload 한도 수정은 마지막 gate 이후 반영되었으며
  gate 검증을 받지 않았다(`lib/orch_archive.py`, `Archive.scan_files`).
- indexed PNG의 PLTE 필수 검사는 마지막 gate 이후 반영되었으며 gate 검증을 받지 않았다
  (`lib/orch_archive.py`, `png_info`).
- `.orchestra/wt`와 `.orchestra/archive` 컨테이너는 전체를 건너뛰고 합계 용량을 보고한다.
  내부의 중첩된 `.orchestra` 루트만 보관하므로 `archive/<x>/handoff/` 같은 개별 파일은
  복사하지 않는다.
- Codex-only 설치(`install_codex_only`)는 `orch-archive` 링크를 만들지 않는다.
- Obsidian 렌더링(graph 색상과 Bases dashboard)은 시각적으로 확인하지 않았다.
- 한 번 기록한 thumbnail은 다른 artifact처럼 vault의 git 이력에 남는다. 인코더나 파라미터를
  바꾸면 새 버전이 추가되며 이전 버전은 정리하지 않는다.
- 파일별 `sampled: false` 플래그는 변경 불가능한 snapshot manifest에 기록된다. 나중에
  `THUMB_MAX_PER_TASK`를 바꾸면 catalog, 노트와 폴더별 요약은 갱신되지만, 해당 snapshot에
  이미 작성된 manifest의 플래그는 바뀌지 않는다.
- `--measure-thumbnails` 없는 `plan`은 픽셀 데이터 손상을 감지할 수 없다(`pending`으로 보고).
  `apply`와 측정 plan만 디코딩한다. `PAYLOAD_FILE_MAX_BYTES`를 넘는 원본은 인코딩 전에
  chunk CRC 검사와 해시가 없다.
- tRNS 키가 있는 16비트 RGB PNG는 Pillow가 8비트로 디코딩하므로 키의 상위 바이트로 일치를
  판정한다. 키와 하위 바이트만 다른 샘플도 흰색이 될 수 있다. 16비트 gray 키는 정확히 일치시킨다.
- PNG만 지원한다. `.bmp`, `.tif` 등 다른 래스터 형식은 payload 한도를 따른다.
- Pillow 9.0.1 호환은 (신규 전용 호출을 쓰지 않는) 구조로 확보했으며 실행해 보지는 않았다.
  thumbnail의 Obsidian embed 렌더링도 시각적으로 확인하지 않았다.

## 설정 튜닝

`model-policy.conf`는 고정 role/profile의 model/effort 기본값,
`budget-policy.conf`는 pressure별 Claude profile, Codex model/effort, provider 선택을 정의합니다.

라우팅 정책을 조정하려면 `budget-policy.conf`를 수정합니다.

이 파일은 `orch-policy-rev` 계산에서 제외되어 있으므로, quota threshold나 모델 배분표를 조정하는 것만으로 prompt cache가 무효화되지는 않습니다.

주요 설정값은 다음과 같습니다.

```text
BUDGET_WATCH_RATIO
BUDGET_TIGHT_RATIO
BUDGET_CRITICAL_RATIO
BUDGET_NEAR_RESET_MINUTES
BUDGET_PROVIDER_SWITCH_MARGIN
BUDGET_CODEX_SPARING_MIN_RANK
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

`orch-model-guard status`는 legacy Fable guard와 runtime budget을 함께 보여 줍니다.
`budget`은 reset/pressure/headroom, `lanes`는 provider 결정과 이유를 표시합니다.
다음 dispatch의 lead profile/model/effort 또는 Codex model/effort/allow를 미리 확인하려면:

```bash
orch-model-guard route lead normal alpha
orch-model-guard route codex implement
```

## 회귀 검사

```bash
bash tests/test-policy.sh
bash tests/test-runtime.sh
bash tests/test-tier1-runtime.sh
bash tests/test-notice-runtime.sh
```

Model-policy profile, reset-aware pressure, Claude/Codex routing, Fast 호환성, provider reserve,
Tier 1 normal=Sonnet, stale-policy notice 오탐, tmux/worktree lifecycle, status-line 보존,
runtime hook JSON contract를 검사합니다.

### Codex 추정 비용 (orch-usage-report --cost)

`orch-usage-report --days 7 --cost`는 공개 API 요금 기준 추정치이며 계정에서 차감된 금액이 아닙니다.
호출은 ChatGPT 플랜 quota를 사용하므로 달러 금액은 상대적 부하를 비교하는 지표입니다.
요금, 적용일, 출처 URL은 `pricing-policy.conf`에 기록하며 `CC_ORCH_PRICING_POLICY`로 경로를 바꿉니다. 이 정책은 라우팅에 영향을 주지 않습니다.
Astra 가정 비용은 관측된 토큰 수를 그대로 재계산합니다. 실제 Astra의 토큰 수는 달라집니다.
unpriced는 남아 있는 토큰 데이터가 없는 호출이며, coverage는 기간 내 전체 호출 중 토큰과 유효한 요금이 있는 호출의 비율입니다.
Fast 배수는 기본적으로 미상이라 Standard 요금으로 추정하며, 요청별 긴 컨텍스트 할증은 적용하지 않습니다.
이벤트 파일 mtime과 wrapper 로그 순서로 연결합니다. 같은 root의 동일 mode 호출 구간이 교차하고 두 완료 사이에 다른 wrapper 호출이 시작되지 않으면 서로 뒤바뀔 수 있습니다.
작업 디렉터리를 복사하거나 touch하여 mtime이 바뀌면 과거 토큰이 더 최근 호출에 연결될 수 있습니다.
토큰과 호출의 연결은 추정입니다. `codex.log`에는 이벤트 파일 또는 실행 식별자가 없습니다.
`codex-run`은 이벤트 파일을 `codex.log` 행보다 먼저 쓰므로, 그 사이 다른 호출이 로그에 행을 추가하면 완료 중인 호출이 다른 호출의 모델 요금으로 계산될 수 있습니다.
정확한 연결에는 `codex-run` 로그 변경이 필요하며 이는 보류합니다. `orch-jev`는 전체 행에 대한 정규식으로 로그 행을 파싱합니다.
