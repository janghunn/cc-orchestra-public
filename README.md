# cc-orchestra

Claude Code를 제어 계층으로, Codex를 조사·구현·검증의 기본 실행 계층으로 사용하는
4-tier 오케스트레이션 하네스다. 목표는 Claude 사용량, 특히 Fable 소비를 줄이면서도
최종 설계 책임과 독립 검증을 분명하게 유지하는 것이다.

```text
사용자
  │
  ▼
orchestrator             Sonnet @ high       의도·범위·분해·배정·보고
  └─ codex-run intake    Terra @ high        brief 전 코드/테스트 지도 작성
  │
  ▼
lead-<slot>              Opus @ high         일반 작업의 최종 설계·계획·diff 책임자
  ├─ light               Sonnet @ medium     문서·설정 등 저위험
  ├─ critical            Fable @ high        보안·핵심 알고리즘·고위험
  └─ critical-xhigh      Fable @ xhigh       명시적으로 깊은 추론이 필요한 고위험
  │
  ├─ 조사
  │   └─ Codex Sol @ high
  ├─ 구현
  │   ├─ Codex Sol @ xhigh                  기본
  │   ├─ Codex Luna @ medium                기계적 변경
  │   ├─ Claude Sonnet dev-* @ high         명시적 예외
  │   └─ Claude Opus dev-opus-* @ high      Codex 반복 실패 후 fresh eyes
  └─ 검증
      ├─ Codex Terra verify @ high           실행 검증
      ├─ Codex Sol review @ high             의미·회귀 리뷰
      └─ Claude Opus verifier @ max          critical에 추가
```

일반 작업에서 전체 검토 후 설계와 계획을 최종 결정하는 모델은 **Tier 2의 Opus@high lead**다.
Codex intake/investigate/plan-review는 근거를 수집하거나 반론을 제시하지만 설계를 확정하지 않는다.
orchestrator도 구현 설계를 하지 않고 사용자 의도, 범위, 인수 조건과 위험도만 결정한다.

## 정책 요약

모델·effort의 단일 소스는 `model-policy.conf`다.

| 역할/프로필 | 모델 | effort | 용도 |
|---|---|---:|---|
| orchestrator normal | `sonnet[1m]` | high | 대화, 분해, 라우팅 |
| lead light | `sonnet[1m]` | medium | 저위험 문서·설정 |
| lead normal | `opus[1m]` | high | 일반 설계·계획·리뷰 |
| lead critical | `fable[1m]` | high | 보안, 데이터 손실, 핵심 알고리즘 |
| lead critical-xhigh | `fable[1m]` | xhigh | 사용자가 요청했거나 복수 설계의 고위험 결정 |
| Claude dev | `sonnet[1m]` | high | Codex 장애, 1M context, 정밀 조향, GPU, sparing |
| Claude fresh-eyes dev | `opus[1m]` | high | Codex가 같은 유닛에서 두 번 실패한 뒤 |
| normal fallback verifier | `sonnet[1m]` | high | Codex verify 장애 시 |
| critical verifier | `opus[1m]` | max | critical의 추가 독립 검증 |

Codex 정책:

| 모드 | 모델 | effort |
|---|---|---:|
| `intake` | `gpt-5.6-terra` | high |
| `investigate` | `gpt-5.6-sol` | high |
| `implement` | `gpt-5.6-sol` | xhigh |
| `implement --mech` | `gpt-5.6-luna` | medium |
| `review`, `plan-review` | `gpt-5.6-sol` | high |
| `verify` | `gpt-5.6-terra` | high |
| review/verify `--critical` | 해당 기본 모델 | xhigh |
| failed implementation `--escalate` | 해당 모델 | max |

`--fast-mode`는 선택된 Sol/Terra와 effort를 그대로 유지하면서 해당 호출만 공식 Fast service
tier로 실행한다. 공식 안내 기준으로 지원 모델의 처리 속도는 약 1.5배지만 크레딧은 Standard의
2.5배이므로 지연 시간이 중요한 `codex-first` 호출에만 명시적으로 사용하고,
`codex-sparing`에서는 사용하지 않는다. 기존 `--fast`는 공식 Fast mode가 아니라 Luna@high로
모델을 낮추는 호환 옵션이다. ([OpenAI Fast mode 문서](https://learn.chatgpt.com/docs/agent-configuration/speed))

이 배분에서 Fable은 기본 세션이나 일반 lead에 쓰지 않는다. 일반 lead는 사용자가 요청한 대로
Opus를 유지하고, Fable은 critical/deep profile에서만 쓴다. 조사·일반 리뷰는 xhigh에서 high로
낮춰 Claude와 Codex 양쪽의 불필요한 추론 소비를 줄였다.

## Codex-first 규칙

`orch-model-guard lanes`는 두 상태만 반환한다.

| 상태 | 조건 | 구현 | 조사 | 검증 |
|---|---|---|---|---|
| `codex-first` | 기본, Codex 주간 사용량 < 90% 또는 unknown | Codex 최대 2개 병렬, 나머지는 직렬화 | Codex | Codex verify + review |
| `codex-sparing` | Codex 주간 사용량 ≥ 90% | Sonnet dev 예외 허용 | lead/Explore 폴백 | Sonnet verifier + Luna review |

속도를 위해 세 번째 구현 유닛을 Claude로 넘기는 `balanced` 상태는 없다. Codex에 여유가 있으면
직렬화해서라도 Codex가 구현하고, Claude dev를 썼다면 `summary.md`의 `LANES:`에 아래 예외 중
하나를 기록해야 한다.

- `fallback`: Codex quota/auth/timeout
- `context`: Codex context보다 큰 작업
- `steering`: 턴 단위 정밀 조향이 필수
- `gpu`: Codex sandbox가 필요한 장치/런타임을 사용할 수 없음
- `fresh-eyes`: Codex가 같은 유닛에서 두 번 실패
- `sparing`: `dispatch=codex-sparing`

`orch-summary-check --strict`는 사유 없는 Claude dev 사용을 PASS로 인정하지 않는다.

## 설치

```bash
git clone https://github.com/janghunn/cc-orchestra.git ~/cc-orchestra
cd ~/cc-orchestra
./install.sh
./install.sh --check
```

설치되는 항목:

- `~/.claude/orchestra` → 저장소 심링크
- `~/.claude/agents/orchestrator.md`, `verifier.md`, `verifier-normal.md`
- lead 16개 profile: 4 slots × light/normal/critical/critical-xhigh
- dev 6개 profile: Sonnet 3개 + Opus fresh-eyes 3개
- `~/.local/bin/{cc-orch,codex-run,orch-model-guard,orch-summary-check,orch-usage-report}`
- Fable quota를 5분마다 확인하는 user systemd timer와 stale-policy 안내 hook

Codex lane은 Codex CLI와 `codex login`을 요구한다. 사용할 수 없으면 명시적인 Claude fallback을
기록하며 진행한다.

## 실행과 profile 선택

```bash
cc-orch dsv ~/projects/dsv
cc-orch --no-rc dsv ~/projects/dsv
cc-orch --profile critical dsv ~/projects/dsv
cc-orch --profile deep dsv ~/projects/dsv
cc-orch --model opus[1m] --effort high dsv ~/projects/dsv
```

기본 `normal` 오케스트레이터는 Sonnet@high다. 특정 작업의 위험도는 오케스트레이터 전체 모델을
올리는 대신 해당 lead profile만 선택한다.

## 실행 중 세션에 정책 반영

Claude Code는 세션 모델·effort와 agent 정의를 프로세스 시작 시 캐시한다. 파일을 고치거나
`/model`만 실행해서는 이후 생성되는 lead의 prompt/model/effort까지 바뀌지 않는다.

안전한 전체 재적용:

```bash
cc-orch --reload dsv
```

`--reload`는 다음 순서로 동작한다.

1. `orchestrator@dsv` 프로세스와 실제 작업 디렉터리를 찾는다.
2. `.orchestra/REGISTRY.md`에 실행 중인 lead가 있으면 재시작을 거부한다.
3. 기존 프로세스에 TERM을 보내고 최대 10초 기다린다. SIGKILL은 보내지 않는다.
4. 기존 project profile과 디렉터리를 보존하고 `-c`로 대화를 이어 새 프로세스를 시작한다.
5. 새 프로세스가 최신 roster, prompt, model, effort를 다시 읽는다.

실행 중 lead의 상태가 디스크에 안전하게 남았음을 직접 확인한 경우에만
`cc-orch --force-reload dsv`를 쓴다. 현재 프로세스를 찾을 수 없고 저장된 project map도 없다면
`cc-orch --reload dsv /absolute/project/path`처럼 경로를 함께 준다.

policy hash가 바뀌었거나 모델/effort가 현재 profile과 다르면 prompt-submit hook도
`cc-orch --reload <project>`를 안내한다.

## Fable quota fallback

```bash
orch-model-guard status
orch-model-guard check
orch-model-guard set fallback
orch-model-guard set primary
orch-model-guard set auto
```

가드는 `claude -p /usage`의 `Current week (Fable)`을 읽는다. 모델 호출 없이 확인하며 기본
임계값은 다음과 같다.

- Fable 사용량 `>= 98%`: fallback 활성화
- Fable 사용량 `<= 90%`: role별 primary profile 복원
- 90~98%: 현재 상태 유지

fallback이 활성화되면 **모든 control profile을 Opus로 바꾼다**.

- normal/critical/deep을 포함한 새 orchestrator launch → Opus
- light/normal/critical/critical-xhigh lead profile → 전부 Opus
- effort는 profile별 값을 유지
- 이미 실행 중인 세션 → `cc-orch --reload <project>` 필요

복원 시에는 light=Sonnet, normal=Opus, critical/deep=Fable로 돌아간다. dev/verifier에는 원래
Fable이 없으므로 Fable fallback 대상이 아니다.

## 작업 흐름과 산출물

작업별 디렉터리는 `<repo>/.orchestra/<NN>-<slug>/`다.

| 파일 | 작성자 | 내용 |
|---|---|---|
| `brief.md` | orchestrator | 목표, 범위, 인수 조건, 검증, RISK |
| `codex-intake.md` | Codex | brief 전 owning file/test/risk 지도 |
| `plan.md` | lead | 조사 결과와 최종 구현 설계 |
| `codex-investigation.md` | Codex | file:line 기반 조사 |
| `plan-review-codex.md` | Codex | critical/신규 경계의 설계 반론 |
| `impl-report-codex[-lane].md` | Codex | 구현·테스트 보고 |
| `impl-report-devN.md` | Claude dev | 예외 lane 구현·테스트 보고 |
| `review.md` | lead | 실제 diff에 대한 최종 review |
| `codex-verdict.md` | Codex | 제로 컨텍스트 실행 검증 |
| `codex-review.md` | Codex | 독립 의미·회귀 review |
| `verdict.md` | Claude verifier | fallback 또는 critical 추가 검증 |
| `summary.md` | lead | profile, promotion, lane, gate, 증거 요약 |

활성 컨텍스트 예산은 brief 12 KiB, plan 40 KiB, summary 20 KiB다. 긴 로그와 반복 라운드는
`evidence/` 또는 `rounds/`로 옮긴다.

```bash
orch-summary-check --strict <task-dir>
```

검사 항목은 artifact 크기, RISK/profile 일치, dispatch 값, Claude dev 예외 태그, gate 결과와
라운드 상한이다. low/normal은 기본 2회, critical은 3회다. 추가 라운드는 brief의
`EXTRA GATE ROUND: approved`가 있어야 한다.

## Codex 명령

모든 Codex 호출은 `codex-run`을 통한다.

```bash
codex-run intake      <workdir> <task-dir> "<goal>"
codex-run investigate <workdir> <task-dir> "<question>"
codex-run investigate <workdir> <task-dir> "<question>" --fast-mode
codex-run implement   <workdir> <task-dir>
codex-run implement   <workdir> <task-dir> --lane b
codex-run implement   <workdir> <task-dir> --mech
codex-run resume      <workdir> <task-dir> "<follow-up>" [--lane b]
codex-run plan-review <workdir> <task-dir> [--critical]
codex-run verify      <workdir> <task-dir> [--critical]
codex-run review      <workdir> <task-dir> --base <branch> [--critical]
codex-run status      <task-dir>
```

모델 호출 모드는 `--model`, `--effort`, `--fast`, `--fast-mode`, `--dry-run`을 지원한다.
`--fast-mode`는 Sol/Terra를 유지하며 호출별로 공식 Fast tier를 켜고 `--critical`과 함께 쓸 수
있다. Luna로 낮추는 `--fast`/`--mech` 또는 `--model luna`와는 함께 쓸 수 없다. `--critical`은
review/plan-review/verify에만 유효하고 기존 `--fast`와 동시에 쓸 수 없다. 구현은
workspace-write, intake/investigate/review/plan-review는 read-only sandbox다. verify는 테스트가
만드는 파일을 허용하기 위해 workspace-write지만 prompt가 product code 수정 전후 상태를 검사한다.

## Gate 정책

| 위험도 | 필수 gate |
|---|---|
| low/normal | Codex executable verify PASS + Codex review CLEAR/NONBLOCKING |
| critical | 위 두 gate를 `--critical`로 실행 + Opus@max verifier PASS |

Codex 장애 시 low/normal은 `verifier-normal`, critical은 기존 Opus verifier로 실행 검증을
대체하고 `GATES:`에 `unavailable`을 명시한다. low의 문서·순수 설정 변경만 구체적 이유와 함께
adversarial review를 waive할 수 있다. 실패한 gate가 있으면 수정 뒤 그 위험도의 전체 gate set을
다시 실행한다.

## 사용량 확인

```bash
orch-model-guard status      # 현재 profile/fallback과 Claude/Codex quota snapshot
orch-model-guard lanes       # dispatch 결정과 근거
orch-usage-report            # 최근 7일 로컬 workload
orch-usage-report --days 14
```

`orch-usage-report`의 Claude context 값은 cache-inclusive 로컬 workload이며 공급자 간 청구량을
직접 비교하는 수치는 아니다. Codex 표는 wrapper mode별 실행 횟수다. 정책 변경 전후에 동일한
기간과 작업 유형으로 비교하는 용도다.

## 슬롯과 Git 규율

사람이 쓰는 이름은 `lead-alpha`부터 `lead-delta`까지다. 실제 메시지 라우팅은 Agent 호출이
반환한 `agentId`를 `.orchestra/REGISTRY.md`에 기록해서 수행한다. profile suffix는 모델 선택용일
뿐 사람에게 보이는 슬롯과 registry identity는 바뀌지 않는다.

여러 lead를 동시에 쓰면 작업별 worktree, 하나만 쓰면 inplace가 기본이다. dev와 Codex lane은
commit/push를 하지 않고, lead만 명시적 pathspec으로 commit한다. `git add -A`, 강제 push,
`reset --hard`, 자동 merge/branch 삭제는 허용하지 않는다.

## 프롬프트 수정과 배포

`lead-*`, `dev-*`는 생성 파일이므로 template과 policy를 고친 뒤 roster를 다시 만든다.

```bash
vi templates/lead.md.tpl
vi templates/dev.md.tpl
vi model-policy.conf
./build-roster.sh
```

`agents/orchestrator.md`, `agents/verifier.md`, `agents/verifier-normal.md`는 직접 연결된다. 어떤
prompt/policy 변경도 실행 중 세션에는 캐시되어 있으므로 적용할 때 `cc-orch --reload <project>`를
사용한다.

다른 머신에는 다음으로 동기화한다.

```bash
./sync-to.sh server4
./sync-to.sh server4 --check
```

원격에서 실행 중인 세션도 해당 머신에서 `cc-orch --reload <project>`를 별도로 실행해야 한다.
