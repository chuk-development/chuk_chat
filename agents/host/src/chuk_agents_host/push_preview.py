"""The sealed preview of a push (docs/agents/NOTIFICATIONS.md, CHAT-128).

A push goes through Supabase and FCM, which are not end-to-end. So the text
that the user can read (the answer preview) goes only sealed. The key comes
from the pairing: both the host and the app hold the 32-byte channel key.

    push_key = HMAC-SHA256(channel_key, b"cowork/push/preview/v1")
    sealed   = base64(nonce || AES-256-GCM(push_key, nonce, plaintext) || tag)

The nonce has 12 random bytes. There is no AAD. The plaintext is UTF-8 JSON
(:func:`preview_plaintext`). The host seals once per stored trust record and
writes ``{channel_id: sealed}`` into the row's ``preview_sealed`` column.
"""

from __future__ import annotations

import base64
import json
import os
from collections.abc import Iterable
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .controller_sessions import mac

PUSH_PREVIEW_LABEL = "cowork/push/preview/v1"
PREVIEW_VERSION = 1
NONCE_BYTES = 12


def push_key(channel_key: bytes) -> bytes:
    """The AES-256 key of the sealed preview, derived from the channel key."""
    if len(channel_key) != 32:
        raise ValueError("channel key must be 32 bytes")
    return mac(channel_key, PUSH_PREVIEW_LABEL, b"")


def preview_plaintext(
    *, title: str, body: str, agent_id: str, session_key: str, run_id: str
) -> bytes:
    """The plaintext JSON. Compact, keys in this order, UTF-8 (no ``\\u``
    escapes), so the test vector is the same bytes in Python and Dart."""
    payload = {
        "v": PREVIEW_VERSION,
        "title": title,
        "body": body,
        "agent_id": agent_id,
        "session_key": session_key,
        "run_id": run_id,
    }
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def seal_preview(channel_key: bytes, plaintext: bytes, *, nonce: bytes | None = None) -> str:
    """Seal ``plaintext`` for one pairing. ``nonce`` is for the test vector
    only; normal calls get 12 random bytes."""
    nonce = os.urandom(NONCE_BYTES) if nonce is None else nonce
    if len(nonce) != NONCE_BYTES:
        raise ValueError("nonce must be 12 bytes")
    sealed = AESGCM(push_key(channel_key)).encrypt(nonce, plaintext, None)
    return base64.b64encode(nonce + sealed).decode("ascii")


def open_preview(channel_key: bytes, sealed_b64: str) -> bytes:
    """Open a sealed preview (the app's side; used by the tests)."""
    raw = base64.b64decode(sealed_b64, validate=True)
    if len(raw) < NONCE_BYTES + 16:
        raise ValueError("sealed preview is too short")
    return AESGCM(push_key(channel_key)).decrypt(raw[:NONCE_BYTES], raw[NONCE_BYTES:], None)


def seal_for_trusts(trusts: Iterable[Any], plaintext: bytes) -> dict[str, str]:
    """``{channel_id: sealed}`` for every trust record with a valid key.
    A record without a channel id or a 32-byte key is skipped."""
    out: dict[str, str] = {}
    for trust in trusts:
        channel_id = getattr(trust, "channel_id", None)
        channel_key = getattr(trust, "channel_key", None)
        if not isinstance(channel_id, str) or not channel_id:
            continue
        if not isinstance(channel_key, (bytes, bytearray)) or len(channel_key) != 32:
            continue
        out[channel_id] = seal_preview(bytes(channel_key), plaintext)
    return out
