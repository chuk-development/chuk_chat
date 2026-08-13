"""``send_file_to_user`` — push a produced file into the chat thread (§9).

A CSV the agent generated, a rendered PDF, a chart, a browser screenshot, a
converted video: the user has to *get* it, and the workspace lives inside a
container on their laptop, not on their phone. The path back is the one channel
that already exists and is already encrypted — the executor's event stream
(``delta`` / ``tool`` / ``done``). This module is the agent-side half: it lifts
the bytes out of the sandbox and hands them to a :class:`FileSink`. The executor
binds that sink to a sealed ``file`` event
(:func:`cowork_executor.protocol.file_payload`); a test binds it to a list.

Two things this deliberately does **not** do:

- It never returns the file content to the model. The tool result goes into the
  prompt on every following turn (§7.9); a 4 MB base64 blob there would be
  ruinous and pointless — the bytes are for the user, not for the model.
- It never sends an unbounded file. :data:`MAX_FILE_BYTES` is a hard ceiling,
  checked against the file's measured size *before* any byte is transferred, so
  an oversized file costs one ``wc -c`` and is refused with a message the model
  can act on (compress it, split it, send a link) instead of flooding the relay.

The sink may raise; the raise is caught and reported as a normal tool failure,
which is what makes the executor's own second size gate safe to add.
"""

from __future__ import annotations

import mimetypes
import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import PurePosixPath

from .environment import Environment
from .registry import ToolRegistry
from .sandbox_io import TransferError, fetch_bytes

# The hard ceiling for one file, raw bytes before any encoding. The payload is
# base64 inside the sealed frame and the sealed frame is base64 again inside the
# relay envelope, so 8 MiB on disk is roughly 11 MiB of frame and 15 MiB of
# envelope line. That is the largest thing worth pushing through a phone
# connection in one piece; past it the agent should compress or split. It is
# also a time bound: the bytes leave the sandbox in 48 KiB blocks
# (:mod:`cowork_agent.sandbox_io`), so 8 MiB is on the order of 170 round trips.
MAX_FILE_BYTES = 8 * 1024 * 1024

DEFAULT_MIME = "application/octet-stream"

# Names travel to a UI and may be used to save a file. Keep them boring.
NAME_CAP = 120
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._\- ()\[\]]+")

SEND_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Send a file from the workspace to the user, so it appears in the chat "
        "as a download. Use it for anything you produced that the user needs to "
        "have: a CSV, a PDF, an image, a screenshot, a converted video. The file "
        "must already exist; write it first."
    ),
    "properties": {
        "path": {
            "type": "string",
            "description": "File path, relative to the workspace or absolute.",
        },
        "name": {
            "type": "string",
            "description": (
                "Name to show the user. Defaults to the file's own name."
            ),
        },
    },
    "required": ["path"],
}


@dataclass(frozen=True)
class SentFile:
    """One file on its way to the user."""

    name: str
    mime_type: str
    size: int
    data: bytes


# What the executor binds. Raising is allowed and is reported to the model.
FileSink = Callable[[SentFile], None]


def sanitize_name(raw: str, *, fallback: str = "file") -> str:
    """Reduce a name to something safe to show and to save.

    Any directory part is dropped (a name is not a path), control characters and
    separators go, and the result is length-capped. A name that reduces to
    nothing — ``".."``, ``"/"``, all control characters — becomes ``fallback``.
    """
    candidate = PurePosixPath((raw or "").strip()).name
    candidate = candidate.replace("\\", "/").split("/")[-1]
    candidate = _UNSAFE_NAME.sub("_", candidate).strip(" .")
    if not candidate:
        return fallback
    if len(candidate) <= NAME_CAP:
        return candidate
    stem = PurePosixPath(candidate).stem[: NAME_CAP - 20]
    suffix = PurePosixPath(candidate).suffix[:20]
    return f"{stem}{suffix}" or fallback


def guess_mime(name: str) -> str:
    guessed, _ = mimetypes.guess_type(name)
    return guessed or DEFAULT_MIME


def make_send_file_handler(
    env: Environment,
    sink: FileSink,
    *,
    max_bytes: int = MAX_FILE_BYTES,
):
    """Build the ``send_file_to_user`` handler around one sink."""

    def send_file_to_user(path: str, name: str | None = None) -> dict:
        text_path = (path if isinstance(path, str) else str(path or "")).strip()
        if not text_path:
            return {"ok": False, "error": "path is empty"}

        try:
            fetched = fetch_bytes(env, text_path, max_bytes=max_bytes)
        except TransferError as exc:
            return {"ok": False, "path": text_path, "error": str(exc)}

        shown = sanitize_name(
            name or text_path,
            fallback=sanitize_name(text_path, fallback="file"),
        )
        sent = SentFile(
            name=shown,
            mime_type=guess_mime(shown),
            size=fetched.size,
            data=fetched.data,
        )
        try:
            sink(sent)
        except Exception as exc:
            return {
                "ok": False,
                "path": text_path,
                "error": f"could not send {shown}: {type(exc).__name__}: {exc}",
            }
        # No content in the result: the bytes went to the user, not the prompt.
        return {
            "ok": True,
            "path": text_path,
            "name": shown,
            "mime_type": sent.mime_type,
            "bytes": sent.size,
        }

    return send_file_to_user


def register_send_file(
    registry: ToolRegistry,
    env: Environment,
    sink: FileSink | None,
    *,
    max_bytes: int = MAX_FILE_BYTES,
) -> None:
    """Register ``send_file_to_user``.

    Without a sink there is nowhere to send to — the tool is not registered at
    all, so it costs no prompt tokens in a run that has no channel to the user
    (a cron run, a subagent).
    """
    if sink is None:
        return
    registry.register(
        "send_file_to_user",
        SEND_FILE_SCHEMA,
        make_send_file_handler(env, sink, max_bytes=max_bytes),
    )


__all__ = [
    "DEFAULT_MIME",
    "MAX_FILE_BYTES",
    "NAME_CAP",
    "FileSink",
    "SentFile",
    "guess_mime",
    "make_send_file_handler",
    "register_send_file",
    "sanitize_name",
]
