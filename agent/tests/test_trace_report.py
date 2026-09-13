"""The trace reader: rotation, prefix lookup, buckets, and the printed report.

Every timestamp here is a literal. A test that slept to make a duration would
be slow and flaky, and it would prove nothing the trace does not already write
down: the tracer stamps the numbers, so the reader must be driven with numbers.
"""

from __future__ import annotations

import json

from chuk_agents_runtime.trace import TRACE_FILENAME
from chuk_agents_runtime.trace_report import (
    attribution,
    list_runs,
    read_lines,
    span_ms,
    waterfall,
)

WALL = 1_780_000_000.0


def line(
    phase: str,
    *,
    t: float,
    run_id: str = "run-aaaa1111",
    session: str = "sess-1",
    round_no: int = 1,
    dt_ms: float = 0.0,
    **fields,
) -> dict:
    return {
        "t": t,
        "wall": WALL + t,
        "run_id": run_id,
        "session_key": session,
        "round": round_no,
        "phase": phase,
        "dt_ms": dt_ms,
        **fields,
    }


def write(path, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def a_run(run_id: str = "run-aaaa1111") -> list[dict]:
    """A realistic slow turn: the provider took most of it, one retry died."""
    return [
        line("task_received", t=0.0, run_id=run_id),
        line("round_start", t=0.01, run_id=run_id, dt_ms=10.0),
        line("ladder_pass", t=0.05, run_id=run_id, dt_ms=40.0, ms=40.0),
        line("payload_prepared", t=0.08, run_id=run_id, dt_ms=30.0, ms=30.0, messages=12),
        line("retry", t=1.10, run_id=run_id, dt_ms=1020.0, dead_ms=1000.0, reason="overloaded"),
        line(
            "model_call",
            t=9.00,
            run_id=run_id,
            dt_ms=7900.0,
            connect_ms=120.0,
            auth_ms=30.0,
            first_frame_ms=5000.0,
            stream_ms=2500.0,
            prepare_ms=70.0,
            server={"queue_ms": 400.0, "prefill_ms": 900.0},
        ),
        line("usage", t=9.01, run_id=run_id, dt_ms=10.0, prompt_tokens=1200, completion_tokens=300),
        line("tool_start", t=9.02, run_id=run_id, round_no=2, dt_ms=10.0, tool="run_command"),
        line("tool_end", t=10.52, run_id=run_id, round_no=2, dt_ms=1500.0, ms=1500.0, tool="run_command"),
        line("run_finished", t=12.00, run_id=run_id, round_no=2, dt_ms=1480.0, reason="final_answer"),
    ]


# ----------------------------------------------------------------- reading


def test_rotated_files_are_read_oldest_first(tmp_path):
    """A run that straddles a rotation must come back whole, and in order."""
    live = tmp_path / TRACE_FILENAME
    write(live.with_suffix(live.suffix + ".2"), [line("task_received", t=0.0)])
    write(live.with_suffix(live.suffix + ".1"), [line("round_start", t=0.01)])
    write(live, [line("run_finished", t=1.0, reason="final_answer")])

    phases = [row["phase"] for row in read_lines(tmp_path)]
    assert phases == ["task_received", "round_start", "run_finished"]


def test_source_may_be_the_file_itself(tmp_path):
    live = tmp_path / TRACE_FILENAME
    write(live, a_run())
    assert len(read_lines(live)) == len(read_lines(tmp_path))


def test_unparseable_lines_are_skipped(tmp_path):
    live = tmp_path / TRACE_FILENAME
    live.write_text(
        json.dumps(line("task_received", t=0.0)) + "\n"
        + "{ this is not json\n"
        + "\n"
        + "[1, 2, 3]\n"
        + json.dumps(line("run_finished", t=1.0)) + "\n",
        encoding="utf-8",
    )
    assert [row["phase"] for row in read_lines(live)] == ["task_received", "run_finished"]


def test_run_id_prefix_filters(tmp_path):
    live = tmp_path / TRACE_FILENAME
    write(live, [*a_run("run-aaaa1111"), *a_run("run-bbbb2222")])

    assert len(read_lines(live)) == 20
    picked = read_lines(live, run_id="run-aaaa")
    assert len(picked) == 10
    assert {row["run_id"] for row in picked} == {"run-aaaa1111"}
    assert read_lines(live, run_id="run-zzzz") == []


def test_missing_file_reads_as_empty(tmp_path):
    assert read_lines(tmp_path / "nope") == []


# ------------------------------------------------------------------- runs


def test_list_runs_is_newest_first_with_a_summary(tmp_path):
    live = tmp_path / TRACE_FILENAME
    older = [dict(row, wall=row["wall"] - 600.0) for row in a_run("run-old")]
    write(live, [*older, *a_run("run-new")])

    runs = list_runs(live)
    assert [row["run_id"] for row in runs] == ["run-new", "run-old"]
    newest = runs[0]
    assert newest["session_key"] == "sess-1"
    assert newest["reason"] == "final_answer"
    assert newest["rounds"] == 2
    assert newest["lines"] == 10
    assert abs(newest["total_ms"] - 12000.0) < 1.0


def test_lines_outside_a_run_do_not_become_a_run(tmp_path):
    live = tmp_path / TRACE_FILENAME
    write(live, [*a_run(), line("task_received", t=0.0, run_id="")])
    assert [row["run_id"] for row in list_runs(live)] == ["run-aaaa1111"]


# ------------------------------------------------------------ attribution


def test_buckets_add_up_to_the_span():
    shares = attribution(a_run())
    assert shares["prepare"] == 70.0          # ladder 40 + payload 30
    assert shares["connect"] == 150.0         # connect 120 + auth 30
    assert shares["provider_wait"] == 5000.0
    assert shares["provider_stream"] == 2500.0
    assert shares["tools"] == 1500.0
    assert shares["retries"] == 1000.0
    assert shares["memory_recall"] == 0.0
    assert shares["retries_count"] == 1
    assert shares["model_calls"] == 1
    assert shares["tokens"] == {"prompt": 1200, "completion": 300, "total": 1500}
    assert shares["server"] == {"queue_ms": 400.0, "prefill_ms": 900.0}

    named = sum(shares[name] for name in ("prepare", "connect", "provider_wait",
                                          "provider_stream", "tools", "memory_recall",
                                          "retries", "unattributed"))
    assert abs(named - shares["total_ms"]) < 1.0
    assert abs(shares["total_ms"] - span_ms(a_run())) < 0.001


def test_prepare_falls_back_to_the_model_call_when_no_phase_measured_it():
    rows = [row for row in a_run() if row["phase"] not in ("ladder_pass", "payload_prepared")]
    assert attribution(rows)["prepare"] == 70.0


def test_unattributed_never_goes_negative():
    """Overlapping measurements must not print a negative bucket."""
    rows = [
        line("task_received", t=0.0),
        line("model_call", t=0.5, dt_ms=500.0, first_frame_ms=9000.0, stream_ms=9000.0),
        line("run_finished", t=1.0, dt_ms=500.0, reason="final_answer"),
    ]
    shares = attribution(rows)
    assert shares["unattributed"] == 0.0
    assert shares["total_ms"] > 0


def test_memory_recall_is_its_own_bucket():
    rows = [
        line("task_received", t=0.0),
        line("memory_recall_end", t=2.0, dt_ms=2000.0, ms=2000.0, hits=3),
        line("run_finished", t=3.0, dt_ms=1000.0, reason="final_answer"),
    ]
    assert attribution(rows)["memory_recall"] == 2000.0


def test_server_blocks_of_several_calls_are_merged():
    rows = [
        line("model_call", t=1.0, server={"queue_ms": 100.0}),
        line("model_call", t=2.0, server={"queue_ms": 250.0, "prefill_ms": 40.0}),
    ]
    assert attribution(rows)["server"] == {"queue_ms": 350.0, "prefill_ms": 40.0}


def test_empty_run_attributes_nothing():
    shares = attribution([])
    assert shares["total_ms"] == 0.0
    assert shares["unattributed"] == 0.0


# -------------------------------------------------------------- waterfall


def test_waterfall_leads_with_the_biggest_bucket():
    text = waterfall(a_run())
    lines = text.splitlines()
    assert "run-aaaa1111" in lines[0]

    body = [row for row in lines if row.strip().startswith(("prepare", "connect", "provider_",
                                                            "tools", "memory_recall", "retries",
                                                            "unattributed"))]
    assert body[0].strip().startswith("provider_wait")   # the slow segment, first
    assert "provider_wait" in text
    assert "%" in body[0] and "#" in body[0]


def test_waterfall_groups_by_round_and_marks_retries():
    text = waterfall(a_run())
    assert "round 1" in text
    assert "round 2" in text
    retry_lines = [row for row in text.splitlines() if "retry" in row and "dead_ms" in row]
    assert retry_lines and retry_lines[0].lstrip().startswith("!")


def test_waterfall_is_plain_ascii_and_fits_a_hundred_columns():
    text = waterfall(a_run())
    assert text.isascii()
    assert max(len(row) for row in text.splitlines()) <= 100


def test_waterfall_says_so_when_there_is_nothing():
    assert "no trace lines" in waterfall([])
