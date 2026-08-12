"""DockerEnvironment: run commands inside a session-scoped container.

The container is created lazily on first command and labelled
``cowork-session=<id>`` so an orphan reaper (or a human) can find and remove
containers a killed run left behind. :meth:`cleanup` force-removes it.
"""

from __future__ import annotations

import shutil
import subprocess
import uuid

from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment
from .result import ProcessResult

DEFAULT_IMAGE = "debian:stable-slim"
SESSION_LABEL = "cowork-session"


class DockerUnavailableError(RuntimeError):
    """Raised when the docker CLI or daemon cannot be reached."""


def docker_available() -> bool:
    """True if the docker CLI is on PATH and the daemon answers."""
    if shutil.which("docker") is None:
        return False
    try:
        proc = subprocess.run(
            ["docker", "ps", "-q"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


class DockerEnvironment(BaseEnvironment):
    """A ``BaseEnvironment`` backed by ``docker exec`` into one container."""

    def __init__(
        self,
        *,
        image: str = DEFAULT_IMAGE,
        session_id: str | None = None,
        initial_cwd: str = "/root",
        max_output_chars: int = DEFAULT_MAX_OUTPUT_CHARS,
    ) -> None:
        self._image = image
        self._session_id = session_id or uuid.uuid4().hex[:12]
        self._container: str | None = None
        # The snapshot lives inside the container filesystem.
        super().__init__(
            snapshot_path=f"{initial_cwd}/.cowork_session.snap",
            initial_cwd=initial_cwd,
            max_output_chars=max_output_chars,
        )

    @property
    def session_id(self) -> str:
        return self._session_id

    @property
    def container_name(self) -> str:
        return f"cowork-{self._session_id}"

    # ------------------------------------------------------------------ #
    # Container lifecycle
    # ------------------------------------------------------------------ #
    def _ensure_container(self) -> str:
        if self._container is not None:
            return self._container
        if not docker_available():
            raise DockerUnavailableError("docker CLI or daemon is unavailable")
        proc = subprocess.run(
            [
                "docker", "run", "-d",
                "--label", f"{SESSION_LABEL}={self._session_id}",
                "--name", self.container_name,
                "--workdir", self._cwd,
                self._image,
                "sleep", "infinity",
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if proc.returncode != 0:
            raise DockerUnavailableError(
                f"could not start container: {proc.stderr.strip()}"
            )
        self._container = proc.stdout.strip()
        return self._container

    def _run_bash(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
    ) -> ProcessResult:
        container = self._ensure_container()
        argv = ["docker", "exec", "-i", container, "bash"]
        if login:
            argv.append("-l")
        argv += ["-c", cmd]
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
        )
        try:
            out, err = proc.communicate(input=stdin, timeout=timeout)
            return ProcessResult(out, err, proc.returncode)
        except subprocess.TimeoutExpired:
            # Kill the exec client. The in-container process is reaped when the
            # container is removed at cleanup.
            proc.kill()
            out, err = proc.communicate()
            return ProcessResult(out, err, -9, timed_out=True)

    def cleanup(self) -> None:
        if self._container is None:
            return
        try:
            subprocess.run(
                ["docker", "rm", "-f", self._container],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.SubprocessError):
            pass
        self._container = None
