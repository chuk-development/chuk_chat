"""``web_search`` — web search through our own backend (§8, §9).

The provider key never reaches the sandbox. The agent calls ``api.chuk.chat``
with the account access token; the backend holds the Brave key, rate-limits the
account and returns a reduced result list.

Backend route (verified against ``api_server/routers/brave.py``)::

    POST {base_url}/v1/tools/brave/search
    Authorization: Bearer <supabase access token>
    Content-Type: application/json

Request body (``BraveSearchRequest``); every field except ``query`` is optional::

    {
      "query": "site:python.org asyncio",   # required, non-empty
      "count": 5,                           # server clamps to 1..20
      "freshness": "pd",                    # pd | pw | pm | py | YYYY-MM-DDtoYYYY-MM-DD
      "country": "DE",                      # ISO 3166-1 alpha-2
      "search_lang": "de",                  # ISO 639-1
      "extra_snippets": false               # we switch this OFF, see below
    }

Success response (HTTP 200)::

    {
      "query": "...",
      "results": [
        {"title": "...", "url": "https://...", "description": "...",
         "age": "3 days ago",              # optional
         "extra_snippets": ["...", "..."]} # optional, only with extra_snippets
      ]
    }

Failure responses carry ``{"error": "<text>"}`` with the status code:
400 (empty query), 401/403 (token), 429 (rate limit or too many concurrent
calls), 502 (provider error), 503 (no provider key), 500 (proxy failure).

Token efficiency (§7.9): the backend defaults ``extra_snippets`` to *true*,
which adds up to five extra excerpts per result. We send ``false`` and bound
every description, so one search costs a predictable, small number of tokens.
When the agent needs the full text of a hit it calls ``web_fetch`` on the URL.
"""

from __future__ import annotations

from typing import Any, Protocol

import httpx

from .registry import ToolRegistry

# The single default backend. Kept as its own constant so this module does not
# import ``backend`` (and with it the websocket client) just for one string.
DEFAULT_BASE_URL = "https://api.chuk.chat"

SEARCH_PATH = "/v1/tools/brave/search"

# Result bounds. A search result travels straight into the prompt.
MAX_RESULTS = 10
DEFAULT_RESULTS = 5
DESCRIPTION_CAP = 400
TITLE_CAP = 200
URL_CAP = 500
REQUEST_TIMEOUT = 30.0

WEB_SEARCH_SCHEMA = {
    "type": "object",
    "description": (
        "Search the web and get ranked results with title, URL and a short "
        "description. Use it for facts that can change, for anything after your "
        "training data, and to find the page you then read with `web_fetch`. "
        "The descriptions are short on purpose: pick a URL and fetch it."
    ),
    "properties": {
        "query": {
            "type": "string",
            "description": "Search query. Search operators such as site: work.",
        },
        "count": {
            "type": "integer",
            "description": "How many results to return, 1 to 10.",
            "default": DEFAULT_RESULTS,
        },
        "freshness": {
            "type": "string",
            "description": (
                "Limit the age of the results: 'pd' past day, 'pw' past week, "
                "'pm' past month, 'py' past year."
            ),
        },
    },
    "required": ["query"],
}


class TokenSession(Protocol):
    """What ``web_search`` needs from a session: a token, and a way to renew it.

    :class:`cowork_agent.backend.SupabaseSession` satisfies this.
    """

    access_token: str

    def refresh(self) -> None: ...


def _clip(value: Any, cap: int) -> str:
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    text = text.strip()
    return text if len(text) <= cap else text[:cap].rstrip() + "…"


def _error_text(response: httpx.Response) -> str:
    """Pull the backend's ``{"error": ...}`` out of a failure response."""
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        detail = body.get("error") or body.get("detail")
        if detail:
            return _clip(detail, 300)
    return _clip(response.text, 300) or f"HTTP {response.status_code}"


def _reduce(body: Any, count: int) -> list[dict[str, str]]:
    raw = body.get("results") if isinstance(body, dict) else None
    if not isinstance(raw, list):
        return []
    results: list[dict[str, str]] = []
    for item in raw[:count]:
        if not isinstance(item, dict):
            continue
        url = _clip(item.get("url"), URL_CAP)
        if not url:
            continue
        entry = {
            "title": _clip(item.get("title"), TITLE_CAP),
            "url": url,
            "description": _clip(item.get("description"), DESCRIPTION_CAP),
        }
        age = item.get("age")
        if age:
            entry["age"] = _clip(age, 40)
        results.append(entry)
    return results


def make_web_search_handler(
    session: TokenSession,
    *,
    base_url: str = DEFAULT_BASE_URL,
    http_client: httpx.Client | None = None,
    timeout: float = REQUEST_TIMEOUT,
):
    """Build the ``web_search`` handler.

    ``session`` supplies the account access token. A 401/403 is retried once
    after :meth:`TokenSession.refresh`, so an expired token costs one extra
    round trip instead of a failed task.
    """
    url = f"{base_url.rstrip('/')}{SEARCH_PATH}"

    def _post(payload: dict[str, Any]) -> httpx.Response:
        client = http_client or httpx.Client(timeout=timeout)
        try:
            return client.post(
                url,
                json=payload,
                headers={"Authorization": f"Bearer {session.access_token}"},
            )
        finally:
            if http_client is None:
                client.close()

    def web_search(
        query: str,
        count: int = DEFAULT_RESULTS,
        freshness: str | None = None,
    ) -> dict:
        # The model can send anything; a wrong type must not raise here.
        text = (query if isinstance(query, str) else str(query or "")).strip()
        if not text:
            return {"ok": False, "error": "query is empty"}
        try:
            wanted = max(1, min(int(count), MAX_RESULTS))
        except (TypeError, ValueError):
            wanted = DEFAULT_RESULTS

        payload: dict[str, Any] = {
            "query": text,
            "count": wanted,
            # Off by design: extra snippets multiply the token cost of a search.
            "extra_snippets": False,
        }
        if freshness:
            payload["freshness"] = str(freshness).strip()

        try:
            response = _post(payload)
            if response.status_code in (401, 403):
                session.refresh()
                response = _post(payload)
        except httpx.TimeoutException:
            return {"ok": False, "query": text, "error": "web search timed out"}
        except Exception as exc:
            return {
                "ok": False,
                "query": text,
                "error": f"web search failed: {type(exc).__name__}",
            }

        if response.status_code != 200:
            return {
                "ok": False,
                "query": text,
                "status": response.status_code,
                "error": _error_text(response),
            }

        try:
            body = response.json()
        except ValueError:
            return {"ok": False, "query": text, "error": "backend sent no JSON"}

        return {"ok": True, "query": text, "results": _reduce(body, wanted)}

    return web_search


def register_web_search(
    registry: ToolRegistry,
    session: TokenSession | None,
    *,
    base_url: str = DEFAULT_BASE_URL,
    http_client: httpx.Client | None = None,
) -> None:
    """Register ``web_search``.

    Without a session there is no token to pay with, so the tool is not
    registered at all. With one, a ``check_fn`` still gates it on the token
    being present, and :func:`cowork_agent.prompt.render_tool_docs` drops an
    unavailable tool from the prompt — the model must never be told about a
    tool that cannot run.
    """
    if session is None:
        return
    registry.register(
        "web_search",
        WEB_SEARCH_SCHEMA,
        make_web_search_handler(session, base_url=base_url, http_client=http_client),
        check_fn=lambda: bool(getattr(session, "access_token", "")),
    )
