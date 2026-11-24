"""The real :class:`~chuk_agents_host.gateways.base.GatewayHost`: the running
host (CHAT-184). Every call looks the executor up again, because the host
builds its task server only when the app provisions it, and may rebuild it.
"""

from __future__ import annotations

from typing import Any, Callable

from ..coworker_names import host_agent_id
from ..notification_text import DEFAULT_COWORKER


class HostBridge:
    def __init__(self, host: Any) -> None:
        self._host = host

    def _executor(self):
        party = getattr(self._host, "_party", None)
        server = party.task_server if party is not None else None
        if server is None:
            return None
        return server.supervisor.executor(self._host._agent.id)

    def ready(self) -> bool:
        return self._executor() is not None

    def subscribe(self, listener: Callable[[dict], None]) -> bool:
        executor = self._executor()
        if executor is None or not hasattr(executor, "add_event_listener"):
            return False
        executor.add_event_listener(listener)
        return True

    def submit(self, session_key: str, prompt: str, meta: dict) -> str | None:
        executor = self._executor()
        if executor is None:
            return None
        return executor.submit_task(session_key, prompt, meta)

    def stop(self, session_key: str) -> int:
        executor = self._executor()
        return executor.stop_session(session_key) if executor is not None else 0

    def resolve_approval(self, approval_id: str, approved: bool, scope: str | None) -> None:
        executor = self._executor()
        if executor is not None:
            executor.resolve_approval(approval_id, approved, scope)

    def default_agent(self) -> str:
        return host_agent_id(self._host._device_id)

    def agents(self) -> list[dict[str, Any]]:
        """This host's own agent first, then the agents the app registered."""
        own = self.default_agent()
        rows: list[dict[str, Any]] = []
        try:
            stored = list(self._host._coworker_names.list())
        except Exception:  # noqa: BLE001 — an unreadable roster is just the own agent
            stored = []
        own_name = next((r.get("name") for r in stored if r.get("host")), None)
        rows.append({"agent_id": own, "name": own_name or DEFAULT_COWORKER})
        for row in stored:
            if row.get("host") or not row.get("agent_id"):
                continue
            rows.append({"agent_id": row["agent_id"], "name": row.get("name") or row["agent_id"]})
        return rows

    def workspace_for(self, session_key: str) -> str | None:
        executor = self._executor()
        if executor is None:
            return None
        return executor.workspace_for(session_key)

    def secret(self, name: str) -> str | None:
        vault = getattr(self._host, "_secrets_vault", None)
        if vault is None:
            return None
        try:
            return vault.env().get(name) or None
        except Exception:  # noqa: BLE001
            return None
