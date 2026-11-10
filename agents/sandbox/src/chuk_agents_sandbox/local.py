"""LocalEnvironment: run commands in a subprocess on the host itself."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile
import threading

from collections.abc import Mapping

from . import bwrap as _bwrap
from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment, PolicyProvider
from .child_env import child_env
from .policy import SandboxPolicy
from .result import ProcessResult

#: SIGTERM first, then SIGKILL after this many seconds (research item 36).
KILL_GRACE_S = 3.0


class LocalEnvironment(BaseEnvironment):
    """A ``BaseEnvironment`` backed by ``bash -c`` on the local machine.

    A private workspace directory and snapshot file are created under a temp
    root and removed on :meth:`cleanup`.

    Of the agent permissions (docs/WIRE_CONTRACT.md, "Agent permissions") only
    ``secrets_env`` can be enforced here: a host process has the host's sudo,
    network and file access, and no flag of ours takes them away. The docker
    backend enforces the rest. With ``isolation="bwrap"`` (see
    :mod:`.bwrap`) ``network`` and ``workspace_mount`` hold too.

    A command never inherits the host's environment as a whole (bead B9): it
    gets the allowlist of :func:`.child_env.child_env`, plus the secrets the
    user granted for it. ``sandbox_fallback`` marks an environment the host
    picked because ``--sandbox auto`` found no docker (bead B10).
    """

    def __init__(
        self,
        *,
        workdir: str | None = None,
        max_output_chars: int = DEFAULT_MAX_OUTPUT_CHARS,
        policy: SandboxPolicy | None = None,
        policy_provider: PolicyProvider | None = None,
        isolation: str | None = None,
        sandbox_fallback: bool = False,
    ) -> None:
        self._root = tempfile.mkdtemp(prefix="agents-local-")
        self._sandbox_fallback = bool(sandbox_fallback)
        self._isolation = _bwrap.resolve_isolation(isolation)
        self._bwrap = _bwrap.bwrap_binary() if _bwrap.wants_bwrap(self._isolation) else None
        self._private_tmp = os.path.join(self._root, "tmp")
        if self._bwrap:
            os.makedirs(self._private_tmp, mode=0o700, exist_ok=True)
        self._owns_workdir = workdir is None
        work = workdir if workdir is not None else os.path.join(self._root, "workspace")
        os.makedirs(work, exist_ok=True)
        self._workspace = work
        # The agent's own tmux server (bead B9): with the default socket a
        # ``terminal`` session would join the USER's tmux server and inherit
        # its environment (every token the user exported in that shell).
        # Keyed on the workspace, so a host restart finds its sessions again.
        self._tmux_dir = _tmux_dir_for(work)
        snapshot = os.path.join(self._root, "session.snap")
        # The process this environment is blocked on, so ``cancel`` (§7.1) can
        # kill it from the thread that pressed Stop.
        self._proc: subprocess.Popen | None = None
        self._proc_lock = threading.Lock()
        super().__init__(
            snapshot_path=snapshot,
            initial_cwd=work,
            max_output_chars=max_output_chars,
            policy=policy,
            policy_provider=policy_provider,
        )

    @property
    def workspace(self) -> str:
        """The directory this environment works in.

        Named like :attr:`DockerEnvironment.workspace` on purpose: a caller that
        asks an environment where its files live must not have to know which
        backend it is holding.
        """
        return self._workspace

    @property
    def sandbox_fallback(self) -> bool:
        """True when this environment stands in for a docker box that the
        host could not start (``--sandbox auto`` without a daemon)."""
        return self._sandbox_fallback

    @property
    def isolated(self) -> bool:
        """True when commands run inside bwrap."""
        return self._bwrap is not None

    @property
    def kind(self) -> str:
        """``local-bwrap`` or ``local``: the key of
        :func:`~.policy.enforced_permissions`."""
        return "local-bwrap" if self._bwrap else "local"

    def _child_env(self, extra: Mapping[str, str] | None) -> dict[str, str]:
        return child_env(extra, extra={"TMUX_TMPDIR": self._tmux_dir})

    def _argv(
        self, cmd: str, *, login: bool, policy: SandboxPolicy | None = None
    ) -> list[str]:
        argv = ["bash"]
        if login:
            argv.append("-l")
        argv += ["-c", cmd]
        if self._bwrap is None:
            return argv
        # ``policy`` is the widened policy of one escalated call, passed down
        # for that call only (security review C1); everyone else gets the
        # environment's own policy.
        policy = policy or self.effective_policy
        return _bwrap.wrap_argv(
            argv,
            binary=self._bwrap,
            workspace=self._workspace,
            session_dir=self._root,
            private_tmp=self._private_tmp,
            read_only_workspace=policy.read_only_workspace,
            network=policy.network,
        )

    def init_session(self) -> None:
        """Seed the snapshot from a login shell, minus every credential the
        profile exported (bead B9)."""
        if self._session_initialized:
            return
        import shlex

        from .child_env import SCRUB_SNIPPET

        snap = shlex.quote(self._snapshot_path)
        seed = (
            f"{SCRUB_SNIPPET}; {{ declare -px; declare -f; alias; }} > {snap} 2>/dev/null; true"
        )
        self._run_bash(seed, login=True, timeout=60)
        self._session_initialized = True

    def _run_bash(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
        env: Mapping[str, str] | None = None,
        policy: SandboxPolicy | None = None,
    ) -> ProcessResult:
        argv = self._argv(cmd, login=login, policy=policy)
        # start_new_session puts the child in its own process group so a timeout
        # can kill the whole tree, not just the top bash.
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            start_new_session=True,
            # An allowlist of the host environment, plus the per-command
            # extras (secrets) for THIS child and nowhere else (bead B9).
            env=self._child_env(env),
        )
        with self._proc_lock:
            self._proc = proc
        try:
            out, err = proc.communicate(input=stdin, timeout=timeout)
            return ProcessResult(out, err, proc.returncode)
        except subprocess.TimeoutExpired:
            self._kill_group(proc)
            out, err = proc.communicate()
            return ProcessResult(out, err, -9, timed_out=True)
        finally:
            with self._proc_lock:
                if self._proc is proc:
                    self._proc = None

    def cancel(self) -> None:
        """Kill the process group of the command in flight (§7.1).

        The group, not the process: ``start_new_session`` put the command in its
        own process group precisely so a stop reaches the whole tree it spawned,
        the way the timeout path does. ``communicate`` in :meth:`_run_bash` then
        returns whatever the command had already written, with exit code -9.
        """
        with self._proc_lock:
            proc = self._proc
        if proc is not None and proc.poll() is None:
            # Off the caller's thread: the grace period must not hold up Stop.
            threading.Thread(
                target=self._kill_group, args=(proc,), name="agents-local-kill", daemon=True
            ).start()

    @staticmethod
    def _kill_group(proc: subprocess.Popen, grace: float | None = None) -> None:
        """SIGTERM the process group, SIGKILL it after ``grace`` seconds
        (default :data:`KILL_GRACE_S`). A program gets the chance to clean up
        (a temp file, a lock, a child server); one that ignores TERM still
        dies. The group, not the process: ``start_new_session`` made the
        command the leader of its own group."""
        wait = KILL_GRACE_S if grace is None else grace
        pgid = proc.pid  # start_new_session: the group id is the leader's pid
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            proc.kill()
            return
        try:
            proc.wait(timeout=wait)
        except subprocess.TimeoutExpired:
            pass
        # Whatever is left of the group (a child that ignored TERM) dies now.
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        if proc.poll() is None:
            proc.kill()

    def cleanup(self) -> None:
        if self._root and os.path.isdir(self._root):
            shutil.rmtree(self._root, ignore_errors=True)
        self._root = ""


def _tmux_dir_for(workspace: str) -> str:
    """A private ``TMUX_TMPDIR`` per workspace: ``<tmp>/agents-tmux-<uid>-<digest>``,
    mode 0700. tmux puts its ``tmux-<uid>/default`` socket below it."""
    import hashlib

    digest = hashlib.sha256(os.path.abspath(workspace).encode()).hexdigest()[:12]
    uid = getattr(os, "getuid", lambda: 0)()
    path = os.path.join(tempfile.gettempdir(), f"agents-tmux-{uid}-{digest}")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path
