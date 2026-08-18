# cc-orchestra

Claude Code용 4계층·2공급자 위임 하네스. Tier 1이 사용자와 대화하며 작업을 쪼개고, Tier 2가
분석·설계·레인 배분·리뷰, Tier 3가 구현(Claude/Codex 두 레인), Tier 4가 독립 검증(제로 컨텍스트
+ 교차 패밀리, 두 게이트)을 맡는다.

```
 사용자
   │
   ▼
 orchestrator                Fable 5 @ xhigh       총괄 관리자 — 인테이크, 분해, 배정, 릴레이, 보고
   │                                               Edit 제거 (구현 불가), codex 호출도 금지
   ├── lead-alpha            Fable 5 @ xhigh       작업별 관리자 — 조사, 설계, 레인 배분, diff 리뷰
   ├── lead-bravo                                  Edit 제거 — 유일하게 codex-run을 부르는 계층
   ├── lead-charlie
   └── lead-delta
         │
         ├─ Phase A 조사 ────────────────────────────────────────────────────────
         │    codex-run investigate GPT-5.6-Sol @ xhigh    기본 조사 레인 — 증거 수집은 전부 여기
         │      └ --fast           GPT-5.6-Luna @ high    중간 깊이 질문
         │    (리드 본인 Grep/Read)                        인용 file:line 검증·베이스라인 실행만
         │
         ├─ Tier 3 구현 ─────────────────────────────────────────────────────────
         │    codex-run implement  GPT-5.6-Sol @ xhigh    기본 구현 레인 — 모든 유닛 (--lane으로 동시 2유닛)
         │      └ --mech           GPT-5.6-Luna @ medium  기계적 대량 수정 (rename, lint, boilerplate)
         │    dev-1..3             Opus 5 @ high          예외 레인 — codex 폴백, >272k 컨텍스트, 정밀 조향
         │
         └─ Tier 4 검증 ─────────────────────────────────────────────────────────
              verifier             Opus 5 @ max           제로 컨텍스트 재검증 — 읽기 전용
              codex-run review     GPT-5.6-Sol @ xhigh    교차 패밀리 diff 리뷰 — 읽기 전용
                └ --fast           GPT-5.6-Luna @ high    소규모·저위험 diff용
```

공급자가 둘인 이유: 교차 패밀리 검증(어느 쪽이 짜든 다른 패밀리가 반드시 리뷰에 낀다) +
쿼터 풀 분리다. 특히 Claude 쪽은 트리의 **모든 호출(리드·dev·verifier)이 같은 5h 세션
버킷을 소모**해서 무거운 세션에선 주간 한도보다 세션 한도가 먼저 바닥난다(실측: 주간
29%/50%일 때 세션 79%). 그래서 **구현은 Codex 전담이 기본**이고 dev-\*는 좁은 예외
레인이다 — codex 폴백, >272k 컨텍스트, 정밀 조향, 2회 실패 후 fresh-eyes 스왑, codex-sparing.
Codex는 Tier 2의 도구다 — orchestrator는 부르지 않고, 리드가 `bin/codex-run`으로만 부른다.

**조사도 Codex가 기본이다.** 세 대의 머신에서 서브에이전트별 Claude 사용량을 재보니 최대
소비처는 늘 `lead-*`였다 — 48%/63%/60%로 dev-\*(4~20%)를 크게 앞선다. 리드가 쓰는 토큰의
대부분은 Phase A 증거 수집이므로, 크롤은 `codex-run investigate`로 넘기고 리드는 인용된
file:line 검증·베이스라인 실행·설계 판단만 맡는다. `Explore` 서브에이전트는 codex 불가
(exit 3/4)·`codex-sparing`·사소한 이름 스윕일 때의 폴백이다.

이 배치의 목표는 "Claude 1 : Codex 2"를 요청 수로 맞추는 게 아니다 — 단위가 다르다.
**토큰이 무거운 일(조사·구현·기계적 수정·계획 검토·diff 리뷰 게이트)은 Codex, 판단이
무거운 일(대화·분해·설계·diff 읽기·verifier)은 Claude**로 나누고, 실제 소모율은
`orch-model-guard status`의 두 줄로 관측한다.

## 설치

```bash
git clone https://github.com/janghunn/cc-orchestra.git ~/cc-orchestra
cd ~/cc-orchestra && ./install.sh
./install.sh --check      # 설치 상태 확인
```

`install.sh`는 심링크를 건다 — 리포에서 프롬프트를 고치면 다음 실행부터 바로 반영되고,
`git status`가 항상 실제로 돌아가는 버전을 알려준다.

| 링크 | 대상 |
|---|---|
| `~/.claude/orchestra` | 리포 루트 |
| `~/.claude/agents/orchestrator.md` | `agents/orchestrator.md` |
| `~/.claude/agents/verifier.md` | `agents/verifier.md` |
| `~/.local/bin/cc-orch` | `bin/cc-orch` |
| `~/.local/bin/codex-run` | `bin/codex-run` |

Codex 레인은 **codex CLI + ChatGPT 로그인**을 요구한다 (`codex login`, 머신마다 별도).
없어도 하네스는 Claude 단독으로 완전히 동작하며, `install.sh --check`가 WARN으로 알려준다.

`lead-*.md` / `dev-*.md`는 `build-roster.sh`가 `~/.claude/agents`에 생성하는 실제 파일이며
git 추적 대상이 아니다. 기존 파일이 있으면 덮어쓰지 않고 `.pre-cc-orchestra`로 밀어둔다.

`install.sh`는 모델 가드(systemd user 타이머 + 세션 안내 훅)도 같이 깐다 →
[모델 가드](#모델-가드--fable-주간-한도-소진-시-자동-전환).

## 실행

프로젝트 이름은 **필수**다. 세션 이름, Remote Control 브리지 이름, `$CC_ORCH_PROJECT`에 쓰이므로
여러 프로젝트를 동시에 돌릴 때 휴대폰에서도 어느 세션인지 구분된다.

```bash
cc-orch priorsplat                              # 현재 디렉터리
cc-orch priorsplat ~/projects/priorsplat        # 디렉터리 지정
cc-orch priorsplat ~/projects/priorsplat -c     # 마지막 대화 이어서
cc-orch --no-rc halfres-gshead                  # Remote Control 없이
```

실제로 실행되는 것:

```bash
claude --agent orchestrator \
       --model "$(orch-model-guard active)" \   # 보통 fable[1m], 한도 소진 시 opus[1m]
       --effort xhigh \
       --dangerously-skip-permissions \
       --settings ~/.claude/orchestra/guardrails.json \
       --remote-control "orch-<name>" \
       --name "orchestrator@<name>"
```

Remote Control은 claude.ai 구독 로그인이 필요하며, 세션을 claude.ai/code에 연결해
휴대폰이나 다른 기기에서 같은 세션을 조종할 수 있게 한다.

## 슬롯 이름으로 특정 관리자 지목하기

핵심 제약: **`SendMessage`는 서브에이전트를 타입 이름으로 라우팅하지 못한다.** 이름으로 보내면
`No agent named 'lead-bravo' is currently addressable` 로 실패한다. 실제 핸들은 `Agent` 호출
결과에 담겨 오는 `agentId`(`a…` 형식)다.

그래서 구조는 이렇게 나뉜다:

- **슬롯 이름** (`lead-bravo`) = 사람이 쓰는 라벨. 사용자가 말하고, 보고서 머리에 찍히고,
  보드에 표시되는 것.
- **agentId** = 실제 라우팅 주소. orchestrator가 `REGISTRY.md`에 기록하고 번역한다.

사용법은 그냥 이름으로 부르면 된다:

```
> lead-bravo에게 캐시 TTL을 300초로 바꾸라고 전달해줘
> 지금 각 슬롯 상태 보여줘
> lead-charlie 작업은 취소하고 슬롯 비워줘
```

완료된 리드에게 보내도 트랜스크립트에서 재개되므로 컨텍스트가 유지된다.

슬롯이 4개인 이유는 동시 진행 작업 수 상한이자, 리뷰 품질이 병목이 되는 지점이기 때문이다.
더 필요하면 `build-roster.sh`의 `LEAD_SLOTS` 배열에 추가하고 재생성하면 된다.

## 작업 산출물

작업마다 `<repo>/.orchestra/<NN>-<slug>/` 아래에 쌓인다. 첫 사용 시 `.orchestra/`가
`.git/info/exclude`에 추가된다 (`.gitignore`는 건드리지 않음).

| 파일 | 작성자 | 내용 |
|---|---|---|
| `REGISTRY.md` | orchestrator | 슬롯 ↔ agentId ↔ 작업 매핑 (루트에 위치) |
| `brief.md` | orchestrator | 목표, 범위 경계, 인수 조건, RISK, 제외 항목 |
| `plan.md` | lead | 조사 결과 + 자기완결적 구현 명세 |
| `plan-review-codex.md` | codex (조건부) | 구현 전 설계 교차 검토 — `PLAN-REVIEW: SOUND \| ISSUES n` |
| `codex-investigation.md` | codex (조건부) | Phase A 조사 위임 결과 — `[codex] INVESTIGATION` + file:line 근거 |
| `impl-report-devN.md` | dev | 변경 요약, 실행 명령, 원문 출력 |
| `impl-report-codex[-lane].md` | codex 레인 | dev 리포트와 동일 계약 (`[codex]` 헤더, 병렬 lane별 파일) |
| `review.md` | lead | diff 리뷰 지적사항 |
| `verdict.md` | verifier | PASS / FAIL / INCONCLUSIVE + 근거 |
| `codex-review.md` | codex 게이트 | `CODEX-REVIEW: CLEAR \| BLOCKING n / NONBLOCKING m` + 지적 |
| `summary.md` | lead | orchestrator에게 올리는 최종 보고 |

`.codex-session`(레인별 스레드 ID·모델·effort)과 `codex-*.jsonl/.stderr.log`(이벤트 스트림)는
`codex-run`의 배관이다 — 진행 상황은 `tail codex-implement.jsonl`로 볼 수 있다.

## Git 규율 — 전 과정 추적과 되돌리기

모든 작업이 git에 남아서 어느 지점으로든 되돌릴 수 있다. **커밋 권한은 리드에게만 있다** —
dev는 `commit`/`push`/`branch`/`switch`/`restore`/`stash`가 전부 금지고 읽기 전용 git만 쓴다.
작업당 커밋 주체가 하나라는 것이 병렬 작업이 엉키지 않는 핵심 장치다.

리드는 스폰 직후 Phase A0에서:

1. **repo 확보** — 이미 git repo면 그대로 쓴다 (**기존 repo 위에 `git init` 절대 금지**).
   repo가 아니면 `git init`하되, 데이터셋·체크포인트(`*.pth`, `outputs/`)가 있고 `.gitignore`가
   없으면 커밋하지 않고 orchestrator에게 확인받는다. 사용자가 특정 remote를 지정했으면 그걸 등록한다.
2. **베이스라인 기록** — `HEAD` sha와 `git status`. 이미 더러운 트리는 **사용자의 변경**이므로
   절대 스테이징하지 않고 `plan.md`에 기록만 한다.
3. **브랜치 생성** — `orch/<NN>-<slug>`, 작업 디렉터리와 이름을 맞춘다.

### GIT MODE — 동시 실행 충돌 방지

orchestrator가 brief의 `GIT MODE:` 줄로 지정한다. 몇 개가 동시에 도는지는 orchestrator만 알기 때문:

| 모드 | 언제 | 동작 |
|---|---|---|
| `worktree` | 리드 2개 이상 동시 실행 | `.orchestra/wt/<slot>`에 리드별 체크아웃. index·브랜치 경합 없음 |
| `inplace` | 리드 1개, 또는 환경 의존이 큰 프로젝트 | 메인 worktree에서 `git switch -c` |

conda 환경 경로, 데이터 심링크, 다운로드된 weight처럼 새 worktree에 없는 것에 의존하는
연구 repo는 `inplace`가 맞다. 그런 경우엔 동시 실행 대신 순차 실행으로 분리한다.

`worktree` 모드여도 `.orchestra/<NN>-<slug>/` 산출물은 **메인 worktree에 남는다.** 코드 작업만
worktree에서 하고 brief·plan·report·verdict는 한 곳에 모인다.

### 커밋 시점

| 시점 | 메시지 |
|---|---|
| dev 착수 전 | `chore(lead-alpha): baseline for <task>` |
| dev 작업 도착 + 리뷰 통과 | `feat(lead-alpha): <변경 내용>` |
| 리뷰 수정 라운드마다 | `fix(lead-alpha): <리뷰가 잡은 것>` |
| verifier PASS | `test(lead-alpha): verified via <command>` |

**`git add -A` / `git add .` 금지, 명시적 pathspec만.** plan의 *Changes* 목록에 있는 파일만
스테이징한다. 이것이 있어야 같은 worktree를 공유해도 다른 작업의 진행 중 변경을 물어가지 않는다.
목록 밖의 변경이 보이면 그건 커밋 대상이 아니라 조사 대상(scope violation)이다.

### push와 되돌리기

커밋마다 `git push -u origin orch/<NN>-<slug>`. **자기 `orch/*` 브랜치만** 밀고
`main`/`master`는 절대 건드리지 않는다. remote가 없거나 push가 실패해도 작업은 계속한다 —
중요한 건 커밋이고, 실패는 `summary.md`에 기록한다.

리드는 커밋 SHA를 전부 `summary.md`에 남기고 최종 보고에 `BRANCH` / `COMMITS` 줄로 올린다.
되돌릴 때는 `git revert <sha>` 또는 `git restore --source=<sha> -- <files>`.
`git reset --hard`는 가드레일이 막는다 — 커밋되지 않은 사용자 작업까지 날리기 때문.

**머지는 아무도 자동으로 하지 않는다.** 리드는 브랜치를 넘기고, orchestrator는 브랜치 목록을
제시하며, 머지 여부는 사용자가 결정한다. 병합되지 않은 `orch/*` 브랜치는 그 작업의 유일한
사본이므로 임의로 삭제하지 않는다.

## Brief 감사 — 검사받지 않는 계층 메우기

검사 체계에 비대칭이 있었다:

```
dev-*         →  lead가 diff를 직접 읽고 검사
lead-*        →  verifier가 컨텍스트 제로로 독립 검증
orchestrator  →  아무도 검사하지 않음      ← 구멍
```

Tier 1의 오류만 끝까지 조용히 통과한다. 잘못된 분해는 리드가 "범위 안에 머물라"는 지시를
*충실히* 따르기 때문에 그대로 실행되고, 헐거운 인수 조건은 verifier가 "사용자 의도"가 아니라
**"기준"에 대고** 검사하기 때문에 엉뚱한 것에 초록불을 켠다.

그래서 리드에 **Phase A1 — brief 감사**를 넣었다. 코드를 실제로 읽은 뒤(Phase A 이후),
설계하기 전에 brief를 검사한다:

1. 인수 조건이 전부 **명령이나 관찰로 환원 가능한가** — "인증이 안전해진다"는 검증 불가,
   "`pytest tests/test_auth.py::test_expired_token` 통과"는 검증 가능
2. 범위가 코드와 맞는가 — *In scope*가 실제로 변경이 일어나는 층인가, *Out of scope*가
   반드시 건드려야 하는 파일을 빼고 있지 않은가
3. 검증 명령이 존재하고 실행되는가
4. 다른 작업과 범위가 겹치지 않는가 — 겹치면 분해가 틀렸고 리드 둘이 곧 충돌한다

**핵심은 반박 기준을 좁게 잡은 것이다.** 매 작업마다 왕복이 생기면 오히려 시간 손해다:

| 상황 | 대응 |
|---|---|
| 증거로 메울 수 있는 격차 (읽는 법이 하나뿐인 조건, 명령 오타, 명백히 빠진 파일) | **직접 고치고 `plan.md`의 *Amendments*에 기록하고 계속 진행.** 왕복 없음 — 이게 일반적인 경우 |
| 사이클을 낭비할 수 있는 결함 (검증 자체가 불가, 구현이 갈리는 두 가지 해석, 형제 작업과 범위 중첩, 코드가 전제를 반증) | **즉시 `BLOCKED` + 정확한 수정안 제시** |

`BLOCKED`을 낼 때는 결함 줄을 인용하고 **교체할 문장을 그대로 제시**한다.
"인수 조건 2가 검증 불가"는 턴을 낭비하고, "인수 조건 2를 `pytest tests/test_cache.py -k ttl`로
바꿔주면 검증 가능"은 한 번에 끝난다.

리드는 최종 보고에 `BRIEF AUDIT: clean | amended | defective` 줄을 올리고, orchestrator는
`defective`를 받으면 brief를 수정해 **같은 리드에게** 보낸다(조사 결과가 살아 있으므로 메시지
하나로 끝난다). **이건 실패 라운드로 세지 않는다** — 가장 값싼 시점에 오류를 잡은 것이므로
에스컬레이션 예산(작업당 2회)을 소모하지 않는다.

여기서 잡힌 brief 결함은 메시지 하나. 같은 결함을 dev가 구현한 뒤에 잡으면
구현→리뷰→검증 사이클 하나. 이 비대칭이 이 단계의 존재 이유다.

## Codex 통합 — 두 번째 공급자

Codex(OpenAI)는 에이전트가 아니라 **리드가 Bash로 부르는 CLI 레인**으로 들어온다. 래퍼는
`bin/codex-run` 하나이고, 리드만 부른다 (orchestrator·dev는 금지).

```bash
codex-run implement   <workdir> <task-dir>              # Sol @ xhigh — plan.md를 읽고 구현
codex-run implement   <workdir> <task-dir> --lane b     # 같은 작업의 동시 2번째 유닛 (plan.md에 Lane assignment 필요)
codex-run implement   <workdir> <task-dir> --mech       # Luna @ medium — 기계적 대량 수정
codex-run investigate <workdir> <task-dir> "<질문>"     # Sol @ xhigh — Phase A 조사 위임 (읽기 전용)
codex-run resume      <workdir> <task-dir> "<지시>"     # 같은 스레드에 후속 수정 (컨텍스트 유지, --lane으로 지정)
codex-run review      <workdir> <task-dir> --base <br>  # Sol @ xhigh — Tier 4 교차 리뷰 (읽기 전용)
codex-run plan-review <workdir> <task-dir>              # Sol @ xhigh — 구현 전 설계 교차 검토
codex-run status      <task-dir>                        # 스레드·산출물·최근 런 확인
# 공통: --fast(luna@high) --escalate(effort max) --model M --effort E --dry-run
```

**역할 배분의 논리:**

- **구현(Tier 3)은 codex 전담이 기본이다.** 모든 유닛이 sol로 간다 — 단일 유닛은 `implement`
  레인, 동시 2번째 유닛은 `--lane <이름>`(작업당 codex 스레드 최대 2개). dev-\*는 예외
  레인이고, 리드는 dev를 쓸 때마다 `summary.md`의 `LANES:` 줄에 사유 태그를 남긴다:
  ① codex 폴백(exit 3/4) ② >272k 컨텍스트(dev는 1M) ③ 턴 단위 정밀 조향
  ④ codex 2회 실패 후 fresh-eyes 스왑(역방향도 동일) ⑤ `codex-sparing` 디스패치.
  리드는 Phase C 전에 `orch-model-guard lanes`를 보고 작업 전체의 모양을 정한다(아래 표).
  원인 불명 버그·성능 미스터리는 어느 경우든 **sol 먼저** (다른 패밀리, 다른 prior가 곧
  fresh eyes다).
- **조사(Phase A)는 codex가 기본이다.** 실측상 Claude 최대 소비처가 `lead-*`(48~63%)이고
  그 대부분이 증거 수집이라, 실질적인 질문은 전부 `codex-run investigate`로 보낸다
  (중간 깊이는 `--fast`). 결과는 dev 리포트처럼 취급한다 — file:line 근거를 리드가 직접
  확인하고, 베이스라인 커맨드는 리드가 직접 돌리고, 설계 판단은 리드 몫이다.
- **리뷰 게이트(Tier 4)는 무조건 교차 패밀리다.** codex가 구현한 diff도 리드(Claude)가
  리뷰하므로, 어느 레인이 짰든 "Claude가 놓치는 것"은 codex 리뷰만 잡을 수 있다.
  PASS 조건: `verdict.md` = PASS **그리고** `codex-review.md` = CLEAR 또는 NONBLOCKING만.
  BLOCKING은 실패 라운드로 취급하고 수정 후 **두 게이트를 다시** 돌린다. 예외는 명시적으로만:
  문서·설정 전용 diff는 `codex gate: waived (<이유>)`, 쿼터·인증 장애는
  `codex gate: unavailable`을 `summary.md`에 남기고 verifier 단독으로 간다.
- **`RISK:` (brief의 필드)가 강도를 정한다.** `critical`이면 plan-review 필수 + sol 게이트
  강제(`--fast`·waive 금지), `low`면 게이트 waive 허용.

**연속성** — `codex exec`는 스레드를 남기고, 래퍼가 `<task-dir>/.codex-session`에
`레인=스레드ID|모델|effort`를 기록한다. `codex-run resume`은 그 스레드를 **그 레인의
모델·effort 그대로** 이어간다 (`--mech`로 시작한 유닛이 후속 지시에서 조용히 sol로 승격되지
않는다; `--escalate`만 effort를 올린다). dev의 `SendMessage` 재개와 같은 역할이다.

**격리** — implement는 `--sandbox workspace-write`(쓰기가 workdir로 제한), review·plan-review·
investigate는 `--sandbox read-only`. 위험 플래그(`--dangerously-bypass-approvals-and-sandbox` 등)는 래퍼에
아예 없다. codex도 dev와 같은 규칙으로 **커밋하지 않는다** — 커밋은 리드만 한다.

**실패 처리** — 종료 코드로 구분한다: `3` 쿼터 소진(리뷰는 `--fast` 1회 재시도, 구현은 dev로
폴백), `4` 인증(`codex login` 필요, Claude 단독 진행), `5` 타임아웃(구현 90분·리뷰 45분,
스레드가 남으므로 `resume`으로 이어받기 가능). 어느 경우든 **codex 장애는 작업을 멈추지
않는다** — 기록하고 Claude 단독으로 진행한다.

### 양쪽 사용량 관측 → 3-상태 디스패치

Codex 쪽 주간 한도도 이제 모델 가드가 본다. **추가 API 호출은 없다** — `codex exec`(즉
`codex-run`)가 매 턴 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`에 남기는 `rate_limits`
스냅샷을 읽는다:

```
"rate_limits":{"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":10080,
               "resets_at":1787196964},"secondary":null,...,"plan_type":"pro",...}
```

가장 최근 rollout 파일(오늘·어제 디렉토리 fast path, 없으면 mtime 전체 스캔)의 마지막
`rate_limits`를 파싱해 `codex_pct`/`codex_resets_at`/`codex_asof`를 state에 기록한다.
스냅샷이 없거나 24h(`CODEX_USAGE_STALE_HOURS`)보다 오래되면 **unknown = 여유 있다고 가정**한다 —
Codex는 이 하네스에서 역사적으로 유휴 풀이고, 진짜 소진은 exit 3으로 즉시 드러나기 때문이다.

`orch-model-guard lanes`는 이제 양쪽을 보고 세 상태 중 하나를 준다 (우선순위 순):

| `dispatch=` | 조건 | 구현 | 조사(Phase A) | 리뷰 게이트 |
|---|---|---|---|---|
| `codex-sparing` | codex 주간 ≥ `LANES_CODEX_SPARE_PCT`(85) | dev (`sparing` 태그) | 리드 직접 + `Explore` | `--fast` |
| `codex-first` | 세션 ≥ 60 · 주간(all) ≥ 75 · Claude 데이터 없음 | codex 직렬화 (spill 금지) | codex | 전력 sol |
| `balanced` | 그 외 | codex, 3번째+ 병렬 유닛만 dev spill | codex | 전력 sol |

`codex-sparing`의 85%는 주간 가드의 98%보다 훨씬 낮다 — **리뷰 게이트는 작업마다 필수인데
구현은 대체재(dev-\*)가 있으므로**, 남은 15%는 게이트 몫으로 잡아둔다.

```bash
orch-model-guard status   # claude / codex 두 줄을 나란히 — 실제로 어느 쪽이 타고 있는지
orch-model-guard lanes    # 4줄: dispatch / claude / codex / reason
```

리드는 자기가 받은 값을 `summary.md`와 보고 블록의 `DISPATCH:`·`INVESTIGATION:`·`LANES:`
줄에 남기므로, 배분이 의도대로 갔는지는 사후에도 확인된다.

## Effort 배분

Effort는 직급순이 아니라 **(오류의 대가) ÷ (토큰 물량)** 으로 준다.

| 계층 | 모델 | effort | 이유 |
|---|---|---|---|
| orchestrator | `fable[1m]` | `xhigh` | 분해 결정은 레버리지가 가장 크지만, 릴레이·보드 갱신 같은 저부가 턴이 대부분이고 **사용자가 직접 기다리는** 유일한 계층이라 `max`는 세금이 된다 |
| lead-\* | `fable[1m]` | `xhigh` | 가장 어려운 사고를 한다 — 증거 검증, 설계, 레인 배분, diff 리뷰. 컨텍스트 압박도 최대라 1M이 실제로 필요한 곳. 실측 최대 소비처이기도 해서(48~63%) 증거 **수집**은 codex 조사 레인으로 뺐다 |
| codex 조사 | `gpt-5.6-sol` | `xhigh` | Phase A 기본 레인. 증거 크롤은 토큰이 무겁고 판단은 가벼워서, 리드의 5h 세션 버킷 대신 Codex 주간 풀에서 태우기에 가장 적합한 일이다. 중간 깊이 질문은 `--fast`(luna@`high`) |
| dev-\* | `opus[1m]` | `high` | 리드가 자기완결적 명세를 넘기므로 열린 추론보다 정밀한 실행에 가깝다. 150턴 × 3슬롯이라 **전체 wall-clock의 긴 다리**이기도 하다. Opus 5 자체 기본값도 `high` |
| codex 구현 | `gpt-5.6-sol` | `xhigh` | 기본 구현 레인 — 보통 유닛의 명세 실행부터 원인 불명 버그·2차 시도까지 전부 이 레인이 받으므로 상한을 넉넉히 둔다. `--escalate`가 `max`. **sol의 자체 기본값은 `low`라서** 래퍼가 항상 명시한다 |
| codex 기계 수정 | `gpt-5.6-luna` | `medium` | 변환 규칙이 명확한 대량 수정은 깊은 추론이 아니라 처리량 문제다. luna 자체 기본값 |
| verifier | `opus[1m]` | `max` | 40턴 읽기 전용이라 물량은 무시할 수준인데 실패 모드가 **false PASS** — 시스템 최악의 결과. 하네스에서 가장 값싼 품질 투자 |
| codex 리뷰 | `gpt-5.6-sol` | `xhigh` | verifier와 같은 논리의 게이트지만 물량이 더 크다(diff 전체 정독). `max`가 아닌 이유: 게이트 둘 중 실행 검증(false PASS 방어)은 verifier가 `max`로 이미 서 있고, 이쪽의 부가가치는 깊이보다 **다른 priors**에서 온다. `--fast`(luna@`high`)는 소규모 diff 전용 |

dev가 미묘한 디버깅에서 막히면 대응이 둘로 늘었다: **명세를 조이거나, sol 레인으로 넘긴다.**
effort를 올리는 것은 여전히 답이 아니다 — 같은 모델의 같은 맹점에 토큰만 더 쓰는 일이다.

**모델 배치는 우연이 아니다.** 설계하는 계층(Fable)과 검증하는 계층(Opus)이 다른 모델이라
오류가 탈상관되고, Tier 4의 codex 게이트는 아예 **다른 회사의 패밀리**라 한 단계 더 굵은
탈상관을 준다. 쿼터 풀도 셋(Fable 주간 / Opus 주간 / Codex 주간)으로 분산된다.

[모델 가드](#모델-가드--fable-주간-한도-소진-시-자동-전환)가 fallback으로 넘어가면 Tier 1/2가
`opus[1m]`으로 내려가 Claude 안쪽(Fable↔Opus)의 탈상관은 사라진다 — 예전에는 이때 검증
전체가 단일 패밀리가 됐지만, 지금은 **codex 게이트가 남아** 교차 패밀리 검증만은 유지된다.
verifier를 `sonnet[1m]`으로 돌려 Claude 안쪽 분리까지 복원하는 선택지는 여전히 있다
(아직 적용 안 함).

per-call effort 오버라이드는 Claude 쪽엔 없다 — Agent 도구는 `model`만 받고 `effort`는
frontmatter 고정이다. 그래서 "리드의 리뷰 단계만 max"는 불가능하다. **codex 레인은 반대로
per-call이 기본이다** — `codex-run`이 호출마다 `--effort`를 명시할 수 있으므로
(`--escalate`가 그 예), 상황별 강도 조절이 필요한 작업은 codex 레인이 유리하다.

## 설계상의 강제 장치

프롬프트로 "하지 마라"고 쓰는 것보다 도구를 빼는 쪽이 확실하다:

- `orchestrator`, `lead-*` → `Edit` 제거. 직접 구현으로 흘러내리는 것을 구조적으로 차단.
- `dev-*` → `Agent` 제거. 리프 노드이므로 임의로 계층을 늘리지 못함.
- `verifier` → `Bash, Read, Grep, Glob`만. 검증자가 코드를 고치는 사고를 원천 차단.
  프롬프트로는 다른 에이전트의 산출물(`review.md`·`codex-review.md`)을 읽는 것도 금지 —
  두 게이트가 서로를 앵커링하면 탈상관이 무의미해진다.
- codex → `codex-run` 래퍼로만. 샌드박스(구현 workspace-write / 리뷰 read-only)와
  모델·effort 정책이 래퍼에 박혀 있고, 위험 플래그는 인터페이스에 존재하지 않는다.
  sol의 자체 기본 effort가 `low`인 것도 래퍼가 항상 명시하는 이유다.
- `maxTurns` — lead 200, dev 150, verifier 40. codex는 타임아웃(구현 90분·리뷰 45분). 무한 루프 방지.
- 라운드 상한 — lead는 구현→검증 3회, orchestrator는 작업당 실패 2회 후 사용자에게 에스컬레이션.
  codex BLOCKING 지적의 근거 있는 기각도 작업당 2회까지.

## 가드레일

`guardrails.json`은 `--settings`로 주입된다. **deny 규칙은 권한 모드보다 먼저 평가되므로
`--dangerously-skip-permissions` 아래에서도 유효하다** (실측 확인).

파일 경로 규칙 두 가지 함정:

- 절대 경로는 **슬래시 2개**가 필요하다. `Edit(//home/...)`이지 `Edit(/home/...)`가 아니다.
- **`Write(path)` 규칙은 무시된다.** 파일 권한 검사는 `Edit(path)`만 매칭하며, `Edit` 규칙이
  Write를 포함한 모든 파일 편집 도구를 커버한다. (2.1.220은 이걸 경고로 알려주지만
  2.1.197은 조용히 무시하므로, `Write(...)`로 막아뒀다고 믿으면 안 뚫린 줄 알고 뚫린다.)

막아둔 것: `sudo`, `git push --force`, `git reset --hard`, `git clean`, `mkfs`, `dd`,
`shutdown`, `reboot`, 그리고 `~/.claude/agents`·`~/.claude/orchestra`·`~/cc-orchestra`·
`settings.json` 편집 (계층이 자기 지시문을 실행 중에 고쳐쓰지 못하도록).
`~/.claude/orchestra`가 리포로의 심링크이므로 양쪽 경로를 모두 막아야 한다 — 권한 검사는
실제 경로로 해석되기 때문. 나머지는 전부 프롬프트 없이 실행된다.

너무 빡빡하면 그냥 해당 줄을 지우면 된다. 정책이 아니라 되돌릴 수 없는 사고에 대한 안전망이다.

## 모델 가드 — Fable 주간 한도 소진 시 자동 전환

Tier 1/2는 Fable 5로 돈다. Fable 주간 한도가 바닥나면 `orch-model-guard`가 **orchestrator와
lead-\*를 opus[1m]로 내리고**, 주가 넘어가 한도가 리셋되면 다시 fable[1m]로 올린다.
Tier 3(dev-\*)와 Tier 4(verifier)는 원래 Opus라 대상이 아니다.

```bash
orch-model-guard status      # 지금 뭐가 활성이고 왜 그런지 + 타이머/훅 상태
orch-model-guard check       # 즉시 1회 폴링 (타이머가 5분마다 하는 그것)
orch-model-guard lanes       # 배분 힌트: dispatch=codex-sparing|codex-first|balanced (리드가 Phase C 전에 호출)
orch-model-guard set fallback / primary / auto     # 수동 고정(pin) 및 해제
```

가드 본체(주간 Fable 버킷 → Tier 1/2 모델 전환)와 별개로, `lanes`는 **5h 세션 버킷과 Codex
주간 버킷**을 함께 본다 — Claude 쪽은 트리의 모든 호출이 세션 버킷을 공유해서 무거운
세션에선 주간보다 먼저 바닥나고(실측: 주간 29%/50%일 때 세션 79%), Codex 쪽은 반대로
거의 유휴다(실측: 같은 주에 4%). 세 상태의 조건과 의미는 위 "양쪽 사용량 관측" 표에 있고,
임계값은 `model-policy.conf`의 `LANES_*`다.

판단 근거는 `claude -p /usage`의 `Current week (Fable)` 값이다 (모델 호출 없음, ~2초, 토큰 0).
임계값은 `model-policy.conf`에 있고, 경계에서 왔다 갔다 하지 않도록 두 개다 — `>=98%`면 내리고
`<=90%`면 올린다. 그 사이면 현재 상태를 유지한다. 100이 아니라 98인 이유: 100%가 곧 벽이고
가드는 5분마다만 보므로, 거기서 전환하면 몇 분치 거절을 그대로 맞는다.

**실행 중인 세션에 어디까지 닿는가** — 2.1.220에서 실측한 결과:

| 대상 | 자동 반영 | 근거 |
|---|---|---|
| 새로 띄우는 세션 (전 계층) | **된다** | `cc-orch`가 `orch-model-guard active`를 읽어 `--model`로 넘기고, 로스터 파일도 시작 시점에 읽힌다. |
| 이미 돌고 있는 세션의 `lead-*` | **안 된다** | **에이전트 정의는 세션 시작 시점에 캐시된다.** 파일을 바꿔도 그 세션이 이후에 띄우는 서브에이전트는 시작 당시의 모델·프롬프트·effort를 쓴다. |
| 이미 돌고 있는 orchestrator 본인 | **안 된다** | 세션 자신의 모델은 프로세스 시작 시점에 고정된다. settings 파일도, agent 파일도, 훅도 바꾸지 못한다. |

**측정 방법** (2.1.197·2.1.220 양쪽 동일 결과) — 파일 게이트로 타이밍 레이스를 제거한 프로브:
세션이 프로브 에이전트를 한 번 스폰하고 게이트에서 대기 → 에이전트 파일의 마커를
`MARKER-ALPHA`→`MARKER-BRAVO`로 바꾸고 **디스크에서 확인** → 게이트 개방 → 두 번째 스폰.

```
on-disk marker before release: MARKER-BRAVO
RESULT: FIRST=MARKER-ALPHA  SECOND=MARKER-ALPHA
```

두 번째 스폰도 옛 마커를 받았다. 프롬프트 본문이 캐시된다면 같은 파일의 frontmatter(`model`,
`effort`)도 당연히 캐시된다 — 같은 파싱 결과다.

**그래서 실행 중 세션은 재시작해야 한다.** `/model`은 Tier 1만 옮기고 그 세션의 `lead-*`는
소진된 모델에 그대로 남으므로 임시 조치에 그친다. `hooks/orch-model-notice.sh`가 불일치
상태에서 프롬프트를 넣을 때마다 이 사실을 세션 안에서 알린다:

```
⚠️  모델 가드: Tier 1/2는 이제 opus[1m] 입니다.
    이 세션은 fable[1m] 로 고정돼 있고, 이 세션이 띄우는 lead-* 도 계속 fable[1m] 로 뜹니다
    — 에이전트 정의는 세션 시작 시점에 캐시되므로 파일을 바꿔도 안 바뀝니다.
    →  cc-orch <project>   로 재시작하세요. 두 계층을 다 옮기는 유일한 방법입니다.
       /model opus[1m] 는 이 세션만 옮기고 lead-* 는 fable[1m] 에 남습니다 (임시 조치).
```

진행 중인 작업이 있으면 그것을 마친 뒤 재시작한다. `cc-orch <name> <dir> -c` 로 같은
디렉터리의 최근 대화를 이어받으면 컨텍스트 손실을 줄일 수 있다.

이 훅은 두 군데에 등록된다. `~/.claude/settings.json`은 Claude Code가 watch하므로 **이미 돌고
있는 세션**까지 닿고, `guardrails.json`은 시작 시점에만 읽히지만 cc-orch가 띄우는 **모든 새
세션**에 확실히 붙는다. 둘 다 걸려도 `prompt_id` 스탬프로 한 번만 말한다. orch 세션이 아니면
아무 것도 하지 않으므로 일반 `claude` 세션에는 영향이 없다.

폴링은 systemd user 타이머(`orch-model-guard.timer`, 5분)가 돌린다. `install.sh`가 타이머와
훅을 같이 깔고, `install.sh --check`가 둘 다 확인한다. 상태와 로그는 리포 밖에 둔다 —
`~/.claude/orchestra-state/{state,guard.log,last-usage.txt}`.

## 프롬프트 수정

`~/.claude/agents/lead-*.md`와 `dev-*.md`는 **생성 파일이다. 직접 고치지 말 것** — 다음
빌드에 덮어써진다.

```bash
vi ~/cc-orchestra/templates/lead.md.tpl   # 또는 dev.md.tpl
~/cc-orchestra/build-roster.sh
```

`agents/orchestrator.md`와 `agents/verifier.md`는 슬롯이 하나뿐이라 직접 편집한다. 심링크라
빌드 단계는 필요 없다.

orch 세션 자체는 이 파일들을 못 고치도록 막혀 있으므로, 수정은 일반 `claude` 세션에서.

> ⚠️ **프롬프트를 고쳐도 실행 중인 세션에는 닿지 않는다.** 에이전트 정의는 세션 시작 시점에
> 캐시되므로, 그 세션이 이후에 띄우는 `lead-*`·`dev-*`·`verifier`도 시작 당시 버전으로 뜬다
> ([측정](#실행-중인-세션에-어디까지-닿는가)). 반영에는 **세션 재시작**이 필요하다:
> 진행 중 작업을 마친 뒤 `cc-orch <name> <dir> -c`.
>
> 이것 때문에 오래 돌린 세션은 어떤 하네스 버전으로 도는지 헷갈릴 수 있다. 확인법:
> ```bash
> ps -o lstart= -p <PID>                          # 세션 시작 시각
> git -C ~/cc-orchestra log --oneline --until="<그 시각>" -1   # 그때 캐시된 커밋
> ```

## 다른 머신에 배포

```bash
./sync-to.sh server4            # clone 또는 pull 후 install
./sync-to.sh server4 --check    # 원격 상태만 확인
```

원격이 같은 리포를 clone하므로 양쪽이 동일한 히스토리를 추적하고, 어느 쪽에서든 `git log`로
지금 돌아가는 버전을 알 수 있다. 원격에 `gh` 인증이 되어 있어야 하고(private repo),
`$HOME`이 다르면 스크립트가 거부한다 (`guardrails.json`이 절대 경로를 박아 쓰므로).
Codex 레인까지 쓰려면 원격에도 `codex login`이 따로 필요하다 (없으면 Claude 단독으로 동작).

프롬프트를 고쳤으면: 커밋 → push → `./sync-to.sh server4`.

| 머신 | ssh 별칭 | claude |
|---|---|---|
| 로컬 | — | 2.1.197 |
| render (<internal-host>:2222) | `server4` (Windows에서는 `render`) | 2.1.220 |

버전 열은 2026-08 초 기준이라 그대로 믿지 말 것 — 아래 "확인된 동작"의 항목들은 버전별로
단서를 달아뒀으니, 업그레이드했다면 해당 항목을 다시 재봐야 한다.

## 확인된 동작

실측으로 확인한 것들 (로컬 2.1.197 / 원격 2.1.220 양쪽):

- 서브에이전트의 서브에이전트 생성 — 동작함. Tier 2가 Tier 3을 띄우는 것 확인.
- 커스텀 에이전트 타입은 서브에이전트 컨텍스트에 목록으로 주입되지 않지만, 이름으로 호출하면
  정상 해석된다. 그래서 각 프롬프트에 자기 자식 타입 이름을 명시해 두었다.
- `SendMessage` 이름 라우팅은 team 컨텍스트가 있을 때만 동작 → 서브에이전트는 agentId 사용.
- `effort: xhigh`는 에이전트 frontmatter에서 유효. `fable[1m]` / `opus[1m]` 모두 유효한 모델 문자열.
- deny 규칙 > bypassPermissions. 심링크 경유 경로도 실제 경로로 해석되어 차단됨.
- 에이전트 frontmatter 유효 키: `name, description, model, tools, disallowedTools, color, effort,
  permissionMode, mcpServers, hooks, maxTurns, skills, initialPrompt, memory, background, isolation`.

2.1.220에서 모델 가드를 만들며 실측한 것들:

- **에이전트 정의는 세션 시작 시점에 캐시된다.** 세션 도중 `~/.claude/agents/x.md`를 바꿔도
  그 세션이 이후 띄우는 서브에이전트는 시작 당시의 정의로 뜬다 — 파일 게이트 프로브로 확인
  ([측정](#실행-중인-세션에-어디까지-닿는가)). 초기에 "스폰마다 다시 읽힌다"고 기록했던 것은
  세션 경계를 통제하지 못한 오측이었다.
- **세션 자신의 모델은 시작 후 못 바꾼다.** 프로젝트 settings의 `model`을 도중에 바꿔도, `--settings`
  파일을 바꿔도 그 세션은 계속 원래 모델로 돈다.
- **watch되는 settings 파일의 훅은 실행 중 세션에 반영된다.** 프로젝트 `.claude/settings.json`에
  훅을 도중에 추가하면 다음 프롬프트에서 실행된다. 반면 `--settings`로 넘긴 파일은 시작 시점에만
  읽힌다 (훅은 등록되지만 이후 변경은 무시).
- **훅은 세션의 환경 변수를 물려받는다.** `CC_ORCH_MODEL`을 export해 두면 훅이 그대로 본다.
- `UserPromptSubmit` 훅 입력에는 `model` 필드가 없다. 세션이 지금 실제로 쓰는 모델은
  `transcript_path`의 마지막 assistant 메시지에서 읽는다.
- `claude -p /usage`는 모델 호출 없이 주간 사용률을 텍스트로 준다 (~2초, 토큰 0). 버킷 이름은
  API 쪽 `seven_day_overage_included`가 패널의 `Current week (Fable)`에 해당한다.

codex-cli 0.144.4에서 Codex 레인을 만들며 실측한 것들:

- 모델 라인업과 effort 한계는 `~/.codex/models_cache.json`에 있다: `gpt-5.6-sol`(frontier,
  272k ctx, effort low~**ultra**), `gpt-5.6-terra`(balanced, ~ultra), `gpt-5.6-luna`(fast,
  ~max). `ultra`는 "max + 자동 위임"인데 분해 권한은 Tier 2 것이므로 어느 레인의 기본값도
  아니다.
- **sol의 기본 reasoning effort는 `low`다.** effort를 명시하지 않은 `codex exec -m gpt-5.6-sol`은
  조용히 얕게 돈다. `codex-run`이 매 호출 `-c model_reasoning_effort=`를 강제하는 이유.
- **exec 레벨 플래그는 `resume` 서브커맨드보다 앞에 와야 한다.**
  `codex exec [flags] resume <id> <prompt>`는 되고, `codex exec resume <id> [flags]`는
  `unexpected argument` 에러다.
- **stdin이 열린 파이프면 프롬프트 인자가 있어도 EOF를 기다린다**
  ("Reading additional input from stdin..."에서 무한 대기). 에이전트 하네스 아래가 정확히
  이 조건이라 `codex-run`은 `< /dev/null`을 박아 넣는다.
- `--json`의 첫 이벤트 `thread.started`가 `thread_id`를 주고, 그 id로
  `codex exec resume <id>`가 컨텍스트를 복원한다 (이전 턴 내용 기억 확인).
  resume 시 모델·effort를 바꿔도 스레드는 이어진다.
- `-o <file>`은 마지막 에이전트 메시지를 그 파일에 쓴다 — 리포트 아티팩트를 에이전트의
  파일 쓰기 능력에 의존하지 않고 CLI 레벨에서 보장하는 수단. `--json`과 동시 사용 가능.
- `--sandbox workspace-write`에서 워크트리 밖 쓰기가 실제로 막히고, 프롬프트의 "git 쓰기
  금지" 지시를 준수한다 (e2e: 코드 수정 + 검증 실행 + 무커밋 확인).
- **Codex 주간 사용률은 rollout 로그에 그대로 있다.** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`의
  매 턴 이벤트에 `rate_limits.primary.used_percent`(+ `window_minutes: 10080`, `resets_at` epoch,
  `plan_type`)가 실려 있어서, **추가 API 호출이나 로그인 셸아웃 없이** 파일 읽기만으로 관측된다
  (`orch-model-guard`가 5분 주기에 같이 갱신). 다만 `codex exec`가 한 번은 돌아야 갱신되므로
  최신성은 마지막 codex 런 시각까지다 — 24h 넘으면 unknown 처리한다.
  `secondary`는 `null`이라 5h 상당의 단기 버킷은 여기서 읽을 수 없다 (Claude 쪽과 다른 점).
  객체 위치·이웃 키가 버전마다 흔들려서 파서는 중괄호 세기가 아니라 JSON을 순회해 키를 찾는다.
