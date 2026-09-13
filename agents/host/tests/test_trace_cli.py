"""The ``trace`` subcommand and the ``--trace`` switch.

Two things are asserted that a reading of the code would not prove:

- ``trace`` never builds a host. It is driven through ``main()`` with a real
  temp trace directory and no relay, no port and no pairing — which is the
  whole point of the subcommand, since you reach for it when the host is the
  thing that is broken.
- Parsing alone must not turn tracing on. The tracer is process-wide state, so
  the fixture below puts the previous one back; a test that leaked a live
  ``JsonlTracer`` would make every later test in this suite write JSONL.
"""

from __future__ import annotations

import json

import pytest

from chuk_agents_host.cli import _build_parser, main, normalize_argv
from chuk_agents_runtime.trace import TRACE_FILENAME, get_tracer, set_tracer

WALL = 1_780_000_000.0


@pytest.fixture(autouse=True)
def restore_tracer():
    """No test may leave the process-wide tracer installed."""
    previous = set_tracer(None)
    try:
        yield
    finally:
        set_tracer(previous)


@pytest.fixture(autouse=True)
def no_trace_env(monkeypatch):
    """The environment must not decide what these tests assert."""
    for name in (
        "AGENTS_TRACE",
        "AGENTS_TRACE_CONTENT",
        "AGENTS_TRACE_DIR",
        "AGENTS_TRACE_MAX_BYTES",
        "AGENTS_TRACE_BACKUPS",
    ):
        monkeypatch.delenv(name, raising=False)


def _line(phase: str, *, t: float, run_id: str, round_no: int = 1, dt_ms: float = 0.0, **fields):
    return {
        "t": t,
        "wall": WALL + t,
        "run_id": run_id,
        "session_key": "sess-1",
        "round": round_no,
        "phase": phase,
        "dt_ms": dt_ms,
        **fields,
    }


def write_trace(directory, run_id: str = "run-abcd1234"):
    directory.mkdir(parents=True, exist_ok=True)
    rows = [
        _line("task_received", t=0.0, run_id=run_id),
        _line("ladder_pass", t=0.05, run_id=run_id, dt_ms=50.0, ms=50.0),
        _line("retry", t=1.05, run_id=run_id, dt_ms=1000.0, dead_ms=1000.0, reason="overloaded"),
        _line(
            "model_call",
            t=7.05,
            run_id=run_id,
            dt_ms=6000.0,
            connect_ms=100.0,
            first_frame_ms=4000.0,
            stream_ms=1800.0,
        ),
        _line("run_finished", t=8.0, run_id=run_id, round_no=2, dt_ms=950.0, reason="final_answer"),
    ]
    path = directory / TRACE_FILENAME
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return path


# --------------------------------------------------------------- the switch


def test_trace_flags_parse_on_run_and_connect():
    parser = _build_parser()
    args = parser.parse_args(
        ["run", "--trace", "--trace-dir", "/tmp/x", "--trace-max-bytes", "1024"]
    )
    assert args.trace is True
    assert args.trace_content is False
    assert args.trace_dir == "/tmp/x"
    assert args.trace_max_bytes == 1024

    connect = parser.parse_args(["connect", "--trace-content"])
    assert connect.trace_content is True
    assert connect.trace is False  # --trace-content implies it at configure time


def test_parsing_alone_leaves_tracing_off():
    """Building the parser must not install anything: off costs nothing."""
    _build_parser().parse_args(["run", "--trace"])
    assert get_tracer().enabled is False


def test_start_tracing_is_silent_when_off(capsys, tmp_path):
    from chuk_agents_host.cli import _start_tracing

    args = _build_parser().parse_args(["run", "--workspace", str(tmp_path)])
    _start_tracing(args)
    assert capsys.readouterr().out == ""
    assert get_tracer().enabled is False
    assert not (tmp_path / "trace").exists()


def test_start_tracing_names_the_file_and_the_content_switch(capsys, tmp_path):
    from chuk_agents_host.cli import _start_tracing

    args = _build_parser().parse_args(
        ["run", "--workspace", str(tmp_path), "--trace-content"]
    )
    _start_tracing(args)
    out = capsys.readouterr().out
    assert TRACE_FILENAME in out
    assert "content tracing ON" in out
    assert get_tracer().enabled is True


def test_trace_dir_flag_wins_over_the_workspace(capsys, tmp_path):
    from chuk_agents_host.cli import _start_tracing

    elsewhere = tmp_path / "somewhere-else"
    args = _build_parser().parse_args(
        ["run", "--workspace", str(tmp_path), "--trace", "--trace-dir", str(elsewhere)]
    )
    _start_tracing(args)
    assert str(elsewhere) in capsys.readouterr().out


# ----------------------------------------------------------- the subcommand


def test_trace_is_a_subcommand():
    assert normalize_argv(["trace"]) == ["trace"]
    assert normalize_argv(["trace", "--last"]) == ["trace", "--last"]


def test_list_shows_the_run(capsys, tmp_path):
    write_trace(tmp_path / "trace")
    code = main(["trace", "--list", "--workspace", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 0
    assert "run-abcd1234" in out
    assert "final_answer" in out
    assert "RUN" in out and "SPAN" in out


def test_no_arguments_behaves_like_list(capsys, tmp_path):
    write_trace(tmp_path / "trace")
    assert main(["trace", "--workspace", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "RUN" in out and "run-abcd1234" in out


def test_a_run_id_prefix_prints_the_waterfall(capsys, tmp_path):
    write_trace(tmp_path / "trace")
    code = main(["trace", "run-abcd", "--workspace", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 0
    assert "run run-abcd1234" in out
    assert "where the time went" in out
    assert "provider_wait" in out
    assert "timeline" in out
    assert "round 1" in out


def test_last_picks_the_newest_run(capsys, tmp_path):
    directory = tmp_path / "trace"
    write_trace(directory, "run-oldone")
    path = directory / TRACE_FILENAME
    newer = [
        json.dumps(
            {
                "t": 0.0,
                "wall": WALL + 900.0,
                "run_id": "run-newone",
                "session_key": "sess-2",
                "round": 1,
                "phase": "task_received",
                "dt_ms": 0.0,
            }
        ),
        json.dumps(
            {
                "t": 3.0,
                "wall": WALL + 903.0,
                "run_id": "run-newone",
                "session_key": "sess-2",
                "round": 1,
                "phase": "run_finished",
                "dt_ms": 3000.0,
                "reason": "final_answer",
            }
        ),
    ]
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(newer) + "\n")

    assert main(["trace", "--last", "--workspace", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "run run-newone" in out
    assert "run-oldone" not in out


def test_trace_dir_may_point_anywhere(capsys, tmp_path):
    directory = tmp_path / "elsewhere"
    write_trace(directory)
    assert main(["trace", "--last", "--trace-dir", str(directory)]) == 0
    assert "run run-abcd1234" in capsys.readouterr().out


def test_missing_trace_file_explains_how_to_turn_it_on(capsys, tmp_path):
    code = main(["trace", "--list", "--workspace", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 1
    assert "cowork-host run --trace" in out
    assert "AGENTS_TRACE=1" in out


def test_unknown_run_id_is_an_error_not_an_empty_report(capsys, tmp_path):
    write_trace(tmp_path / "trace")
    code = main(["trace", "run-zzzz", "--workspace", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 1
    assert "run-zzzz" in out
    assert "--list" in out


def test_trace_never_builds_a_host(monkeypatch, capsys, tmp_path):
    """The subcommand must work on a machine where the host cannot start."""
    import chuk_agents_host.cli as cli_module

    def explode(*_args, **_kwargs):
        raise AssertionError("cmd_trace must not build a host")

    monkeypatch.setattr(cli_module, "_build_host", explode)
    write_trace(tmp_path / "trace")
    assert main(["trace", "--last", "--workspace", str(tmp_path)]) == 0
    assert "run run-abcd1234" in capsys.readouterr().out
