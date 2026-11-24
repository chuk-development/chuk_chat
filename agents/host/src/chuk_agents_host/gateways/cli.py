"""``agents-host telegram ...`` (CHAT-184, docs/agents/GATEWAYS.md).

- ``token``: read the bot token from stdin (or a hidden prompt) and store it
  sealed. The token is never an argument: every local user can read a
  command line.
- ``pair``: print a one-time code for ``/pair <code>`` in Telegram.
- ``status``: token stored, paired users.
- ``unpair <user id>``: remove one paired user.
- ``off``: delete the stored token (the paired users stay).

The running host reads the token at start: restart it after ``token`` or
``off``. A code from ``pair`` works at once.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path
from typing import Any, Callable

from . import telegram_token_store
from .store import PAIRING_TTL_SECONDS, GatewayStore


def add_parser(sub: Any, workspace_help: str) -> None:
    parser = sub.add_parser(
        "telegram",
        help="set up the Telegram gateway: token, pairing codes, paired users",
        description="Talk to your agents from Telegram. Make a bot with "
        "@BotFather, store its token with 'telegram token', restart the host, "
        "then send '/pair <code>' to the bot with a code from 'telegram pair'.",
    )
    parser.add_argument("--workspace", default=None, help=workspace_help)
    tg = parser.add_subparsers(dest="telegram_command")
    tg.add_parser("token", help="store the bot token (read from stdin or a hidden prompt)")
    tg.add_parser("pair", help="print a one-time pairing code")
    tg.add_parser("status", help="show whether a token is stored and who is paired")
    unpair = tg.add_parser("unpair", help="remove a paired Telegram user")
    unpair.add_argument("user_id")
    tg.add_parser("off", help="delete the stored bot token")


def cmd_telegram(
    args: argparse.Namespace,
    *,
    out: Callable[..., Any] = print,
    stdin: Any = None,
    identity: Any = None,
) -> int:
    workspace = Path(args.workspace).expanduser()
    store = GatewayStore(workspace, "telegram")
    command = getattr(args, "telegram_command", None) or "status"
    if command == "pair":
        code = store.new_pairing_code()
        out(f"Send this to your bot in Telegram within {PAIRING_TTL_SECONDS // 60} minutes:")
        out(f"  /pair {code}")
        return 0
    if command == "unpair":
        if store.unpair(args.user_id):
            out(f"Removed {args.user_id}.")
            return 0
        out(f"{args.user_id} is not paired.")
        return 1
    if identity is None:
        from ..identity import load_or_create_identity

        identity = load_or_create_identity(workspace / "host_device.key")
    tokens = telegram_token_store(workspace, identity)
    if command == "token":
        stream = stdin or sys.stdin
        if stream.isatty():
            token = getpass.getpass("Bot token from @BotFather (hidden): ")
        else:
            token = stream.readline()
        token = (token or "").strip()
        if ":" not in token or any(ch.isspace() or ch == "/" for ch in token):
            out("That does not look like a bot token (it has the form 123456:ABC...).")
            return 2
        tokens.put(token)
        out("Stored. Restart the host to start the gateway (systemctl --user restart agents-manager).")
        return 0
    if command == "off":
        out("Token deleted. Restart the host." if tokens.clear() else "No token was stored.")
        return 0
    # status
    out(f"Token stored: {'yes' if tokens.get() else 'no'}")
    paired = store.paired()
    if not paired:
        out("Paired users: none (make a code with: agents-host telegram pair)")
    for user_id, row in sorted(paired.items()):
        out(f"  {user_id}\t{row.get('name') or ''}")
    return 0
