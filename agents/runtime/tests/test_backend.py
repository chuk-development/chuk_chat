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
    clamp_reasoning_effort,
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


def test_content_is_never_parsed_for_calls():
    """No text fallback. A turn is a tool-call turn only when the server sent a
    `tool_calls` frame; content that merely *looks* like a call — a name and an
    argument object — is the assistant's answer text and is delivered verbatim.

    This is the whole point of the native migration: one protocol, on its own
    frame, so an answer that quotes JSON can never be executed by accident.
    """
    shaped_like_a_call = '{"name":"run_command","arguments":{"command":"ls"}}'

    def script(message, payload):
        return [
            {"kind": "content", "data": "the call would be "},
            {"kind": "content", "data": shaped_like_a_call},
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        resp = client.complete([{"role": "user", "content": "list files"}])
        assert not resp.has_tool_calls
        assert resp.text == "the call would be " + shaped_like_a_call
        assert resp.raw.get("native") is False
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


def test_native_tools_sent_and_tool_calls_frame_parsed():
    """With tools declared, the payload carries them and a `tool_calls` frame is
    parsed into structured calls. The content of the same turn stays the
    assistant's interim text — the two channels never mix."""
    seen = {}

    def script(message, payload):
        seen.update(payload)
        return [
            {"kind": "content", "data": "sure"},
            {
                "kind": "tool_calls",
                "data": [
                    {
                        "id": "call_9",
                        "type": "function",
                        "function": {
                            "name": "run_command",
                            "arguments": '{"command":"ls"}',
                        },
                    }
                ],
            },
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        client.set_tools(
            [
                {
                    "type": "function",
                    "function": {
                        "name": "run_command",
                        "description": "run a shell command",
                        "parameters": {
                            "type": "object",
                            "properties": {"command": {"type": "string"}},
                            "required": ["command"],
                        },
                    },
                }
            ]
        )
        resp = client.complete([{"role": "user", "content": "list files"}])
        # tools travelled on the wire — presence is what enables native mode
        assert seen["tools"][0]["function"]["name"] == "run_command"
        # the tool_calls frame is the only place a call can come from
        assert resp.has_tool_calls
        assert resp.tool_calls[0].id == "call_9"
        assert resp.tool_calls[0].name == "run_command"
        assert resp.tool_calls[0].arguments == {"command": "ls"}
        assert resp.text == "sure"
        assert resp.raw.get("native") is True
        client.close()
    finally:
        server.stop()


def test_native_history_roundtrip_and_empty_message_after_tools():
    """A stored assistant tool_calls turn + its tool result serialise to native
    OpenAI history (arguments as a JSON string, tool_call_id kept), and the newest
    `message` is empty because the tool results are the model's next input."""
    seen = {}

    def script(message, payload):
        seen.update(payload)
        return [{"kind": "content", "data": "done"}, {"kind": "done"}]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        client.complete(
            [
                {"role": "system", "content": "sys"},
                {"role": "user", "content": "do it"},
                {
                    "role": "assistant",
                    "tool_calls": [
                        {
                            "id": "call_1",
                            "type": "function",
                            "function": {"name": "run_command", "arguments": {"command": "ls"}},
                        }
                    ],
                },
                {
                    "role": "tool",
                    "tool_call_id": "call_1",
                    "name": "run_command",
                    "content": {"stdout": "a\nb"},
                },
            ]
        )
        assert seen["message"] == ""  # tool results are the input, not a user turn
        hist = seen["history"]
        assert hist[0] == {"role": "user", "content": "do it"}
        assistant = hist[1]
        assert assistant["role"] == "assistant"
        assert assistant["content"] is None  # tool-calls-only turn, like chuk
        # arguments serialised to a JSON STRING on the wire, not a dict
        assert assistant["tool_calls"][0]["function"]["arguments"] == '{"command":"ls"}'
        assert assistant["tool_calls"][0]["id"] == "call_1"
        tool_turn = hist[2]
        assert tool_turn["role"] == "tool"
        assert tool_turn["tool_call_id"] == "call_1"
        assert isinstance(tool_turn["content"], str)  # dict result stringified
        client.close()
    finally:
        server.stop()


def test_malformed_tool_call_arguments_fall_back_to_empty():
    """Providers emit truncated JSON in arguments; a bad string must not raise."""

    def script(message, payload):
        return [
            {
                "kind": "tool_calls",
                "data": [
                    {"id": "c1", "type": "function", "function": {"name": "x", "arguments": "{not json"}},
                ],
            },
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        resp = client.complete([{"role": "user", "content": "go"}])
        assert resp.tool_calls[0].name == "x"
        assert resp.tool_calls[0].arguments == {}
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


# -- cheap_clone: the hero/aux twin (§7.3) -----------------------------------


def test_cheap_clone_is_reasoning_off_small_and_shares_the_session():
    session = _session()
    client = BackendModelClient(
        session,
        model_id="deepseek/deepseek-v4-flash",
        provider_slug="fireworks",
        base_url="https://api.chuk.chat",
        max_tokens=2048,
        temperature=0.4,
        reasoning_effort="high",
    )
    clone = client.cheap_clone()

    # Reasoning off, at the weakest level the chat API accepts.
    assert clone._reasoning_effort == "none"
    # Small output cap by default.
    assert clone._max_tokens == 512
    # Same model + provider + backend endpoint.
    assert clone._model_id == client._model_id
    assert clone._provider_slug == client._provider_slug
    assert clone._ws_url == client._ws_url
    assert clone._temperature == client._temperature
    # The SAME session object — no second login, one shared token + refresh.
    assert clone._session is client._session
    # A distinct client (own socket), not the original.
    assert clone is not client


def test_cheap_clone_honours_a_custom_max_tokens():
    client = BackendModelClient(
        _session(),
        model_id="deepseek/deepseek-v4-flash",
        provider_slug="fireworks",
    )
    clone = client.cheap_clone(max_tokens=256)
    assert clone._max_tokens == 256
    assert clone._reasoning_effort == "none"


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


# -- who refreshes (bead cowork-c91) -----------------------------------------


def _attached_session(monkeypatch, *, timeout=2.0):
    """A session with a controller attached: the host must never touch GoTrue."""
    from cowork_agent import backend as backend_mod

    def forbidden(*args, **kwargs):
        raise AssertionError("GoTrue must not be called while the app is attached")

    monkeypatch.setattr(backend_mod, "_gotrue", forbidden)
    session = _session(token="expired", refresh_token="shared-rt")
    session.may_self_refresh = lambda: False
    session.reprovision_timeout = timeout
    return session


def test_attached_refresh_asks_the_app_and_waits_for_the_new_pair(monkeypatch):
    import threading

    session = _attached_session(monkeypatch)
    asked: list[str] = []

    def request(reason: str) -> None:
        asked.append(reason)

        def app_answers():
            # What the host does when the account_authentication frame lands.
            session.access_token = "fresh-from-app"
            session.refresh_token = "rt-from-app"
            session.mark_reprovisioned()

        threading.Timer(0.05, app_answers).start()

    session.request_reprovision = request
    before = session.generation

    session.refresh()

    assert asked == ["token_expired"]
    assert session.access_token == "fresh-from-app"
    assert session.generation == before + 1


def test_attached_refresh_gives_up_after_the_deadline(monkeypatch):
    from cowork_agent.backend import SupabaseAuthError

    session = _attached_session(monkeypatch, timeout=0.05)
    session.request_reprovision = lambda reason: None  # the app never answers
    with pytest.raises(SupabaseAuthError, match="did not re-provision"):
        session.refresh(reason="refresh_failed")


def test_detached_refresh_uses_gotrue_and_reports_the_rotated_pair():
    http, calls = _gotrue_transport(new_token="rotated")
    try:
        session = _session(token="old", refresh_token="r-old", http_client=http)
        session.may_self_refresh = lambda: True  # no controller attached
        reported: list = []
        session.on_self_refreshed = reported.append

        session.refresh()

        assert calls["refresh"] == 1
        assert session.access_token == "rotated"
        assert reported == [session]  # the host relays this pair to the app
        assert session.generation == 1
    finally:
        http.close()


def test_refresh_is_single_flight():
    """The loop's client and the hero clone share one session; when both hit an
    expired token at once, GoTrue is spent ONCE and the late-comer sees the
    fresh pair instead of burning a second (now invalid) refresh."""
    import threading

    http, calls = _gotrue_transport(new_token="rotated")
    try:
        session = _session(token="old", refresh_token="r-old", http_client=http)
        session.may_self_refresh = lambda: True
        gate = threading.Barrier(2)

        def go():
            gate.wait()
            # Both callers saw the SAME token fail; whoever comes second finds it
            # already replaced and must not spend another refresh.
            session.refresh(seen_token="old")

        threads = [threading.Thread(target=go) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(5)
        assert calls["refresh"] == 1
        assert session.access_token == "rotated"
    finally:
        http.close()


def test_complete_survives_an_expired_token_while_the_app_is_attached(monkeypatch):
    """The c91 symptom end to end at the client: the backend rejects the token,
    the client asks the app (not GoTrue), the app's re-provision lands, and the
    SAME request is retried and succeeds — the task loop never sees an error."""
    import threading

    from cowork_agent.backend import BackendModelClient, _AuthRejected
    from cowork_agent.model import ModelResponse

    session = _attached_session(monkeypatch)

    def request(reason: str) -> None:
        def app_answers():
            session.access_token = "fresh-from-app"
            session.mark_reprovisioned()

        threading.Timer(0.05, app_answers).start()

    session.request_reprovision = request
    client = BackendModelClient(session, model_id="m", provider_slug="p")

    attempts: list[str] = []

    def fake_chat_once(payload):
        attempts.append(session.access_token)
        if len(attempts) == 1:
            raise _AuthRejected("token expired")
        return ModelResponse(text="ok")

    monkeypatch.setattr(client, "_chat_once", fake_chat_once)

    response = client.complete([{"role": "user", "content": "hi"}])

    assert response.text == "ok"
    assert attempts == ["expired", "fresh-from-app"]


def test_on_reasoning_streams_each_thinking_chunk_as_it_arrives():
    """The thinking channel streams live, exactly like ``on_delta`` does for
    content: every ``reasoning`` frame reaches the sink as it comes off the wire,
    in order, and never leaks into ``on_delta`` or the answer text. The full
    reasoning is still accumulated in ``raw`` for persistence."""

    def script(message, payload):
        return [
            {"kind": "reasoning", "data": "let me "},
            {"kind": "reasoning", "data": "think"},
            {"kind": "content", "data": "answer"},
            {"kind": "done"},
        ]

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        seen: list[tuple[str, str]] = []
        client.on_delta = lambda text: seen.append(("delta", text))
        client.on_reasoning = lambda text: seen.append(("reasoning", text))
        resp = client.complete([{"role": "user", "content": "hi"}])
        assert seen == [
            ("reasoning", "let me "),
            ("reasoning", "think"),
            ("delta", "answer"),
        ]
        assert resp.text == "answer"
        assert resp.raw["reasoning"] == "let me think"
        client.close()
    finally:
        server.stop()


def test_a_failing_reasoning_sink_never_aborts_the_turn():
    def script(message, payload):
        return [
            {"kind": "reasoning", "data": "hmm"},
            {"kind": "content", "data": "answer"},
            {"kind": "done"},
        ]

    def boom(_text: str) -> None:
        raise RuntimeError("ui went away")

    server = MockWsServer(script, valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        client.on_reasoning = boom
        resp = client.complete([{"role": "user", "content": "hi"}])
        assert resp.text == "answer"
        assert resp.raw["reasoning"] == "hmm"
        client.close()
    finally:
        server.stop()


def test_cheap_clone_does_not_inherit_the_reasoning_sink():
    """Housekeeping turns (compaction, fact extraction) run with reasoning off
    and must never narrate into the thread's thinking block."""
    server = MockWsServer(lambda m, p: [{"kind": "done"}], valid_tokens={"valid-token"})
    try:
        client = _client(server, _session())
        client.on_reasoning = lambda text: None
        client.on_delta = lambda text: None
        clone = client.cheap_clone()
        assert clone.on_reasoning is None
        assert clone.on_delta is None
        client.close()
    finally:
        server.stop()


# -- reasoning effort clamp (the catalogue decides what a model accepts) ------

_CATALOGUE = [
    {
        "id": "z-ai/glm-5.3-flash",
        "supported_efforts": ["low", "high", "max"],
        "reasoning_default_effort": "max",
        "reasoning_mandatory": True,
        "providers": [{"slug": "fireworks/serverless"}],
    },
    {
        "id": "deepseek/deepseek-v4-pro-0813",
        "supported_efforts": ["none", "low", "high", "max"],
        "reasoning_default_effort": "high",
        "providers": [{"slug": "fireworks/serverless"}],
    },
    {
        "id": "z-ai/glm-5.1",
        "supported_efforts": ["none", "on"],
        "providers": [{"slug": "fireworks"}],
    },
    {
        "id": "vendor/no-list",
        "providers": [{"slug": "x"}],
    },
]


def test_clamp_keeps_a_supported_level_and_passes_unknown_models_through():
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", "high") == "high"
    assert clamp_reasoning_effort(_CATALOGUE, "vendor/no-list", "medium") == "medium"
    assert clamp_reasoning_effort(_CATALOGUE, "nobody/knows", "medium") == "medium"
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", None) is None


def test_clamp_moves_an_unsupported_graded_level_to_the_next_stronger_one():
    """The live finding: ``medium`` on a low/high/max model gets NO reasoning
    from the backend. The user asked to think, so the clamp goes up, not off."""
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", "medium") == "high"
    assert clamp_reasoning_effort(_CATALOGUE, "deepseek/deepseek-v4-pro-0813", "medium") == "high"
    # Nothing stronger allowed -> the strongest weaker level (never off).
    assert clamp_reasoning_effort(
        [{"id": "m", "supported_efforts": ["none", "low"]}], "m", "medium"
    ) == "low"
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", "xhigh") == "max"


def test_clamp_never_sends_off_to_a_reasoning_mandatory_model():
    # glm-5.3-flash has no ``none``: the server rejects "off" there.
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", "none") == "low"
    # A model that allows off keeps off.
    assert clamp_reasoning_effort(_CATALOGUE, "deepseek/deepseek-v4-pro-0813", "none") == "none"


def test_clamp_handles_the_binary_on_token():
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.1", "on") == "on"
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.1", "medium") == "on"
    # On a graded model ``on`` means the model's advertised default.
    assert clamp_reasoning_effort(_CATALOGUE, "z-ai/glm-5.3-flash", "on") == "max"


def test_client_exposes_the_effort_it_sends():
    server = MockWsServer(lambda m, p: [{"kind": "done"}], valid_tokens={"valid-token"})
    try:
        client = _client(server, _session(), reasoning_effort="high")
        assert client.reasoning_effort == "high"
        assert client.cheap_clone().reasoning_effort == "none"
        client.close()
    finally:
        server.stop()


def _jwt(exp: float) -> str:
    """A token shaped like a GoTrue JWT: only the payload is ever read."""
    import base64
    import json as _json

    def seg(obj):
        raw = _json.dumps(obj, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    return f"{seg({'alg': 'HS256'})}.{seg({'exp': int(exp), 'sub': 'u1'})}.sig"


def test_session_reads_its_deadline_from_the_token_when_none_was_passed():
    """A caller that omits ``expires_at`` must not get a session that believes it
    never expires: the host then redials the relay forever with a dead JWT
    (bead cowork-fm8w)."""
    import time as _time

    stale = _session(token=_jwt(_time.time() - 60))
    assert stale.expires_at is None or stale.expires_at > 0
    assert stale.is_expired() is True

    fresh = _session(token=_jwt(_time.time() + 3600))
    assert fresh.is_expired() is False


def test_session_without_a_readable_token_still_assumes_valid():
    """An opaque token carries no deadline, and guessing one would refresh in a
    loop. The ``auth_error`` frame stays the backstop there."""
    assert _session(token="not-a-jwt").is_expired() is False
