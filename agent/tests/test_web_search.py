"""``web_search`` goes through our backend, never to a provider directly.

Every test drives an :class:`httpx.MockTransport`, so nothing here touches the
network. What is pinned: the route and the Bearer header, the token-saving
request shape, the reduced result, the refresh-once-on-401 path, and that every
backend failure comes back as a bounded envelope instead of an exception.
"""

from __future__ import annotations

import json

import httpx
import pytest

from cowork_agent import (
    LocalEnvironment,
    ToolRegistry,
    make_web_search_handler,
    register_builtin_tools,
    register_web_search,
    render_tool_docs,
)
from cowork_agent.web_search import DESCRIPTION_CAP, MAX_RESULTS, SEARCH_PATH

BASE = "https://api.example.test"


class FakeSession:
    """A :class:`~cowork_agent.web_search.TokenSession` stand-in that counts
    refreshes and hands out a new token each time."""

    def __init__(self, token: str = "tok-1") -> None:
        self.access_token = token
        self.refreshes = 0

    def refresh(self) -> None:
        self.refreshes += 1
        self.access_token = f"tok-{self.refreshes + 1}"


def _client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def _ok_body(results: list[dict]) -> dict:
    return {"query": "q", "results": results}


def _handler(recorder: list, *, status: int = 200, body=None, statuses=None):
    """A transport handler that records every request. ``statuses`` gives a
    per-call status sequence (for the refresh path)."""
    sequence = list(statuses or [])

    def handle(request: httpx.Request) -> httpx.Response:
        recorder.append(request)
        code = sequence.pop(0) if sequence else status
        payload = body if body is not None else _ok_body([])
        if code != 200 and body is None:
            payload = {"error": "nope"}
        return httpx.Response(code, json=payload)

    return handle


# -- happy path ---------------------------------------------------------------


def test_search_hits_the_backend_route_with_the_account_token():
    seen: list[httpx.Request] = []
    handler = make_web_search_handler(
        FakeSession(),
        base_url=BASE,
        http_client=_client(
            _handler(
                seen,
                body=_ok_body(
                    [
                        {
                            "title": "Python",
                            "url": "https://python.org",
                            "description": "The language",
                            "age": "2 days ago",
                        }
                    ]
                ),
            )
        ),
    )
    result = handler("python asyncio")

    assert result["ok"] is True
    assert result["results"] == [
        {
            "title": "Python",
            "url": "https://python.org",
            "description": "The language",
            "age": "2 days ago",
        }
    ]
    request = seen[0]
    assert str(request.url) == f"{BASE}{SEARCH_PATH}"
    assert request.method == "POST"
    assert request.headers["Authorization"] == "Bearer tok-1"


def test_request_keeps_the_result_cheap_and_clamps_the_count():
    seen: list[httpx.Request] = []
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler(seen))
    )
    handler("q", count=99, freshness="pw")

    payload = json.loads(seen[0].content)
    # extra_snippets defaults to true on the backend and multiplies the tokens.
    assert payload["extra_snippets"] is False
    assert payload["count"] == MAX_RESULTS
    assert payload["freshness"] == "pw"


def test_stringy_count_from_the_model_is_tolerated():
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler([]))
    )
    assert handler("q", count="not a number")["ok"] is True


def test_long_descriptions_are_capped():
    body = _ok_body(
        [{"title": "T", "url": "https://a.test", "description": "x" * 5000}]
    )
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler([], body=body))
    )
    description = handler("q")["results"][0]["description"]
    assert len(description) <= DESCRIPTION_CAP + 1  # + the ellipsis


def test_results_without_a_url_are_dropped():
    body = _ok_body(
        [
            {"title": "no url", "description": "d"},
            {"title": "ok", "url": "https://a.test", "description": "d"},
            "not a dict",
        ]
    )
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler([], body=body))
    )
    assert [r["url"] for r in handler("q")["results"]] == ["https://a.test"]


# -- failure paths ------------------------------------------------------------


@pytest.mark.parametrize("query", ["", "   ", None])
def test_empty_query_never_reaches_the_backend(query):
    seen: list[httpx.Request] = []
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler(seen))
    )
    result = handler(query)
    assert result["ok"] is False
    assert seen == []


@pytest.mark.parametrize("status", [400, 429, 500, 502, 503])
def test_backend_errors_come_back_as_an_envelope(status):
    handler = make_web_search_handler(
        FakeSession(),
        base_url=BASE,
        http_client=_client(_handler([], status=status)),
    )
    result = handler("q")
    assert result == {
        "ok": False,
        "query": "q",
        "status": status,
        "error": "nope",
    }


def test_expired_token_is_refreshed_once_and_the_call_retried():
    session = FakeSession()
    seen: list[httpx.Request] = []
    handler = make_web_search_handler(
        session,
        base_url=BASE,
        http_client=_client(_handler(seen, statuses=[401, 200])),
    )
    result = handler("q")

    assert result["ok"] is True
    assert session.refreshes == 1
    assert [r.headers["Authorization"] for r in seen] == ["Bearer tok-1", "Bearer tok-2"]


def test_a_second_401_is_reported_and_not_retried_forever():
    session = FakeSession()
    seen: list[httpx.Request] = []
    handler = make_web_search_handler(
        session,
        base_url=BASE,
        http_client=_client(_handler(seen, statuses=[401, 401])),
    )
    result = handler("q")
    assert result["ok"] is False
    assert result["status"] == 401
    assert len(seen) == 2


def test_a_timeout_is_an_error_not_an_exception():
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("too slow", request=request)

    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(handle)
    )
    assert handler("q") == {"ok": False, "query": "q", "error": "web search timed out"}


def test_a_transport_failure_is_an_error_not_an_exception():
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route", request=request)

    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(handle)
    )
    result = handler("q")
    assert result["ok"] is False
    assert "ConnectError" in result["error"]


def test_a_non_json_body_is_reported():
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="<html>gateway</html>")

    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(handle)
    )
    assert handler("q") == {"ok": False, "query": "q", "error": "backend sent no JSON"}


# -- registration -------------------------------------------------------------


def test_without_a_session_the_tool_is_not_registered_and_not_documented():
    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    assert registry.has("web_search") is False
    assert "## web_search" not in render_tool_docs(registry)


def test_with_a_session_the_tool_is_registered_and_documented():
    registry = ToolRegistry()
    register_builtin_tools(
        registry, LocalEnvironment(), session=FakeSession(), base_url=BASE
    )
    assert registry.available("web_search") is True
    docs = render_tool_docs(registry)
    assert "## web_search" in docs
    assert "`query` (string, required)" in docs


def test_a_session_that_lost_its_token_makes_the_tool_unavailable():
    session = FakeSession(token="")
    registry = ToolRegistry()
    register_web_search(registry, session, base_url=BASE)
    assert registry.available("web_search") is False
    assert "## web_search" not in render_tool_docs(registry)
    session.access_token = "tok"
    assert registry.available("web_search") is True


def test_dispatch_coerces_the_model_string_count_from_the_schema():
    seen: list[httpx.Request] = []
    registry = ToolRegistry()
    register_web_search(
        registry, FakeSession(), base_url=BASE, http_client=_client(_handler(seen))
    )
    result = registry.dispatch("web_search", {"query": "q", "count": "3"})

    assert result["ok"] is True
    assert json.loads(seen[0].content)["count"] == 3


def test_a_non_string_query_is_rejected_not_raised():
    handler = make_web_search_handler(
        FakeSession(), base_url=BASE, http_client=_client(_handler([]))
    )
    assert handler({"not": "a query"})["ok"] is True  # coerced, still one call
    assert handler([])["ok"] is False  # empty -> never leaves the sandbox
