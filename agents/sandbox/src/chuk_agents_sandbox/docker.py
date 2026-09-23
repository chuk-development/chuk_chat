"""DockerEnvironment: one container per agent, reused across turns (§6).

Lifecycle rules, all of them driven by labels (see :mod:`.lifecycle`):

* **Reuse.** On the first command the backend looks for a container labelled
  with this ``(agent_id, task_id)``. A running one is reused as-is, a stopped
  one is started again. So the agent keeps its installed packages between
  turns, and a restarted Manager finds the same box.
* **Replace, don't corrupt.** A found container whose workspace mount or image
  no longer matches what the caller asked for is removed and rebuilt. Reusing
  it would silently give the agent the wrong files.
* **Teardown.** ``task_id == "default"`` is the agent's own session container:
  :meth:`cleanup` leaves it running so the next turn reuses it, and the orphan
  reaper is what eventually collects it. Any other ``task_id`` is task-scoped
  (a subagent, a one-off job) and :meth:`cleanup` force-removes it.
  :meth:`remove` always removes, whatever the task id.

Workspace bind mount
--------------------
``workdir`` is a **host** directory (the agent's git-versioned workspace). It is
bound to ``/workspace`` inside the container, which is also the initial cwd, so
host-side tools (the GPU ffmpeg passthrough of §9) and the agent operate on the
same bytes. ``AGENTS_UID``/``AGENTS_GID`` are passed in so the base image's
entrypoint can align its ``agents`` user with the host owner — without that,
every file the agent creates would land on the host owned by the wrong uid.

The session snapshot deliberately lives in ``/tmp``, **not** in the workspace:
the workspace is a git repo the user sees, and a churning dump of shell state
has no business being in it.
"""

from __future__ import annotations

import hashlib
import os
import shlex
import subprocess
import threading
import time
import uuid
from collections.abc import Mapping

from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment
from .lifecycle import (
    DEFAULT_TASK_ID,
    LABEL_IMAGE,
    LABEL_WORKSPACE,
    SESSION_LABEL,
    ContainerInfo,
    DockerCli,
    DockerUnavailableError,
    build_labels,
    default_cli,
    docker_available,
    find_agent_container,
    label_args,
    remove_container,
)
from .result import ProcessResult

#: The image ``install.sh`` builds (``sandbox/docker/Dockerfile``).
BASE_IMAGE = "agents-base:latest"
#: The image ``sandbox/docker/Dockerfile.browser`` builds: base + Chromium +
#: Xvfb + x11vnc + the Playwright MCP launcher. The watchable browser (§9.1)
#: exists in this image and in no other.
BROWSER_IMAGE = "agents-browser:latest"
#: Environment override, so a host can point every sandbox at its own build.
IMAGE_ENV_VAR = "AGENTS_SANDBOX_IMAGE"
#: Kept for backwards compatibility with callers importing ``DEFAULT_IMAGE``.
DEFAULT_IMAGE = BASE_IMAGE

#: The launcher the browser image installs. Its presence IS the capability:
#: a tag that says "browser" proves nothing, and a tag that does not say it can
#: still carry the launcher (bead cowork-3i5c).
BROWSER_MCP_PATH = "/usr/local/bin/agents-browser-mcp"

#: Unprivileged user with passwordless sudo in the base image. Used only when the
#: image actually has it (probed once per container).
DEFAULT_USER = "agents"

#: Bind-mount target and default cwd inside the container.
CONTAINER_WORKSPACE = "/workspace"

__all__ = [
    "BASE_IMAGE",
    "BROWSER_IMAGE",
    "BROWSER_MCP_PATH",
    "CONTAINER_WORKSPACE",
    "DEFAULT_IMAGE",
    "DEFAULT_USER",
    "DockerEnvironment",
    "DockerUnavailableError",
    "IMAGE_ENV_VAR",
    "SESSION_LABEL",
    "default_image",
    "docker_available",
    "image_has_browser",
    "image_present",
    "resolve_image",
]


def resolve_image(image: str | None = None) -> str:
    """Explicit image > ``AGENTS_SANDBOX_IMAGE`` > the built base image."""
    if image:
        return image
    return os.environ.get(IMAGE_ENV_VAR) or BASE_IMAGE


def image_present(image: str, cli: DockerCli | None = None) -> bool:
    """True when that image is on this machine."""
    cli = cli or default_cli()
    return cli.run("image", "inspect", image, timeout=20).ok


#: ``image -> has the browser launcher``. A probe starts a container, so it runs
#: once per image per process.
_BROWSER_PROBE: dict[str, bool] = {}


def image_has_browser(image: str, cli: DockerCli | None = None) -> bool:
    """True when that image carries :data:`BROWSER_MCP_PATH`.

    The answer is the file, not the tag. An image is probed once and the answer
    is kept, because the probe costs a container start.
    """
    cached = _BROWSER_PROBE.get(image)
    if cached is not None:
        return cached
    cli = cli or default_cli()
    probe = cli.run(
        "run", "--rm", "--entrypoint", "test", image, "-x", BROWSER_MCP_PATH,
        timeout=60,
    )
    _BROWSER_PROBE[image] = probe.ok
    return probe.ok


def forget_image_probes() -> None:
    """Drop the cached browser probes (a rebuilt image, and tests)."""
    _BROWSER_PROBE.clear()


def default_image(cli: DockerCli | None = None) -> str:
    """The image a host should run when the user named none.

    ``AGENTS_SANDBOX_IMAGE`` still wins. Otherwise the browser image is taken
    when it is built on this machine: it is the base image plus the watchable
    browser, so preferring it costs disk and gains the one capability the user
    asks for by name. Falls back to the base image.
    """
    override = os.environ.get(IMAGE_ENV_VAR)
    if override:
        return override
    if image_present(BROWSER_IMAGE, cli):
        return BROWSER_IMAGE
    return BASE_IMAGE


def _slug(text: str, limit: int = 24) -> str:
    """Container-name-safe fragment of ``text``."""
    kept = [c if (c.isalnum() or c in "-_.") else "-" for c in text]
    out = "".join(kept).strip("-.") or "x"
    return out[:limit]


def _fingerprint(text: str, length: int = 8) -> str:
    """A short, stable digest of the FULL text.

    :func:`_slug` is lossy twice over: it folds every unusual character to ``-``
    and it cuts at ``limit``. Two different agent ids can therefore produce the
    same slug (``my agent`` and ``my/agent``; two ids that share a long prefix),
    and two agents that share a container name are exactly the collision this
    package must not have. The digest is appended to the name so the name is
    unique per agent id, not per slug.
    """
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:length]


class DockerEnvironment(BaseEnvironment):
    """A ``BaseEnvironment`` backed by ``docker exec`` into one agent container."""

    def __init__(
        self,
        *,
        image: str | None = None,
        agent_id: str = "default",
        task_id: str = DEFAULT_TASK_ID,
        session_id: str | None = None,
        workdir: str | None = None,
        initial_cwd: str | None = None,
        user: str | None = None,
        snapshot_path: str | None = None,
        max_output_chars: int = DEFAULT_MAX_OUTPUT_CHARS,
        extra_run_args: tuple[str, ...] = (),
        cli: DockerCli | None = None,
    ) -> None:
        self._image = resolve_image(image)
        self._agent_id = agent_id
        self._task_id = task_id or DEFAULT_TASK_ID
        # How long to keep retrying `docker start` while a container is still
        # mid-shutdown. Short: this is a transition, not a wait for work.
        self._start_grace_s = 10.0
        self._session_id = session_id or uuid.uuid4().hex[:12]
        self._workspace = os.path.abspath(os.path.expanduser(workdir)) if workdir else None
        self._user: str | None = user
        self._user_resolved = user is not None
        self._extra_run_args = tuple(extra_run_args)
        self._cli = cli or DockerCli()
        self._container: str | None = None
        self._reused = False
        # The exec client this environment is blocked on, so ``cancel`` (§7.1)
        # can kill it from the thread that pressed Stop.
        self._proc: subprocess.Popen | None = None
        self._proc_lock = threading.Lock()

        cwd = initial_cwd or CONTAINER_WORKSPACE
        # The snapshot lives in the container's /tmp, never in the mounted
        # workspace (which is a git repo the user reads).
        snap = snapshot_path or f"/tmp/.agents-session-{self._session_id}.snap"
        super().__init__(
            snapshot_path=snap,
            initial_cwd=cwd,
            max_output_chars=max_output_chars,
        )

    # ------------------------------------------------------------------ #
    # Identity
    # ------------------------------------------------------------------ #
    @property
    def session_id(self) -> str:
        return self._session_id

    @property
    def agent_id(self) -> str:
        return self._agent_id

    @property
    def task_id(self) -> str:
        return self._task_id

    @property
    def image(self) -> str:
        return self._image

    @property
    def workspace(self) -> str | None:
        """The host directory bound into the container, if any."""
        return self._workspace

    @property
    def container_name(self) -> str:
        """Deterministic name, so the agent's box is recognisable in ``docker ps``.

        The *default* task keeps a stable name across sessions (it is the same
        box being reused); task-scoped containers carry the session id because
        several may exist for one agent at once.

        The name always ends in a digest of the whole agent id, so two agents
        can never land on one name (see :func:`_fingerprint`). Reuse is still
        decided by the labels, never by the name.
        """
        base = f"agents-{_slug(self._agent_id)}-{_fingerprint(self._agent_id)}"
        if self._task_id == DEFAULT_TASK_ID:
            return base
        return f"{base}-{_slug(self._task_id, 16)}-{self._session_id}"

    @property
    def container_id(self) -> str | None:
        """The container backing this environment, or ``None`` before first use."""
        return self._container

    @property
    def reused_container(self) -> bool:
        """True when the current container existed before this environment did."""
        return self._reused

    @property
    def is_task_scoped(self) -> bool:
        """True when ``cleanup()`` tears the container down (``task_id != default``)."""
        return self._task_id != DEFAULT_TASK_ID

    def labels(self) -> dict[str, str]:
        return build_labels(
            agent_id=self._agent_id,
            task_id=self._task_id,
            session_id=self._session_id,
            workspace=self._workspace,
            image=self._image,
        )

    # ------------------------------------------------------------------ #
    # Container lifecycle
    # ------------------------------------------------------------------ #
    def _ensure_container(self) -> str:
        # A cached ID is not proof of a live container: another host process
        # or a rebuild may have removed/replaced it since the previous command.
        # Resolve by ownership labels again before handing an ID to docker exec.
        if not self._cli.available():
            raise DockerUnavailableError(
                f"{self._cli.binary} CLI or daemon is unavailable"
            )

        existing = find_agent_container(
            agent_id=self._agent_id, task_id=self._task_id, cli=self._cli
        )
        if existing is not None and not self._matches(existing):
            # Wrong workspace or wrong image: reusing it would hand the agent
            # someone else's files. Replace it.
            remove_container(existing.id or existing.name, cli=self._cli)
            existing = None
        if existing is not None and not existing.running:
            if not self._start_existing(existing):
                remove_container(existing.id or existing.name, cli=self._cli)
                existing = None
        if existing is not None:
            if existing.id == self._container:
                return self._container
            self._container = existing.id
            self._reused = True
            # Adopt the existing box's session id so the reaper's "live session"
            # bookkeeping keeps matching the label that is actually on it.
            adopted = existing.session_id
            if adopted:
                self._session_id = adopted
            self._resolve_user()
            return self._container

        self._container = self._create()
        self._reused = False
        self._resolve_user()
        return self._container

    def _start_existing(self, existing: ContainerInfo) -> bool:
        """Start a stopped container back up, tolerating a transitional state.

        ``docker stop`` returns as soon as the signal is delivered, so a
        container can still be mid-shutdown when we look. ``start`` then fails
        with "container is restarting"/"removal in progress", and the caller
        used to replace the box — silently discarding the agent's filesystem
        (an installed package, a checked-out repo, /tmp state) and handing back
        an empty one. Retry briefly instead; only a container that will not come
        back after that is genuinely broken.
        """
        deadline = time.monotonic() + self._start_grace_s
        attempt = 0
        while True:
            result = self._cli.run("start", existing.id, timeout=60)
            if result.ok:
                return True
            stderr = result.stderr.lower()
            if "no such container" in stderr:
                return False  # gone for good; a fresh one is the right answer
            if time.monotonic() >= deadline:
                return False
            attempt += 1
            time.sleep(min(0.1 * attempt, 0.5))

    def _matches(self, container: ContainerInfo) -> bool:
        """False when a found container's mount or image no longer fits."""
        labelled_workspace = container.labels.get(LABEL_WORKSPACE)
        if (labelled_workspace or None) != (self._workspace or None):
            return False
        labelled_image = container.labels.get(LABEL_IMAGE)
        # Containers from before the image label existed are given the benefit of
        # the doubt; a mismatch is only a mismatch when we know both sides.
        return labelled_image is None or labelled_image == self._image

    def _create(self) -> str:
        argv = ["run", "-d", *label_args(self.labels())]
        argv += ["--name", self.container_name, "--workdir", self._cwd]
        if self._workspace is not None:
            os.makedirs(self._workspace, exist_ok=True)
            argv += ["-v", f"{self._workspace}:{CONTAINER_WORKSPACE}"]
            # The transcript folder is the host's record of the thread
            # (cowork-b5): mounted read-only over the workspace mount, so a
            # `run_command` inside the container cannot delete or rewrite it.
            transcript = os.path.join(self._workspace, "transcript")
            if os.path.isdir(transcript):
                argv += ["-v", f"{transcript}:{CONTAINER_WORKSPACE}/transcript:ro"]
            uid = getattr(os, "getuid", lambda: None)()
            gid = getattr(os, "getgid", lambda: None)()
            if uid is not None and gid is not None:
                # The base image's entrypoint aligns its `agents` user with these,
                # so files the agent writes land on the host owned by the user.
                argv += ["-e", f"AGENTS_UID={uid}", "-e", f"AGENTS_GID={gid}"]
        argv += [*self._extra_run_args, self._image, "sleep", "infinity"]

        result = self._cli.run(*argv, timeout=180)
        if not result.ok and "already in use" in result.stderr.lower():
            # A name clash with a container we do not manage (or a racing peer):
            # take a unique name rather than steal or fail.
            argv[argv.index("--name") + 1] = f"{self.container_name}-{self._session_id}"
            result = self._cli.run(*argv, timeout=180)
        if not result.ok:
            raise DockerUnavailableError(
                f"could not start container: {result.stderr.strip()}"
            )
        return result.stdout.strip()

    def _resolve_user(self) -> None:
        """Pick the exec user once: the requested one, else the image's ``agents``.

        Probing beats configuring: our base image ships the unprivileged
        passwordless-sudo user, a plain ``debian:*`` image does not, and the same
        code has to work with both.
        """
        if self._user_resolved:
            return
        self._user_resolved = True
        probe = self._cli.run(
            "exec", str(self._container), "id", "-u", DEFAULT_USER, timeout=30
        )
        if probe.ok:
            self._user = DEFAULT_USER
            return
        # No agent user in this image (a plain ``debian:*`` in development). With a
        # workspace mounted, running as root would litter the host with
        # root-owned files, so fall back to the host uid/gid. There is no sudo and
        # no passwd entry for it — which is exactly why the base image exists.
        uid = getattr(os, "getuid", lambda: None)()
        gid = getattr(os, "getgid", lambda: None)()
        if self._workspace is not None and uid is not None and gid is not None:
            self._user = f"{uid}:{gid}"
        else:
            self._user = None

    # ------------------------------------------------------------------ #
    # Command execution
    # ------------------------------------------------------------------ #
    def _run_bash(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        container = self._ensure_container()
        argv = [self._cli.binary, "exec", "-i"]
        if self._user:
            argv += ["-u", self._user]
        # Per-command extras (the user's secrets): ``-e NAME`` with NO value
        # makes the docker client read the value from ITS OWN environment, so
        # the value never appears on a command line (`ps`, shell history, a
        # log of argv) and never touches the image or the container config.
        # The value rides in ``env=`` on the Popen below.
        for name in env or ():
            argv += ["-e", name]
        argv += [container, "bash"]
        if login:
            argv.append("-l")
        argv += ["-c", cmd]
        try:
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                stdin=subprocess.PIPE,
                text=True,
                env={**os.environ, **env} if env else None,
            )
        except OSError as exc:  # CLI vanished mid-session
            raise DockerUnavailableError(str(exc)) from exc
        with self._proc_lock:
            self._proc = proc
        try:
            out, err = proc.communicate(input=stdin, timeout=timeout)
            return ProcessResult(out, err, proc.returncode)
        except subprocess.TimeoutExpired:
            # Kill the exec client, then the in-container process tree it spawned:
            # killing only the client would leave the command running forever in a
            # container we deliberately keep alive for reuse.
            proc.kill()
            out, err = proc.communicate()
            self._kill_in_container()
            return ProcessResult(out, err, -9, timed_out=True)
        finally:
            with self._proc_lock:
                if self._proc is proc:
                    self._proc = None

    def cancel(self) -> None:
        """Kill the ``docker exec`` in flight and the tree it left inside (§7.1).

        Same two-step as the timeout path, for the same reason: the container is
        kept alive for reuse, so killing only the exec client would leave the
        command running in it forever with nobody reading its output.
        """
        with self._proc_lock:
            proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        proc.kill()
        self._kill_in_container()

    def _kill_in_container(self) -> None:
        """Best-effort kill of the bash tree a timed-out exec left behind."""
        if self._container is None:
            return
        snap = shlex.quote(self._snapshot_path)
        self._cli.run(
            "exec",
            self._container,
            "bash",
            "-c",
            f"pkill -9 -f {snap} 2>/dev/null; true",
            timeout=30,
        )

    # ------------------------------------------------------------------ #
    # Teardown
    # ------------------------------------------------------------------ #
    def cleanup(self) -> None:
        """Session close: remove a task-scoped container, keep the default one.

        The default container is the agent's box; keeping it is the whole point of
        label-keyed reuse. The orphan reaper collects it when no session owns it.
        """
        if self._container is None:
            return
        if self.is_task_scoped:
            self.remove()
            return
        self._container = None

    def remove(self) -> bool:
        """Force-remove the container regardless of task id. Idempotent."""
        target = self._container
        if target is None:
            # Nothing started in this process, but a labelled box may still exist.
            found = find_agent_container(
                agent_id=self._agent_id, task_id=self._task_id, cli=self._cli
            )
            if found is None:
                return False
            target = found.id or found.name
        removed = remove_container(target, cli=self._cli)
        self._container = None
        return removed

    def container_label(self, key: str) -> str | None:
        """Read one label off the live container (used by tests and diagnostics)."""
        if self._container is None:
            return None
        result = self._cli.run(
            "inspect",
            "-f",
            f"{{{{index .Config.Labels {_go_label_key(key)}}}}}",
            self._container,
            timeout=30,
        )
        if not result.ok:
            return None
        value = result.stdout.strip()
        return None if value in ("", "<no value>") else value


def _go_label_key(key: str) -> str:
    """Quote a label name for a Go template index expression."""
    return '"' + key.replace('"', '\\"') + '"'
