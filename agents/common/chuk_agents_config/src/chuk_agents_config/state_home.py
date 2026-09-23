"""Where the host keeps its state, and the one-time move that puts it there.

The host state is the device seed (``host_device.key``), the pairing
(``paired.json``), the account token (``account.json``), the encrypted vault
(``secrets.enc``), the roster and executor databases and the agent workspaces.
If any of it is lost, every paired phone must pair again.

**Why not ``~/.agents``.** After the rename the default was ``~/.agents``. That
directory is not ours: the ``skills`` CLI keeps ``~/.agents/skills`` and
``~/.agents/.skill-lock.json`` there, and other agent tools use it too. The old
migration moved ``~/.cowork`` only when ``~/.agents`` did not exist, so on a
machine with skills installed it never ran. The host then started with a fresh
identity and no pairing, and the pairing looked lost.

**The decision.** The state lives in a directory that only this product writes:
``$XDG_DATA_HOME/chuk-agents``, which is ``~/.local/share/chuk-agents`` when
``XDG_DATA_HOME`` is not set. It is *data*, not *state* in the XDG sense:
``XDG_STATE_HOME`` is for things that may be lost (logs, history), and losing
this directory loses the pairing and the user's agent workspaces. The Flutter
app keeps its own data next to it, in ``~/.local/share/dev.chuk.cowork``.

``$AGENTS_HOME`` (and the pre-rename ``$COWORK_HOME``) still move the directory.
An explicit path is used as given, and it is never migrated into.

**The move.** :func:`migrate_state_home` runs once, before anything reads the
state. It looks for a host state in ``~/.cowork`` and at the top level of
``~/.agents`` (left there by a run of the renamed code). A directory counts as a
host state only if it holds one of :data:`IDENTITY_FILES`; an empty directory or
a ``skills/`` folder does not count. When there are two, the one with
``paired.json`` wins. The move never overwrites a file, never touches anything
in ``~/.agents`` that is not a known host file, and it can resume after a crash.
"""

from __future__ import annotations

import contextlib
import errno
import logging
import os
import shutil
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass, field
from pathlib import Path

__all__ = [
    "HOME_ENV",
    "IDENTITY_FILES",
    "LEGACY_HOME_ENV",
    "MIGRATION_MARKER",
    "MOVED_NOTE",
    "STATE_DIRNAME",
    "STATE_ENTRIES",
    "MigrationReport",
    "default_state_home",
    "has_host_state",
    "locate_state_home",
    "migrate_state_home",
    "resolve_state_home",
]

_LOG = logging.getLogger("chuk_agents.state_home")

#: The environment variable that moves the state directory.
HOME_ENV = "AGENTS_HOME"
#: Its pre-rename spelling, read after it.
LEGACY_HOME_ENV = "COWORK_HOME"  # rename: keep

#: The directory name under ``$XDG_DATA_HOME``.
STATE_DIRNAME = "chuk-agents"

#: The pre-rename state directory. Only this product ever wrote it, so all of
#: its content is moved.
LEGACY_OWNED_NAME = ".cowork"  # rename: keep
#: The post-rename state directory. It is shared with other tools, so only the
#: entries in :data:`STATE_ENTRIES` are moved out of it.
LEGACY_SHARED_NAME = ".agents"

#: A directory holds a host state when it holds one of these. Directories such
#: as ``agents/`` or ``logs/`` do not count: an installer may create them empty.
IDENTITY_FILES = (
    "paired.json",
    "host_device.key",
    "account.json",
    "secrets.enc",
    "roster.db",
    "executor-state.db",
    "rooms.db",
)

#: Every top-level entry the host writes. From a shared directory, only these
#: are moved. ``skills/`` and ``.skill-lock.json`` belong to the ``skills`` CLI
#: and are never in this list.
_SQLITE_FILES = ("roster.db", "executor-state.db", "rooms.db", "room-transcript.db")
STATE_ENTRIES = (
    "paired.json",
    "host_device.key",
    "account.json",
    "secrets.enc",
    "config.toml",
    "ESTOP",
    "host.log",
    "agents",
    "room-agents",
    "logs",
    "trace",
    *(
        name + suffix
        for name in _SQLITE_FILES
        for suffix in ("", "-wal", "-shm", "-journal")
    ),
)

#: Written into the target while a move runs. It names the source, so a move
#: that was interrupted is finished on the next start.
MIGRATION_MARKER = ".migrating-from"
#: Left in ``~/.agents`` after its host files moved out.
MOVED_NOTE = "CHUK_AGENTS_STATE_MOVED.txt"

Logger = Callable[[str], None]


def _home(environ: Mapping[str, str]) -> Path:
    raw = (environ.get("HOME") or "").strip()
    return Path(raw) if raw else Path.home()


def _expand(raw: str, environ: Mapping[str, str]) -> Path:
    if raw == "~":
        return _home(environ)
    if raw.startswith("~/"):
        return _home(environ) / raw[2:]
    return Path(raw).expanduser()


def _env_home(environ: Mapping[str, str]) -> Path | None:
    raw = (environ.get(HOME_ENV) or "").strip()
    if not raw:
        raw = (environ.get(LEGACY_HOME_ENV) or "").strip()
    return _expand(raw, environ) if raw else None


def _xdg_default(environ: Mapping[str, str]) -> Path:
    data = (environ.get("XDG_DATA_HOME") or "").strip()
    # The XDG spec says a relative value is invalid and must be ignored.
    base = Path(data) if data and os.path.isabs(data) else _home(environ) / ".local" / "share"
    return base / STATE_DIRNAME


def default_state_home(environ: Mapping[str, str] | None = None) -> Path:
    """The state directory, without touching the disk.

    ``$AGENTS_HOME``, else ``$COWORK_HOME``, else
    ``$XDG_DATA_HOME/chuk-agents`` (``~/.local/share/chuk-agents``).
    """
    env = os.environ if environ is None else environ
    return _env_home(env) or _xdg_default(env)


def has_host_state(path: Path) -> bool:
    """True when ``path`` holds a host identity, a pairing or a database."""
    try:
        return any((path / name).is_file() for name in IDENTITY_FILES)
    except OSError:
        return False


# -- candidates --------------------------------------------------------------


@dataclass(frozen=True)
class _Candidate:
    #: The path as the user knows it (``~/.cowork`` or ``~/.agents``).
    path: Path
    #: Where it really is, after symlinks.
    real: Path
    #: True when every entry is ours (``~/.cowork``); False for a shared dir.
    owned: bool
    order: int

    @property
    def paired(self) -> bool:
        return (self.real / "paired.json").is_file()

    def rank(self) -> tuple:
        paired = self.real / "paired.json"
        try:
            paired_mtime = paired.stat().st_mtime if paired.is_file() else 0.0
        except OSError:
            paired_mtime = 0.0
        return (
            self.paired,
            paired_mtime,
            (self.real / "account.json").is_file(),
            (self.real / "host_device.key").is_file(),
            -self.order,
        )


def _candidates(home: Path, target: Path) -> list[_Candidate]:
    try:
        target_real = target.resolve()
    except OSError:
        target_real = target
    shared_real = (home / LEGACY_SHARED_NAME).resolve()
    seen: dict[Path, _Candidate] = {}
    for order, name in enumerate((LEGACY_OWNED_NAME, LEGACY_SHARED_NAME)):
        path = home / name
        try:
            if not path.is_dir():
                continue
            real = path.resolve()
        except OSError:
            continue
        if real == target_real or real in seen:
            continue
        # A ``~/.cowork`` that is a symlink into ``~/.agents`` (the old
        # migration left one) is the shared directory, not an owned one.
        owned = name == LEGACY_OWNED_NAME and not path.is_symlink() and real != shared_real
        if not has_host_state(real):
            continue
        seen[real] = _Candidate(path=path, real=real, owned=owned, order=order)
    return list(seen.values())


def _best(candidates: list[_Candidate]) -> _Candidate | None:
    if not candidates:
        return None
    return max(candidates, key=lambda c: c.rank())


# -- resolving ---------------------------------------------------------------


def locate_state_home(
    explicit: str | os.PathLike[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> Path:
    """Where the state is **now**, without moving anything.

    For read-only commands (``status``, ``doctor``): an explicit path or
    ``$AGENTS_HOME`` as given; else the default directory when it holds a
    state; else the legacy directory the next host start will move from;
    else the default directory.
    """
    env = os.environ if environ is None else environ
    if explicit:
        return _expand(os.fspath(explicit), env)
    from_env = _env_home(env)
    if from_env is not None:
        return from_env
    target = _xdg_default(env)
    if has_host_state(target) and not (target / MIGRATION_MARKER).exists():
        return target
    best = _best(_candidates(_home(env), target))
    return best.real if best is not None else target


def resolve_state_home(
    explicit: str | os.PathLike[str] | None = None,
    environ: Mapping[str, str] | None = None,
    *,
    migrate: bool = True,
    logger: Logger | None = None,
) -> Path:
    """The state directory for a process that owns the state (``run``,
    ``connect``, :class:`LocalHost`).

    An explicit path or ``$AGENTS_HOME``/``$COWORK_HOME`` is used as given.
    Only the default directory is migrated into, and only when ``migrate``.
    """
    env = os.environ if environ is None else environ
    if explicit:
        return _expand(os.fspath(explicit), env)
    from_env = _env_home(env)
    if from_env is not None:
        return from_env
    target = _xdg_default(env)
    if migrate:
        migrate_state_home(target, home=_home(env), logger=logger)
    return target


# -- the move ----------------------------------------------------------------


@dataclass
class MigrationReport:
    """What :func:`migrate_state_home` did. Mainly for tests and logs."""

    target: Path
    source: Path | None = None
    moved: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    left_in_place: list[Path] = field(default_factory=list)


@contextlib.contextmanager
def _lock(parent: Path) -> Iterator[None]:
    """Serialise two processes that start at the same moment."""
    try:
        import fcntl
    except ImportError:  # pragma: no cover - not POSIX
        yield
        return
    parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(parent / f".{STATE_DIRNAME}.migrate.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _say(logger: Logger | None, message: str) -> None:
    _LOG.warning(message)
    if logger is not None:
        logger(message)


def _move_entry(src: Path, dst: Path) -> None:
    """Move one entry. Never overwrites, except an empty directory."""
    if dst.is_dir() and not dst.is_symlink():
        dst.rmdir()  # OSError(ENOTEMPTY) when it holds anything: the caller decides
    try:
        os.replace(src, dst)
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
        shutil.move(str(src), str(dst))


def _entries(source: _Candidate) -> list[str]:
    if source.owned:
        return sorted(p.name for p in source.real.iterdir())
    return [name for name in STATE_ENTRIES if (source.real / name).exists() or (source.real / name).is_symlink()]


def _leave_pointer(source: _Candidate, target: Path, report: MigrationReport, logger: Logger | None) -> None:
    home = source.path.parent
    legacy_owned = home / LEGACY_OWNED_NAME
    if source.owned:
        try:
            source.real.rmdir()
        except OSError:
            # Something could not move (a conflict). Leave the directory and
            # say where the rest went.
            _write_note(source.real, target)
            return
        try:
            legacy_owned.symlink_to(target, target_is_directory=True)
        except OSError as error:  # pragma: no cover - platform dependent
            _say(logger, f"moved the host state to {target}, but could not leave a symlink at {legacy_owned}: {error}")
        return
    # A shared source: never remove it. Leave a note, and point an old
    # ``~/.cowork`` symlink (it pointed into the shared directory) at the
    # new place, so scripts that still say ``~/.cowork`` keep working.
    _write_note(source.real, target)
    if legacy_owned.is_symlink():
        with contextlib.suppress(OSError):
            legacy_owned.unlink()
            legacy_owned.symlink_to(target, target_is_directory=True)


def _write_note(directory: Path, target: Path) -> None:
    with contextlib.suppress(OSError):
        (directory / MOVED_NOTE).write_text(
            "The Agents host state (pairing, device key, account, vault,\n"
            "databases and agent workspaces) that was here moved to:\n\n"
            f"    {target}\n\n"
            "Set AGENTS_HOME to use another directory. Other files in this\n"
            "directory, such as skills/, were not touched.\n",
            encoding="utf-8",
        )


def _resume_source(target: Path, candidates: list[_Candidate], home: Path) -> _Candidate | None:
    marker = target / MIGRATION_MARKER
    try:
        recorded = Path(marker.read_text(encoding="utf-8").strip())
    except OSError:
        return None
    for candidate in candidates:
        if candidate.real == recorded or candidate.path == recorded:
            return candidate
    if recorded.is_dir():
        owned = recorded == (home / LEGACY_OWNED_NAME) and not recorded.is_symlink()
        return _Candidate(path=recorded, real=recorded.resolve(), owned=owned, order=0)
    return None


def migrate_state_home(
    target: Path,
    *,
    home: Path | None = None,
    logger: Logger | None = None,
) -> Path:
    """Move a legacy host state into ``target``, once. Returns ``target``.

    Nothing happens when ``target`` already holds a state (and no interrupted
    move is recorded in it), or when no legacy directory holds one. Otherwise
    the best candidate is moved: the one with ``paired.json``; with two, the
    newer pairing. A failure is logged and never raised: the host must still
    start, and the caller still gets a usable path.
    """
    report = migrate_state_home_report(target, home=home, logger=logger)
    return report.target


def migrate_state_home_report(
    target: Path,
    *,
    home: Path | None = None,
    logger: Logger | None = None,
) -> MigrationReport:
    """:func:`migrate_state_home`, returning what was done."""
    target = Path(target)
    home = Path(home) if home is not None else Path.home()
    report = MigrationReport(target=target)
    try:
        with _lock(target.parent):
            _migrate_locked(target, home, report, logger)
    except OSError as error:
        _say(logger, f"could not move the host state into {target}: {error}")
    return report


def _migrate_locked(target: Path, home: Path, report: MigrationReport, logger: Logger | None) -> None:
    marker = target / MIGRATION_MARKER
    candidates = _candidates(home, target)
    resuming = marker.is_file()
    if resuming:
        source = _resume_source(target, candidates, home)
        if source is None:
            marker.unlink(missing_ok=True)
            return
    else:
        if has_host_state(target):
            for other in candidates:
                if other.paired:
                    report.left_in_place.append(other.path)
                    _say(
                        logger,
                        f"{other.path} still holds a paired host state, but {target} is"
                        " already in use; it was left untouched. Remove it when sure.",
                    )
            return
        source = _best(candidates)
        if source is None:
            return

    report.source = source.path
    target.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(OSError):
        os.chmod(target, 0o700)
    if not resuming:
        marker.write_text(str(source.real) + "\n", encoding="utf-8")
        _say(
            logger,
            f"moving the host state from {source.path} to {target}"
            + (" (it holds the pairing)" if source.paired else ""),
        )

    for name in _entries(source):
        src = source.real / name
        dst = target / name
        if name == MIGRATION_MARKER:
            continue
        if dst.exists() or dst.is_symlink():
            if not (dst.is_dir() and not dst.is_symlink() and not any(dst.iterdir())):
                report.conflicts.append(name)
                _say(logger, f"not moved, {dst} already exists: {src}")
                continue
        try:
            _move_entry(src, dst)
        except OSError as error:
            report.conflicts.append(name)
            _say(logger, f"could not move {src} to {dst}: {error}")
            continue
        report.moved.append(name)

    marker.unlink(missing_ok=True)
    _leave_pointer(source, target, report, logger)

    for other in candidates:
        if other.real != source.real:
            report.left_in_place.append(other.path)
            _say(
                logger,
                f"{other.path} holds a second, "
                + ("paired" if other.paired else "unpaired")
                + f" host state; it was left untouched. The host uses {target}.",
            )
    _say(logger, f"the host state is now in {target}")
