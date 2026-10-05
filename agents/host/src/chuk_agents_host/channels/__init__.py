"""Messenger channels: talk to one coworker from outside the app.

Opt-in per coworker, off by default. Today there is one channel, Telegram
(long polling, no open port). Telegram is not end-to-end encrypted; the app's
own path stays the end-to-end encrypted one.
"""

from .manager import (
    CAPABILITY,
    FRAMES,
    FRAME_GET,
    FRAME_REPLY,
    FRAME_SET,
    ChannelManager,
    ChannelSettings,
    read_run_files,
)
from .store import FILE_NAME, ChannelStore, channels_at_rest_key
from .telegram import ORIGIN, PROMPT_MARKER, TelegramChannel, TelegramTiming
from .telegram_api import TelegramClient, TelegramError

__all__ = [
    "CAPABILITY",
    "FILE_NAME",
    "FRAMES",
    "FRAME_GET",
    "FRAME_REPLY",
    "FRAME_SET",
    "ORIGIN",
    "PROMPT_MARKER",
    "ChannelManager",
    "ChannelSettings",
    "ChannelStore",
    "TelegramChannel",
    "TelegramClient",
    "TelegramError",
    "TelegramTiming",
    "channels_at_rest_key",
    "read_run_files",
]
