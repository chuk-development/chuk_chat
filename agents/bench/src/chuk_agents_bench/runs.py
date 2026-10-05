"""Run timings from a state database copy, and the backend timing log.

The loop writes one ``runs`` row per task with the timing columns of
``chuk_agents_runtime.loop.RunTimings``: ``model_calls``, ``model_wait_ms``,
``prepare_ms``, ``tool_ms``, ``recall_ms``, ``retries``, ``retry_ms``. This
module reads those rows and aggregates them (p50/p95 by session and by
provider/model). It imports nothing from the runtime: it is plain ``sqlite3``
plus arithmetic, so it also works on a copy from an older host.

A row with ``model_calls = 0`` was written before the timing columns existed
(or the run made no model call). Its timings read as zero, which means "not
measured", so it is left out of the aggregates unless asked for.
"""

from __future__ import annotations

import json
import math
import re
import sqlite3
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

#: The timing columns, in the order the loop writes them.
TIMING_COLUMNS = (
    "model_calls",
    "model_wait_ms",
    "prepare_ms",
    "tool_ms",
    "recall_ms",
    "retries",
    "retry_ms",
)

#: The millisecond figures the aggregates report, in display order.
METRICS = (
    "wall_ms",
    "prepare_ms",
    "model_wait_ms",
    "tool_ms",
    "recall_ms",
    "retry_ms",
    "other_ms",
    "prepare_per_call_ms",
    "model_wait_per_call_ms",
)

PROMPT_PREVIEW = 40


@dataclass
class RunRow:
    """One ``runs`` row with the derived figures the report needs."""

    run_id: str
    session_key: str
    prompt_preview: str
    prompt_chars: int
    state: str
    model: str
    provider: str
    started_at: float
    finished_at: float | None
    iterations: int
    tokens_spent: int
    model_calls: int
    model_wait_ms: float
    prepare_ms: float
    tool_ms: float
    recall_ms: float
    retries: int
    retry_ms: float
    wall_ms: float | None = None
    other_ms: float | None = None
    prepare_per_call_ms: float | None = None
    model_wait_per_call_ms: float | None = None

    @property
    def measured(self) -> bool:
        """The run carries timings (written after the timing columns existed
        and made at least one model call)."""
        return self.model_calls > 0

    @property
    def model_key(self) -> str:
        return f"{self.provider or '-'} | {self.model or '-'}"

    def as_dict(self) -> dict[str, Any]:
        out = asdict(self)
        out["measured"] = self.measured
        out["model_key"] = self.model_key
        return out


def derive(row: RunRow) -> RunRow:
    """Fill the derived fields.

    ``wall_ms`` is ``finished_at - started_at``. ``other_ms`` is the part of
    the wall clock no timing column claims (clamped at zero: the buckets can
    overlap). The per-call figures make a one-round "hi" comparable with a
    17-round task.
    """
    if row.finished_at is not None and row.finished_at >= row.started_at:
        row.wall_ms = round((row.finished_at - row.started_at) * 1000, 1)
        claimed = row.prepare_ms + row.model_wait_ms + row.tool_ms + row.recall_ms
        row.other_ms = round(max(0.0, row.wall_ms - claimed), 1)
    if row.model_calls > 0:
        row.prepare_per_call_ms = round(row.prepare_ms / row.model_calls, 1)
        row.model_wait_per_call_ms = round(row.model_wait_ms / row.model_calls, 1)
    return row


def _preview(prompt: str | None) -> str:
    text = " ".join((prompt or "").split())
    if len(text) > PROMPT_PREVIEW:
        return text[: PROMPT_PREVIEW - 1] + "~"
    return text


def _columns(conn: sqlite3.Connection) -> set[str]:
    return {str(r[1]) for r in conn.execute("PRAGMA table_info(runs)").fetchall()}


def load_runs(db_path: str | Path) -> list[RunRow]:
    """Every ``runs`` row of a database COPY, oldest first.

    Opened read-only. A copy from a host older than a column reads that
    column as zero / empty instead of failing.
    """
    conn = sqlite3.connect(f"file:{Path(db_path)}?mode=ro", uri=True, timeout=5.0)
    try:
        conn.row_factory = sqlite3.Row
        have = _columns(conn)
        if not have:
            return []

        def col(name: str, default: str = "0") -> str:
            return name if name in have else f"{default} AS {name}"

        sql = (
            "SELECT run_id, session_key, prompt, state, "
            f"{col('model', 'NULL')}, {col('provider', 'NULL')}, "
            "started_at, finished_at, iterations, tokens_spent, "
            + ", ".join(col(c) for c in TIMING_COLUMNS)
            + " FROM runs ORDER BY started_at"
        )
        rows = conn.execute(sql).fetchall()
    finally:
        conn.close()
    return [_row(r) for r in rows]


def _row(r: sqlite3.Row) -> RunRow:
    prompt = r["prompt"] or ""
    return derive(
        RunRow(
            run_id=str(r["run_id"]),
            session_key=str(r["session_key"] or ""),
            prompt_preview=_preview(prompt),
            prompt_chars=len(prompt),
            state=str(r["state"] or ""),
            model=str(r["model"] or ""),
            provider=str(r["provider"] or ""),
            started_at=float(r["started_at"] or 0.0),
            finished_at=None if r["finished_at"] is None else float(r["finished_at"]),
            iterations=int(r["iterations"] or 0),
            tokens_spent=int(r["tokens_spent"] or 0),
            model_calls=int(r["model_calls"] or 0),
            model_wait_ms=float(r["model_wait_ms"] or 0),
            prepare_ms=float(r["prepare_ms"] or 0),
            tool_ms=float(r["tool_ms"] or 0),
            recall_ms=float(r["recall_ms"] or 0),
            retries=int(r["retries"] or 0),
            retry_ms=float(r["retry_ms"] or 0),
        )
    )


# --------------------------------------------------------------------------
# filtering
# --------------------------------------------------------------------------


def parse_since(text: str | None, *, now: float | None = None) -> float | None:
    """``24h`` / ``90m`` / ``7d`` (relative) or ``2026-10-05`` /
    ``2026-10-05T03:00`` (local time) as an epoch second. ``None`` passes."""
    if not text:
        return None
    now = time.time() if now is None else now
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd])\s*", text)
    if match:
        scale = {"s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2)]
        return now - float(match.group(1)) * scale
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return time.mktime(time.strptime(text.strip(), fmt))
        except ValueError:
            continue
    raise ValueError(f"cannot read --since {text!r}; use 24h, 90m, 7d or 2026-10-05[T03:00]")


@dataclass
class RunFilter:
    session: str | None = None
    prompt: str | None = None
    model: str | None = None
    provider: str | None = None
    state: str | None = None
    since: float | None = None
    include_unmeasured: bool = False

    def keep(self, row: RunRow) -> bool:
        if not self.include_unmeasured and not row.measured:
            return False
        if self.session and row.session_key != self.session:
            return False
        if self.prompt is not None and row.prompt_preview != _preview(self.prompt):
            return False
        if self.model and self.model not in row.model:
            return False
        if self.provider and self.provider not in row.provider:
            return False
        if self.state and row.state != self.state:
            return False
        if self.since is not None and row.started_at < self.since:
            return False
        return True


def select(rows: Iterable[RunRow], flt: RunFilter) -> list[RunRow]:
    return [row for row in rows if flt.keep(row)]


# --------------------------------------------------------------------------
# aggregation
# --------------------------------------------------------------------------


def percentile(values: Sequence[float], q: float) -> float | None:
    """The ``q``-th percentile (0..100), linear between closest ranks — the
    same rule as ``numpy.percentile``'s default. ``None`` for no values."""
    data = sorted(float(v) for v in values)
    if not data:
        return None
    if len(data) == 1:
        return data[0]
    q = min(100.0, max(0.0, float(q)))
    pos = (len(data) - 1) * q / 100.0
    low = math.floor(pos)
    high = math.ceil(pos)
    if low == high:
        return data[low]
    return data[low] + (data[high] - data[low]) * (pos - low)


@dataclass
class Stat:
    n: int
    p50: float | None
    p95: float | None
    max: float | None
    mean: float | None

    @classmethod
    def of(cls, values: Sequence[float]) -> "Stat":
        data = [float(v) for v in values]
        if not data:
            return cls(0, None, None, None, None)
        return cls(
            n=len(data),
            p50=_round(percentile(data, 50)),
            p95=_round(percentile(data, 95)),
            max=_round(max(data)),
            mean=_round(sum(data) / len(data)),
        )


def _round(value: float | None) -> float | None:
    return None if value is None else round(value, 1)


@dataclass
class Group:
    key: str
    runs: int
    model_calls: int
    tokens_p50: float | None
    metrics: dict[str, Stat] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "runs": self.runs,
            "model_calls": self.model_calls,
            "tokens_p50": self.tokens_p50,
            "metrics": {name: asdict(stat) for name, stat in self.metrics.items()},
        }


def aggregate(rows: Sequence[RunRow], key: str = "all") -> Group:
    metrics: dict[str, Stat] = {}
    for name in METRICS:
        values = [getattr(r, name) for r in rows if getattr(r, name) is not None]
        metrics[name] = Stat.of(values)
    return Group(
        key=key,
        runs=len(rows),
        model_calls=sum(r.model_calls for r in rows),
        tokens_p50=_round(percentile([r.tokens_spent for r in rows], 50)),
        metrics=metrics,
    )


def group_by(rows: Sequence[RunRow], attr: str) -> list[Group]:
    """One :class:`Group` per distinct value, the most runs first."""
    buckets: dict[str, list[RunRow]] = {}
    for row in rows:
        value = getattr(row, attr)
        buckets.setdefault(str(value), []).append(row)
    groups = [aggregate(items, key) for key, items in buckets.items()]
    return sorted(groups, key=lambda g: (-g.runs, g.key))


@dataclass
class Report:
    source: str
    generated_at: float
    filters: dict[str, Any]
    total_rows: int
    selected: list[RunRow]
    last: list[RunRow]
    overall: Group
    by_session: list[Group]
    by_model: list[Group]

    def as_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "generated_at": self.generated_at,
            "filters": self.filters,
            "total_rows": self.total_rows,
            "selected_rows": len(self.selected),
            "overall": self.overall.as_dict(),
            "by_session": [g.as_dict() for g in self.by_session],
            "by_model": [g.as_dict() for g in self.by_model],
            "last": [r.as_dict() for r in self.last],
        }


def build_report(
    rows: Sequence[RunRow], flt: RunFilter, *, last: int = 20, source: str = ""
) -> Report:
    selected = select(rows, flt)
    newest = sorted(selected, key=lambda r: r.started_at, reverse=True)[: max(0, last)]
    filters = {k: v for k, v in asdict(flt).items() if v not in (None, False)}
    return Report(
        source=source,
        generated_at=time.time(),
        filters=filters,
        total_rows=len(rows),
        selected=selected,
        last=newest,
        overall=aggregate(selected),
        by_session=group_by(selected, "session_key"),
        by_model=group_by(selected, "model_key"),
    )


# --------------------------------------------------------------------------
# text rendering
# --------------------------------------------------------------------------


def _ms(value: float | None) -> str:
    if value is None:
        return "-"
    if value >= 10_000:
        return f"{value / 1000:.1f}s"
    return f"{value:.0f}"


def _clip(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 1] + "~"


def _local(ts: float | None) -> str:
    if not ts:
        return "-"
    return time.strftime("%m-%d %H:%M:%S", time.localtime(ts))


GROUP_METRICS = ("wall_ms", "prepare_ms", "model_wait_ms", "tool_ms", "recall_ms", "other_ms")


def _group_table(title: str, groups: Sequence[Group], key_width: int = 34) -> list[str]:
    out = [title]
    head = f"  {'key':<{key_width}} {'runs':>4} {'calls':>5}"
    for name in GROUP_METRICS:
        short = name.removesuffix("_ms")
        head += f" {short + ' p50/p95':>17}"
    out.append(head)
    for group in groups:
        line = f"  {_clip(group.key, key_width):<{key_width}} {group.runs:>4} {group.model_calls:>5}"
        for name in GROUP_METRICS:
            stat = group.metrics[name]
            line += f" {_ms(stat.p50) + '/' + _ms(stat.p95):>17}"
        out.append(line)
    if not groups:
        out.append("  (no runs)")
    return out


def render_text(report: Report) -> str:
    out: list[str] = []
    out.append(f"source  {report.source}")
    shown = ", ".join(f"{k}={v}" for k, v in report.filters.items()) or "none"
    out.append(
        f"rows    {len(report.selected)} selected of {report.total_rows}   filters: {shown}"
    )
    out.append("        times in ms unless marked s; p50/p95 over runs")
    out.append("")
    out.extend(_group_table("overall", [report.overall]))
    out.append("")
    out.extend(_group_table("by session", report.by_session))
    out.append("")
    out.extend(_group_table("by provider | model", report.by_model, key_width=44))
    out.append("")
    per_call = report.overall.metrics
    out.append(
        "per model call: prepare p50 "
        f"{_ms(per_call['prepare_per_call_ms'].p50)} p95 {_ms(per_call['prepare_per_call_ms'].p95)}"
        "   model_wait p50 "
        f"{_ms(per_call['model_wait_per_call_ms'].p50)} p95 {_ms(per_call['model_wait_per_call_ms'].p95)}"
    )
    out.append("")
    out.append(f"last {len(report.last)} runs (newest first)")
    out.append(
        f"  {'started':<14} {'run':<8} {'session':<30} {'prompt':<18} {'model':<22}"
        f" {'calls':>5} {'wall':>7} {'prep':>7} {'model':>7} {'tool':>7} {'recall':>6} {'other':>7} {'tok':>7}"
    )
    for r in report.last:
        out.append(
            f"  {_local(r.started_at):<14} {r.run_id[:8]:<8} {_clip(r.session_key, 30):<30}"
            f" {_clip(r.prompt_preview, 18):<18} {_clip(r.model, 22):<22} {r.model_calls:>5}"
            f" {_ms(r.wall_ms):>7} {_ms(r.prepare_ms):>7} {_ms(r.model_wait_ms):>7}"
            f" {_ms(r.tool_ms):>7} {_ms(r.recall_ms):>6} {_ms(r.other_ms):>7} {r.tokens_spent:>7}"
        )
    return "\n".join(out)


def render_json(report: Report) -> str:
    return json.dumps(report.as_dict(), indent=2, sort_keys=False, default=str)


# --------------------------------------------------------------------------
# the backend timing log
# --------------------------------------------------------------------------

#: ``chuk_agents_runtime.backend._log_model_call`` writes one line per model
#: call: ``model call ok model=... provider=... attempts=1 retry=- prepare_ms=12
#: connect_ms=80 first_frame_ms=900 first_token_ms=950 stream_ms=1200
#: total_ms=2200 wasted_ms=- prompt_tokens=33000 prompt_tokens_est=32000
#: completion_tokens=40``. Whatever the logging prefix is, the part after
#: ``model call`` is the same.
_LOG_RE = re.compile(r"model call (?P<status>ok|failed\[[^\]]*\])(?P<rest>(?: \w+=\S*)+)")
_KV_RE = re.compile(r"(\w+)=(\S*)")

LOG_METRICS = (
    "prepare_ms",
    "connect_ms",
    "first_frame_ms",
    "first_token_ms",
    "stream_ms",
    "total_ms",
    "wasted_ms",
)


def parse_log_line(line: str) -> dict[str, Any] | None:
    """One ``model call`` line as a dict, or ``None`` for any other line. A
    ``-`` value (not measured) is ``None``, never a fake zero."""
    match = _LOG_RE.search(line)
    if not match:
        return None
    record: dict[str, Any] = {"status": match.group("status")}
    for key, raw in _KV_RE.findall(match.group("rest")):
        if raw in ("", "-"):
            record[key] = None
            continue
        try:
            number = float(raw)
        except ValueError:
            record[key] = raw
            continue
        record[key] = int(number) if number.is_integer() and not key.endswith("_ms") else number
    record["ok"] = record["status"] == "ok"
    return record


def parse_log(lines: Iterable[str]) -> list[dict[str, Any]]:
    return [rec for rec in (parse_log_line(line) for line in lines) if rec is not None]


def summarize_log(records: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """p50/p95 of every timing field, overall and per provider/model."""

    def block(items: Sequence[dict[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {
            "calls": len(items),
            "failed": sum(1 for r in items if not r.get("ok")),
        }
        for name in LOG_METRICS:
            values = [r[name] for r in items if isinstance(r.get(name), (int, float))]
            out[name] = asdict(Stat.of(values))
        return out

    groups: dict[str, list[dict[str, Any]]] = {}
    for rec in records:
        key = f"{rec.get('provider') or '-'} | {rec.get('model') or '-'}"
        groups.setdefault(key, []).append(rec)
    return {
        "overall": block(records),
        "by_model": {key: block(items) for key, items in sorted(groups.items())},
    }


def render_log_text(summary: dict[str, Any]) -> str:
    out = ["backend model calls (log)"]
    head = f"  {'key':<44} {'calls':>5} {'fail':>4}"
    for name in LOG_METRICS:
        head += f" {name.removesuffix('_ms') + ' p50/p95':>19}"
    out.append(head)
    rows = [("overall", summary["overall"]), *summary["by_model"].items()]
    for key, block in rows:
        line = f"  {_clip(key, 44):<44} {block['calls']:>5} {block['failed']:>4}"
        for name in LOG_METRICS:
            stat = block[name]
            line += f" {_ms(stat['p50']) + '/' + _ms(stat['p95']):>19}"
        out.append(line)
    return "\n".join(out)
