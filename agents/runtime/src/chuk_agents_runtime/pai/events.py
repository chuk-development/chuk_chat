"""Pydantic AI stream events -> the executor's frames (docs/PYDANTIC_AI_LOOP.md, section 8).

The wire contract does not change. The executor already turns three callbacks
into sealed frames:

- ``on_delta(text)`` -> ``delta{text}``
- ``on_reasoning(text)`` -> ``reasoning{text}``
- ``tool_event_observer(fields)`` -> ``tool{...}`` (one per call, after its result)

With a streaming Pydantic AI model the loop feeds the first two from the model
request stream: a text part start or a text delta is a ``delta``, a thinking
part start or a thinking delta is a ``reasoning``. Tool-call argument deltas
have no frame in the contract (the app draws a tool card once, when the result
is known), so they are only traced.

With a legacy client the client itself fires the callbacks, and the loop maps
nothing (see :func:`~chuk_agents_runtime.pai.model.is_legacy`).
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from pydantic_ai.messages import (
    PartDeltaEvent,
    PartStartEvent,
    TextPart,
    TextPartDelta,
    ThinkingPart,
    ThinkingPartDelta,
    ToolCallPart,
    ToolCallPartDelta,
)

from ..telemetry import get_tracer

Sink = Callable[[str], None]


def _safe(sink: Sink | None, text: str) -> None:
    """A UI sink must never take the run down."""
    if sink is None or not text:
        return
    try:
        sink(text)
    except Exception:  # noqa: BLE001
        pass


@dataclass
class StreamMapper:
    """Maps one model request's stream events to the delta / reasoning sinks,
    and keeps the first-token clocks the trace reports."""

    on_delta: Sink | None = None
    on_reasoning: Sink | None = None
    started: float = field(default_factory=time.monotonic)
    first_event_ms: float | None = None
    first_content_ms: float | None = None
    first_reasoning_ms: float | None = None
    content_chars: int = 0
    reasoning_chars: int = 0
    tool_calls: int = 0

    def _content(self, text: str) -> None:
        if not text:
            return
        if self.first_content_ms is None:
            self.first_content_ms = (time.monotonic() - self.started) * 1000
            self._trace("first_content")
        self.content_chars += len(text)
        _safe(self.on_delta, text)

    def _reasoning(self, text: str | None) -> None:
        if not text:
            return
        if self.first_reasoning_ms is None:
            self.first_reasoning_ms = (time.monotonic() - self.started) * 1000
            self._trace("first_reasoning")
        self.reasoning_chars += len(text)
        _safe(self.on_reasoning, text)

    def _trace(self, phase: str) -> None:
        tracer = get_tracer()
        if tracer.enabled:
            tracer.emit(phase, ms=round((time.monotonic() - self.started) * 1000, 3))

    def feed(self, event: Any) -> None:
        """One event from ``ModelRequestNode.stream``."""
        if self.first_event_ms is None and isinstance(event, (PartStartEvent, PartDeltaEvent)):
            self.first_event_ms = (time.monotonic() - self.started) * 1000
        if isinstance(event, PartStartEvent):
            part = event.part
            if isinstance(part, TextPart):
                self._content(part.content)
            elif isinstance(part, ThinkingPart):
                self._reasoning(part.content)
            elif isinstance(part, ToolCallPart):
                self.tool_calls += 1
        elif isinstance(event, PartDeltaEvent):
            delta = event.delta
            if isinstance(delta, TextPartDelta):
                self._content(delta.content_delta)
            elif isinstance(delta, ThinkingPartDelta):
                self._reasoning(delta.content_delta)
            elif isinstance(delta, ToolCallPartDelta):
                pass  # no frame for argument deltas in the wire contract

    def timing(self) -> dict[str, Any]:
        return {
            "first_frame_ms": _round(self.first_event_ms),
            "first_content_ms": _round(self.first_content_ms),
            "first_reasoning_ms": _round(self.first_reasoning_ms),
            "content_chars": self.content_chars,
            "reasoning_chars": self.reasoning_chars,
        }


def _round(value: float | None) -> float | None:
    return None if value is None else round(value, 3)


__all__ = ["StreamMapper"]
