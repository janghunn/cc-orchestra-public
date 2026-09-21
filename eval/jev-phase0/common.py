#!/usr/bin/env python3
"""Shared paths, guarded artifact IO and historical-text helpers."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone


class OutOfTreeError(ValueError):
    pass


def state_dir():
    return Path(os.environ.get("CC_ORCH_STATE_DIR") or
                (Path.home() / ".claude/orchestra-state"))


def git_worktree_roots(start):
    def git(*args):
        result = subprocess.run(
            ["git", "-C", str(start), *args], capture_output=True,
            timeout=10, check=False,
        )
        return result.stdout if result.returncode == 0 else b""

    top = git("rev-parse", "--show-toplevel").decode(errors="replace").strip()
    if not top:
        return set()
    roots = {Path(top).resolve()}
    common = git("rev-parse", "--git-common-dir").decode(errors="replace").strip()
    if common:
        common_path = (Path(start) / common).resolve()
        if common_path.name == ".git":
            roots.add(common_path.parent)
    for field in git("worktree", "list", "--porcelain").split(b"\n"):
        if field.startswith(b"worktree "):
            roots.add(Path(os.fsdecode(field[9:])).resolve())
    return roots


def assert_out_of_tree(path):
    target = Path(os.path.realpath(path))
    # Discover both this checkout's siblings and any unrelated destination repo.
    ancestor = target.parent
    while not ancestor.exists() and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    roots = (git_worktree_roots(Path(__file__).parent) |
             git_worktree_roots(Path.cwd()) | git_worktree_roots(ancestor))
    for root in sorted(roots):
        if target == root or root in target.parents:
            raise OutOfTreeError(
                f"refusing to write inside the git work tree: {path} (under {root})")
    return target


def iter_task_dirs(root, *, seen=None, stats=None):
    seen = set() if seen is None else seen
    stats = {} if stats is None else stats
    try:
        children = sorted(Path(root).iterdir())
    except OSError:
        return
    for child in children:
        if child.name == "wt" or not (child / "brief.md").is_file():
            continue
        resolved = os.path.realpath(child)
        if resolved in seen:
            stats["realpath_collisions"] = stats.get("realpath_collisions", 0) + 1
            continue
        seen.add(resolved)
        yield child


def read_text(path):
    try:
        # Preserve CR: it is assignment whitespace to the Bash secret scanner,
        # not a line boundary. Universal newline conversion would change matches.
        with Path(path).open(encoding="utf-8", errors="replace", newline="") as stream:
            return stream.read()
    except OSError:
        return ""


def strip_fences(text):
    # Blank replacements preserve source line numbers; NUL fails closed.
    if "\0" in text:
        return ""
    fence, length = None, 0
    output = []
    for line in text.split("\n"):
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            run = match.group(1)
            if fence is None:
                fence, length = run[0], len(run)
                output.append("")
                continue
            if run[0] == fence and len(run) >= length and not line[match.end():].strip():
                fence = None
                output.append("")
                continue
        output.append(line if fence is None else "")
    return "\n".join(output)


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_jsonl(path):
    with Path(path).open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def write_jsonl(path, records):
    target = assert_out_of_tree(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
