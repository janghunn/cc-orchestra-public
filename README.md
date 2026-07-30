# cc-orchestra

Claude Code용 3계층 위임 하네스. Tier 1이 사용자와 대화하며 작업을 쪼개고, Tier 2가 분석·설계·리뷰,
Tier 3가 구현과 독립 검증을 맡는다.

```
 사용자
   │
   ▼
 orchestrator            Fable 5 @ xhigh    총괄 관리자 — 인테이크, 분해, 배정, 릴레이, 보고
   │                                        Edit 도구 제거됨 (구현 불가)
   ├── lead-alpha        Fable 5 @ xhigh    작업별 관리자 — 조사, 설계, diff 리뷰, 검증 게이트
   ├── lead-bravo                           Edit 도구 제거됨 (구현 불가)
   ├── lead-charlie
   └── lead-delta
         │
         ├── dev-1       Opus 5 @ high      구현 개발자 — 구현, 테스트, 증거 기반 보고
         ├── dev-2                          Agent 도구 제거됨 (leaf, 재위임 불가)
         ├── dev-3
         └── verifier    Opus 5 @ max       독립 검증자 — 읽기 전용, 컨텍스트 제로
```

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
| `brief.md` | orchestrator | 목표, 범위 경계, 인수 조건, 제외 항목 |
| `plan.md` | lead | 조사 결과 + 자기완결적 구현 명세 |
| `impl-report-devN.md` | dev | 변경 요약, 실행 명령, 원문 출력 |
| `review.md` | lead | diff 리뷰 지적사항 |
| `verdict.md` | verifier | PASS / FAIL / INCONCLUSIVE + 근거 |
| `summary.md` | lead | orchestrator에게 올리는 최종 보고 |

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

## Effort 배분

Effort는 직급순이 아니라 **(오류의 대가) ÷ (토큰 물량)** 으로 준다.

| 계층 | 모델 | effort | 이유 |
|---|---|---|---|
| orchestrator | `fable[1m]` | `xhigh` | 분해 결정은 레버리지가 가장 크지만, 릴레이·보드 갱신 같은 저부가 턴이 대부분이고 **사용자가 직접 기다리는** 유일한 계층이라 `max`는 세금이 된다 |
| lead-\* | `fable[1m]` | `xhigh` | 가장 어려운 사고를 한다 — 코드 조사, 설계, diff 리뷰. 컨텍스트 압박도 최대라 1M이 실제로 필요한 곳 |
| dev-\* | `opus[1m]` | `high` | 리드가 자기완결적 명세를 넘기므로 열린 추론보다 정밀한 실행에 가깝다. 150턴 × 3슬롯이라 **전체 wall-clock의 긴 다리**이기도 하다. Opus 5 자체 기본값도 `high` |
| verifier | `opus[1m]` | `max` | 40턴 읽기 전용이라 물량은 무시할 수준인데 실패 모드가 **false PASS** — 시스템 최악의 결과. 하네스에서 가장 값싼 품질 투자 |

dev가 미묘한 디버깅에서 막히면 올바른 대응은 Tier 3 effort를 올리는 게 아니라 **명세를 조이는
것**이다. 그게 이 구조의 전제다.

**모델 배치는 우연이 아니다.** 설계하는 계층(Fable)과 검증하는 계층(Opus)이 다른 패밀리라
오류가 탈상관된다 — Fable에 맹점이 있으면 또 다른 Fable보다 Opus가 잡을 확률이 높다.
덤으로 쿼터 풀도 둘로 분산된다.

단, [모델 가드](#모델-가드--fable-주간-한도-소진-시-자동-전환)가 fallback으로 넘어가면 Tier 1/2가
`opus[1m]`으로 내려가 설계와 검증이 같은 패밀리가 되고 이 탈상관이 사라진다. Fable 쿼터가
바닥난 상황이라 verifier를 Fable로 올릴 수도 없으므로, 그때 패밀리 분리를 유지하려면
verifier를 `sonnet[1m]`으로 돌리는 선택지가 있다 (아직 적용 안 함).

per-call effort 오버라이드는 없다 — Agent 도구는 `model`만 받고 `effort`는 frontmatter 고정이다.
그래서 "리드의 리뷰 단계만 max"는 불가능하고, 하려면 별도 reviewer 에이전트가 필요하다.
verifier가 `max`를 가지므로 중복이라 두지 않았다.

## 설계상의 강제 장치

프롬프트로 "하지 마라"고 쓰는 것보다 도구를 빼는 쪽이 확실하다:

- `orchestrator`, `lead-*` → `Edit` 제거. 직접 구현으로 흘러내리는 것을 구조적으로 차단.
- `dev-*` → `Agent` 제거. 리프 노드이므로 임의로 4계층을 만들지 못함.
- `verifier` → `Bash, Read, Grep, Glob`만. 검증자가 코드를 고치는 사고를 원천 차단.
- `maxTurns` — lead 200, dev 150, verifier 40. 무한 루프 방지.
- 라운드 상한 — lead는 구현→검증 3회, orchestrator는 작업당 실패 2회 후 사용자에게 에스컬레이션.

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
Tier 3(dev-\*, verifier)은 원래 Opus라 대상이 아니다.

```bash
orch-model-guard status      # 지금 뭐가 활성이고 왜 그런지 + 타이머/훅 상태
orch-model-guard check       # 즉시 1회 폴링 (타이머가 5분마다 하는 그것)
orch-model-guard set fallback / primary / auto     # 수동 고정(pin) 및 해제
```

판단 근거는 `claude -p /usage`의 `Current week (Fable)` 값이다 (모델 호출 없음, ~2초, 토큰 0).
임계값은 `model-policy.conf`에 있고, 경계에서 왔다 갔다 하지 않도록 두 개다 — `>=98%`면 내리고
`<=90%`면 올린다. 그 사이면 현재 상태를 유지한다. 100이 아니라 98인 이유: 100%가 곧 벽이고
가드는 5분마다만 보므로, 거기서 전환하면 몇 분치 거절을 그대로 맞는다.

**실행 중인 세션에 어디까지 닿는가** — 2.1.220에서 실측한 결과:

| 대상 | 자동 반영 | 근거 |
|---|---|---|
| `lead-*` (실행 중 세션 포함) | **된다** | `~/.claude/agents/lead-*.md`는 서브에이전트를 띄울 때마다 다시 읽힌다. 세션 도중 파일을 바꾸면 다음 스폰부터 새 모델로 뜬다. |
| 새로 띄우는 orchestrator | **된다** | `cc-orch`가 `orch-model-guard active`를 읽어 `--model`로 넘긴다. |
| **이미 돌고 있는 orchestrator 본인** | **안 된다** | 세션 자신의 모델은 프로세스 시작 시점에 고정된다. settings 파일도, agent 파일도, 훅도 바꾸지 못한다. |

그래서 마지막 칸은 사람이 한 번 눌러야 한다. `hooks/orch-model-notice.sh`가 그 순간을 놓치지
않게, 불일치 상태에서 프롬프트를 넣을 때마다 세션 안에서 알린다:

```
⚠️  모델 가드: Tier 1/2는 이제 opus[1m] 입니다.
    →  /model opus[1m]   를 입력하세요. (또는 세션 재시작: cc-orch <project>)
```

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

`agents/orchestrator.md`와 `agents/verifier.md`는 슬롯이 하나뿐이라 직접 편집하며, 심링크라
빌드 없이 바로 반영된다.

orch 세션 자체는 이 파일들을 못 고치도록 막혀 있으므로, 수정은 일반 `claude` 세션에서.

## 다른 머신에 배포

```bash
./sync-to.sh server4            # clone 또는 pull 후 install
./sync-to.sh server4 --check    # 원격 상태만 확인
```

원격이 같은 리포를 clone하므로 양쪽이 동일한 히스토리를 추적하고, 어느 쪽에서든 `git log`로
지금 돌아가는 버전을 알 수 있다. 원격에 `gh` 인증이 되어 있어야 하고(private repo),
`$HOME`이 다르면 스크립트가 거부한다 (`guardrails.json`이 절대 경로를 박아 쓰므로).

프롬프트를 고쳤으면: 커밋 → push → `./sync-to.sh server4`.

| 머신 | ssh 별칭 | claude |
|---|---|---|
| 로컬 | — | 2.1.197 |
| render (<internal-host>:2222) | `server4` (Windows에서는 `render`) | 2.1.220 |

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

- **에이전트 정의 파일은 스폰 때마다 다시 읽힌다.** 세션 도중 `~/.claude/agents/x.md`의 `model:`을
  바꾸고 다시 띄우면 새 모델로 뜬다 (haiku → sonnet으로 확인). 그래서 lead-\* 전환이 실행 중
  세션까지 닿는다.
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
