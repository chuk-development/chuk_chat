"""Pictures the user attached to a task, for a vision-capable model
(docs/WIRE_CONTRACT.md, "Attachments to Agents").

The executor stores an upload under ``<workspace>/.agents/inbox/<blob_id>/``
and puts ``attachments`` on the task's user row. With a model the catalogue
marks ``supports_vision``, the loop sends the pictures of the current task as
image parts (:func:`make_image_loader`); otherwise they stay paths in the
prompt and the agent reads them with its tools.
"""

from __future__ import annotations

import os
import stat
from typing import Any

IMAGE_MIME = frozenset({"image/png", "image/jpeg", "image/webp", "image/gif"})
MAX_IMAGE_BYTES = 8 * 1024 * 1024
INBOX_PREFIX = ".agents/inbox/"


def model_supports_vision(model: Any) -> bool:
    """True when a layer of the model client (through ``inner``) says it
    takes images (``supports_vision``). Unknown = no."""
    seen = 0
    current = model
    while current is not None and seen < 6:
        flag = getattr(current, "supports_vision", None)
        if isinstance(flag, bool):
            return flag
        current = getattr(current, "inner", None)
        seen += 1
    return False


def open_dir_nofollow(root: str, parts: list[str] | tuple[str, ...], *, create: bool = False) -> int:
    """A directory fd for ``root/parts...`` that never follows a symlink.

    ``root`` itself is trusted (a host path). Every part below it is opened
    with ``O_NOFOLLOW`` relative to its parent's fd, so an agent that plants a
    symlink anywhere on the way (``.agents``, ``.agents/inbox``, the blob
    directory) makes this raise :class:`OSError` instead of leading the host
    out of the workspace. ``create`` makes missing directories (``mkdir`` at
    the parent fd, also no follow). The caller closes the fd.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(root, flags)
    try:
        for part in parts:
            if not part or part in (".", "..") or "/" in part or "\\" in part:
                raise OSError(f"bad path part {part!r}")
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, flags | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_regular_nofollow(root: str, rel: str, *, max_bytes: int) -> bytes | None:
    """The bytes of the regular file ``root/rel`` (at most ``max_bytes``), or
    ``None`` when a part of the path is a symlink, the file is no regular file,
    or it is larger. Never follows a symlink."""
    parts = [p for p in rel.split("/") if p]
    if not parts:
        return None
    try:
        dir_fd = open_dir_nofollow(root, parts[:-1])
    except OSError:
        return None
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=dir_fd)
    except OSError:
        return None
    finally:
        os.close(dir_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > max_bytes:
            return None
        chunks = []
        remaining = max_bytes + 1
        while remaining > 0:
            block = os.read(fd, min(remaining, 1 << 20))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
        return None if len(data) > max_bytes else data
    except OSError:
        return None
    finally:
        os.close(fd)


def make_image_loader(workspace: str | None):
    """``loader(attachment) -> (bytes, mime) | None``. Reads only a picture
    inside ``<workspace>/.agents/inbox/``, of an image type, up to
    :data:`MAX_IMAGE_BYTES`. No part of the path may be a symlink (the agent
    can write the workspace; a planted link must not show the model a host
    file)."""
    if not workspace:
        return None

    def load(attachment: dict) -> tuple[bytes, str] | None:
        rel = attachment.get("path")
        mime = str(attachment.get("mime") or "").lower()
        if not isinstance(rel, str) or not rel.startswith(INBOX_PREFIX) or mime not in IMAGE_MIME:
            return None
        if any(part in ("", ".", "..") for part in rel.split("/")):
            return None
        data = read_regular_nofollow(workspace, rel, max_bytes=MAX_IMAGE_BYTES)
        if data is None:
            return None
        return data, mime

    return load


__all__ = [
    "IMAGE_MIME",
    "MAX_IMAGE_BYTES",
    "make_image_loader",
    "model_supports_vision",
    "open_dir_nofollow",
    "read_regular_nofollow",
]
