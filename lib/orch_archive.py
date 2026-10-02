"""Deterministic, copy-only local archive. Python standard library only."""
import sys
sys.dont_write_bytecode = True

import argparse
import collections
import contextlib
import copy
import datetime
import errno
import fcntl
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import zlib

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("orch_archive_secrets", REPO / "eval/jev-phase0/secrets.py")
_secrets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_secrets)
is_secret_shaped = _secrets.is_secret_shaped
scan_record = _secrets.scan_record
EXCLUDED = {".git", "__pycache__", "node_modules", ".venv", "venv"}
PATH_KEYS = {"VAULT_DIR", "RAW_DIR", "ALLOWLIST_FILE", "CLAUDE_PROJECTS_DIR", "CODEX_HOME_DIR"}
LIST_KEYS = {"STATE_DIRS", "EXTRA_BASES"}
EXT_KEYS = {"VAULT_TEXT_EXTENSIONS", "TEXT_EXTENSIONS", "APPEND_EXTENSIONS", "CHECKPOINT_EXTENSIONS"}
INT_KEYS = {"INCLUDE_CLAUDE_TRANSCRIPTS", "INCLUDE_CODEX_ROLLOUTS", "INCLUDE_PAYLOAD",
            "PAYLOAD_FILE_MAX_BYTES", "PAYLOAD_TASK_MAX_BYTES", "VAULT_TEXT_MAX_BYTES",
            "SIZE_REPORT_BYTES", "NESTED_ROOT_MAX_DEPTH", "GZIP_LEVEL", "COMMIT"}
OVERRIDES = {"VAULT_DIR": "VAULT", "RAW_DIR": "RAW", "ALLOWLIST_FILE": "ALLOWLIST",
             "STATE_DIRS": "STATE_DIRS", "CLAUDE_PROJECTS_DIR": "CLAUDE_PROJECTS",
             "CODEX_HOME_DIR": "CODEX_HOME", "EXTRA_BASES": "EXTRA_BASES"}
UUID = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
SNAPSHOT_DIR = r"artifacts/(?:tasks/[^/]+/[0-9a-f]{12}|roots/[^/]+/[0-9a-f]{12})"
COPIED_ARTIFACT_PATH = SNAPSHOT_DIR + r"/files/.+"
_WRITE_BASES = set()


class ArchiveError(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value, compact=False):
    options = {"separators": (",", ":")} if compact else {"indent": 2}
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, **options) + "\n").encode()


def under(path, base):
    return Path(path).resolve().is_relative_to(Path(base).resolve())


def expand(value):
    home = os.environ.get("HOME", str(Path.home()))
    value = value.replace("${HOME}", home).replace("$HOME", home)
    if value == "~" or value.startswith("~/"):
        value = home + value[1:]
    return str(Path(value).absolute())


def load_policy():
    values = {}
    # The source policy is authoritative, including defaults for a partial override file.
    paths = [REPO / "archive-policy.conf"]
    custom = os.environ.get("ORCH_ARCHIVE_POLICY")
    if custom and Path(custom).resolve() != paths[0].resolve():
        paths.append(Path(expand(custom)))
    for path in paths:
        for n, line in enumerate(path.read_text().splitlines(), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                raise ArchiveError(f"policy: invalid line {n}")
            key, value = (s.strip() for s in line.split("=", 1))
            if key not in PATH_KEYS | LIST_KEYS | EXT_KEYS | INT_KEYS:
                raise ArchiveError(f"policy: unknown key {key}")
            if value.startswith('"'):
                if not value.endswith('"'):
                    raise ArchiveError(f"policy: invalid quoting at line {n}")
                value = value[1:-1]
            values[key] = value
    for key, env in OVERRIDES.items():
        if "ORCH_ARCHIVE_" + env in os.environ:
            values[key] = os.environ["ORCH_ARCHIVE_" + env]
        elif key == "CODEX_HOME_DIR" and os.environ.get("CODEX_HOME"):
            values[key] = os.environ["CODEX_HOME"]
    for key in PATH_KEYS:
        values[key] = Path(expand(values[key])).resolve()
    for key in LIST_KEYS:
        values[key] = sorted({Path(expand(v)).resolve() for v in values[key].split(":") if v})
    for key in EXT_KEYS:
        values[key] = set(values[key].split())
    values["CHECKPOINT_EXTENSIONS"] = {ext.lower() for ext in values["CHECKPOINT_EXTENSIONS"]}
    for key in INT_KEYS:
        try:
            values[key] = int(values[key])
        except ValueError:
            raise ArchiveError(f"policy: {key} must be an integer") from None
        if values[key] < 0:
            raise ArchiveError(f"policy: {key} must be nonnegative")
    if values["GZIP_LEVEL"] > 9:
        raise ArchiveError("policy: GZIP_LEVEL must be 0..9")
    for key in {"INCLUDE_CLAUDE_TRANSCRIPTS", "INCLUDE_CODEX_ROLLOUTS", "INCLUDE_PAYLOAD", "COMMIT"}:
        if values[key] not in (0, 1):
            raise ArchiveError(f"policy: {key} must be 0 or 1")
    if under(values["VAULT_DIR"], values["RAW_DIR"]) or under(values["RAW_DIR"], values["VAULT_DIR"]):
        raise ArchiveError("policy: vault and raw directories overlap")
    return values


def _write_atomic(base, rel, data):
    """The sole archive file writer; rejects symlink escapes and preserves equal files."""
    base = Path(base).resolve()
    if base not in _WRITE_BASES:
        raise ArchiveError("write base is not the configured vault or raw directory")
    target = base / rel
    if not under(target, base) or target.resolve() == base:
        raise ArchiveError("write target escapes archive directory")
    if target.is_symlink():
        raise ArchiveError("write target is a symlink")
    equal = False
    if target.exists() and isinstance(data, bytes):
        equal = target.read_bytes() == data
    elif target.exists() and isinstance(data, PackedFile):
        equal = same_bytes(target, data.path)
    elif target.exists() and isinstance(data, (Document, VaultFile)):
        equal = target.stat().st_size == len(data) and VaultFile(target).digest() == data.digest()
    if equal:
        os.chmod(target, 0o600)
        return False
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Resolve again after mkdir; pre-existing directory symlinks must stay inside base.
    if not under(target, base):
        raise ArchiveError("write target escapes archive directory")
    fd, temporary = tempfile.mkstemp(prefix=".archive-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            if callable(data):
                data(stream)
            elif isinstance(data, PackedFile):
                with open(data.path, "rb") as packed:
                    while True:
                        chunk = packed.read(1024 * 1024)
                        if not chunk:
                            break
                        stream.write(chunk)
            else:
                stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if target.exists() and same_bytes(Path(temporary), target):
            os.chmod(target, 0o600)
            return False
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def same_bytes(left, right):
    if left.stat().st_size != right.stat().st_size:
        return False
    with open(left, "rb") as first, open(right, "rb") as second:
        while True:
            chunk = first.read(1024 * 1024)
            if chunk != second.read(1024 * 1024):
                return False
            if not chunk:
                return True


class PackedFile:
    """An apply capture's compressed temporary file, owned solely by this run."""
    def __init__(self, path):
        self.path = path
        self.length = path.stat().st_size

    def __len__(self):
        return self.length

    def close(self):
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    def __del__(self):
        try:
            self.close()
        except OSError:
            pass


def _after_stat(path):
    """Test seam for concurrent appends; called before the bounded source read."""


class CountingSink:
    """Discard compressed dry-run bytes while retaining the exact encoded size."""
    def __init__(self):
        self.length = 0

    def write(self, data):
        self.length += len(data)
        return len(data)

    def flush(self):
        pass

    def __len__(self):
        return self.length


def capture(path, level=6, keep=False, opened=None, counting=False, raw_dir=None):
    """One bounded read, streaming simultaneously into SHA-256 and deterministic gzip."""
    st = os.stat(path, follow_symlinks=False) if opened is None else opened[0]
    if not stat.S_ISREG(st.st_mode):
        raise OSError(errno.EINVAL, "not a regular source")
    if opened is None:
        _after_stat(path)
    digest = hashlib.sha256()
    packed = CountingSink() if counting else io.BytesIO() if raw_dir is None else None
    pieces = [] if keep else None
    remaining = st.st_size
    with contextlib.ExitStack() as stack:
        source = stack.enter_context(open(path, "rb")) if opened is None else opened[1]
        initial = b"" if opened is None else opened[2]
        def compress_into(sink):
            nonlocal initial, remaining
            with gzip.GzipFile(fileobj=sink, mode="wb", filename="", mtime=0, compresslevel=level) as gz:
                while remaining:
                    part = initial if initial else source.read(min(1024 * 1024, remaining))
                    initial = b""
                    if not part:
                        break
                    part = part[:remaining]
                    digest.update(part)
                    gz.write(part)
                    if pieces is not None:
                        pieces.append(part)
                    remaining -= len(part)
        if raw_dir is None:
            compress_into(packed)
        else:
            # Re-captures may coexist with a previously returned PackedFile.
            # Temporary names do not enter gzip headers or archive pointers.
            rel = ".capture-" + sha(str(path).encode())[:24] + "-" + str(os.getpid()) + "-" + os.urandom(8).hex() + ".gz"
            _write_atomic(raw_dir, rel, compress_into)
            packed = PackedFile(Path(raw_dir) / rel)
    return {"stat": st, "length": st.st_size - remaining, "sha256": digest.hexdigest(),
            "gzip": packed if counting or raw_dir is not None else packed.getvalue(), "data": b"".join(pieces) if keep else None}


class Document:
    """Compact JSON parts; stream scans/writes without joining a large manifest."""
    def __init__(self, *parts):
        self.parts = parts

    def __len__(self):
        return sum(map(len, self.parts))

    def __call__(self, stream):
        for part in self.parts:
            stream.write(part)

    def digest(self):
        digest = hashlib.sha256()
        for part in self.parts:
            digest.update(part)
        return digest.hexdigest()

    def lines(self):
        for part in self.parts:
            yield from byte_lines(part)


class VaultFile:
    """Stream an existing archive file for hashing and byte comparisons."""
    def __init__(self, path):
        self.path = path

    def __len__(self):
        return self.path.stat().st_size

    def __call__(self, stream):
        with self.path.open("rb") as source:
            shutil.copyfileobj(source, stream, 1024 * 1024)

    def digest(self):
        digest = hashlib.sha256()
        with self.path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def lines(self):
        with self.path.open("rb") as source:
            yield from source


class Artifact:
    """Only lengths/pointers in plan; apply restores the bounded copy from raw blobs."""
    def __init__(self, root, pointers, length, digest):
        self.root, self.pointers, self.length, self.sha256 = root, pointers, length, digest

    def __len__(self):
        return self.length

    def materialize(self):
        parts = []
        offset = 0
        for pointer in self.pointers:
            path = self.root / pointer["blob"]
            if not under(path, self.root) or pointer["offset"] != offset:
                raise ArchiveError("artifact raw pointer escapes store or has invalid offset")
            with gzip.open(path, "rb") as source:
                data = source.read(pointer["length"] + 1)
            if len(data) != pointer["length"] or sha(data) != pointer["sha256"]:
                raise ArchiveError("artifact raw blob hash or length mismatch", 1)
            parts.append(data)
            offset += len(data)
        data = b"".join(parts)
        if len(data) != self.length or sha(data) != self.sha256:
            raise ArchiveError("artifact raw content hash or length mismatch", 1)
        return data


def byte_lines(data):
    start = 0
    while start < len(data):
        end = data.find(b"\n", start)
        end = len(data) if end < 0 else end + 1
        yield data[start:end]
        start = end


def data_sha(data):
    return sha(data) if isinstance(data, bytes) else data.digest()


class Samples:
    """Exact skip counts with only the requested, deterministically ordered details."""
    def __init__(self, top, guard):
        self.top, self.guard = top, guard
        self.counts, self.items = collections.Counter(), []

    def append(self, item):
        self.counts[item["reason"]] += 1
        # Unreported details never become vault-bound strings.
        key = lambda row: (row["reason"], row["path"])
        if self.top and (len(self.items) < self.top or key(item) < key(self.items[-1])):
            self.items.append(self.guard.tree(item, "report", "skipped"))
            self.items.sort(key=key)
            del self.items[self.top:]


class SourceErrors:
    """One error per source; the report bounds guarded diagnostics."""
    def __init__(self, guard):
        self.guard = guard
        self.failed = {}

    def record(self, path, error):
        key = str(path)
        if key not in self.failed:
            self.failed[key] = {"path": self.guard.value(key, "report", "source-error", "path"),
                                "reason": "vanished" if error.errno == errno.ENOENT else "unreadable",
                                "errno": error.errno}
        return self.failed[key]

    def report(self, top):
        return {"count": len(self.failed), "items": sorted(self.failed.values(), key=lambda row: row["path"])[:top]}


class Guard:
    def __init__(self, policy):
        self.allow = set()
        self.released = set()
        self.items = {}
        self.source_errors = SourceErrors(self)
        path = policy["ALLOWLIST_FILE"]
        if path.exists():
            for line in path.read_text().splitlines():
                entry = line.split("#", 1)[0].strip()
                if entry:
                    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", entry):
                        raise ArchiveError("allow-list: expected sha256:<64 hex>")
                    self.allow.add(entry[7:].lower())

    def value(self, value, owner="unknown", context="field", kind="field"):
        if not isinstance(value, str):
            return value
        digest = sha(value.encode())
        lines = [i for i, line in enumerate(value.split("\n"), 1) if is_secret_shaped(line)]
        if lines and digest not in self.allow:
            key = (digest, kind, owner, context)
            # Diagnostics are themselves guarded, without exposing matched content.
            safe = lambda s: "[withheld:" + sha(str(s).encode())[:12] + "]" if scan_record(str(s))[0] else str(s)
            self.items[key] = {"id": digest[:12], "kind": kind, "owner": safe(owner),
                               "context": safe(context), "lines": lines, "sha256": digest}
            return "[withheld:" + digest[:12] + "]"
        if lines:
            self.released.add(value)
            self.released.add(json.dumps(value, ensure_ascii=False)[1:-1])
            self.released.add(json.dumps(value, ensure_ascii=True)[1:-1])
        return value

    def tree(self, value, owner="unknown", context="field"):
        if isinstance(value, dict):
            return {self.value(k, owner, context, "path"): self.tree(v, owner, context + "/" + str(k))
                    for k, v in value.items()}
        if isinstance(value, list):
            return [self.tree(v, owner, context) for v in value]
        return self.value(value, owner, context)

    def seed_released(self, value):
        """Restore explicit releases from retained catalog strings, including keys."""
        if isinstance(value, dict):
            for key, item in value.items():
                self.seed_released(key)
                self.seed_released(item)
        elif isinstance(value, list):
            for item in value:
                self.seed_released(item)
        elif isinstance(value, str) and sha(value.encode()) in self.allow:
            self.value(value)

    def file(self, data, owner, rel):
        text = data.decode("utf-8")
        return self.value(text, owner, rel, "artifact") != text

    def check(self, data, path, artifact=False):
        # Each complete line passes scan_record immediately before the writer.
        # Only values actually released by this Guard can exempt metadata lines.
        if artifact and sha(data) in self.allow:
            return
        lines = byte_lines(data) if isinstance(data, bytes) else data.lines()
        for n, line in enumerate(lines, 1):
            text = line.decode("utf-8")
            if scan_record(text)[0] and not any(value in text for value in self.released):
                raise ArchiveError(f"secret guard: {self.value(path)}:{n}", 1)


    def identifier(self, value, context, slugify=True):
        guarded = self.value(value, context, "id", "path")
        if guarded != value:
            return "withheld-" + sha(value.encode())[:12]
        if slugify:
            return slug(value)
        # Preserve case and ordinary historical ids; escape only path/link delimiters.
        safe = re.sub(r"[\\/\[\]|#\x00-\x1f]", "-", value)
        return safe if safe not in {"", ".", ".."} else "unknown-" + sha(value.encode())[:12]


def slug(value):
    return re.sub(r"[^a-z0-9._-]", "-", value.lower()).strip("-.") or "unknown"


class SourceEntry:
    """DirEntry predicates can fail too; report them without aborting discovery."""
    def __init__(self, entry, errors):
        self.entry, self.errors = entry, errors
        self.name, self.path = entry.name, entry.path

    def _test(self, method, **kwargs):
        try:
            return getattr(self.entry, method)(**kwargs)
        except OSError as error:
            self.errors.record(self.path, error)
            return False

    def is_dir(self, **kwargs):
        return self._test("is_dir", **kwargs)

    def is_file(self, **kwargs):
        return self._test("is_file", **kwargs)

    def is_symlink(self):
        return self._test("is_symlink")


def entries(path, errors=None, optional=False):
    try:
        with os.scandir(path) as scan:
            result = sorted(scan, key=lambda e: e.name)
            return [SourceEntry(entry, errors) for entry in result] if errors else result
    except OSError as error:
        if errors and not (optional and error.errno == errno.ENOENT):
            errors.record(path, error)
        return []


def source_test(path, method, errors=None):
    try:
        return getattr(path, method)()
    except OSError as error:
        if errors:
            errors.record(path, error)
        return False


def walk(path, skipped=None, skip_nested=False, errors=None, optional=False):
    """Yield regular files, links and specials; never descend directory symlinks."""
    try:
        with os.scandir(path) as scan:
            children = list(scan)
        if errors:
            children = [SourceEntry(entry, errors) for entry in children]
        children.sort(key=lambda entry: entry.name + ("/" if entry.is_dir(follow_symlinks=False) else ""))
    except OSError as error:
        if errors and not (optional and error.errno == errno.ENOENT):
            errors.record(path, error)
        elif skipped is not None:
            skipped.append({"path": str(path), "reason": "unreadable", "errno": error.errno})
        return
    for entry in children:
        if entry.name in EXCLUDED or (skip_nested and entry.name == ".orchestra" and entry.is_dir(follow_symlinks=False)):
            if skipped is not None:
                skipped.append({"path": entry.path, "reason": "excluded dir"})
            continue
        try:
            if entry.is_dir(follow_symlinks=False):
                yield from walk(entry.path, skipped, skip_nested=skip_nested, errors=errors)
            else:
                yield Path(entry.path)
        except OSError:
            yield Path(entry.path)


def byte_total(path, errors=None):
    total = 0
    for file in walk(path, errors=errors):
        try:
            st = file.lstat()
            if stat.S_ISREG(st.st_mode):
                total += st.st_size
        except OSError as error:
            if errors:
                errors.record(file, error)
    return total


def ansi_decode(value):
    if not (value.startswith("$'") and value.endswith("'")):
        raise ValueError("bad ANSI-C quoting")
    body, out, i = value[2:-1], [], 0
    escapes = {"n": "\n", "t": "\t", "\\": "\\", "'": "'", "r": "\r", "a": "\a", "b": "\b", "v": "\v", "f": "\f"}
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            if ch == "'":
                raise ValueError("unescaped quote")
            out.append(ch)
            i += 1
            continue
        i += 1
        if i == len(body):
            raise ValueError("trailing escape")
        ch = body[i]
        if ch in escapes:
            out.append(escapes[ch])
            i += 1
        elif ch == "x":
            match = re.match(r"[0-9a-fA-F]{2}", body[i + 1:])
            if not match:
                raise ValueError("bad hex escape")
            out.append(chr(int(match[0], 16)))
            i += 3
        elif ch in "01234567":
            match = re.match(r"[0-7]{1,3}", body[i:])
            out.append(chr(int(match[0], 8)))
            i += len(match[0])
        else:
            raise ValueError("unknown escape")
    return "".join(out)


def parse_conf(path, source_errors=None):
    result, errors = {}, []
    try:
        text = path.read_text()
    except OSError as error:
        if source_errors:
            source_errors.record(path, error)
        return None, []
    except UnicodeError:
        return {}, [{"source": str(path), "line": 0}]
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            key, value = line.split("=", 1)
            if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or key in result:
                raise ValueError("invalid or duplicate key")
            if value.startswith("$'"):
                decoded = ansi_decode(value)
            else:
                tokens = shlex.split(value, posix=True)
                if len(tokens) > 1:
                    raise ValueError("multiple tokens")
                if not tokens and value.strip():
                    raise ValueError("invalid value")
                decoded = tokens[0] if tokens else ""
            result[key] = decoded
        except ValueError:
            errors.append({"source": str(path), "line": n})
    return result, errors


class Discovery:
    def __init__(self, policy, guard):
        self.p, self.guard = policy, guard
        self.sessions, self.bases, self.roots = {}, {}, {}
        self.skipped = []
        self.errors = guard.source_errors

    def session(self, name, fields, path, kind, backend, errors=None):
        sid = self.guard.identifier(name, "session", slugify=False)
        record = self.sessions.setdefault(sid, {"id": sid, "fields": {}, "sources": [],
                                                "parse_error": [], "backend": backend,
                                                "backend_source": "inferred", "bases": [], "thread_ids": []})
        record["fields"].update(fields)
        record["sources"].append({"path": str(path), "kind": kind})
        record["parse_error"].extend(errors or [])
        if fields.get("BACKEND"):
            record.update(backend=fields["BACKEND"], backend_source="conf")
        for key in ("REPO", "WORKDIR", "dir", "directory"):
            if isinstance(fields.get(key), str) and fields[key]:
                base = Path(expand(fields[key])).resolve()
                if str(base) not in record["bases"]:
                    record["bases"].append(str(base))
                project = fields.get("PROJECT_NAME")
                if not isinstance(project, str) or not project:
                    project = "home" if base == Path(expand("~")).resolve() else Path(fields.get("REPO") or str(base)).name
                self.bases.setdefault(base, []).append((sid, project))
        if isinstance(fields.get("session_id"), str) and fields["session_id"]:
            record["thread_ids"].append(fields["session_id"].lower())

    def run(self):
        for state_dir in self.p["STATE_DIRS"]:
            backend = "codex" if "codex" in str(state_dir) else "claude"
            for entry in entries(state_dir / "sessions", self.errors, optional=True):
                if entry.name.endswith(".conf") and entry.is_file(follow_symlinks=False):
                    path = Path(entry.path)
                    fields, errors = parse_conf(path, self.errors)
                    if fields is None:
                        continue
                    name = fields.get("LAUNCH_NAME") or ((fields.get("PROJECT_NAME") or Path(fields.get("REPO", "unknown")).name)
                                                               + "-" + fields.get("NAME", path.stem))
                    self.session(name, fields, path, "conf", backend, errors)
            for entry in entries(state_dir / "projects", self.errors, optional=True):
                if entry.is_file(follow_symlinks=False):
                    path = Path(entry.path)
                    fields = {}
                    try:
                        for line in path.read_text().splitlines():
                            if "=" in line:
                                key, value = line.split("=", 1)
                                fields[key] = value
                    except OSError as error:
                        self.errors.record(path, error)
                        continue
                    except UnicodeError:
                        self.skipped.append({"path": str(path), "reason": "unreadable"})
                    self.session(entry.name, fields, path, "record", backend)
            for entry in entries(state_dir / "codex-projects", self.errors, optional=True):
                path = Path(entry.path) / "project.json"
                if entry.is_dir(follow_symlinks=False) and source_test(path, "is_file", self.errors) and not source_test(path, "is_symlink", self.errors):
                    try:
                        fields = json.loads(path.read_text())
                        if not isinstance(fields, dict):
                            raise ValueError()
                        self.session(entry.name, fields, path, "codex project", "codex")
                    except OSError as error:
                        self.errors.record(path, error)
                    except (ValueError, UnicodeError):
                        self.session(entry.name, {}, path, "codex project", "codex", [{"source": str(path), "line": 1}])
            for project in entries(state_dir / "worktrees", self.errors, optional=True):
                if project.is_dir(follow_symlinks=False):
                    for checkout in entries(project.path, self.errors):
                        if checkout.is_dir(follow_symlinks=False):
                            self.bases.setdefault(Path(checkout.path).resolve(), []).append((None, project.name))
        for base in self.p["EXTRA_BASES"]:
            self.bases.setdefault(base, [])
        for base in sorted(self.bases):
            if not source_test(base, "is_dir", self.errors) or source_test(base, "is_symlink", self.errors):
                self.skipped.append({"path": str(base), "reason": "base missing"})
                continue
            root = base / ".orchestra"
            if source_test(root, "is_dir", self.errors) and not source_test(root, "is_symlink", self.errors):
                self.add_root(root, "direct")
                self.nested(root, 0)
        # Reject destination overlap before locks, directories or archive writes.
        source_roots = list(self.roots) + self.p["STATE_DIRS"] + [self.p["CLAUDE_PROJECTS_DIR"], self.p["CODEX_HOME_DIR"]]
        for destination in (self.p["VAULT_DIR"], self.p["RAW_DIR"]):
            if any(under(destination, root) for root in source_roots):
                raise ArchiveError("policy: archive destination is inside a source root")
        return self

    def project(self, root):
        for state_dir in self.p["STATE_DIRS"]:
            prefix = state_dir / "worktrees"
            if under(root, prefix):
                rel = root.relative_to(prefix)
                if rel.parts:
                    return self.guard.identifier(rel.parts[0], "project")
        ancestors = [(len(base.parts), str(base), owners) for base, owners in self.bases.items() if under(root, base) and owners]
        if ancestors:
            _, nearest, owners = sorted(ancestors, key=lambda row: (-row[0], row[1]))[0]
            if Path(nearest) == Path(expand("~")).resolve():
                return "home"
            return self.guard.identifier(sorted(owners, key=lambda o: (o[0] or "", o[1]))[0][1], "project")
        parent = root.parent
        name = "home" if parent == Path(expand("~")).resolve() else parent.name
        return self.guard.identifier(name, "project")

    def add_root(self, root, kind):
        root = root.resolve()
        self.roots.setdefault(root, {"path": str(root), "project": self.project(root), "kind": kind})

    @staticmethod
    def task_dir(path, errors=None):
        documents = any(source_test(path / name, "is_file", errors) and not source_test(path / name, "is_symlink", errors)
                        for name in ("brief.md", "summary.md", "plan.md"))
        return documents or (bool(re.match(r"^\d+[-_]", path.name)) and not Discovery.container(path, errors=errors))

    def nested(self, directory, depth):
        if depth >= self.p["NESTED_ROOT_MAX_DEPTH"]:
            return
        for entry in entries(directory, self.errors):
            if entry.name in EXCLUDED or not entry.is_dir(follow_symlinks=False):
                continue
            path = Path(entry.path)
            if entry.name == ".orchestra":
                self.add_root(path, "nested")
                self.nested(path, 0)
            # Numeric container names alone must not hide historical roots.
            # Direct root children use task_dir()'s task/container classification.
            elif not any(source_test(path / name, "is_file", self.errors) and not source_test(path / name, "is_symlink", self.errors)
                         for name in ("brief.md", "summary.md", "plan.md")):
                self.nested(path, depth + 1)

    @staticmethod
    def container(path, depth=0, errors=None):
        if path.name == "wt" or source_test(path / ".git", "exists", errors):
            return True
        if depth >= 3:
            return False
        for entry in entries(path, errors):
            if entry.name in EXCLUDED or not entry.is_dir(follow_symlinks=False):
                continue
            if entry.name == ".orchestra" or Discovery.container(Path(entry.path), depth + 1, errors):
                return True
        return False


class RawStore:
    def __init__(self, policy, apply, guard):
        self.p, self.apply, self.guard = policy, apply, guard
        self.root = policy["RAW_DIR"]
        self.new_blobs = 0
        self.stats = {kind: {"before": 0, "after": 0, "blobs": 0} for kind in ("task-files", "withheld", "transcripts", "rollouts", "manifests")}
        self.seen = set()
        self.cache = {}

    def blob(self, data, category, packed=None, digest=None, length=None):
        digest = digest or data_sha(data)
        length = len(data) if length is None else length
        rel = f"blobs/{digest[:2]}/{digest}.gz"
        if digest not in self.seen:
            if packed is None:
                # GzipFile consistently omits both a filename and platform-dependent OS byte.
                buf = io.BytesIO() if self.apply else CountingSink()
                with gzip.GzipFile(fileobj=buf, mode="wb", filename="", mtime=0, compresslevel=self.p["GZIP_LEVEL"]) as gz:
                    if callable(data):
                        data(gz)
                    else:
                        gz.write(data)
                packed = buf.getvalue() if self.apply else buf
            self.stats[category]["before"] += length
            self.stats[category]["after"] += len(packed)
            self.stats[category]["blobs"] += 1
            self.seen.add(digest)
            if not (self.root / rel).exists():
                self.new_blobs += 1
                if self.apply:
                    _write_atomic(self.root, rel, packed)
        return {"length": length, "sha256": digest, "blob": rel}

    def existing(self, pointer, category):
        digest = pointer["sha256"]
        if digest not in self.seen:
            path = self.root / pointer["blob"]
            self.stats[category]["before"] += pointer["length"]
            self.stats[category]["after"] += path.stat().st_size
            self.stats[category]["blobs"] += 1
            self.seen.add(digest)

    def archive(self, path, category, captured=None, opened=None):
        try:
            return self._archive(path, category, captured, opened)
        except OSError as error:
            self.guard.source_errors.record(path, error)
            return None

    def _archive(self, path, category, captured=None, opened=None):
        path = Path(path)
        key = str(path.resolve())
        if key in self.cache:
            return self.cache[key]
        rel = "sources/" + sha(key.encode())[:24] + ".json"
        source = {"path": key, "kind": category, "generations": []}
        if (self.root / rel).exists():
            source = json.loads((self.root / rel).read_text())
        st = captured["stat"] if captured else os.stat(path, follow_symlinks=False)
        previous = source["generations"][-1] if source["generations"] else None
        signature = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        if previous and tuple(previous[k] for k in ("dev", "inode", "size_seen", "mtime_ns")) == signature:
            for pointer in previous["chunks"] + ([previous["tail"]] if previous.get("tail") else []):
                self.existing(pointer, category)
        else:
            append = path.suffix.lower() in self.p["APPEND_EXTENSIONS"]
            cap = captured or capture(path, self.p["GZIP_LEVEL"], keep=append, opened=opened, counting=not self.apply,
                                      raw_dir=self.root if self.apply else None)
            data = cap["data"]
            if append:
                end = data.rfind(b"\n") + 1
                prefix_len = sum(c["length"] for c in previous["chunks"]) if previous else 0
                extend = bool(previous and previous["dev"] == st.st_dev and previous["inode"] == st.st_ino
                              and end >= prefix_len and sha(data[:prefix_len]) == previous["prefix_sha256"])
                generation = copy.deepcopy(previous) if extend else {"chunks": []}
                if not extend:
                    prefix_len = 0
                if end > prefix_len:
                    chunk = self.blob(data[prefix_len:end], category)
                    chunk["offset"] = prefix_len
                    generation["chunks"].append(chunk)
                tail = None
                if end < len(data):
                    tail = self.blob(data[end:], category)
                    tail["offset"] = end
                generation.update(tail=tail, prefix_sha256=sha(data[:end]))
            else:
                same = previous and previous["chunks"] and previous["chunks"][0]["sha256"] == cap["sha256"]
                extend = bool(same)
                generation = copy.deepcopy(previous) if same else {
                    "chunks": [dict(self.blob(data, category, cap["gzip"], cap["sha256"], cap["length"]), offset=0)],
                    "tail": None, "prefix_sha256": cap["sha256"]}
            generation.update(dev=st.st_dev, inode=st.st_ino, size_seen=cap["length"], mtime_ns=st.st_mtime_ns)
            if extend:
                source["generations"][-1] = generation
            else:
                source["generations"].append(generation)
            for pointer in generation["chunks"] + ([generation["tail"]] if generation.get("tail") else []):
                self.existing(pointer, category)
            if self.apply:
                _write_atomic(self.root, rel, json_bytes(source))
            previous = generation
        index = len(source["generations"]) - 1
        pointers = [dict(pointer, source=self.guard.value(key, "raw", "source", "path"), generation=index)
                    for pointer in previous["chunks"] + ([previous["tail"]] if previous.get("tail") else [])]
        self.cache[key] = pointers
        return pointers


def utc(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def unfenced_lines(text):
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match:
            token = match[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not line[match.end():].strip():
                fence = None
            continue
        if fence is None:
            yield n, line


def strip_prefix(line):
    value = re.sub(r"^\s*(?:[-*]\s+|#+\s*)", "", line)
    value = value.replace("**", "").replace("__", "")
    return re.sub(r"^\[lead-[^]]+\]\s*", "", value).strip()


def extract(files, location, entries_list):
    fields = {key: "unknown" for key in ("title", "risk", "branch", "task", "lead_profile", "lead_model",
                                         "lead_effort", "codex_profile", "backend", "gates", "rounds", "dispatch", "lanes", "mode", "worktree")}
    fields.update(status="running" if "summary.md" not in files else "unknown", status_rule="no-summary",
                  commits=[], models=[], status_mentions=[], field_sources={}, raw_fields={}, refs=[], unresolved_refs=[])
    brief = files.get("brief.md", "")
    git_depth = None
    for n, line in unfenced_lines(brief):
        if line.startswith("#"):
            if line.startswith("# ") and fields["title"] == "unknown":
                fields["title"] = line[2:]
                fields["field_sources"]["title"] = f"{location}/brief.md:{n}"
            depth = len(line) - len(line.lstrip("#"))
            if re.search(r"\bgit\b", line, re.I):
                git_depth = depth
            elif git_depth is not None and depth <= git_depth:
                git_depth = None
        match = re.match(r"^RISK:\s*(trivial|low|normal|critical)\b", line)
        if match and fields["risk"] == "unknown":
            fields["risk"] = match[1]
            fields["field_sources"]["risk"] = f"{location}/brief.md:{n}"
        if git_depth is not None and line.startswith("BRANCH:"):
            fields["branch"] = line.split(":", 1)[1].strip()
            fields["field_sources"]["branch"] = f"{location}/brief.md:{n}"
    aliases = {"TASK": "task", "CLAUDE PROFILE": "claude_profile", "CODEX PROFILE": "codex_profile",
               "BACKEND": "backend", "BRANCH": "branch", "MODE": "mode", "WORKTREE": "worktree",
               "COMMITS": "commits", "GATES": "gates", "ROUNDS": "rounds", "DISPATCH": "dispatch", "LANES": "lanes"}
    for n, original in enumerate(files.get("summary.md", "").splitlines(), 1):
        if re.match(r"^\s*(`{3,}|~{3,})", original):
            continue
        line = strip_prefix(original)
        status = re.match(r"^(?i:STATUS)\s*:\s*([A-Z][A-Z-]*)", line)
        if status:
            fields["status_mentions"].append({"value": status[1].lower(), "line": original,
                                               "source": f"{location}/summary.md:{n}", "final": original.startswith("[lead-")})
        for label, key in aliases.items():
            match = re.match(re.escape(label) + r"\s*:\s*(.*)", line)
            if match:
                fields["raw_fields"][key] = match[1]
                # Keep historical value formatting; normalization is for recognizing labels.
                raw_match = re.search(re.escape(label) + r"(?:\*\*|__)?\s*:\s*(.*)", original)
                if raw_match:
                    raw_value = raw_match[1]
                    if "**" in original[:raw_match.start(1)] or "__" in original[:raw_match.start(1)]:
                        raw_value = re.sub(r"^(?:\*\*|__)\s*", "", raw_value)
                    fields["raw_fields"][key] = raw_value
                fields["field_sources"][key] = f"{location}/summary.md:{n}"
                if key == "branch":
                    fields[key] = re.split(r"\s+(?:MODE|WORKTREE):", match[1])[0].strip()
                elif key not in {"commits", "rounds", "claude_profile"}:
                    fields[key] = match[1]
        for key in ("mode", "worktree"):
            match = re.search(r"(?:^|\s)" + key.upper() + r":\s*(.*?)(?=\s+[A-Z]+:|$)", line)
            if match:
                fields[key] = match[1]
                fields["raw_fields"][key] = match[1]
                fields["field_sources"][key] = f"{location}/summary.md:{n}"
    candidates = fields["status_mentions"]
    if candidates:
        finals = [s for s in candidates if s["final"]]
        governing = finals[-1] if finals else candidates[0]
        fields.update(status=governing["value"], status_rule="last-lead" if finals else "first-candidate")
        fields["field_sources"]["status"] = governing["source"]
    elif "summary.md" in files:
        fields["status_rule"] = "no-candidate"
    profile = fields["raw_fields"].get("claude_profile", "unknown")
    fields["claude_profile"] = profile
    match = re.match(r"^(\S+)\s+([A-Za-z0-9.\[\]-]+)@([a-z]+)", profile)
    if match:
        fields.update(lead_profile=match[1], lead_model=match[2], lead_effort=match[3])
        for key in ("lead_profile", "lead_model", "lead_effort"):
            fields["field_sources"][key] = fields["field_sources"].get("claude_profile", "unknown")
    rounds = re.search(r"\d+", fields["raw_fields"].get("rounds", ""))
    fields["rounds"] = int(rounds[0]) if rounds else "unknown"
    fields["commits"] = re.findall(r"\b[0-9a-f]{7,40}\b", fields["raw_fields"].get("commits", ""))
    models = set()
    model_text = " ".join(fields["raw_fields"].get(key, "") for key in ("lanes", "gates", "claude_profile", "codex_profile"))
    models.update(re.findall(r"gpt-[0-9][0-9.]*-[a-z]+", model_text))
    models.update("claude-" + family.lower() for family in re.findall(r"\b(opus|sonnet|fable|haiku)\b", model_text, re.I))
    threads = []
    for n, line in enumerate(files.get(".codex-session", "").splitlines(), 1):
        columns = line.split("=", 1)[1].split("|") if "=" in line else line.split()
        if len(columns) >= 2 and "=" in line:
            model = columns[1].strip()
        elif len(columns) >= 3:
            model = columns[2].strip()
        else:
            model = ""
        if model:
            models.add(model)
            fields["field_sources"].setdefault("models", []).append(f"{location}/.codex-session:{n}")
        models.update(re.findall(r"gpt-[0-9][0-9.]*-[a-z]+", line))
        threads.extend(re.findall(UUID, line))
    for name, text in files.items():
        if re.match(r"codex-.*\.jsonl$", name):
            try:
                first = json.loads(text.splitlines()[0])
                if first.get("type") == "thread.started" and first.get("thread_id"):
                    threads.append(first["thread_id"])
            except (ValueError, IndexError, AttributeError):
                pass
    fields["models"] = sorted(models)
    for name in ("brief.md", "plan.md", "summary.md"):
        for n, line in enumerate(files.get(name, "").splitlines(), 1):
            refs = re.findall(r"orch/(\d{2,}-[a-z0-9-]+)|\.orchestra/(\d{2,}-[A-Za-z0-9_.-]+)", line)
            for branch, directory in refs:
                ref = branch or directory
                fields["refs"].append({"ref": ref, "line": line, "source": f"{location}/{name}:{n}"})
            if name == "brief.md":
                fields["unresolved_refs"].extend(re.findall(r"\bT\d+\b", line))
    fields["unresolved_refs"] = sorted(set(fields["unresolved_refs"]))
    archived = [entry for entry in entries_list if entry["kind"] in ("vault", "raw", "withheld")]
    fields["updated"] = utc(max(entry["mtime"] for entry in archived)) if archived else "unknown"
    brief_entry = next((entry for entry in archived if entry["relpath"] == "brief.md"), None)
    fields["created"] = utc(brief_entry["mtime"]) if brief_entry else "unknown"
    return fields, sorted({thread.lower() for thread in threads})


def registry_rows(text, path):
    headers = None
    rows = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip().startswith("|"):
            headers = None
            continue
        content = line.strip()[1:]
        if content.endswith("|"):
            content = content[:-1]
        cells = re.split(r"(?<!\\)\|", content)
        if all(re.fullmatch(r"\s*:?-+:?\s*", c) for c in cells):
            continue
        if headers is None:
            headers = [c.strip().lower() for c in cells]
            continue
        if len(cells) == len(headers):
            rows.append({"source": str(path), "line": n, "cells": dict(zip(headers, cells))})
    return rows


class Archive:
    def __init__(self, policy, discovery, guard, apply=False, top=20):
        self.p, self.d, self.guard, self.apply = policy, discovery, guard, apply
        self.errors = guard.source_errors
        self.raw = RawStore(policy, apply, guard)
        self.files = {}
        self.capture_cache = {}
        self.catalog = {"version": 1, "tasks": {}, "sessions": {}, "projects": {}, "models": {}, "generated": []}
        existing = policy["VAULT_DIR"] / "_meta/catalog.json"
        if existing.exists():
            self.catalog = json.loads(existing.read_text())
            self.guard.seed_released(self.catalog)
        self.previous_generated = list(self.catalog["generated"])
        self.skipped = Samples(top, guard)
        for item in discovery.skipped:
            self.skipped.append(item)
        self.top = top
        self.locations = 0
        self.transcripts = {"files": 0, "bytes": 0, "unlinked_projects": 0, "unlinked_bytes": 0}
        self.rollouts = {"files": 0, "bytes": 0, "missing": [], "native_unlinked": 0, "native_unlinked_bytes": 0}
        self.large = []
        self.payload = {"files": 0, "bytes": 0, "tasks": {}, "items": []}
        self.checkpoints = {"files": 0, "bytes": 0, "tasks": {}}
        self.thread_owners = collections.defaultdict(set)
        self.root_reports = []
        for task in self.catalog["tasks"].values():
            for sid, snap in task["snapshots"].items():
                old_entries = snap.pop("entries", None)
                if old_entries is not None:
                    snap.update(files=len(old_entries), bytes=sum(e["size"] for e in old_entries),
                                counts=dict(collections.Counter(e["kind"] for e in old_entries)))
                    if "manifest" not in snap:
                        summary = {"body": b",\n".join(json_bytes(entry, compact=True).rstrip(b"\n") for entry in old_entries)}
                        snap["manifest"] = dict(self.raw.blob(self.manifest({"snapshot": sid}, summary), "manifests"), snapshot=sid)
                if "manifest" in snap:
                    self.raw.existing(snap["manifest"], "manifests")
            for location in task["locations"].values():
                location["present"] = False

    def captured(self, path, keep):
        key = str(path.resolve())
        if key not in self.capture_cache or (keep and self.capture_cache[key]["data"] is None):
            self.capture_cache[key] = capture(path, self.p["GZIP_LEVEL"], keep, counting=not self.apply,
                                              raw_dir=self.raw.root if self.apply else None)
        return self.capture_cache[key]

    def scan_files(self, base, owner, prefix, paths=None):
        # A stat-only first pass measures the task payload budget. The second walk
        # is globally sorted and emits one guarded entry at a time into JSON.
        # Neither pass retains Paths/dicts for the potentially millions of links.
        paths = sorted(paths) if paths is not None else None
        payload_total = 0
        for path in paths if paths is not None else walk(base, skip_nested=True, errors=self.errors):
            try:
                st = path.lstat()
                if stat.S_ISREG(st.st_mode) and path.suffix.lower() not in self.p["TEXT_EXTENSIONS"] | self.p["CHECKPOINT_EXTENSIONS"] and path.name != ".codex-session":
                    payload_total += st.st_size
            except OSError as error:
                self.errors.record(path, error)
        texts, artifacts, archived, checkpoints = {}, {}, [], []
        counts, total, file_count = collections.Counter(), 0, 0
        identity, body = hashlib.sha256(), io.BytesIO()
        for path in paths if paths is not None else walk(base, self.skipped, skip_nested=True, errors=self.errors):
            rel = str(path.relative_to(base))
            entry = {"relpath": rel}
            try:
                st = path.lstat()
                entry.update(size=st.st_size, mtime=st.st_mtime)
                if stat.S_ISLNK(st.st_mode):
                    entry.update(kind="symlink", target=os.readlink(path))
                elif not stat.S_ISREG(st.st_mode):
                    entry["kind"] = "special"
                elif path.suffix.lower() in self.p["CHECKPOINT_EXTENSIONS"]:
                    entry.update(kind="checkpoint", reason="checkpoint-not-copied")
                    checkpoints.append({"relpath": self.guard.value(rel, owner, rel, "path"),
                                        "size": st.st_size, "mtime": utc(st.st_mtime)})
                    self.checkpoints["files"] += 1
                    self.checkpoints["bytes"] += st.st_size
                    self.checkpoints["tasks"][owner] = self.checkpoints["tasks"].get(owner, 0) + st.st_size
                else:
                    entry["kind"] = "candidate"
            except OSError as error:
                failure = self.errors.record(path, error)
                entry.update(kind=failure["reason"], errno=error.errno, size=0)
            safe_rel = self.guard.value(rel, owner, rel, "path")
            if entry["kind"] == "candidate":
                payload = path.suffix.lower() not in self.p["TEXT_EXTENSIONS"] and path.name != ".codex-session"
                over = payload and (not self.p["INCLUDE_PAYLOAD"] or
                    (self.p["PAYLOAD_TASK_MAX_BYTES"] and payload_total > self.p["PAYLOAD_TASK_MAX_BYTES"]) or
                    (self.p["PAYLOAD_FILE_MAX_BYTES"] and entry["size"] > self.p["PAYLOAD_FILE_MAX_BYTES"]))
                if over:
                    entry.update(kind="payload-over-budget", reason="payload-over-budget" if self.p["INCLUDE_PAYLOAD"] else "payload-disabled")
                    self.payload["files"] += 1
                    self.payload["bytes"] += entry["size"]
                    self.payload["tasks"][owner] = self.payload["tasks"].get(owner, 0) + entry["size"]
                    if len(self.payload["items"]) < self.top:
                        self.payload["items"].append({"owner": owner, "path": str(path), "bytes": entry["size"], "reason": entry["reason"]})
                else:
                    vault_candidate = path.suffix.lower() in self.p["VAULT_TEXT_EXTENSIONS"] and entry["size"] <= self.p["VAULT_TEXT_MAX_BYTES"]
                    parse = path.name in {"brief.md", "summary.md", "plan.md", ".codex-session", "REGISTRY.md"} or re.match(r"codex-.*\.jsonl$", path.name)
                    try:
                        keep = bool(vault_candidate or parse or path.suffix.lower() in self.p["APPEND_EXTENSIONS"])
                        cap = self.captured(path, keep)
                        entry.update(size=cap["length"], sha256=cap["sha256"], mtime=cap["stat"].st_mtime, kind="raw")
                        text = None
                        if cap["data"] is not None and (parse or vault_candidate):
                            try:
                                data = cap["data"]
                                if path.name.endswith(".jsonl") and not vault_candidate:
                                    end = data.find(b"\n")
                                    data = data[:end] if end >= 0 else data
                                text = data.decode("utf-8")
                                del data
                            except UnicodeError:
                                pass
                        if parse and text is not None:
                            # Only thread.started on the first line is extracted.
                            # Keep the complete original exclusively in the raw store.
                            end = text.find("\n") if path.name.endswith(".jsonl") else -1
                            texts[rel] = text[:end] if end >= 0 else text
                        if safe_rel != rel:
                            entry["kind"] = "withheld"
                        elif vault_candidate and text is not None:
                            entry["kind"] = "withheld" if self.guard.file(cap["data"], owner, rel) else "vault"
                        category = "withheld" if entry["kind"] == "withheld" else "task-files"
                        entry["raw"] = self.raw.archive(path, category, cap)
                        if entry["raw"] is None:
                            raise OSError(self.errors.failed[str(path)]["errno"], "source archive failed")
                        if entry["kind"] == "vault":
                            artifacts[safe_rel] = Artifact(self.raw.root, entry["raw"], cap["length"], cap["sha256"])
                        archived.append({"relpath": rel, "kind": entry["kind"], "mtime": entry["mtime"]})
                        # Each source has already been captured once. Drop its bytes.
                        self.capture_cache[str(path.resolve())] = {"stat": cap["stat"], "length": cap["length"], "sha256": cap["sha256"], "data": None, "gzip": None}
                    except OSError as error:
                        failure = self.errors.record(path, error)
                        entry.update(kind=failure["reason"], errno=error.errno)
                        entry.pop("raw", None)
                        entry.pop("sha256", None)
                        texts.pop(rel, None)
                    finally:
                        # Do not retain the preceding source's bytes while capturing
                        # the next file; artifacts already hold only raw pointers.
                        cap = text = data = None
            if entry["kind"] in {"symlink", "special"}:
                self.skipped.append({"path": str(path), "reason": entry["kind"], "bytes": entry["size"]})
            if entry["size"] > self.p["SIZE_REPORT_BYTES"]:
                self.large.append({"path": str(path), "bytes": entry["size"], "kind": entry["kind"]})
            if file_count:
                identity.update(b"\n")
                body.write(b",\n")
            identity.update("\0".join((rel, entry["kind"], entry.get("sha256", str(entry["size"])), entry.get("target", ""))).encode())
            file_count += 1
            total += entry["size"]
            counts[entry["kind"]] += 1
            # Guard each entry once, then retain only its compact serialization.
            entry["relpath"] = safe_rel
            body.write(json_bytes(self.guard.tree(entry, owner, "entries"), compact=True).rstrip(b"\n"))
        snapshot = identity.hexdigest()[:12]
        for rel, data in artifacts.items():
            self.files[f"{prefix}/{snapshot}/files/{rel}"] = data
        summary = {"files": file_count, "bytes": total, "counts": dict(counts),
                   "body": body.getvalue(), "archived": archived, "checkpoints": checkpoints}
        return snapshot, summary, texts

    @staticmethod
    def manifest(header, summary):
        prefix = json_bytes(header, compact=True).rstrip(b"\n")[:-1]
        separator = b"," if header else b""
        return Document(prefix + separator + b'"entries":[\n', summary["body"], b"\n]}\n")

    def build(self):
        for root, info in sorted(self.d.roots.items()):
            project = info["project"]
            project_record = self.catalog["projects"].setdefault(project, {"id": project, "roots": [], "registry_rows": [], "raw": []})
            safe_root = self.guard.value(str(root), project, "root", "path")
            if safe_root not in project_record["roots"]:
                project_record["roots"].append(safe_root)
            root_files, task_paths = [], []
            for entry in entries(root, self.errors):
                if entry.name in EXCLUDED or (entry.name == ".orchestra" and entry.is_dir(follow_symlinks=False)):
                    self.skipped.append({"path": entry.path, "reason": "excluded dir"})
                    continue
                path = Path(entry.path)
                if entry.is_dir(follow_symlinks=False):
                    if self.d.task_dir(path, self.errors):
                        task_paths.append(path)
                    elif self.d.container(path, errors=self.errors):
                        self.skipped.append({"path": str(path), "reason": "checkout container", "bytes": byte_total(path, self.errors)})
                    else:
                        root_files.extend(walk(path, self.skipped, skip_nested=True, errors=self.errors))
                else:
                    root_files.append(path)
            # A root's artifacts use the same dispositions, but no extra snapshot directory.
            root_prefix = f"artifacts/roots/{project}/{sha(str(root).encode())[:12]}"
            rid, rentries, root_texts = self.scan_files(root, project, root_prefix, root_files)
            for rel in list(self.files):
                if rel.startswith(root_prefix + "/" + rid + "/"):
                    self.files[root_prefix + "/" + rel.split("/" + rid + "/", 1)[1]] = self.files.pop(rel)
            manifest = dict(self.raw.blob(self.manifest({"root": safe_root}, rentries), "manifests"), root=safe_root)
            project_record["manifests"] = sorted([p for p in project_record.get("manifests", []) if p["root"] != safe_root] + [manifest],
                                                  key=lambda p: p["root"])
            rows = registry_rows(root_texts.get("REGISTRY.md", ""), root / "REGISTRY.md")
            unmatched = list(rows)
            for path in task_paths:
                task_id = project + "--" + self.guard.identifier(path.name, project, slugify=False)
                task = self.catalog["tasks"].setdefault(task_id, {"id": task_id, "project": project,
                    "task_dir": self.guard.value(path.name, task_id, "task_dir", "path"), "locations": {}, "snapshots": {}, "raw": []})
                prefix = f"artifacts/tasks/{task_id}"
                snapshot_id, task_entries, texts = self.scan_files(path, task_id, prefix)
                fields, threads = extract(texts, str(path), task_entries["archived"])
                fields["models"] = sorted({self.guard.identifier(model, task_id) for model in fields["models"]})
                matched = []
                for row in rows:
                    directory = row["cells"].get("dir", "")
                    branch = row["cells"].get("branch", "")
                    if re.search(r"\.orchestra/" + re.escape(path.name) + r"(?:[/\s`]|$)", directory) or (
                            fields["branch"] != "unknown" and re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(fields["branch"]) + r"(?![A-Za-z0-9_.-])", branch)):
                        matched.append(row)
                        if row in unmatched:
                            unmatched.remove(row)
                fields["registry_status"] = matched[0]["cells"].get("status", "unknown").strip() if matched else "unknown"
                if matched:
                    fields["field_sources"]["registry_status"] = f"{matched[0]['source']}:{matched[0]['line']}"
                safe_fields = self.guard.tree(fields, task_id, "fields")
                safe_rows = self.guard.tree(matched, task_id, "registry")
                safe_location = self.guard.value(str(path), task_id, "location", "path")
                loc_key = sha(str(path.resolve()).encode())[:24]
                task["locations"][loc_key] = {"path": safe_location, "present": True, "snapshot": snapshot_id,
                                               "root": safe_root, "fields": safe_fields, "registry_rows": safe_rows}
                task["snapshots"].setdefault(snapshot_id, {"id": snapshot_id, "fields": safe_fields,
                    "registry_rows": safe_rows, "files": task_entries["files"], "bytes": task_entries["bytes"],
                    "counts": task_entries["counts"], "locations": [], "checkpoints": task_entries["checkpoints"]})
                snap = task["snapshots"][snapshot_id]
                if safe_location not in snap["locations"]:
                    snap["locations"].append(safe_location)
                # The first manifest for a content identity remains immutable.
                if "manifest" not in snap:
                    snap["manifest"] = dict(self.raw.blob(self.manifest({"snapshot": snapshot_id}, task_entries), "manifests"), snapshot=snapshot_id)
                for thread in threads:
                    self.thread_owners[thread].add(("tasks", task_id))
                self.locations += 1
            if "REGISTRY.md" in root_texts:
                source = self.guard.value(str(root / "REGISTRY.md"), project, "registry/source", "path")
                project_record["registry_rows"] = sorted(
                    [row for row in project_record["registry_rows"] if row["source"] != source] +
                    self.guard.tree(unmatched, project, "registry"), key=lambda row: (row["source"], row["line"]))
            self.root_reports.append(dict(info, tasks=len(task_paths)))
        for sid, session in sorted(self.d.sessions.items()):
            for thread in session["thread_ids"]:
                self.thread_owners[thread].add(("sessions", sid))
            record = self.guard.tree(session, sid, "conf")
            record["raw"] = self.catalog["sessions"].get(sid, {}).get("raw", [])
            self.catalog["sessions"][sid] = record
        self.link_sessions()
        for project in self.catalog["projects"].values():
            for pointer in project.get("manifests", []):
                self.raw.existing(pointer, "manifests")
        if self.p["INCLUDE_CLAUDE_TRANSCRIPTS"]:
            self.claude_transcripts()
        if self.p["INCLUDE_CODEX_ROLLOUTS"]:
            self.codex_rollouts()
        self.primary_fields()
        self.relations()
        self.render()
        return self

    def link_sessions(self):
        for task in self.catalog["tasks"].values():
            present = [loc for loc in task["locations"].values() if loc["present"]]
            linked = set() if present else set(task.get("sessions", []))
            for loc in present:
                if loc["path"].startswith("[withheld:"):
                    continue
                bases = [base for base, owners in self.d.bases.items() if owners and under(loc["path"], base)]
                if bases:
                    depth = max(len(base.parts) for base in bases)
                    linked.update(sid for base in bases if len(base.parts) == depth
                                  for sid, _ in self.d.bases[base] if sid)
            task["sessions"] = sorted(linked)

    def owner_for_base(self, base):
        owners = self.d.bases.get(base, [])
        sessions = sorted(sid for sid, _ in owners if sid)
        if sessions:
            return "sessions", sessions[0]
        project = self.d.project(base / ".orchestra")
        self.catalog["projects"].setdefault(project, {"id": project, "roots": [], "registry_rows": [], "raw": []})
        return "projects", project

    def add_raw(self, owner, source, pointers):
        kind, identifier = owner
        record = self.catalog[kind][identifier]
        source = self.guard.value(str(source.resolve()), "raw", "source", "path")
        record["raw"] = [p for p in record.get("raw", []) if p["source"] != source] + pointers
        record["raw"].sort(key=lambda p: (p["source"], p["generation"], p["offset"]))

    def claude_transcripts(self):
        home = Path(expand("~")).resolve()
        bases = sorted(self.d.bases)
        encoded = lambda p: re.sub(r"[^A-Za-z0-9]", "-", str(p))
        for entry in entries(self.p["CLAUDE_PROJECTS_DIR"], self.errors, optional=True):
            if not entry.is_dir(follow_symlinks=False):
                continue
            directory = Path(entry.path)
            candidates = []
            for child in entries(directory, self.errors):
                if child.is_symlink():
                    self.skipped.append({"path": child.path, "reason": "symlink"})
                elif child.is_file(follow_symlinks=False) and child.name.endswith(".jsonl"):
                    candidates.append(Path(child.path))
                elif child.is_dir(follow_symlinks=False):
                    for agents in entries(child.path, self.errors):
                        if agents.name != "subagents":
                            continue
                        if agents.is_symlink():
                            self.skipped.append({"path": agents.path, "reason": "symlink"})
                        elif agents.is_dir(follow_symlinks=False):
                            for sub in entries(agents.path, self.errors):
                                if sub.is_file(follow_symlinks=False) and (sub.name.endswith(".jsonl") or sub.name.endswith(".meta.json")):
                                    candidates.append(Path(sub.path))
            matched = next((base for base in bases if entry.name == encoded(base) or
                            (base != home and entry.name.startswith(encoded(base) + "--orchestra-"))), None)
            if matched is None:
                for path in sorted(p for p in candidates if p.parent == directory):
                    try:
                        with open(path, "rb") as stream:
                            initial = stream.read(65536)
                    except OSError as error:
                        self.errors.record(path, error)
                        continue
                    cwd = None
                    for line in initial.splitlines():
                        try:
                            record = json.loads(line)
                            if isinstance(record, dict) and record.get("cwd"):
                                cwd = Path(record["cwd"]).resolve()
                                break
                        except (ValueError, TypeError):
                            continue
                    if cwd:
                        matched = next((base for base in sorted(bases, key=lambda b: (-len(b.parts), str(b)))
                                        if cwd == base or (base != home and under(cwd, base))), None)
                    if matched:
                        break
            if matched is None:
                self.transcripts["unlinked_projects"] += 1
                size = byte_total(directory, self.errors)
                self.transcripts["unlinked_bytes"] += size
                self.skipped.append({"path": str(directory), "reason": "not linked to a cc-orch base", "bytes": size})
                continue
            owner = self.owner_for_base(matched)
            for path in sorted(candidates):
                pointers = self.raw.archive(path, "transcripts")
                if pointers is None:
                    continue
                self.add_raw(owner, path, pointers)
                size = sum(p["length"] for p in pointers)
                self.transcripts["files"] += 1
                self.transcripts["bytes"] += size
                if size > self.p["SIZE_REPORT_BYTES"]:
                    self.large.append({"path": str(path), "bytes": size, "kind": "transcript"})

    def codex_rollouts(self):
        indexed = {}
        for dirname in ("sessions", "archived_sessions"):
            for path in walk(self.p["CODEX_HOME_DIR"] / dirname, errors=self.errors, optional=True):
                match = re.search(r"(" + UUID + r")\.jsonl$", path.name)
                if match and path.name.startswith("rollout-") and not source_test(path, "is_symlink", self.errors):
                    indexed.setdefault(match[1].lower(), []).append(path)
        for thread, owners in sorted(self.thread_owners.items()):
            matches = indexed.get(thread.lower(), [])
            if not matches:
                self.rollouts["missing"].append(self.guard.value(thread, "rollout", "missing"))
            for path in sorted(matches):
                pointers = self.raw.archive(path, "rollouts")
                if pointers is None:
                    continue
                for owner in sorted(owners):
                    self.add_raw(owner, path, pointers)
                size = sum(p["length"] for p in pointers)
                self.rollouts["files"] += 1
                self.rollouts["bytes"] += size
                if size > self.p["SIZE_REPORT_BYTES"]:
                    self.large.append({"path": str(path), "bytes": size, "kind": "rollout"})
        for thread, paths in indexed.items():
            if thread not in {t.lower() for t in self.thread_owners}:
                self.rollouts["native_unlinked"] += len(paths)
                for path in paths:
                    try:
                        self.rollouts["native_unlinked_bytes"] += path.lstat().st_size
                    except OSError as error:
                        self.errors.record(path, error)

    def primary_fields(self):
        for task in self.catalog["tasks"].values():
            present = [loc for loc in task["locations"].values() if loc["present"]]
            if present:
                primary = sorted(present, key=lambda loc: (
                    loc["fields"]["updated"] if loc["fields"]["updated"] != "unknown" else "", loc["path"]))[-1]
                task["primary"] = primary["snapshot"]
                task["fields"] = copy.deepcopy(primary["fields"])
            elif "fields" not in task:
                task["fields"] = copy.deepcopy(task["snapshots"][task["primary"]]["fields"])
            # Models describe every archived run; scalar fields still follow the primary.
            task["fields"]["models"] = sorted({model for snapshot in task["snapshots"].values()
                                              for model in snapshot["fields"]["models"]})
            current_fields = [loc["fields"] for loc in present]
            scalar_keys = [key for key, value in task["fields"].items() if key not in {"field_sources", "refs", "raw_fields", "status_mentions"}]
            task["conflicts"] = sorted(key for key in scalar_keys if len({json.dumps(f.get(key), sort_keys=True) for f in current_fields}) > 1)
            rows = [row for loc in task["locations"].values() for row in loc["registry_rows"]]
            unique = {json.dumps(row, sort_keys=True): row for row in rows}
            task["registry_rows"] = [unique[key] for key in sorted(unique)]
            task["registry_statuses"] = sorted({row["cells"].get("status", "unknown").strip() for row in rows})
            dated_records = list(task["snapshots"].values()) + list(task["locations"].values())
            dates = [record["fields"]["created"] for record in dated_records if record["fields"]["created"] != "unknown"]
            task["fields"]["created"] = min(dates) if dates else "unknown"
            for model in task["fields"]["models"]:
                self.catalog["models"].setdefault(model, {"id": model})

    def relations(self):
        evidence = r"build(s)? on|based on|follow-?up|follows|depends on|prerequisite|predecessor|successor|continues|spin(s|ned)? off|spun off|후속|선행"
        tasks = self.catalog["tasks"]
        relation_keys = ("predecessors", "successors", "supersedes", "superseded_by", "overlaps", "mentions")
        for task in tasks.values():
            for key in relation_keys:
                task[key] = set()
        for identifier, task in sorted(tasks.items()):
            unresolved = set(task["fields"]["unresolved_refs"])
            for reference in task["fields"]["refs"]:
                ref, line = reference["ref"], reference["line"]
                same_project = [other for other in tasks.values() if other["project"] == task["project"]]
                candidates = [other for other in same_project if other["task_dir"] == ref]
                if not candidates:
                    candidates = [other for other in same_project if other["fields"]["branch"] == "orch/" + ref]
                if not candidates:
                    candidates = [other for other in same_project if other["task_dir"].split("-", 1)[0] == ref.split("-", 1)[0]]
                if len(candidates) != 1:
                    unresolved.add(ref)
                    continue
                other = candidates[0]
                if other["id"] == identifier:
                    continue
                related = False
                if re.search(evidence, line, re.I):
                    first = re.match(r"\d+", task["task_dir"])
                    second = re.match(r"\d+", other["task_dir"])
                    if first and second and int(first[0]) != int(second[0]):
                        predecessor, successor = (task, other) if int(first[0]) < int(second[0]) else (other, task)
                        predecessor["successors"].add(successor["id"])
                        successor["predecessors"].add(predecessor["id"])
                        related = True
                if re.search("supersed", line, re.I):
                    task["supersedes"].add(other["id"])
                    other["superseded_by"].add(identifier)
                    related = True
                if re.search("overlap|concurrent", line, re.I):
                    task["overlaps"].add(other["id"])
                    other["overlaps"].add(identifier)
                    related = True
                if not related:
                    task["mentions"].add(other["id"])
            task["fields"]["unresolved_refs"] = sorted(unresolved)
        for task in tasks.values():
            for key in relation_keys:
                task[key] = sorted(task[key])

    def render(self):
        for identifier, task in sorted(self.catalog["tasks"].items()):
            self.render_task(identifier, task)
        for kind in ("projects", "sessions", "models"):
            for identifier, record in sorted(self.catalog[kind].items()):
                pointers = record.get("raw", [])
                index = self.raw_index(kind, identifier, pointers)
                linked = [tid for tid, task in sorted(self.catalog["tasks"].items()) if
                          (kind == "projects" and task["project"] == identifier) or
                          (kind == "sessions" and identifier in task["sessions"]) or
                          (kind == "models" and identifier in task["fields"]["models"])]
                fields = {"id": identifier, "type": kind[:-1], "sources": record.get("sources", record.get("roots", [])),
                          "tasks": [link("tasks", tid) for tid in linked], "raw_index": index,
                          "transcript_count": len({p["source"] for p in pointers}), "transcript_bytes": sum(p["length"] for p in pointers),
                          "tags": ["type/" + kind[:-1]]}
                if kind == "sessions":
                    fields.update(backend=record["backend"], backend_source=record["backend_source"],
                                  created_at=record["fields"].get("CREATED_AT", "unknown"), conf=record["fields"], parse_error=record["parse_error"])
                if kind == "projects":
                    fields["manifests"] = record.get("manifests", [])
                body = "# " + kind[:-1].title() + "\n\n" + fenced(json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2))
                if kind == "sessions":
                    body += "\n\n## Recorded conf values\n\n" + fenced(history_values(record["fields"]))
                if kind == "projects":
                    body += "\n\n## Unmatched registry rows\n\n" + fenced(history_rows(record.get("registry_rows", [])))
                body += "\n\n## Tasks\n\n" + "\n".join("- " + link("tasks", tid) for tid in linked) + "\n"
                self.files[f"{kind}/{identifier}.md"] = note(fields, body)
        index_links = [link(kind, identifier) for kind in ("projects", "sessions", "models") for identifier in sorted(self.catalog[kind])]
        index_links += ["[[dashboards/Tasks.base]]", "[[dashboards/Sessions.base]]", "[[dashboards/Open tasks.base]]", "[[_meta/report]]", "[[_meta/withheld]]"]
        self.files["index.md"] = note({"id": "index", "type": "index"}, "# Orchestra archive\n\n" + "\n".join("- " + value for value in index_links) + "\n")
        palette = [14034728, 15109176, 7449760, 5089607, 10053324, 4871631, 9858609]
        queries = ["tag:#risk/" + risk for risk in ("critical", "normal", "low", "trivial")] + ["path:models", "path:sessions", "path:projects"]
        queries += ["tag:#project/" + project for project in sorted(self.catalog["projects"])]
        self.files[".obsidian/graph.json"] = json_bytes({"search": "-path:artifacts -path:_meta -path:dashboards", "showTags": False,
                "showAttachments": False, "showOrphans": True, "hideUnresolved": False,
                "colorGroups": [{"query": query, "color": {"a": 1, "rgb": palette[i % len(palette)]}} for i, query in enumerate(queries)]})
        for name, folder in (("Tasks", "tasks"), ("Open tasks", "tasks"), ("Sessions", "sessions")):
            filters = [f'file.inFolder("{folder}")']
            if name == "Open tasks":
                filters.extend(f'note.status != "{status}"' for status in ("pass", "closed"))
            view = {"type": "table", "name": name, "order": ["file.name", "note.project", "note.status", "note.risk", "note.lead_model", "note.rounds", "note.updated"]}
            if folder == "tasks":
                view["groupBy"] = {"property": "note.project", "direction": "ASC"}
            self.files[f"dashboards/{name}.base"] = json_bytes({"filters": {"and": filters}, "views": [view]})
        self.files[".gitignore"] = b".obsidian/workspace*.json\n.obsidian/cache\n.trash/\n"

    def raw_index(self, kind, identifier, pointers):
        path = f"artifacts/{kind}/{identifier}/raw.json"
        self.files[path] = json_bytes(pointers)
        return {"path": path, "sha256": sha(self.files[path])}

    def render_task(self, identifier, task):
        fields = copy.deepcopy(task["fields"])
        for key in ("refs", "raw_fields", "status_mentions", "field_sources", "claude_profile", "task", "mode", "worktree"):
            fields.pop(key, None)
        current = {loc["snapshot"] for loc in task["locations"].values() if loc["present"]}
        manifests = [snap["manifest"] for _, snap in sorted(task["snapshots"].items())]
        fields.update(id=identifier, type="task", task_dir=task["task_dir"], project=link("projects", task["project"]),
                      sources=[{key: loc[key] for key in ("path", "present", "snapshot", "root")}
                               for loc in sorted(task["locations"].values(), key=lambda loc: loc["path"])], snapshots=sorted(task["snapshots"]),
                      conflicts=task["conflicts"], registry_statuses=task["registry_statuses"],
                      raw_index=self.raw_index("tasks", identifier, task["raw"]), manifests=manifests,
                      models=[link("models", m) for m in task["fields"]["models"]], sessions=[link("sessions", sid) for sid in task["sessions"]],
                      withheld=sum(snap["counts"].get("withheld", 0) for snap in task["snapshots"].values()),
                      tags=["type/task", "risk/" + fields["risk"], "status/" + fields["status"], "project/" + task["project"]] +
                           ["model/" + model for model in task["fields"]["models"]])
        body = "# Task\n\n" + fenced(task["fields"]["title"]) + "\n\n## Fields\n\n"
        body += "| Property | Recorded value |\n| --- | --- |\n"
        for key in ("id", "project", "snapshots", "withheld"):
            value = fields[key] if key != "snapshots" else len(fields[key])
            body += f"| {key} | {value} |\n"
        body += "\nHistorical values and their source lines:\n\n"
        body += fenced(json.dumps(task["fields"], ensure_ascii=False, sort_keys=True, indent=2))
        body += "\n\n## Recorded field values\n\n" + fenced(history_values(task["fields"]["raw_fields"], task["fields"]["field_sources"]))
        mentions = "\n\n".join(item["source"] + "\n" + item["line"] for item in task["fields"]["status_mentions"])
        body += "\n\n## Status mentions\n\n" + fenced(mentions)
        body += "\n\n## Registry rows\n\n" + fenced(history_rows(task["registry_rows"]))
        body += "\n\n## Relations\n\n" + link("projects", task["project"]) + "\n"
        for key in ("predecessors", "successors", "supersedes", "superseded_by", "overlaps", "mentions"):
            fields[key] = [link("tasks", tid) for tid in task[key]]
            body += "\n" + key.replace("_", " ").title() + ": " + ", ".join(fields[key]) + "\n"
        body += "\n## Snapshots\n\n| Snapshot | Current | Files | Bytes | Dispositions |\n| --- | --- | --- | --- | --- |\n"
        for sid, snap in sorted(task["snapshots"].items()):
            dispositions = ", ".join(f"{kind}: {count}" for kind, count in sorted(snap["counts"].items()))
            body += f"| {sid} | {str(sid in current).lower()} | {snap['files']} | {snap['bytes']} | {dispositions} |\n"
        body += "\n## Checkpoint files (not copied)\n"
        for sid in sorted(current):
            checkpoints = task["snapshots"][sid].get("checkpoints", [])
            if checkpoints:
                body += "\n" + sid + "\n\n" + fenced("relpath | size | mtime (UTC)\n" + "\n".join(
                    f"{row['relpath']} | {row['size']} | {row['mtime']}" for row in checkpoints)) + "\n"
        body += "\n## Per-snapshot values\n"
        for sid, snap in sorted(task["snapshots"].items()):
            values = dict(snapshot=sid, current=sid in current, locations=snap["locations"], fields=snap["fields"],
                          files=snap["files"], dispositions=snap["counts"],
                          bytes=snap["bytes"], registry_rows=snap["registry_rows"],
                          location_values=[loc for loc in sorted(task["locations"].values(), key=lambda loc: loc["path"]) if loc["snapshot"] == sid])
            body += "\n" + fenced(json.dumps(values, ensure_ascii=False, sort_keys=True, indent=2)) + "\n"
            body += "\n" + fenced(history_values(snap["fields"]["raw_fields"], snap["fields"]["field_sources"])) + "\n"
            body += "\n" + fenced(history_rows(snap["registry_rows"])) + "\n"
        body += "\n## Raw pointers\n\n| Source id | Generation | Offset | Length | SHA-256 | Blob |\n| --- | --- | --- | --- | --- | --- |\n"
        for pointer in task["raw"]:
            body += "| " + " | ".join(str(value) for value in (
                sha(pointer["source"].encode())[:12], pointer["generation"], pointer["offset"], pointer["length"], pointer["sha256"], pointer["blob"])) + " |\n"
        body += "\n" + fenced(json.dumps(task["raw"], ensure_ascii=False, sort_keys=True, indent=2)) + "\n"
        self.files[f"tasks/{identifier}.md"] = note(fields, body)

    def report(self, top):
        tasks = self.catalog["tasks"]
        stats = self.raw.stats
        source_errors = self.errors.report(top)
        skipped_counts = self.skipped.counts + collections.Counter(item["reason"] for item in self.errors.failed.values())
        safe_skipped = self.skipped.items + source_errors["items"]
        safe_large = self.guard.tree(self.large, "report", "large")
        report = {"roots": self.guard.tree(self.root_reports, "report", "roots"), "logical_tasks": len(tasks), "locations": self.locations,
            "snapshots": sum(len(task["snapshots"]) for task in tasks.values()),
            "statuses": dict(sorted(collections.Counter(task["fields"]["status"] for task in tasks.values()).items())),
            "sessions": len(self.catalog["sessions"]), "session_records": dict(sorted(collections.Counter(
                source["kind"] for s in self.d.sessions.values() for source in s["sources"]).items())),
            "sessions_without_tasks": sorted(set(self.catalog["sessions"]) - {sid for task in tasks.values() for sid in task["sessions"]}),
            "transcripts": self.transcripts, "rollouts": self.rollouts, "raw": stats,
            "source_errors": source_errors,
            "checkpoints": {"files": self.checkpoints["files"], "bytes": self.checkpoints["bytes"],
                            "top_tasks": sorted(self.checkpoints["tasks"].items(), key=lambda row: (-row[1], row[0]))[:top]},
            "raw_total": {key: sum(value[key] for value in stats.values()) for key in ("before", "after", "blobs")},
            "vault_bytes": sum(len(data) for data in self.files.values()),
            "payload_over_budget": {"files": self.payload["files"], "bytes": self.payload["bytes"],
                "items": self.guard.tree(self.payload["items"][:top], "report", "payload"),
                "top_tasks": sorted(self.payload["tasks"].items(), key=lambda row: (-row[1], row[0]))[:top]},
            "withheld_count": len(self.guard.items), "withheld": sorted(self.guard.items.values(), key=lambda row: (row["id"], row["kind"], row["owner"], row["context"]))[:top],
            "skipped_counts": dict(sorted(skipped_counts.items())),
            "skipped": sorted(safe_skipped, key=lambda row: (row["reason"], row["path"]))[:top],
            "large_items": sorted(safe_large, key=lambda row: (-row["bytes"], row["path"]))}
        return report

    def finalize(self, top, check_secrets=True):
        report = self.report(top)
        withheld = "# Withheld material\n\nAppend `sha256:<hex>` to the configured allow-list and re-run apply to release an item.\n\n"
        withheld += "| id | kind | task/session | relative path or field | line numbers | sha256 |\n| --- | --- | --- | --- | --- | --- |\n"
        for item in sorted(self.guard.items.values(), key=lambda row: (row["id"], row["kind"], row["owner"], row["context"])):
            cells = [item["id"], item["kind"], item["owner"], "See details below", item["lines"], item["sha256"]]
            withheld += "| " + " | ".join(str(value).replace("|", "\\|").replace("\n", " ") for value in cells) + " |\n"
        withheld += "\n## Context details\n\n"
        withheld += fenced(json.dumps(sorted(self.guard.items.values(), key=lambda row: (row["id"], row["kind"], row["owner"], row["context"])),
                                     ensure_ascii=False, sort_keys=True, indent=2)) + "\n"
        self.files["_meta/withheld.md"] = note({"id": "withheld", "type": "report"}, withheld)
        # All historical artifact files remain generated and immutable.
        generated = set(self.files) | {path for path in self.previous_generated if path.startswith("artifacts/")}
        generated.update({"_meta/catalog.json", "_meta/report.md"})
        self.catalog["generated"] = sorted(generated)
        self.files["_meta/catalog.json"] = json_bytes(self.catalog, compact=True)
        # Include catalog/report/withheld bytes too. Iterate until the report's own
        # decimal byte-count width stabilizes; no wall-clock values are introduced.
        while True:
            breakdown = {kind: 0 for kind in ("artifacts", "notes", "catalog", "other")}
            for path in self.catalog["generated"]:
                data = self.files.get(path)
                size = len(data) if data is not None else (self.p["VAULT_DIR"] / path).stat().st_size if (self.p["VAULT_DIR"] / path).is_file() else 0
                if path == "_meta/catalog.json":
                    kind = "catalog"
                elif re.fullmatch(COPIED_ARTIFACT_PATH, path):
                    kind = "artifacts"
                elif path.endswith(".md"):
                    kind = "notes"
                else:
                    kind = "other"
                breakdown[kind] += size
            report["vault_bytes_breakdown"] = breakdown
            report["vault_bytes"] = sum(breakdown.values())
            old_report_size = len(self.files.get("_meta/report.md", b""))
            self.files["_meta/report.md"] = note({"id": "report", "type": "report"},
                "# Archive report\n\n" + fenced(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2)) + "\n")
            if old_report_size == len(self.files["_meta/report.md"]):
                break
        # Validate all vault-bound bytes before the first vault write.
        if check_secrets:
            for path, data in sorted(self.files.items()):
                if not isinstance(data, Artifact):
                    self.guard.check(data, path)
        return report


def link(kind, identifier):
    return f"[[{kind}/{identifier}]]"


def history_values(values, sources=None):
    """Render original values verbatim, rather than JSON-escaping historical strings."""
    sections = []
    for key, value in sorted(values.items()):
        source = (sources or {}).get(key, "unknown")
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)
        sections.append(key + "\nsource: " + source + "\n" + text)
    return "\n\n".join(sections)


def history_rows(rows):
    sections = []
    for row in rows:
        section = row["source"] + ":" + str(row["line"])
        for key, value in sorted(row["cells"].items()):
            section += "\n" + key + ":" + value
        sections.append(section)
    return "\n\n".join(sections)


def fenced(value):
    runs = re.findall(r"`+", value)
    fence = "`" * max(3, max((len(run) + 1 for run in runs), default=3))
    return fence + "text\n" + value + "\n" + fence


def note(fields, body):
    header = "---\n" + "\n".join(key + ": " + json.dumps(value, ensure_ascii=False, sort_keys=True) for key, value in sorted(fields.items())) + "\n---\n\n"
    return (header + body).encode()


def git_env():
    result = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "HOME") if key in os.environ}
    result.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_ATTR_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
                  GIT_AUTHOR_NAME="cc-orchestra-archive", GIT_COMMITTER_NAME="cc-orchestra-archive",
                  GIT_AUTHOR_EMAIL="cc-orchestra-archive@localhost", GIT_COMMITTER_EMAIL="cc-orchestra-archive@localhost")
    return result


def git(vault, *args, check=True):
    command = ["git", "-C", str(vault), "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
               "-c", "commit.gpgsign=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args]
    return subprocess.run(command, env=git_env(), check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def git_containment(vault):
    gitdir = vault / ".git"
    if not gitdir.is_dir() or gitdir.is_symlink():
        raise ArchiveError("vault git directory is not a real directory")
    top = git(vault, "rev-parse", "--show-toplevel").stdout.strip()
    actual = git(vault, "rev-parse", "--absolute-git-dir").stdout.strip()
    if top != str(vault.resolve()) or actual != str(gitdir.resolve()):
        raise ArchiveError("vault git containment check failed")


def private_files(base):
    """Git creates its own files; normalize their permissions after its operations."""
    gitdir = base / ".git"
    if gitdir.is_dir() and not gitdir.is_symlink():
        for path in walk(gitdir):
            if path.is_file() and not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) != 0o600:
                os.chmod(path, 0o600)


def strip_code(text):
    result = []
    fence = None
    for line in text.splitlines():
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            token = match[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is None:
            result.append(line)
    return re.sub(r"(`+)(.*?)\1", "", "\n".join(result), flags=re.S)


def frontmatter(text):
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        raise ValueError("missing frontmatter")
    head, body = text[4:].split("\n---\n", 1)
    fields = {}
    for line in head.splitlines():
        key, value = line.split(": ", 1)
        if key in fields:
            raise ValueError("duplicate property")
        fields[key] = json.loads(value)
    return fields, body


def pointer_values(value):
    if isinstance(value, dict):
        if "sha256" in value and ("blob" in value or "path" in value):
            yield value
        for child in value.values():
            yield from pointer_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from pointer_values(child)


def verify(policy):
    vault, raw = policy["VAULT_DIR"], policy["RAW_DIR"]
    problems, links, pointers, notes = [], 0, 0, 0
    try:
        catalog = json.loads((vault / "_meta/catalog.json").read_text())
    except (OSError, ValueError):
        print("catalog: missing or invalid")
        return 1
    checked = set()
    manifest_blobs = {(pointer["blob"], pointer["sha256"])
                      for record in catalog.get("projects", {}).values() for pointer in record.get("manifests", [])}
    manifest_blobs.update((snap["manifest"]["blob"], snap["manifest"]["sha256"])
                          for task in catalog.get("tasks", {}).values() for snap in task["snapshots"].values())

    def check_pointer(pointer, context):
        nonlocal pointers
        try:
            is_raw = "blob" in pointer
            rel = pointer["blob"] if is_raw else pointer["path"]
            base = raw if is_raw else vault
            if not under(base / rel, base):
                raise ValueError("pointer escapes archive directory")
            key = (str(base), rel, pointer["sha256"], pointer.get("length"))
            if key in checked:
                return
            checked.add(key)
            data = (base / rel).read_bytes()
            if is_raw:
                data = gzip.decompress(data)
                pointers += 1
            if sha(data) != pointer["sha256"] or (is_raw and len(data) != pointer["length"]):
                raise ValueError("hash or length mismatch")
            if is_raw and (rel, pointer["sha256"]) in manifest_blobs:
                manifest = json.loads(data)
                if isinstance(manifest, dict):
                    for embedded in pointer_values(manifest.get("entries", [])):
                        if "blob" in embedded:
                            check_pointer(embedded, f"{context}: manifest {rel}")
        except (OSError, ValueError, EOFError, KeyError, TypeError, zlib.error) as error:
            problems.append(f"{context}: raw pointer or file pointer invalid ({type(error).__name__})")

    for rel in catalog.get("generated", []):
        path = vault / rel
        if not under(path, vault):
            problems.append("catalog: generated path escapes vault")
            continue
        try:
            text = path.read_text()
            if rel.endswith(".md") and not rel.startswith("artifacts/"):
                fields, body = frontmatter(text)
                notes += 1
                # Only tool-created link properties contain live frontmatter wikilinks.
                active_keys = {"project", "models", "sessions", "predecessors", "successors", "supersedes", "superseded_by", "overlaps", "mentions", "tasks"}
                live = json.dumps({key: fields[key] for key in active_keys if key in fields}, ensure_ascii=False) + "\n" + strip_code(body)
                for target in re.findall(r"\[\[([^]\n]+)\]\]", live):
                    target = re.split(r"[|#]", target, 1)[0]
                    links += 1
                    candidate = vault / target
                    if not under(candidate, vault) or not (candidate.is_file() or (vault / (target + ".md")).is_file()):
                        problems.append(f"{rel}: unresolved wikilink {target}")
                for pointer in pointer_values(fields):
                    check_pointer(pointer, rel)
            elif rel in {"_meta/catalog.json", ".obsidian/graph.json"} or rel.startswith("dashboards/") and rel.endswith(".base") or re.fullmatch(
                    r"artifacts/(?:tasks|sessions|projects)/[^/]+/raw\.json", rel):
                value = json.loads(text)
                for pointer in pointer_values(value):
                    check_pointer(pointer, rel)
        except (OSError, ValueError, UnicodeError) as error:
            problems.append(f"{rel}: missing or invalid ({type(error).__name__})")
    # Validate every generation and its tail, including historical raw blobs.
    for path in walk(raw / "sources"):
        if path.suffix == ".json" and not path.is_symlink():
            try:
                source = json.loads(path.read_text())
                for generation in source["generations"]:
                    offset = 0
                    digest = hashlib.sha256()
                    for pointer in generation["chunks"]:
                        check_pointer(pointer, path.name)
                        if pointer["offset"] != offset:
                            problems.append(f"{path.name}: non-contiguous chunks")
                        offset += pointer["length"]
                        digest.update(gzip.decompress((raw / pointer["blob"]).read_bytes()))
                    if digest.hexdigest() != generation["prefix_sha256"]:
                        problems.append(f"{path.name}: prefix hash mismatch")
                    tail = generation.get("tail")
                    if tail:
                        check_pointer(tail, path.name)
                        if tail["offset"] != offset:
                            problems.append(f"{path.name}: invalid tail offset")
                        offset += tail["length"]
                    if offset != generation["size_seen"]:
                        problems.append(f"{path.name}: generation length mismatch")
            except (OSError, ValueError, KeyError, EOFError, TypeError, zlib.error):
                problems.append(f"{path.name}: invalid raw generation")
    if problems:
        print("\n".join(sorted(set(problems))))
        return 1
    print(f"verify: OK ({notes} notes, {links} links, {pointers} raw pointers)")
    return 0


def show(policy, identifier):
    vault = policy["VAULT_DIR"]
    matches = []
    for kind in ("tasks", "sessions", "projects", "models"):
        for entry in entries(vault / kind):
            if entry.is_file(follow_symlinks=False) and entry.name.endswith(".md"):
                name = Path(entry.name).stem
                if name == identifier or (kind == "tasks" and name.split("--", 1)[-1] == identifier):
                    matches.append(Path(entry.path))
    if len(matches) != 1:
        print("show: unknown or ambiguous id")
        return 1
    print(matches[0].read_text(), end="")
    return 0


def output_report(report, as_json):
    if as_json:
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    else:
        print("Archive plan (copy only; local vault and raw store)")
        print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--top", type=int, default=20)
    sub = parser.add_subparsers(dest="command")
    for command in ("plan", "apply", "verify", "show"):
        child = sub.add_parser(command)
        if command in ("plan", "apply"):
            child.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
            child.add_argument("--top", type=int, default=argparse.SUPPRESS)
        if command == "apply":
            child.add_argument("--no-commit", action="store_true")
        if command == "show":
            child.add_argument("id")
    args = parser.parse_args(argv)
    try:
        policy = load_policy()
        if args.command == "verify":
            return verify(policy)
        if args.command == "show":
            return show(policy, args.id)
        if args.top < 0:
            raise ArchiveError("--top must be nonnegative")
        guard = Guard(policy)
        discovery = Discovery(policy, guard).run()
        apply = args.command == "apply"
        if not apply:
            archive = Archive(policy, discovery, guard, top=args.top).build()
            output_report(archive.finalize(args.top, check_secrets=False), args.json)
            return 4 if guard.source_errors.failed else 0
        vault, raw = policy["VAULT_DIR"], policy["RAW_DIR"]
        global _WRITE_BASES
        _WRITE_BASES = {vault.resolve(), raw.resolve()}
        if vault.exists() and any(vault.iterdir()) and not (vault / "_meta/catalog.json").is_file():
            raise ArchiveError("existing non-empty vault has no archive catalog")
        if (vault / ".git").exists():
            git_containment(vault)
        os.umask(0o077)
        for base in (vault, raw):
            base.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(base, 0o700)
        lock_path = raw / ".lock"
        if lock_path.is_symlink():
            raise ArchiveError("raw lock is a symlink")
        if not under(lock_path, raw):
            raise ArchiveError("raw lock escapes store")
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(lock_fd, "r+b") as lock:
            os.fchmod(lock.fileno(), 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ArchiveError("archive lock busy", 3) from None
            archive = Archive(policy, discovery, guard, apply=True, top=args.top).build()
            report = archive.finalize(args.top)
            written = removed = 0
            for rel, data in sorted(archive.files.items()):
                # Full-text fail-closed check immediately precedes each vault write.
                artifact = isinstance(data, Artifact)
                if artifact:
                    data = data.materialize()
                guard.check(data, rel, artifact=artifact)
                written += _write_atomic(vault, rel, data)
            for rel in sorted(set(archive.previous_generated) - set(archive.catalog["generated"])):
                if rel.startswith("artifacts/"):
                    continue
                path = vault / rel
                if not under(path, vault) or path.is_symlink():
                    raise ArchiveError("removal target escapes vault")
                if path.is_file():
                    path.unlink()
                    removed += 1
            commit = "none"
            if not (vault / ".git").exists():
                git(vault, "init", "-q", "-b", "main", "--template=")
            git_containment(vault)
            if policy["COMMIT"] and not args.no_commit:
                git(vault, "add", "-A")
                dirty = git(vault, "diff", "--cached", "--quiet", check=False)
                if dirty.returncode == 1:
                    git(vault, "commit", "-q", "-m", f"archive: apply ({len(archive.catalog['tasks'])} tasks, {len(archive.catalog['sessions'])} sessions)")
                    commit = git(vault, "rev-parse", "HEAD").stdout.strip()
                elif dirty.returncode:
                    raise ArchiveError("git diff failed")
            private_files(vault)
            output_report(report, args.json)
            print(f"vault: {written} files written, {removed} removed; raw: {archive.raw.new_blobs} new blobs; commit: {commit}")
        return 4 if guard.source_errors.failed else 0
    except ArchiveError as error:
        print(str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        # No exception message may echo a source-derived secret or git environment value.
        print(f"archive: {type(error).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
