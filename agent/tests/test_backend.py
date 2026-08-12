"""BackendModelClient + SupabaseSession, tested against a local mock ``/v2/ws``
server and a mocked GoTrue — no real credits, no network.

The mock server replicates the confirmed protocol: the auth handshake, ping/pong,
and the chat frame stream (content / reasoning / usage / error / done), routed by
``req_id``. A token of ``"expired"`` is rejected with ``auth_error`` so the refresh
+ reconnect path is exercised.
"""

from __future__ import annotations

import json
import os
import threading

import httpx
import pytest
from websockets.sync.server import serve

from cowork_agent.backend import (
    BackendModelClient,
    BackendModelError,
    SupabaseSession,
    fetch_models_info,
    login,
    resolve_model,
)


# -- a mock /v2/ws server ----------------------------------------------------


class MockWsServer:
    """A local websockets server that speaks the ChukChat ``/v2/ws`` protocol.

    ``script`` maps the chat payload's ``message`` to a list of outgoing frame
    dicts (without ``req_id``/``kind`` fixed up) — the test decides what the
    "model" streams back. A ``valid_tokens`` set gates the handshake.
    """

    def __init__(self, script, *, valid_tokens):
        self._script = script
        self._valid_tokens = valid_tokens
        self._server = serve(self._handler, "127.0.0.1", 0)
        self.auth_tokens_seen: list[str] = []
        sock = self._server.socket.getsockname()
        self.url = f"ws://{sock[0]}:{sock[1]}/v2/ws"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def _handler(self, ws):
        # 1. Handshake.
        raw = ws.recv()
        frame = json.loads(raw)
        assert frame["type"] == "auth"
        token = frame["token"]
        self.auth_tokens_seen.append(token)
        if token not in self._valid_tokens:
            ws.send(json.dumps({"type": "auth_error", "detail": "token rejected"}))
            return
        ws.send(json.dumps({"type": "auth_ok"}))

        # 2. Serve chat requests until the client goes away.
        try:
            while True:
                raw = ws.recv()
                frame = json.loads(raw)
                if frame.get("type") == "ping":
                    ws.send(json.dumps({"type": "pong"}))
                    continue
                if frame.get("type") != "chat":
                    continue
                req_id = frame["req_id"]
                message = frame["payload"].get("message", "")
                for out in self._script(message, frame["payload"]):
                    out = dict(out)
                    out["req_id"] = req_id
                    ws.send(json.dumps(out))
        except Exception:
            return

    def stop(self):
        self._server.shutdown()


def _session(token="valid-token", *, refresh_token="refresh-1", http_client=None):
    return SupabaseSession(
        access_token=token,
        refresh_token=refresh_token,
        supabase_url="https://proj.supabase.co",
        anon_key="anon-key",
        http_client=http_client,
    )


def _client(server, session, **kw):
    # base_url is the ws server; _ws_url_from_base turns ws://host/v2/ws through.
    base = server.url[: -len("/v2/ws")]  # strip the path the client re-adds
    return BackendModelClient(
        session,
        model_id="openai/gpt-oss-20b",
        provider_slug="groq",
        base_url=base,
        **kw,
    )


# -- chat / accumulation ------------------------------------------------------


def test_auth_and_chat_accumulates_content():
    def script(message, payload):
        return [
            {"kind": "content", "data": "Hello "},
            {"kind": "content", "data": "world"},
            {"kind": "usage", "data": {"total_tokens": 5}},
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        resp = client.complete([{"role": "user", "content": "hi"}])
        assert resp.text == "Hello world"
        assert resp.raw["usage"] == {"total_tokens": 5}
        assert not resp.has_tool_calls
        client.close()
    finally:
        server.stop()


def test_reasoning_is_separate_channel_not_folded_into_text():
    def script(message, payload):
        return [
            {"kind": "reasoning", "data": "let me think"},
            {"kind": "content", "data": "answer"},
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        resp = client.complete([{"role": "user", "content": "hi"}])
        assert resp.text == "answer"
        assert resp.raw["reasoning"] == "let me think"
        client.close()
    finally:
        server.stop()


def test_tool_call_parsed_from_content_stream():
    def script(message, payload):
        block = '<tool_call>{"name":"run_command","arguments":{"command":"ls"}}</tool_call>'
        return [
            {"kind": "content", "data": "running "},
            {"kind": "content", "data": block},
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        resp = client.complete([{"role": "user", "content": "list files"}])
        assert resp.has_tool_calls
        assert resp.tool_calls[0].name == "run_command"
        assert resp.tool_calls[0].arguments == {"command": "ls"}
        assert resp.text == "running"  # the <tool_call> block is stripped
        client.close()
    finally:
        server.stop()


def test_error_frame_surfaces_as_exception():
    def script(message, payload):
        return [{"kind": "error", "detail": "model exploded", "code": "500"}]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        with pytest.raises(BackendModelError) as exc:
            client.complete([{"role": "user", "content": "hi"}])
        assert exc.value.detail == "model exploded"
        assert exc.value.code == "500"
        client.close()
    finally:
        server.stop()


def test_payload_carries_system_prompt_history_and_params():
    seen = {}

    def script(message, payload):
        seen.update(payload)
        return [{"kind": "content", "data": "ok"}, {"kind": "done"}]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(
            server, _session(), max_tokens=1234, temperature=0.3, reasoning_effort="high"
        )
        client.complete(
            [
                {"role": "system", "content": "be terse"},
                {"role": "user", "content": "first"},
                {"role": "assistant", "content": "prior answer"},
                {"role": "user", "content": "second"},
            ]
        )
        assert seen["message"] == "second"
        assert seen["system_prompt"] == "be terse"
        assert seen["model_id"] == "openai/gpt-oss-20b"
        assert seen["provider_slug"] == "groq"
        assert seen["max_tokens"] == 1234
        assert seen["temperature"] == 0.3
        assert seen["reasoning_effort"] == "high"
        # history is everything before the last turn (minus the system prompt).
        assert seen["history"] == [
            {"role": "user", "content": "first"},
            {"role": "assistant", "content": "prior answer"},
        ]
        client.close()
    finally:
        server.stop()


# -- refresh / reconnect ------------------------------------------------------


def _gotrue_transport(new_token="fresh-token"):
    """An httpx MockTransport standing in for Supabase GoTrue: a refresh returns a
    fresh access token; a password login returns a full session."""
    calls = {"refresh": 0, "password": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        grant = request.url.params.get("grant_type")
        assert request.headers["apikey"] == "anon-key"
        body = json.loads(request.content)
        if grant == "refresh_token":
            calls["refresh"] += 1
            assert body["refresh_token"]
            return httpx.Response(
                200,
                json={
                    "access_token": new_token,
                    "refresh_token": "refresh-2",
                    "expires_in": 3600,
                },
            )
        if grant == "password":
            calls["password"] += 1
            assert body["email"] and body["password"]
            return httpx.Response(
                200,
                json={
                    "access_token": new_token,
                    "refresh_token": "refresh-login",
                    "expires_in": 3600,
                },
            )
        return httpx.Response(400, json={"error": "bad grant"})

    return httpx.Client(transport=httpx.MockTransport(handler)), calls


def test_auth_error_triggers_refresh_then_reconnects():
    def script(message, payload):
        return [{"kind": "content", "data": "after refresh"}, {"kind": "done"}]

    # Server accepts only the FRESH token, so the first (expired) connect is
    # rejected with auth_error, forcing a refresh + reconnect.
    server = MockWsServer(script, valid_tokens={"fresh-token"})
    http, calls = _gotrue_transport(new_token="fresh-token")
    try:
        session = _session(token="expired", http_client=http)
        client = _client(server, session)
        resp = client.complete([{"role": "user", "content": "hi"}])
        assert resp.text == "after refresh"
        assert calls["refresh"] == 1
        assert session.access_token == "fresh-token"
        # The server saw the expired token first, then the refreshed one.
        assert server.auth_tokens_seen == ["expired", "fresh-token"]
        client.close()
    finally:
        server.stop()
        http.close()


def test_session_refresh_absorbs_new_tokens():
    http, calls = _gotrue_transport(new_token="rotated")
    try:
        session = _session(token="old", refresh_token="r-old", http_client=http)
        session.refresh()
        assert session.access_token == "rotated"
        assert session.refresh_token == "refresh-2"
        assert session.expires_at is not None
        assert calls["refresh"] == 1
    finally:
        http.close()


def test_login_helper_trades_credentials_for_a_session():
    http, calls = _gotrue_transport()
    try:
        session = login(
            "user@example.com",
            "pw",
            supabase_url="https://proj.supabase.co",
            anon_key="anon-key",
            http_client=http,
        )
        assert session.access_token == "fresh-token"
        assert session.refresh_token == "refresh-login"
        assert calls["password"] == 1
    finally:
        http.close()


# -- model / provider resolution ---------------------------------------------


_MODELS = [
    {
        "id": "openai/gpt-oss-20b",
        "name": "GPT-OSS 20B",
        "providers": [
            {"slug": "groq", "pricing": {"completion": 0.0002}},
            {"slug": "fireworks", "pricing": {"completion": 0.0009}},
        ],
    },
    {
        "id": "meta/llama-3",
        "name": "Llama 3",
        "providers": [{"slug": "together", "pricing": {"completion": 0.0005}}],
    },
]


def test_resolve_model_defaults_and_cheapest_provider():
    resolved = resolve_model(_MODELS)
    assert resolved.model_id == "openai/gpt-oss-20b"
    assert resolved.provider_slug == "groq"  # cheapest completion price


def test_resolve_model_honours_preferences():
    resolved = resolve_model(
        _MODELS,
        preferred_model_id="meta/llama-3",
        preferred_provider="together",
    )
    assert resolved.model_id == "meta/llama-3"
    assert resolved.provider_slug == "together"


def test_resolve_model_falls_back_to_first_when_default_absent():
    resolved = resolve_model(_MODELS, default_model_id="does/not-exist")
    assert resolved.model_id == "openai/gpt-oss-20b"


def test_fetch_models_info_uses_bearer_token():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"] = request.headers.get("Authorization")
        seen["path"] = request.url.path
        return httpx.Response(200, json=_MODELS)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        models = fetch_models_info(_session(token="tok"), http_client=http)
        assert seen["auth"] == "Bearer tok"
        assert seen["path"] == "/v1/models_info"
        assert len(models) == 2
    finally:
        http.close()


# -- optional live smoke test (never required, never hardcodes creds) --------


@pytest.mark.skipif(
    not (
        os.getenv("COWORK_LIVE_ACCESS_TOKEN")
        or (os.getenv("COWORK_LIVE_EMAIL") and os.getenv("COWORK_LIVE_PASSWORD"))
    ),
    reason="live smoke test needs COWORK_LIVE_ACCESS_TOKEN or COWORK_LIVE_EMAIL/PASSWORD",
)
def test_live_smoke_real_backend():  # pragma: no cover - opt-in, spends real credits
    supabase_url = os.environ["COWORK_LIVE_SUPABASE_URL"]
    anon_key = os.environ["COWORK_LIVE_SUPABASE_ANON_KEY"]
    token = os.getenv("COWORK_LIVE_ACCESS_TOKEN")
    if token:
        session = SupabaseSession(
            access_token=token,
            refresh_token=os.getenv("COWORK_LIVE_REFRESH_TOKEN", ""),
            supabase_url=supabase_url,
            anon_key=anon_key,
        )
    else:
        session = login(
            os.environ["COWORK_LIVE_EMAIL"],
            os.environ["COWORK_LIVE_PASSWORD"],
            supabase_url=supabase_url,
            anon_key=anon_key,
        )
    models = fetch_models_info(session)
    resolved = resolve_model(models)
    client = BackendModelClient(
        session, model_id=resolved.model_id, provider_slug=resolved.provider_slug
    )
    resp = client.complete(
        [{"role": "user", "content": "Reply with the single word: pong"}]
    )
    assert resp.text
    client.close()
