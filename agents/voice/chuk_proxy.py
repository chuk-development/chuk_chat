"""Auth for the chuk API proxy — the worker holds no provider keys.

LLM, STT and TTS run through ``CHUK_API_BASE`` (api.chuk.chat), which bills the
user's credits. Every worker -> api request carries two headers:

* ``Authorization: Bearer <worker_jwt>`` — HS256, signed with
  ``LIVEKIT_API_SECRET``, ``iss`` = ``LIVEKIT_API_KEY``,
  ``sub`` = ``chuk-voice-worker``, ``exp`` = now + 5 min. :class:`WorkerToken`
  re-mints it before it expires.
* ``X-Chuk-Voice-Grant: <voice_grant>`` — the opaque grant from the dispatch
  metadata. It ties the request to the user who started the call.

:func:`make_client` builds one ``openai.AsyncClient`` per call with both. The
OpenAI SDK asks the token provider for the bearer token before every request,
so a long call never sends an expired token.

This module imports no LiveKit code, so the unit tests run without a room.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable

import jwt
import openai

#: The api_server base URL. The OpenAI-compatible routes hang below it.
DEFAULT_API_BASE = "https://api.chuk.chat/v1"

#: ``sub`` claim of every worker token.
WORKER_SUBJECT = "chuk-voice-worker"

#: Lifetime of one worker token.
TOKEN_TTL_SECONDS = 300

#: Re-mint when less than this is left, so a token never expires in flight.
REMINT_MARGIN_SECONDS = 60

GRANT_HEADER = "X-Chuk-Voice-Grant"


def api_base() -> str:
    """``CHUK_API_BASE`` without a trailing slash (default: api.chuk.chat)."""
    return (os.environ.get("CHUK_API_BASE") or DEFAULT_API_BASE).rstrip("/")


def mint_worker_jwt(api_key: str, api_secret: str, *, now: float, ttl: int = TOKEN_TTL_SECONDS) -> str:
    """One HS256 worker token, valid from ``now`` for ``ttl`` seconds."""
    if not api_key or not api_secret:
        raise ValueError("LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set")
    issued = int(now)
    claims = {
        "iss": api_key,
        "sub": WORKER_SUBJECT,
        "iat": issued,
        "exp": issued + int(ttl),
    }
    return jwt.encode(claims, api_secret, algorithm="HS256")


class WorkerToken:
    """A cached worker token that re-mints itself before it expires."""

    def __init__(
        self,
        api_key: str,
        api_secret: str,
        *,
        clock: Callable[[], float] = time.time,
        ttl: int = TOKEN_TTL_SECONDS,
        margin: int = REMINT_MARGIN_SECONDS,
    ) -> None:
        if not api_key or not api_secret:
            raise ValueError("LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set")
        self._key = api_key
        self._secret = api_secret
        self._clock = clock
        self._ttl = ttl
        self._margin = margin
        self._token = ""
        self._expires_at = 0.0

    @classmethod
    def from_env(cls) -> WorkerToken:
        return cls(os.environ.get("LIVEKIT_API_KEY", ""), os.environ.get("LIVEKIT_API_SECRET", ""))

    def get(self) -> str:
        now = self._clock()
        if not self._token or self._expires_at - now < self._margin:
            self._token = mint_worker_jwt(self._key, self._secret, now=now, ttl=self._ttl)
            self._expires_at = int(now) + self._ttl
        return self._token

    async def aget(self) -> str:
        """Async form: the OpenAI SDK calls this before each request."""
        return self.get()


def grant_headers(voice_grant: str) -> dict[str, str]:
    """The per-call headers. The grant is opaque; it is never logged."""
    return {GRANT_HEADER: voice_grant}


def make_client(
    token: WorkerToken,
    voice_grant: str,
    *,
    base_url: str | None = None,
    timeout: float = 30.0,
) -> openai.AsyncClient:
    """An OpenAI client for the chuk proxy, bound to one call's grant."""
    return openai.AsyncClient(
        api_key=token.aget,
        base_url=base_url or api_base(),
        default_headers=grant_headers(voice_grant),
        timeout=timeout,
    )


__all__ = [
    "DEFAULT_API_BASE",
    "GRANT_HEADER",
    "REMINT_MARGIN_SECONDS",
    "TOKEN_TTL_SECONDS",
    "WORKER_SUBJECT",
    "WorkerToken",
    "api_base",
    "grant_headers",
    "make_client",
    "mint_worker_jwt",
]
