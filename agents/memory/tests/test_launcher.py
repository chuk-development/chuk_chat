"""The sidecar launcher: loopback only, a per-install database password, HOME
under the state directory, no ``.env`` walk, and it stops with its parent."""

from __future__ import annotations

import os
import signal
import stat
import subprocess
import sys
import time

import pytest

from chuk_agents_memory import launcher


def test_it_binds_loopback_only():
    args = launcher.parse_args(["--state-dir", "/x", "--port", "9"])
    assert args.host == "127.0.0.1" and args.port == 9
    with pytest.raises(SystemExit):
        launcher.parse_args(["--state-dir", "/x", "--port", "9", "--host", "0.0.0.0"])


def test_the_database_password_is_minted_once_and_private(tmp_path):
    first = launcher.pg_password(tmp_path)
    assert len(first) >= 24
    assert launcher.pg_password(tmp_path) == first
    mode = stat.S_IMODE((tmp_path / "pg0.secret").stat().st_mode)
    assert mode == 0o600


def test_home_moves_under_the_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", "/somewhere/else")
    monkeypatch.delenv("LITELLM_LOCAL_MODEL_COST_MAP", raising=False)
    launcher.prepare_environment(tmp_path)
    assert os.environ["HOME"] == str(tmp_path / "home")
    assert (tmp_path / "home").is_dir()
    assert os.environ["LITELLM_LOCAL_MODEL_COST_MAP"] == "True"


def test_run_hindsight_turns_off_the_dotenv_walk(monkeypatch):
    import hindsight_api.main as hindsight_main

    seen: dict = {}

    def fake_main():
        seen["argv"] = list(sys.argv)
        seen["dotenv"] = hindsight_main.load_dotenv_for_entrypoint()

    monkeypatch.setattr(hindsight_main, "main", fake_main)
    monkeypatch.setattr(sys, "argv", ["x"])
    launcher.run_hindsight("127.0.0.1", 4321, "warning")
    assert seen["argv"][:5] == ["hindsight-api", "--host", "127.0.0.1", "--port", "4321"]
    assert "--no-access-log" in seen["argv"]
    assert seen["dotenv"] is None


def test_it_stops_when_the_parent_is_gone():
    # A child python whose "parent" is a short sleep: when the sleep ends, the
    # watch thread must SIGTERM the child, and the SystemExit handler exits 0.
    sleeper = subprocess.Popen(["sleep", "0.5"])
    code = (
        "import signal, sys, time\n"
        "from chuk_agents_memory import launcher\n"
        "signal.signal(signal.SIGTERM, launcher._terminate)\n"
        f"launcher.watch_parent({sleeper.pid}, poll=0.1)\n"
        "time.sleep(20)\n"
        "sys.exit(7)\n"
    )
    started = time.monotonic()
    child = subprocess.run([sys.executable, "-c", code], timeout=30)
    sleeper.wait()
    assert child.returncode == 0
    assert time.monotonic() - started < 10


def test_terminate_handler_raises_system_exit():
    with pytest.raises(SystemExit):
        launcher._terminate(signal.SIGTERM, None)


def test_one_sidecar_per_state_dir(tmp_path):
    first = launcher.acquire_instance_lock(tmp_path)
    assert first is not None
    code = (
        "import sys; from pathlib import Path; from chuk_agents_memory import launcher; "
        f"sys.exit(0 if launcher.acquire_instance_lock(Path({str(tmp_path)!r})) is None else 1)"
    )
    assert subprocess.run([sys.executable, "-c", code]).returncode == 0
    os.close(first)
    assert subprocess.run([sys.executable, "-c", code]).returncode == 1


def test_a_locked_state_dir_exits_with_the_locked_code(tmp_path, monkeypatch):
    held = launcher.acquire_instance_lock(tmp_path)
    try:
        code = (
            "import sys; from chuk_agents_memory import launcher; "
            f"sys.exit(launcher.main(['--state-dir', {str(tmp_path)!r}, '--port', '9']))"
        )
        assert subprocess.run([sys.executable, "-c", code]).returncode == launcher.EXIT_LOCKED
    finally:
        os.close(held)


class _FakePg:
    def __init__(self):
        self.stopped = False

    def stop(self):
        self.stopped = True


@pytest.mark.parametrize("adopted", [True, False])
def test_an_adopted_postgres_is_never_stopped(tmp_path, monkeypatch, adopted):
    pg = _FakePg()
    monkeypatch.setattr(launcher, "start_postgres", lambda state_dir: (pg, "postgresql://x", adopted))
    monkeypatch.setattr(launcher, "prepare_environment", lambda state_dir: None)

    def fake_run(*a, **k):
        raise SystemExit(0)

    monkeypatch.setattr(launcher, "run_hindsight", fake_run)
    monkeypatch.chdir(tmp_path)
    assert launcher.main(["--state-dir", str(tmp_path), "--port", "9"]) == 0
    assert pg.stopped is (not adopted)


def test_log_records_are_redacted_except_safe_loggers(tmp_path):
    import logging

    log_file = tmp_path / "sidecar.log"
    launcher.install_logging(str(log_file), "info")
    root = logging.getLogger()
    handler = root.handlers[0]
    assert isinstance(handler, logging.handlers.RotatingFileHandler)
    assert handler.maxBytes == 5 * 1024 * 1024 and handler.backupCount == 3
    logging.getLogger("hindsight_api.engine.providers.openai_compatible_llm").error(
        "JSON parse error: %s", "the user's secret plans"
    )
    try:
        raise ValueError("memory text inside an exception")
    except ValueError:
        logging.getLogger("hindsight_api.api.http").exception("failed on %s", "private content")
    logging.getLogger("hindsight.db.pool").warning("slow DB pool acquire: waited 1.5s")
    handler.flush()
    text = log_file.read_text()
    assert "secret plans" not in text and "private content" not in text
    assert "memory text inside" not in text
    assert "message withheld" in text and "exception ValueError" in text
    assert "slow DB pool acquire" in text
    assert logging.getLogger("litellm").level == logging.ERROR
    for h in root.handlers[:]:
        root.removeHandler(h)


def test_postgres_is_told_not_to_log_statements():
    assert launcher.PG_CONFIG["log_min_error_statement"] == "panic"
