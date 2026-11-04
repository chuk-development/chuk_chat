"""Per-agent sandbox permissions (docs/WIRE_CONTRACT.md, "Agent permissions").

The owner's rule: by default the agent may do EVERYTHING. It has passwordless
sudo, the internet, the user's secrets as environment variables and a writable
workspace. The user can switch each of those off per agent in the app. The one
switch that starts OFF is the user's own browser (the browser add-on target).

A :class:`SandboxPolicy` is plain config that a :class:`~.base.BaseEnvironment`
carries. The backends enforce it at the one place they can:

``sudo``
    Container creation. ``False`` starts the container with
    ``--security-opt no-new-privileges``: the kernel then refuses every setuid
    transition, so ``sudo`` (a setuid binary) fails for the agent user, with the
    image as it is. ``AGENTS_SUDO=0`` also tells the entrypoint to delete the
    sudoers entry (images built from this repository's Dockerfile).
``network``
    Container creation. ``False`` is ``--network none``: only the loopback
    device exists. The watchable browser still works, because the host reaches
    x11vnc over ``docker exec`` and not over the network.
``workspace_mount``
    Container creation. ``ro`` binds the workspace read-only. The browser
    profile then moves to ``/tmp`` (it normally lives in the workspace).
``secrets_env``
    Every command. ``False`` drops the per-command secret environment in
    :meth:`~.base.BaseEnvironment.run`, for every backend. It is also part of
    the container key, so the box is rebuilt when it changes.
``user_browser``
    Not enforced here: the executor reads it when it picks the browser target.
``external_agents``
    Not enforced here: the executor reads it when it wires subagents. ``True``
    lets ``delegate_task`` hand a task to a ``claude`` / ``codex`` CLI that is
    installed in the sandbox (``chuk_agents_runtime.acp_runner``). Off by
    default: the CLI bills the user's own account.

The container-level part of a policy is written onto the container as the
``cowork.policy`` label. A container whose label does not match the policy of
its environment is replaced, exactly like a container with the wrong image.
An environment changes its policy only while no run holds it (see
:meth:`~.base.BaseEnvironment.begin_run`), so a box is never rebuilt under a
running task.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, fields
from typing import Any

#: The workspace bind mount is writable.
WORKSPACE_RW = "rw"
#: The workspace bind mount is read-only.
WORKSPACE_RO = "ro"
WORKSPACE_MODES = (WORKSPACE_RW, WORKSPACE_RO)

#: Every permission key, in the order the app shows them.
PERMISSION_KEYS = (
    "sudo",
    "network",
    "secrets_env",
    "workspace_mount",
    "user_browser",
    "external_agents",
)
_BOOL_KEYS = frozenset(
    {"sudo", "network", "secrets_env", "user_browser", "external_agents"}
)

#: Label with the container-level part of the policy (see ``container_key``).
LABEL_POLICY = "cowork.policy"

#: Where the browser profile goes when the workspace is read-only. The
#: launcher reads ``AGENTS_BROWSER_PROFILE`` (``docker/browser-mcp.sh``).
READ_ONLY_BROWSER_PROFILE = "/tmp/agents-chrome-profile"


class PolicyError(ValueError):
    """A permission key or value that the host does not accept."""


@dataclass(frozen=True, slots=True)
class SandboxPolicy:
    """What one agent may do in its sandbox. Defaults: everything but the
    user's own browser."""

    sudo: bool = True
    network: bool = True
    secrets_env: bool = True
    workspace_mount: str = WORKSPACE_RW
    user_browser: bool = False
    external_agents: bool = False

    def __post_init__(self) -> None:
        for name in _BOOL_KEYS:
            if not isinstance(getattr(self, name), bool):
                raise PolicyError(f"{name} must be true or false")
        if self.workspace_mount not in WORKSPACE_MODES:
            raise PolicyError("workspace_mount must be 'rw' or 'ro'")

    # ------------------------------------------------------------------ #
    # Wire shape
    # ------------------------------------------------------------------ #
    def to_dict(self) -> dict[str, Any]:
        """Every key, in :data:`PERMISSION_KEYS` order."""
        return {key: getattr(self, key) for key in PERMISSION_KEYS}

    def merged(self, partial: Mapping[str, Any] | None) -> "SandboxPolicy":
        """This policy with ``partial`` applied on top.

        Strict: an unknown key or a value of the wrong type raises
        :class:`PolicyError` and nothing is applied. ``1`` is not ``true``: a
        JSON number where a boolean belongs is refused.
        """
        if partial is None:
            return self
        if not isinstance(partial, Mapping):
            raise PolicyError("permissions must be an object")
        values = self.to_dict()
        for key, value in partial.items():
            if key not in values:
                raise PolicyError(f"unknown permission {str(key)[:40]!r}")
            if key in _BOOL_KEYS and not isinstance(value, bool):
                raise PolicyError(f"{key} must be true or false")
            if key == "workspace_mount" and value not in WORKSPACE_MODES:
                raise PolicyError("workspace_mount must be 'rw' or 'ro'")
            values[key] = value
        return SandboxPolicy(**values)

    @classmethod
    def from_dict(
        cls, data: Mapping[str, Any] | None, *, base: "SandboxPolicy | None" = None
    ) -> "SandboxPolicy":
        """``data`` (full or partial) on top of ``base`` (default: the defaults)."""
        return (base or cls()).merged(data)

    # ------------------------------------------------------------------ #
    # Enforcement helpers
    # ------------------------------------------------------------------ #
    @property
    def read_only_workspace(self) -> bool:
        return self.workspace_mount == WORKSPACE_RO

    def container_key(self) -> str:
        """The part of the policy a container is created with.

        ``secrets_env`` is in it: a secret the box got while the permission was
        on can still live in a tmux server, a background job or a file under
        ``/tmp``, and only a new box is sure to have none. ``user_browser`` is
        left out: it picks the browser target per task and never reached the
        box. No commas: the CLI prints labels as ``k=v,k=v``.
        """
        return (
            f"sudo={int(self.sudo)};network={int(self.network)};"
            f"workspace={self.workspace_mount};secrets={int(self.secrets_env)}"
        )

    def docker_run_args(self) -> tuple[str, ...]:
        """``docker run`` flags for this policy. Empty for the defaults, so a
        default agent's container is created exactly as it was before."""
        args: list[str] = []
        if not self.network:
            args += ["--network", "none"]
        if not self.sudo:
            args += ["--security-opt", "no-new-privileges", "-e", "AGENTS_SUDO=0"]
        if self.read_only_workspace:
            args += ["-e", f"AGENTS_BROWSER_PROFILE={READ_ONLY_BROWSER_PROFILE}"]
        return tuple(args)


#: The policy of an agent nobody configured: everything but the user's browser.
DEFAULT_POLICY = SandboxPolicy()

#: The sandbox backends, and which permissions each one really enforces.
#: ``user_browser`` is enforced by the executor, so it holds for both. The local
#: backend runs commands as the host user, with the host's sudo, network and
#: files; of the sandbox permissions it can only keep secrets out.
_ENFORCED_BY_KIND: dict[str, frozenset[str]] = {
    "docker": frozenset(PERMISSION_KEYS),
    "local": frozenset({"secrets_env", "user_browser", "external_agents"}),
    # Local commands inside bubblewrap (``AGENTS_LOCAL_ISOLATION``): the
    # network namespace and the read-only bind make ``network`` and
    # ``workspace_mount`` real. ``sudo`` is not: bwrap's ``no_new_privs``
    # forbids it whatever the switch says.
    "local-bwrap": frozenset(
        {"secrets_env", "user_browser", "external_agents", "network", "workspace_mount"}
    ),
}


def enforced_permissions(kind: str) -> dict[str, bool]:
    """``{permission: enforced}`` for a sandbox backend (``docker`` / ``local``).
    An unknown backend enforces nothing it cannot prove."""
    enforced = _ENFORCED_BY_KIND.get(
        kind, frozenset({"user_browser", "external_agents"})
    )
    return {key: key in enforced for key in PERMISSION_KEYS}

#: ``--pids-limit`` of every agent container: a fork bomb stops here, a
#: browser with its renderers stays well below it.
PIDS_LIMIT = 512

#: Capabilities the box keeps when ``sudo`` is on, after ``--cap-drop ALL``:
#: what root needs to install packages and run the entrypoint's uid remap
#: (chown, setuid/setgid to drop to the agent user, signals). Not kept:
#: ``NET_RAW`` (raw sockets, ARP/ICMP spoofing), ``MKNOD``, ``SYS_CHROOT``,
#: ``SETFCAP``, ``SETPCAP``.
SUDO_CAPS = (
    "CHOWN",
    "DAC_OVERRIDE",
    "FOWNER",
    "FSETID",
    "SETUID",
    "SETGID",
    "KILL",
    "NET_BIND_SERVICE",
    "AUDIT_WRITE",
)

#: Capabilities the box keeps with ``sudo`` off. The entrypoint runs as root
#: once (uid remap, sudoers removal, workspace chown); agent commands run as
#: the agent user through ``docker exec -u`` and never need one.
NO_SUDO_CAPS = ("CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID")


def hardening_run_args(policy: SandboxPolicy) -> tuple[str, ...]:
    """``docker run`` hardening for every agent container (research item 37):
    ``--cap-drop ALL`` plus the few capabilities the policy needs back,
    ``--pids-limit`` and, with ``sudo`` off, ``no-new-privileges`` (already in
    :meth:`SandboxPolicy.docker_run_args`).

    Not in the container key on purpose: an existing box keeps working and
    gets these flags the next time it is rebuilt (a policy or image change).

    The cloud metadata address (169.254.169.254) cannot be blocked from a
    ``docker run`` flag: that needs a host firewall rule, e.g.
    ``iptables -I DOCKER-USER -d 169.254.169.254 -j REJECT`` (root, once per
    host). With ``network`` off there is no route to it at all."""
    keep = SUDO_CAPS if policy.sudo else NO_SUDO_CAPS
    args = ["--cap-drop", "ALL"]
    for cap in keep:
        args += ["--cap-add", cap]
    args += ["--pids-limit", str(PIDS_LIMIT)]
    return tuple(args)


#: The container key a container from before the policy label was created
#: with. Such a container ran with every permission, so it matches the default.
DEFAULT_CONTAINER_KEY = DEFAULT_POLICY.container_key()

assert tuple(f.name for f in fields(SandboxPolicy)) == PERMISSION_KEYS
