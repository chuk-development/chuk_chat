"""LocalHost — wires the relay, roster, pairing, and task server into one host.

This is the whole platform on one machine, no production relay:

- a :class:`~cowork_host.relay.LocalRelay` (blind localhost WebSocket router),
- a :class:`~cowork_manager.RosterStore` with a persistent per-agent workspace,
- a :class:`~cowork_crypto.Pairing` **initiator** whose code the app types in,
- a :class:`~cowork_host.party.HostParty` that pairs, provisions the account
  token, and serves tasks through the real :class:`~cowork_executor.Executor`.

For production the model wiring is built from the provisioned Supabase token
(``resolve_backend_model_wiring`` reads ``/v1/models_info`` once and returns both
the default factory and the per-task selector). Tests inject
``model_factory_override``, which wires no selector, so no credits are spent and
nothing hits prod even when a task names a model.
"""

from __future__ import annotations

import hashlib
import os
import threading
from pathlib import Path
from typing import Callable

from cowork_agent import DEFAULT_MODEL_ID, StateStore, SupabaseSession
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
    ModelSelect,
    SecretsVault,
    encode_payload,
    frame_to_b64,
    resolve_backend_model_wiring,
)

from .identity import HOST_DEVICE_ID, derive_channel_id, load_or_create_identity
from .pairing_store import HostPairingStore, HostTrust
from .party import HostParty
from .protocol import ROLE_CONTROLLER
from .relay import EVENT_JOIN, EVENT_LEAVE, LocalRelay
from .room_service import RoomService, dispatch_room_frame
from .coworker_names import CoworkerNameStore, handle_agent_frame, host_agent_id
from .secrets_key import secrets_at_rest_key
from .seed_skills import seed_skills_dir, seed_workspace_skills
from .desktop_notify import DesktopNotifier
from .automations import AutomationManager
from .notify import SupabaseNotifier
from .serve import TaskServer

# Bead cowork-sq3: how long a run that ended with an app attached may go
# without the app's ``run_ack`` before it is announced as finished while away.
RUN_ACK_TIMEOUT_SECONDS = float(os.environ.get("COWORK_RUN_ACK_TIMEOUT_SECONDS", "15") or 15)

DEFAULT_WORKSPACE = "~/.cowork"
KEY_VERSION = 1
DEFAULT_SYSTEM_PROMPT = "You are a CoWork coworker running on the user's own machine."


def _agent_dirname(agent_id: str, limit: int = 32) -> str:
    """A filesystem-safe, collision-free directory name for one agent id.

    The readable part is for the person who opens the folder; the digest is what
    makes it unique, because two coworkers can carry the same name and an id can
    hold characters a path must not.
    """
    kept = [c if (c.isalnum() or c in "-_.") else "-" for c in agent_id]
    slug = "".join(kept).strip("-.")[:limit] or "agent"
    digest = hashlib.sha256(agent_id.encode("utf-8")).hexdigest()[:8]
    return f"{slug}-{digest}"


class LocalHost:
    """One local host: relay + roster + pairing + supervised executor."""

    def __init__(
        self,
        *,
        port: int = 8787,
        workspace_dir: str = DEFAULT_WORKSPACE,
        model_id: str = DEFAULT_MODEL_ID,
        provider_slug: str | None = None,
        reasoning_effort: str | None = None,
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
        self._provider_slug = provider_slug
        self._reasoning_effort = reasoning_effort
        self._sandbox_kind = sandbox_kind
        # The Playwright MCP + watchable browser (§9.1) ship in the browser image
        # only; on the base image the launcher script is absent, so leave it off.
        # The image is what COWORK_SANDBOX_IMAGE selects (resolve_image); "browser"
        # in the tag is the browser variant.
        self._browser_mcp = sandbox_kind == "docker" and (
            "browser" in os.environ.get("COWORK_SANDBOX_IMAGE", "").lower()
        )
        self._supabase_url = supabase_url
        self._anon_key = anon_key
        self._model_factory_override = model_factory_override
        # The provisioned account session, set once a model factory is resolved
        # from the token. The task server forwards its live access token to the
        # executor so ``appSession`` MCP connectors authenticate server-side.
        self._session: SupabaseSession | None = None

        self._workspace = Path(workspace_dir).expanduser()
        self._agents_dir = self._workspace / "agents"
        self._agents_dir.mkdir(parents=True, exist_ok=True)
        self._roster_path = str(self._workspace / "roster.db")
        self._db_path = str(self._workspace / "executor-state.db")
        # Bead cowork-sq3: a live ``done`` the app never acknowledged. One timer
        # per run, armed when the run ends with an app attached, cancelled by
        # its ``run_ack``; on expiry the run is treated as finished while away
        # and announced like one (desktop toast + cloud push, deduped by
        # ``notified_at``). Guarded: the executor's serve thread arms, the
        # ack arrives on the same thread, the timer fires on its own.
        self._ack_pending: dict[str, threading.Timer] = {}
        self._ack_lock = threading.Lock()
        # The app-free kill switch (§7.1): `touch ~/.cowork/ESTOP` stops the run.
        self._estop_path = str(self._workspace / "ESTOP")

        self._roster = RosterStore(self._roster_path)
        self._agent = self._load_or_create_agent(agent_name)
        # The names the user chose in the app (docs/WIRE_CONTRACT.md, "Coworker
        # names"): own table in the roster file, own connection (any thread).
        self._coworker_names = CoworkerNameStore(self._roster_path, device_id=HOST_DEVICE_ID)

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
            # The resolver is keyed by agent id on purpose (bead cowork-jo2):
            # a lambda that ignored it would bind-mount the host agent's
            # workspace into EVERY coworker's container, so two coworkers would
            # read and write each other's files even with two containers.
            self._containers = ContainerSupervisor(
                workspace_resolver=self._workspace_for_agent,
            )
        # The environments handed out per agent, so one agent keeps ONE box
        # across its turns. The host agent's own environment is built when the
        # task server is, and registered here under every name it answers to.
        self._environments: dict[str, BaseEnvironment] = {}

        self._identity = load_or_create_identity(self._workspace / "host_device.key")
        self._device_id = HOST_DEVICE_ID

        # The user's secret set (docs/WIRE_CONTRACT.md, "Secrets"): one per
        # user, global for every agent and session on this host. Held in
        # memory, written at rest under a key derived from the host identity,
        # loaded here so a restart with no app attached still has the keys.
        # ``secrets_vault.env`` is the one reader of the values (the sandbox
        # child processes, and cowork-94's watcher processes).
        self._secrets_vault = SecretsVault(
            path=self._workspace / "secrets.enc",
            key=secrets_at_rest_key(self._identity),
        )
        loaded = self._secrets_vault.load()
        if loaded:
            self._log(f"[cowork-host] loaded {loaded} secret name(s) at rest")

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
        # The sealer of the current controller session (set when its task server
        # is built), for host-originated frames such as reprovision_request.
        self._sealer: CoworkFrameSealer | None = None
        # An ``account_session_rotated`` frame the app has not acknowledged yet
        # (bead cowork-c91): the host refreshed on its own while no controller
        # was attached, so the app's pair is dead until it adopts this one.
        self._pending_session_rotation: dict | None = None
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
        # Drop the shipped seed skills in so a fresh coworker can act on a
        # YouTube link (and future seeds) out of the box. Non-destructive: an
        # agent's own skills are never overwritten.
        seeded = seed_workspace_skills(workspace)
        if seeded:
            self._log(f"[cowork-host] seeded skills for {agent.name}: {', '.join(seeded)}")
        if agent.workspace_dir != str(workspace):
            updated = self._roster.update(agent.id, workspace_dir=str(workspace))
            if updated is not None:
                agent = updated
        return agent

    # -- lifecycle -------------------------------------------------------

    def start(self) -> None:
        """Start the relay and the host party. Non-blocking."""
        self._reap_orphan_containers()
        self._sweep_orphan_runs()
        # The desktop channel for "your answer is ready" when no app is attached
        # (docs/WIRE_CONTRACT.md). Needs no cloud; a no-op without a display.
        self._desktop_notifier = DesktopNotifier()
        # The cloud channel (P7): a row with the user's own token, then the
        # Edge Function pushes to the user's devices. Best-effort, outboxed.
        self._notifier = SupabaseNotifier(
            session_provider=lambda: self._session,
            user_id_provider=lambda: getattr(self, "_user_id", "") or "",
            agent_provider=lambda: (self._agent.id, self._agent.name),
            db_path=self._db_path,
            desktop=self._desktop_notifier,
            logger=self._log,
        )
        # Automations (docs/WIRE_CONTRACT.md, "Automations"): the clock, the
        # watcher supervisor and the self-wake watchdog. Started before the
        # party: a persisted watcher must run again whether or not an app
        # ever connects; a fire before provisioning is retried per tick.
        vault = getattr(self, "_secrets_vault", None)
        self._automations = AutomationManager(
            db_path=self._db_path,
            workspace=self._agent.workspace_dir or str(self._agents_dir / self._agent.name),
            fire=self._fire_automation,
            busy=self._automation_busy,
            send=self._send_host_payload,
            env_provider=getattr(vault, "env", None),
            # Only a container sandbox needs the environment (for the
            # ``docker exec`` prefix); a local watcher is a local process.
            environment_provider=(
                self._make_environment if self._containers is not None else None
            ),
            estop_path=self._estop_path,
            logger=self._log,
        )
        # Background jobs (docs/WIRE_CONTRACT.md, "Interactive shell and
        # background commands"): the same trigger tail, a second consumer. A
        # finished job wakes the agent through the executor's job router.
        self._automations.register_trigger_consumer("job", self._on_job_trigger)
        try:
            self._automations.start()
        except Exception as exc:  # noqa: BLE001 — automations must not block startup
            self._log(f"could not start automations: {type(exc).__name__}: {exc}")
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
            on_reprovision=self._on_reprovision,
        )
        self._party.start()

    def stop(self) -> None:
        automations = getattr(self, "_automations", None)
        if automations is not None:
            automations.stop()
        if self._party is not None:
            self._party.stop()
            self._party = None
        self._relay.stop()
        self._cancel_ack_timers()
        if self._containers is not None:
            # Releases the handles. The agent's own container is deliberately left
            # in place: it is the box the agent installed into, and the next start
            # reuses it (§6). Task-scoped children are removed by their cleanup.
            self._containers.shutdown()
        self._roster.close()
        self._coworker_names.close()

    def _sweep_orphan_runs(self) -> None:
        """A run still ``running`` in the store was cut off by a crash or a
        restart of this host. Close it as failed so no client ever sees a stale
        run as live (docs/WIRE_CONTRACT.md)."""
        try:
            store = StateStore(self._db_path)
            try:
                swept = store.sweep_orphan_runs()
            finally:
                store.close()
        except Exception as exc:  # noqa: BLE001 — a sweep must not block startup
            self._log(f"could not sweep orphan runs: {type(exc).__name__}: {exc}")
            return
        if swept:
            self._log(f"closed {swept} run(s) left running by a previous host process")

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

    @property
    def secrets_vault(self) -> SecretsVault:
        """The user's secret set (docs/WIRE_CONTRACT.md, "Secrets"). Callers
        that start a child process take ``secrets_vault.env()``; nothing else
        reads the values."""
        return self._secrets_vault

    # -- model factory + task server wiring (called by HostParty) --------

    def _make_environment(self) -> BaseEnvironment:
        """This host agent's own execution environment.

        ``docker`` goes through the supervisor, so the agent gets **its** labelled
        container with the workspace bind-mounted and reused across turns.
        ``local`` runs on the host itself in the same workspace directory.
        """
        return self._environment_for(self._agent.id)

    # -- one sandbox per agent (§6, bead cowork-jo2) ---------------------

    def _primary_agent_ids(self) -> tuple[str, ...]:
        """The keys that mean "this host's own coworker".

        The app calls it ``host:<device id>`` (the id it got at pairing), the
        roster calls it by its row id, and a client that names no session at all
        gets it too. All three are ONE agent and therefore one box.
        """
        return ("", "default", self._agent.id, host_agent_id(self._device_id))

    def _is_own_coworker(self, agent_id: str) -> bool:
        """True when the app registered this id as a coworker of its own.

        The app sends ``agent_create`` for every coworker the user makes, with
        the id that is also its ``session_key``. That registration is what makes
        a key a coworker; a key nobody registered — an old client's ``default``,
        a thread key from a test double — stays on this host's own agent, which
        is what it has always been. Guessing the other way round would hand a
        typo its own container and its own empty workspace.
        """
        if not agent_id or agent_id in self._primary_agent_ids():
            return False
        try:
            return any(
                row.get("agent_id") == agent_id and not row.get("host")
                for row in self._coworker_names.list()
            )
        except Exception:  # noqa: BLE001 — an unreadable roster is not a new agent
            return False

    def _agent_key(self, session_key: str) -> str:
        """The coworker a session key belongs to: itself, or this host's agent."""
        return session_key if self._is_own_coworker(session_key) else self._agent.id

    def _workspace_for_agent(self, agent_id: str) -> str:
        """The host directory an agent works in — one per agent, never shared.

        The host's own coworker keeps the directory it always had. Every other
        coworker gets ``<agents dir>/<name>-<digest of its id>``: the digest is
        what makes it collision-free, because a coworker name is whatever the
        user typed and two of them can read alike.
        """
        if self._agent_key(agent_id) == self._agent.id:
            return self._agent.workspace_dir or str(self._agents_dir / self._agent.name)
        workspace = self._agents_dir / _agent_dirname(agent_id)
        if not workspace.exists():
            workspace.mkdir(parents=True, exist_ok=True)
            # Only on the first look: the shipped seed skills go in once, so a
            # new coworker can act out of the box. Re-seeding on every call
            # would put a disk walk behind a status request.
            seeded = seed_workspace_skills(workspace)
            if seeded:
                self._log(
                    f"[cowork-host] seeded skills for {agent_id}: {', '.join(seeded)}"
                )
        return str(workspace)

    def _environment_for(self, session_key: str) -> BaseEnvironment:
        """That coworker's sandbox: its own container, its own workspace.

        Cached per coworker, so one coworker talks to the SAME box across its
        turns. With the docker backend the box is a container labelled with that
        agent id (``cowork.agent``); with the local backend it is that agent's
        own directory. Either way two coworkers never share one.
        """
        key = self._agent_key(session_key)
        existing = self._environments.get(key)
        if existing is not None:
            return existing
        workdir = self._workspace_for_agent(key)
        if self._containers is not None:
            environment = self._containers.environment(key)
        else:
            environment = make_environment("local", workdir=workdir)
        self._environments[key] = environment
        return environment

    def _make_model_wiring(
        self, token: dict
    ) -> tuple[ModelFactory, ModelSelect | None]:
        """Build the default model factory and, in production, the per-task model
        selector. The mock/override path returns no selector, so an offline run
        always uses the injected factory and spends no credits regardless of what
        model a task names."""
        if self._model_factory_override is not None:
            self._log("using injected model factory (no backend, no credits)")
            return self._model_factory_override, None
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
        # Keep the live session so the task server can hand its (refreshable)
        # access token to the executor for appSession MCP connectors.
        self._session = session
        # Who may refresh (bead cowork-c91): with a controller attached the APP
        # is the token source — the host asks it to re-provision and waits;
        # with none attached the host refreshes itself and reports the rotated
        # pair back. Wired here so every client built off this session obeys it.
        session.may_self_refresh = lambda: not self._controller_attached()
        session.request_reprovision = self._request_reprovision
        session.on_self_refreshed = self._on_session_self_refreshed
        # A (re)connecting app that already adopted a rotated pair acks it here.
        self._note_incoming_token(token)
        # The account owner, for the notification rows (owner-only RLS).
        self._user_id = str(token.get("user_id") or "")
        self._log("resolving a model from the account (one /v1/models_info call)...")
        return resolve_backend_model_wiring(
            session, preferred_model_id=self._model_id,
            preferred_provider=self._provider_slug, reasoning_effort=self._reasoning_effort
        )

    def _build_task_server(
        self,
        opener: CoworkFrameOpener,
        sealer: CoworkFrameSealer,
        token: dict,
        party: HostParty,
    ) -> TaskServer:
        # This session's sealer, for frames the host itself originates.
        self._sealer = sealer
        model_factory, model_select = self._make_model_wiring(token)
        # A fresh controller connection: hand over any pair the host rotated
        # while nobody was attached (unless this provision already carried it).
        self._flush_pending_session_rotation()
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
            # One sandbox per agent (bead cowork-jo2): every session key that is
            # not this host's own coworker gets its own container/workspace.
            environment_factory=self._environment_for,
            model_factory=model_factory,
            model_select=model_select,
            db_path=self._db_path,
            send_frame=party.send_result_frame,
            system_prompt=self._agent.persona or DEFAULT_SYSTEM_PROMPT,
            workspace=self._agent.workspace_dir or None,
            estop_path=self._estop_path,
            on_room_frame=lambda payload: dispatch_room_frame(room_service, payload),
            # appSession MCP connectors (GitHub etc.) authenticate server-side
            # with the account token; read it live off the session so a refresh
            # carries to the next task.
            account_token_provider=(
                (lambda: self._session.access_token if self._session else None)
            ),
            account_session_provider=lambda: self._session,
            browser_mcp=self._browser_mcp,
            # Run ownership (docs/WIRE_CONTRACT.md): the run outlives the socket;
            # the host is told when it ends, when it waits on an approval, and
            # when a later account frame carries fresh tokens.
            on_run_finished=self._on_run_finished,
            on_approval_pending=self._on_approval_pending,
            on_account_frame=self._on_reprovision,
            # The app rendered a live ``done`` (docs/WIRE_CONTRACT.md,
            # ``run_ack``): disarm that run's while-away timer.
            on_run_ack=self._on_run_ack,
            # The secret set every task injects and masks against.
            secrets=self._secrets_vault,
            on_secret_request_pending=self._on_secret_request_pending,
            # Automations: the manager for the session-scoped tools, and the
            # app's control / list frames.
            automations=getattr(self, "_automations", None),
            on_automation_frame=self._on_automation_frame,
            # Skills (docs/WIRE_CONTRACT.md, "Skills"): the executor answers the
            # app's ``skills_list`` / ``skill_control`` itself; the seed root
            # tells it which of the workspace's skills are the shipped ones.
            skills_seed_root=(lambda d: str(d) if d else None)(seed_skills_dir()),
            # A finished background job's ``job`` frame, when no run of its
            # session is live to carry it.
            job_frame_sender=self._send_host_payload,
            # Coworker names (docs/WIRE_CONTRACT.md, "Coworker names").
            on_agent_frame=self._on_agent_frame,
        )

    # -- run ownership hooks (docs/WIRE_CONTRACT.md) ----------------------

    def _on_reprovision(self, token: dict) -> None:
        """A later ``account_authentication`` frame: refresh the live Supabase
        session in place. The model factory closes over this object, so every
        later model call carries the new token with no rebuild. This is also
        the fix for a host token going stale when the app rotates its refresh
        token mid-session."""
        session = self._session
        if session is None or not isinstance(token, dict):
            return
        access = token.get("access_token")
        refresh = token.get("refresh_token")
        if isinstance(access, str) and access:
            session.access_token = access
        if isinstance(refresh, str) and refresh:
            session.refresh_token = refresh
        expires = token.get("expires_at")
        if isinstance(expires, (int, float)) and not isinstance(expires, bool):
            session.expires_at = float(expires)
        user_id = token.get("user_id")
        if isinstance(user_id, str) and user_id:
            self._user_id = user_id
        self._log("account session refreshed in place from a new token frame")
        # An app that adopted our rotated pair sends it back: that is the ack.
        self._note_incoming_token(token)
        # Wake a refresh that is waiting for exactly this frame (c91).
        session.mark_reprovisioned()
        # A fresh token is the moment to retry what could not be delivered.
        notifier = getattr(self, "_notifier", None)
        if notifier is not None:
            notifier.flush_outbox()

    # -- account session: who refreshes, and how the pair stays in sync (c91) --

    def _send_host_payload(self, payload: dict) -> bool:
        """Seal a host-originated payload with the current session's sealer and
        send it to the attached app. False when there is no session or no
        controller (the party drops frames while none is attached)."""
        party, sealer = self._party, self._sealer
        if party is None or sealer is None or not self._controller_attached():
            return False
        try:
            sealed = sealer.seal(encode_payload(payload))
            party.send_result_frame(frame_to_b64(sealed.to_bytes()))
            return True
        except Exception as exc:  # noqa: BLE001 — a relay hiccup must not raise into a refresh
            self._log(f"could not send {payload.get('type')}: {type(exc).__name__}")
            return False

    def _request_reprovision(self, reason: str) -> None:
        """Ask the attached app for a fresh token pair (docs/WIRE_CONTRACT.md
        ``reprovision_request``). The app answers with a normal
        ``account_authentication`` frame, which lands in ``_on_reprovision``."""
        self._log(f"asking the app to re-provision ({reason})")
        self._send_host_payload({"type": "reprovision_request", "reason": reason})

    def _on_session_self_refreshed(self, session: SupabaseSession) -> None:
        """The host refreshed on its own (no controller attached) and GoTrue
        rotated the pair — the app's copy is now dead. Report the new pair
        (``account_session_rotated``): now if someone is attached, else pending
        until the next connect, until the app acks by sending it back."""
        from datetime import UTC, datetime

        payload = {
            "type": "account_session_rotated",
            "access_token": session.access_token,
            "refresh_token": session.refresh_token,
            "rotated_at": datetime.now(UTC).isoformat(),
        }
        if session.expires_at is not None:
            payload["expires_at"] = session.expires_at
        self._pending_session_rotation = payload
        self._log("account session refreshed by the host; reporting the rotated pair")
        self._flush_pending_session_rotation()

    def _flush_pending_session_rotation(self) -> None:
        """Send the unacknowledged rotated pair if a controller is attached. The
        frame stays pending until acked — a send while detached is dropped by the
        party, and we cannot know delivery, only adoption."""
        pending = self._pending_session_rotation
        if pending is not None:
            self._send_host_payload(pending)

    def _note_incoming_token(self, token: dict) -> None:
        """An ``account_authentication`` frame carrying the refresh token the host
        rotated to means the app adopted the pair: the rotation is acknowledged."""
        pending = self._pending_session_rotation
        if pending is None or not isinstance(token, dict):
            return
        if token.get("refresh_token") == pending.get("refresh_token"):
            self._pending_session_rotation = None
            self._log("rotated account session acknowledged by the app")

    def _controller_attached(self) -> bool:
        party = self._party
        return bool(party is not None and party.controller_attached)

    def _on_run_finished(self, summary: dict) -> None:
        """A run ended on this host. With an app attached the user is watching
        the stream; with none, tell them another way. Here: the desktop
        notification. The cloud push is added by the notification phase on the
        same hook. The notification never carries the answer.

        A fired automation (``origin == "automation"``) is unattended by
        definition: the desktop toast fires even with a controller attached
        (its ``done`` says ``host_notified`` so the app draws no second one);
        the cloud push still only when nobody is attached."""
        attached = self._controller_attached()
        # ``automation`` and ``job`` runs are unattended by definition.
        automation = isinstance(summary, dict) and summary.get("origin") in ("automation", "job")
        if attached and not automation:
            # The user is (supposedly) watching. Hold the announcement until the
            # app confirms it rendered the ``done`` (``run_ack``); if that never
            # comes, the answer must not stay unannounced (Bead cowork-sq3).
            self._arm_ack_timer(summary)
            return
        notifier = getattr(self, "_notifier", None)
        if notifier is None:
            return
        if attached:
            # Attached + automation: desktop only, once per run.
            desktop = getattr(self, "_desktop_notifier", None)
            if desktop is not None and notifier._mark_notified_once(str(summary.get("run_id") or "")):
                from .desktop_notify import completion_text

                failed = bool(summary.get("error")) or str(summary.get("reason") or "") == "failed"
                title, body = completion_text(self._agent.name, failed=failed)
                desktop.notify(title, body)
            return
        # Desktop toast + cloud push, one per run, on a background thread.
        notifier.notify_run_finished(summary)

    # -- run_ack delivery confirmation (Bead cowork-sq3) -------------------

    def _arm_ack_timer(self, summary: dict) -> None:
        """Start the while-away clock for a run that ended with an app attached.
        A second ``done`` for the same run (a retry) restarts the clock."""
        run_id = str(summary.get("run_id") or "") if isinstance(summary, dict) else ""
        if not run_id:
            return
        timer = threading.Timer(
            RUN_ACK_TIMEOUT_SECONDS, self._on_ack_timeout, args=(run_id, summary)
        )
        timer.daemon = True
        with self._ack_lock:
            old = self._ack_pending.pop(run_id, None)
            self._ack_pending[run_id] = timer
        if old is not None:
            old.cancel()
        timer.start()

    def _on_run_ack(self, payload: dict) -> None:
        """The app rendered the live ``done``: the run is seen, no announcement."""
        run_id = str(payload.get("run_id") or "") if isinstance(payload, dict) else ""
        if not run_id:
            return
        with self._ack_lock:
            timer = self._ack_pending.pop(run_id, None)
        if timer is not None:
            timer.cancel()

    def _on_ack_timeout(self, run_id: str, summary: dict) -> None:
        """No ``run_ack`` within the window: the app was attached but did not
        show the answer (backgrounded, a socket half-open, a lost frame). Treat
        the run as finished while away: the same desktop toast + cloud push a
        detached run gets, once per run (``notified_at``). ``seen_at`` stays
        unset, so the next replay says ``while_away`` too."""
        with self._ack_lock:
            if self._ack_pending.pop(run_id, None) is None:
                return  # acked or cancelled in the meantime
        notifier = getattr(self, "_notifier", None)
        if notifier is None:
            return
        try:
            self._log(f"run {run_id}: no run_ack within {RUN_ACK_TIMEOUT_SECONDS:.0f}s, notifying")
            notifier.notify_run_finished(summary)
        except Exception:  # noqa: BLE001 — a notifier must never take the host down
            pass

    def _cancel_ack_timers(self) -> None:
        with self._ack_lock:
            timers = list(self._ack_pending.values())
            self._ack_pending.clear()
        for timer in timers:
            timer.cancel()

    # -- automations (docs/WIRE_CONTRACT.md, "Automations") ---------------

    def _fire_automation(self, session_key: str, prompt: str, meta: dict) -> str | None:
        """Start the task a fired automation asks for. ``None`` when the host
        has no provisioned task server yet (restarted, no app since): the
        manager retries at its next tick."""
        party = self._party
        server = party.task_server if party is not None else None
        if server is None:
            return None
        executor = server.supervisor.executor(self._agent.id)
        if executor is None:
            return None
        return executor.submit_task(session_key, prompt, meta)

    def _automation_busy(self, session_key: str) -> bool:
        """True while that thread still has an automation/user run queued or
        in flight. A watcher reports on its own cadence, which is faster than
        a model round: without this gate every report starts another run and
        the queue grows until the numbers on screen are hours old."""
        party = self._party
        server = party.task_server if party is not None else None
        if server is None:
            return False
        executor = server.supervisor.executor(self._agent.id)
        if executor is None:
            return False
        return executor.has_live_run(session_key)

    def _on_job_trigger(self, record: dict) -> None:
        """A ``kind: job`` line in the trigger file: a background job ended
        (docs/WIRE_CONTRACT.md, "The wake-up"). Handed to the executor's job
        router, which wakes the model. With no provisioned task server the
        line is dropped here; the executor's start-up sweep (``.exit`` without
        ``.woken``) catches the job once the app has provisioned the host."""
        party = self._party
        server = party.task_server if party is not None else None
        if server is None:
            self._log(f"[jobs] job {record.get('job_id')} ended but the host is not provisioned; swept at the next task server")
            return
        executor = server.supervisor.executor(self._agent.id)
        if executor is None:
            return
        try:
            outcome = executor.job_finished(record)
        except Exception as exc:  # noqa: BLE001 — the tail must keep running
            self._log(f"[jobs] wake for {record.get('job_id')} failed: {type(exc).__name__}: {exc}")
            return
        self._log(f"[jobs] job {record.get('job_id')} exit {record.get('exit_code')} -> {outcome}")

    def _on_automation_frame(self, payload: dict) -> list[dict] | None:
        """The app's ``automation_control`` / ``automation_list``. The app is
        the user: it may manage every automation of this host, so no session
        scope is applied here (the tools apply it)."""
        manager = getattr(self, "_automations", None)
        if manager is None or not isinstance(payload, dict):
            return None
        if payload.get("type") == "automation_list":
            key = payload.get("session_key")
            return manager.list(key if isinstance(key, str) and key else None)
        automation_id = payload.get("id")
        action = payload.get("action")
        if isinstance(automation_id, str) and isinstance(action, str):
            result = manager.control(None, automation_id, action)
            if not result.get("ok"):
                self._log(f"automation {action} {automation_id}: {result.get('error')}")
        return None

    def _on_agent_frame(self, payload: dict) -> list[dict]:
        """The app's ``agent_create`` / ``agent_rename`` / ``agent_list``: keep
        the name, answer with the current list."""
        return handle_agent_frame(self._coworker_names, payload, log=self._log)

    def _on_secret_request_pending(self, info: dict) -> None:
        """A run is blocked on ``request_secrets`` and no app is attached to
        show the dialog: nudge the user on the desktop. Names only, never a
        value (there is none yet)."""
        if self._controller_attached():
            return
        notifier = getattr(self, "_desktop_notifier", None)
        if notifier is None:
            return
        names = info.get("names") if isinstance(info, dict) else None
        listed = ", ".join(str(n) for n in names) if isinstance(names, list) else ""
        try:
            notifier.notify(
                f"{self._agent.name} needs an API key",
                f"Open the app to enter: {listed}" if listed else "Open the app to enter it",
            )
        except Exception:  # noqa: BLE001 — a toast must never take a run down
            pass

    def _on_approval_pending(self, info: dict) -> None:
        """A run is blocked on a here.now publish approval. With no app attached
        the user cannot see the card, so nudge them to open the app."""
        if self._controller_attached():
            return
        notifier = getattr(self, "_notifier", None)
        if notifier is not None:
            notifier.notify_approval_pending(info)

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
