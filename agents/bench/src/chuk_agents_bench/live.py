"""Opt-in live run: real prompts to a scratch session, timed end to end.

This mode spends credits, so the CLI runs it only with ``--yes-spend-credits``.
It never talks to the owner's coworkers:

- The session key is always generated here (``bench:<random>``). A key that
  does not start with ``bench:`` is refused.
- The state database is a fresh scratch file under ``_scratch/bench``. With
  ``seed_session`` the stored rows of a real session are COPIED into the
  scratch session first (from a database copy), so a long-history turn can be
  timed without the real session ever seeing the prompt.
- The runtime is built directly (``build_runtime``) with a local environment,
  no memory, no MCP, no browser and no workspace git. The host, the relay and
  the running ``agents-manager`` service are not touched.

Credentials come from the environment only (``SUPABASE_URL``,
``SUPABASE_ANON_KEY``, ``AGENTS_LIVE_ACCESS_TOKEN``,
``AGENTS_LIVE_REFRESH_TOKEN``). No ``.env`` file and no app session file is
read. Use a test account: refreshing a token rotates it, and a rotated token
signs out every other client that holds it.
"""

from __future__ import annotations

import json
import os
import secrets as _secrets
import sqlite3
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

from .runs import Stat
from .snapshot import default_scratch_dir, is_live_path

SESSION_PREFIX = "bench:"

ENV_VARS = (
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "AGENTS_LIVE_ACCESS_TOKEN",
    "AGENTS_LIVE_REFRESH_TOKEN",
)


class CaptureTracer:
    """A runtime ``Tracer`` that keeps the phase lines in memory."""

    enabled = True

    def __init__(self) -> None:
        self.lines: list[dict[str, Any]] = []

    def emit(self, phase: str, **fields: Any) -> None:
        self.lines.append({"phase": phase, "t": time.perf_counter(), **fields})

    def text(self, value: str | None) -> str | None:  # content stays out
        return None

    def take(self) -> list[dict[str, Any]]:
        lines, self.lines = self.lines, []
        return lines


@dataclass
class LiveTurn:
    index: int
    prompt_chars: int
    wall_ms: float
    reason: str
    iterations: int
    tokens_spent: int
    timings: dict[str, int]
    first_token_ms: float | None = None
    first_frame_ms: float | None = None
    ttft_ms: float | None = None
    ladder_ms: list[float] = field(default_factory=list)
    model_calls_traced: int = 0


@dataclass
class LiveResult:
    db: str
    session_key: str
    seeded_rows: int
    model: str
    turns: list[LiveTurn] = field(default_factory=list)

    def summary(self) -> dict[str, Any]:
        def stat(values: list[float | None]) -> dict[str, Any]:
            return asdict(Stat.of([v for v in values if v is not None]))

        return {
            "turns": len(self.turns),
            "wall_ms": stat([t.wall_ms for t in self.turns]),
            "ttft_ms": stat([t.ttft_ms for t in self.turns]),
            "prepare_ms": stat([t.timings.get("prepare_ms") for t in self.turns]),
            "model_wait_ms": stat([t.timings.get("model_wait_ms") for t in self.turns]),
        }

    def as_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["summary"] = self.summary()
        return data


def new_session_key() -> str:
    return SESSION_PREFIX + _secrets.token_hex(6)


def check_session_key(key: str) -> str:
    if not key.startswith(SESSION_PREFIX):
        raise ValueError(f"live mode only runs on {SESSION_PREFIX}* sessions, not {key!r}")
    return key


def seed_from(source_db: str | Path, source_key: str, store: Any, session_id: int) -> int:
    """Copy the model-visible rows (``role <> 'event'``) of ``source_key``
    from a database COPY into the scratch session. Returns the row count."""
    if is_live_path(source_db):
        raise ValueError("seed from a copy (agents-bench snapshot), not from the live file")
    conn = sqlite3.connect(f"file:{Path(source_db)}?mode=ro", uri=True, timeout=5.0)
    try:
        route = conn.execute(
            "SELECT session_id FROM session_routes WHERE session_key=?", (source_key,)
        ).fetchone()
        if route is None:
            raise LookupError(f"no session {source_key!r} in {source_db}")
        rows = conn.execute(
            "SELECT role, content FROM messages WHERE session_id=? AND role<>'event' ORDER BY id",
            (int(route[0]),),
        ).fetchall()
    finally:
        conn.close()
    for role, content in rows:
        store.append_message(session_id, role, json.loads(content))
    return len(rows)


def session_from_env() -> Any:
    """A ``SupabaseSession`` from the environment only."""
    missing = [name for name in ENV_VARS if not os.environ.get(name)]
    if missing:
        raise RuntimeError("live mode needs these environment variables: " + ", ".join(missing))
    from chuk_agents_runtime import SupabaseSession

    return SupabaseSession(
        access_token=os.environ["AGENTS_LIVE_ACCESS_TOKEN"],
        refresh_token=os.environ["AGENTS_LIVE_REFRESH_TOKEN"],
        supabase_url=os.environ["SUPABASE_URL"],
        anon_key=os.environ["SUPABASE_ANON_KEY"],
    )


def backend_client(model_id: str | None) -> tuple[Any, str]:
    """The account's streamed model client and its ``provider | model`` label."""
    from chuk_agents_runtime import BackendModelClient, fetch_models_info, resolve_model

    session = session_from_env()
    resolved = resolve_model(fetch_models_info(session), preferred_model_id=model_id)
    client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=1024,
    )
    return client, f"{resolved.provider_slug} | {resolved.model_id}"


def run_live(
    client: Any,
    *,
    prompts: list[str],
    label: str = "",
    db_path: str | Path | None = None,
    seed_db: str | Path | None = None,
    seed_session: str | None = None,
    session_key: str | None = None,
    max_iterations: int = 4,
    with_aux: bool = True,
    on_turn: Callable[[LiveTurn], None] | None = None,
) -> LiveResult:
    """Send ``prompts`` one after the other to one scratch session.

    ``client`` is any runtime ``ModelClient`` (the backend client in the CLI,
    a scripted mock in the tests). The loop is the real ``build_runtime``
    loop, so prepare, ladder and model wait are measured the way a live turn
    measures them.
    """
    from chuk_agents_runtime import LocalEnvironment, build_runtime
    from chuk_agents_runtime.telemetry import set_tracer

    key = check_session_key(session_key or new_session_key())
    scratch = default_scratch_dir()
    db = Path(db_path) if db_path else scratch / "live.db"
    if is_live_path(db):
        raise ValueError("live mode writes a scratch database, never the live one")
    db.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(db) + suffix)
        if candidate.exists():
            candidate.unlink()
    workspace = db.parent / "live-workspace"
    workspace.mkdir(parents=True, exist_ok=True)

    loop = build_runtime(
        client,
        db_path=str(db),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        max_iterations=max_iterations,
        enable_memory=False,
        enable_mcp=False,
        enable_browser=False,
        enable_terminal=False,
        version_workspace=False,
        aux_model=client if with_aux else None,
    )
    seeded = 0
    if seed_session:
        if seed_db is None:
            raise ValueError("seed_session needs seed_db (a database copy)")
        session_id = loop.store.route(key)
        seeded = seed_from(seed_db, seed_session, loop.store, session_id)

    result = LiveResult(db=str(db), session_key=key, seeded_rows=seeded, model=label)
    tracer = CaptureTracer()
    previous = set_tracer(tracer)
    try:
        for index, prompt in enumerate(prompts, start=1):
            tracer.take()
            started = time.perf_counter()
            outcome = loop.run(key, prompt)
            wall_ms = (time.perf_counter() - started) * 1000
            lines = tracer.take()
            calls = [line for line in lines if line.get("phase") == "model_call"]
            first = calls[0] if calls else {}
            ladders = [float(line.get("ms") or 0) for line in lines if line.get("phase") == "ladder_pass"]
            ttft = None
            received = next((line for line in lines if line.get("phase") == "task_received"), None)
            if received is not None and first.get("first_token_ms") is not None:
                # task received -> first request sent is everything up to the
                # model call (recall + prepare); the call's own first_token_ms
                # is measured from the request.
                call_line_t = first["t"]
                total_ms = float(first.get("total_ms") or 0.0)
                request_t = call_line_t - total_ms / 1000
                ttft = round((request_t - received["t"]) * 1000 + float(first["first_token_ms"]), 1)
            turn = LiveTurn(
                index=index,
                prompt_chars=len(prompt),
                wall_ms=round(wall_ms, 1),
                reason=outcome.reason.value,
                iterations=outcome.iterations,
                tokens_spent=outcome.tokens_spent,
                timings=outcome.timings.as_row(),
                first_token_ms=first.get("first_token_ms"),
                first_frame_ms=first.get("first_frame_ms"),
                ttft_ms=ttft,
                ladder_ms=ladders,
                model_calls_traced=len(calls),
            )
            result.turns.append(turn)
            if on_turn is not None:
                on_turn(turn)
    finally:
        set_tracer(previous)
        mcp = getattr(loop, "mcp", None)
        if mcp is not None and hasattr(mcp, "close"):
            try:
                mcp.close()
            except Exception:  # noqa: BLE001
                pass
        close = getattr(client, "close", None)
        if callable(close):
            close()
        store_close = getattr(loop.store, "close", None)
        if callable(store_close):
            store_close()
    return result


def render_text(result: LiveResult) -> str:
    def fmt(value: float | None) -> str:
        return "-" if value is None else f"{value:.0f}"

    out = [
        f"live  session {result.session_key}  model {result.model or '-'}  "
        f"seeded rows {result.seeded_rows}  db {result.db}",
        f"  {'#':>2} {'wall':>8} {'ttft':>8} {'prepare':>8} {'model':>8} {'tool':>7}"
        f" {'calls':>5} {'tokens':>7} reason",
    ]
    for t in result.turns:
        out.append(
            f"  {t.index:>2} {fmt(t.wall_ms):>8} {fmt(t.ttft_ms):>8}"
            f" {fmt(t.timings.get('prepare_ms')):>8} {fmt(t.timings.get('model_wait_ms')):>8}"
            f" {fmt(t.timings.get('tool_ms')):>7} {t.timings.get('model_calls', 0):>5}"
            f" {t.tokens_spent:>7} {t.reason}"
        )
    s = result.summary()
    out.append(
        f"  p50 wall {fmt(s['wall_ms']['p50'])}  ttft {fmt(s['ttft_ms']['p50'])}  "
        f"prepare {fmt(s['prepare_ms']['p50'])}  model {fmt(s['model_wait_ms']['p50'])} (ms)"
    )
    return "\n".join(out)
