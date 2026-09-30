"""The loopback memory gateway (§12, Hindsight backend): auth, both routes as
plain forwards with the live token and one refresh, the pinned embedder, the
pinned memory model, and the per-minute limit. No network: an ``httpx`` mock
transport stands in for ``api.chuk.chat``."""

from __future__ import annotations

import json
import threading

import httpx
import pytest

from chuk_agents_runtime.memory_gateway import (
    CHAT_BUDGET_SECONDS,
    SIDECAR_LLM_TIMEOUT,
    GatewayError,
    MemoryGateway,
    RateLimiter,
)


class Session:
    def __init__(self, token: str = "tok-1") -> None:
        self.access_token = token
        self.refreshes: list[str | None] = []

    def refresh(self, *, seen_token: str | None = None) -> None:
        self.refreshes.append(seen_token)
        self.access_token = f"tok-{len(self.refreshes) + 1}"


def _vectors(n: int, dims: int = 1024) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "object": "list",
            "data": [{"object": "embedding", "index": i, "embedding": [0.1] * dims} for i in range(n)],
            "model": "qwen3-embedding-8b",
        },
    )


COMPLETION = {
    "id": "chatcmpl-1",
    "object": "chat.completion",
    "choices": [{"index": 0, "message": {"role": "assistant", "content": '{"facts": []}'}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15},
}


class Upstream:
    """Records every call; answers from a queue, else a sensible default."""

    def __init__(self, *responses: httpx.Response) -> None:
        self.calls: list[httpx.Request] = []
        self._responses = list(responses)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        if self._responses:
            return self._responses.pop(0)
        if request.url.path.endswith("/chat/completions"):
            return httpx.Response(200, json=COMPLETION)
        body = json.loads(request.content)
        return _vectors(1 if isinstance(body["input"], str) else len(body["input"]))


@pytest.fixture
def make_gateway():
    made: list[MemoryGateway] = []

    def make(*, session=None, upstream=None, limiter=None, rate_wait=0.0, **kwargs):
        gw = MemoryGateway(
            lambda: session,
            http_client=httpx.Client(transport=httpx.MockTransport(upstream or Upstream())),
            limiter=limiter,
            rate_wait_seconds=rate_wait,
            **kwargs,
        ).start()
        made.append(gw)
        return gw

    yield make
    for gw in made:
        gw.stop()


def _post(gw: MemoryGateway, path: str, body: dict, *, key: str | None = None) -> httpx.Response:
    return httpx.post(
        f"{gw.base_url}{path}",
        json=body,
        headers={"Authorization": f"Bearer {key if key is not None else gw.secret}"},
        timeout=10,
    )


MSGS = [{"role": "user", "content": "hi"}]


def test_it_binds_loopback_and_refuses_a_wrong_key(make_gateway):
    gw = make_gateway(session=Session())
    assert gw.base_url.startswith("http://127.0.0.1:") and gw.base_url.endswith("/v1")
    assert httpx.get(f"http://127.0.0.1:{gw.port}/health").status_code == 200
    assert _post(gw, "/embeddings", {"input": "x"}, key="wrong").status_code == 401
    assert httpx.post(f"{gw.base_url}/chat/completions", json={"messages": MSGS}).status_code == 401


def test_embeddings_are_pinned_and_carry_the_live_token(make_gateway):
    upstream = Upstream()
    gw = make_gateway(session=Session("live-token"), upstream=upstream)
    response = _post(gw, "/embeddings", {"input": ["a", "b"], "model": "qwen3-embedding-8b"})
    assert response.status_code == 200
    assert len(response.json()["data"]) == 2
    (call,) = upstream.calls
    assert str(call.url) == "https://api.chuk.chat/v1/embeddings"
    assert call.headers["Authorization"] == "Bearer live-token"
    assert json.loads(call.content) == {"model": "qwen3-embedding-8b", "input": ["a", "b"], "dimensions": 1024}


def test_a_foreign_model_or_dimension_is_refused(make_gateway):
    upstream = Upstream()
    gw = make_gateway(session=Session(), upstream=upstream)
    assert _post(gw, "/embeddings", {"input": "x", "model": "text-embedding-3-small"}).status_code == 400
    assert _post(gw, "/embeddings", {"input": "x", "dimensions": 1536}).status_code == 400
    assert _post(gw, "/embeddings", {"input": ""}).status_code == 400
    assert upstream.calls == []


def test_a_401_refreshes_once_and_retries_once(make_gateway):
    upstream = Upstream(httpx.Response(401, json={"detail": "expired"}))
    session = Session("old")
    gw = make_gateway(session=session, upstream=upstream)
    assert _post(gw, "/embeddings", {"input": "x"}).status_code == 200
    assert session.refreshes == ["old"]
    assert [c.headers["Authorization"] for c in upstream.calls] == ["Bearer old", "Bearer tok-2"]
    assert gw.stats["refresh"] == 1


def test_a_second_401_is_passed_back_not_looped(make_gateway):
    upstream = Upstream(httpx.Response(401, json={}), httpx.Response(401, json={"error": {"code": "invalid_api_key"}}))
    session = Session()
    gw = make_gateway(session=session, upstream=upstream)
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 401
    assert len(upstream.calls) == 2 and len(session.refreshes) == 1


def test_a_wrong_vector_size_from_upstream_is_a_502(make_gateway):
    gw = make_gateway(session=Session(), upstream=Upstream(_vectors(1, dims=768)))
    response = _post(gw, "/embeddings", {"input": "x"})
    assert response.status_code == 502
    assert "768" in response.json()["error"]["message"]


def test_no_session_is_a_503(make_gateway):
    gw = make_gateway(session=None)
    assert _post(gw, "/embeddings", {"input": "x"}).status_code == 503
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 503


def test_chat_is_a_forward_with_the_model_pinned_reasoning_off_and_a_cap(make_gateway):
    upstream = Upstream()
    gw = make_gateway(session=Session("live"), upstream=upstream)
    tools = [{"type": "function", "function": {"name": "search", "parameters": {"type": "object"}}}]
    response = _post(
        gw,
        "/chat/completions",
        {
            "model": "gpt-5-mini",
            "messages": [{"role": "developer", "content": "rules"}, *MSGS],
            "temperature": 0.1,
            "max_completion_tokens": 64000,
            "response_format": {"type": "json_object"},
            "tools": tools,
            "user": "bank-1",
        },
    )
    assert response.status_code == 200
    assert response.json() == COMPLETION  # verbatim
    (call,) = upstream.calls
    assert str(call.url) == "https://api.chuk.chat/v1/chat/completions"
    assert call.headers["Authorization"] == "Bearer live"
    sent = json.loads(call.content)
    assert sent["model"] == "deepseek/deepseek-v4-flash"
    assert sent["reasoning_effort"] == "none"
    assert sent["max_tokens"] == 8192 and "max_completion_tokens" not in sent
    assert sent["response_format"] == {"type": "json_object"}
    assert sent["tools"] == tools and sent["temperature"] == 0.1
    assert sent["messages"][0] == {"role": "developer", "content": "rules"}
    assert "user" not in sent and "stream" not in sent


def test_chat_keeps_a_smaller_cap_and_refuses_streaming(make_gateway):
    gw = make_gateway(session=Session())
    assert gw.chat_payload({"messages": MSGS, "max_tokens": 500})["max_tokens"] == 500
    with pytest.raises(GatewayError):
        gw.chat_payload({"messages": MSGS, "stream": True})
    with pytest.raises(GatewayError):
        gw.chat_payload({"messages": []})
    assert _post(gw, "/chat/completions", {"messages": MSGS, "stream": True}).status_code == 400


def test_upstream_errors_pass_through_with_their_status(make_gateway):
    upstream = Upstream(
        httpx.Response(429, json={"error": {"code": "rate_limit_exceeded"}}),
        httpx.Response(402, json={"error": {"code": "insufficient_quota"}}),
    )
    gw = make_gateway(session=Session(), upstream=upstream)
    first = _post(gw, "/chat/completions", {"messages": MSGS})
    assert first.status_code == 429 and first.headers["Retry-After"] == "30"
    assert _post(gw, "/chat/completions", {"messages": MSGS}).json()["error"]["code"] == "insufficient_quota"
    assert gw.stats["upstream_error"] == 2


def test_an_unreachable_upstream_is_a_502(make_gateway):
    def boom(request):
        raise httpx.ConnectError("down")

    gw = make_gateway(session=Session(), upstream=boom)
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 502


def test_the_limit_counts_both_routes_and_answers_429(make_gateway):
    gw = make_gateway(session=Session(), limiter=RateLimiter(2), rate_wait=0.0)
    assert _post(gw, "/embeddings", {"input": "x"}).status_code == 200
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 200
    third = _post(gw, "/embeddings", {"input": "x"})
    assert third.status_code == 429
    assert third.headers["Retry-After"] == "30"
    assert gw.stats["rate_limited"] == 1


def test_rate_limiter_is_a_sliding_window():
    now = [0.0]

    def sleep(s: float) -> None:
        now[0] += s

    limiter = RateLimiter(20, clock=lambda: now[0], sleep=sleep)
    assert all(limiter.acquire(0) for _ in range(20))
    assert limiter.acquire(0) is False  # the 21st inside the minute
    now[0] = 30.0
    assert limiter.acquire(0) is False  # still inside the window of the first
    assert limiter.acquire(40.0) is True  # waits until the first slot frees
    assert now[0] == pytest.approx(60.0)


def test_rate_limiter_reserve_keeps_slots_for_others():
    now = [0.0]
    limiter = RateLimiter(5, clock=lambda: now[0], sleep=lambda s: None)
    assert [limiter.acquire(0, reserve=2) for _ in range(4)] == [True, True, True, False]
    assert limiter.acquire(0) and limiter.acquire(0)  # the reserved two
    assert limiter.acquire(0) is False  # the window is full for everyone
    now[0] = 60.0
    assert limiter.acquire(0, reserve=2)


def test_only_a_ticketed_recall_gets_the_reserved_slots(make_gateway):
    upstream = Upstream()
    gw = make_gateway(
        session=Session(), upstream=upstream, limiter=RateLimiter(6), rate_wait=0.0, query_prefix="Q: "
    )
    # Background (extraction, documents, consolidation's own searches) gets 6 - 4 = 2.
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 200
    assert _post(gw, "/embeddings", {"input": ["Q: a consolidation search"]}).status_code == 200
    assert _post(gw, "/embeddings", {"input": ["Q: another one"]}).status_code == 429
    # A foreground recall with a live ticket still gets through, ticket stripped.
    ticket = gw.issue_ticket()
    assert _post(gw, "/embeddings", {"input": [f"Q: {ticket}what is the port"]}).status_code == 200
    assert json.loads(upstream.calls[-1].content)["input"] == ["Q: what is the port"]
    # The ticket was burnt: replaying it is background traffic (and is refused here).
    assert _post(gw, "/embeddings", {"input": [f"Q: {ticket}again"]}).status_code == 429
    assert gw.stats["recalls"] == 1


def test_a_forged_ticket_is_stripped_but_gets_no_priority(make_gateway):
    upstream = Upstream()
    gw = make_gateway(session=Session(), upstream=upstream, query_prefix="Q: ")
    assert _post(gw, "/embeddings", {"input": "Q: \u27e6deadbeef\u27e7 question"}).status_code == 200
    assert json.loads(upstream.calls[-1].content)["input"] == "Q: question"
    assert gw.stats["recalls"] == 0 and gw.stats["background_embeddings"] == 1


def test_the_token_only_goes_to_the_account_host():
    for bad in (
        "https://evil.example/v1",
        "http://api.chuk.chat/v1",
        "https://api.chuk.chat.evil.example/v1",
        "https://user@api.chuk.chat/v1",
    ):
        with pytest.raises(ValueError):
            MemoryGateway(lambda: Session(), api_base_url=bad)
    MemoryGateway(lambda: Session(), api_base_url="https://api.chuk.chat/v1").stop()
    MemoryGateway(lambda: Session(), api_base_url="https://staging.example/v1", allowed_host="staging.example").stop()


def test_a_chat_call_fits_inside_the_sidecar_timeout(make_gateway):
    upstream = Upstream()
    gw = make_gateway(session=Session(), upstream=upstream)
    assert _post(gw, "/chat/completions", {"messages": MSGS}).status_code == 200
    read_timeout = upstream.calls[-1].extensions["timeout"]["read"]
    assert read_timeout <= CHAT_BUDGET_SECONDS < SIDECAR_LLM_TIMEOUT
    # The slot wait is part of the budget, not added on top of it.
    from chuk_agents_runtime.memory_gateway import DEFAULT_RATE_WAIT_SECONDS

    assert DEFAULT_RATE_WAIT_SECONDS < CHAT_BUDGET_SECONDS


def test_a_client_that_hung_up_is_counted_not_crashed(make_gateway):
    import socket

    gw = make_gateway(session=Session())
    body = json.dumps({"input": "x"}).encode()
    request = (
        f"POST /v1/embeddings HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {gw.secret}\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n"
    ).encode() + body
    with socket.create_connection(("127.0.0.1", gw.port)) as sock:
        sock.sendall(request)
    # The server is still healthy afterwards.
    assert _post(gw, "/embeddings", {"input": "y"}).status_code == 200


def test_concurrent_requests_are_served(make_gateway):
    gw = make_gateway(session=Session(), rate_wait=5.0)
    results: list[int] = []

    def hit():
        results.append(_post(gw, "/embeddings", {"input": "x"}).status_code)

    threads = [threading.Thread(target=hit) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    assert results == [200] * 6
