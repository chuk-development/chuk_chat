"""Chat-network gateways of the host (CHAT-184, docs/agents/GATEWAYS.md).

:func:`build_gateways` returns the gateways that are configured. Each one is
off unless its token exists: today only Telegram.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable

from .base import Gateway, GatewayHost, gateway_session_key, split_message
from .store import GATEWAYS_DIR, GatewayStore, TokenStore, gateway_token_key

#: ``AGENTS_GATEWAYS=0`` turns every gateway off.
GATEWAYS_ENV = "AGENTS_GATEWAYS"

__all__ = [
    "Gateway",
    "GatewayHost",
    "GatewayStore",
    "TokenStore",
    "build_gateways",
    "gateway_session_key",
    "gateway_token_key",
    "split_message",
    "telegram_token_store",
]


def telegram_token_store(state_dir: str | os.PathLike, identity: Any) -> TokenStore:
    """The sealed Telegram bot token of the host in ``state_dir``."""
    key = gateway_token_key(identity, "telegram") if identity is not None else None
    return TokenStore(Path(state_dir) / GATEWAYS_DIR / "telegram-token.enc", key)


def build_gateways(
    host: GatewayHost,
    state_dir: str | os.PathLike,
    identity: Any,
    *,
    log: Callable[[str], None] | None = None,
    environ: dict | None = None,
) -> list[Gateway]:
    """The configured gateways, not started."""
    env = os.environ if environ is None else environ
    if env.get(GATEWAYS_ENV, "1") == "0":
        return []
    from .telegram import TOKEN_SECRET_NAME, TelegramGateway
    from .telegram_api import TelegramBotApi

    gateways: list[Gateway] = []
    token = telegram_token_store(state_dir, identity).get() or host.secret(TOKEN_SECRET_NAME)
    if token:
        try:
            api = TelegramBotApi(token)
        except ValueError:
            if log is not None:
                log("[telegram] the stored bot token has a wrong form; the gateway is off")
        else:
            gateways.append(
                TelegramGateway(api, host, GatewayStore(state_dir, "telegram"), log=log)
            )
    return gateways
