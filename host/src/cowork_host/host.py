"""LocalHost — wires the relay, roster, pairing, and task server into one host.

This is the whole platform on one machine, no production relay:

- a :class:`~cowork_host.relay.LocalRelay` (blind localhost WebSocket router),
- a :class:`~cowork_manager.RosterStore` with a persistent per-agent workspace,
- a :class:`~cowork_crypto.Pairing` **initiator** whose code the app types in,
- a :class:`~cowork_host.party.HostParty` that pairs, provisions the account
  token, and serves tasks through the real :class:`~cowork_executor.Executor`.

For production the model factory is built from the provisioned Supabase token
(``resolve_backend_model_factory`` reads ``/v1/models_info`` once). Tests inject
``model_factory_override`` so no credits are spent and nothing hits prod.
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from cowork_agent import DEFAULT_MODEL_ID, SupabaseSession
from cowork_crypto import CoworkFrameOpener, CoworkFrameSealer, Pairing
from cowork_manager import Agent, RosterStore
from cowork_sandbox import make_environment

from cowork_executor import ModelFactory, resolve_backend_model_factory

from .identity import HOST_DEVICE_ID, load_or_create_identity
from .party import HostParty
from .protocol import ROLE_CONTROLLER
from .relay import EVENT_JOIN, EVENT_LEAVE, LocalRelay
from .serve import TaskServer

DEFAULT_WORKSPACE = "~/.cowork"
KEY_VERSION = 1
DEFAULT_SYSTEM_PROMPT = "You are a CoWork coworker running on the user's own machine."


class LocalHost:
    """One local host: relay + roster + pairing + supervised executor."""

    def __init__(
        self,
        *,
        port: int = 8787,
        workspace_dir: str = DEFAULT_WORKSPACE,
        model_id: str = DEFAULT_MODEL_ID,
        sandbox_kind: str = "local",
        host_addr: str = "127.0.0.1",
        agent_name: str | None = None,
        supabase_url: str | None = None,
        anon_key: str | None = None,
        # Deterministic pairing code for tests; random otherwise.
        channel_id: str | None = None,
        digits: str | None = None,
        sas_digits: int = 6,
        # Test seam: skip the real Supabase/backend and use this factory.
        model_factory_override: ModelFactory | None = None,
        logger: Callable[[str], None] | None = None,
    ) -> None:
        self._log = logger or (lambda _msg: None)
        self._host_addr = host_addr
        self._model_id = model_id
        self._sandbox_kind = sandbox_kind
        self._supabase_url = supabase_url
        self._anon_key = anon_key
        self._model_factory_override = model_factory_override

        self._workspace = Path(workspace_dir).expanduser()
        self._agents_dir = self._workspace / "agents"
        self._agents_dir.mkdir(parents=True, exist_ok=True)
        self._roster_path = str(self._workspace / "roster.db")
        self._db_path = str(self._workspace / "executor-state.db")

        self._roster = RosterStore(self._roster_path)
        self._agent = self._load_or_create_agent(agent_name)

        self._identity = load_or_create_identity(self._workspace / "host_device.key")
        self._device_id = HOST_DEVICE_ID

        # The printed pairing code is STABLE for the host's lifetime: the same
        # channel id + digits are shown once and reused for every connection. A
        # throwaway session normalises and validates them (and generates random
        # ones when not pinned) so the exact rules live in one place — ``Pairing``.
        probe = Pairing.initiator(
            device_id=self._device_id,
            device_identity=self._identity,
            sas_digits=sas_digits,
            channel_id=channel_id,
            digits=digits,
        )
        self._sas_digits = sas_digits
        self._channel_id = probe.channel_id
        self._pairing_code = probe.pairing_code
        self._digits = self._pairing_code.rpartition("-")[2]

        self._relay = LocalRelay(
            host_addr, port, logger=self._log, on_peer_event=self._on_peer_event
        )
        self._party: HostParty | None = None
        self._port = port

    def _pairing_factory(self) -> Pairing:
        """Mint a fresh initiator session — new ephemeral keys, new expiry, new
        (empty) trust store — reusing the stable printed code. One per controller
        connection, so a reconnect never meets an expired or consumed session."""
        return Pairing.initiator(
            device_id=self._device_id,
            device_identity=self._identity,
            sas_digits=self._sas_digits,
            channel_id=self._channel_id,
            digits=self._digits,
        )

    def _on_peer_event(self, channel: str, role: str, event: str, token: int) -> None:
        """Relay callback: route controller join/leave to the party so it can
        mint a fresh session per connection and reset on disconnect."""
        if role != ROLE_CONTROLLER:
            return
        party = self._party
        if party is None:
            return
        if event == EVENT_JOIN:
            party.on_controller_joined(token)
        elif event == EVENT_LEAVE:
            party.on_controller_left(token)

    # -- setup helpers ---------------------------------------------------

    def _load_or_create_agent(self, agent_name: str | None) -> Agent:
        if agent_name is not None:
            existing = self._roster.get_by_name(agent_name)
            if existing is not None:
                agent = existing
            else:
                agent = self._roster.create(
                    workspace_dir="",  # filled in below with the real path
                    persona=DEFAULT_SYSTEM_PROMPT,
                    name=agent_name,
                )
        else:
            roster_agents = self._roster.list()
            agent = (
                roster_agents[0]
                if roster_agents
                else self._roster.create(persona=DEFAULT_SYSTEM_PROMPT, workspace_dir="")
            )
        # Each agent owns a real workspace directory under the host.
        workspace = self._agents_dir / agent.name
        workspace.mkdir(parents=True, exist_ok=True)
        if agent.workspace_dir != str(workspace):
            updated = self._roster.update(agent.id, workspace_dir=str(workspace))
            if updated is not None:
                agent = updated
        return agent

    # -- lifecycle -------------------------------------------------------

    def start(self) -> None:
        """Start the relay and the host party. Non-blocking."""
        self._relay.start()
        self._port = self._relay.port
        self._party = HostParty(
            url=self.url,
            channel_id=self._channel_id,
            pairing_factory=self._pairing_factory,
            device_id=self._device_id,
            device_identity=self._identity,
            key_version=KEY_VERSION,
            build_task_server=self._build_task_server,
            logger=self._log,
            controller_token=lambda: self._relay.current_peer_token(
                self._channel_id, ROLE_CONTROLLER
            ),
        )
        self._party.start()

    def stop(self) -> None:
        if self._party is not None:
            self._party.stop()
            self._party = None
        self._relay.stop()
        self._roster.close()

    # -- observable pairing info ----------------------------------------

    @property
    def port(self) -> int:
        return self._port

    @property
    def url(self) -> str:
        return f"ws://{self._host_addr}:{self._port}"

    @property
    def channel_id(self) -> str:
        return self._channel_id

    @property
    def pairing_code(self) -> str:
        return self._pairing_code

    @property
    def agent(self) -> Agent:
        return self._agent

    @property
    def device_id(self) -> str:
        return self._device_id

    @property
    def party(self) -> HostParty | None:
        return self._party

    # -- model factory + task server wiring (called by HostParty) --------

    def _make_model_factory(self, token: dict) -> ModelFactory:
        if self._model_factory_override is not None:
            self._log("using injected model factory (no backend, no credits)")
            return self._model_factory_override
        supabase_url = token.get("supabase_url") or self._supabase_url
        anon_key = token.get("anon_key") or self._anon_key
        if not supabase_url or not anon_key:
            raise RuntimeError(
                "no Supabase URL / anon key: set --supabase-url and --anon-key "
                "(or SUPABASE_URL / SUPABASE_ANON_KEY) or provide them in the token"
            )
        session = SupabaseSession(
            access_token=token.get("access_token", ""),
            refresh_token=token.get("refresh_token", ""),
            supabase_url=supabase_url,
            anon_key=anon_key,
        )
        self._log("resolving a model from the account (one /v1/models_info call)...")
        return resolve_backend_model_factory(
            session, preferred_model_id=self._model_id
        )

    def _build_task_server(
        self,
        opener: CoworkFrameOpener,
        sealer: CoworkFrameSealer,
        token: dict,
        party: HostParty,
    ) -> TaskServer:
        model_factory = self._make_model_factory(token)
        environment = make_environment(
            self._sandbox_kind, workdir=self._agent.workspace_dir
        )
        # A fresh roster connection, opened in the party thread that will use it
        # (sqlite3 connections are single-thread). It reads the same roster file.
        serve_roster = RosterStore(self._roster_path)
        return TaskServer(
            roster=serve_roster,
            agent_id=self._agent.id,
            opener=opener,
            sealer=sealer,
            environment=environment,
            model_factory=model_factory,
            db_path=self._db_path,
            send_frame=party.send_result_frame,
            system_prompt=self._agent.persona or DEFAULT_SYSTEM_PROMPT,
        )
