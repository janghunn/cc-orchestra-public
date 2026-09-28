# Codex 전용 모드와 혼합 모드 전환

Codex 전용 모드는 Tier 1 orchestrator, Tier 2 lead, Tier 3 worker, Tier 4 검증을
모두 Codex CLI의 `gpt-6-astra`로 실행한다. Claude CLI나 Claude 사용량 조회를 호출하지
않으며, Sol·Terra·Luna 또는 다른 provider로 자동 대체하지 않는다. Astra를 사용할 수
없으면 작업 기록을 보존하고 BLOCKED로 보고한다.

## 역할과 effort

정책의 원본은 [`codex-policy.json`](codex-policy.json)이다.

| 역할 | Astra effort |
| --- | --- |
| Orchestrator normal / critical / deep | high / xhigh / max |
| Lead light / normal / critical / deep | medium / xhigh / xhigh / max |
| Worker / 단순 기계적 작업 | xhigh / medium |
| 실행 검증 / 의미·회귀 리뷰 | high / xhigh |
| Critical 추가 독립 auditor | max |
| Intake / 조사 / 계획 리뷰 | medium / high / high |

기존 4개 lead 슬롯과 작업별 최대 2개 worker를 유지한다. 완료된 하위 스레드는 닫아
동시 스레드 한도 12개를 재사용한다. low/normal은 독립 verify와 review가 필요하며,
critical은 별도 Astra auditor까지 통과해야 한다. trivial은 구체적인 self-check를 기록한다.
같은 모델을 쓰더라도 검증·리뷰는 서로의 결과를 보지 않는 별도 문맥에서 실행한다.
대체 실행 경로인 `codex-run-codex`는 맡은 작업 하나만 수행하며 하위 agent 생성을 끈다.
작업 분해와 추가 위임은 native orchestrator/lead가 담당한다.

Lead는 승인된 작업을 gate와 `summary.md`까지 일상적인 재승인 질문 없이 완료한다.
Worker는 자신의 변경이 일으킨 실패를 범위 안에서 수정하고 해당 검사를 다시 실행한 뒤
실제 결과를 보고한다. Gate 실패는 상한 내 fix round로 처리하되, 필요한 결정으로 인한
`BLOCKED`, round 상한, provider의 quota/auth/timeout 실패, 파괴적·비가역적 작업은
기존 중단 규칙을 따른다. 진행을 막지 않는 질문은 나머지 작업을 마친 뒤 summary에 남긴다.

## 설치와 실행

Linux의 Bash, Python 3, Git과 로그인된 Codex CLI가 필요하다. 관리 세션은 tmux도 사용한다.
설정 로딩은 Codex CLI 0.153.2에서 확인했다. 구버전은 native subagent/config/hook 기능을
지원하지 않을 수 있다. 테스트는 Python 3.11 이상의 `tomllib`을 사용한다.

기존 혼합 모드 설치에 추가하려면:

```bash
./install.sh
cc-orch-codex my-project /path/to/repo
# 기존 cc-orch 진입점에서도 명시적으로 선택 가능
cc-orch --backend codex my-project /path/to/repo
```

Claude 없이 설치하고 `cc-orch`와 `codex-run`의 기본값도 Codex 전용으로 만들려면:

```bash
./install.sh --codex-only
cc-orch my-project /path/to/repo
```

`--codex-only` 설치는 Claude 설정·agent·기존 timer를 변경하지 않는다. 이미 다른 용도로
설치된 Claude timer가 있다면 그 timer의 동작까지 중단하는 옵션은 아니다. 일반 설치를
다시 실행하면 `cc-orch`/`codex-run`의 기본값은 혼합 모드로 돌아간다. 두 설치 모두
`cc-orch-codex`, `codex-run-codex`라는 명시적인 전용 진입점을 제공한다.
별도 실행 파일 디렉터리는 `CC_ORCH_BIN_DIR`로 지정할 수 있다.

```bash
# 모델 호출 없이 역할·실행 명령 확인
cc-orch-codex --dry-run my-project /path/to/repo
# 같은 Codex 대화 재개
cc-orch-codex --resume saved my-project /path/to/repo
# 한 번의 비대화형 요청: 실제 계정 사용량을 소비함
cc-orch-codex --exec --prompt '현재 작업 상태를 정리해줘' my-project /path/to/repo
```

`--resume saved`는 저장된 Codex session ID를 사용한다. 새 대화를 시작하면 이전 선택 ID를
비우고 새 ID가 보고될 때 저장한다. ID가 없는 대화형 실행은 Codex의
해당 디렉터리 세션 선택기를 연다. 이때 `--prompt`나 모드 전환 인계 요청이 있으면
경고를 표시하고 그 요청으로 새 대화를 시작한다. 비대화형 실행은 ID가 없으면 중단한다. 같은 이름을
다른 디렉터리에 재사용하거나 이미 실행 중인 이름을 중복 실행하면 거부한다.

## Claude 한도 회복 후 혼합 모드로 전환

전환은 **관리 세션 단위의 명시적 명령**이다. Claude 한도 회복을 확인한 다음 실행한다.
Codex 전용 모드에서 Claude 사용량을 주기적으로 조회하거나 자동으로 Claude를 시작하지 않는다.

```bash
# 처음 시작: 별도 Git worktree를 만들어 Codex 전용 세션 실행
cc-orch-codex session new work /path/to/repo --no-attach
cc-orch-codex session attach work

# Claude 사용량 한도 회복 후: 동일 worktree에서 Claude + Codex로 전환
cc-orch-codex session switch work --backend hybrid --no-attach
cc-orch-codex session attach work

# Claude 한도에 다시 도달하면 Codex 전용으로 복귀
cc-orch-codex session switch work --backend codex --no-attach
cc-orch-codex session status work
```

기존 작업 디렉터리를 그대로 사용하려면 `session new`에 `--inplace`를 붙인다.
`hybrid`는 기존 Claude orchestrator + Codex worker/gate 체계이며 상태 표시의 내부 이름은
`claude`다. 혼합 모드에는 Claude CLI 로그인과 일반 `./install.sh`로 설치한 Claude
orchestra agent들이 필요하다. 전용 설치만 한 새 환경에서는 먼저 이 구성을 준비한다.

전환 시 `.orchestra/BACKEND-HANDOFF.md`를 기록하고 해당 tmux 세션을 종료·재시작한다.
브랜치, 변경 파일, task artifact와 각 CLI의 대화 기록을 유지한다. 서로 다른 CLI의
대화 ID는 호환되지 않으므로 처음 전환할 때는 artifact를 읽어 인계받고, 같은 CLI로
돌아왔을 때 그 CLI의 문맥을 재개한다. 모델·effort 명시값도 CLI별로 복원한다.
작업 중인 lead가 REGISTRY에 있으면 기본적으로 전환을 거부한다. `--force`는 이 검사만
생략하므로 작업을 저장하고 하위 실행 상태를 확인한 경우에만 사용한다.

Codex 전용 진입점의 기본 상태 디렉터리는 `~/.local/state/cc-orchestra-codex`, 기존 혼합
진입점은 `~/.claude/orchestra-state`다. **세션을 만든 진입점으로 계속 관리한다.** 위 예제는
혼합 모드로 바꾼 뒤에도 `cc-orch-codex session`을 사용한다. 기존 `cc-orch session`으로
만든 세션은 `cc-orch session switch <name> --backend codex`로 전환한다. 기본 링크를
전용 설치로 바꿨다면 `CC_ORCH_STATE_DIR`에 기존 상태 디렉터리를 명시하면 된다.
일반 대화형 launcher는 tmux 관리 세션으로 자동 등록되지 않는다.

## 설정과 검증 범위

세션 생성·재시작·backend 전환 전에 npm `latest` 버전을 조회하고 새 버전이 있으면
업데이트 완료 후 실행한다. Hybrid는 Claude Code와 Codex, Codex-only는 Codex만 확인한다.
독립 CLI 실행과 Codex worker 실행에도 적용한다. 현재 PATH의 CLI가 같은 npm global
prefix에서 설치된 경우를 지원하며, 확인·업데이트 실패 시 구버전으로 실행하지 않는다.
동시 업데이트는 잠금으로 직렬화한다. `--dry-run`은 업데이트하지 않는다.
오프라인 재현/가짜 provider 테스트에만 `CC_ORCH_CLI_AUTO_UPDATE=0`으로 끌 수 있다.
이미 실행 중인 프로세스는 재시작 전까지 해당 실행 버전을 유지한다.

Codex 전용 모드는 기본적으로 `--dangerously-bypass-approvals-and-sandbox`로 실행한다.
Tier 1의 새 실행·resume·비대화형 실행과 독립 `codex-run-codex` lane에 모두 적용하며,
native 하위 역할도 `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`를
사용한다. CLI 실행 승인창과 샌드박스 격리를 생략하며, 프로세스는 현재 OS 사용자의
권한으로 실행된다. 작업 소유권·검증 역할·gate 규칙은 계속 적용된다.

이미 실행 중인 세션의 실행 인자는 자동으로 바뀌지 않는다. 적용하려면 해당 세션의
작업을 저장한 뒤 재시작한다. 아래 `work`는 자신이 만든 세션 이름으로 바꾼다.

```bash
cc-orch-codex session stop work
cc-orch-codex session restart work
```

역할 TOML과 manifest는 상태 디렉터리의 `codex-projects/<name>/roles/`에 생성된다.
사용자 `~/.codex/config.toml`과 프로젝트 `.codex` 파일은 수정하지 않는다. 실행별 설정에
역할과 native hook을 추가한다. 공식 문서상 기존 hook과 실행별 hook은 함께 로드된다.
새 hook은 CLI의 `/hooks`에서 내용을 검토하고 신뢰해야 동작할 수 있다. Hook 신뢰 검토는
실행 승인과 별개이며 자동으로 우회하지 않는다. 대화형 session ID 저장도 SessionStart hook에 의존한다.
Claude Remote Control 대신 tmux attach/SSH로 Codex 터미널에 접속한다.

`bash tests/test-codex-only.sh`는 가짜 provider와 tmux로 전용 설치, Astra 고정, resume,
gate 규칙, 전환·복귀·작업 보존을 검사하고 Claude 호출이 있으면 실패한다. 실제 모델의
하위 agent 실행 품질과 승인 UI까지 검증하는 end-to-end 실행과는 구분해야 한다.

설정 근거: [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[설정 참조](https://learn.chatgpt.com/docs/config-file/config-reference),
[native hooks와 신뢰](https://learn.chatgpt.com/docs/hooks).
