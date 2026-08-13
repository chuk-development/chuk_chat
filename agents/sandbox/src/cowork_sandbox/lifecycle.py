"""Container lifecycle for per-agent sandboxes (§6).

One container per agent, reused across turns. Reuse is keyed off **Docker
labels**, never off in-process bookkeeping, so a fresh Manager process finds the
containers a previous one started:

======================  ==================================================
``cowork.managed``      ``true`` on every container we create. The reaper
                        will only ever touch containers carrying this.
``cowork.agent``        the roster agent id the container belongs to.
``cowork.task``         ``default`` for the agent's own session container;
                        anything else marks a **task-scoped** container (a
                        subagent, a one-off job) that is torn down when its
                        session closes.
``cowork.session``      the id of the run that created it — what the orphan
                        reaper compares against the set of live sessions.
======================  ==================================================

The reaper exists because a killed Manager leaves its containers behind: they
are still labelled, still running, and nothing will ever call ``cleanup()`` on
them. :func:`reap_orphans` removes every managed container whose session is not
in the live set, which for a starting Manager (live set empty) means "everything
left over from the last run".

All docker access goes through :class:`DockerCli`, a thin argv wrapper, so the
lifecycle logic is unit-testable against a fake without a daemon.
"""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass, field

#: Marks every container this package creates.
LABEL_MANAGED = "cowork.managed"
LABEL_AGENT = "cowork.agent"
LABEL_TASK = "cowork.task"
LABEL_SESSION = "cowork.session"

#: Host workspace bound into the container. Part of the reuse guard: a container
#: pointing at a different workspace is stale and gets replaced, not reused.
LABEL_WORKSPACE = "cowork.workspace"
#: Image the container was created from — the other half of the reuse guard.
LABEL_IMAGE = "cowork.image"

#: Legacy label kept so containers from before the lifecycle work stay findable.
SESSION_LABEL = "cowork-session"

#: The task id of an agent's own long-lived session container. Any other value
#: marks a task-scoped container that ``cleanup()`` tears down.
DEFAULT_TASK_ID = "default"


class DockerUnavailableError(RuntimeError):
    """Raised when the container CLI or daemon cannot be reached."""


@dataclass(frozen=True, slots=True)
class CliResult:
    """The outcome of one container-CLI invocation."""

    stdout: str
    stderr: str
    exit_code: int

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


@dataclass(frozen=True, slots=True)
class ContainerInfo:
    """One container as the CLI reports it."""

    id: str
    name: str
    state: str
    labels: dict[str, str] = field(default_factory=dict)

    @property
    def running(self) -> bool:
        return self.state.lower() == "running"

    @property
    def agent_id(self) -> str | None:
        return self.labels.get(LABEL_AGENT)

    @property
    def task_id(self) -> str | None:
        return self.labels.get(LABEL_TASK)

    @property
    def session_id(self) -> str | None:
        return self.labels.get(LABEL_SESSION) or self.labels.get(SESSION_LABEL)


class DockerCli:
    """Thin wrapper around the container CLI (docker, or a compatible podman).

    Every call returns a :class:`CliResult`; nothing raises for a non-zero exit
    so callers decide what a failure means. Tests substitute this class.
    """

    def __init__(self, binary: str = "docker", *, default_timeout: int = 120) -> None:
        self._binary = binary
        self._default_timeout = default_timeout

    @property
    def binary(self) -> str:
        return self._binary

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        try:
            proc = subprocess.run(
                [self._binary, *args],
                capture_output=True,
                text=True,
                timeout=timeout or self._default_timeout,
            )
        except subprocess.TimeoutExpired:
            return CliResult("", f"{self._binary} {' '.join(args)} timed out", 124)
        except OSError as exc:
            return CliResult("", str(exc), 127)
        return CliResult(proc.stdout, proc.stderr, proc.returncode)

    def available(self) -> bool:
        """True if the CLI is on PATH and the daemon answers."""
        if shutil.which(self._binary) is None:
            return False
        return self.run("ps", "-q", timeout=15).ok


def default_cli() -> DockerCli:
    """The CLI used when a caller passes none."""
    return DockerCli()


def docker_available(cli: DockerCli | None = None) -> bool:
    """True if the container CLI is on PATH and its daemon answers."""
    return (cli or default_cli()).available()


# ---------------------------------------------------------------------- #
# Label helpers
# ---------------------------------------------------------------------- #


def build_labels(
    *,
    agent_id: str,
    task_id: str,
    session_id: str,
    workspace: str | None = None,
    image: str | None = None,
) -> dict[str, str]:
    """The full label set every managed container carries."""
    labels = {
        LABEL_MANAGED: "true",
        LABEL_AGENT: agent_id,
        LABEL_TASK: task_id,
        LABEL_SESSION: session_id,
        SESSION_LABEL: session_id,
    }
    if workspace is not None:
        labels[LABEL_WORKSPACE] = workspace
    if image is not None:
        labels[LABEL_IMAGE] = image
    return labels


def label_args(labels: dict[str, str]) -> list[str]:
    """``{'a': 'b'} -> ['--label', 'a=b']``, in a stable order."""
    out: list[str] = []
    for key in sorted(labels):
        out += ["--label", f"{key}={labels[key]}"]
    return out


def parse_labels(raw: str) -> dict[str, str]:
    """Parse the CLI's ``k=v,k=v`` label column."""
    labels: dict[str, str] = {}
    for part in raw.split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, _, value = part.partition("=")
        labels[key.strip()] = value.strip()
    return labels


_PS_FORMAT = "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Labels}}"


def list_containers(
    *,
    cli: DockerCli | None = None,
    filters: dict[str, str] | None = None,
    all_states: bool = True,
) -> list[ContainerInfo]:
    """List containers matching ``filters`` (label name -> value)."""
    cli = cli or default_cli()
    argv = ["ps", "--no-trunc", "--format", _PS_FORMAT]
    if all_states:
        argv.append("-a")
    for key, value in sorted((filters or {}).items()):
        argv += ["--filter", f"label={key}={value}"]
    result = cli.run(*argv, timeout=30)
    if not result.ok:
        return []
    containers: list[ContainerInfo] = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        cid, name, state = parts[0], parts[1], parts[2]
        raw_labels = parts[3] if len(parts) > 3 else ""
        containers.append(
            ContainerInfo(
                id=cid.strip(),
                name=name.strip(),
                state=state.strip(),
                labels=parse_labels(raw_labels),
            )
        )
    return containers


def find_agent_container(
    *,
    agent_id: str,
    task_id: str = DEFAULT_TASK_ID,
    cli: DockerCli | None = None,
) -> ContainerInfo | None:
    """The reusable container for ``(agent_id, task_id)``, if one exists.

    A running container wins over a stopped one; otherwise the first match.
    """
    matches = list_containers(
        cli=cli,
        filters={
            LABEL_MANAGED: "true",
            LABEL_AGENT: agent_id,
            LABEL_TASK: task_id,
        },
    )
    if not matches:
        return None
    for container in matches:
        if container.running:
            return container
    return matches[0]


def remove_container(name_or_id: str, *, cli: DockerCli | None = None) -> bool:
    """Force-remove one container. True when it is gone afterwards."""
    cli = cli or default_cli()
    result = cli.run("rm", "-f", name_or_id, timeout=60)
    if result.ok:
        return True
    # "No such container" also means gone, which is what the caller wanted.
    return "no such container" in result.stderr.lower()


def reap_orphans(
    *,
    active_session_ids: set[str] | frozenset[str] | None = None,
    cli: DockerCli | None = None,
) -> list[str]:
    """Remove managed containers no live session owns; return their names.

    Called by the Manager at startup with an **empty** live set, this removes
    every container a killed previous run left behind. Called later with the
    sessions currently in flight, it removes only the strays.

    Only containers carrying ``cowork.managed=true`` are ever considered, so a
    user's own containers are never touched.
    """
    live = set(active_session_ids or ())
    reaped: list[str] = []
    for container in list_containers(cli=cli, filters={LABEL_MANAGED: "true"}):
        session = container.session_id
        if session is not None and session in live:
            continue
        if remove_container(container.id or container.name, cli=cli):
            reaped.append(container.name or container.id)
    return reaped
