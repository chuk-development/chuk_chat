"""Run tracing on OpenTelemetry — the developer switch that attributes a slow turn.

Why this exists: a four-minute turn used to leave no trace anywhere. The trace
answers one question: **which segment of the turn was slow — us, the
transport, or the provider?** So every phase is recorded with a duration, and
the phases tile the whole path:

    task_received -> memory_recall_* -> round_start -> history_loaded ->
    ladder_pass -> payload_prepared -> first_reasoning -> first_content ->
    usage -> model_call -> tool_start/tool_end* -> ... -> run_finished

``retry`` is recorded whenever a request is sent twice.

**The data is OpenTelemetry.** A traced run is one ``agent_run`` span; every
phase is a short child span of it (name = the phase, attributes = its fields),
ended at once so it is exported live — a run that hangs still shows how far it
got. Pydantic AI's own ``invoke_agent`` / ``chat`` / ``execute_tool`` spans
nest under the run span when this provider is the global one. The local sink is
:class:`JsonlSpanExporter`: one rolling JSON-lines file, one span per line,
which ``chuk_agents_runtime.telemetry_report`` reads back for
``agents-host trace``. An OTLP exporter can sit beside it through the standard
OTel SDK configuration.

Design rules:

- **Off costs nothing.** The default tracer is :data:`NULL_TRACER`, whose
  ``enabled`` is ``False`` and whose ``emit`` returns immediately. Call sites
  read ``tracer.enabled`` before building any string, dict or timestamp that
  only the trace would read.
- **One rolling file, ``run_id`` on every span.** Not one file per run: the
  question "is the provider slow tonight?" is answered by comparing runs, and a
  single file rotates at a fixed size cap, while per-run files grow without
  bound on a host that runs for months. The reader filters by run id.
- **Structure always, content never by default.** Phase names, counts, sizes
  and durations are always safe. Message text, tool arguments and tool results
  are written only when the separate, louder content switch is on AND a
  scrubber is wired; without a scrubber the field is dropped and the line says
  so. An API key, a token or a vault value is never a traced field.
- **The clock is injectable.** ``clock``/``wall`` are constructor parameters so
  a test drives the trace without sleeping; span times follow ``wall``.

The per-run identity (run id, session key, round) rides in a
:class:`contextvars.ContextVar`, not in a parameter threaded through six
layers. A run owns a thread, and a fresh thread starts with a fresh context, so
two concurrent runs never see each other's scope.
"""

from __future__ import annotations

import json
import os
import threading
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from opentelemetry import context as otel_context
from opentelemetry import trace as otel_trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, SpanLimits, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExporter, SpanExportResult

#: Every phase name the runtime emits, in the order a healthy turn produces
#: them. Kept as data so the reader can order a waterfall without guessing and
#: a test can assert the set is covered.
PHASES: tuple[str, ...] = (
    # Before the loop: the relay frame that carries the task. A task that
    # never becomes a run leaves no ``task_received`` at all, and these two
    # phases are what tell "the frame arrived and the host threw it away"
    # apart from "the frame never arrived" (see
    # :mod:`chuk_agents_host.relay_ledger`).
    "relay_frame_in",
    "relay_frame_dropped",
    # The executor's own preparation (bead chuk_chat-4xc5): queue + sandbox
    # lease, the model clients, the MCP connectors, the runtime build.
    "task_accepted",
    "model_ready",
    "mcp_ready",
    "runtime_built",
    "task_received",
    "memory_recall_start",
    "memory_recall_end",
    # The recall's real latency, when it ends (it no longer blocks the run).
    "memory_recall_done",
    "round_start",
    "history_loaded",
    "ladder_pass",
    "payload_prepared",
    "first_reasoning",
    "first_content",
    "usage",
    "retry",
    "model_call",
    "tool_start",
    "tool_end",
    "run_finished",
)

#: Default rolling-file cap. A host that runs for months must not fill the
#: disk, and 16 MiB is ~40k trace lines — many days of real use.
DEFAULT_MAX_BYTES = 16 * 1024 * 1024
#: How many rotated files are kept beside the live one.
DEFAULT_BACKUPS = 3
#: Default file name under ``<trace dir>``.
TRACE_FILENAME = "agent-trace.jsonl"
#: Directory under the workspace where traces land.
TRACE_DIRNAME = "trace"
#: The span that holds one run; every phase span is its child.
RUN_SPAN = "agent_run"
#: Attribute naming the fields that were JSON-encoded because OTel attributes
#: take only primitives and flat lists.
JSON_KEYS_ATTR = "trace.json_keys"


@dataclass(frozen=True)
class TraceScope:
    """Who the next trace spans belong to."""

    run_id: str = ""
    session_key: str = ""
    round: int = 0
    #: The run's ``agent_run`` span, the parent of every phase span.
    span: Any = field(default=None, compare=False)


_SCOPE: ContextVar[TraceScope | None] = ContextVar("cowork_trace_scope", default=None)


@runtime_checkable
class Tracer(Protocol):
    """What the runtime needs from a trace sink."""

    enabled: bool

    def emit(self, phase: str, **fields: Any) -> None: ...

    def text(self, value: str | None) -> str | None: ...


class NullTracer:
    """The off switch. Every call returns before it allocates anything."""

    enabled = False

    def emit(self, phase: str, **fields: Any) -> None:  # noqa: D102
        return None

    def text(self, value: str | None) -> str | None:  # noqa: D102
        return None

    def close(self) -> None:  # noqa: D102
        return None


#: The process-wide default. Replaced by :func:`set_tracer` when the host is
#: started with tracing on.
NULL_TRACER = NullTracer()

_tracer: Tracer = NULL_TRACER


def get_tracer() -> Tracer:
    """The process-wide tracer. Always an object — never ``None`` — so a call
    site is one attribute read plus a branch when tracing is off."""
    return _tracer


def set_tracer(tracer: Tracer | None) -> Tracer:
    """Install (or, with ``None``, remove) the process-wide tracer. Returns the
    previous one, so a test can restore it."""
    global _tracer
    previous = _tracer
    _tracer = tracer if tracer is not None else NULL_TRACER
    return previous


def current_scope() -> TraceScope:
    return _SCOPE.get() or TraceScope()


@contextmanager
def run_scope(run_id: str, session_key: str) -> Iterator[TraceScope]:
    """One run: its ``agent_run`` span, current for everything inside the
    block (Pydantic AI's spans nest under it), and the run id and session key
    every phase carries. Restored on exit, so a nested subagent run cannot leak
    its id into its parent's spans."""
    tracer = _tracer
    span = tracer.start_run(run_id, session_key) if isinstance(tracer, OTelTracer) else None
    scope = TraceScope(run_id=run_id, session_key=session_key, round=0, span=span)
    token = _SCOPE.set(scope)
    attached = otel_context.attach(otel_trace.set_span_in_context(span)) if span is not None else None
    try:
        yield scope
    finally:
        if attached is not None:
            otel_context.detach(attached)
        _SCOPE.reset(token)
        if span is not None:
            span.end()


def set_round(round_no: int) -> None:
    """Stamp the round number onto every following phase of this run."""
    scope = _SCOPE.get()
    _SCOPE.set(replace(scope or TraceScope(), round=int(round_no)))


class JsonlSpanExporter(SpanExporter):
    """One rolling JSON-lines file, one finished span per line.

    ``max_bytes``/``backups`` bound the disk: when the live file reaches the cap
    it is rotated to ``<name>.1`` (and the older ones shift down), and anything
    past ``backups`` is deleted. A write that fails never takes a run down.
    """

    def __init__(self, path: str | os.PathLike, *, max_bytes: int, backups: int) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._max_bytes = max(0, int(max_bytes))
        self._backups = max(0, int(backups))
        self._lock = threading.Lock()

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        for span in spans:
            parent = span.parent.span_id if span.parent is not None else None
            line = {
                "name": span.name,
                "trace_id": f"{span.context.trace_id:032x}",
                "span_id": f"{span.context.span_id:016x}",
                "parent_id": f"{parent:016x}" if parent else None,
                "start": (span.start_time or 0) / 1e9,
                "end": (span.end_time or 0) / 1e9,
                "attributes": dict(span.attributes or {}),
            }
            try:
                blob = json.dumps(line, ensure_ascii=False, default=str)
            except (TypeError, ValueError):
                continue
            with self._lock:
                self._write(blob)
        return SpanExportResult.SUCCESS

    def shutdown(self) -> None:  # noqa: D102
        return None

    def _write(self, blob: str) -> None:
        try:
            self._rotate_if_needed(len(blob) + 1)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(blob + "\n")
        except OSError:
            return

    def _rotate_if_needed(self, incoming: int) -> None:
        if self._max_bytes <= 0:
            return
        try:
            size = self.path.stat().st_size
        except OSError:
            return
        if size + incoming <= self._max_bytes:
            return
        if self._backups == 0:
            self.path.unlink(missing_ok=True)
            return
        oldest = self.path.with_suffix(self.path.suffix + f".{self._backups}")
        oldest.unlink(missing_ok=True)
        for index in range(self._backups - 1, 0, -1):
            src = self.path.with_suffix(self.path.suffix + f".{index}")
            if src.exists():
                src.replace(self.path.with_suffix(self.path.suffix + f".{index + 1}"))
        self.path.replace(self.path.with_suffix(self.path.suffix + ".1"))


class OTelTracer:
    """The switch on: phases become OpenTelemetry spans in the run's trace.

    ``content`` is the second, louder switch. With it off, only structure and
    sizes are recorded. With it on, text still goes through ``scrubber`` first;
    with no scrubber wired the text is dropped, because a field that cannot be
    proven clean is not written.
    """

    enabled = True

    def __init__(
        self,
        path: str | os.PathLike,
        *,
        max_bytes: int = DEFAULT_MAX_BYTES,
        backups: int = DEFAULT_BACKUPS,
        content: bool = False,
        scrubber: Callable[[str], str] | None = None,
        clock: Callable[[], float] = time.monotonic,
        wall: Callable[[], float] = time.time,
        max_text: int = 4000,
    ) -> None:
        self.exporter = JsonlSpanExporter(path, max_bytes=max_bytes, backups=backups)
        self.provider = TracerProvider(
            resource=Resource.create({"service.name": "chuk-agents-runtime"}),
            # A long run is thousands of phases; the SDK default caps would
            # drop them silently.
            span_limits=SpanLimits(max_attributes=512, max_attribute_length=16_384),
        )
        self.provider.add_span_processor(SimpleSpanProcessor(self.exporter))
        self._otel = self.provider.get_tracer("chuk_agents_runtime")
        self._content = bool(content)
        self._scrubber = scrubber
        self._clock = clock
        self._wall = wall
        self._max_text = max(0, int(max_text))
        self._lock = threading.Lock()
        self._origin = clock()
        #: Last timestamp per run, so ``dt_ms`` is "since the previous phase of
        #: THIS run" and two interleaved runs do not corrupt each other's deltas.
        self._last: dict[str, float] = {}

    @property
    def path(self) -> Path:
        return self.exporter.path

    @property
    def content_enabled(self) -> bool:
        return self._content and self._scrubber is not None

    def set_scrubber(self, scrubber: Callable[[str], str] | None) -> None:
        """Wire the secret scrubber after construction. Content tracing stays
        inert until this is called: no scrubber, no text."""
        self._scrubber = scrubber

    def start_run(self, run_id: str, session_key: str) -> Any:
        return self._otel.start_span(
            RUN_SPAN,
            attributes={"run_id": run_id, "session_key": session_key},
            start_time=int(self._wall() * 1e9),
        )

    # -- sink ------------------------------------------------------------

    def emit(self, phase: str, **fields: Any) -> None:
        """One phase: a child span of the run, ended at once (exported live).
        A phase with a duration (``ms``) spans that duration."""
        scope = current_scope()
        now = self._clock()
        with self._lock:
            previous = self._last.get(scope.run_id)
            self._last[scope.run_id] = now
            if phase == "run_finished":
                self._last.pop(scope.run_id, None)
        attributes: dict[str, Any] = {
            "t": round(now - self._origin, 6),
            "run_id": scope.run_id,
            "session_key": scope.session_key,
            "round": scope.round,
            "dt_ms": 0.0 if previous is None else round((now - previous) * 1000, 3),
        }
        encoded: list[str] = []
        for key, value in fields.items():
            if value is None:
                continue
            value = _jsonable(value)
            if isinstance(value, (dict, list)):
                value = json.dumps(value, ensure_ascii=False, default=str)
                encoded.append(key)
            attributes[key] = value
        if encoded:
            attributes[JSON_KEYS_ATTR] = encoded
        end = int(self._wall() * 1e9)
        duration = fields.get("ms")
        start = end - int(float(duration) * 1e6) if isinstance(duration, (int, float)) and duration > 0 else end
        context = otel_trace.set_span_in_context(scope.span) if scope.span is not None else None
        try:
            span = self._otel.start_span(phase, context=context, attributes=attributes, start_time=start)
            span.end(end_time=end)
        except Exception:  # noqa: BLE001 — a trace must never take a run down
            return

    def text(self, value: str | None) -> str | None:
        """The ONE way traced message text is produced. ``None`` whenever the
        content switch is off or no scrubber is wired — the caller then simply
        omits the field."""
        if value is None or not self._content:
            return None
        if self._scrubber is None:
            return None
        try:
            cleaned = self._scrubber(value)
        except Exception:  # noqa: BLE001 — a broken scrubber writes nothing
            return None
        if not isinstance(cleaned, str):
            return None
        if self._max_text and len(cleaned) > self._max_text:
            return cleaned[: self._max_text] + f"…[+{len(cleaned) - self._max_text}]"
        return cleaned

    def close(self) -> None:
        self.provider.shutdown()


#: The old name: tests and callers built a ``JsonlTracer(path)``; the file is
#: now the local exporter of the OTel tracer.
JsonlTracer = OTelTracer


def _jsonable(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    return str(value)


# -- configuration ---------------------------------------------------------


def trace_dir_for(workspace: str | os.PathLike | None) -> Path:
    """Where a workspace's traces live: ``<workspace>/trace``. Falls back to the
    current directory when no workspace is known."""
    base = Path(workspace).expanduser() if workspace else Path.cwd()
    return base / TRACE_DIRNAME


def _env_flag(name: str) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return False
    return raw.strip().lower() not in ("", "0", "false", "no", "off")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class TraceSettings:
    """The resolved switch: what the CLI flags and the environment agreed on."""

    enabled: bool = False
    content: bool = False
    directory: str | None = None
    max_bytes: int = DEFAULT_MAX_BYTES
    backups: int = DEFAULT_BACKUPS

    @classmethod
    def from_env(cls, **overrides: Any) -> "TraceSettings":
        """Environment first, explicit arguments win. A CLI flag passes
        ``enabled=True``; an unset flag passes nothing and the environment
        decides, so ``AGENTS_TRACE=1`` is enough for a systemd unit."""
        settings = cls(
            enabled=_env_flag("AGENTS_TRACE"),
            content=_env_flag("AGENTS_TRACE_CONTENT"),
            directory=os.environ.get("AGENTS_TRACE_DIR") or None,
            max_bytes=_env_int("AGENTS_TRACE_MAX_BYTES", DEFAULT_MAX_BYTES),
            backups=_env_int("AGENTS_TRACE_BACKUPS", DEFAULT_BACKUPS),
        )
        clean = {k: v for k, v in overrides.items() if v is not None and v is not False}
        return replace(settings, **clean) if clean else settings


def configure_tracing(
    settings: TraceSettings,
    *,
    workspace: str | os.PathLike | None = None,
    scrubber: Callable[[str], str] | None = None,
) -> Tracer:
    """Install the process-wide tracer from ``settings`` and return it.

    Disabled settings install :data:`NULL_TRACER` — there is no half-on state
    and no file is created.
    """
    if not settings.enabled:
        set_tracer(NULL_TRACER)
        return NULL_TRACER
    directory = Path(settings.directory).expanduser() if settings.directory else trace_dir_for(workspace)
    tracer = OTelTracer(
        directory / TRACE_FILENAME,
        max_bytes=settings.max_bytes,
        backups=settings.backups,
        content=settings.content,
        scrubber=scrubber,
    )
    # The first provider wins process-wide: with ours global, Pydantic AI's
    # spans (the Instrumentation capability) land in the same trace, under
    # the run span. An operator's own OTel setup is left alone.
    if isinstance(otel_trace.get_tracer_provider(), otel_trace.ProxyTracerProvider):
        otel_trace.set_tracer_provider(tracer.provider)
    set_tracer(tracer)
    return tracer
