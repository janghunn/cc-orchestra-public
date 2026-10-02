#!/usr/bin/env python3
"""Snapshot-limited, append-order Claude transcript normalization."""
import sys
sys.dont_write_bytecode = True

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path


@dataclass(frozen=True)
class FileRef:
    path: Path
    kind: str
    size_limit: int
    earliest_timestamp: str = ""
    mtime: float = 0

    @property
    def key(self):
        return hashlib.sha256(str(self.path.resolve()).encode()).hexdigest()[:16]


@dataclass
class Event:
    kind: str
    text: str = ""
    msg_key: str = ""
    uuid: str = ""
    tool_use_id: str = ""
    name: str = "?"
    input_text: str = ""
    is_error: bool = False
    nontext: int = 0
    copied: bool = False


def records(ref):
    """Never read beyond discovery's byte limit, including a partial final line."""
    with ref.path.open("rb") as stream:
        left = ref.size_limit
        while left:
            line = stream.readline(left)
            if not line:
                break
            left -= len(line)
            if not line.endswith(b"\n"):
                break
            try:
                record = json.loads(line)
                yield record if isinstance(record, dict) else None
            except (ValueError, UnicodeError, RecursionError):
                yield None


def discover(projects_dir):
    root = Path(projects_dir).absolute()
    if not root.is_dir() or any(p.is_symlink() for p in (root, *root.parents)):
        return []
    refs = []
    for pattern, kind in (("*/*.jsonl", "main"), ("*/*/subagents/*.jsonl", "subagent")):
        for path in sorted(root.glob(pattern)):
            if not path.is_file() or any(p.is_symlink() for p in (path, *path.parents)):
                continue
            info = path.stat()
            ref = FileRef(path, kind, info.st_size, mtime=info.st_mtime)
            earliest = min((r["timestamp"] for r in records(ref)
                            if r and isinstance(r.get("timestamp"), str)), default="")
            refs.append(FileRef(path, kind, info.st_size, earliest, info.st_mtime))
    return sorted(refs, key=lambda r: (r.earliest_timestamp, str(r.path)))


def string_leaves(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key in sorted(value):
            yield from string_leaves(value[key])
    elif isinstance(value, list):
        for child in value:
            yield from string_leaves(child)


def result_text(content):
    if isinstance(content, str):
        return content, 0
    if not isinstance(content, list):
        return "", int(content is not None)
    texts, nontext = [], 0
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text", ""))
        else:
            nontext += 1
    return "\n".join(t for t in texts if isinstance(t, str)), nontext


def load_events(fileref, seen_uuids):
    stats = dict(records=0, parse_errors=0, dup_records_in_file=0, dup_conflicts=0,
                 copied_records=0, files_skipped_copy=0, nontext_result_blocks=0,
                 excluded_records=0)
    events, fingerprints, file_uuids, tools = [], {}, set(), {}
    unidentified = False
    for ordinal, record in enumerate(records(fileref)):
        if record is None:
            stats["parse_errors"] += 1
            continue
        stats["records"] += 1
        uid = record.get("uuid", "")
        if uid:
            digest = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).digest()
            if uid in fingerprints:
                stats["dup_records_in_file"] += 1
                stats["dup_conflicts"] += int(fingerprints[uid] != digest)
                continue
            fingerprints[uid] = digest
        typ = record.get("type")
        copied = bool(uid and uid in seen_uuids)
        if typ in ("user", "assistant"):
            if uid:
                file_uuids.add(uid)
                stats["copied_records"] += int(copied)
            else:
                unidentified = True
        key = uid or f"record-{ordinal}"
        if typ == "system" and record.get("subtype") == "compact_boundary":
            events.append(Event("boundary", uuid=key))
            continue
        if typ not in ("user", "assistant"):
            continue
        if typ == "user" and any(record.get(flag) for flag in
                                  ("isMeta", "isCompactSummary", "isVisibleInTranscriptOnly")):
            stats["excluded_records"] += 1
            continue
        message = record.get("message", {})
        content = message.get("content", [])
        msg_key = "assistant:" + str(message.get("id") or key) if typ == "assistant" else "user:" + key
        base = dict(msg_key=msg_key, uuid=key, copied=copied)
        if isinstance(content, str):
            if typ == "user":
                events.append(Event("user_text", content, **base))
            continue
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            block_type = block.get("type")
            if block_type == "text":
                events.append(Event(typ + "_text", block.get("text", ""), **base))
            elif typ == "assistant" and block_type == "tool_use":
                tool_id = block.get("id", "")
                name = block.get("name", "?")
                text = "\n".join(string_leaves(block.get("input", {})))
                tools[tool_id] = (name, text)
                events.append(Event("tool_input", text, tool_use_id=tool_id, name=name, **base))
            elif typ == "user" and block_type == "tool_result":
                tool_id = block.get("tool_use_id", "")
                name, input_text = tools.get(tool_id, ("?", ""))
                text, nontext = result_text(block.get("content"))
                stats["nontext_result_blocks"] += nontext
                events.append(Event("result", text, tool_use_id=tool_id, name=name,
                                    input_text=input_text, nontext=nontext,
                                    is_error=bool(block.get("is_error")), **base))
    fully_copied = bool(file_uuids) and not unidentified and file_uuids <= seen_uuids
    seen_uuids.update(file_uuids)
    if fully_copied:
        stats["files_skipped_copy"] = 1
        # Report partial-copy overlap separately; full copies are excluded entirely.
        stats["copied_records"] = 0
        return [], stats
    return events, stats
