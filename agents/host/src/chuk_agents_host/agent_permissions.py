"""Per-agent sandbox permissions, kept by the host (docs/WIRE_CONTRACT.md,
"Agent permissions", bead chuk_chat-voq3).

The host is the truth. The app reads and switches the permissions of one
coworker with two sealed frames and draws what the host answers. Everything is
allowed by default; the user switches single permissions off in the app.

Storage: one JSON file in the host's state directory
(``agent_permissions.json``, mode 0600). Only the keys the user set are stored,
per agent, so a default that changes later still reaches every agent that
never touched that switch. The file is rewritten atomically on every change.

Per-action approvals (docs/WIRE_CONTRACT.md, "Per-action approvals", bead
chuk_chat-mxxm) live in the same file, under ``approvals``: per agent, the
mode the user set for each action class and the allowed sites. They ride the
same two frames (``approvals`` next to ``permissions``) and, unlike the
sandbox switches, apply from the next action, also inside a running task.

Enforcement is not here. The sandbox carries the policy
(:class:`chuk_agents_sandbox.SandboxPolicy`): the host hands every per-agent
environment a *provider* over this store, and the executor reads that provider
once at the start of each task. So a change applies from the next task on and
never in the middle of one.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from chuk_agents_runtime.action_policy import (
    ACTION_CLASSES,
    SCOPE_AGENT,
    SCOPE_SITE,
    ActionPolicy,
    ActionPolicyError,
)
from chuk_agents_sandbox import (
    PERMISSION_KEYS,
    BaseEnvironment,
    DockerEnvironment,
    PolicyError,
    SandboxPolicy,
    enforced_permissions,
)

#: The file in the state directory.
FILE_NAME = "agent_permissions.json"
_FILE_VERSION = 1

#: App -> host: read one coworker's permissions.
FRAME_GET = "agent_permissions_get"
#: App -> host: change some of them (a partial map).
FRAME_SET = "agent_permissions_set"
#: Host -> app: the whole, current set (the answer to both).
FRAME_REPLY = "agent_permissions"
FRAMES = (FRAME_GET, FRAME_SET)

#: When a change takes effect. Always the next task: the executor reads the
#: policy at a task's start, and a container is only rebuilt there.
APPLIES_FROM = "next_task"
#: When an approvals change takes effect: the next action, also in a running
#: task (the runtime reads the policy at every call).
APPROVALS_APPLY_FROM = "next_action"

#: What the host says it can do (``host_route.capabilities``): the app sends
#: the permission frames only to a host that names this.
CAPABILITY = "agent_permissions"
#: The host also keeps per-action approvals (``approvals`` in the same frames,
#: the ``options`` / ``scope`` of ``approval_request`` / ``approval_decision``).
APPROVALS_CAPABILITY = "action_approvals"

MAX_AGENT_ID_LEN = 256


def host_defaults(*, user_browser: bool = False) -> SandboxPolicy:
    """The policy of an agent the user never configured.

    Everything is on, except the user's own browser. A host whose operator set
    ``AGENTS_BROWSER_TARGET=user_browser`` (the old host-wide switch) passes
    ``user_browser=True``, so its agents keep the add-on until the user
    switches it off per agent.
    """
    return SandboxPolicy(user_browser=bool(user_browser))


class AgentPermissionsStore:
    """The per-agent overrides, in memory and in one JSON file.

    Thread-safe: the executor's serve thread answers the frames while its worker
    thread reads a provider at a task's start.
    """

    def __init__(
        self,
        path: str | os.PathLike[str] | None,
        *,
        defaults: SandboxPolicy | None = None,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._path = Path(path) if path is not None else None
        self._defaults = defaults or host_defaults()
        self._log = log or (lambda _msg: None)
        self._lock = threading.Lock()
        self._approvals: dict[str, ActionPolicy] = {}
        self._overrides: dict[str, dict[str, Any]] = self._load()

    @property
    def defaults(self) -> SandboxPolicy:
        return self._defaults

    @property
    def path(self) -> Path | None:
        return self._path

    # ------------------------------------------------------------------ #
    # Reads
    # ------------------------------------------------------------------ #
    def get(self, agent_id: str) -> SandboxPolicy:
        """The agent's current policy: its overrides on top of the defaults."""
        with self._lock:
            stored = dict(self._overrides.get(agent_id, {}))
        try:
            return self._defaults.merged(stored)
        except PolicyError:
            # Only a hand-edited file gets here; its entry was checked on load.
            return self._defaults

    def provider_for(self, agent_id: str) -> Callable[[], SandboxPolicy]:
        """A live reader for one agent. The environment calls it at a task's
        start (``refresh_policy``); it always returns a policy."""
        return lambda: self.get(agent_id)

    def overrides(self) -> dict[str, dict[str, Any]]:
        """Every stored override, for diagnostics and tests."""
        with self._lock:
            return {agent: dict(values) for agent, values in self._overrides.items()}

    def approvals(self, agent_id: str) -> ActionPolicy:
        """The agent's per-action approval policy (the defaults when unset)."""
        with self._lock:
            return self._approvals.get(agent_id) or ActionPolicy()

    # ------------------------------------------------------------------ #
    # Writes
    # ------------------------------------------------------------------ #
    def update(self, agent_id: str, partial: Mapping[str, Any]) -> SandboxPolicy:
        """Apply ``partial`` to the agent and persist it. Returns the new policy.

        Raises :class:`PolicyError` for an unknown key or a wrong value, and
        then nothing changes: not the memory, not the file.
        """
        if not isinstance(partial, Mapping):
            raise PolicyError("permissions must be an object")
        with self._lock:
            stored = dict(self._overrides.get(agent_id, {}))
            policy = self._defaults.merged({**stored, **partial})  # validates
            stored.update(partial)
            before = self._overrides.get(agent_id)
            self._overrides[agent_id] = stored
            try:
                self._save_locked()
            except OSError:
                if before is None:
                    self._overrides.pop(agent_id, None)
                else:
                    self._overrides[agent_id] = before
                raise
        return policy

    def update_approvals(self, agent_id: str, partial: Mapping[str, Any]) -> ActionPolicy:
        """Apply an app ``set`` of approvals and persist it. Raises
        :class:`ActionPolicyError` for a bad change; nothing changes then."""
        with self._lock:
            before = self._approvals.get(agent_id)
            policy = (before or ActionPolicy()).updated(partial)
            self._put_approvals_locked(agent_id, policy, before)
        return policy

    def remember_approval(
        self, agent_id: str, action_class: str, scope: str, site: str | None = None
    ) -> ActionPolicy | None:
        """Store a decision with a lasting scope (``always_this_agent`` /
        ``always_this_site``). Returns the new policy, or ``None`` when
        nothing changed (``once``, ``deny``, a site already covered)."""
        if action_class not in ACTION_CLASSES or scope not in (SCOPE_AGENT, SCOPE_SITE):
            return None
        with self._lock:
            before = self._approvals.get(agent_id)
            current = before or ActionPolicy()
            policy = current.remembered(action_class, scope, site)
            if policy == current:
                return None
            self._put_approvals_locked(agent_id, policy, before)
        return policy

    def _put_approvals_locked(
        self, agent_id: str, policy: ActionPolicy, before: ActionPolicy | None
    ) -> None:
        if policy.to_stored():
            self._approvals[agent_id] = policy
        else:
            self._approvals.pop(agent_id, None)
        try:
            self._save_locked()
        except OSError:
            if before is None:
                self._approvals.pop(agent_id, None)
            else:
                self._approvals[agent_id] = before
            raise

    # ------------------------------------------------------------------ #
    # File
    # ------------------------------------------------------------------ #
    def _load(self) -> dict[str, dict[str, Any]]:
        if self._path is None or not self._path.exists():
            return {}
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            self._log(f"[permissions] unreadable {self._path.name}: {type(exc).__name__}")
            return {}
        approvals = raw.get("approvals") if isinstance(raw, dict) else None
        if isinstance(approvals, dict):
            for agent_id, values in approvals.items():
                if not isinstance(agent_id, str):
                    continue
                try:
                    self._approvals[agent_id] = ActionPolicy.from_stored(values)
                except ActionPolicyError as exc:
                    self._log(f"[permissions] dropped the approvals of {agent_id!r}: {exc}")
        agents = raw.get("agents") if isinstance(raw, dict) else None
        if not isinstance(agents, dict):
            return {}
        out: dict[str, dict[str, Any]] = {}
        for agent_id, values in agents.items():
            if not isinstance(agent_id, str) or not isinstance(values, dict):
                continue
            try:
                self._defaults.merged(values)
            except PolicyError as exc:
                self._log(f"[permissions] dropped the entry of {agent_id!r}: {exc}")
                continue
            out[agent_id] = dict(values)
        return out

    def _save_locked(self) -> None:
        if self._path is None:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        document: dict[str, Any] = {"version": _FILE_VERSION, "agents": self._overrides}
        approvals = {
            agent: policy.to_stored()
            for agent, policy in self._approvals.items()
            if policy.to_stored()
        }
        if approvals:
            document["approvals"] = approvals
        body = json.dumps(document, indent=2, sort_keys=True)
        fd, tmp = tempfile.mkstemp(prefix=".agent_permissions.", dir=self._path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(body + "\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


# ---------------------------------------------------------------------- #
# Environments
# ---------------------------------------------------------------------- #


def permissions_env_factory(
    store: AgentPermissionsStore,
    factory: Callable[..., BaseEnvironment] = DockerEnvironment,
) -> Callable[..., BaseEnvironment]:
    """An ``env_factory`` for :class:`chuk_agents_manager.ContainerSupervisor`
    that gives every environment its agent's policy provider.

    The supervisor calls it with ``agent_id=`` (the agent the box belongs to)
    and the usual docker options. A task-scoped child of that agent (a subagent)
    gets the same provider, so it never has more permissions than its parent.
    """

    def build(**kwargs: Any) -> BaseEnvironment:
        agent_id = str(kwargs.get("agent_id") or "default")
        kwargs.setdefault("policy_provider", store.provider_for(agent_id))
        return factory(**kwargs)

    return build


# ---------------------------------------------------------------------- #
# Frames
# ---------------------------------------------------------------------- #


def permissions_payload(
    agent_id: str,
    policy: SandboxPolicy | None,
    *,
    enforced: Mapping[str, bool] | None = None,
    error: str | None = None,
    approvals: ActionPolicy | None = None,
) -> dict[str, Any]:
    """The ``agent_permissions`` reply: every key, which ones this host really
    enforces, and when a change applies. ``policy`` is ``None`` only when there
    is no agent to report (then ``error`` says why). ``approvals`` adds the
    agent's per-action approval policy (docs/WIRE_CONTRACT.md, "Per-action
    approvals")."""
    payload: dict[str, Any] = {
        "type": FRAME_REPLY,
        "agent_id": agent_id,
        "applies_from": APPLIES_FROM,
        "enforced": dict(enforced) if enforced is not None else enforced_permissions("docker"),
    }
    if policy is not None:
        payload["permissions"] = policy.to_dict()
    if approvals is not None:
        payload["approvals"] = {**approvals.to_dict(), "applies_from": APPROVALS_APPLY_FROM}
    if error:
        payload["error"] = error
    return payload


def handle_permissions_frame(
    store: AgentPermissionsStore,
    payload: Mapping[str, Any],
    *,
    key_for: Callable[[str], str | None] | None = None,
    enforced: Mapping[str, bool] | None = None,
    log: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], SandboxPolicy | None, SandboxPolicy | None]:
    """Answer one ``agent_permissions_get`` / ``agent_permissions_set``.

    Returns ``(reply, before, after)``: ``before`` / ``after`` are the policy
    of a ``set`` that changed something, else ``None`` (the host restarts
    what a narrower policy must not keep, and tells its other devices).

    ``key_for`` maps the app's agent id to the key the sandbox is kept under
    (the host maps ``host:<device id>`` to its own agent) and returns ``None``
    for an id this host does not know: that is an error, never the host agent.
    The reply names the agent id the app sent, so the app can file it.

    The answer is always ``agent_permissions``, never a bare ``error``: the
    app reads a bare error as the end of a run. A refused ``set`` changes
    nothing and answers with the current set plus ``error``.
    """
    kind = payload.get("type") if isinstance(payload, Mapping) else None
    raw_id = payload.get("agent_id") if isinstance(payload, Mapping) else None
    agent_id = raw_id if isinstance(raw_id, str) and len(raw_id) <= MAX_AGENT_ID_LEN else ""

    def refused(error: str, policy: SandboxPolicy | None = None, approvals=None):
        reply = permissions_payload(
            agent_id, policy, enforced=enforced, error=error, approvals=approvals
        )
        return reply, None, None

    if kind not in FRAMES:
        return refused(f"unknown permissions frame {str(kind)[:40]!r}")
    if not agent_id:
        return refused("agent_permissions needs an agent_id")
    key = key_for(agent_id) if key_for is not None else agent_id
    if not key:
        return refused(f"unknown agent {agent_id[:80]!r}")
    current = store.get(key)
    current_approvals = store.approvals(key)
    if kind == FRAME_GET:
        reply = permissions_payload(
            agent_id, current, enforced=enforced, approvals=current_approvals
        )
        return reply, None, None

    partial = payload.get("permissions")
    approvals_partial = payload.get("approvals")
    if partial is None and approvals_partial is not None:
        partial = {}
    if not isinstance(partial, Mapping):
        return refused("permissions must be an object", current, current_approvals)
    unknown = [k for k in partial if k not in PERMISSION_KEYS]
    if unknown:
        return refused(
            f"unknown permission {str(unknown[0])[:40]!r}", current, current_approvals
        )
    # Check both halves before either is written: a refused set changes nothing.
    try:
        store.defaults.merged({**store.overrides().get(key, {}), **partial})
        if approvals_partial is not None:
            current_approvals.updated(approvals_partial)
    except (PolicyError, ActionPolicyError) as exc:
        return refused(str(exc), current, current_approvals)
    try:
        policy = store.update(key, partial) if partial else current
        approvals = (
            store.update_approvals(key, approvals_partial)
            if approvals_partial is not None
            else current_approvals
        )
    except (PolicyError, ActionPolicyError) as exc:
        return refused(str(exc), store.get(key), store.approvals(key))
    except OSError as exc:
        return refused(f"could not save: {type(exc).__name__}", store.get(key), store.approvals(key))
    if log is not None:
        changed = ", ".join(f"{k}={partial[k]}" for k in partial)
        if approvals_partial is not None:
            changed = ", ".join(x for x in (changed, "approvals") if x)
        log(f"[permissions] {key}: {changed or 'no change'}")
    reply = permissions_payload(agent_id, policy, enforced=enforced, approvals=approvals)
    if policy == current and approvals == current_approvals:
        return reply, None, None
    return reply, current, policy


class ActionApprovalsBridge:
    """The executor's view of the approval policies (``Executor(action_approvals=)``).

    ``policy_for(session_key)`` maps the run's session key to the coworker it
    belongs to (``agent_key``) and reads that coworker's policy;
    ``remember(...)`` stores a lasting decision and calls ``on_change(key,
    policy)`` when it changed something, so the host can tell the app."""

    def __init__(
        self,
        store: AgentPermissionsStore,
        agent_key: Callable[[str], str],
        *,
        on_change: Callable[[str, ActionPolicy], None] | None = None,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._store = store
        self._agent_key = agent_key
        self._on_change = on_change
        self._log = log or (lambda _msg: None)

    def policy_for(self, session_key: str) -> ActionPolicy:
        return self._store.approvals(self._agent_key(session_key))

    def remember(self, session_key: str, action_class: str, scope: str, site: str = "") -> None:
        key = self._agent_key(session_key)
        try:
            policy = self._store.remember_approval(key, action_class, scope, site)
        except OSError as exc:
            self._log(f"[approvals] could not save a decision: {type(exc).__name__}")
            return
        if policy is None:
            return
        self._log(f"[approvals] {key}: {action_class} {scope}")
        if self._on_change is not None:
            try:
                self._on_change(key, policy)
            except Exception as exc:  # noqa: BLE001 — telling the app is best effort
                self._log(f"[approvals] could not announce a change: {type(exc).__name__}")


def restart_watchers(manager: Any, log: Callable[[str], None] | None = None) -> list[str]:
    """End every running automation watcher so the watchdog starts it again.

    Used when the host agent's ``secrets_env`` goes off: a watcher got the
    secret set as its environment when it started, and only a new process is
    sure to have none. The watchdog relaunches an active row on its next tick,
    through the same ``env_provider`` that now returns nothing.
    """
    running = []
    try:
        running = list(manager.running_watchers())
        watchers = getattr(manager, "_watchers", {})
        lock = getattr(manager, "_lock", None)
        for automation_id in running:
            if lock is not None:
                with lock:
                    watcher = watchers.get(automation_id)
            else:
                watcher = watchers.get(automation_id)
            if watcher is not None:
                manager._kill(watcher)
    except Exception as exc:  # noqa: BLE001 — a watcher hiccup must not refuse the change
        if log is not None:
            log(f"[permissions] could not restart the watchers: {type(exc).__name__}")
    if log is not None and running:
        log(f"[permissions] restarted {len(running)} watcher(s) without secrets")
    return running
