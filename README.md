# cc-orchestra

**Claude Code를 control plane으로, Codex CLI를 investigation / implementation / verification 실행 계층으로 사용하는 quota-aware multi-agent orchestration harness.**

cc-orchestra는 단순히 여러 모델을 번갈아 호출하는 wrapper가 아니다. 사용자 요청을 작업 단위로 분해하고, 각 작업에 설계 책임자를 두고, Claude와 Codex의 서로 다른 관점을 이용해 구현과 검증을 분리한다. 동시에 Claude Max와 ChatGPT Pro/Codex의 **현재 사용량과 리셋까지 남은 시간**을 함께 보면서 다음 작업에 사용할 모델과 effort를 동적으로 고른다.

서버 운영을 위해 `tmux`, Git worktree, Claude Code Remote Control도 하나의 workflow로 묶는다.

> 자세한 운영 절차는 [`OPERATIONS.ko.md`](OPERATIONS.ko.md), 영문판은 [`OPERATIONS.md`](OPERATIONS.md)를 참고한다.

---

## 주요 기능

- **4-tier Claude + Codex orchestration**
  - Tier 1 Sonnet orchestrator가 사용자 의도, 범위, 위험도, 작업 배정을 관리
  - Tier 2 Claude lead가 설계·계획·최종 diff 책임
  - Tier 3 Codex가 조사·구현을 기본 수행하고 Claude dev가 예외 fallback
  - Tier 4 Codex verify/review와 critical용 Claude verifier가 독립 검증 (`trivial`은 lead self-check만)
- **리셋 시각 기반 quota routing**
  - Claude 5시간 / 7일 window와 Codex 7일 window를 함께 추적
  - 단순 사용률이 아니라 `남은 quota ÷ 남은 시간`으로 소비 속도를 판단
  - `healthy / watch / tight / critical` 상태에 따라 모델과 effort 자동 조정
- **호출 경계별 동적 모델 선택**
  - Claude lead: Sonnet / Opus / Fable profile 선택
  - Codex: healthy 기본 Astra(폴백 Sol / Terra)와 effort를 호출마다 선택
  - 실행 중 agent는 강제로 바꾸지 않고 **다음 dispatch부터** 새 정책 적용
- **provider 간 자동 부하 분산**
  - 기본은 `codex-first`
  - Codex가 실제 reserve boundary에 들어갈 때만 `codex-sparing`
  - Claude가 critical이면 별도 Codex pool을 적극 사용
- **persistent tmux session**
  - SSH가 끊겨도 Claude Code 세션 유지
  - `attach`, `stop`, `restart`, `shell`, `remove` 지원
- **Git worktree 자동 관리**
  - 병렬 작업은 별도 branch + worktree로 격리
  - 기존 프로젝트에서 그대로 작업하려면 `--inplace`
- **Claude Code Remote Control 기본 활성화**
  - 터미널, 휴대폰, 다른 머신에서 동일 session 제어
- **immutable runtime lead roster**
  - 16개의 `route-lead-*` agent를 미리 생성
  - quota가 바뀔 때 파일을 다시 쓰지 않고 다음 task에서 적절한 profile 선택
- **구조적 정책 변경과 quota 변경을 분리**
  - quota/reset/`budget-policy.conf` 변경은 reload 불필요
  - prompt/template/agent 정의 변경만 reload 안내
- **검증 가능한 task artifact contract**
  - `brief.md`, `plan.md`, 구현 보고, Codex verdict/review, lead summary 등을 명시적으로 관리
  - `orch-summary-check --strict`로 gate와 artifact 규칙 검사

---

## 아키텍처

```text
User
 │
 ▼
Tier 1  orchestrator                              Claude Sonnet @ high
        intent / scope / decomposition / routing / status
 │
 ├─ Codex intake                                 healthy 기본 Astra (폴백 Terra), pressure에 따라 조정
 │
 ▼
Tier 2  route-lead-<slot>-<profile>               Claude
        final design / plan / diff owner          Sonnet | Opus | Fable
 │
 ├─ investigate ────────────────────────────────► Codex Astra (Sol 폴백)
 │
 ├─ implement ──────────────────────────────────► Codex Astra (Sol 폴백)
 │                                                 └─ Claude Sonnet dev-* exception
 │                                                 └─ Claude Opus fresh-eyes rescue
 │
 ├─ lead diff review                              Claude lead
 │
 ▼
Tier 4  executable verify ──────────────────────► Codex Astra (Terra 폴백)
        semantic/regression review ─────────────► Codex Astra (Sol 폴백)
        critical extra verifier ────────────────► Claude Opus @ max
        trivial: Tier 4 생략 ─────────────────────► lead self-check only
```

### 역할 분리

**Tier 1 orchestrator**는 구현하지 않는다. 사용자의 요구를 task로 나누고, acceptance criteria와 risk를 정하고, 적절한 lead에 배정하고 결과를 보고한다.

**Tier 2 lead**는 해당 task의 최종 설계 책임자다. Codex 조사 결과를 근거로 활용하지만, 구현 방식과 plan을 최종 결정하는 것은 lead다.

모델·effort의 단일 소스는 `model-policy.conf`(고정 기본값·폴백)와
`budget-policy.conf`(quota 압력별 Codex 라우팅, healthy = Astra)다.

**Codex**는 Claude와 다른 provider family이므로 조사·구현뿐 아니라 verify/review에서도 독립적인 관점을 제공한다. 같은 family 안에서만 self-review하는 구조를 피하기 위한 핵심 장치다.

---

## 왜 Tier 1은 Sonnet인가

일반 `cc-orch`의 Tier 1 orchestrator는 **`sonnet[1m] @ high`**로 고정한다.

Tier 1의 일은 주로 다음과 같다.

- 사용자 의도 파악
- task 분해
- brief 작성
- lead slot 배정
- registry와 상태 추적
- 결과 보고

고비용 모델이 필요한 실제 설계·구현·review는 아래 tier에 배분한다. 따라서 legacy Fable guard가 `active=opus[1m]` 상태이더라도 **runtime-managed normal Tier 1은 Sonnet을 유지**한다.

실제로 실행 중인 Tier 1 모델은 다음으로 확인할 수 있다.

```bash
ps -eo pid,args | grep '[c]laude.*--agent orchestrator'
```

정상적인 normal session:

```text
--model sonnet[1m] --effort high
```

`orch-model-guard active`는 legacy compatibility state이므로 normal Tier 1의 실제 모델과 다를 수 있다.

---

# Quota-aware routing

## 핵심: 사용률만 보지 않고 리셋까지 남은 시간을 본다

cc-orchestra의 runtime router는 다음 값을 사용한다.

### Claude

```text
5시간 window 사용률
5시간 window reset 시각
7일 window 사용률
7일 window reset 시각
Fable 전용 주간 사용률
```

### Codex

```text
7일 window 사용률
7일 window reset 시각
```

단순히 `90% 사용`만으로 위험하다고 판단하지 않는다.

```text
90% 사용 + 5분 뒤 reset   → 아직 충분히 쓸 수 있음
90% 사용 + 6일 뒤 reset   → 사용 속도를 크게 낮춰야 함
```

이를 위해 **headroom ratio**를 계산한다.

```text
headroom ratio = 남은 quota 비율 / 리셋까지 남은 시간 비율
```

예를 들어 전체 window의 절반이 남았는데 quota도 절반 남았다면:

```text
remaining quota = 0.5
remaining time  = 0.5
headroom        = 1.0
```

즉 현재 소비 속도가 리셋 시점까지 정확히 맞는 수준이다.

### headroom 해석

```text
ratio > 1.0   현재 속도로 사용해도 여유가 큼
ratio = 1.0   reset 시점에 맞춰 quota를 소진하는 속도
ratio < 1.0   앞으로 사용 속도를 낮추는 것이 안전
```

---

## 현재 pressure 기준

현재 `budget-policy.conf`는 subscription을 지나치게 남기지 않도록 비교적 공격적인 정책을 사용한다.

```text
healthy   ratio >= 0.55
watch     0.30 <= ratio < 0.55
tight     0.10 <= ratio < 0.30
critical  ratio < 0.10
```

reset timestamp를 얻지 못한 경우에는 사용률 fallback을 사용한다.

```text
healthy   < 88%
watch     >= 88%
tight     >= 96%
critical  >= 99%
```

리셋까지 **10분 이하**가 남은 window는 이미 100%를 소진한 경우가 아니라면 `healthy`로 취급해, 리셋 직전 quota를 불필요하게 남기지 않는다.

### 예시 1: window의 50%가 남은 경우

```text
used <= 72.5%       healthy
72.5% ~ 85%         watch
85% ~ 95%           tight
> 95%               critical
```

### 예시 2: window의 10%만 남은 경우

```text
used <= 94.5%       healthy
94.5% ~ 97%         watch
97% ~ 99%           tight
> 99%               critical
```

즉 **같은 사용률도 reset에 가까워질수록 더 적극적으로 사용할 수 있다.**

---

## Claude pressure 결정

Claude는 5시간 window와 7일 window를 각각 평가한다.

```text
Claude 5h  ─┐
            ├─ 더 압박이 큰 상태 → CLAUDE_STATE
Claude 7d  ─┘
```

두 window 중 더 나쁜 상태가 전체 Claude pressure가 된다. 같은 rank라면 headroom이 더 낮은 쪽을 limiting window로 본다.

확인:

```bash
orch-model-guard budget
```

예:

```text
runtime budget policy (no cc-orch reload required for new dispatches)
claude  healthy (limiting: week)
  5h    used=42% headroom=...
  7d    used=92% headroom=...
codex   watch
  7d    used=...

dispatch=codex-first
```

---

# Claude 모델과 effort 선정

새 lead를 만들 때 risk와 현재 Claude pressure를 함께 사용한다.

## low risk

문서, 주석, 단순 설정처럼 저위험 작업은 quota 상태와 관계없이 가볍게 처리한다.

| Pressure | Model | Effort |
|---|---|---|
| healthy | Sonnet | medium |
| watch | Sonnet | medium |
| tight | Sonnet | medium |
| critical | Sonnet | medium |

`trivial` risk도 같은 표를 사용한다(Sonnet medium, `route lead low`). 차이는 모델이 아니라 gate 정책이다.

## normal task

| Pressure | Profile | Model | Effort |
|---|---|---|---|
| healthy | normal | Opus | high |
| watch | normal | Opus | high |
| tight | light | Sonnet | medium |
| critical | light | Sonnet | medium |

일반 작업은 Claude quota가 충분할 때 Opus가 설계·diff 책임을 맡고, 압박이 커지면 Sonnet으로 내려간다.

## critical task

| Pressure | Profile | Model | Effort |
|---|---|---|---|
| healthy | critical | Fable | high |
| watch | normal | Opus | high |
| tight | normal | Opus | high |
| critical | normal | Opus | high |

Fable은 critical task를 위한 reserve로 사용한다.

## critical + deep reasoning

| Pressure | Profile | Model | Effort |
|---|---|---|---|
| healthy | critical-xhigh | Fable | xhigh |
| watch | critical | Fable | high |
| tight | normal | Opus | high |
| critical | normal | Opus | high |

`deep`은 사용자가 명시적으로 요청했거나 보안·핵심 알고리즘처럼 여러 설계가 실제로 경쟁하는 경우에만 사용한다.

### Fable reserve 보호

`BUDGET_FABLE_RESERVE_PCT=85`가 기본값이다.

Fable 전용 사용률이 85% 이상이면 새 `critical` / `critical-xhigh` 선택을 Opus normal profile로 낮춰 Fable을 보존한다.

---

## immutable `route-lead-*`

Claude Code는 agent 정의를 process 시작 시 캐시한다. quota가 바뀔 때마다 `lead-alpha.md` 같은 파일을 다시 쓰면 실행 중 session이 새 모델을 보지 못한다.

이를 피하기 위해 설치 시 16개 profile을 미리 생성한다.

```text
route-lead-alpha-light
route-lead-alpha-normal
route-lead-alpha-critical
route-lead-alpha-critical-xhigh

route-lead-bravo-...
route-lead-charlie-...
route-lead-delta-...
```

새 task를 dispatch할 때:

```bash
orch-model-guard route lead normal alpha
orch-model-guard route lead critical bravo
orch-model-guard route lead critical deep charlie
```

처럼 **이미 캐시된 agent type 중 하나를 선택**한다.

따라서 사용량이 변해도 실행 중 Tier 1을 reload하지 않고 다음 lead부터 새 routing을 적용할 수 있다.

---

# Codex 모델과 effort 선정

Codex는 매 `codex-run` 호출마다 현재 weekly pressure를 다시 읽는다.

현재 자동 routing table:

| Mode | healthy | watch | tight | critical |
|---|---|---|---|---|
| `intake` | Astra high (폴백 Terra high) | Terra medium | Terra medium | Terra low |
| `investigate` | Astra high (폴백 Sol high) | Terra high | Terra medium | **withheld** |
| `implement` | Astra xhigh (폴백 Sol xhigh) | Sol high | Terra high | **withheld** |
| `review` | Astra high (폴백 Sol high) | Sol medium | Terra high | Terra medium |
| `plan-review` | Astra high (폴백 Sol high) | Sol medium | Terra high | Terra medium |
| `verify` | Astra high (폴백 Terra high) | Terra medium | Terra medium | Terra low |

healthy 상태에서는 Astra(`gpt-6-astra`)가 기본이며, `~/.codex/models_cache.json`의 live catalog로 계정/CLI별
가용성을 확인한다. 자동 라우팅 호출에서 Astra를 쓸 수 없으면 위 표의 폴백 모델로 내려가며
`CODEX-RUN: MODEL_FALLBACK`을 출력한다. 명시적으로 `--model astra`를 지정했는데 Astra를 쓸 수
없으면 대체하지 않고 `CODEX-RUN: MODEL_UNAVAILABLE`과 exit 6으로 종료한다.
`CC_ORCH_CODEX_CATALOG_CHECK=0`은 이 사전 catalog 검사를 끈다.

이 표에는 별도의 Luna `--mech`/`--fast` 행이 없으며, 해당 lane은 변경 없이 `templates/lead.md.tpl`의 lane 표에 문서화되어 있다.

### 왜 critical에서 implement/investigate를 멈추는가

Codex quota가 거의 소진된 경우 마지막 quota를 일반 구현에 모두 써버리지 않고 **cross-family review와 executable verification**에 남긴다.

```text
Codex critical
 │
 ├─ intake       유지
 ├─ investigate  자동 호출 보류 → Claude/Explore fallback 가능
 ├─ implement    자동 호출 보류 → Claude dev fallback 가능
 ├─ review       유지
 └─ verify       유지
```

### Fast mode

현재 자동 정책은:

```text
CODEX_ALWAYS_FAST_MODE=1
```

이다. 자동 routing으로 선택된 지원 Astra/Sol/Terra 호출에는 Codex CLI Fast mode를 사용한다.

명시적 옵션은 자동 정책보다 우선한다.

```bash
codex-run ... --model sol --effort xhigh
codex-run ... --critical
codex-run ... --fast-mode
codex-run ... --mech
codex-run ... --fast
```

`--mech`와 legacy `--fast`는 Luna 기반의 명시적 경량 경로다.

특정 호출에서 자동 model/effort routing을 끄려면:

```bash
CC_ORCH_AUTO_ROUTE=0 codex-run ...
```

shell 전체에서 끄려면:

```bash
export CC_ORCH_AUTO_ROUTE=0
```

`resume`은 기존 Codex thread의 context/model 연속성을 우선하므로 새 자동 model routing을 강제로 적용하지 않는다.

---

# Claude와 Codex 사이의 provider routing

`orch-model-guard lanes`는 두 provider의 pressure를 보고 다음 중 하나를 선택한다.

```text
dispatch=codex-first
dispatch=codex-sparing
```

## `codex-first`

기본 상태다.

```text
Claude orchestrator가 이미 control cost를 지불하고 있으므로
무거운 조사·구현·독립 검증은 별도 Codex quota를 적극 사용한다.
```

현재 정책은 Codex가 `healthy`, `watch`, `tight`인 동안 **codex-first를 유지**한다.

quota pressure가 증가하면 provider를 바로 바꾸는 대신 먼저 Codex 내부에서 model/effort를 낮춘다.

```text
Sol xhigh
  ↓
Sol high
  ↓
Terra high / medium
  ↓
critical reserve boundary
```

## `codex-sparing`

Codex가 `critical` reserve boundary에 들어가고 Claude보다 실제 headroom이 부족할 때 사용한다.

이 상태에서는 Codex를 일반 구현에 덜 쓰고 review/verify reserve를 보존한다.

두 provider가 모두 critical인 경우에도 Codex가 Claude보다 충분히 나쁜지 `BUDGET_PROVIDER_SWITCH_MARGIN`을 이용해 비교한다.

반대로 Claude가 critical이고 Codex가 critical이 아니라면:

```text
dispatch=codex-first
```

를 유지해 별도 Codex pool을 적극적으로 사용한다.

---

# tmux 기반 persistent managed session

서버에서 장시간 `cc-orch`를 실행한다면 managed session 사용을 권장한다.

```text
SSH terminal
   │
   ▼
cc-orch session
   │
   ├─ tmux persistent session
   ├─ Claude Code orchestrator
   ├─ Claude Remote Control
   └─ optional Git worktree
```

SSH 연결이 끊겨도 tmux와 Claude Code는 계속 실행된다.

## 기존 프로젝트 디렉터리를 그대로 사용할 때

```bash
cc-orch session new main ~/projects/dsv --project-name dsv --inplace
```

생성되는 구조:

```text
/home/user/projects/dsv
        │
        └─ tmux: ccorch-main
              │
              └─ cc-orch
                   └─ orchestrator@dsv-main
                        └─ Remote Control: orch-dsv-main
```

`--inplace`는 별도 worktree를 만들지 않고 기존 checkout에서 그대로 작업한다.

연구 코드, 대형 데이터 경로, conda/GPU 환경, 기존 build artifact에 의존하는 프로젝트에 특히 편하다.

## 별도 worktree를 사용할 때

Git repo에서 `--inplace`를 생략하면 worktree가 기본이다.

```bash
cc-orch session new auth-refactor ~/projects/api
```

기본적으로:

```text
repo
 ├─ original checkout
 │
 └─ branch: orch/auth-refactor
      │
      └─ ~/.claude/orchestra-state/worktrees/<project>/auth-refactor
            │
            └─ tmux: ccorch-auth-refactor
                  └─ cc-orch
```

기본 branch 이름:

```text
orch/<session-name>
```

기본 base는 현재 branch 또는 `HEAD`다.

직접 지정할 수도 있다.

```bash
cc-orch session new cache ~/projects/api \
  --branch orch/cache-v2 \
  --base develop
```

기존 branch를 worktree로 다시 붙이려면:

```bash
cc-orch session new cache ~/projects/api \
  --branch orch/cache-v2 \
  --reuse-branch
```

---

## managed session 명령

```bash
cc-orch session list
cc-orch session status main
cc-orch session attach main
cc-orch session shell main
cc-orch session stop main
cc-orch session restart main
cc-orch session remove main
cc-orch session path main
```

### attach

```bash
cc-orch session attach main
```

실행 중인 Claude tmux session에 다시 들어간다.

### tmux에서 빠져나오기

Claude를 종료하지 않고 terminal만 detach:

```text
Ctrl-b, d
```

### Claude 자체를 정상 종료

Claude Code 안에서:

```text
/exit
```

### 다시 이어서 실행

```bash
cc-orch session restart main
```

`restart`는 내부적으로 `-c`를 사용해 마지막 Claude conversation을 이어간다.

### stop

```bash
cc-orch session stop main
```

tmux session을 종료하지만 session registry, branch, worktree는 유지한다.

### remove

```bash
cc-orch session remove main
```

정지되어 있고 clean한 managed worktree와 registry를 제거한다. **작업 branch는 삭제하지 않는다.**

실행 중이거나 dirty한 worktree를 강제로 정리하려면:

```bash
cc-orch session remove main --force
```

---

## session state 위치

```text
~/.claude/orchestra-state/sessions/
~/.claude/orchestra-state/worktrees/
```

worktree root 변경:

```bash
export CC_ORCH_WORKTREE_ROOT=/fast-disk/cc-orch-worktrees
```

---

# Claude Code Remote Control

`cc-orch`는 기본적으로 Remote Control을 켠다.

```text
--remote-control orch-<project-name>
```

managed session의 경우 session name도 포함한 launcher name을 사용한다.

```text
orchestrator@dsv-main
Remote Control: orch-dsv-main
```

Remote Control이 필요 없으면:

```bash
cc-orch --no-rc dsv ~/projects/dsv
```

또는 managed session:

```bash
cc-orch session new main ~/projects/dsv --project-name dsv --inplace --no-rc
```

---

# 설치

## 신규 설치

```bash
git clone https://github.com/janghunn/cc-orchestra.git ~/cc-orchestra
cd ~/cc-orchestra

./install.sh
./install.sh --check
```

Codex lane을 사용하려면 Codex CLI가 로그인되어 있어야 한다.

```bash
codex login status
```

## 기존 설치 업그레이드

```bash
cd ~/cc-orchestra

git fetch origin
git switch main
git pull --ff-only

./install.sh
./install.sh --check
```

설치 후 repository가 clean인지 확인:

```bash
git status --short
```

정상이라면 출력이 없어야 한다.

## 설치되는 주요 항목

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
```

또한:

- Fable legacy guard timer
- Claude 5h/7d status-line quota tap
- live runtime routing `UserPromptSubmit` hook
- structural stale-policy notice hook

을 설치한다.

선택형 `PreToolUse` 수동 폴링 방지 hook은 `hooks/orch-poll-guard.sh`에 있으며 등록 방법은 `OPERATIONS.md`를 참고한다.

---

# 실행 예시

## 직접 실행

```bash
cc-orch dsv ~/projects/dsv
```

Remote Control 없이:

```bash
cc-orch --no-rc dsv ~/projects/dsv
```

critical Tier 1 session:

```bash
cc-orch --profile critical dsv ~/projects/dsv
```

deep critical Tier 1 session:

```bash
cc-orch --profile deep dsv ~/projects/dsv
```

명시적 model override:

```bash
cc-orch --model opus[1m] --effort high dsv ~/projects/dsv
```

대부분의 경우 전체 orchestrator를 critical/deep으로 올리기보다 normal Sonnet Tier 1을 유지하고 **개별 task risk를 통해 lead profile을 올리는 방식**을 권장한다.

---

# reload가 필요한 경우와 필요 없는 경우

## reload 없이 바로 반영

다음 항목은 runtime dispatch 때 다시 읽는다.

```text
Claude 5h 사용률/reset
Claude 7d 사용률/reset
Codex 7d 사용률/reset
budget-policy.conf threshold
Claude lead routing table
Codex model/effort table
provider codex-first / codex-sparing 결정
```

따라서:

```text
healthy → watch
watch → tight
reset 시각 변화
quota 사용량 증가
budget-policy.conf tuning
```

만으로 `cc-orch --reload`를 할 필요가 없다.

## 이미 실행 중인 agent는 유지

```text
running Tier 1       현재 model/context 유지
running lead         현재 model/context 유지
next lead            최신 Claude budget 적용
next codex-run       최신 Codex budget 적용
```

context handoff 비용 때문에 진행 중 agent를 quota 변화만으로 교체하지 않는다.

## reload가 필요한 구조적 변경

Claude Code가 process 시작 시 캐시하는 항목:

- `agents/*.md`
- `templates/*.tpl`
- structural `model-policy.conf`
- orchestrator / lead / verifier prompt

이런 변경 후에는:

```bash
cc-orch --reload <project>
```

을 사용한다.

`--reload`는 실행 중 lead가 있으면 기본적으로 거부한다.

managed session을 사용한다면 Claude를 `/exit`한 뒤:

```bash
cc-orch session restart main
```

으로 대화를 이어 재시작할 수도 있다.

---

# Runtime quota 데이터는 어디서 오는가

## Claude

Claude Code status line에 전달되는 구조화된 rate limit 값을 읽는다.

```text
rate_limits.five_hour.used_percentage
rate_limits.five_hour.resets_at
rate_limits.seven_day.used_percentage
rate_limits.seven_day.resets_at
```

기존 status line이 있었다면 cc-orchestra는 그 명령을 보존하고 chain한다.

## Codex

최신 rollout JSONL에서 읽는다.

```text
~/.codex/sessions/**/rollout-*.jsonl
```

사용 필드:

```text
rate_limits.primary.used_percent
rate_limits.primary.resets_at
```

quota 확인을 위해 별도의 Codex model request를 보내지 않는다.

---

# 주요 상태 확인 명령

```bash
orch-model-guard budget
```

리셋 시간을 포함한 Claude/Codex pressure와 headroom을 표시한다.

```bash
orch-model-guard lanes
```

`codex-first` / `codex-sparing`과 결정 이유를 표시한다.

```bash
orch-model-guard status
```

legacy Fable guard와 runtime budget 상태를 함께 확인한다.

```bash
orch-model-guard route lead normal alpha
```

지금 새 normal task를 배정한다면 어떤 Claude lead profile/model/effort가 선택되는지 확인한다.

```bash
orch-model-guard route codex implement
```

지금 implement를 시작한다면 Codex model/effort/allow가 어떻게 결정되는지 확인한다.

---

# Task workflow

일반적인 task 흐름:

```text
User request
   │
   ▼
Tier 1 Sonnet orchestrator
   │
   ├─ Codex intake
   ├─ brief.md
   │
   ▼
Runtime-selected Claude lead
   │
   ├─ investigate: Codex
   ├─ plan.md
   ├─ optional plan-review: Codex
   │
   ├─ implement: Codex default
   │      └─ Claude dev exception when justified
   │
   ├─ lead diff review
   │
   ├─ Codex executable verify
   ├─ Codex semantic/regression review
   ├─ critical: Claude Opus verifier
   └─ trivial: Codex verify/review 생략, lead self-check only
          │
          ▼
       summary.md
```

---

# 작업 산출물

작업별 디렉터리:

```text
<repo>/.orchestra/<NN>-<slug>/
```

| 파일 | 작성자 | 역할 |
|---|---|---|
| `brief.md` | orchestrator | 목표, 범위, acceptance, verification, risk |
| `codex-intake.md` | Codex | 구현 전 ownership/test/risk 지도 |
| `plan.md` | lead | 조사 결과와 최종 구현 설계 |
| `codex-investigation.md` | Codex | 조사 근거 |
| `plan-review-codex.md` | Codex | 독립 설계 cross-check |
| `impl-report-codex[-lane].md` | Codex | 구현·테스트 보고 |
| `impl-report-devN.md` | Claude dev | 예외 구현 보고 |
| `review.md` | lead | 실제 diff 최종 review |
| `codex-verdict.md` | Codex | executable verification |
| `codex-review.md` | Codex | 독립 semantic/regression review |
| `verdict.md` | Claude verifier | fallback / critical 추가 검증 |
| `summary.md` | lead | 최종 상태와 gate evidence |

active context budget:

```text
brief.md    12 KiB
plan.md     40 KiB
summary.md  20 KiB
```

긴 로그는 `evidence/`, 반복 라운드는 `rounds/`에 둔다.

---

# Gate 정책

| Risk | 필수 gate |
|---|---|
| trivial | 없음 — lead self-check only (`GATES: self-check only (trivial) — <확인한 내용>`) |
| low / normal | Codex verify PASS + Codex review CLEAR/NONBLOCKING |
| critical | 위 Codex gate + Claude Opus@max verifier PASS |

Codex가 unavailable이면 normal에는 `verifier-normal` Sonnet fallback, critical에는 Opus verifier fallback을 사용할 수 있지만 `summary.md`에 degraded gate 상태를 명확히 기록해야 한다.

`trivial`은 문서·주석·비분기 설정 변경이거나, 이미 구현된 코드·모델을 실행해 사용자가
직접 보고 판단할 산출물을 만드는 경우에만 사용한다. 후자의 경우에도 실행과 산출물 sanity
check는 생략하지 않는다. 새 로직을 작성하면 `trivial`이 아니다. Lead의 self-downgrade는
`low`→`trivial`만 허용하며, `plan.md`에 `RISK AMENDED: low -> trivial`을 쓰고 summary에
`BRIEF AUDIT: amended`를 기록해야 한다.
`brief.md`의 trivial 선언은 fenced code block 밖의 0열에 `RISK: trivial`로 써야 하며,
들여쓰기나 bullet을 쓰면 안 되고 brief 전체에서 `RISK:`로 시작하는 유일한 줄이어야 한다.
사유는 대시 뒤에만 쓸 수 있고 `plan.md`에는 `RISK AMENDED` 줄이 최대 하나만 있어야 한다.
또한 fenced code block 밖의 0열에서 선택적으로 대시 하나 뒤에 필드 마커로 시작하는 별도 선언형 줄에서 다른 tier를 선언한 경우에만 충돌하며, 일반 문장이나 fenced 예시의 언급은 충돌로 보지 않으며,
`GATES:` 설명에는 명령·파일·숫자를 나타내는 ASCII 영문자나 숫자가 하나 이상 있어야 한다.

implement→verify 실패 round 상한:

```text
trivial / low / normal   2회
critical                 3회
```

그 이상은 `brief.md`에:

```text
EXTRA GATE ROUND: approved
```

가 있어야 한다.

검사:

```bash
orch-summary-check --strict <task-dir>
```

---

# Codex 명령

모든 자동 Codex 실행은 `codex-run` facade를 통한다.

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

명시적 model/effort가 필요하면 `--model astra`, `--model <slug>`, `--effort`, `--fast-mode`
(선택된 Astra/Sol/Terra 모델·effort를 유지한 채 해당 호출만 공식 Fast tier로 실행), 레거시
`--fast`(Luna 다운그레이드), `--dry-run`을 지정한다:

```bash
codex-run ... --model sol --effort xhigh
```

---

# Git / worktree 원칙

- 여러 독립 task를 동시에 수행할 때는 worktree 격리를 권장한다.
- managed session의 worktree 기본 branch는 `orch/<session-name>`이다.
- `session remove`는 branch를 자동 삭제하지 않는다.
- 작업 branch는 사용자가 merge/abandon 결정을 내릴 때까지 안전하게 남긴다.
- Claude lead slot은 `lead-alpha` → `lead-delta`를 사용한다.
- 실제 agent routing은 `.orchestra/REGISTRY.md`의 `agentId`를 사용한다.

---

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
분리된 checkout에서도 공유 registry를 찾습니다. 명령 체인의 `cd`/`pushd`와 `git -C`를
추적해 각 Git 호출의 대상을 따로 평가합니다. `cd`/`pushd` 대상이 없거나 디렉터리가
아니면 Bash의 실패한 디렉터리 이동처럼 기존 cwd를 유지합니다. 선두의 `~/`와 단독 `~`는
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
Override는 운영 점검과 테스트에 사용할 수 있습니다. `--strict <task-dir>`로 실행하여
exit 0이면 조용히 허용하고, exit 1이면 checker 출력의 처음 1,500바이트와 정확한 재실행
명령, off-switch 경로를 포함해 차단합니다. Task/checker를 찾지 못하거나 exit 2 또는
실행 오류가 발생하면 `systemMessage`, stderr, journal에 경고를 남기고 허용합니다.
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

# 테스트

```bash
bash tests/test-policy.sh
bash tests/test-runtime.sh
bash tests/test-tier1-runtime.sh
bash tests/test-notice-runtime.sh
```

주요 회귀 검사 범위:

- model-policy profile
- reset-aware pressure 계산
- Claude runtime lead routing
- Codex model/effort routing
- Fast mode compatibility
- provider reserve behavior
- Tier 1 normal=Sonnet 보장
- stale-policy notice false positive 방지
- tmux/worktree managed session lifecycle
- status-line 설정 보존
- runtime hook JSON contract

---

# 설정 파일

## `model-policy.conf`

정적인 role/profile → model/effort mapping.

## `budget-policy.conf`

실시간 pressure → Claude lead profile / Codex model-effort / provider dispatch mapping.

quota 정책을 튜닝할 때 가장 많이 보는 값:

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

`budget-policy.conf`은 structural policy revision에서 제외되어 있으므로 threshold 조정만으로 running session을 reload하지 않는다.

---

# 권장 운영 패턴

서버에서 하나의 프로젝트를 계속 작업:

```bash
cc-orch session new main ~/projects/my-project \
  --project-name my-project \
  --inplace
```

SSH에서 빠질 때:

```text
Ctrl-b, d
```

다시 접속:

```bash
cc-orch session attach main
```

Claude를 종료했다가 같은 conversation을 이어갈 때:

```bash
cc-orch session restart main
```

상태 확인:

```bash
orch-model-guard budget
cc-orch session list
```

병렬 feature 작업:

```bash
cc-orch session new auth ~/projects/api
cc-orch session new cache ~/projects/api
```

각 session은 별도 branch/worktree/tmux에서 동작하므로 서로 index와 checkout을 충돌시키지 않는다.

---

# 설계 철학 요약

```text
Claude ↔ Codex 전환은 task/work-unit 경계에서
각 provider 내부 model/effort 전환은 phase/call 경계에서
```

진행 중인 agent의 context를 버리고 모델을 계속 바꾸는 대신, 하나의 agent가 맡은 책임과 context는 유지한다. 새로운 작업이나 새로운 Codex 호출에서만 최신 quota 상태를 읽어 다음 자원을 선택한다.

이 방식은 다음을 동시에 노린다.

- 두 subscription quota의 실질적인 병렬 활용
- reset 직전 quota를 불필요하게 남기지 않기
- reset이 먼데 과소비하는 상황 방지
- 고비용 모델을 bookkeeping에 낭비하지 않기
- Claude와 Codex의 서로 다른 blind spot을 독립 gate로 활용
- SSH/서버 환경에서도 세션과 작업 디렉터리를 안정적으로 유지

**cc-orchestra의 목표는 항상 가장 강한 모델을 쓰는 것이 아니라, 남은 시간·남은 quota·작업 위험도·검증 역할을 함께 고려해 가장 적절한 자원을 다음 작업에 배정하는 것이다.**
