"""Pull file bytes back *out* of the environment (§9).

Most tools only need to run a command. Three do not: ``read_document`` has to
hand the bytes to anydoc, which runs in this process, and ``send_file_to_user``
has to put the bytes on the wire to the phone. Neither can open the file: the
only seam between the runtime and the sandbox is
:meth:`~cowork_agent.environment.Environment.run_bash` (§7.3). So the bytes come
back the way ``write_file`` sends them in — base64 over the command channel.

**Why chunked.** The sandbox base class bounds captured output
(``cowork_sandbox.base.DEFAULT_MAX_OUTPUT_CHARS`` = 100 000 chars) so that one
command cannot blow up the context window. A single ``base64 file`` of anything
larger than ~73 KB would therefore come back silently *truncated*. This module
reads the file in fixed blocks whose base64 form stays well inside that bound,
and verifies the total against the size measured up front, so a truncated
transfer is an error and never a silently corrupt file.

Everything here is environment-agnostic: it works the same against
``LocalEnvironment`` and against a Docker sandbox, and it needs no host-side
filesystem access.
"""

from __future__ import annotations

import base64
import binascii
import shlex
from dataclasses import dataclass

from .environment import Environment

# Raw bytes per round trip. 48 KiB of input is 65 536 base64 characters — a
# third under the sandbox's 100 000-char output bound, leaving room for the
# shell's own noise.
CHUNK_BYTES = 48 * 1024

# Default ceiling for one transfer. Callers set their own (a document may be
# larger than a file we are willing to push into a chat thread).
DEFAULT_MAX_BYTES = 8 * 1024 * 1024


class TransferError(RuntimeError):
    """A file could not be read out of the environment, for a reason the model
    can act on (missing, empty, too large, truncated)."""


@dataclass(frozen=True)
class FetchedFile:
    """One file, fully transferred and length-checked."""

    path: str
    size: int
    data: bytes


def stat_file(env: Environment, path: str, *, timeout: int = 30) -> int:
    """Size of a regular file, in bytes. Raises :class:`TransferError` if the
    path is not a readable regular file (a directory, a device, or missing)."""
    quoted = shlex.quote(path)
    result = env.run_bash(f"test -f {quoted} && wc -c < {quoted}", timeout=timeout)
    if not result.ok:
        raise TransferError(f"not a readable file: {path}")
    fields = (result.stdout or "").split()
    if not fields:
        raise TransferError(f"could not measure file: {path}")
    try:
        return int(fields[0])
    except ValueError:
        raise TransferError(f"could not measure file: {path}") from None


def fetch_bytes(
    env: Environment,
    path: str,
    *,
    max_bytes: int = DEFAULT_MAX_BYTES,
    chunk_bytes: int = CHUNK_BYTES,
    timeout: int = 120,
) -> FetchedFile:
    """Read ``path`` out of the environment and return its exact bytes.

    The size is measured first, so an oversized file is refused *before* a
    single byte moves. Each block is decoded with ``validate=True`` and the
    total is compared with the measured size, which is what turns a truncated
    read into an error instead of a corrupt file.
    """
    size = stat_file(env, path, timeout=timeout)
    if size <= 0:
        raise TransferError(f"file is empty: {path}")
    if size > max_bytes:
        raise TransferError(
            f"file is {size} bytes, over the {max_bytes} byte limit for this tool"
        )

    quoted = shlex.quote(path)
    block = max(1024, int(chunk_bytes))
    out = bytearray()
    index = 0
    while len(out) < size:
        # dd on exact block boundaries: no re-reading the head of the file for
        # every chunk, and no reliance on GNU-only flags.
        cmd = (
            f"dd if={quoted} bs={block} skip={index} count=1 2>/dev/null "
            f"| base64 | tr -d '\\n'"
        )
        result = env.run_bash(cmd, timeout=timeout)
        if not result.ok:
            raise TransferError(
                f"read failed at byte {len(out)} of {path}: "
                f"{(result.stderr or 'command failed').strip()}"
            )
        payload = (result.stdout or "").strip()
        if not payload:
            raise TransferError(f"transfer stalled at byte {len(out)} of {path}")
        try:
            chunk = base64.b64decode(payload, validate=True)
        except (binascii.Error, ValueError):
            raise TransferError(
                f"transfer of {path} came back truncated or not base64"
            ) from None
        if not chunk:
            raise TransferError(f"transfer stalled at byte {len(out)} of {path}")
        out += chunk
        index += 1
        if len(out) > size:
            raise TransferError(f"{path} grew while it was being read")

    if len(out) != size:
        raise TransferError(f"read {len(out)} bytes of {path}, expected {size}")
    return FetchedFile(path=path, size=size, data=bytes(out))
