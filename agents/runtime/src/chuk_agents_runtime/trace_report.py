"""Read a run trace back and say which segment of the turn was slow.

:mod:`chuk_agents_runtime.trace` writes the JSONL; this module is the other
half — the pure reader that turns those lines into an answer. It knows three
things the writer deliberately does not:

- **A run can straddle a rotation.** The writer caps the live file and shifts
  the older ones down to ``agent-trace.jsonl.1`` ... ``.3``. A reader that only
  opened the live file would silently drop the first half of the very run the
  user is asking about, so :func:`read_lines` reads the rotated files first,
  oldest first, and then the live one.
- **A run id is long and nobody types it.** Every lookup takes a prefix.
- **Buckets, not lines, answer the question.** A waterfall of 300 phase lines
  is a haystack. :func:`attribution` tiles the wall span into
  prepare / connect / provider_wait / provider_stream / tools / memory_recall /
  retries, and whatever is left over is named ``unattributed`` instead of being
  quietly dropped — an honest "we do not know where 8s went" is a finding.

Nothing here imports the host, opens a socket or starts a run: it is a file
reader plus string formatting, so the CLI can print a trace on a machine where
the agent could not even start.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from .trace import TRACE_FILENAME

#: The report must stay readable in a plain 100-column terminal, so every
#: line is built to fit and then clamped.
LINE_WIDTH = 100

#: Fields every line carries. They frame the line; they are not its payload, so
#: the waterfall's "key fields" column skips them.
STRUCTURAL_FIELDS = ("t", "wall", "run_id", "session_key", "round", "phase", "dt_ms")

#: The buckets :func:`attribution` reports, in a fixed order so two runs can be
#: compared column by column. ``unattributed`` is last because it is the
#: remainder, not a measurement.
BUCKETS = (
    "prepare",
    "connect",
    "provider_wait",
    "provider_stream",
    "tools",
    "memory_recall",
    "retries",
    "unattributed",
)

#: One line of explanation per bucket, printed under the attribution block.
BUCKET_HELP = {
    "prepare": "our own work before the request (ladder, payload build)",
    "connect": "opening the transport + auth",
    "provider_wait": "request sent -> first byte back (provider queue + prefill)",
    "provider_stream": "first byte -> stream closed (generation)",
    "tools": "tool calls, including the sandbox",
    "memory_recall": "memory lookups",
    "retries": "attempts thrown away and paid for twice",
    "unattributed": "wall time no phase claimed",
}


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------


def _resolve_path(source: str | os.PathLike) -> Path:
    """A directory means ``<dir>/agent-trace.jsonl``; anything else is the file."""
    path = Path(source).expanduser()
    if path.is_dir():
        return path / TRACE_FILENAME
    if not path.exists() and not path.suffix:
        return path / TRACE_FILENAME
    return path


def rotated_paths(path: Path) -> list[Path]:
    """The rotated backups beside ``path``, oldest first.

    The writer shifts files down (``.1`` becomes ``.2``), so a higher number is
    older. Sorting numerically — not lexically — keeps ``.10`` after ``.9``.
    """
    parent = path.parent
    prefix = path.name + "."
    numbered: list[tuple[int, Path]] = []
    try:
        entries = list(parent.glob(path.name + ".*"))
    except OSError:
        return []
    for entry in entries:
        tail = entry.name[len(prefix):]
        if tail.isdigit():
            numbered.append((int(tail), entry))
    numbered.sort(key=lambda item: item[0], reverse=True)
    return [entry for _, entry in numbered]


def trace_files(source: str | os.PathLike) -> list[Path]:
    """Every file that may hold lines of this trace, oldest first."""
    path = _resolve_path(source)
    return [*rotated_paths(path), path]


def read_lines(source: str | os.PathLike, *, run_id: str | None = None) -> list[dict]:
    """Every trace line in file order, rotated backups first.

    ``run_id`` may be a prefix — a run id is a uuid nobody retypes. A line that
    is not valid JSON is skipped in silence: a trace truncated mid-write by a
    kill is the normal case, not an error worth raising at the user.
    """
    lines: list[dict] = []
    for candidate in trace_files(source):
        try:
            if not candidate.is_file():
                continue
            text = candidate.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for raw in text.splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if not isinstance(obj, dict):
                continue
            if run_id:
                candidate_id = str(obj.get("run_id", ""))
                if not (candidate_id == run_id or candidate_id.startswith(run_id)):
                    continue
            lines.append(obj)
    return lines


def list_runs(source: str | os.PathLike) -> list[dict]:
    """One summary row per run id, newest first."""
    rows: dict[str, dict] = {}
    for line in read_lines(source):
        run_id = str(line.get("run_id") or "")
        if not run_id:
            # Emitted outside a run scope: real, but it belongs to no run.
            continue
        wall = _number(line.get("wall"))
        row = rows.get(run_id)
        if row is None:
            row = {
                "run_id": run_id,
                "session_key": str(line.get("session_key") or ""),
                "started_wall": wall,
                "finished_wall": wall,
                "rounds": 0,
                "total_ms": 0.0,
                "reason": "",
                "lines": 0,
            }
            rows[run_id] = row
        row["lines"] += 1
        if not row["session_key"] and line.get("session_key"):
            row["session_key"] = str(line["session_key"])
        if wall:
            if not row["started_wall"] or wall < row["started_wall"]:
                row["started_wall"] = wall
            if wall > row["finished_wall"]:
                row["finished_wall"] = wall
        row["rounds"] = max(row["rounds"], int(_number(line.get("round"))))
        if line.get("phase") == "run_finished":
            row["reason"] = str(line.get("reason") or line.get("status") or "")
    for row in rows.values():
        row["total_ms"] = round(max(0.0, row["finished_wall"] - row["started_wall"]) * 1000, 3)
    return sorted(rows.values(), key=lambda row: row["started_wall"], reverse=True)


# --------------------------------------------------------------------------
# attribution
# --------------------------------------------------------------------------


def _number(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return 0.0
    return 0.0


def span_ms(lines: list[dict]) -> float:
    """The run's wall span. Falls back to the monotonic ``t`` when a line has
    no wall clock, so a hand-written or partial trace still reports a span."""
    walls = [_number(line.get("wall")) for line in lines if _number(line.get("wall"))]
    if len(walls) >= 2:
        return max(0.0, (max(walls) - min(walls)) * 1000)
    stamps = [_number(line.get("t")) for line in lines if line.get("t") is not None]
    if len(stamps) >= 2:
        return max(0.0, (max(stamps) - min(stamps)) * 1000)
    return 0.0


def _merge_server(into: dict, block: Any) -> None:
    """Sum the backend-side timing blocks of every model call.

    They are the provider's own view of the same request, so the useful merge
    is the same one we do for our numbers: add them up per key.
    """
    if not isinstance(block, dict):
        return
    for key, value in block.items():
        if isinstance(value, dict):
            nested = into.setdefault(str(key), {})
            if isinstance(nested, dict):
                _merge_server(nested, value)
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            into[str(key)] = round(_number(into.get(str(key))) + float(value), 3)
        elif str(key) not in into:
            into[str(key)] = value


def attribution(lines: list[dict]) -> dict:
    """Split the run's wall span into buckets, all in milliseconds.

    Each bucket is summed from the phase that measured it, never from the gap
    between two lines: a gap is only evidence that nothing emitted, which is
    exactly what ``unattributed`` is for. ``unattributed`` is clamped at zero —
    overlapping measurements (a tool that ran while a stream was open) must not
    produce a negative number that reads like a bug in the trace.
    """
    prepare_direct = 0.0
    prepare_direct_seen = False
    prepare_fallback = 0.0
    connect = 0.0
    provider_wait = 0.0
    provider_stream = 0.0
    tools = 0.0
    memory_recall = 0.0
    retries = 0.0
    retries_count = 0
    model_calls = 0
    prompt_tokens = 0.0
    completion_tokens = 0.0
    total_tokens = 0.0
    server: dict = {}

    for line in lines:
        phase = line.get("phase")
        if phase in ("ladder_pass", "payload_prepared"):
            if line.get("ms") is not None:
                prepare_direct += _number(line.get("ms"))
                prepare_direct_seen = True
        elif phase == "model_call":
            model_calls += 1
            prepare_fallback += _number(line.get("prepare_ms"))
            connect += _number(line.get("connect_ms")) + _number(line.get("auth_ms"))
            provider_wait += _number(line.get("first_frame_ms"))
            provider_stream += _number(line.get("stream_ms"))
            _merge_server(server, line.get("server"))
        elif phase == "tool_end":
            tools += _number(line.get("ms"))
        elif phase == "memory_recall_end":
            memory_recall += _number(line.get("ms"))
        elif phase == "retry":
            retries += _number(line.get("dead_ms"))
            retries_count += 1
        elif phase == "usage":
            prompt_tokens += _number(line.get("prompt_tokens") or line.get("prompt"))
            completion_tokens += _number(line.get("completion_tokens") or line.get("completion"))
            total_tokens += _number(line.get("total_tokens") or line.get("total"))

    prepare = prepare_direct if prepare_direct_seen else prepare_fallback
    total = span_ms(lines)
    buckets = {
        "prepare": round(prepare, 3),
        "connect": round(connect, 3),
        "provider_wait": round(provider_wait, 3),
        "provider_stream": round(provider_stream, 3),
        "tools": round(tools, 3),
        "memory_recall": round(memory_recall, 3),
        "retries": round(retries, 3),
    }
    accounted = sum(buckets.values())
    buckets["unattributed"] = round(max(0.0, total - accounted), 3)
    if not total_tokens:
        total_tokens = prompt_tokens + completion_tokens
    return {
        **buckets,
        "total_ms": round(total, 3),
        "retries_count": retries_count,
        # A model client that has no transport of its own (the mock, a test
        # double) writes no ``model_call`` phase, but the loop still counted its
        # calls on the ``run_finished`` line. Prefer the measured phases and
        # fall back to the loop's own count, so this never reads "0 calls" for a
        # run that plainly made some.
        "model_calls": model_calls or _last_int(lines, "run_finished", "model_calls"),
        "tokens": {
            "prompt": int(prompt_tokens),
            "completion": int(completion_tokens),
            "total": int(total_tokens),
        },
        "server": server,
    }


# --------------------------------------------------------------------------
# the report
# --------------------------------------------------------------------------


def _bar(value: float, peak: float, width: int) -> str:
    if peak <= 0 or value <= 0:
        return " " * width
    filled = int(round((value / peak) * width))
    filled = max(1, min(width, filled))
    return "#" * filled + " " * (width - filled)


def _clamp(text: str, limit: int = LINE_WIDTH) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "~"


def _wall_text(wall: float) -> str:
    if not wall:
        return "?"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(wall))


def _field_order(key: str) -> int:
    """Durations first. The column is narrow, and a number of milliseconds is
    why anyone opened the trace; a label can be cut."""
    return 0 if key == "ms" or key.endswith("_ms") else 1


def _field_text(line: dict, budget: int) -> str:
    parts: list[str] = []
    keys = sorted((k for k in line if k not in STRUCTURAL_FIELDS), key=_field_order)
    for key in keys:
        value = line[key]
        if isinstance(value, float):
            rendered = f"{value:g}"
        elif isinstance(value, (dict, list)):
            rendered = json.dumps(value, separators=(",", ":"), default=str)
        else:
            rendered = str(value)
        rendered = rendered.replace("\n", " ")
        if len(rendered) > 28:
            rendered = rendered[:27] + "~"
        parts.append(f"{key}={rendered}")
    text = " ".join(parts)
    if budget > 1 and len(text) > budget:
        text = text[: budget - 1] + "~"
    return text


def waterfall(lines: list[dict], *, width: int = 48) -> str:
    """A terminal report for one run: the buckets first, then the timeline.

    The buckets come first on purpose. The question is "what was slow", and the
    answer is one row of this block; the timeline below it is the evidence, and
    nobody should have to read 300 lines to find a number that fits on one.
    """
    if not lines:
        return "no trace lines for that run."

    head = lines[0]
    run_id = str(head.get("run_id") or "?")
    session_key = str(head.get("session_key") or "?")
    start_wall = min(
        (_number(line.get("wall")) for line in lines if _number(line.get("wall"))),
        default=0.0,
    )
    reason = ""
    for line in lines:
        if line.get("phase") == "run_finished":
            reason = str(line.get("reason") or line.get("status") or "")
    shares = attribution(lines)
    total = float(shares["total_ms"])

    out: list[str] = []
    out.append(f"run {run_id}")
    out.append(
        f"  session {session_key}   started {_wall_text(start_wall)}   "
        f"span {total / 1000:.3f}s   reason {reason or '-'}"
    )
    out.append("")
    out.append(f"  where the time went ({total:.0f}ms total)")
    ranked = sorted(BUCKETS, key=lambda name: float(shares.get(name, 0.0)), reverse=True)
    peak = max((float(shares.get(name, 0.0)) for name in ranked), default=0.0)
    for name in ranked:
        value = float(shares.get(name, 0.0))
        share = (value / total * 100) if total else 0.0
        out.append(
            f"    {name:<15} {value:>9.1f}ms {share:>5.1f}%  |{_bar(value, peak, width)}|"
        )
    out.append("")
    out.append(
        f"  model calls {shares['model_calls']}   retries {shares['retries_count']}   "
        f"tokens {shares['tokens']['prompt']}+{shares['tokens']['completion']}"
        f"={shares['tokens']['total']}"
    )
    if shares["server"]:
        out.append(
            "  server "
            + json.dumps(shares["server"], separators=(",", ":"), sort_keys=True, default=str)
        )
    top = ranked[0] if ranked else ""
    if top and BUCKET_HELP.get(top):
        out.append(f"  biggest: {top} - {BUCKET_HELP[top]}")
    out.append("")

    origin = min((_number(line.get("t")) for line in lines), default=0.0)
    peak_dt = max((_number(line.get("dt_ms")) for line in lines), default=0.0)
    bar_width = max(8, width // 3)
    out.append("  timeline")
    current_round: int | None = None
    for line in lines:
        round_no = int(_number(line.get("round")))
        if round_no != current_round:
            current_round = round_no
            out.append(f"    round {round_no}")
        phase = str(line.get("phase") or "?")
        offset = _number(line.get("t")) - origin
        dt_ms = _number(line.get("dt_ms"))
        # A retry is the one line you must not scroll past, so it breaks the
        # indent instead of sitting in it.
        marker = "  !   " if phase == "retry" else "      "
        prefix = (
            f"{marker}+{offset:>8.3f}  {phase:<18} {dt_ms:>9.1f}ms "
            f"[{_bar(dt_ms, peak_dt, bar_width)}] "
        )
        out.append((prefix + _field_text(line, LINE_WIDTH - len(prefix))).rstrip())
    return "\n".join(_clamp(row) for row in out)


def _last_int(lines: list[dict], phase: str, field: str) -> int:
    """The last value of ``field`` on a ``phase`` line, or 0."""
    for line in reversed(lines):
        if line.get("phase") == phase:
            try:
                return int(line.get(field) or 0)
            except (TypeError, ValueError):
                return 0
    return 0
