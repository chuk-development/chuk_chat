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


def make_image_loader(workspace: str | None):
    """``loader(attachment) -> (bytes, mime) | None``. Reads only a picture
    inside ``<workspace>/.agents/inbox/``, of an image type, up to
    :data:`MAX_IMAGE_BYTES`."""
    if not workspace:
        return None
    inbox = os.path.realpath(os.path.join(workspace, INBOX_PREFIX))

    def load(attachment: dict) -> tuple[bytes, str] | None:
        rel = attachment.get("path")
        mime = str(attachment.get("mime") or "").lower()
        if not isinstance(rel, str) or not rel.startswith(INBOX_PREFIX) or mime not in IMAGE_MIME:
            return None
        path = os.path.realpath(os.path.join(workspace, rel))
        if not path.startswith(inbox + os.sep):
            return None
        try:
            if os.path.getsize(path) > MAX_IMAGE_BYTES:
                return None
            with open(path, "rb") as handle:
                return handle.read(), mime
        except OSError:
            return None

    return load


__all__ = ["IMAGE_MIME", "MAX_IMAGE_BYTES", "make_image_loader", "model_supports_vision"]
