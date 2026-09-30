"""Worker JWT minting and the proxy headers (no network, no LiveKit room)."""

from __future__ import annotations

import asyncio

import jwt
import pytest

import chuk_proxy
from chuk_proxy import GRANT_HEADER, WORKER_SUBJECT, WorkerToken, make_client, mint_worker_jwt

KEY = "APItestkey"
SECRET = "test-secret-that-is-long-enough-for-hs256"


class Clock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def _claims(token: str) -> dict:
    return jwt.decode(token, SECRET, algorithms=["HS256"], options={"verify_exp": False, "verify_iat": False})


def test_jwt_has_the_contract_claims_and_is_hs256() -> None:
    token = mint_worker_jwt(KEY, SECRET, now=1_800_000_000.4)
    assert jwt.get_unverified_header(token)["alg"] == "HS256"
    claims = _claims(token)
    assert claims["iss"] == KEY
    assert claims["sub"] == WORKER_SUBJECT == "chuk-voice-worker"
    assert claims["iat"] == 1_800_000_000
    assert claims["exp"] == 1_800_000_000 + 300


def test_jwt_is_signed_with_the_livekit_secret() -> None:
    token = mint_worker_jwt(KEY, SECRET, now=1_800_000_000)
    with pytest.raises(jwt.InvalidSignatureError):
        jwt.decode(token, "another-secret-that-is-long-enough-xx", algorithms=["HS256"],
                   options={"verify_exp": False, "verify_iat": False})


def test_missing_livekit_credentials_fail_loudly() -> None:
    with pytest.raises(ValueError):
        mint_worker_jwt("", SECRET, now=0)
    with pytest.raises(ValueError):
        WorkerToken(KEY, "")


def test_token_is_cached_then_reminted_before_expiry() -> None:
    clock = Clock()
    token = WorkerToken(KEY, SECRET, clock=clock)
    first = token.get()

    clock.now += 200  # 100 s left: still more than the 60 s margin
    assert token.get() == first

    clock.now += 45  # 55 s left: re-mint
    second = token.get()
    assert second != first
    assert _claims(second)["exp"] == int(clock.now) + 300


def test_async_provider_returns_the_same_token() -> None:
    token = WorkerToken(KEY, SECRET, clock=Clock())
    assert asyncio.run(token.aget()) == token.get()


def test_client_sends_the_grant_header_and_a_fresh_jwt(monkeypatch) -> None:
    monkeypatch.delenv("CHUK_API_BASE", raising=False)
    token = WorkerToken(KEY, SECRET, clock=Clock())
    client = make_client(token, "grant-abc")
    try:
        assert str(client.base_url).rstrip("/") == "https://api.chuk.chat/v1"
        assert client.default_headers[GRANT_HEADER] == "grant-abc"
        # The SDK asks the provider for the bearer token before each request.
        bearer = asyncio.run(client._refresh_api_key())
        assert _claims(bearer)["sub"] == "chuk-voice-worker"
        assert client.auth_headers == {"Authorization": f"Bearer {bearer}"}
    finally:
        asyncio.run(client.close())


def test_api_base_comes_from_env(monkeypatch) -> None:
    monkeypatch.setenv("CHUK_API_BASE", "https://staging.example.com/v1/")
    assert chuk_proxy.api_base() == "https://staging.example.com/v1"
    monkeypatch.delenv("CHUK_API_BASE")
    assert chuk_proxy.api_base() == chuk_proxy.DEFAULT_API_BASE
