"""``browser_task`` — the browser fallback for services with no usable API (§8, §9).

The capability hierarchy of §8 puts this tool **second**: a hand-built API tool
first, this only when a service has no usable API, and graphical computer-use /
VNC never. §7.9 says why in money terms — one rendered page serialised into a
prompt is thousands of tokens, and a browser task spends one model round *per
step*. So this module is written around two ideas: keep the browser out of the
prompt until it is really needed (``check_fn``), and make what a session cost
impossible to miss (:class:`BridgeUsage` in every result).

Verified facts about ``browser-use`` (read 2026-08-13, not from memory)
----------------------------------------------------------------------

Sources: ``https://pypi.org/pypi/browser-use/json`` and the tagged sources at
``https://raw.githubusercontent.com/browser-use/browser-use/main/...``.

* **Version 0.13.7, MIT, ``requires-python = ">=3.11,<4.0"``** (pyproject.toml).
  Our runtime is 3.12, so it fits.
* **Playwright is NOT a dependency any more.** ``pyproject.toml`` pins
  ``cdp-use==1.4.5``, ``browser-harness==0.1.8``, ``browser-use-sdk==3.4.2`` —
  the browser is driven straight over the Chrome DevTools Protocol. Playwright
  appears in exactly one place: ``browser_use/cli.py::_run_install_command``
  shells out to ``uvx playwright install chromium --with-deps --no-shell``, i.e.
  Playwright is used as the *downloader* for the Chromium build, not as the
  driver. The plan's "browser-use + Playwright + Chromium" (§9) is therefore one
  step stale: it is "browser-use + CDP + a Chromium binary".
* **Where it looks for that binary** (``browser/watchdogs/local_browser_watchdog.py::
  _find_installed_browser_path``): ``profile.executable_path`` first, then, on
  Linux, ``/usr/bin/google-chrome*``, ``$PLAYWRIGHT_BROWSERS_PATH`` (default
  ``~/.cache/ms-playwright``) ``/chromium-*/chrome-linux*/chrome``,
  ``/usr/bin/chromium``, ``/usr/bin/chromium-browser``, ``/snap/bin/chromium``,
  and the headless-shell build last. :func:`find_chromium` mirrors that list so
  our ``check_fn`` agrees with what the library will actually find. Size: the
  Chromium download plus ``--with-deps`` system libraries is several hundred MB
  — the reason the image is a separate variant (``sandbox/docker/Dockerfile.browser``).
* **The LLM seam is a Protocol, not a base class**
  (``browser_use/llm/base.py``): ``BaseChatModel`` is a ``@runtime_checkable``
  ``Protocol`` with an attribute ``model: str``, properties ``provider`` /
  ``name`` / ``model_name``, an optional ``_verified_api_keys: bool``, and
  ``async def ainvoke(messages: list[BaseMessage], output_format: type[T] | None)
  -> ChatInvokeCompletion[T] | ChatInvokeCompletion[str]``. **No LangChain.** So
  the adapter here is a plain duck-typed class — nothing to subclass, no
  provider SDK, no provider key.
* **Messages** (``browser_use/llm/messages.py``) are
  ``SystemMessage``/``UserMessage``/``AssistantMessage`` pydantic models with a
  ``.text`` property; user content may be a list of text and ``image_url`` parts.
* **The return type** (``browser_use/llm/views.py``): ``ChatInvokeCompletion``
  with fields ``completion``, ``thinking``, ``redacted_thinking``, ``usage``,
  ``stop_reason``, ``stop_details``. ``usage`` has **no default** — it must be
  passed, even as ``None``. ``ChatInvokeUsage`` needs ``prompt_tokens``,
  ``prompt_cached_tokens``, ``prompt_cache_creation_tokens``,
  ``prompt_image_tokens``, ``completion_tokens``, ``total_tokens``.
* **Structured output is how the agent decides its next action**: the Agent calls
  ``ainvoke(..., output_format=AgentOutput)`` and expects a validated pydantic
  instance back. Our backend returns free text, so the adapter appends the JSON
  schema to the prompt and validates the reply itself
  (:func:`extract_json_object`). That is the fragile joint of this module and it
  is counted, not hidden: every repair attempt increments
  ``BridgeUsage.structured_retries``.
* **Run + result** (``agent/service.py``, ``agent/views.py``):
  ``await Agent(...).run(max_steps=500)`` (that default is the money leak this
  module caps) returns an ``AgentHistoryList`` with ``final_result()``,
  ``is_done()``, ``is_successful()``, ``number_of_steps()``, ``urls()``,
  ``errors()``, ``screenshots()`` (base64 PNGs) and ``usage``.
* **Defaults that cost money and are turned off here**: ``use_vision=True``
  (image tokens — and our ``/v2/ws`` route carries text only), ``use_judge=True``
  (an extra model round per run), ``calculate_cost=False`` but with
  ``pricing_url`` fetching a public price list — we price against our own
  backend instead. ``flash_mode=True`` shrinks the action schema, which is both
  fewer tokens per round and an easier target for a mid-size open-weight model.
* **Telemetry** (``browser_use/config.py``): ``ANONYMIZED_TELEMETRY`` defaults to
  *true* and ``BROWSER_USE_CLOUD_SYNC`` follows it. This runs on the user's own
  machine, so :func:`_configure_environment` sets both to ``false`` (plus
  ``BROWSER_USE_VERSION_CHECK=false``) before the library is imported.

Where this runs, and why
------------------------

The plan (§9) lists the browser "inside the sandbox". This module puts the
*driver* where the agent runtime already is — the executor process on the user's
machine — and lets the *browser* be either local or remote:

* ``COWORK_BROWSER_EXECUTABLE`` / a Chromium on ``PATH`` — browser-use launches
  it itself, next to the runtime.
* ``COWORK_BROWSER_CDP_URL`` — attach to a browser somebody else runs: the
  container built from ``sandbox/docker/Dockerfile.browser`` with its debug port
  published, or the user's own Chrome started with ``--remote-debugging-port``
  (which is also the honest answer to "how does it get past a login": the profile
  that is already logged in, not a password handed to the agent).

Two reasons, both structural. First, **the model bridge holds the account
session**; running browser-use inside the sandbox would mean putting a credential
that can spend money into the box the agent may `apt install` anything into.
Second, browser-use 0.13 drives the browser purely over CDP, so nothing is lost:
the browser can sit in the container while the driver stays with the token. The
:class:`Environment` seam offers ``run_bash`` and nothing else — no published
port, no RPC — so a driver inside the sandbox would need a channel that does not
exist yet. If the sandbox ever grows one, only :class:`BrowserUseRunner` changes.

What the model bridge is
------------------------

:class:`BackendChatModel` wraps any :class:`~cowork_agent.model.ModelClient` —
in production the account's :class:`~cowork_agent.backend.BackendModelClient`
over ``wss://api.chuk.chat/v2/ws``. Every browser step therefore bills the
account through our backend, and **no provider key and no account token ever
reaches the browser or the sandbox**. ``complete`` is synchronous, so it is
called through :func:`asyncio.to_thread`; browser-use stays fully async.

Hardening, honestly (§8, point 4)
---------------------------------

Enforced here, before a browser exists:

* the start URL runs through :func:`cowork_agent.web_fetch.validate_url` — the
  same scheme allowlist, no embedded credentials, and the same DNS-then-address
  check that refuses loopback, private, CGNAT, link-local (``169.254.169.254``),
  multicast and reserved ranges in v4 and v6, including IPv4-mapped forms.

Enforced by the browser, as configuration we set:

* ``allowed_domains`` — navigation is scoped to the start URL's host (plus
  ``*.<registrable domain>`` and anything the caller passed explicitly).
* ``prohibited_domains`` — the local and metadata names.
* ``block_ip_addresses=True`` — navigation to an IP-literal URL is refused.

**Not** enforceable from here, stated plainly:

* Sub-resources. A page loads its own images, XHR, iframes and beacons; there is
  no per-request hook, so anything the browser process can reach, the page can
  reach.
* A public host name that resolves to a private address. ``block_ip_addresses``
  matches IP *literals*, and our own pre-check only covers the start URL, not
  every later navigation, and cannot cover DNS that changes after the check
  (rebinding).

So the real boundary is the sandbox's **egress policy**, exactly as
:mod:`cowork_agent.web_fetch` already says for its own residual risk. This tool
narrows the blast radius; it does not replace that policy.

Measured, not assumed
---------------------

The whole path was run against a real install and a real Chromium in a throwaway
container built from ``sandbox/docker/Dockerfile.browser`` (Google Chrome for
Testing 151.0.7922.34, browser-use 0.13.7, Python 3.12): browser-use launched the
browser under the profile above, navigated, and called this adapter with
``output_format`` set. With a scripted client that deliberately answers prose, the
run ended in :class:`ModelBridgeError` per step — browser-use reported
"Result failed 1/3 times" — and the tool returned ``ok`` with ``done: false`` and
``usage {"model_rounds": 4, "prompt_tokens": 400, "total_tokens": 428,
"structured_retries": 2}`` for a two-step run. Two things that only a real
install revealed are fixed here: ``ChatInvokeCompletion`` *validates* its
``completion`` field, and ``isinstance(bridge, BaseChatModel)`` is False unless
the adapter also carries ``__get_pydantic_core_schema__``, which the Protocol
counts as a member.

Note that ``steps`` in the result is browser-use's own history length and is
*larger* than the number of model turns (4 history entries for a 2-step run). The
number that maps to money is ``usage.model_rounds``.
"""

from __future__ import annotations

import asyncio
import base64
import glob
import json
import os
import shutil
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from importlib import import_module
from importlib.util import find_spec
from typing import Any, Protocol
from urllib.parse import urlsplit

from .files_out import MAX_FILE_BYTES, FileSink, SentFile, sanitize_name
from .model import ModelClient
from .registry import ToolRegistry
from .web_fetch import Resolver, UrlRejected, validate_url

# -- limits (every one of them is a token or time bound) ----------------------

#: Steps per task. One step = one model round whose prompt carries the current
#: page, so this is the single biggest cost dial. browser-use's own default is
#: 500, which on our pricing is a runaway. Twelve covers open → log in →
#: navigate → extract → done for a normal export; past that the agent is usually
#: lost rather than close, and the cap is the money stop.
DEFAULT_MAX_STEPS = 12
#: Hard ceiling, whatever the model asks for.
MAX_MAX_STEPS = 40
#: Per-step deadline handed to browser-use, and the whole-task deadline.
STEP_TIMEOUT_S = 120
DEFAULT_TASK_TIMEOUT_S = 600
#: How many past steps browser-use keeps in the prompt. Unbounded history is how
#: a browser session's cost grows quadratically.
MAX_HISTORY_ITEMS = 10
#: The returned text goes into the prompt on every following turn (§7.9).
BROWSER_RESULT_CAP = 20_000
#: Screenshots are for the user, not the model; they never enter the prompt.
MAX_SCREENSHOTS = 3

#: Attach to a browser somebody else runs (a published CDP port of the browser
#: image, or the user's own Chrome started with ``--remote-debugging-port``).
CDP_ENV_VAR = "COWORK_BROWSER_CDP_URL"
#: Point at a specific Chromium binary instead of searching.
EXECUTABLE_ENV_VAR = "COWORK_BROWSER_EXECUTABLE"

#: Names that must never be navigated to, on top of the IP-literal block.
PROHIBITED_DOMAINS = (
    "localhost",
    "*.localhost",
    "*.local",
    "*.internal",
    "*.localdomain",
    "metadata.google.internal",
    "metadata.goog",
)

#: Mirrors ``browser_use`` ``_find_installed_browser_path`` (see the docstring).
_LINUX_BROWSER_COMMANDS = (
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "chrome",
)
_PLAYWRIGHT_GLOBS = (
    "chromium-*/chrome-linux*/chrome",
    "chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium",
    "chromium_headless_shell-*/chrome-linux*/chrome",
)

BROWSER_TASK_SCHEMA = {
    "type": "object",
    "description": (
        "Do a task in a real web browser, described in plain language ('log in "
        "to X and export Y as CSV'). This is the FALLBACK: if the service has an "
        "API tool, or if reading one page is enough, use that instead — a browser "
        "session costs one model round per step and is many times more expensive. "
        "Returns what the browser found, plus what the session cost. Navigation "
        "is limited to the start URL's domain."
    ),
    "properties": {
        "task": {
            "type": "string",
            "description": (
                "The task in plain language. Be concrete about the goal and about "
                "what counts as done."
            ),
        },
        "start_url": {
            "type": "string",
            "description": (
                "http(s) URL to open first. Required: it also sets which domains "
                "the browser may navigate to."
            ),
        },
        "max_steps": {
            "type": "integer",
            "description": (
                "Stop after this many browser steps. Each step is one model round."
            ),
            "default": DEFAULT_MAX_STEPS,
        },
        "allow_domains": {
            "type": "string",
            "description": (
                "Extra domains the task needs, comma separated (for example an "
                "identity provider used for the login). Patterns like "
                "'*.example.com' are allowed."
            ),
        },
        "send_screenshots": {
            "type": "boolean",
            "description": (
                "Send the last screenshots to the user as images. They are never "
                "put into the answer, only sent."
            ),
            "default": False,
        },
    },
    "required": ["task", "start_url"],
}


class BrowserUnavailable(Exception):
    """No browser stack in this process. Turned into an error envelope."""


class ModelBridgeError(Exception):
    """The model round behind a browser step failed. Never swallowed: browser-use
    counts it as a step failure and stops after ``max_failures``."""


# -- availability -------------------------------------------------------------


def browser_use_available() -> bool:
    """True when ``browser_use`` is importable in *this* process."""
    try:
        return find_spec("browser_use") is not None
    except (ImportError, ValueError):  # pragma: no cover - broken install
        return False


def browser_use_version() -> str | None:
    """The installed version, or ``None``. Never raises."""
    try:
        from importlib.metadata import version

        return version("browser-use")
    except Exception:
        return None


def find_chromium(executable: str | None = None) -> str | None:
    """Resolve a Chromium/Chrome binary for this process, or ``None``.

    Order: the explicit argument, ``COWORK_BROWSER_EXECUTABLE``, ``PATH``, then
    the Playwright download directory — the same places browser-use itself looks,
    so ``check_fn`` cannot promise a browser the library will fail to find.
    """
    candidates = [executable, os.environ.get(EXECUTABLE_ENV_VAR, "")]
    for candidate in candidates:
        text = (candidate or "").strip()
        if text:
            return text if os.access(text, os.X_OK) else None

    for name in _LINUX_BROWSER_COMMANDS:
        found = shutil.which(name)
        if found:
            return found

    root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "").strip()
    roots = [root] if root else ["~/.cache/ms-playwright", "~/Library/Caches/ms-playwright"]
    for base in roots:
        for pattern in _PLAYWRIGHT_GLOBS:
            matches = sorted(glob.glob(os.path.expanduser(os.path.join(base, pattern))))
            for match in reversed(matches):
                if os.access(match, os.X_OK):
                    return match
    return None


def configured_cdp_url(cdp_url: str | None = None) -> str | None:
    """An externally hosted browser to attach to, or ``None``."""
    text = (cdp_url or os.environ.get(CDP_ENV_VAR, "")).strip()
    return text or None


# -- cost accounting ----------------------------------------------------------


@dataclass
class BridgeUsage:
    """What a browser session spent. Returned with every result — a browser task
    with an invisible cost is a money leak (§7.9)."""

    #: Model rounds, including the repair rounds below.
    invocations: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0
    #: Extra rounds spent because a reply was not valid JSON for the schema.
    structured_retries: int = 0
    #: Image parts we dropped because the backend route carries text only.
    images_dropped: int = 0
    #: Rounds the backend reported no usage for, so the token counts are a floor.
    unreported_rounds: int = 0

    def record(self, usage: dict | None) -> None:
        self.invocations += 1
        if not isinstance(usage, dict):
            self.unreported_rounds += 1
            return
        prompt = _as_int(usage.get("prompt_tokens", usage.get("input_tokens")))
        completion = _as_int(usage.get("completion_tokens", usage.get("output_tokens")))
        total = _as_int(usage.get("total_tokens"))
        if prompt is None and completion is None and total is None:
            self.unreported_rounds += 1
            return
        self.prompt_tokens += prompt or 0
        self.completion_tokens += completion or 0
        self.total_tokens += total if total is not None else (prompt or 0) + (completion or 0)

    def as_dict(self) -> dict:
        return {
            "model_rounds": self.invocations,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
            "structured_retries": self.structured_retries,
            "images_dropped": self.images_dropped,
            "rounds_without_usage": self.unreported_rounds,
        }


def _as_int(value: Any) -> int | None:
    try:
        if value is None or isinstance(value, bool):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


# -- the model bridge ---------------------------------------------------------

_STRUCTURED_INSTRUCTION = (
    "Reply with ONE JSON object and nothing else. No prose, no explanation, no "
    "markdown code fence. It must validate against this JSON schema:\n"
)
_REPAIR_INSTRUCTION = (
    "Your previous reply could not be read as the required JSON object: {reason}. "
    "Send only the JSON object this time. No code fence, no text around it."
)


@dataclass
class _Completion:
    """Stand-in for ``browser_use.llm.views.ChatInvokeCompletion``, used when the
    library is not installed (the offline tests). Same field names, so the
    calling code is identical either way."""

    completion: Any
    usage: Any = None
    thinking: str | None = None
    redacted_thinking: str | None = None
    stop_reason: str | None = None
    stop_details: dict | None = None


def _completion_classes() -> tuple[type, type | None]:
    """``(ChatInvokeCompletion, ChatInvokeUsage)`` from browser-use when it is
    installed, else the local stand-in and ``None``."""
    try:
        views = import_module("browser_use.llm.views")
    except Exception:
        return _Completion, None
    return views.ChatInvokeCompletion, views.ChatInvokeUsage


class BackendChatModel:
    """A ``browser_use.llm.base.BaseChatModel`` (a Protocol — nothing to
    subclass) implemented over one of our :class:`~cowork_agent.model.ModelClient`
    instances.

    The client is whatever the runtime was given, in production the account's
    ``/v2/ws`` client. Consequences worth naming:

    * the browser's model rounds are billed to the account, server-side, like
      every other round — there is no second billing path and no provider key;
    * the route carries **text**, so image parts are dropped and counted, and
      the caller runs the Agent with ``use_vision=False``;
    * ``complete`` is synchronous, so it runs in a worker thread.
    """

    #: browser-use skips its API-key probe when this is already true. There is no
    #: key to probe — the credential is the account session inside the client.
    _verified_api_keys = True

    def __init__(
        self,
        client: ModelClient,
        *,
        model: str = "cowork-backend",
        usage: BridgeUsage | None = None,
        repairs: int = 1,
    ) -> None:
        self._client = client
        self.model = model
        self.usage = usage if usage is not None else BridgeUsage()
        self._repairs = max(0, int(repairs))

    # -- BaseChatModel surface -------------------------------------------

    @property
    def provider(self) -> str:
        return "cowork-backend"

    @property
    def name(self) -> str:
        return self.model

    @property
    def model_name(self) -> str:
        return self.model

    @classmethod
    def __get_pydantic_core_schema__(cls, source_type: Any, handler: Any) -> Any:
        """Present because ``BaseChatModel`` declares it.

        A ``runtime_checkable`` Protocol counts *every* member, so without this
        method ``isinstance(bridge, BaseChatModel)`` is False even though every
        real method matches — measured against the installed 0.13.7, not guessed.
        The body mirrors the library's own: the Protocol is used as a pydantic
        field type in the agent settings, and any object is accepted. ``pydantic_core``
        is imported here and not at module level, so this file keeps working
        without pydantic installed.
        """
        del source_type, handler
        from pydantic_core import core_schema

        return core_schema.any_schema()

    async def ainvoke(
        self,
        messages: Sequence[Any],
        output_format: type | None = None,
        **kwargs: Any,
    ) -> Any:
        del kwargs  # temperature and friends belong to the client, not here
        turns, dropped = messages_to_dicts(messages)
        self.usage.images_dropped += dropped
        completion_cls, usage_cls = _completion_classes()

        if output_format is None:
            text, usage = await self._round(turns)
            return _wrap(completion_cls, text, usage, usage_cls)

        schema = _schema_of(output_format)
        attempt_turns = list(turns)
        if schema:
            attempt_turns.append(
                {"role": "user", "content": _STRUCTURED_INSTRUCTION + schema}
            )
        last_reason = "no reply"
        for attempt in range(self._repairs + 1):
            text, usage = await self._round(attempt_turns)
            data = extract_json_object(text)
            if data is not None:
                try:
                    parsed = output_format.model_validate(data)
                except Exception as exc:
                    last_reason = f"{type(exc).__name__}"
                else:
                    return _wrap(completion_cls, parsed, usage, usage_cls)
            else:
                last_reason = "no JSON object in the reply"
            if attempt < self._repairs:
                self.usage.structured_retries += 1
                attempt_turns = list(attempt_turns) + [
                    {"role": "assistant", "content": text or ""},
                    {
                        "role": "user",
                        "content": _REPAIR_INSTRUCTION.format(reason=last_reason),
                    },
                ]
        # Raise, never fake a decision: browser-use counts this as a failed step
        # and stops the run after ``max_failures``, which is the behaviour we
        # want — a silently invented action would click something at random.
        raise ModelBridgeError(f"model did not return valid structured output: {last_reason}")

    # -- one round -------------------------------------------------------

    async def _round(self, turns: list[dict]) -> tuple[str, dict | None]:
        try:
            response = await asyncio.to_thread(self._client.complete, turns)
        except Exception as exc:
            self.usage.invocations += 1
            self.usage.unreported_rounds += 1
            raise ModelBridgeError(f"{type(exc).__name__}: {exc}") from exc
        raw = getattr(response, "raw", None)
        usage = raw.get("usage") if isinstance(raw, dict) else None
        self.usage.record(usage if isinstance(usage, dict) else None)
        text = getattr(response, "text", None)
        if not text and isinstance(raw, dict):
            candidate = raw.get("content")
            text = candidate if isinstance(candidate, str) else None
        return text or "", usage if isinstance(usage, dict) else None


def _wrap(completion_cls: type, value: Any, usage: dict | None, usage_cls: type | None) -> Any:
    """Build the ``ChatInvokeCompletion``.

    It is a pydantic model and it validates: ``completion`` must be a
    ``BaseModel`` or a ``str``. A failure here would otherwise leave a raw
    ``ValidationError`` from a foreign library escaping the adapter, which
    browser-use would report as a mystery. It becomes our own error instead.
    """
    try:
        return completion_cls(completion=value, usage=_to_usage(usage, usage_cls))
    except Exception as exc:
        raise ModelBridgeError(
            f"could not build the completion for {type(value).__name__}: {type(exc).__name__}"
        ) from exc


def _to_usage(usage: dict | None, usage_cls: type | None) -> Any:
    """Map a backend ``usage`` frame onto ``ChatInvokeUsage``. ``None`` is a
    legal value and the field has no default, so it is always passed."""
    if usage is None or usage_cls is None:
        return None
    prompt = _as_int(usage.get("prompt_tokens", usage.get("input_tokens"))) or 0
    completion = _as_int(usage.get("completion_tokens", usage.get("output_tokens"))) or 0
    total = _as_int(usage.get("total_tokens"))
    try:
        return usage_cls(
            prompt_tokens=prompt,
            prompt_cached_tokens=None,
            prompt_cache_creation_tokens=None,
            prompt_image_tokens=None,
            completion_tokens=completion,
            total_tokens=total if total is not None else prompt + completion,
        )
    except Exception:
        # A future field change must not break a browser step over accounting.
        return None


def messages_to_dicts(messages: Sequence[Any]) -> tuple[list[dict], int]:
    """browser-use messages -> the ``[{"role","content"}]`` list our clients take.

    Returns the turns and how many image parts were dropped. Image parts are
    dropped because the ``/v2/ws`` chat payload carries a text ``message`` only;
    counting them is what keeps that from being a silent loss.
    """
    turns: list[dict] = []
    dropped = 0
    for message in messages or []:
        role = getattr(message, "role", None)
        if role not in ("system", "user", "assistant"):
            role = "user"
        content = getattr(message, "content", None)
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, (list, tuple)):
            parts: list[str] = []
            for part in content:
                kind = getattr(part, "type", None)
                if kind == "text":
                    parts.append(str(getattr(part, "text", "")))
                elif kind == "refusal":
                    parts.append(f"[refusal] {getattr(part, 'refusal', '')}")
                elif kind == "image_url":
                    dropped += 1
            text = "\n".join(p for p in parts if p)
        else:
            fallback = getattr(message, "text", None)
            text = fallback if isinstance(fallback, str) else ""
        turns.append({"role": role, "content": text})
    return turns, dropped


def _schema_of(output_format: type) -> str:
    """The pydantic JSON schema as compact text, or ``""`` if it has none."""
    getter = getattr(output_format, "model_json_schema", None)
    if not callable(getter):
        return ""
    try:
        return json.dumps(getter(), separators=(",", ":"))
    except Exception:
        return ""


def extract_json_object(text: str | None) -> dict | None:
    """Pull the first JSON object out of a model reply.

    Handles the three shapes a text model actually produces: a bare object, an
    object inside a ``` fence, and an object after a sentence of prose. Brace
    matching is string- and escape-aware, so a ``}`` inside a value does not end
    the object early.
    """
    if not text:
        return None
    body = text.strip()
    if body.startswith("```"):
        # Drop the opening fence (with or without a language tag) and the closer.
        body = body.split("\n", 1)[1] if "\n" in body else ""
        if "```" in body:
            body = body.rsplit("```", 1)[0]
        body = body.strip()
    try:
        parsed = json.loads(body)
        if isinstance(parsed, dict):
            return parsed
    except (ValueError, TypeError):
        pass

    start = body.find("{")
    while start != -1:
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(body)):
            char = body[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue
            if char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    try:
                        parsed = json.loads(body[start : index + 1])
                    except (ValueError, TypeError):
                        break
                    if isinstance(parsed, dict):
                        return parsed
                    break
        start = body.find("{", start + 1)
    return None


# -- URL policy ---------------------------------------------------------------


#: Two-label public suffixes. The last two labels of ``app.example.co.uk`` are a
#: *suffix*, not a registrable domain, so a naive "last two labels" rule would put
#: ``*.co.uk`` — every host in the United Kingdom — on the allowed list. A curated
#: set covers the cases that actually turn up and needs no new dependency;
#: an unusual suffix that is not in here still degrades safely, because the
#: wildcard is then simply not added.
_TWO_LABEL_SUFFIXES = frozenset(
    {
        "ac.uk", "co.uk", "gov.uk", "me.uk", "net.uk", "org.uk", "sch.uk",
        "com.au", "edu.au", "gov.au", "id.au", "net.au", "org.au",
        "co.nz", "net.nz", "org.nz",
        "ac.jp", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.cn", "com.hk", "com.mx", "com.sg", "com.tr", "com.tw",
        "co.in", "co.il", "co.kr", "co.za", "com.ar", "com.pl", "com.ua",
        "co.at", "or.at", "com.es", "gov.br", "gob.mx",
    }
)


def registrable_domain(host: str) -> str:
    """The part of ``host`` a wildcard may safely cover, or ``""``.

    ``www.example.com`` -> ``example.com``. ``app.example.co.uk`` ->
    ``example.co.uk``, **not** ``co.uk``: widening to a two-label public suffix
    would allow every host in a whole country, which is the opposite of what
    :func:`domain_scope` promises.
    """
    labels = [label for label in (host or "").lower().split(".") if label]
    if len(labels) < 2:
        return ""
    if ".".join(labels[-2:]) in _TWO_LABEL_SUFFIXES:
        return ".".join(labels[-3:]) if len(labels) >= 3 else ""
    return ".".join(labels[-2:])


def domain_scope(url: str, extra: Sequence[str] = ()) -> list[str]:
    """The ``allowed_domains`` list for a task: the exact host, ``*.<host>``, and
    ``*.<registrable domain>`` so ``login.example.com`` stays reachable from
    ``www.example.com``. Explicit extras are kept verbatim — a pattern the caller
    wrote is the caller's decision."""
    host = (urlsplit(url).hostname or "").lower()
    scope: list[str] = []
    if host:
        scope.append(host)
        scope.append(f"*.{host}")
        registrable = registrable_domain(host)
        if registrable and registrable != host:
            scope.append(f"*.{registrable}")
    for item in extra:
        text = (item or "").strip().lower()
        if text and text not in scope:
            scope.append(text)
    return scope


def parse_domain_list(raw: str | Sequence[str] | None) -> list[str]:
    """A comma-separated string (what a model reliably sends) or a real list."""
    if raw is None:
        return []
    if isinstance(raw, str):
        items = raw.replace(";", ",").split(",")
    else:
        items = [str(item) for item in raw]
    out: list[str] = []
    for item in items:
        text = item.strip().lower()
        # A URL where a domain was wanted is a common model slip; take its host.
        if "://" in text:
            text = (urlsplit(text).hostname or "").lower()
        if text and text not in out:
            out.append(text)
    return out


# -- the runner seam ----------------------------------------------------------


@dataclass
class BrowserTaskSpec:
    """Everything the runner needs, after validation. A dataclass rather than a
    pile of arguments so a fake runner in a test can assert on the whole plan —
    including that the step cap really arrived."""

    task: str
    start_url: str
    max_steps: int
    allowed_domains: list[str]
    prohibited_domains: list[str] = field(default_factory=lambda: list(PROHIBITED_DOMAINS))
    want_screenshots: bool = False
    max_screenshots: int = MAX_SCREENSHOTS
    timeout_s: float = DEFAULT_TASK_TIMEOUT_S


@dataclass
class BrowserRunOutcome:
    """What a browser run produced, independent of browser-use's own types."""

    done: bool = False
    success: bool | None = None
    #: History entries, which is browser-use's own ``number_of_steps()``.
    steps: int = 0
    #: The step budget was used up. Set by the runner from the agent's own step
    #: counter, the one number that is comparable to ``max_steps``; ``None`` when
    #: it could not be read, so the result says nothing rather than guessing.
    budget_exhausted: bool | None = None
    result: str = ""
    urls: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    screenshots: list[bytes] = field(default_factory=list)


class BrowserRunner(Protocol):
    async def run(self, spec: BrowserTaskSpec, llm: Any) -> BrowserRunOutcome: ...


def _configure_environment() -> None:
    """Silence browser-use's phone-home before the library is imported.

    ``ANONYMIZED_TELEMETRY`` defaults to true and ``BROWSER_USE_CLOUD_SYNC``
    follows it, so a plain import would post agent events off the user's machine.
    ``setdefault``, so an operator who wants them can still say so.
    """
    os.environ.setdefault("ANONYMIZED_TELEMETRY", "false")
    os.environ.setdefault("BROWSER_USE_CLOUD_SYNC", "false")
    os.environ.setdefault("BROWSER_USE_VERSION_CHECK", "false")
    # At INFO the library prints the task text and every URL it visits. That is
    # user content in a log file; keep it at ``error``.
    os.environ.setdefault("BROWSER_USE_LOGGING_LEVEL", "error")
    # There is no API key in this setup; the probe would only cost a round trip.
    os.environ.setdefault("SKIP_LLM_API_KEY_VERIFICATION", "true")


class BrowserUseRunner:
    """The real runner: browser-use over a Chromium it launches, or over a CDP
    endpoint somebody else runs.

    Both paths go through the same :class:`BrowserTaskSpec`, so the policy above
    is applied identically whether the browser is ours or attached to.
    """

    def __init__(
        self,
        *,
        cdp_url: str | None = None,
        executable_path: str | None = None,
        headless: bool = True,
        user_data_dir: str | None = None,
    ) -> None:
        self._cdp_url = cdp_url
        self._executable_path = executable_path
        self._headless = headless
        self._user_data_dir = user_data_dir
        self._available: bool | None = None

    def available(self) -> bool:
        """Probe once and remember it: this is the tool's ``check_fn``, so it runs
        on every prompt render and every dispatch, and it walks ``sys.path`` and a
        few globs."""
        if self._available is None:
            self._available = browser_use_available() and (
                bool(configured_cdp_url(self._cdp_url))
                or bool(find_chromium(self._executable_path))
            )
        return self._available

    async def run(self, spec: BrowserTaskSpec, llm: Any) -> BrowserRunOutcome:
        _configure_environment()
        try:
            browser_use = import_module("browser_use")
            profile_mod = import_module("browser_use.browser.profile")
        except Exception as exc:  # pragma: no cover - install-dependent
            raise BrowserUnavailable(f"browser_use import failed: {type(exc).__name__}: {exc}") from exc

        cdp_url = configured_cdp_url(self._cdp_url)
        executable = None if cdp_url else find_chromium(self._executable_path)
        if not cdp_url and not executable:  # pragma: no cover - guarded by check_fn
            raise BrowserUnavailable("no Chromium executable and no CDP endpoint")

        profile_kwargs: dict[str, Any] = {
            "headless": self._headless,
            # Navigation policy. The browser enforces these; see the module
            # docstring for what they do and do not cover.
            "allowed_domains": list(spec.allowed_domains),
            "prohibited_domains": list(spec.prohibited_domains),
            "block_ip_addresses": True,
            # Chrome's own sandbox needs privileges a container does not have;
            # the container is the isolation boundary here, not Chrome's.
            "chromium_sandbox": False,
            # Cost: the extensions are fetched over the network on first launch.
            "enable_default_extensions": False,
        }
        if executable:
            profile_kwargs["executable_path"] = executable
        if self._user_data_dir:
            profile_kwargs["user_data_dir"] = self._user_data_dir
        # Unset, browser-use uses its own persistent profile directory
        # (``~/.config/browseruse/profiles/default``). That is left alone on
        # purpose: cookies survive between tasks, so a login done once stays
        # usable, which is the whole point of the browser fallback.
        profile = profile_mod.BrowserProfile(**profile_kwargs)

        session_kwargs: dict[str, Any] = {"browser_profile": profile}
        if cdp_url:
            session_kwargs["cdp_url"] = cdp_url
        browser = browser_use.BrowserSession(**session_kwargs)

        agent = browser_use.Agent(
            task=_task_text(spec),
            llm=llm,
            browser_session=browser,
            # Every one of these is a cost decision; see the module docstring.
            use_vision=False,
            use_judge=False,
            calculate_cost=False,
            flash_mode=True,
            max_history_items=MAX_HISTORY_ITEMS,
            max_failures=2,
            step_timeout=STEP_TIMEOUT_S,
        )
        try:
            history = await asyncio.wait_for(
                agent.run(max_steps=spec.max_steps), timeout=spec.timeout_s
            )
        except asyncio.TimeoutError as exc:
            raise TimeoutError(
                f"browser task hit the {spec.timeout_s:.0f}s deadline"
            ) from exc
            # Read before teardown: this is the counter the run loop compares
            # against ``max_steps`` (``while self.state.n_steps <= max_steps``,
            # agent/service.py), so it — and not the history length — is what
            # says whether the budget ran out. It ends one past the budget.
            n_steps = _as_int(getattr(getattr(agent, "state", None), "n_steps", None))
        finally:
            try:
                await agent.close()
            except Exception:  # pragma: no cover - teardown must not mask a result
                pass
        outcome = outcome_from_history(history, spec)
        if n_steps is not None:
            outcome.budget_exhausted = n_steps > spec.max_steps
        return outcome


def _task_text(spec: BrowserTaskSpec) -> str:
    return (
        f"{spec.task}\n\nStart at {spec.start_url}. Stay on the domains you are "
        f"allowed to visit. When the goal is reached, finish and report the result."
    )


def outcome_from_history(history: Any, spec: BrowserTaskSpec) -> BrowserRunOutcome:
    """Map an ``AgentHistoryList`` onto :class:`BrowserRunOutcome`.

    Every accessor is called defensively: a version bump that renames one of them
    must degrade the report, not lose a finished browser session.
    """

    def call(name: str, default: Any, *args: Any) -> Any:
        method = getattr(history, name, None)
        if not callable(method):
            return default
        try:
            value = method(*args)
        except Exception:
            return default
        return default if value is None else value

    urls = [str(url) for url in call("urls", []) if url]
    errors = [str(error) for error in call("errors", []) if error]
    screenshots: list[bytes] = []
    if spec.want_screenshots:
        raw = call("screenshots", [], spec.max_screenshots, False)
        screenshots = [decoded for decoded in (_decode_b64(item) for item in raw) if decoded]
    return BrowserRunOutcome(
        done=bool(call("is_done", False)),
        success=call("is_successful", None),
        steps=int(call("number_of_steps", 0) or 0),
        result=str(call("final_result", "") or ""),
        # Deduplicate consecutive repeats: a browser sits on one URL for steps.
        urls=_dedupe(urls),
        errors=errors,
        screenshots=screenshots,
    )


def _dedupe(items: list[str]) -> list[str]:
    out: list[str] = []
    for item in items:
        if not out or out[-1] != item:
            out.append(item)
    return out


def _decode_b64(item: Any) -> bytes | None:
    if not isinstance(item, str) or not item:
        return None
    try:
        return base64.b64decode(item, validate=False)
    except Exception:
        return None


# -- the tool -----------------------------------------------------------------


def make_browser_task_handler(
    model: ModelClient,
    *,
    runner: BrowserRunner,
    file_sink: FileSink | None = None,
    resolve: Resolver | None = None,
    model_id: str = "cowork-backend",
    max_steps_ceiling: int = MAX_MAX_STEPS,
    timeout_s: float = DEFAULT_TASK_TIMEOUT_S,
    max_file_bytes: int = MAX_FILE_BYTES,
):
    """Build the async ``browser_task`` handler.

    ``runner`` is the seam: the production one drives browser-use, a test passes
    a fake and every rule around the browser — the URL policy, the step cap, the
    cost report, the screenshot channel — is checked without a browser existing.
    """

    async def browser_task(
        task: str,
        start_url: str,
        max_steps: int = DEFAULT_MAX_STEPS,
        allow_domains: str | list[str] | None = None,
        send_screenshots: bool = False,
    ) -> dict:
        text_task = (task if isinstance(task, str) else str(task or "")).strip()
        if not text_task:
            return {"ok": False, "error": "task is empty"}

        # The URL policy runs first, so a forbidden target never starts a browser.
        try:
            url = validate_url(
                start_url, resolve=resolve or _default_resolver_for_policy()
            )
        except UrlRejected as exc:
            return {"ok": False, "url": str(start_url), "error": f"start_url rejected: {exc}"}

        try:
            steps = int(max_steps)
        except (TypeError, ValueError):
            steps = DEFAULT_MAX_STEPS
        steps = max(1, min(steps, max_steps_ceiling))

        spec = BrowserTaskSpec(
            task=text_task,
            start_url=url,
            max_steps=steps,
            allowed_domains=domain_scope(url, parse_domain_list(allow_domains)),
            want_screenshots=bool(send_screenshots) and file_sink is not None,
            timeout_s=timeout_s,
        )

        usage = BridgeUsage()
        llm = BackendChatModel(model, model=model_id, usage=usage)
        started = time.monotonic()
        try:
            outcome = await runner.run(spec, llm)
        except BrowserUnavailable as exc:
            return {
                "ok": False,
                "url": url,
                "error": f"browser not available: {exc}",
                "usage": usage.as_dict(),
            }
        except (ModelBridgeError, TimeoutError) as exc:
            # Partial spend still has to be reported: this is where the money went.
            return {
                "ok": False,
                "url": url,
                "error": f"{type(exc).__name__}: {exc}",
                "steps_allowed": steps,
                "duration_s": round(time.monotonic() - started, 2),
                "usage": usage.as_dict(),
            }
        except Exception as exc:
            return {
                "ok": False,
                "url": url,
                "error": f"browser task failed: {type(exc).__name__}: {exc}",
                "duration_s": round(time.monotonic() - started, 2),
                "usage": usage.as_dict(),
            }

        result_text = outcome.result or ""
        truncated = len(result_text) > BROWSER_RESULT_CAP
        if truncated:
            result_text = result_text[:BROWSER_RESULT_CAP]

        sent = _send_screenshots(
            outcome.screenshots,
            file_sink if spec.want_screenshots else None,
            max_bytes=max_file_bytes,
            limit=spec.max_screenshots,
        )

        payload: dict[str, Any] = {
            "ok": True,
            "url": url,
            "done": outcome.done,
            "success": outcome.success,
            # `steps` is browser-use's own history length, which counts more
            # entries than model turns (measured: 4 for a 2-step run). The
            # authoritative cost figure is `usage.model_rounds`, and the step
            # budget is judged by the runner from the agent's own counter — never
            # by comparing the history length against `steps_allowed`.
            "steps": outcome.steps,
            "steps_allowed": steps,
            "result": result_text,
            "truncated": truncated,
            "visited": outcome.urls[-5:],
            "duration_s": round(time.monotonic() - started, 2),
            "usage": usage.as_dict(),
        }
        if outcome.budget_exhausted is not None:
            payload["capped"] = bool(outcome.budget_exhausted) and not outcome.done
        if outcome.errors:
            payload["errors"] = outcome.errors[-5:]
        if sent:
            payload["screenshots_sent"] = sent
        return payload

    return browser_task


def _default_resolver_for_policy() -> Resolver:
    from .web_fetch import _default_resolver

    return _default_resolver


def _send_screenshots(
    shots: Sequence[bytes],
    sink: FileSink | None,
    *,
    max_bytes: int,
    limit: int = MAX_SCREENSHOTS,
) -> int:
    """Push screenshots at the user through the same sealed channel
    ``send_file_to_user`` uses (:mod:`cowork_agent.files_out`).

    The bytes are already in this process, so they go straight to the sink rather
    than through the sandbox — and, like ``send_file_to_user``, they never enter
    the tool result: a base64 PNG in the prompt would be ruinous and pointless.
    A failing sink is counted as "not sent", never raised: a browser task must
    not fail because a screenshot could not be delivered.
    """
    if sink is None:
        return 0
    sent = 0
    # The last few, whatever the run produced: the end of a browser task is what
    # a user wants to see, and each image costs relay bandwidth.
    for index, data in enumerate(list(shots)[-max(1, limit) :], start=1):
        if not data or len(data) > max_bytes:
            continue
        # Numbered within what is sent, not by browser-use's step counter: only
        # the last few are sent, so a step number here would be a lie.
        name = sanitize_name(f"browser-screenshot-{index}.png", fallback="screenshot.png")
        try:
            sink(SentFile(name=name, mime_type="image/png", size=len(data), data=data))
        except Exception:
            continue
        sent += 1
    return sent


def register_browser_task(
    registry: ToolRegistry,
    model: ModelClient | None,
    *,
    runner: BrowserRunner | None = None,
    available: Callable[[], bool] | None = None,
    file_sink: FileSink | None = None,
    resolve: Resolver | None = None,
    model_id: str = "cowork-backend",
    cdp_url: str | None = None,
    executable_path: str | None = None,
    user_data_dir: str | None = None,
    timeout_s: float = DEFAULT_TASK_TIMEOUT_S,
) -> None:
    """Register ``browser_task``.

    Without a ``model`` there is nothing to drive the browser with and the tool
    is not registered at all — it costs no prompt tokens in a run that cannot use
    it. The ``model`` must be a client the *browser* may use freely: not the
    loop's streaming client, or every browser step's JSON would be streamed into
    the user's chat.

    ``check_fn`` is the real gate: without ``browser_use`` importable and without
    either a Chromium binary or a configured CDP endpoint, the tool stays out of
    the prompt (:func:`cowork_agent.prompt.render_tool_docs`) and a call to it
    comes back as ``tool unavailable`` from the registry.
    """
    if model is None:
        return
    real_runner = runner or BrowserUseRunner(
        cdp_url=cdp_url,
        executable_path=executable_path,
        user_data_dir=user_data_dir,
    )
    if available is None:
        probe = getattr(real_runner, "available", None)
        available = probe if callable(probe) else (lambda: True)
    registry.register(
        "browser_task",
        BROWSER_TASK_SCHEMA,
        make_browser_task_handler(
            model,
            runner=real_runner,
            file_sink=file_sink,
            resolve=resolve,
            model_id=model_id,
            timeout_s=timeout_s,
        ),
        check_fn=available,
        is_async=True,
    )


__all__ = [
    "CDP_ENV_VAR",
    "DEFAULT_MAX_STEPS",
    "DEFAULT_TASK_TIMEOUT_S",
    "EXECUTABLE_ENV_VAR",
    "MAX_HISTORY_ITEMS",
    "MAX_MAX_STEPS",
    "MAX_SCREENSHOTS",
    "PROHIBITED_DOMAINS",
    "BROWSER_RESULT_CAP",
    "STEP_TIMEOUT_S",
    "BackendChatModel",
    "BridgeUsage",
    "BrowserRunOutcome",
    "BrowserRunner",
    "BrowserTaskSpec",
    "BrowserUnavailable",
    "BrowserUseRunner",
    "ModelBridgeError",
    "browser_use_available",
    "browser_use_version",
    "configured_cdp_url",
    "domain_scope",
    "extract_json_object",
    "find_chromium",
    "make_browser_task_handler",
    "messages_to_dicts",
    "outcome_from_history",
    "parse_domain_list",
    "register_browser_task",
    "registrable_domain",
]
