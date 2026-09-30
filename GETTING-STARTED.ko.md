# cc-orchestra 첫 사용 안내

## 0. 이 문서에서 얻는 것

설치 상태를 확인하고, 첫 작업을 요청하고, 진행과 결과를 찾는 순서를 안내한다.
예시 이름 `main`, `my-project`, `/path/to/project`는 자신의 세션 이름, 프로젝트 이름,
프로젝트 폴더 경로로 바꾼다. 이미 프로젝트의 Git 저장소가 있다고 가정한다.

## 1. cc-orchestra가 하는 일

cc-orchestra는 Claude Code와 Codex CLI가 한 코드 작업을 나눠 처리하도록 연결한다.
사용자는 Claude Code에 원하는 변경을 말한다. 첫 단계인 **Tier 1**이 요청 범위와
완료 조건을 정한다. **lead**는 그 작업의 계획과 결과를 책임지는 담당자다.
Codex가 조사·구현·검증에 참여한다. 완료 전 검증을 **gate**라고 부른다.
일반적인 혼합 모드 기준이며, Codex만 쓰는 방법은
[Codex 전용 모드](CODEX-ONLY.ko.md)를 참고한다.

## 2. 준비물

- [ ] Linux 서버 또는 PC, bash, Python 3, Git, tmux
- [ ] Claude 구독 계정과 로그인한 Claude Code
- [ ] 로그인한 Codex CLI
- [ ] 작업할 프로젝트 폴더. 아래 예시는 Git 저장소를 사용한다.

**tmux**는 SSH 연결이 끊겨도 서버의 터미널을 유지하는 도구다.
새 Linux 사용자나 서버부터 준비한다면 [부트스트랩 가이드](BOOTSTRAP.ko.md)를 따른다.
로그인 상태는 다음처럼 확인한다.

```bash
claude auth status
codex login status
```

## 3. 설치·확인

환경이 준비된 서버에서는 다음을 실행한다.

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

새 서버에서 도구와 로그인을 함께 준비하려면 저장소를 받은 뒤
`./install.sh --bootstrap`을 사용한다. 세부 순서는
[부트스트랩 가이드](BOOTSTRAP.ko.md#2-한-번에-부트스트랩)에 있다.
`--check`가 실패하면 출력된 누락 항목을 먼저 해결한다.

## 4. 첫 세션 시작

**세션**은 요청을 입력하고 다시 접속할 수 있는 작업 공간이다.
프로젝트 폴더 경로를 자신의 경로로 바꿔 실행한다.

```bash
cc-orch session new main /path/to/project --project-name my-project --inplace
```

이 명령은 관리 세션을 만들고 tmux 화면에 접속한다. `--inplace`는 세션의 기준 폴더로
기존 프로젝트 폴더를 쓴다. Tier 1이 배정한 개별 작업은 별도 작업 브랜치와 폴더에서
진행될 수 있다. 기본값처럼 `--inplace`를 빼면, Git 저장소에서 세션 자체도 새 브랜치와
**worktree**를 만든다. worktree는 같은 저장소를 다른 폴더에 펼친 것이다.
`cc-orch session path main`으로 세션의 실제 폴더를 확인할 수 있다.

| 다른 시작 방법 | 선택할 때 |
|---|---|
| `cc-orch my-project /path/to/project` | 관리 세션 없이 직접 한 번 실행할 때 |
| `cc-orch session new main /path/to/project --project-name my-project` | 별도 브랜치와 worktree에 세션을 둘 때. Git 저장소의 기본 방식 |
| 위 첫 예시의 `--inplace` | 세션의 기준 폴더를 기존 프로젝트 폴더로 둘 때 |
| `cc-orch-codex my-project /path/to/project` | Codex만 사용할 때. [별도 안내](CODEX-ONLY.ko.md) 참고 |

**Remote Control**은 다른 기기에서 같은 Claude Code 대화를 여는 기능이다.
혼합 모드에서는 기본으로 켜진다. 사용하지 않으려면
[운영 가이드의 직접 실행 설명](OPERATIONS.ko.md#직접-실행과-remote-control)을 참고한다.

## 5. 무엇을 입력하나

열린 Claude Code 입력창에 평소 말로 요청한다. 다음은 **예시 요청**이다.

> 프로젝트 README의 설치 확인 부분에 한 문장을 추가해 줘. 기존 설명을 유지하고,
> 바뀐 문장을 확인해 줘.

Tier 1은 필요한 경우 질문하거나 범위를 정한다. 작업의 목표와 완료 조건을
`brief.md`라는 파일에 적고 lead 자리를 배정한다. `brief`는 작업 지시의 짧은 기록이다.
Tier 1은 진행 중인 lead 자리를 표로 보여준다. 화면 문구와 작업 번호는 실제 요청에
따라 달라진다. lead가 계획, 구현, 검증을 진행한다.

## 6. 끝났는지 아는 법

lead의 최종 보고에서 `STATUS`, `BRANCH`, `WORKTREE`, `COMMITS`를 확인한다.
`STATUS: PASS`는 완료, `FAIL`과 `BLOCKED`는 실패 또는 진행 중단을 뜻한다.
해당 작업의 `.orchestra/<NN>-<slug>/summary.md`에서 최종 상태와 검증 내용을 읽는다.
`<NN>`은 작업 번호, `<slug>`는 짧은 작업 이름이다. 브랜치와 커밋은 보고에 적힌 것을
확인한다. `cc-orch session path main`은 세션의 기준 폴더만 보여준다. lead 작업은
`<repo>/.orchestra/wt/lead-<slot>` 같은 별도 worktree와 `orch/<NN>-<slug>` 브랜치에
있을 수 있다. 최종 보고의 `BRANCH`·`WORKTREE`, `.orchestra/REGISTRY.md`의 해당 행,
작업의 `summary.md`를 함께 확인한다. 작업 브랜치는 남으며,
사용자가 요청하기 전에는 기본 브랜치에 자동으로 병합되지 않는다.

## 7. 진행 확인

새 터미널에서도 다음 명령을 쓸 수 있다.

```bash
cc-orch session list
cc-orch session status main
cc-orch session path main
```

`status`는 세션의 실행 상태, 기준 폴더와 브랜치를 보여준다.
`path`도 세션의 기준 폴더만 보여준다. lead 작업은
`<repo>/.orchestra/wt/lead-<slot>` 같은 별도 worktree와 `orch/<NN>-<slug>` 브랜치에서
진행될 수 있다. lead 최종 보고의 `BRANCH`·`WORKTREE`, 프로젝트의
`.orchestra/REGISTRY.md` 행과 작업의 `summary.md`를 확인한다.
`REGISTRY.md`는 lead별 작업, 상태, 마지막 갱신을 적은 표다.
개별 작업 기록은 `.orchestra/<NN>-<slug>/`에 있다. 그 안의 `brief.md`는 목표,
`plan.md`는 설계, `summary.md`는 최종 결과를 담는다.

남은 모델 사용 한도에 따라 다음 호출을 배정하는 것을 **quota routing**이라고 한다.
상태를 확인하려면 다음을 실행한다.

```bash
orch-model-guard budget
orch-model-guard lanes
orch-usage-report --days 1
```

## 8. 중지·재개·전환

- tmux에서 `Ctrl-b` 다음 `d`를 누르면 대화는 계속 실행되고 화면에서만 빠져나온다.
- 다시 접속하려면 `cc-orch session attach main`을 실행한다.
- Claude Code 안에서 `/exit`를 입력하면 대화가 정상 종료된다.
- 세션을 멈추려면 `cc-orch session stop main`을 실행한다. 이 명령은 Claude에 `Ctrl-C`를
  보내고 약 1초 뒤 tmux 세션을 종료한다. 진행 중인 작업에는 사용하지 않는다.
  브랜치와 worktree는 남는다.
- 멈춘 세션은 `cc-orch session restart main`으로 다시 시작한다. 저장된 CLI 대화만 이어진다.
- Codex 쪽으로 넘겨야 하면 진행 중인 작업 상태를 먼저 확인하고
  `cc-orch session switch main --backend codex`를 사용한다. 되돌릴 때는
  `cc-orch session switch main --backend hybrid`를 사용한다. 전환은 파일 기록을
  넘기며 서로 다른 CLI의 대화 자체를 옮기지는 않는다.
- 더 이상 세션이 필요 없다면 `cc-orch session remove main`을 사용한다.
  먼저 세션을 멈추고 변경 파일을 확인한다. 브랜치는 남는다.

전체 명령은 [운영 가이드의 지속형 세션](OPERATIONS.ko.md#지속형-세션과-worktree)에 있다.

## 9. 막혔을 때

| 상황 | 확인할 것 |
|---|---|
| 설치 검사가 실패함 | `./install.sh --check` 출력과 [부트스트랩 검증 설명](BOOTSTRAP.ko.md#6-cc-orchestra-설치-검증) |
| 로그인 오류 | `claude auth status`, `codex login status` |
| tmux 화면이 사라짐 | `cc-orch session list` 후 실행 중이면 `cc-orch session attach main` |
| 세션이 정지됨 | `cc-orch session status main` 후 `cc-orch session restart main` |
| 변경 파일이 예상 폴더에 없음 | `cc-orch session path main`은 세션의 기준 폴더만 보여준다. lead 작업은 `<repo>/.orchestra/wt/lead-<slot>` 같은 별도 worktree와 `orch/<NN>-<slug>` 브랜치에 있을 수 있다. lead 최종 보고의 `BRANCH`·`WORKTREE`, `.orchestra/REGISTRY.md` 행과 작업의 `summary.md` 확인 |

더 자세한 점검은 [운영 가이드의 운영 명령](OPERATIONS.ko.md#자주-쓰는-운영-명령-요약)을 본다.

## 10. 안전 주의

- Git 저장소에서 관리 세션은 기본적으로 별도 브랜치와 worktree를 만든다.
  `--inplace`는 세션의 기준 폴더를 기존 폴더로 바꾼다. 작업 위치를 먼저 확인한다.
- `cc-orch session remove main --force`는 실행 중인 세션을 멈추고 변경 사항이 있는
  worktree도 제거할 수 있다. 필요한 파일을 확인한 뒤 사용한다.
- 직접 실행의 `--force-reload`는 `.orchestra/REGISTRY.md` 안전 검사만 건너뛴다.
  실행 중인 lead의 작업이 안전하게 끝났다는 뜻은 아니다.
- lead와 Tier 1은 작업 브랜치를 넘겨준다. 사용자가 요청하기 전에는 병합하지 않는다.
  세션 제거 후에도 브랜치는 남는다.

## 11. 용어집과 다음 문서

| 말 | 뜻 |
|---|---|
| Tier 1 | 요청의 범위와 작업 배정을 관리하는 첫 단계 |
| lead | 한 작업의 계획과 최종 결과를 책임지는 담당자 |
| brief | 목표·범위·완료 조건을 적은 `brief.md` |
| gate | 완료 전에 실행하는 검증 |
| worktree | 같은 Git 저장소를 별도 폴더에 둔 작업 공간 |
| quota routing | 남은 모델 사용 한도에 맞춰 다음 호출을 배정하는 방식 |
| tmux | SSH 접속이 끊겨도 터미널을 유지하는 프로그램 |
| Remote Control | 다른 기기에서 같은 Claude Code 대화를 여는 기능 |

다음에는 [운영 가이드](OPERATIONS.ko.md)에서 관리 명령을 자세히 볼 수 있다.
새 서버 설치는 [부트스트랩 가이드](BOOTSTRAP.ko.md), Codex만 쓰는 방법은
[Codex 전용 안내](CODEX-ONLY.ko.md)를 따른다. [README](README.md)로 돌아갈 수도 있다.
