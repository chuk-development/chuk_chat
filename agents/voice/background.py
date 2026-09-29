"""Background work and proactive speech.

A normal tool call holds the conversation hostage: the user waits, in silence,
until it returns. That is fine for a two-second weather lookup and useless for
"research this for me" or "remind me in ten minutes".

This module gives the agent a second mode. It can hand work off, keep talking,
and come back on its own when the work is done — the way a person would.

Two pieces:

  ``BackgroundRunner`` — runs a coroutine detached from the turn loop. When it
  finishes, the result is written into the chat context and the agent is asked
  to voice it.

  ``_speak_when_idle`` — the manners layer. Proactive speech never barges in:
  it waits until the user has stopped talking and the agent has stopped
  speaking, then delivers. If the session ends first, it is dropped silently.
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from collections.abc import Awaitable
from dataclasses import dataclass, field
from typing import Any

from livekit.agents import AgentSession

logger = logging.getLogger("voice-agent.background")

#: How long to wait between idleness checks before speaking proactively.
_IDLE_POLL = 0.4

#: Give up trying to find a quiet moment after this long and speak anyway.
_IDLE_TIMEOUT = 120.0


@dataclass
class BackgroundJob:
    id: str
    label: str
    started_at: float = field(default_factory=time.time)
    done: bool = False
    result: str | None = None
    error: str | None = None

    @property
    def elapsed(self) -> float:
        return time.time() - self.started_at


class BackgroundRunner:
    """Owns detached jobs and reports their results back into the conversation."""

    def __init__(self, session: AgentSession) -> None:
        self._session = session
        self._jobs: dict[str, BackgroundJob] = {}
        self._tasks: set[asyncio.Task[None]] = set()
        self._closed = False

    @property
    def jobs(self) -> list[BackgroundJob]:
        return list(self._jobs.values())

    @property
    def pending(self) -> list[BackgroundJob]:
        return [j for j in self._jobs.values() if not j.done]

    def start(self, label: str, work: Awaitable[str]) -> BackgroundJob:
        """Kick off ``work`` and return immediately.

        The caller (a tool) returns a short "I'm on it" line straight away, so
        the agent keeps the floor instead of going quiet for a minute.
        """
        job = BackgroundJob(id=str(uuid.uuid4())[:8], label=label)
        self._jobs[job.id] = job

        task = asyncio.create_task(self._run(job, work), name=f"bg-{job.id}")
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        logger.info("background job %s started: %s", job.id, label)
        return job

    async def _run(self, job: BackgroundJob, work: Awaitable[str]) -> None:
        try:
            job.result = await work
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            job.error = str(e)
            logger.warning("background job %s failed: %s", job.id, e)
        finally:
            job.done = True

        if self._closed:
            return

        if job.error:
            instructions = (
                f"The background task '{job.label}' failed after "
                f"{job.elapsed:.0f} seconds: {job.error}. Tell the user briefly "
                "that it didn't work out and offer to try again."
            )
        else:
            instructions = (
                f"The background task '{job.label}' you started "
                f"{job.elapsed:.0f} seconds ago just finished. Here is the "
                f"result:\n\n{job.result}\n\n"
                "Bring it up now, unprompted. Open by referring back to what "
                "the user asked for, then give the answer in two or three "
                "spoken sentences. Do not read it out verbatim and do not "
                "mention that it ran in the background."
            )

        await self.speak_when_idle(instructions)

    def speak_soon(self, instructions: str) -> None:
        """Schedule :meth:`speak_when_idle` and return at once.

        For callers that must not block, e.g. an RPC handler that has to answer
        the app now while the announcement waits for a quiet moment.
        """
        if self._closed:
            return
        task = asyncio.create_task(self.speak_when_idle(instructions), name="speak-soon")
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def speak_when_idle(self, instructions: str) -> None:
        """Voice something on the agent's own initiative, politely.

        Waits for a genuine gap in the conversation. Interrupting the user to
        announce a finished task is exactly the robot behaviour we're avoiding.
        """
        deadline = time.time() + _IDLE_TIMEOUT
        while not self._closed and time.time() < deadline:
            if self._session.user_state == "listening" and self._session.agent_state == "listening":
                break
            await asyncio.sleep(_IDLE_POLL)

        if self._closed:
            return

        try:
            self._session.generate_reply(instructions=instructions)
        except Exception as e:  # noqa: BLE001 — session may have closed under us
            logger.debug("proactive reply dropped: %s", e)

    async def aclose(self) -> None:
        self._closed = True
        for task in list(self._tasks):
            task.cancel()
        for task in list(self._tasks):
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
