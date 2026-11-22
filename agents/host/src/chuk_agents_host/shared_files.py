"""Files that agents share between hosts (CHAT-177).

A shared file is content-addressed: its name in the store is its sha256. The
store lives in the host's state directory, outside every workspace, so an
agent cannot change a file after it shared it, and a peer can fetch only what
an agent shared (never any other file of a workspace).

    <state>/shared-files/blobs/<sha256>        the bytes
    <state>/shared-files/meta/<sha256>.json    {"name", "size"}
    <state>/shared-files/partial/<sha256>.part a fetch from a peer in progress

A file goes into a workspace only under ``.agents/inbox/<sha256>/<name>``, and
only through directory fds opened without following a symlink, so a link an
agent planted cannot lead the host out of the workspace.

A file reference, as agents and frames carry it:
``{"host_id": "<relay device id>", "sha256": "<hex>", "name": "<file name>",
"size": <bytes>}``.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
import threading
from pathlib import Path

from chuk_agents_executor.attachments import safe_name
from chuk_agents_runtime.agent_mail import workspace_file
from chuk_agents_runtime.attachment_images import open_dir_nofollow

#: The largest file one share or one fetch moves.
MAX_SHARE_BYTES = 200 * 1024 * 1024
#: Raw bytes per chunk on the peer route (as the app's attachment chunks).
CHUNK_BYTES = 256 * 1024
#: Where a fetched file lands, relative to the workspace.
INBOX_PARTS = (".agents", "inbox")

_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
_COPY_BLOCK = 1 << 20


class ShareError(ValueError):
    """A share or fetch that cannot be done; the message goes to the model."""


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and bool(_SHA_RE.match(value))


def clean_ref(raw: object) -> dict | None:
    """A file reference with checked fields, or ``None``. Accepts the dict or
    its JSON text (models often pass the text)."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return None
    if not isinstance(raw, dict):
        return None
    sha = raw.get("sha256")
    size = raw.get("size")
    host_id = raw.get("host_id")
    if not is_sha256(sha) or not isinstance(host_id, str) or not host_id:
        return None
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        return None
    return {
        "host_id": host_id,
        "sha256": sha,
        "name": safe_name(raw.get("name")),
        "size": size,
    }


class SharedFileStore:
    """The content-addressed store of one host."""

    def __init__(self, root: Path, *, max_bytes: int = MAX_SHARE_BYTES) -> None:
        self._root = Path(root)
        self._max = max_bytes
        self._lock = threading.Lock()
        for sub in ("blobs", "meta", "partial"):
            (self._root / sub).mkdir(parents=True, exist_ok=True, mode=0o700)

    @property
    def max_bytes(self) -> int:
        return self._max

    def _blob(self, sha: str) -> Path:
        return self._root / "blobs" / sha

    def _meta(self, sha: str) -> Path:
        return self._root / "meta" / f"{sha}.json"

    def _part(self, sha: str) -> Path:
        return self._root / "partial" / f"{sha}.part"

    # -- share ---------------------------------------------------------------

    def put_from_workspace(self, workspace: str, raw_path: str, *, host_id: str) -> dict:
        """Copy one workspace file into the store and return its reference.
        Only a regular file inside ``workspace`` (no ``..``, no symlink out)."""
        resolved = workspace_file(workspace, raw_path)
        if resolved is None:
            raise ShareError(f"not a file in your workspace: {raw_path}")
        try:
            fd = os.open(resolved, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            raise ShareError(f"cannot read {raw_path}") from None
        with os.fdopen(fd, "rb") as handle:
            st = os.fstat(handle.fileno())
            if not stat.S_ISREG(st.st_mode):
                raise ShareError(f"not a regular file: {raw_path}")
            if st.st_size > self._max:
                raise ShareError(
                    f"{raw_path} is {st.st_size} bytes; the limit is {self._max} bytes"
                )
            sha, size = self._ingest(handle)
        name = safe_name(resolved.name)
        self._write_meta(sha, name, size)
        return {"sha256": sha, "name": name, "size": size, "host_id": host_id}

    def _ingest(self, handle) -> tuple[str, int]:
        digest = hashlib.sha256()
        size = 0
        tmp_fd, tmp_name = tempfile.mkstemp(dir=self._root / "partial", prefix="in-")
        try:
            with os.fdopen(tmp_fd, "wb") as out:
                while True:
                    block = handle.read(_COPY_BLOCK)
                    if not block:
                        break
                    size += len(block)
                    if size > self._max:
                        raise ShareError(f"the file is over {self._max} bytes")
                    digest.update(block)
                    out.write(block)
            sha = digest.hexdigest()
            os.replace(tmp_name, self._blob(sha))
            return sha, size
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise

    def _write_meta(self, sha: str, name: str, size: int) -> None:
        self._meta(sha).write_text(json.dumps({"name": name, "size": size}), encoding="utf-8")

    def has(self, sha: str) -> bool:
        return is_sha256(sha) and self._blob(sha).is_file()

    def size(self, sha: str) -> int | None:
        try:
            return self._blob(sha).stat().st_size if is_sha256(sha) else None
        except OSError:
            return None

    def read_chunk(self, sha: str, offset: int, length: int) -> bytes:
        """Bytes ``[offset, offset+length)`` of a stored file."""
        if not self.has(sha):
            raise ShareError("no such shared file")
        with open(self._blob(sha), "rb") as handle:
            handle.seek(offset)
            return handle.read(length)

    # -- fetch from a peer ---------------------------------------------------

    def partial_size(self, sha: str) -> int:
        try:
            return self._part(sha).stat().st_size
        except OSError:
            return 0

    def append_partial(self, sha: str, offset: int, data: bytes) -> int:
        """Add the bytes at ``offset`` to a fetch in progress. ``offset`` must
        be the bytes held so far; returns the new size."""
        path = self._part(sha)
        with self._lock:
            current = self.partial_size(sha)
            if offset != current:
                raise ShareError(f"chunk at {offset}, expected {current}")
            with open(path, "ab") as handle:
                handle.write(data)
            return current + len(data)

    def drop_partial(self, sha: str) -> None:
        try:
            self._part(sha).unlink()
        except OSError:
            pass

    def finish_partial(self, sha: str, name: str, size: int) -> None:
        """Check the finished fetch against its sha256 and keep it. A mismatch
        drops the partial file and raises."""
        path = self._part(sha)
        digest = hashlib.sha256()
        total = 0
        with open(path, "rb") as handle:
            while True:
                block = handle.read(_COPY_BLOCK)
                if not block:
                    break
                total += len(block)
                digest.update(block)
        if total != size or digest.hexdigest() != sha:
            self.drop_partial(sha)
            raise ShareError("sha256_mismatch: the fetched bytes do not match the reference")
        os.replace(path, self._blob(sha))
        self._write_meta(sha, safe_name(name), size)

    # -- into a workspace ----------------------------------------------------

    def deliver(self, sha: str, name: str, workspace: str) -> str:
        """Copy a stored file into ``<workspace>/.agents/inbox/<sha>/<name>``
        and return that path relative to the workspace. A file already there
        with the right bytes is kept."""
        if not self.has(sha):
            raise ShareError("no such shared file")
        shown = safe_name(name)
        try:
            dir_fd = open_dir_nofollow(str(workspace), [*INBOX_PARTS, sha], create=True)
        except OSError:
            raise ShareError("cannot write the inbox of this workspace") from None
        try:
            if self._same_file(dir_fd, shown, sha):
                return "/".join([*INBOX_PARTS, sha, shown])
            try:
                os.unlink(shown, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            out_fd = os.open(shown, flags, 0o644, dir_fd=dir_fd)
            with os.fdopen(out_fd, "wb") as out, open(self._blob(sha), "rb") as src:
                while True:
                    block = src.read(_COPY_BLOCK)
                    if not block:
                        break
                    out.write(block)
        except OSError:
            raise ShareError("cannot write the file into the workspace") from None
        finally:
            os.close(dir_fd)
        return "/".join([*INBOX_PARTS, sha, shown])

    def _same_file(self, dir_fd: int, name: str, sha: str) -> bool:
        try:
            fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
        except OSError:
            return False
        with os.fdopen(fd, "rb") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                return False
            digest = hashlib.sha256()
            while True:
                block = handle.read(_COPY_BLOCK)
                if not block:
                    break
                digest.update(block)
        return digest.hexdigest() == sha
