"""Continuous video understanding with a bounded context cost.

Per-turn frame injection (see ``VisionAgent``) answers "what am I looking at"
but only at the moment the user asks. It has no memory: the agent can't notice
that you picked something up, or that someone walked in, because it never saw
the frames in between.

This narrator watches the stream continuously. Every ``interval`` seconds it
sends one frame to a vision model together with the description it produced
last time, and asks only for **what changed**. Two things fall out of that:

  * **Temporal awareness** — "you just put the mug down" is answerable, because
    the change log holds it.
  * **Constant context cost** — the narration occupies exactly one slot in the
    chat context, rewritten in place, holding the current scene plus the last
    few changes. Watching for an hour costs the same as watching for a minute,
    and no image is ever stored in the history.

Frames the model would describe identically are dropped before they cost a
token: the model answers with a sentinel and we skip the update entirely.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import time
from collections import deque

from livekit import rtc
from livekit.agents import llm

logger = logging.getLogger("voice-agent.vision")

#: Seconds between sampled frames. Lower = more responsive, more tokens.
DEFAULT_INTERVAL = float(os.environ.get("VISION_INTERVAL", "2.5"))

#: Recent changes kept alongside the current scene description.
_CHANGE_LOG_SIZE = 6

#: Chat-context item id for the narration slot. Stable so we can rewrite it.
_NARRATION_ID = "live-vision-narration"

#: Exact reply the model must send when the scene is unchanged.
_NO_CHANGE = "NOCHANGE"

_SYSTEM_PROMPT = f"""\
You watch a live video feed for an assistant and keep a running description of it.

You get the scene as you last described it, plus the current frame.

Reply with ONE of:
- The single word {_NO_CHANGE}, if nothing meaningful is different. Ignore \
noise: lighting flicker, compression artifacts, tiny head movements, a hand \
shifting slightly. Prefer {_NO_CHANGE} when in doubt.
- Otherwise two lines, nothing else:
SCENE: <one sentence describing the whole frame as it is now>
CHANGE: <one short clause naming only what is different from before>

Be concrete: name objects, people, text you can read, what someone is doing. \
No speculation, no markdown, no preamble.
"""


class VideoNarrator:
    """Samples a video track and keeps a compressed description in the context."""

    def __init__(
        self,
        *,
        vision_llm: llm.LLM,
        chat_ctx: llm.ChatContext,
        interval: float = DEFAULT_INTERVAL,
    ) -> None:
        self._llm = vision_llm
        self._chat_ctx = chat_ctx
        self._interval = interval

        self._scene: str = ""
        self._changes: deque[tuple[float, str]] = deque(maxlen=_CHANGE_LOG_SIZE)
        self._started_at: float = 0.0

        self._latest: rtc.VideoFrame | None = None
        self._reader: asyncio.Task[None] | None = None
        self._loop: asyncio.Task[None] | None = None

    # -- lifecycle -----------------------------------------------------------

    def attach(self, track: rtc.Track) -> None:
        """Start watching ``track``. Replaces any track already being watched."""
        self.detach()
        self._started_at = time.time()
        self._reader = asyncio.create_task(self._read_frames(track), name="vision-read")
        self._loop = asyncio.create_task(self._narrate_loop(), name="vision-narrate")
        logger.info("video narration started (interval=%.1fs)", self._interval)

    def detach(self) -> None:
        """Stop watching and drop the narration from the context."""
        for task in (self._reader, self._loop):
            if task is not None and not task.done():
                task.cancel()
        self._reader = self._loop = None
        self._latest = None

        if self._scene or self._changes:
            self._scene = ""
            self._changes.clear()
            self._remove_narration()
            logger.info("video narration stopped")

    async def aclose(self) -> None:
        tasks = [t for t in (self._reader, self._loop) if t is not None]
        self.detach()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task

    # -- internals -----------------------------------------------------------

    async def _read_frames(self, track: rtc.Track) -> None:
        stream = rtc.VideoStream(track)
        try:
            async for event in stream:
                self._latest = event.frame
        finally:
            await stream.aclose()

    async def _narrate_loop(self) -> None:
        while True:
            await asyncio.sleep(self._interval)
            frame = self._latest
            if frame is None:
                continue
            try:
                await self._describe(frame)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 — narration is best-effort
                logger.debug("narration step failed: %s", e)

    async def _describe(self, frame: rtc.VideoFrame) -> None:
        prompt = llm.ChatContext.empty()
        prompt.add_message(role="system", content=_SYSTEM_PROMPT)

        previous = (
            f"Scene as you last described it: {self._scene}"
            if self._scene
            else "This is the first frame; there is no previous description."
        )
        prompt.add_message(
            role="user",
            content=[
                previous,
                # Downscaled hard: the model only needs the gist, and a smaller
                # image is both cheaper and faster to encode at this cadence.
                llm.ImageContent(image=frame, inference_width=512, inference_height=512),
            ],
        )

        chunks: list[str] = []
        async with self._llm.chat(chat_ctx=prompt) as stream:
            async for chunk in stream:
                if chunk.delta and chunk.delta.content:
                    chunks.append(chunk.delta.content)

        reply = "".join(chunks).strip()
        if not reply or reply.upper().startswith(_NO_CHANGE):
            return

        scene, change = self._parse(reply)
        if not scene:
            return

        self._scene = scene
        if change:
            self._changes.append((time.time(), change))
        self._write_narration()

    @staticmethod
    def _parse(reply: str) -> tuple[str, str]:
        scene = change = ""
        for line in reply.splitlines():
            line = line.strip()
            if line.upper().startswith("SCENE:"):
                scene = line.split(":", 1)[1].strip()
            elif line.upper().startswith("CHANGE:"):
                change = line.split(":", 1)[1].strip()
        # Tolerate a model that ignored the format and just wrote a sentence.
        if not scene and reply and ":" not in reply:
            scene = reply.strip()
        return scene, change

    # -- context slot --------------------------------------------------------

    def _render(self) -> str:
        now = time.time()
        lines = [f"Live camera feed — what you can see right now: {self._scene}"]
        if self._changes:
            lines.append("Recent changes, newest last:")
            lines += [f"- {int(now - ts)}s ago: {text}" for ts, text in self._changes]
        lines.append(
            "This is your own observation of the feed, not something the user said. "
            "Use it when relevant; do not narrate it unprompted."
        )
        return "\n".join(lines)

    def _write_narration(self) -> None:
        """Rewrite the single narration slot — never append a second one.

        This in-place rewrite is what keeps the cost flat: the context always
        holds exactly one narration message, however long the feed runs.
        """
        text = self._render()
        existing = self._chat_ctx.get_by_id(_NARRATION_ID)

        if existing is not None and isinstance(getattr(existing, "content", None), list):
            existing.content[:] = [text]
            return

        self._remove_narration()
        message = llm.ChatMessage(id=_NARRATION_ID, role="system", content=[text])
        self._chat_ctx.items.append(message)

    def _remove_narration(self) -> None:
        items = self._chat_ctx.items
        for i in range(len(items) - 1, -1, -1):
            if getattr(items[i], "id", None) == _NARRATION_ID:
                del items[i]
