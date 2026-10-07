# cc-orchestra

cc-orchestra는 코드 작업 요청을 작은 작업으로 나누고, 계획·구현·검증을 맡을
Claude Code와 Codex CLI를 연결하는 도구다. 서버에서 여러 작업을 진행하며 결과를
확인하려는 개발자를 위한 것이다. 처음이라면 [첫 사용 안내](GETTING-STARTED.ko.md)를
따라 설치부터 첫 요청, 결과 확인, 재접속까지 진행하면 된다.

기본 혼합 모드는 Claude Code가 작업을 조율하고 Codex CLI가 조사·구현·검증에 참여한다.
Codex만 쓰는 모드도 있다. 모델 선택과 검증 규칙은 아래 운영 설명에 정리했다.

## 처음 사용하는 순서

### 필요한 것

- [ ] Linux 서버 또는 PC, bash, Python 3, Git, tmux
- [ ] 로그인한 Claude Code와 Codex CLI
- [ ] Claude 구독 계정

새 서버에서 준비한다면 [부트스트랩 가이드](BOOTSTRAP.ko.md)부터 읽는다.
Codex CLI의 로그인도 확인한다. 자세한 준비와 확인 명령은
[첫 사용 안내의 준비물](GETTING-STARTED.ko.md#2-준비물)에 있다.

### 첫 실행

1. 이 저장소를 설치하고 `./install.sh --check`로 확인한다.
   아래 [설치 명령](#quick-start)을 따르거나 새 서버라면 부트스트랩을 사용한다.
2. 작업할 프로젝트의 Git 폴더에서 관리 세션을 시작한다. 세션은 tmux가 유지하는
   터미널 작업 공간이다. 아래 예시는 기존 폴더에서 작업한다.

   ```bash
   cc-orch session new main /path/to/project --project-name my-project --inplace
   ```

3. 열린 Claude Code에 요청을 평소 말로 입력한다. 예: “README에 설치 확인 문장 한 줄을
   추가하고, 변경 내용을 확인해 줘.” 범위와 완료 조건을 함께 쓰면 좋다.
4. 진행은 `cc-orch session status main`과 프로젝트의 `.orchestra/REGISTRY.md`에서 본다.
   완료되면 최종 보고의 `STATUS`, 작업 디렉터리의 `summary.md`, 브랜치와 커밋을 확인한다.
5. 터미널에서 `Ctrl-b` 다음 `d`를 눌러 세션을 남기고 빠져나온다.
   `cc-orch session attach main`으로 다시 접속한다.

각 단계와 실제 입력 위치는 [첫 사용 안내](GETTING-STARTED.ko.md)에 설명했다.

### 자주 쓰는 명령

| 목적 | 명령 |
|---|---|
| 설치 확인 | `./install.sh --check` |
| 세션 목록·상태 | `cc-orch session list` · `cc-orch session status main` |
| 다시 접속·정지·재시작 | `cc-orch session attach main` · `cc-orch session stop main` · `cc-orch session restart main` |
| 작업 폴더 찾기 | `cc-orch session path main` |
| 사용량·모델 배정 상태 | `orch-usage-report --days 1` · `orch-model-guard budget` · `orch-model-guard lanes` (PATH의 `orch-model-guard`는 런타임 래퍼 `bin/orch-model-guard-runtime`) |
| 작업 기록 보관(아카이브) | `orch-archive` · `orch-archive apply` · `orch-archive verify` |
| 끝난 작업 클론 정리 후보 확인 | `orch-gc` · `orch-gc scan --json` |

### 막혔을 때

| 증상 | 먼저 할 일 |
|---|---|
| 설치 확인이 실패함 | [부트스트랩 가이드의 설치 검증](BOOTSTRAP.ko.md#6-cc-orchestra-설치-검증)을 따라 누락 항목 확인 |
| CLI 로그인이 필요함 | `claude auth status`와 `codex login status` 확인 |
| 세션 화면에서 나왔음 | `cc-orch session list` 후 `cc-orch session attach main` |
| 세션이 멈춰 있음 | `cc-orch session status main` 확인 후 `cc-orch session restart main` |
| 작업 파일이 안 보임 | `cc-orch session path main`은 세션의 기준 폴더만 보여준다. lead 작업은 `<repo>/.orchestra/wt/lead-<slot>` 같은 별도 worktree와 `orch/<NN>-<slug>` 브랜치에 있을 수 있다. lead 최종 보고의 `BRANCH`·`WORKTREE`, `.orchestra/REGISTRY.md` 행, 작업의 `summary.md`를 확인 |

더 자세한 해결 순서는 [첫 사용 안내의 막혔을 때](GETTING-STARTED.ko.md#9-막혔을-때)에 있다.

### 먼저 알아둘 말

**Tier**는 작업 단계, **lead**는 한 작업의 계획과 결과를 책임지는 담당자다.
**brief**는 목표와 완료 조건을 적은 파일이고, **gate**는 완료 전 검증이다.
**worktree**는 같은 Git 저장소를 별도 폴더에서 작업하는 방식이다.
**quota routing**은 남은 모델 사용 한도에 맞춰 다음 호출을 배정하는 것이다.
**tmux**는 접속이 끊겨도 서버에서 터미널을 유지한다.
**Remote Control**은 다른 기기에서 같은 Claude Code 대화를 여는 기능이다.
용어와 작업 위치는 [첫 사용 안내](GETTING-STARTED.ko.md#11-용어집과-다음-문서)에서 다시 설명한다.

[운영 가이드](OPERATIONS.ko.md) · [Operations (English)](OPERATIONS.md) ·
[저장소 수정 가이드](AGENTS.md) · [Codex 전용 모드](CODEX-ONLY.ko.md)

---

## Quick Start

### 신규 설치

새 Linux 사용자·서버의 의존성 설치와 로그인은 [부트스트랩 가이드](BOOTSTRAP.ko.md)의
`./install.sh --bootstrap`으로 준비할 수 있다. 환경이 이미 준비되어 있다면:

```bash
git clone https://github.com/janghunn/cc-orchestra.git ~/cc-orchestra
```

저장소가 비공개일 수 있다. HTTPS 복제가 인증 오류로 실패하면
[부트스트랩 가이드 1절](BOOTSTRAP.ko.md#1-부트스트랩-전에-사람이-해야-하는-것)에 따라
SSH 키를 GitHub에 등록하고 `git clone git@github.com:janghunn/cc-orchestra.git ~/cc-orchestra`로 받는다.

```bash
cd ~/cc-orchestra

./install.sh
./install.sh --check
```

설치 명령은 기본적으로 `~/.local/bin`에 연결된다. `cc-orch: command not found`가 나오면
`export PATH="$HOME/.local/bin:$PATH"`로 현재 셸의 PATH에 추가하고, 같은 설정을
`~/.profile`과 `~/.bashrc`에도 저장한다. `./install.sh --bootstrap`은 `~/.local/bin`을
두 파일에 자동으로 기록한다([부트스트랩 가이드 2절](BOOTSTRAP.ko.md#2-한-번에-부트스트랩)).
부트스트랩을 실행한 현재 셸의 PATH는 자동으로 바뀌지 않으므로 `cc-orch`를 쓰기 전에 새 셸을 열거나
`source ~/.profile`을 실행한다.

Codex lane을 사용하려면 Codex CLI가 로그인되어 있어야 한다.

```bash
codex login status
```

### 기존 설치 업그레이드

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
  - Codex: healthy 기본 Astra(폴백 Sol)와 effort를 호출마다 선택
  - 실행 중 agent는 강제로 바꾸지 않고 **다음 dispatch부터** 새 정책 적용
- **시스템 프롬프트에 반영한 모델별 지침**: Sonnet 5.5 / Opus 5.5 / Fable 5.1 / GPT-6 Astra-Sol의
  프롬프팅 지침(예: 이미 승인된 다음 단계는 재승인 질문 없이 실행)은
  [templates/lead.md.tpl](templates/lead.md.tpl)의 "Finishing the task",
  [agents/codex-lead.md](agents/codex-lead.md), [agents/codex-worker.md](agents/codex-worker.md)의
  lead/Codex 시스템 프롬프트에 직접 담고, Codex lane별 실행 지시는 [bin/codex-run](bin/codex-run)에 둔다.
  별도 팁 문서 대신 실제 실행 지시에 반영해 호출마다 자동으로 적용한다.
- **Codex 모델 확인**: 혼합 모드의 자동 배정은 healthy에서 GPT-6 Astra를 우선하고,
  계정/CLI 모델 목록에 없거나 필요한 effort·Fast mode를 지원하지 않으면 해당 lane의
  기본 GPT-6 Sol로 폴백한다. 일반 Codex lane 기본값은 GPT-6 Sol, 빠른/기계적 작업은
  GPT-6 Luna다. `terra`는 이전 GPT-5.6 모델을 가리키는 별칭이다. 명시적으로 고른
  모델이 없어 exit 6이 나면 목록에 있는 다른 모델로 한 번 재시도한다.
- **실험·평가 단계의 Jev 자문**: [orch-jev](OPERATIONS.ko.md#jev-자문-사이드카-선택-사항-hybrid-모드-전용)의
  `lint-brief`/`risk`/`scan`은 사용자·agent가 명시적으로 호출하는 선택적 자문으로, 작업 파일을 수정하거나
  gate·라우팅을 결정하지 않으며 판단은 사람과 agent가 내린다.
  별도 Codex 라우팅 shadow는 [Stage 1의 `do not adopt` 결과](eval/jev-shadow-stage1/report-2026-10-06.md)에 따라
  2026-10-06부터 현재 꺼져 있다(`jev-policy.conf`의 `JEV_SHADOW_ENABLED=0`).
  활성화한 경우에만 제안 모델·effort를 `codex-shadow.jsonl`에 기록하며,
  Jev 사용 가능 여부와 관계없이 실제 dispatch·인자·exit code·`codex.log`에는 영향을 주지 않는다.
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
 ├─ Codex intake                                 healthy 기본 Astra (폴백 Sol), pressure에 따라 조정
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
Tier 4  executable verify ──────────────────────► Codex Astra (Sol 폴백)
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

## 더 알아보기

- 전체 운영 절차: [한국어](OPERATIONS.ko.md) · [English](OPERATIONS.md)
- 저장소 자체 수정: [AGENTS.md](AGENTS.md) — self-hosting checkout, 정책 원본과 산출물 규칙
- Codex 전용 실행과 혼합 모드 전환: [CODEX-ONLY.ko.md](CODEX-ONLY.ko.md)
- 처음부터 따라 하기: [GETTING-STARTED.ko.md](GETTING-STARTED.ko.md)
- 새 서버 설치: [BOOTSTRAP.ko.md](BOOTSTRAP.ko.md)
- Quota 계산·데이터 출처·pressure 경계: [런타임 예산 모델](OPERATIONS.ko.md#런타임-예산-모델)
- Claude/Codex 모델·effort 표와 gate parsing: [동적 라우팅](OPERATIONS.ko.md#동적-라우팅)
- WATCH `gpt-6.1-sol`, Fast mode와 명시적 `--effort ultra`: [Codex 모델과 effort](OPERATIONS.ko.md#codex-모델과-effort-선택) · [Fast mode](OPERATIONS.ko.md#fast-mode)
- Provider 선택: [provider 간 dispatch 결정](OPERATIONS.ko.md#provider-간-dispatch-결정)
- tmux·worktree 명령과 Remote Control: [지속형 세션](OPERATIONS.ko.md#지속형-세션과-worktree)
- 정책 변경 적용과 roster 재생성: [reload 규칙](OPERATIONS.ko.md#reload-없이-즉시-반영되는-항목)
- 명령 참조: [Codex 명령](OPERATIONS.ko.md#codex-명령) · [상태 확인](OPERATIONS.ko.md#자주-쓰는-운영-명령-요약)
- 운영 설정과 검증: [설정 튜닝](OPERATIONS.ko.md#설정-튜닝) · [런타임 안전 hook](OPERATIONS.ko.md#런타임-안전-hook) · [회귀 검사](OPERATIONS.ko.md#회귀-검사)

---

## Task workflow

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

Lead는 첫 `investigate` 전에 루트의 [AGENTS.md](AGENTS.md)(저장소 안내)와
[INSTINCTS.md](INSTINCTS.md)(이전 작업의 교훈)과 [IMPROVEMENT-CANDIDATES.md](IMPROVEMENT-CANDIDATES.md)(제안된 개선 후보)를 각각 있으면 훑어보며, 이 preflight의
참고 자료를 실행하거나 amended brief·권위 있는 지시로 취급하지 않는다.

Lead는 brief가 승인한 조사·계획·구현 배정·review·commit/push·gate·상한 내 fix round·
최종 보고 블록 반환까지 일상적인 재승인 질문 없이 진행하며 (`summary.md`는 orchestrator가 그 블록을 원문 그대로 저장), 실제 `BLOCKED` 사유·round 상한·
provider 실패에 따른 중단이나 절차 밖의 파괴적·비가역적 작업에 대한 판단은 기존 규칙을 따른다.

---

## 작업 산출물

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
| `summary.md` | orchestrator (lead 반환 블록 원문; Codex-only는 lead) | 최종 상태와 gate evidence |

active context budget:

```text
brief.md    12 KiB
plan.md     40 KiB
summary.md  20 KiB
```

긴 로그는 `evidence/`, 반복 라운드는 `rounds/`에 둔다.

---

## Gate 정책

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
들여쓰기나 bullet을 쓰면 안 되고 fence 밖에서 `RISK:`로 시작하는 유일한 줄이어야 한다.
줄 앞의 inline backtick span(3개 이상 backtick 뒤 같은 줄에 backtick이 더 있는 경우)은
fence를 열지 않으므로 이후 선언을 숨기지 않는다. 충돌 판정·self-check 설명·artifact 대조의
세부 규칙은 [운영 가이드의 동적 라우팅](OPERATIONS.ko.md#동적-라우팅)을 참고한다.

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

## Git / worktree 원칙

- 여러 독립 task를 동시에 수행할 때는 worktree 격리를 권장한다.
- managed session의 worktree 기본 branch는 `orch/<session-name>`이다.
- `session remove`는 branch를 자동 삭제하지 않는다.
- 작업 branch는 사용자가 merge/abandon 결정을 내릴 때까지 안전하게 남긴다.
- Claude lead slot은 `lead-alpha` → `lead-delta`를 사용한다.
- 실제 agent routing은 `.orchestra/REGISTRY.md`의 `agentId`를 사용한다.

---

## 설계 철학 요약

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
