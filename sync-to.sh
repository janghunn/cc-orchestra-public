#!/usr/bin/env bash
# Deploy or update this harness on another machine over ssh, via git.
#
#   ./sync-to.sh server4            # clone or pull, then install
#   ./sync-to.sh server4 --check    # just report the remote's state
#
# The remote clones the same private repo, so both machines track the same history and
# `git log` on either one tells you what version is running. The remote needs `gh` authorized
# (private repo) and $HOME=/home/janghun (guardrails.json pins absolute paths).
set -euo pipefail

TARGET="${1:-}"
MODE="${2:-install}"

if [[ -z "$TARGET" ]]; then
  echo "usage: $(basename "$0") <ssh-target> [--check]" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
REMOTE_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

if [[ -z "$REMOTE_URL" ]]; then
  echo "ERROR: this repo has no 'origin' remote yet — push it to GitHub first." >&2
  exit 1
fi

if [[ "$MODE" == "--check" ]]; then
  ssh "$TARGET" "bash -lc 'cd ~/$REPO_NAME 2>/dev/null && git log --oneline -1 && ./install.sh --check'" \
    || echo "not installed on $TARGET"
  exit 0
fi

echo "==> $TARGET"

remote_home="$(ssh "$TARGET" 'echo $HOME')"
if [[ "$remote_home" != "$HOME" ]]; then
  echo "ERROR: remote HOME is '$remote_home' but guardrails.json pins '$HOME'." >&2
  echo "       Edit the absolute paths in guardrails.json before deploying there." >&2
  exit 1
fi

# Warn rather than block — deploying a dirty tree is sometimes what you want, but it should
# never be a surprise that the remote got an older commit than what you are looking at.
if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
  echo "WARNING: local working tree is dirty; the remote will get the last pushed commit."
fi

ssh "$TARGET" "bash -lc '
  set -e
  if [ -d ~/$REPO_NAME/.git ]; then
    cd ~/$REPO_NAME && git pull --ff-only
  else
    git clone $REMOTE_URL ~/$REPO_NAME && cd ~/$REPO_NAME
  fi
  ./install.sh
'"

echo
echo "==> remote state:"
ssh "$TARGET" "bash -lc 'cd ~/$REPO_NAME && git log --oneline -1 && claude --version'"
