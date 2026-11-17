"""Agent avatars on the host (docs/agents/NOTIFICATIONS.md, CHAT-128).

The host draws no avatar. The app sends each agent's face as a PNG over the
sealed relay:

    {"type": "agent_avatar_set", "agent_id": "<id>", "png_b64": "<PNG>"}

The host checks the PNG signature and the size, and keeps the file as
``<workspace>/avatars/<agent_id>.png``. The desktop toast uses it as its icon.

An agent id is a file name here. So the id must be short and use only
``[A-Za-z0-9:_.-]``. A ``:`` becomes ``_`` in the file name, because Windows
does not allow ``:`` in a file name. Two ids that differ only in ``:`` versus
``_`` share one file. The app makes ids as ``local:<uuid>`` or
``host:<uuid>``, so this does not occur.
"""

from __future__ import annotations

import base64
import binascii
import os
import re
import tempfile
from pathlib import Path
from typing import Any

#: The frame type (app -> host).
AVATAR_SET_FRAME = "agent_avatar_set"
#: The answer frame type (host -> app): a small acknowledgement.
AVATAR_ANSWER = "agent_avatar"
#: Named in ``host_route.capabilities``: this host keeps avatars.
AVATAR_CAPABILITY = "agent_avatar"

#: The largest PNG the host keeps.
MAX_AVATAR_BYTES = 128 * 1024

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

_SAFE_ID = re.compile(r"^[A-Za-z0-9:_.-]{1,128}$")


def safe_agent_id(agent_id: object) -> str | None:
    """The file stem for ``agent_id``, or None when the id is not safe.

    No path separators, no ``..``, no leading dot, only ``[A-Za-z0-9:_.-]``."""
    if not isinstance(agent_id, str) or not _SAFE_ID.match(agent_id):
        return None
    if agent_id.startswith(".") or ".." in agent_id:
        return None
    return agent_id.replace(":", "_")


class AvatarStore:
    """Keeps one PNG per agent under ``<root>``."""

    def __init__(self, root: Path) -> None:
        self._root = Path(root)

    @property
    def root(self) -> Path:
        return self._root

    def path_for(self, agent_id: object) -> Path | None:
        stem = safe_agent_id(agent_id)
        return None if stem is None else self._root / f"{stem}.png"

    def icon_for(self, agent_id: object) -> str | None:
        """The absolute path of the agent's avatar, or None when there is none."""
        path = self.path_for(agent_id)
        if path is None:
            return None
        try:
            return str(path.resolve()) if path.is_file() else None
        except OSError:
            return None

    def save(self, agent_id: object, png: bytes) -> Path:
        """Check ``png`` and write it atomically. Raises ``ValueError`` with a
        short reason when the id or the data is not valid."""
        path = self.path_for(agent_id)
        if path is None:
            raise ValueError("agent_id is not valid")
        if not isinstance(png, (bytes, bytearray)) or not png:
            raise ValueError("png is empty")
        if len(png) > MAX_AVATAR_BYTES:
            raise ValueError("png is larger than 128 KB")
        if not bytes(png[:8]) == PNG_SIGNATURE:
            raise ValueError("data is not a PNG")
        self._root.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".avatar-", suffix=".tmp", dir=str(self._root))
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(bytes(png))
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return path

    def handle_frame(self, payload: Any) -> dict[str, Any]:
        """Apply one ``agent_avatar_set`` frame. Returns the answer frame:
        ``{"type": "agent_avatar", "agent_id": .., "ok": true}``, or with
        ``ok: false`` and an ``error``. Never raises."""
        agent_id = payload.get("agent_id") if isinstance(payload, dict) else None
        answer: dict[str, Any] = {
            "type": AVATAR_ANSWER,
            "agent_id": agent_id if isinstance(agent_id, str) else "",
        }
        data = payload.get("png_b64") if isinstance(payload, dict) else None
        if not isinstance(data, str) or not data:
            return {**answer, "ok": False, "error": "png_b64 is required"}
        # Base64 is 4/3 of the data: refuse a too large string before decoding.
        if len(data) > (MAX_AVATAR_BYTES * 4) // 3 + 8:
            return {**answer, "ok": False, "error": "png is larger than 128 KB"}
        try:
            png = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError):
            return {**answer, "ok": False, "error": "png_b64 is not base64"}
        try:
            self.save(agent_id, png)
        except ValueError as exc:
            return {**answer, "ok": False, "error": str(exc)}
        except OSError as exc:
            return {**answer, "ok": False, "error": f"could not store: {type(exc).__name__}"}
        return {**answer, "ok": True}
