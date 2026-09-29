"""Persistent conversation memory, stored on the agent host.

The app always reconnects to the same logical conversation, so the assistant
picks up where it left off — across app restarts, redeploys and days. Nothing
lives in the client: the phone sends a user id, everything else is here.

Two layers:

  **Transcript** — the rolling ``ChatContext``. Recent turns are kept verbatim;
  once the log outgrows ``max_items`` the overflow is folded into a running
  summary by the LLM, so context length stays bounded while old facts survive.

  **Facts** — things the user explicitly asked to be remembered (the ``remember``
  tool). These are never summarised away and are injected into every session.

Storage is one JSON file per user under ``MEMORY_DIR`` (default ``./.memory``).
That is deliberately boring: a vector DB buys nothing at one user's scale, and
the whole store fits in a prompt anyway.

.. warning::
   The file only outlives a restart if ``MEMORY_DIR`` points at persistent
   storage. Self-hosted Docker: mount a volume (the Dockerfile declares
   ``/data``). **LiveKit Cloud agent deployments have ephemeral filesystems**,
   so on Cloud the history is wiped on every redeploy. Making it durable there
   means swapping the two I/O methods below — :meth:`ConversationMemory.load`
   and :meth:`ConversationMemory.save` — for a networked store (S3/R2, Turso,
   Postgres). Nothing else in the module needs to change; that is why all disk
   access is confined to those two methods.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any

from livekit.agents import llm

logger = logging.getLogger("voice-agent.memory")

MEMORY_DIR = Path(os.environ.get("MEMORY_DIR", ".memory"))

#: Turns kept verbatim in the live context. Older ones get summarised.
DEFAULT_MAX_ITEMS = int(os.environ.get("MEMORY_MAX_ITEMS", "40"))

#: Fold at least this many items per pass, so we don't pay for an LLM call
#: every single time the log creeps one message over the limit.
_SUMMARY_BATCH = 20

#: Never summarise away the tail — the last few turns must stay verbatim or the
#: agent loses the thread of what was just said.
_MIN_VERBATIM = 8

_SCHEMA_VERSION = 1


def _safe_id(user_id: str) -> str:
    """Keep the id usable as a filename without inventing a hashing scheme."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", user_id).strip("._-")
    return cleaned[:120] or "default"


class ConversationMemory:
    """Load/save one user's ongoing conversation."""

    def __init__(self, user_id: str, *, max_items: int = DEFAULT_MAX_ITEMS) -> None:
        self.user_id = _safe_id(user_id)
        self.max_items = max_items
        self.summary: str = ""
        self.facts: list[str] = []
        self.chat_ctx: llm.ChatContext = llm.ChatContext.empty()
        self.updated_at: float = 0.0
        self._lock = asyncio.Lock()

    @property
    def path(self) -> Path:
        return MEMORY_DIR / f"{self.user_id}.json"

    # -- persistence ---------------------------------------------------------

    def load(self) -> None:
        """Read the stored conversation. A missing or corrupt file starts fresh."""
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (OSError, json.JSONDecodeError) as e:
            logger.warning("memory for %s unreadable, starting fresh: %s", self.user_id, e)
            return

        if raw.get("version") != _SCHEMA_VERSION:
            logger.info("memory schema changed, discarding old store for %s", self.user_id)
            return

        self.summary = raw.get("summary") or ""
        self.facts = [f for f in (raw.get("facts") or []) if isinstance(f, str)]
        self.updated_at = float(raw.get("updated_at") or 0)

        try:
            self.chat_ctx = llm.ChatContext.from_dict(raw["chat_ctx"])
        except (KeyError, TypeError, ValueError) as e:
            logger.warning("chat context for %s unreadable: %s", self.user_id, e)
            self.chat_ctx = llm.ChatContext.empty()

        logger.info(
            "memory loaded for %s: %d items, %d facts, summary=%s",
            self.user_id,
            len(self.chat_ctx.items),
            len(self.facts),
            bool(self.summary),
        )

    def save(self) -> None:
        """Write atomically — a crash mid-write must not destroy the history."""
        MEMORY_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": _SCHEMA_VERSION,
            "user_id": self.user_id,
            "updated_at": time.time(),
            "summary": self.summary,
            "facts": self.facts,
            # Images are per-turn camera frames; persisting them would balloon
            # the file and they mean nothing an hour later.
            "chat_ctx": self.chat_ctx.to_dict(exclude_image=True, exclude_audio=True),
        }
        tmp = self.path.with_suffix(".json.tmp")
        try:
            tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)
        except OSError as e:
            logger.error("could not persist memory for %s: %s", self.user_id, e)

    # -- facts ---------------------------------------------------------------

    def add_fact(self, fact: str) -> None:
        fact = fact.strip()
        if fact and fact not in self.facts:
            self.facts.append(fact)

    def forget_fact(self, needle: str) -> bool:
        needle = needle.strip().lower()
        for i, fact in enumerate(self.facts):
            if needle in fact.lower():
                del self.facts[i]
                return True
        return False

    # -- context assembly ----------------------------------------------------

    def preamble(self) -> str:
        """The remembered-state block prepended to the system instructions."""
        blocks: list[str] = []
        if self.facts:
            blocks.append(
                "Things the user told you to remember:\n"
                + "\n".join(f"- {f}" for f in self.facts)
            )
        if self.summary:
            blocks.append(f"Summary of your earlier conversations:\n{self.summary}")
        if not blocks:
            return ""
        return (
            "\n\n"
            + "\n\n".join(blocks)
            + "\n\nTreat all of that as already known. Don't greet the user as a "
            "stranger and don't re-ask what you already know."
        )

    async def compact(self, model: llm.LLM) -> None:
        """Fold the oldest turns into ``summary`` once the log gets too long.

        Runs after a session ends, never during one, so it can't add latency to
        a live turn.
        """
        async with self._lock:
            items = list(self.chat_ctx.items)
            overflow = len(items) - self.max_items
            if overflow <= 0:
                return

            # Take a decent chunk to make the LLM call worth it, but never eat
            # into the last _MIN_VERBATIM turns.
            batch_size = min(max(overflow, _SUMMARY_BATCH), max(0, len(items) - _MIN_VERBATIM))
            if batch_size <= 0:
                return
            batch = items[:batch_size]
            transcript = "\n".join(
                f"{getattr(it, 'role', '?')}: {getattr(it, 'text_content', '') or ''}"
                for it in batch
                if getattr(it, "text_content", None)
            )
            if not transcript.strip():
                self.chat_ctx = llm.ChatContext(items[len(batch) :])
                return

            prompt = llm.ChatContext.empty()
            prompt.add_message(
                role="system",
                content=(
                    "Condense this conversation excerpt into durable notes for an "
                    "assistant's long-term memory. Keep names, preferences, "
                    "decisions, open threads and anything the user would expect "
                    "you to still know. Drop small talk and anything already "
                    "resolved. Write compact prose, no markdown, no bullet "
                    "points, at most 200 words. Answer in the language of the "
                    "conversation."
                ),
            )
            prompt.add_message(
                role="user",
                content=(
                    (f"Previous notes:\n{self.summary}\n\n" if self.summary else "")
                    + f"New excerpt:\n{transcript}"
                ),
            )

            try:
                chunks: list[str] = []
                async with model.chat(chat_ctx=prompt) as stream:
                    async for chunk in stream:
                        if chunk.delta and chunk.delta.content:
                            chunks.append(chunk.delta.content)
                new_summary = "".join(chunks).strip()
            except Exception as e:  # noqa: BLE001 — never lose history over this
                logger.warning("summarisation failed, keeping raw history: %s", e)
                return

            if new_summary:
                self.summary = new_summary
                self.chat_ctx = llm.ChatContext(items[len(batch) :])
                logger.info(
                    "compacted memory for %s: %d items folded into summary",
                    self.user_id,
                    len(batch),
                )

    def sync_from(self, chat_ctx: llm.ChatContext) -> None:
        """Replace the stored transcript with the session's live context."""
        self.chat_ctx = chat_ctx.copy()


def load_for(user_id: str, **kwargs: Any) -> ConversationMemory:
    memory = ConversationMemory(user_id, **kwargs)
    memory.load()
    return memory
