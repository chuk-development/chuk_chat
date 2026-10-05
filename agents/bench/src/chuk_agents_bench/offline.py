"""Replay the prepare pipeline of one session, with no model call.

In a live turn the loop rebuilds the outbound payload before every model
request (``AgentLoop._outbound_messages``):

1. ``history_load`` - every stored row of the session (``get_conversation``).
2. ``prompt_upgrade`` - the persisted system prompt is brought up to date
   (``SkillLibrary.upgrade_catalog(upgrade_research_instructions(...))``).
3. ``ladder_prepare`` - the context ladder scrubs old reasoning and compresses
   under pressure. Tier 2/3 asks the aux model for a summary of the middle.

``prepare_ms`` on the ``runs`` row is the sum of these three. This module runs
the same three steps against a COPY of the state database and times each one.
The aux model is replaced by a stub that answers at once (or after a fixed
delay) and counts its calls, so the numbers are the runtime's own CPU and I/O
cost, and the summarizer count says how many aux model calls a live turn would
add on top.

The runtime is imported from this checkout (the editable install), so a fix
in ``agents/runtime`` shows up in the next run. ``runtime_src`` imports it from
another tree instead, for example the tree the host runs, to get a before/after
pair from one database copy.
"""

from __future__ import annotations

import cProfile
import inspect
import io
import json
import os
import pstats
import sqlite3
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

from .runs import percentile
from .snapshot import copy_file, default_scratch_dir

#: The steps that make up ``prepare_ms`` in a live turn.
PREPARE_STEPS = ("history_load", "prompt_upgrade", "ladder_prepare")

#: Every timed step, in display order. ``scrub_history`` runs inside
#: ``ladder_prepare`` too; it is timed alone for information only.
ALL_STEPS = (
    "open_store",
    "skills_load",
    "history_load",
    "prompt_upgrade",
    "scrub_history",
    "ladder_prepare",
    "estimate_tokens",
    "convert_pai",
)


class StubSummarizer:
    """Stands in for ``AuxSummarizer``. Counts calls and the transcript size,
    and answers with a short fixed text after ``delay_ms``."""

    def __init__(self, delay_ms: float = 0.0) -> None:
        self.delay_ms = max(0.0, float(delay_ms))
        self.calls = 0
        self.transcript_chars = 0
        self.ms = 0.0

    def summarize(self, transcript: str, previous: str | None) -> str:
        started = time.perf_counter()
        self.calls += 1
        self.transcript_chars += len(transcript or "")
        if self.delay_ms:
            time.sleep(self.delay_ms / 1000)
        self.ms += (time.perf_counter() - started) * 1000
        return (
            f"[bench stub summary #{self.calls}: {len(transcript or '')} chars folded"
            + (", previous summary kept]" if previous else "]")
        )


@dataclass
class PassResult:
    index: int
    steps: dict[str, float] = field(default_factory=dict)
    rounds: list[dict[str, Any]] = field(default_factory=list)
    summarizer_calls: int = 0
    summarizer_ms: float = 0.0
    summarizer_transcript_chars: int = 0
    outbound_messages: int = 0
    prompt_tokens_est: int = 0

    @property
    def prepare_ms(self) -> float:
        return round(sum(self.steps.get(name, 0.0) for name in PREPARE_STEPS), 3)


@dataclass
class OfflineResult:
    db: str
    session_key: str
    session_id: int
    stored_rows: int
    stored_bytes: int
    runtime_src: str
    runtime_rev: str
    summarizer: str
    context_length: int
    cache_rows_at_start: int
    passes: list[PassResult] = field(default_factory=list)
    profile: str = ""

    def step_stats(self) -> dict[str, dict[str, float | None]]:
        out: dict[str, dict[str, float | None]] = {}
        for name in (*ALL_STEPS, "prepare_total"):
            values = [
                (p.prepare_ms if name == "prepare_total" else p.steps[name])
                for p in self.passes
                if name == "prepare_total" or name in p.steps
            ]
            out[name] = {
                "p50": _r(percentile(values, 50)),
                "min": _r(min(values)) if values else None,
                "max": _r(max(values)) if values else None,
            }
        return out

    def as_dict(self) -> dict[str, Any]:
        data = asdict(self)
        for item, src in zip(data["passes"], self.passes):
            item["prepare_ms"] = src.prepare_ms
        data["steps"] = self.step_stats()
        return data


def _r(value: float | None) -> float | None:
    return None if value is None else round(value, 3)


def _ms_since(started: float) -> float:
    return round((time.perf_counter() - started) * 1000, 3)


# --------------------------------------------------------------------------
# importing the runtime
# --------------------------------------------------------------------------


def import_runtime(runtime_src: str | os.PathLike | None = None) -> dict[str, Any]:
    """The runtime pieces the replay needs, as a dict of names.

    With ``runtime_src`` (a ``.../agents/runtime/src`` directory) that tree is
    put first on ``sys.path`` and no ``.pyc`` file is written into it, so a
    tree that must not change (the host's) stays byte for byte as it was.
    Must be called before anything imported ``chuk_agents_runtime``.
    """
    if runtime_src is not None:
        src = str(Path(runtime_src).expanduser().resolve())
        if not (Path(src) / "chuk_agents_runtime" / "__init__.py").is_file():
            raise FileNotFoundError(f"no chuk_agents_runtime package under {src}")
        loaded = sys.modules.get("chuk_agents_runtime")
        if loaded is not None and not str(getattr(loaded, "__file__", "")).startswith(src):
            raise RuntimeError("chuk_agents_runtime is already imported from another tree")
        sys.dont_write_bytecode = True
        sys.path.insert(0, src)

    import chuk_agents_runtime
    from chuk_agents_runtime.context import (
        ContextLadder,
        LadderConfig,
        estimate_messages_tokens,
    )
    try:  # the Pydantic AI loop; a tree from before it has no converter
        from chuk_agents_runtime.pai.convert import rows_to_messages
    except ImportError:
        rows_to_messages = None
    from chuk_agents_runtime.prompt import upgrade_research_instructions
    from chuk_agents_runtime.skills import SkillLibrary, SkillSettingsStore, load_skills
    from chuk_agents_runtime.state import StateStore
    from chuk_agents_runtime.think_scrubber import scrub_history

    return {
        "package_file": str(Path(chuk_agents_runtime.__file__).resolve()),
        "ContextLadder": ContextLadder,
        "LadderConfig": LadderConfig,
        "estimate_messages_tokens": estimate_messages_tokens,
        "rows_to_messages": rows_to_messages,
        "upgrade_research_instructions": upgrade_research_instructions,
        "SkillLibrary": SkillLibrary,
        "SkillSettingsStore": SkillSettingsStore,
        "load_skills": load_skills,
        "StateStore": StateStore,
        "scrub_history": scrub_history,
    }


def runtime_revision(package_file: str) -> str:
    """``<short sha>`` of the git tree the runtime came from, ``+dirty`` when
    files under ``agents/runtime`` differ from that commit. Read-only git."""
    package_dir = Path(package_file).parent
    try:
        sha = subprocess.run(
            ["git", "-C", str(package_dir), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", str(package_dir), "status", "--porcelain", "--", "."],
            capture_output=True, text=True, timeout=20, check=True,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return sha + ("+dirty" if dirty else "")


# --------------------------------------------------------------------------
# the replay
# --------------------------------------------------------------------------


def find_session(db_path: str | Path, session_key: str) -> tuple[int, int, int]:
    """``(session_id, rows, bytes)`` of the session's model-visible rows
    (``role <> 'event'``, the same filter ``get_conversation`` uses)."""
    conn = sqlite3.connect(f"file:{Path(db_path)}?mode=ro", uri=True, timeout=5.0)
    try:
        row = conn.execute(
            "SELECT session_id FROM session_routes WHERE session_key=?", (session_key,)
        ).fetchone()
        if row is None:
            known = [r[0] for r in conn.execute("SELECT session_key FROM session_routes")]
            raise LookupError(
                f"no session {session_key!r} in {db_path}; known: {', '.join(known) or 'none'}"
            )
        session_id = int(row[0])
        count, size = conn.execute(
            "SELECT count(*), coalesce(sum(length(content)), 0) FROM messages "
            "WHERE session_id=? AND role<>'event'",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    return session_id, int(count), int(size)


def _cache_rows(db_path: Path, session_id: int, *, clear: bool) -> int:
    """Rows in ``context_summaries`` for the session (0 when the table does
    not exist yet). ``clear`` deletes them first, for a cold run."""
    conn = sqlite3.connect(str(db_path), timeout=5.0)
    try:
        exists = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='context_summaries'"
        ).fetchone()
        if not exists:
            return 0
        if clear:
            conn.execute("DELETE FROM context_summaries WHERE session_id=?", (session_id,))
            conn.commit()
        return int(
            conn.execute(
                "SELECT count(*) FROM context_summaries WHERE session_id=?", (session_id,)
            ).fetchone()[0]
        )
    finally:
        conn.close()


def guess_skills_root(session_key: str, state_dir: Path | None = None) -> Path | None:
    """The agent workspace's ``skills`` directory for a session key.

    The host names a per-agent workspace after the key with ``:`` turned into
    ``-`` plus a short suffix (``local:brisk-heron:2:1166`` ->
    ``agents/local-brisk-heron-2-1166-37d74703``). Only read, never written.
    """
    from .snapshot import live_state_dir

    base = (state_dir or live_state_dir()) / "agents"
    stem = session_key.replace(":", "-")
    try:
        matches = sorted(p for p in base.glob(stem + "-*") if (p / "skills").is_dir())
    except OSError:
        return None
    return matches[0] / "skills" if matches else None


def replay(
    db_copy: str | Path,
    session_key: str,
    *,
    passes: int = 3,
    rounds: int = 1,
    runtime_src: str | os.PathLike | None = None,
    skills_root: str | Path | None = None,
    summarizer: str = "stub",
    aux_delay_ms: float = 0.0,
    context_length: int | None = None,
    cold: bool = False,
    profile: bool = False,
    profile_top: int = 25,
    work_db: str | Path | None = None,
    rt: dict[str, Any] | None = None,
) -> OfflineResult:
    """Run the prepare pipeline ``passes`` times on a fresh working copy.

    Each pass is one new run, as in production (the executor builds a fresh
    runtime, so a fresh ladder, per task); ``rounds`` prepares per pass are
    the model requests of one multi-round run. A summary the ladder stores in
    pass 1 is what pass 2 finds, so pass 1 is "cold" and later passes are
    "warm" when the runtime keeps the summary across runs.

    ``summarizer``: ``stub`` (counts aux calls, answers at once or after
    ``aux_delay_ms``) or ``none`` (tier 1 only, like a mock model).
    """
    if summarizer not in ("stub", "none"):
        raise ValueError("summarizer must be 'stub' or 'none'")
    rt = rt or import_runtime(runtime_src)
    session_id, stored_rows, stored_bytes = find_session(db_copy, session_key)

    work = Path(work_db) if work_db else default_scratch_dir() / "offline-work.db"
    copy_file(db_copy, work)
    cache_rows = _cache_rows(work, session_id, clear=cold)

    config_cls = rt["LadderConfig"]
    config = config_cls(context_length=context_length) if context_length else config_cls()
    result = OfflineResult(
        db=str(db_copy),
        session_key=session_key,
        session_id=session_id,
        stored_rows=stored_rows,
        stored_bytes=stored_bytes,
        runtime_src=str(Path(rt["package_file"]).parent),
        runtime_rev=runtime_revision(rt["package_file"]),
        summarizer="none" if summarizer == "none" else f"stub(delay {aux_delay_ms:g}ms)",
        context_length=int(config.context_length),
        cache_rows_at_start=cache_rows,
    )

    profiler = cProfile.Profile() if profile else None
    for index in range(1, max(1, passes) + 1):
        result.passes.append(
            _one_pass(
                rt,
                work,
                session_id,
                index=index,
                rounds=max(1, rounds),
                config=config,
                skills_root=skills_root,
                stub=StubSummarizer(aux_delay_ms) if summarizer == "stub" else None,
                profiler=profiler if index == 1 else None,
            )
        )
    if profiler is not None:
        buffer = io.StringIO()
        stats = pstats.Stats(profiler, stream=buffer)
        stats.sort_stats("cumulative").print_stats(profile_top)
        result.profile = buffer.getvalue()
    return result


def _timed(steps: dict[str, float], name: str, fn: Callable[[], Any]) -> Any:
    started = time.perf_counter()
    value = fn()
    steps[name] = round(steps.get(name, 0.0) + _ms_since(started), 3)
    return value


def _one_pass(
    rt: dict[str, Any],
    work: Path,
    session_id: int,
    *,
    index: int,
    rounds: int,
    config: Any,
    skills_root: str | Path | None,
    stub: StubSummarizer | None,
    profiler: cProfile.Profile | None,
) -> PassResult:
    out = PassResult(index=index)
    steps = out.steps

    store = _timed(steps, "open_store", lambda: rt["StateStore"](str(work)))
    try:
        def load_library() -> Any:
            if skills_root is None:
                return rt["SkillLibrary"]()
            try:
                settings = rt["SkillSettingsStore"](str(work))
            except sqlite3.Error:
                settings = None
            return rt["load_skills"](str(skills_root), settings=settings)

        library = _timed(steps, "skills_load", load_library)
        upgrade = rt["upgrade_research_instructions"]

        ladder = rt["ContextLadder"](config=config, summarizer=stub)
        # What build_runtime does in the trees that keep the summary across
        # runs; an older tree has no such attribute and skips it.
        if hasattr(ladder, "summary_store"):
            ladder.summary_store = store

        # A tree from before the summary cache takes no session_id.
        takes_session = "session_id" in inspect.signature(ladder.prepare).parameters

        def run_ladder(messages: list[dict]) -> list[dict]:
            if takes_session:
                return ladder.prepare(messages, session_id=session_id)
            return ladder.prepare(messages)

        outbound: list[dict] = []
        for round_no in range(1, rounds + 1):
            messages = _timed(
                steps,
                "history_load",
                lambda: [m.content for m in store.get_conversation(session_id)],
            )
            messages = _timed(
                steps,
                "prompt_upgrade",
                lambda: [
                    {**m, "content": library.upgrade_catalog(upgrade(m["content"]))}
                    if m.get("role") == "system" and isinstance(m.get("content"), str)
                    else m
                    for m in messages
                ],
            )
            _timed(steps, "scrub_history", lambda: rt["scrub_history"](messages))

            def prepare() -> list[dict]:
                if profiler is None:
                    return run_ladder(messages)
                profiler.enable()
                try:
                    return run_ladder(messages)
                finally:
                    profiler.disable()

            outbound = _timed(steps, "ladder_prepare", prepare)
            stats = ladder.last_stats
            out.rounds.append(
                {
                    "round": round_no,
                    "input_messages": len(messages),
                    "outbound_messages": len(outbound),
                    "tier": int(getattr(stats, "tier", 0)),
                    "pressure": round(float(getattr(stats, "pressure", 0.0)), 4),
                    "tokens_before": int(getattr(stats, "tokens_before", 0)),
                    "tokens_after": int(getattr(stats, "tokens_after", 0)),
                    "skipped_reason": getattr(stats, "skipped_reason", None),
                }
            )
        out.prompt_tokens_est = int(
            _timed(steps, "estimate_tokens", lambda: rt["estimate_messages_tokens"](outbound))
        )
        if rt["rows_to_messages"] is not None:
            _timed(steps, "convert_pai", lambda: rt["rows_to_messages"](outbound))
        out.outbound_messages = len(outbound)
        if stub is not None:
            out.summarizer_calls = stub.calls
            out.summarizer_ms = round(stub.ms, 3)
            out.summarizer_transcript_chars = stub.transcript_chars
    finally:
        close = getattr(store, "close", None)
        if callable(close):
            close()
    return out


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------


def _fmt(value: float | None) -> str:
    if value is None:
        return "-"
    if value >= 10_000:
        return f"{value / 1000:.2f}s"
    return f"{value:.1f}"


def render_text(result: OfflineResult, baseline: dict[str, Any] | None = None) -> str:
    out: list[str] = []
    out.append(
        f"offline replay  session {result.session_key} (id {result.session_id})  "
        f"{result.stored_rows} rows, {result.stored_bytes / 1e6:.2f} MB"
    )
    out.append(f"runtime {result.runtime_src}  rev {result.runtime_rev}")
    out.append(
        f"db copy {result.db}  summarizer {result.summarizer}  context_length "
        f"{result.context_length}  cached summaries at start {result.cache_rows_at_start}"
    )
    out.append(
        f"passes {len(result.passes)} x rounds {len(result.passes[0].rounds) if result.passes else 0}"
        "  (pass = one new run, fresh ladder; times in ms)"
    )
    out.append("")
    head = f"  {'step':<18}" + "".join(f" {'pass' + str(p.index):>10}" for p in result.passes)
    head += f" {'p50':>10}"
    if baseline:
        head += f" {'base p50':>10} {'delta':>9}"
    out.append(head)
    stats = result.step_stats()
    base_steps = (baseline or {}).get("steps", {})
    for name in (*ALL_STEPS, "prepare_total"):
        label = name if name not in ("scrub_history",) else "(scrub_history)"
        if name == "prepare_total":
            out.append("  " + "-" * (len(head) - 2))
        line = f"  {label:<18}"
        for p in result.passes:
            value = p.prepare_ms if name == "prepare_total" else p.steps.get(name)
            line += f" {_fmt(value):>10}"
        p50 = stats[name]["p50"]
        line += f" {_fmt(p50):>10}"
        if baseline:
            base = (base_steps.get(name) or {}).get("p50")
            line += f" {_fmt(base):>10}"
            if base and p50 is not None:
                line += f" {(p50 - base) / base * 100:>+8.0f}%"
        out.append(line)
    out.append("  prepare_total = history_load + prompt_upgrade + ladder_prepare (= runs.prepare_ms)")
    out.append("  (scrub_history) also runs inside ladder_prepare; shown alone for information")
    out.append("")
    for p in result.passes:
        tiers = ", ".join(
            f"r{r['round']} tier {r['tier']} pressure {r['pressure']:.2f} "
            f"tokens {r['tokens_before']}->{r['tokens_after']}"
            + (f" ({r['skipped_reason']})" if r.get("skipped_reason") else "")
            for r in p.rounds
        )
        out.append(
            f"  pass{p.index}: {tiers}; outbound {p.outbound_messages} msgs ~{p.prompt_tokens_est} tok;"
            f" aux summarizer calls {p.summarizer_calls}"
            + (
                f" ({p.summarizer_transcript_chars} transcript chars)"
                if p.summarizer_calls
                else ""
            )
        )
    if any(p.summarizer_calls for p in result.passes):
        out.append(
            "  note: each aux summarizer call is a real model call in a live turn;"
            " live prepare ~= prepare_total + calls x aux latency"
        )
    if result.profile:
        out.append("")
        out.append("profile of pass1 ladder_prepare (cumulative):")
        out.append(result.profile.rstrip())
    return "\n".join(out)


def render_json(result: OfflineResult) -> str:
    return json.dumps(result.as_dict(), indent=2, default=str)


def load_baseline(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))
