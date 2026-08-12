"""LocalEnvironment: run commands in a subprocess on the host itself."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile

from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment
from .result import ProcessResult


class LocalEnvironment(BaseEnvironment):
    """A ``BaseEnvironment`` backed by ``bash -c`` on the local machine.

    A private workspace directory and snapshot file are created under a temp
    root and removed on :meth:`cleanup`.
    """

    def __init__(
        self,
        *,
        workdir: str | None = None,
        max_output_chars: int = DEFAULT_MAX_OUTPUT_CHARS,
    ) -> None:
        self._root = tempfile.mkdtemp(prefix="cowork-local-")
        self._owns_workdir = workdir is None
        work = workdir if workdir is not None else os.path.join(self._root, "workspace")
        os.makedirs(work, exist_ok=True)
        snapshot = os.path.join(self._root, "session.snap")
        super().__init__(
            snapshot_path=snapshot,
            initial_cwd=work,
            max_output_chars=max_output_chars,
        )

    def _run_bash(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
    ) -> ProcessResult:
        argv = ["bash"]
        if login:
            argv.append("-l")
        argv += ["-c", cmd]
        # start_new_session puts the child in its own process group so a timeout
        # can kill the whole tree, not just the top bash.
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            out, err = proc.communicate(input=stdin, timeout=timeout)
            return ProcessResult(out, err, proc.returncode)
        except subprocess.TimeoutExpired:
            self._kill_group(proc)
            out, err = proc.communicate()
            return ProcessResult(out, err, -9, timed_out=True)

    @staticmethod
    def _kill_group(proc: subprocess.Popen) -> None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()

    def cleanup(self) -> None:
        if self._root and os.path.isdir(self._root):
            shutil.rmtree(self._root, ignore_errors=True)
        self._root = ""
