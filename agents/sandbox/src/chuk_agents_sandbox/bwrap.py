"""Bubblewrap isolation for the local backend (research item 37).

The local backend runs commands as the host user, with the host's files and
network. When ``bwrap`` is installed it can do better: each command runs in a
mount namespace where the whole file system is read-only except the agent's
workspace, its private ``/tmp`` and its session directory; the PID namespace
is private; and with the ``network`` permission off the network namespace is
empty too.

It is a policy, not a default: :func:`resolve_isolation` reads
``AGENTS_LOCAL_ISOLATION`` (``none`` default, ``bwrap``, ``auto``). The reason:
with ``--unshare-pid`` and ``--die-with-parent`` every process a command
leaves behind ends with that command, so background jobs (``run_background``)
and the interactive terminal (tmux) do not outlive one call. A host that
needs those keeps ``none``; a host that wants the fence turns it on.

``bwrap`` also sets ``no_new_privs``, so ``sudo`` never works inside.

The probe (:func:`bwrap_usable`) runs ``bwrap ... -- true`` once per process,
with a 5 s timeout, and caches the answer. Some kernels forbid unprivileged
user namespaces; then the probe fails and the backend falls back to a plain
local run with one warning in the log.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import threading

logger = logging.getLogger("agents.sandbox.bwrap")

#: Env var with the local isolation mode.
ISOLATION_ENV_VAR = "AGENTS_LOCAL_ISOLATION"
ISOLATION_NONE = "none"
ISOLATION_BWRAP = "bwrap"
#: ``bwrap`` when the probe passes, else ``none`` (no warning: it was optional).
ISOLATION_AUTO = "auto"
ISOLATION_MODES = (ISOLATION_NONE, ISOLATION_BWRAP, ISOLATION_AUTO)

PROBE_TIMEOUT_S = 5.0

_probe_lock = threading.Lock()
_probe_result: bool | None = None


def resolve_isolation(mode: str | None = None) -> str:
    """Explicit mode > ``AGENTS_LOCAL_ISOLATION`` > ``none``. An unknown value
    is ``none``: a typo must not change how commands run."""
    value = (mode or os.environ.get(ISOLATION_ENV_VAR) or ISOLATION_NONE).strip().lower()
    return value if value in ISOLATION_MODES else ISOLATION_NONE


def bwrap_binary() -> str | None:
    return shutil.which("bwrap")


def probe_argv(binary: str) -> list[str]:
    """The probe: the same namespaces a real command gets, then ``true``."""
    return [
        binary,
        "--ro-bind", "/", "/",
        "--dev", "/dev",
        "--proc", "/proc",
        "--tmpfs", "/tmp",
        "--unshare-pid",
        "--die-with-parent",
        "--",
        "true",
    ]


def bwrap_usable(*, refresh: bool = False) -> bool:
    """True when ``bwrap`` is installed and can create its namespaces here.
    Probed once per process (5 s timeout) and cached."""
    global _probe_result
    with _probe_lock:
        if _probe_result is not None and not refresh:
            return _probe_result
        binary = bwrap_binary()
        ok = False
        if binary:
            try:
                done = subprocess.run(
                    probe_argv(binary),
                    capture_output=True,
                    timeout=PROBE_TIMEOUT_S,
                    check=False,
                )
                ok = done.returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                ok = False
        _probe_result = ok
        return ok


def reset_probe() -> None:
    """Forget the cached probe (tests)."""
    global _probe_result
    with _probe_lock:
        _probe_result = None


def wants_bwrap(mode: str | None = None) -> bool:
    """Should commands run under bwrap? Logs once when ``bwrap`` was asked
    for and cannot run."""
    resolved = resolve_isolation(mode)
    if resolved == ISOLATION_NONE:
        return False
    if bwrap_usable():
        return True
    if resolved == ISOLATION_BWRAP:
        _warn_once()
    return False


_warned = False


def _warn_once() -> None:
    global _warned
    if _warned:
        return
    _warned = True
    logger.warning(
        "%s=bwrap but bwrap is missing or cannot create namespaces here; "
        "local commands run WITHOUT isolation",
        ISOLATION_ENV_VAR,
    )


def wrap_argv(
    argv: list[str],
    *,
    binary: str,
    workspace: str,
    session_dir: str,
    private_tmp: str | None = None,
    read_only_workspace: bool = False,
    network: bool = True,
    cwd: str | None = None,
) -> list[str]:
    """``argv`` inside bwrap.

    * ``/`` read-only, fresh ``/dev`` and ``/proc``.
    * ``/tmp``: ``private_tmp`` bound over it (the same directory for every
      command of one environment, so a file written to ``/tmp`` is there next
      time), else a tmpfs.
    * ``session_dir`` (the snapshot) writable: the session must survive.
    * the workspace writable, or read-only with ``workspace_mount: ro``.
    * ``--unshare-net`` when the ``network`` permission is off.
    """
    out = [binary, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"]
    if private_tmp:
        out += ["--bind", private_tmp, "/tmp"]
    else:
        out += ["--tmpfs", "/tmp"]
    # After /tmp: the session directory usually lives under the host /tmp.
    out += ["--bind", session_dir, session_dir]
    out += ["--ro-bind" if read_only_workspace else "--bind", workspace, workspace]
    out += ["--unshare-pid", "--die-with-parent"]
    if not network:
        out.append("--unshare-net")
    if cwd:
        out += ["--chdir", cwd]
    return [*out, "--", *argv]
