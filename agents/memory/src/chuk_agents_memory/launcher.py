"""The Hindsight memory sidecar: embedded Postgres (pg0) plus the Hindsight API.

The Agents host starts this process once per machine (see
``chuk_agents_runtime.hindsight_service``). It runs in its own virtual
environment, because Hindsight pulls a large dependency tree (litellm, boto3,
google-genai, fastmcp, ...) that must not share a resolver with the host.

What this launcher adds on top of ``hindsight-api``:

* **The data stays under the state directory.** Hindsight's own pg0 wrapper has
  no data-dir option, so the launcher starts pg0 itself with
  ``--data-dir <state_dir>/pg0`` and hands Hindsight a plain ``postgresql://``
  URL. ``HOME`` is pointed at ``<state_dir>/home`` too, so pg0's instance
  registry and its extracted PostgreSQL binaries, and anything else Hindsight
  writes under ``~``, stay out of the user's home directory. The state
  directory is never inside an agent workspace, so no sandbox container mounts
  it.
* **A per-install database password.** pg0 binds loopback only, but a fixed
  ``postgres/postgres`` would still be readable by any local process. A random
  password is minted on the first start and kept at ``<state_dir>/pg0.secret``
  (mode 0600).
* **No ``.env`` discovery.** ``hindsight-api`` walks up from the working
  directory for a ``.env`` and applies it with ``override=True``. A stray
  ``.env`` in a parent directory could silently replace the configuration the
  host passed, so the walk is switched off here.
* **It dies with its parent.** ``--parent-pid`` makes the launcher stop (and
  stop pg0) when the host process is gone, so a crashed host never leaves an
  orphaned database holding the data directory.
* **One sidecar per state directory.** An ``flock`` on ``sidecar.lock`` is
  held for the launcher's whole life; a second launcher exits at once
  (code 75). A Postgres left running by a crashed launcher is adopted, and an
  adopted instance is never stopped by this launcher.
* **No memory content in the logs.** Python logging goes to a rotating
  ``--log-file`` (5 MB x 3). Only an allowlist of known-safe loggers keeps its
  message text; every other record (Hindsight's engine logs LLM output on a
  parse error, litellm, openai, httpx) is reduced to logger, level and
  exception type. Postgres is told not to log failing statements.

Everything else is configured by the host through ``HINDSIGHT_API_*``
environment variables.
"""

from __future__ import annotations

import argparse
import fcntl
import logging
import logging.handlers
import os
import secrets
import signal
import sys
import threading
import time
from pathlib import Path

logger = logging.getLogger("chuk_agents_memory")

#: The pg0 instance name. One instance per state directory.
PG_INSTANCE = "chuk-agents-memory"
#: Small on purpose: one person's memory, not a shared database server. pg0's
#: own defaults are sized for development machines (256 MB shared buffers).
PG_CONFIG = {
    "shared_buffers": "64MB",
    "max_connections": "40",
    "maintenance_work_mem": "64MB",
    # A failing statement would carry memory text into the Postgres log.
    "log_min_error_statement": "panic",
    "log_rotation_size": "5MB",
}
PARENT_POLL_SECONDS = 2.0
LOCK_NAME = "sidecar.lock"
EXIT_LOCKED = 75
LOG_MAX_BYTES = 5 * 1024 * 1024
LOG_BACKUPS = 3
#: Loggers whose messages never carry memory content (pool, watchdog, our own).
SAFE_LOGGERS = (
    "chuk_agents_memory",
    "hindsight.db.pool",
    "hindsight.loop_watchdog",
)
#: Loggers turned down to ERROR on top of the redaction.
QUIET_LOGGERS = ("hindsight_api.engine", "litellm", "LiteLLM", "openai", "httpx", "httpcore")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="chuk-agents-memory",
        description="Hindsight memory sidecar for the Agents host.",
    )
    parser.add_argument("--state-dir", required=True, help="The sidecar's own directory.")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (loopback only).")
    parser.add_argument("--port", type=int, required=True, help="Port of the Hindsight API.")
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=None,
        help="Stop when this process is gone (the Agents host).",
    )
    parser.add_argument("--log-level", default="warning")
    parser.add_argument("--log-file", default=None, help="Rotating log file (content withheld).")
    args = parser.parse_args(argv)
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("the memory sidecar binds loopback only")
    return args


def pg_password(state_dir: Path) -> str:
    """The database password for this state directory, minted once."""
    path = state_dir / "pg0.secret"
    try:
        value = path.read_text(encoding="utf-8").strip()
        if value:
            return value
    except FileNotFoundError:
        pass
    value = secrets.token_urlsafe(24)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(value)
    return value


def prepare_environment(state_dir: Path) -> None:
    """Point everything the sidecar writes under ``~`` at the state directory."""
    home = state_dir / "home"
    home.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(home)
    # litellm fetches its model price map from GitHub at import unless told not
    # to. Nothing but the host's own gateway may be reached from here.
    os.environ.setdefault("LITELLM_LOCAL_MODEL_COST_MAP", "True")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")


def acquire_instance_lock(state_dir: Path) -> int | None:
    """Hold ``sidecar.lock`` for the process lifetime. ``None``: another
    launcher owns this state directory."""
    fd = os.open(state_dir / LOCK_NAME, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    return fd


class RedactingFilter(logging.Filter):
    """Keep message text only for :data:`SAFE_LOGGERS`; everything else is
    reduced to logger, level and exception type."""

    def filter(self, record: logging.LogRecord) -> bool:
        name = record.name
        if any(name == safe or name.startswith(safe + ".") for safe in SAFE_LOGGERS):
            return True
        exc = record.exc_info[0].__name__ if record.exc_info and record.exc_info[0] else None
        record.msg = "message withheld (may contain memory content)" + (
            f"; exception {exc}" if exc else ""
        )
        record.args = ()
        record.exc_info = None
        record.exc_text = None
        record.stack_info = None
        return True


def install_logging(log_file: str | None, level: str = "warning") -> None:
    """Route all Python logging to a rotating file through the redaction
    filter. Called again after Hindsight configured its own handler."""
    root = logging.getLogger()
    for handler in root.handlers[:]:
        root.removeHandler(handler)
    if log_file:
        handler: logging.Handler = logging.handlers.RotatingFileHandler(
            log_file, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUPS, encoding="utf-8"
        )
    else:
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    handler.addFilter(RedactingFilter())
    root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.WARNING))
    for name in QUIET_LOGGERS:
        logging.getLogger(name).setLevel(logging.ERROR)


def start_postgres(state_dir: Path):
    """Start (or adopt) the pg0 instance. Returns ``(pg, uri, adopted)``."""
    from pg0 import Pg0, Pg0AlreadyRunningError

    data_dir = state_dir / "pg0"
    data_dir.parent.mkdir(parents=True, exist_ok=True)
    pg = Pg0(
        name=PG_INSTANCE,
        username="hindsight",
        password=pg_password(state_dir),
        database="hindsight",
        data_dir=str(data_dir),
        config=dict(PG_CONFIG),
    )
    adopted = False
    try:
        info = pg.start()
    except Pg0AlreadyRunningError:
        # Left running by a launcher that died (this process holds the
        # instance lock, so no live launcher owns it). Adopt it, and never
        # stop it from here: this launcher did not start it.
        info = pg.info()
        adopted = True
    uri = getattr(info, "uri", None) or pg.uri
    if not uri:
        raise RuntimeError("pg0 started but reported no connection URI")
    return pg, uri, adopted


def watch_parent(parent_pid: int, *, poll: float = PARENT_POLL_SECONDS) -> threading.Thread:
    """Send ourselves SIGTERM when ``parent_pid`` is gone (or re-parented)."""

    def alive() -> bool:
        # Liveness only, not ``os.getppid()``: under ``uv run`` the direct
        # parent is uv, not the host.
        try:
            os.kill(parent_pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        # A zombie still answers signal 0; on Linux its state says it is dead.
        try:
            with open(f"/proc/{parent_pid}/stat", encoding="ascii", errors="replace") as handle:
                state = handle.read().rsplit(")", 1)[-1].split()[0]
            return state not in ("Z", "X")
        except (OSError, IndexError):
            return True

    def run() -> None:
        while alive():
            time.sleep(poll)
        logger.warning("parent %s is gone; stopping the memory sidecar", parent_pid)
        os.kill(os.getpid(), signal.SIGTERM)

    thread = threading.Thread(target=run, name="parent-watch", daemon=True)
    thread.start()
    return thread


def run_hindsight(host: str, port: int, log_level: str, log_file: str | None = None) -> None:
    """Run the Hindsight API in the foreground until it is told to stop."""
    import hindsight_api.config as hindsight_config
    import hindsight_api.main as hindsight_main

    # See the module docstring: no upward `.env` walk with override=True.
    hindsight_main.load_dotenv_for_entrypoint = lambda: None
    # Hindsight replaces the root handlers with a stdout handler; put the
    # rotating, redacting one back right after it.
    original = hindsight_config.HindsightConfig.configure_logging

    def configure_logging(self) -> None:
        original(self)
        install_logging(log_file, log_level)

    hindsight_config.HindsightConfig.configure_logging = configure_logging
    sys.argv = [
        "hindsight-api",
        "--host",
        host,
        "--port",
        str(port),
        "--log-level",
        log_level,
        "--no-access-log",
    ]
    hindsight_main.main()


def _terminate(signum, frame) -> None:  # noqa: ARG001 — signal handler shape
    """SIGTERM before Hindsight installs its own handler: raise, so the
    ``finally`` in :func:`main` still stops pg0. (The default action would kill
    the process on the spot and orphan the database.)"""
    raise SystemExit(0)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    signal.signal(signal.SIGTERM, _terminate)
    state_dir = Path(args.state_dir).expanduser().resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    install_logging(args.log_file, "info")
    lock_fd = acquire_instance_lock(state_dir)
    if lock_fd is None:
        logger.error("another memory sidecar owns %s; exiting", state_dir)
        return EXIT_LOCKED
    prepare_environment(state_dir)
    os.chdir(state_dir)

    # Everything from the Postgres start on is inside the try: a SIGTERM
    # during startup still stops a Postgres this launcher started.
    pg = None
    adopted = False
    try:
        started = time.monotonic()
        pg, uri, adopted = start_postgres(state_dir)
        logger.info("pg0 %s in %.1fs", "adopted" if adopted else "ready", time.monotonic() - started)
        os.environ["HINDSIGHT_API_DATABASE_URL"] = uri
        if args.parent_pid:
            watch_parent(args.parent_pid)
        run_hindsight(args.host, args.port, args.log_level, args.log_file)
    except SystemExit as exc:
        return int(exc.code or 0) if isinstance(exc.code, int) else 0
    finally:
        if pg is not None and not adopted:
            try:
                pg.stop()
            except Exception:  # noqa: BLE001 — shutdown must finish
                logger.warning("pg0 stop failed", exc_info=True)
        os.close(lock_fd)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
