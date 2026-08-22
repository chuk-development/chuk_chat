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

import threading
from pathlib import Path
from typing import Callable

from cowork_agent import DEFAULT_MODEL_ID, SupabaseSession
from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameSealer,
    Pairing,
    ReconnectHandshake,
)
from cowork_manager import (
    Agent,
    ContainerSupervisor,
    RoomBinding,
    RoomStore,
    RoomTranscriptStore,
    RosterStore,
)
from cowork_sandbox import BaseEnvironment, make_environment

from cowork_executor import (
    ModelFactory,
    encode_payload,
    frame_to_b64,
    resolve_backend_model_factory,
)

from .identity import HOST_DEVICE_ID, derive_channel_id, load_or_create_identity
from .pairing_store import HostPairingStore, HostTrust
from .party import HostParty
from .protocol import ROLE_CONTROLLER
from .relay import EVENT_JOIN, EVENT_LEAVE, LocalRelay
from .room_service import RoomService, dispatch_room_frame
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
        # Deliberate re-pair: drop any stored trust at startup and mint a fresh,
        # single-use code (``cowork-host --pair``).
        force_repair: bool = False,
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
        # The app-free kill switch (§7.1): `touch ~/.cowork/ESTOP` stops the run.
        self._estop_path = str(self._workspace / "ESTOP")

        self._roster = RosterStore(self._roster_path)
        self._agent = self._load_or_create_agent(agent_name)

        # Group rooms (§16.1). The stores are SQLite files (opened per party
        # thread, like the roster); the binding is pure-Python and thread-safe,
        # so it is a persistent field. Rooms outlive a single pairing session.
        self._room_store_path = str(self._workspace / "rooms.db")
        self._room_transcript_path = str(self._workspace / "room-transcript.db")
        self._room_binding = RoomBinding()

        # The container lifecycle (§6) is only built for the docker backend: one
        # labelled container per agent, its workspace bind-mounted, reused across
        # turns. The local backend has no lifecycle to supervise.
        self._containers: ContainerSupervisor | None = None
        if sandbox_kind == "docker":
            self._containers = ContainerSupervisor(
                workspace_resolver=lambda _aid: self._agent.workspace_dir or None,
            )

        self._identity = load_or_create_identity(self._workspace / "host_device.key")
        self._device_id = HOST_DEVICE_ID

        # Persistent trust: after the first §15 pairing this file holds the stable
        # channel, the channel key and the app's approved device key, so every
        # later connection reconnects with no code.
        self._store = HostPairingStore(self._workspace / "paired.json")
        if force_repair:
            self._store.clear()
            self._trust: HostTrust | None = None
        else:
            self._trust = self._store.load()

        # The channel id is STABLE across restarts: an explicit override wins (for
        # tests), else the stored pairing's channel, else a deterministic value
        # derived from the host's long-term key. A stable channel is what lets the
        # app find this same host again after either side restarts.
        resolved_channel_id = (
            channel_id
            or (self._trust.channel_id if self._trust is not None else None)
            or derive_channel_id(self._identity)
        )
        if not resolved_channel_id or "-" in resolved_channel_id:
            raise ValueError("channel_id must be non-empty and must not contain '-'")

        self._sas_digits = sas_digits
        self._channel_id = resolved_channel_id
        # The pairing code is guarded because it is mutated from the party thread
        # (the moment a pairing completes) and read from the relay's peer-event
        # threads (when a controller joins).
        self._code_lock = threading.Lock()
        self._pairing_code: str | None = None
        self._digits: str | None = None
        if self._trust is None:
            # Never paired: mint the ONE code this host will ever offer. A
            # throwaway session normalises and validates the parts (and picks
            # random digits when not pinned), so the rules live in one place.
            probe = Pairing.initiator(
                device_id=self._device_id,
                device_identity=self._identity,
                sas_digits=sas_digits,
                channel_id=self._channel_id,
                digits=digits,
            )
            self._pairing_code = probe.pairing_code
            self._digits = probe.pairing_code.rpartition("-")[2]
        # else: a trust record exists, so NO code is generated at all. There is
        # nothing to print, nothing to type, and nothing an attacker can replay —
        # the only way in is the signed reconnect handshake.

        self._relay = LocalRelay(
            host_addr, port, logger=self._log, on_peer_event=self._on_peer_event
        )
        self._party: HostParty | None = None
        self._port = port

    def _pairing_factory(self) -> Pairing | None:
        """Mint a fresh initiator session — new ephemeral keys, new expiry, new
        (empty) trust store — for the printed code. One per controller connection,
        so an interrupted attempt never leaves the next one facing an expired
        session.

        Returns ``None`` once the code has been **consumed**: a code buys exactly
        one successful pairing. After that this host only accepts the signed
        reconnect handshake, and a new code needs ``cowork-host --pair``."""
        with self._code_lock:
            code = self._pairing_code
            digits = self._digits
        if code is None or digits is None:
            return None
        return Pairing.initiator(
            device_id=self._device_id,
            device_identity=self._identity,
            sas_digits=self._sas_digits,
            channel_id=self._channel_id,
            digits=digits,
        )

    def _burn_pairing_code(self) -> bool:
        """Destroy the pairing code so it can never be used a second time.
        Returns True if a live code was destroyed."""
        with self._code_lock:
            burned = self._pairing_code is not None
            self._pairing_code = None
            self._digits = None
        return burned

    def _reconnect_factory(
        self,
    ) -> tuple[ReconnectHandshake, bytes, ApprovedDevices] | None:
        """Mint a fresh reconnect initiator from the stored trust, or ``None`` when
        no pairing is stored (so the party pairs from a code instead)."""
        trust = self._trust
        if trust is None:
            return None
        handshake = ReconnectHandshake.initiator(
            device_id=self._device_id,
            device_identity=self._identity,
            peer_device_id=trust.peer_device_id,
            peer_public_key=trust.peer_public_key,
            channel_id=self._channel_id,
        )
        return handshake, trust.channel_key, trust.approved_devices()

    def _persist_pairing(self, pairing: Pairing) -> None:
        """Store the trust record from a freshly completed pairing so the next
        connection reconnects with no code. Also flips this host into reconnect
        mode in-process, for the very next controller.

        The code is burned FIRST, before anything that could fail: a code that has
        bought one pairing is dead even if persisting the trust then fails."""
        if self._burn_pairing_code():
            self._log("pairing code consumed — it will never be accepted again")
        peer_device_id = pairing.peer_device_id
        peer_public_key = (
            None
            if peer_device_id is None
            else pairing.approved_devices.lookup(peer_device_id)
        )
        if peer_device_id is None or peer_public_key is None:
            self._log(
                "paired but the peer device key is missing; trust NOT stored — "
                "re-pair with `cowork-host --pair`"
            )
            return
        trust = HostTrust(
            channel_id=self._channel_id,
            channel_key=pairing.channel_key,
            peer_device_id=peer_device_id,
            peer_public_key=peer_public_key,
        )
        self._store.save(trust)
        self._trust = trust
        self._log("pairing persisted; future connections reconnect with no code")

    @property
    def has_stored_pairing(self) -> bool:
        """True when a trust record exists, so the host reconnects (no code)."""
        return self._trust is not None

    def forget_pairing(self) -> bool:
        """Delete the stored trust and mint one fresh, single-use pairing code —
        the deliberate "pair a new device" action behind ``cowork-host --pair``.
        Returns True if a stored record was removed."""
        removed = self._store.clear()
        self._trust = None
        probe = Pairing.initiator(
            device_id=self._device_id,
            device_identity=self._identity,
            sas_digits=self._sas_digits,
            channel_id=self._channel_id,
        )
        with self._code_lock:
            self._pairing_code = probe.pairing_code
            self._digits = probe.pairing_code.rpartition("-")[2]
        return removed

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
        self._reap_orphan_containers()
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
            reconnect_factory=self._reconnect_factory,
            on_pair_established=self._persist_pairing,
        )
        self._party.start()

    def stop(self) -> None:
        if self._party is not None:
            self._party.stop()
            self._party = None
        self._relay.stop()
        if self._containers is not None:
            # Releases the handles. The agent's own container is deliberately left
            # in place: it is the box the agent installed into, and the next start
            # reuses it (§6). Task-scoped children are removed by their cleanup.
            self._containers.shutdown()
        self._roster.close()

    def _reap_orphan_containers(self) -> None:
        """Remove containers a killed previous run left behind (§6 orphan reaper).

        Startup is the only safe moment for this: nothing of ours is running yet,
        so every managed container found is by definition an orphan.
        """
        if self._containers is None:
            return
        reaped = self._containers.reap_orphans()
        if reaped:
            self._log(
                f"reaped {len(reaped)} orphaned agent container(s) from a previous run"
            )

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
    def pairing_code(self) -> str | None:
        """The one code this host will accept, or ``None`` once it has been used
        (or when a stored pairing means no code was ever minted)."""
        with self._code_lock:
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

    def _make_environment(self) -> BaseEnvironment:
        """The agent's execution environment for one served session.

        ``docker`` goes through the supervisor, so the agent gets **its** labelled
        container with the workspace bind-mounted and reused across turns.
        ``local`` runs on the host itself in the same workspace directory.
        """
        if self._containers is not None:
            return self._containers.environment(self._agent.id)
        return make_environment("local", workdir=self._agent.workspace_dir)

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
        environment = self._make_environment()
        # A fresh roster connection, opened in the party thread that will use it
        # (sqlite3 connections are single-thread). It reads the same roster file.
        serve_roster = RosterStore(self._roster_path)

        # A RoomService for this session: the room stores are opened here, in the
        # party thread that will use them (sqlite3 is single-thread), reading the
        # same files across sessions; the binding is the host's persistent one.
        # ``emit`` seals a room reply and sends it to the app over this session's
        # channel, the same path the executor's own results take.
        def emit(payload: dict) -> None:
            sealed = sealer.seal(encode_payload(payload))
            party.send_result_frame(frame_to_b64(sealed.to_bytes()))

        room_service = RoomService(
            room_store=RoomStore(self._room_store_path),
            binding=self._room_binding,
            emit=emit,
            transcript=RoomTranscriptStore(self._room_transcript_path),
        )

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
            workspace=self._agent.workspace_dir or None,
            estop_path=self._estop_path,
            on_room_frame=lambda payload: dispatch_room_frame(room_service, payload),
        )

    @property
    def estop_path(self) -> str:
        """The file-sentinel ESTOP for this host (§7.1), the way to stop a run
        **without the app**: ``touch ~/.cowork/ESTOP``.

        Every run and every subagent on this host checks it at the top of each
        round, so an engaged sentinel ends the current run and refuses new work
        until the file is removed again. It needs no phone, no pairing and no
        network — a shell on this machine is enough, which is what makes it the
        fallback when the app is the thing that is broken.
        """
        return self._estop_path
