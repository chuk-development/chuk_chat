"""BackendModelClient + SupabaseSession, against a mocked
``/v1/chat/completions`` route and a mocked GoTrue — no real credits, no
network.

The agent loop streams through Pydantic AI (``test_pai_gates.py``); the client
here is what a task runs on (``chat_spec``) and the blocking path for the
housekeeping calls. A token of ``"expired"`` is answered with ``401
invalid_api_key`` so the refresh-and-retry path is exercised.
"""

from __future__ import annotations

import asyncio
import json
import threading

import httpx
import httpx2
import pytest

from chuk_agents_runtime.backend import (
    clamp_reasoning_effort,
    BackendModelClient,
    BackendModelError,
    SupabaseSession,
    fetch_models_info,
    login,
    resolve_model,
)


# -- a mock /v1/chat/completions route ------------------------------------------


class MockRoute:
    """Answers each request from ``reply(body) -> dict | (status, dict)``;
    rejects any bearer outside ``valid_tokens`` with the route's 401."""

    def __init__(self, reply, *, valid_tokens=("valid-token",)):
        self.reply = reply
        self.valid_tokens = set(valid_tokens)
        self.bodies: list[dict] = []
        self.tokens: list[str] = []
        self.paths: list[str] = []

    def handler(self, request: httpx2.Request) -> httpx2.Response:
        token = request.headers.get("authorization", "").removeprefix("Bearer ")
        self.tokens.append(token)
        self.paths.append(request.url.path)
        if token not in self.valid_tokens:
            return httpx2.Response(401, json={"error": {"message": "invalid token", "type": "auth", "param": None, "code": "invalid_api_key"}})
        body = json.loads(request.content)
        self.bodies.append(body)
        answer = self.reply(body)
        if isinstance(answer, tuple):
            return httpx2.Response(answer[0], json=answer[1])
        return httpx2.Response(200, json=answer)

    def transport(self) -> httpx2.MockTransport:
        return httpx2.MockTransport(self.handler)


def completion(content=None, *, reasoning=None, tool_calls=None, usage=None, finish="stop"):
    message: dict = {"role": "assistant", "content": content}
    if reasoning is not None:
        message["reasoning_content"] = reasoning
    if tool_calls is not None:
        message["tool_calls"] = tool_calls
    return {
        "id": "c", "object": "chat.completion", "model": "m",
        "choices": [{"index": 0, "message": message, "finish_reason": finish}],
        "usage": usage or {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
    }


def _client(route: MockRoute, session, **kw) -> BackendModelClient:
    return BackendModelClient(
        session,
        model_id="deepseek/deepseek-v4-flash",
        provider_slug="fireworks/serverless",
        base_url="https://api.test",
        transport=route.transport(),
        **kw,
    )


# -- the blocking completion ------------------------------------------------------


def test_complete_returns_the_text_and_the_usage():
    route = MockRoute(lambda body: completion("  hello there  "))
    response = _client(route, _session()).complete([{"role": "user", "content": "hi"}])
    assert response.text == "hello there"
    assert response.tool_calls == []
    assert response.raw["usage"]["total_tokens"] == 10
    assert route.paths == ["/v1/chat/completions"]


def test_reasoning_is_separate_and_never_folded_into_the_text():
    route = MockRoute(lambda body: completion("answer", reasoning="let me think"))
    response = _client(route, _session()).complete([{"role": "user", "content": "q"}])
    assert response.text == "answer"
    assert response.raw["reasoning"] == "let me think"


def test_content_is_never_parsed_for_calls():
    text = '{"tool": "run_command", "args": {"command": "ls"}}'
    route = MockRoute(lambda body: completion(text))
    response = _client(route, _session()).complete([{"role": "user", "content": "q"}])
    assert response.tool_calls == []
    assert response.text == text


def test_an_error_body_surfaces_as_an_exception_with_its_code():
    route = MockRoute(lambda body: (402, {"error": {"message": "no credits", "type": "billing", "param": None, "code": "insufficient_quota"}}))
    with pytest.raises(BackendModelError) as caught:
        _client(route, _session()).complete([{"role": "user", "content": "q"}])
    assert caught.value.code == "insufficient_quota"
    assert "no credits" in caught.value.detail


def test_payload_is_the_openai_request_with_the_provider_pin():
    route = MockRoute(lambda body: completion("ok"))
    client = _client(route, _session(), reasoning_effort="low")
    client.complete(
        [
            {"role": "system", "content": "be brief"},
            {"role": "user", "content": "run it"},
            {
                "role": "assistant",
                "content": None,
                "reasoning": "stored thinking",
                "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "run_command", "arguments": {"command": "ls"}}}],
            },
            {"role": "tool", "tool_call_id": "c1", "name": "run_command", "content": {"exit_code": 0, "stdout": "a"}},
            {"role": "user", "content": "[memory recall] x"},
        ]
    )
    body = route.bodies[0]
    assert body["model"] == "deepseek/deepseek-v4-flash"
    assert body["provider"] == "fireworks/serverless"
    assert body["reasoning_effort"] == "low"
    assert not body.get("stream")
    # The WebSocket route ignored sampling fields; nothing is forced here.
    assert "max_tokens" not in body and "max_completion_tokens" not in body
    assert "temperature" not in body
    messages = body["messages"]
    assert messages[0] == {"role": "system", "content": "be brief"}
    assistant = messages[2]
    assert "reasoning" not in assistant and "reasoning_content" not in assistant
    assert assistant["tool_calls"][0]["function"]["arguments"] == '{"command":"ls"}'
    assert messages[3] == {"role": "tool", "tool_call_id": "c1", "content": '{"exit_code":0,"stdout":"a"}'}


def test_native_tools_are_sent_and_tool_calls_parsed():
    calls = [
        {"id": "call_a", "type": "function", "function": {"name": "write_file", "arguments": '{"path": "x", "content": "y"}'}},
        {"id": "call_b", "type": "function", "function": {"name": "run_command", "arguments": '{"command": "ls"}'}},
    ]
    route = MockRoute(lambda body: completion(None, tool_calls=calls, finish="tool_calls"))
    client = _client(route, _session())
    tools = [{"type": "function", "function": {"name": "write_file", "description": "", "parameters": {"type": "object"}}}]
    client.set_tools(tools)
    response = client.complete([{"role": "user", "content": "go"}])
    assert [t["function"]["name"] for t in route.bodies[0]["tools"]] == ["write_file"]
    assert route.bodies[0]["tools"][0]["function"]["parameters"]["type"] == "object"
    assert [(c.id, c.name, c.arguments) for c in response.tool_calls] == [
        ("call_a", "write_file", {"path": "x", "content": "y"}),
        ("call_b", "run_command", {"command": "ls"}),
    ]
    assert response.text is None


def test_malformed_tool_call_arguments_fall_back_to_empty():
    calls = [{"id": "c9", "type": "function", "function": {"name": "t", "arguments": "{not json"}}]
    route = MockRoute(lambda body: completion(None, tool_calls=calls))
    response = _client(route, _session()).complete([{"role": "user", "content": "go"}])
    assert response.tool_calls[0].arguments == {}
    assert response.tool_calls[0].name == "t"


def test_a_401_refreshes_the_token_then_retries_once():
    route = MockRoute(lambda body: completion("after refresh"), valid_tokens={"fresh-token"})
    http, calls = _gotrue_transport(new_token="fresh-token")
    try:
        session = _session(token="expired", http_client=http)
        response = _client(route, session).complete([{"role": "user", "content": "hi"}])
        assert response.text == "after refresh"
        assert calls["refresh"] == 1
        assert route.tokens == ["expired", "fresh-token"]
    finally:
        http.close()


def test_complete_survives_an_expired_token_while_the_app_is_attached(monkeypatch):
    """The c91 rule at the client: the route rejects the token, the client asks
    the app (not GoTrue), the app's re-provision lands, and the SAME request is
    sent again and succeeds."""
    session = _attached_session(monkeypatch)

    def request(reason: str) -> None:
        def app_answers():
            session.access_token = "fresh-from-app"
            session.mark_reprovisioned()

        threading.Timer(0.05, app_answers).start()

    session.request_reprovision = request
    route = MockRoute(lambda body: completion("ok"), valid_tokens={"fresh-from-app"})
    response = _client(route, session).complete([{"role": "user", "content": "hi"}])
    assert response.text == "ok"
    assert route.tokens == ["expired", "fresh-from-app"]


def test_the_sinks_get_the_whole_turn_once():
    route = MockRoute(lambda body: completion("answer", reasoning="thinking"))
    client = _client(route, _session())
    seen: list[tuple[str, str]] = []
    client.on_delta = lambda text: seen.append(("delta", text))
    client.on_reasoning = lambda text: seen.append(("reasoning", text))
    client.complete([{"role": "user", "content": "q"}])
    assert seen == [("reasoning", "thinking"), ("delta", "answer")]


def test_a_failing_sink_never_aborts_the_turn():
    route = MockRoute(lambda body: completion("answer", reasoning="thinking"))
    client = _client(route, _session())
    client.on_reasoning = lambda text: (_ for _ in ()).throw(RuntimeError("ui gone"))
    assert client.complete([{"role": "user", "content": "q"}]).text == "answer"


def test_cancel_mid_call_reports_cancelled():
    started = threading.Event()

    async def slow(request: httpx2.Request) -> httpx2.Response:
        started.set()
        await asyncio.sleep(30)
        return httpx2.Response(200, json=completion("too late"))

    client = BackendModelClient(
        _session(), model_id="m", provider_slug="p", base_url="https://api.test",
        transport=httpx2.MockTransport(slow),
    )
    errors: list[BaseException] = []

    def call() -> None:
        try:
            client.complete([{"role": "user", "content": "q"}])
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    worker = threading.Thread(target=call)
    worker.start()
    assert started.wait(5)
    client.cancel()
    worker.join(5)
    assert not worker.is_alive()
    assert isinstance(errors[0], BackendModelError) and errors[0].code == "cancelled"


def test_a_token_the_route_keeps_rejecting_is_an_auth_error():
    from chuk_agents_runtime.backend import SupabaseAuthError

    route = MockRoute(lambda body: completion("never"), valid_tokens=set())
    http, _ = _gotrue_transport(new_token="still-bad")
    try:
        with pytest.raises(SupabaseAuthError):
            _client(route, _session(token="expired", http_client=http)).complete(
                [{"role": "user", "content": "q"}]
            )
    finally:
        http.close()


# -- what a task runs on ------------------------------------------------------------


def test_chat_spec_describes_the_client_for_the_loop():
    session = _session()
    client = BackendModelClient(
        session, model_id="moonshotai/kimi-k2.6", provider_slug="fireworks", base_url="https://api.test/",
        reasoning_effort="high",
    )
    assert client.chat_spec() == {
        "session": session,
        "model_id": "moonshotai/kimi-k2.6",
        "provider_slug": "fireworks",
        "reasoning_effort": "high",
        "base_url": "https://api.test",
    }


@pytest.fixture(autouse=False)
def no_aux_env(monkeypatch):
    for name in ("AGENTS_MODEL_AUX", "AGENTS_MODEL_AUX_PROVIDER", "AGENTS_MODEL_AUX_REASONING_EFFORT"):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


def test_cheap_clone_is_reasoning_off_small_and_shares_the_session(no_aux_env):
    from chuk_agents_runtime.backend import DEFAULT_AUX_MODEL

    session = _session()
    client = BackendModelClient(
        session,
        model_id="z-ai/glm-5.3-flash",
        provider_slug="fireworks",
        base_url="https://api.chuk.chat",
        reasoning_effort="high",
    )
    clone = client.cheap_clone()
    assert clone.reasoning_effort == "none"
    assert clone._max_tokens == 512
    # Bead chuk_chat-sa7r: the default aux model is a fast one whose reasoning
    # really turns off, not the task's (glm-5.3-flash reasons always). The
    # task's provider pin belongs to the task's model and is not carried over.
    assert clone.chat_spec()["model_id"] == DEFAULT_AUX_MODEL
    assert clone.chat_spec()["provider_slug"] is None
    assert clone.chat_spec()["base_url"] == "https://api.chuk.chat"
    assert clone._session is client._session
    assert clone is not client
    # Housekeeping never narrates into the thread.
    client.on_delta = lambda text: None
    assert client.cheap_clone().on_delta is None


def test_cheap_clone_honours_a_custom_max_tokens_and_sends_it(no_aux_env):
    from chuk_agents_runtime.backend import DEFAULT_AUX_MODEL

    route = MockRoute(lambda body: completion("summary"))
    clone = _client(route, _session()).cheap_clone(max_tokens=256)
    clone.complete([{"role": "user", "content": "summarise"}])
    assert (route.bodies[0].get("max_tokens") or route.bodies[0].get("max_completion_tokens")) == 256
    assert route.bodies[0]["reasoning_effort"] == "none"
    assert route.bodies[0]["model"] == DEFAULT_AUX_MODEL
    # No provider pin and no owner identity: only model, messages, limits.
    assert "provider" not in route.bodies[0]
    assert "user" not in route.bodies[0]
    assert "tools" not in route.bodies[0]


def test_cheap_clone_follows_the_aux_settings(no_aux_env):
    client = BackendModelClient(
        _session(), model_id="z-ai/glm-5.3-flash", provider_slug="deepinfra/fp4",
        reasoning_effort="high",
    )
    no_aux_env.setenv("AGENTS_MODEL_AUX", "mistralai/mistral-small-2603")
    no_aux_env.setenv("AGENTS_MODEL_AUX_PROVIDER", "mistral/zdr")
    no_aux_env.setenv("AGENTS_MODEL_AUX_REASONING_EFFORT", "low")
    clone = client.cheap_clone()
    assert clone.chat_spec()["model_id"] == "mistralai/mistral-small-2603"
    assert clone.chat_spec()["provider_slug"] == "mistral/zdr"
    assert clone.reasoning_effort == "low"


def test_an_empty_aux_model_means_the_tasks_own_model(no_aux_env):
    client = BackendModelClient(
        _session(), model_id="moonshotai/kimi-k2.6", provider_slug="fireworks",
        reasoning_effort="high",
    )
    no_aux_env.setenv("AGENTS_MODEL_AUX", "")
    clone = client.cheap_clone()
    assert clone.chat_spec()["model_id"] == "moonshotai/kimi-k2.6"
    assert clone.chat_spec()["provider_slug"] == "fireworks"
    assert clone.reasoning_effort == "none"


def test_aux_model_settings_defaults():
    from chuk_agents_runtime.backend import (
        DEFAULT_AUX_MODEL,
        AuxModelSettings,
        aux_model_settings,
    )

    assert aux_model_settings({}) == AuxModelSettings(DEFAULT_AUX_MODEL, None, "none")
    assert aux_model_settings({"AGENTS_MODEL_AUX_REASONING_EFFORT": ""}).reasoning_effort is None


def test_client_exposes_the_effort_it_sends():
    client = BackendModelClient(_session(), model_id="m", provider_slug="p", reasoning_effort="high")
    assert client.reasoning_effort == "high"
    assert client.cheap_clone().reasoning_effort == "none"


# -- session, login, catalogue (unchanged) --------------------------------------------


def _session(token="valid-token", *, refresh_token="refresh-1", http_client=None):
    return SupabaseSession(
        access_token=token,
        refresh_token=refresh_token,
        supabase_url="https://proj.supabase.co",
        anon_key="anon-key",
        http_client=http_client,
    )


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


def _attached_session(monkeypatch, *, timeout=2.0):
    """A session with a controller attached: the host must never touch GoTrue."""
    from chuk_agents_runtime import backend as backend_mod

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
    from chuk_agents_runtime.backend import SupabaseAuthError

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


def _refusing_gotrue(status: int) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, json={"error": "invalid_grant"})

    return httpx.Client(transport=httpx.MockTransport(handler))


@pytest.mark.parametrize("status", [400, 503])
def test_a_refused_refresh_carries_gotrues_status_and_is_reported(status):
    from chuk_agents_runtime.backend import SupabaseAuthError

    seen: list[Exception] = []
    session = _session(token="expired", http_client=_refusing_gotrue(status))
    session.on_refresh_failed = seen.append
    with pytest.raises(SupabaseAuthError) as info:
        session.refresh(reason="token_expired")
    assert info.value.status == status
    assert seen == [info.value]
    # Nothing changed: the caller decides what a refusal means.
    assert session.access_token == "expired" and session.refresh_token == "refresh-1"


def test_a_failing_listener_does_not_mask_the_refusal():
    from chuk_agents_runtime.backend import SupabaseAuthError

    def boom(_exc):
        raise RuntimeError("listener bug")

    session = _session(token="expired", http_client=_refusing_gotrue(400))
    session.on_refresh_failed = boom
    with pytest.raises(SupabaseAuthError):
        session.refresh()


def test_a_stop_before_the_call_is_published_is_not_lost():
    """``cancel()`` before ``complete()`` starts: the call is cancelled before
    it sends anything (the cancel is sticky for this per-task client)."""
    route = MockRoute(lambda body: completion("never"))
    client = _client(route, _session())
    client.cancel()
    with pytest.raises(BackendModelError) as caught:
        client.complete([{"role": "user", "content": "q"}])
    assert caught.value.code == "cancelled"
    assert route.bodies == []
