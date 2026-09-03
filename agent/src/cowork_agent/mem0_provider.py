"""A Mem0 LLM provider backed by our own WebSocket model (§12).

Mem0's fact-extraction step needs a chat LLM. The rest of CoWork already has one
— :class:`cowork_agent.backend.BackendModelClient`, which talks to
``wss://api.chuk.chat/v2/ws`` and bills the account. There is no
OpenAI-compatible chat route on the proxy, so instead of pointing Mem0 at a
third-party endpoint we register a custom provider, ``chukbackend``, that routes
Mem0's extraction calls through that same socket.

The bridge is deliberately tiny: :class:`ChukBackendLLM` implements the one
abstract method Mem0 requires, :meth:`generate_response`, converts Mem0's
``[{"role", "content"}]`` messages into what
:meth:`ModelClient.complete` expects, and returns the model's text. Mem0 asks
for a JSON object (``response_format={"type": "json_object"}``) and parses the
returned string itself, so all we owe it is the raw text.

Dependency injection is by design. The provider takes an explicit ``client``,
and when Mem0's own factory builds it (which cannot pass one) it falls back to a
module-level client set by :func:`set_backend_client`. Tests build the provider
directly with a stub and never touch the network.
"""

from __future__ import annotations

import logging
from typing import Any

from mem0.configs.llms.base import BaseLlmConfig
from mem0.llms.base import LLMBase

from .model import ModelClient

logger = logging.getLogger(__name__)

# The provider name Mem0 config refers to (``{"llm": {"provider": "chukbackend"}}``).
PROVIDER_NAME = "chukbackend"

# Mem0 2.0.x validates ``llm.provider`` against a HARDCODED allowlist in a
# pydantic field-validator (``mem0.llms.configs.LlmConfig.validate_config``) that
# runs at ``Memory.from_config`` time — *before* ``LlmFactory`` is ever consulted.
# A genuinely custom provider name like ``chukbackend`` is therefore rejected
# outright ("Unsupported LLM provider"), and the validator is compiled into the
# model at class-creation, so it cannot be monkeypatched after import. The robust
# workaround is to repurpose an allowlisted-but-unused slot: ``lmstudio`` is a
# local-inference provider we never use, it carries no ``provider ==`` special
# case anywhere in Mem0's extraction path, and its factory class is overridden
# below to our own :class:`ChukBackendLLM`. So the config declares provider
# ``lmstudio`` (passes the allowlist) and the factory builds *our* class.
ALIAS_PROVIDER = "lmstudio"

# Fallback client for the factory path. Mem0's ``LlmFactory`` instantiates the
# provider as ``llm_class(config)`` with no room for our client, so
# ``memory.py`` sets this just before building ``Memory`` and each provider
# instance reads it. A directly constructed provider (tests) passes ``client=``
# and ignores this.
_backend_client: ModelClient | None = None


def set_backend_client(client: ModelClient | None) -> None:
    """Set the process-wide client the factory-built provider will use."""
    global _backend_client
    _backend_client = client


def register_provider() -> None:
    """Teach Mem0's ``LlmFactory`` about the ``chukbackend`` provider.

    Idempotent. Registered against ``BaseLlmConfig`` (the generic config Mem0
    passes when it has no provider-specific class), so the ``config`` block in
    the Mem0 config — ``model``, ``temperature``, ``max_tokens`` — is honoured.
    """
    from mem0.utils.factory import LlmFactory

    target = ("cowork_agent.mem0_provider.ChukBackendLLM", BaseLlmConfig)
    # Register under the real name (for clarity / ``get_supported_providers``)
    # AND the allowlisted alias the config actually declares (see ALIAS_PROVIDER).
    LlmFactory.provider_to_class[PROVIDER_NAME] = target
    LlmFactory.provider_to_class[ALIAS_PROVIDER] = target


def _coerce_content(content: Any) -> str:
    """Flatten Mem0 message content to a plain string.

    Mem0 sends string content, but be defensive: a list of parts (the OpenAI
    multimodal shape) is joined on its text pieces so a stray structured message
    never blows up the extraction call.
    """
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                parts.append(str(part.get("text", "")))
        return "".join(parts)
    return str(content)


def _normalize_messages(messages: list[dict]) -> list[dict]:
    """Map Mem0's messages onto the ``{"role", "content"}`` list ``complete`` reads.

    ``BackendModelClient`` already folds system/assistant/tool roles into its
    payload, so we only guarantee a role and a string content here.
    """
    out: list[dict] = []
    for message in messages or []:
        role = message.get("role") or "user"
        out.append({"role": role, "content": _coerce_content(message.get("content"))})
    return out


class ChukBackendLLM(LLMBase):
    """Mem0 LLM provider that calls a :class:`ModelClient` over our backend.

    ``client`` is injected for tests; when omitted (the factory path) the
    module-level client from :func:`set_backend_client` is used.
    """

    def __init__(
        self,
        config: BaseLlmConfig | dict | None = None,
        client: ModelClient | None = None,
    ) -> None:
        super().__init__(config)
        self._client = client if client is not None else _backend_client

    def generate_response(
        self,
        messages: list[dict],
        tools: list[dict] | None = None,
        tool_choice: str = "auto",
        **kwargs: Any,
    ) -> str:
        """Run Mem0's extraction prompt through the backend and return its text.

        ``tools``/``tool_choice``/``response_format`` and any other Mem0 kwargs
        are accepted and ignored: the backend answers in text, and Mem0 parses
        the JSON out of that text itself.
        """
        client = self._client
        if client is None:
            raise RuntimeError(
                "ChukBackendLLM has no backend client; call set_backend_client() "
                "before building Mem0, or pass client= directly."
            )
        response = client.complete(_normalize_messages(messages))
        return response.text or ""
