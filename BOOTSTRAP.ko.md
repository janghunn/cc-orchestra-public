# cc-orchestra 신규 서버 부트스트랩 가이드

이 문서는 **새 Linux 사용자/새 서버에서 cc-orchestra를 처음 설치하는 경우**를 위한 온보딩 절차다.

핵심 원칙은 다음과 같다.

```text
Linux 사용자 생성 + GitHub private repo clone   → 사용자가 1회 준비
그 이후 서버 환경 구성                          → ./install.sh --bootstrap
```

`--bootstrap`은 이미 설치된 프로그램은 건너뛰고, 빠진 항목만 순서대로 설치한다.

## 1. 부트스트랩 전에 사람이 해야 하는 것

### Linux 사용자 계정

서버 관리자가 필요한 사용자 계정을 만든다. 예:

```bash
sudo adduser janghun
sudo usermod -aG sudo janghun
```

SSH 공개키를 사용할 경우 새 사용자의 `~/.ssh/authorized_keys`도 준비한다.

사용자/권한 정책은 서버마다 다르므로 cc-orchestra가 root 권한으로 자동 생성하지 않는다.

### GitHub private repository 접근

cc-orchestra 저장소가 private이면 clone 전에 해당 Linux 사용자가 GitHub에 인증되어 있어야 한다.

권장 방식은 사용자별 SSH key다.

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"
cat ~/.ssh/id_ed25519.pub
```

공개키를 GitHub 계정의 SSH keys에 등록한 뒤 확인한다.

```bash
ssh -T git@github.com
```

그 다음 저장소를 clone한다.

```bash
cd ~
git clone git@github.com:janghunn/cc-orchestra.git
cd ~/cc-orchestra
git switch main
```

## 2. 한 번에 부트스트랩

clone 이후에는 다음 한 명령을 실행한다.

```bash
./install.sh --bootstrap
```

부트스트랩은 다음 순서로 진행된다.

```text
[1/6] System dependencies
      curl / tmux / git / python3 / ssh 확인
      없으면 apt-get, dnf, apk 중 사용 가능한 package manager로 설치

[2/6] PATH
      ~/.local/bin을 현재 shell PATH에 추가
      ~/.profile과 ~/.bashrc에도 영구 반영

[3/6] Provider CLIs
      Claude Code 확인 → 없으면 Anthropic native installer
      Codex CLI 확인   → 없으면 OpenAI standalone installer

[4/6] Provider authentication
      Claude 로그인 상태 확인 → 필요하면 공식 Claude login flow 실행
      Codex 로그인 상태 확인  → 필요하면 ChatGPT login flow 실행

[5/6] cc-orchestra install
      runtime facade / agents / hooks / quota taps / roster 설치

[6/6] Verification
      ./install.sh --check와 regression test suite 실행
```

패키지 설치가 필요하면 `sudo` 비밀번호를 물을 수 있다. OAuth 로그인은 provider의 공식 브라우저/device flow를 사용하며 cc-orchestra가 비밀번호나 토큰을 직접 저장하지 않는다.

## 3. 부트스트랩이 자동 설치하는 시스템 도구

다음 명령이 있는지 먼저 검사한다.

```text
curl
tmux
git
python3
ssh
```

하나라도 없으면 현재 Linux에서 다음 package manager를 순서대로 탐색한다.

```text
apt-get   Ubuntu / Debian
dnf       Fedora / RHEL 계열
apk       Alpine
```

이미 존재하는 도구는 재설치하지 않는다.

## 4. Claude Code

`claude`가 없으면 공식 native installer를 사용한다.

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

설치 후 `claude auth status`를 확인하고 로그인되어 있지 않으면 공식 login flow를 실행한다.

수동 확인:

```bash
claude --version
claude auth status
```

## 5. Codex CLI

`codex`가 없으면 공식 standalone installer를 사용한다.

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
```

설치 후 `codex login status`를 확인하고 로그인되어 있지 않으면 `codex login`을 실행한다.

수동 확인:

```bash
codex --version
codex login status
```

ChatGPT subscription quota를 사용할 경우 해당 ChatGPT 계정으로 로그인한다.

## 6. cc-orchestra 설치 검증

부트스트랩 마지막 단계에서 자동 실행되지만 수동으로 다시 확인할 수 있다.

```bash
./install.sh --check
```

정상 설치에서 중요한 항목:

```text
ok       structural policy hook in settings.json
ok       live runtime routing hook in settings.json
ok       Claude 5h/7d reset tap in settings.json
ok       tmux (...) — managed sessions enabled
ok       Claude Code (..., logged in)
ok       codex CLI (..., logged in)
```

처음에는 quota snapshot이 아직 없어서 다음처럼 보일 수 있다.

```text
budget   claude=unknown(...) codex=unknown(...)
```

Claude/Codex CLI가 실제 rate-limit 정보를 한 번 기록하면 `orch-model-guard budget`에 채워진다.

## 7. 선택 옵션

### 로그인 단계를 건너뛸 때

CI 이미지나 인증을 나중에 할 서버에서는:

```bash
./install.sh --bootstrap --skip-auth
```

### regression test를 생략할 때

```bash
./install.sh --bootstrap --skip-tests
```

둘 다 사용할 수도 있다.

```bash
./install.sh --bootstrap --skip-auth --skip-tests
```

## 8. 첫 managed session 시작

기존 checkout을 그대로 사용할 경우:

```bash
cc-orch session new main /path/to/project \
  --project-name my-project \
  --inplace
```

독립 branch/worktree를 자동 생성하려면 `--inplace`를 생략한다.

```bash
cc-orch session new feature-a /path/to/project \
  --project-name my-project
```

상태 확인:

```bash
cc-orch session list
orch-model-guard budget
```

다시 붙기:

```bash
cc-orch session attach main
```

서버가 재부팅되어 tmux process가 사라졌다면 registry/workdir이 남아 있는 한:

```bash
cc-orch session restart main
```

으로 마지막 Claude conversation을 이어서 시작한다.

## 9. 기존 설치 서버

이미 정상 사용 중인 서버는 `--bootstrap`을 다시 실행할 필요가 없다.

업데이트는 기존 방식으로 충분하다.

```bash
cd ~/cc-orchestra
git switch main
git pull --ff-only
./install.sh
./install.sh --check
```

`--bootstrap`은 **새 사용자 또는 새 서버의 최초 온보딩**을 단순화하기 위한 모드다.
