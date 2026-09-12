"""Room agents — one executor per room member (§16.1/4b).

``RoomBinding`` knows *which* member is reachable; this is what makes one
reachable. It is the piece ``docs/ROOMS_GOING_LIVE.md`` calls the multi-agent
host: for every coworker that is about to speak in a room, start **its own**
:class:`~cowork_executor.Executor` on **its own** loopback link, wrap a
:class:`~cowork_executor.ControllerSession` around the other end, and register
that as the member's task sender.

Why a second executor at all
----------------------------
The executor that carries the app's frames is the one inside ``on_room_frame``
when a room runs. It is single-threaded per task, so it cannot serve itself a
room turn — it would wait for an answer it is the one who has to produce. Every
room member therefore needs a runtime that is **not** the serving one. That is
this pool.

What a member costs
-------------------
A pooled member is one Python thread, one sealed in-process link, and one SQLite
file. It is **not** a second sandbox: the environment comes from the host's own
per-agent factory, so a coworker keeps the one box it already had (§6, bead
cowork-jo2) whether the app drives it or a room does. Members are started **on
demand** — when a room task names them — and kept warm after that, so a six-member
room that nobody opens costs nothing at all.

Lifecycle
---------
``ensure_room`` starts what a room needs and registers each sender in the
binding; ``release`` unregisters one member and stops its executor; ``shutdown``
does that for all of them. A member that cannot be started is simply not
registered, which the room renders as its offline placeholder — one member
failing never takes a room down.
"""

from __future__ import annotations

import hashlib
import threading
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameSealer,
    DeviceIdentity,
    derive_channel_key,
    generate_x25519_keypair,
)
from cowork_manager import RoomBinding, RoomMember
from cowork_sandbox import BaseEnvironment

from cowork_executor import (
    ControllerSession,
    Executor,
    ModelFactory,
    ModelSelect,
    SecretsVault,
    loopback_pair,
    make_room_task_sender,
)

#: How long one member's turn may take before the room treats it as no reply.
#: A room turn is a whole agent run, so this is generous, but it is bounded:
#: without it a wedged member would stall the whole exchange.
DEFAULT_TURN_TIMEOUT_SECONDS = 180.0

#: The frame key version this pool's in-process links use. Local to the pool —
#: these frames never leave the process.
KEY_VERSION = 1

#: Returns the model wiring to build one member's executor with, or ``(None, None)``
#: while the host has not provisioned an account yet. It takes the agent id, so a
#: host that one day gives a coworker its own model can answer per member — and a
#: test can script a different model per member.
ModelWiringProvider = Callable[
    [str], "tuple[ModelFactory | None, ModelSelect | None]"
]


@dataclass(frozen=True, slots=True)
class _Link:
    """One sealed in-process link: the two sides of a pairing that never happened
    over a wire, because both ends live in this process."""

    controller_sealer: CoworkFrameSealer
    controller_opener: CoworkFrameOpener
    executor_sealer: CoworkFrameSealer
    executor_opener: CoworkFrameOpener


def _sealed_link(agent_id: str) -> _Link:
    """Run the pairing math for one member's private link.

    Both ends are in this process, so the X25519 exchange and the mutual device
    approval happen here rather than over a relay. The frames are still sealed
    and still signed: the executor's default-deny opener is not bypassed for a
    local peer, it is simply handed the one device it should accept.
    """
    controller_private, controller_public = generate_x25519_keypair()
    executor_private, executor_public = generate_x25519_keypair()
    channel_key = derive_channel_key(controller_private, executor_public)
    assert channel_key == derive_channel_key(executor_private, controller_public)

    controller_device = f"room-controller:{agent_id}"
    executor_device = f"room-executor:{agent_id}"
    controller_identity = DeviceIdentity.generate()
    executor_identity = DeviceIdentity.generate()

    controller_approved = ApprovedDevices()
    controller_approved.approve(executor_device, executor_identity.public_key)
    executor_approved = ApprovedDevices()
    executor_approved.approve(controller_device, controller_identity.public_key)

    return _Link(
        controller_sealer=CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=controller_device,
            signing_identity=controller_identity,
        ),
        controller_opener=CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=controller_approved,
        ),
        executor_sealer=CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=executor_device,
            signing_identity=executor_identity,
        ),
        executor_opener=CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=executor_approved,
        ),
    )


@dataclass
class _Agent:
    """One running room member: its executor, its controller, and the room whose
    session key its sender currently writes to."""

    agent_id: str
    executor: Executor
    controller: ControllerSession
    room_id: str


class RoomAgentPool:
    """The host's per-member executors, and their registration in the binding.

    Thread-safe: rooms run on a party thread while ``shutdown`` may arrive on the
    main one, so the member table is guarded. Starting a member is done inside
    the lock on purpose — two rooms naming the same coworker at once must not
    race two executors onto one SQLite file.
    """

    def __init__(
        self,
        *,
        binding: RoomBinding,
        model_wiring: ModelWiringProvider,
        environment_factory: Callable[[str], BaseEnvironment],
        db_dir: str | Path,
        system_prompt: Callable[[str], str] | str,
        workspace_for: Callable[[str], str] | None = None,
        estop_path: str | None = None,
        secrets: SecretsVault | None = None,
        turn_timeout: float = DEFAULT_TURN_TIMEOUT_SECONDS,
        logger: Callable[[str], None] | None = None,
    ) -> None:
        self._binding = binding
        self._model_wiring = model_wiring
        self._environment_factory = environment_factory
        self._db_dir = Path(db_dir)
        self._system_prompt = (
            system_prompt
            if callable(system_prompt)
            else (lambda _agent_id, _p=system_prompt: _p)
        )
        self._workspace_for = workspace_for
        self._estop_path = estop_path
        self._secrets = secrets
        self._turn_timeout = turn_timeout
        self._log = logger or (lambda _msg: None)
        self._agents: dict[str, _Agent] = {}
        self._lock = threading.RLock()

    # -- state -----------------------------------------------------------

    @property
    def running_ids(self) -> frozenset[str]:
        with self._lock:
            return frozenset(self._agents)

    # -- lifecycle -------------------------------------------------------

    def ensure_room(
        self, room_id: str, members: Iterable[RoomMember]
    ) -> frozenset[str]:
        """Bring every member of ``room_id`` online and return the ids that are.

        Idempotent: a member already running is re-registered against this room's
        session key (``room:<room_id>``) so its turns land in that room's own
        thread on the executor side rather than in another room's. A member that
        fails to start is left out — the room runs with it offline instead of
        not running at all.
        """
        online: set[str] = set()
        for member in members:
            if self.ensure_member(room_id, member.agent_id):
                online.add(member.agent_id)
        return frozenset(online)

    def ensure_member(self, room_id: str, agent_id: str) -> bool:
        """Start (or re-point) one member and register its sender. ``False`` when
        it could not be started — no model wiring yet, or the executor refused."""
        if not agent_id:
            return False
        with self._lock:
            existing = self._agents.get(agent_id)
            if existing is None:
                started = self._start(agent_id, room_id)
                if started is None:
                    return False
                existing = started
            elif existing.room_id != room_id:
                existing.room_id = room_id
            self._binding.register(
                agent_id,
                make_room_task_sender(
                    existing.controller,
                    session_key=f"room:{room_id}",
                    timeout=self._turn_timeout,
                ),
            )
            return True

    def release(self, agent_id: str) -> None:
        """Take one member offline: unregister its sender first, then stop its
        executor. In that order, so no turn is ever routed at a runtime that is
        already on its way down."""
        with self._lock:
            agent = self._agents.pop(agent_id, None)
        self._binding.unregister(agent_id)
        if agent is None:
            return
        try:
            agent.executor.stop()
        except Exception as exc:  # noqa: BLE001 — a stuck member must not block
            self._log(
                f"[cowork-host] room member {agent_id} did not stop cleanly: "
                f"{type(exc).__name__}: {exc}"
            )

    def shutdown(self) -> None:
        """Stop every member and clear the binding of them."""
        with self._lock:
            ids = list(self._agents)
        for agent_id in ids:
            self.release(agent_id)

    # -- internals -------------------------------------------------------

    def _start(self, agent_id: str, room_id: str) -> _Agent | None:
        model_factory, model_select = self._model_wiring(agent_id)
        if model_factory is None:
            # No account provisioned yet: there is nothing to run a turn on, so
            # the member stays offline rather than a half-built executor being
            # registered as reachable.
            self._log(
                f"[cowork-host] room member {agent_id} stays offline: "
                "no model wiring yet"
            )
            return None
        try:
            environment = self._environment_factory(agent_id)
        except Exception as exc:  # noqa: BLE001 — one member, not the room
            self._log(
                f"[cowork-host] no sandbox for room member {agent_id}: "
                f"{type(exc).__name__}: {exc}"
            )
            return None

        link = _sealed_link(agent_id)
        controller_endpoint, executor_endpoint = loopback_pair()
        self._db_dir.mkdir(parents=True, exist_ok=True)
        executor = Executor(
            name=f"room:{agent_id}",
            endpoint=executor_endpoint,
            opener=link.executor_opener,
            sealer=link.executor_sealer,
            environment=environment,
            # Deliberately no ``environment_factory``: this executor serves ONE
            # agent, and its session keys are room ids. A factory here would hand
            # every room its own box and undo "one coworker, one sandbox".
            db_path=str(self._db_dir / f"{_db_name(agent_id)}.db"),
            model_factory=model_factory,
            model_select=model_select,
            system_prompt=self._system_prompt(agent_id),
            workspace=(
                self._workspace_for(agent_id)
                if self._workspace_for is not None
                else None
            ),
            estop_path=self._estop_path,
            secrets=self._secrets,
        )
        try:
            executor.start()
        except Exception as exc:  # noqa: BLE001 — one member, not the room
            self._log(
                f"[cowork-host] could not start room member {agent_id}: "
                f"{type(exc).__name__}: {exc}"
            )
            return None

        agent = _Agent(
            agent_id=agent_id,
            executor=executor,
            controller=ControllerSession(
                endpoint=controller_endpoint,
                sealer=link.controller_sealer,
                opener=link.controller_opener,
            ),
            room_id=room_id,
        )
        self._agents[agent_id] = agent
        self._log(f"[cowork-host] room member {agent_id} is online")
        return agent


def _db_name(agent_id: str, limit: int = 48) -> str:
    """A filesystem-safe name for one member's state file. Mirrors the host's own
    agent-directory rule: a readable slug plus a digest, because an agent id is
    whatever the app minted and may hold characters a path must not."""
    kept = [c if (c.isalnum() or c in "-_.") else "-" for c in agent_id]
    slug = "".join(kept).strip("-.")[:limit] or "agent"
    digest = hashlib.sha256(agent_id.encode("utf-8")).hexdigest()[:8]
    return f"{slug}-{digest}"
