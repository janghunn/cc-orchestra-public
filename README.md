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
         ├── dev-1       Opus 5 @ xhigh     구현 개발자 — 구현, 테스트, 증거 기반 보고
         ├── dev-2                          Agent 도구 제거됨 (leaf, 재위임 불가)
         ├── dev-3
         └── verifier    Opus 5 @ xhigh     독립 검증자 — 읽기 전용, 컨텍스트 제로
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
       --model 'fable[1m]' \
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
