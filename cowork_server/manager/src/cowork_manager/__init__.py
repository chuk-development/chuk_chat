"""CoWork Manager — the host control plane (§5 of the platform plan).

The Manager holds the agent roster, supervises per-agent sandboxes, runs the
scheduler (§13), and bridges the relay frame contract (§14). This package is the
control-plane skeleton: real container lifecycle and a real network relay wire in
later behind the interfaces defined here.
"""

from cowork_manager.containers import (
    ContainerSupervisor,
    WorkspaceResolver,
    roster_workspace_resolver,
)
from cowork_manager.names import random_name
from cowork_manager.roster import Agent, RosterStore
from cowork_manager.room_store import RoomStore
from cowork_manager.room_runner import (
    RoomContext,
    RoomOutcome,
    RoomRunner,
)
from cowork_manager.room_driver import (
    OFFLINE_REPLY,
    RoomDriver,
)
from cowork_manager.room_binding import RoomBinding
from cowork_manager.room_transcript import RoomTranscriptStore
from cowork_manager.group_room import (
    DEFAULT_MAX_MEMBERS,
    DEFAULT_MAX_ROUNDS,
    DEFAULT_MAX_MESSAGES_PER_SEND,
    AgentIdentity,
    GroupRoom,
    RoomCaps,
    RoomError,
    RoomMember,
    RoomSession,
    RoomTurn,
    parse_mentions,
    has_broadcast_mention,
    BROADCAST_HANDLES,
    assign_room_handles,
)
from cowork_manager.supervisor import (
    AgentSupervisor,
    RuntimeState,
    RuntimeStatus,
    StubSupervisor,
)
from cowork_manager.scheduler import (
    Job,
    JobMode,
    MonitorSignal,
    Scheduler,
    Ticker,
    parse_schedule,
    unified_diff,
)
from cowork_manager.autonomy import (
    JobDispatcher,
    ScheduleError,
    load_roster_schedules,
    Notification,
    NotificationKind,
    RunEvent,
    RunEventKind,
    RunHandle,
    RunOutcome,
    RunSpec,
    RunStatus,
    SILENT_MARKER,
    ThreadedRunHandle,
    UnattendedRunner,
    should_deliver,
)
from cowork_manager.relay import (
    CapabilityDescriptor,
    CorrelationMap,
    RelayBridge,
    Transport,
    build_upgrade_headers,
    decode_frames,
    encode_frame,
    make_error,
    make_request,
    make_response,
)

__all__ = [
    "random_name",
    "Agent",
    "RosterStore",
    "AgentIdentity",
    "assign_room_handles",
    "GroupRoom",
    "RoomStore",
    "RoomRunner",
    "RoomDriver",
    "RoomBinding",
    "RoomTranscriptStore",
    "OFFLINE_REPLY",
    "RoomContext",
    "RoomOutcome",
    "RoomCaps",
    "RoomError",
    "RoomMember",
    "RoomSession",
    "RoomTurn",
    "parse_mentions",
    "has_broadcast_mention",
    "BROADCAST_HANDLES",
    "DEFAULT_MAX_MEMBERS",
    "DEFAULT_MAX_ROUNDS",
    "DEFAULT_MAX_MESSAGES_PER_SEND",
    "AgentSupervisor",
    "ContainerSupervisor",
    "WorkspaceResolver",
    "roster_workspace_resolver",
    "RuntimeState",
    "RuntimeStatus",
    "StubSupervisor",
    "Job",
    "JobMode",
    "MonitorSignal",
    "Scheduler",
    "Ticker",
    "parse_schedule",
    "unified_diff",
    "JobDispatcher",
    "ScheduleError",
    "load_roster_schedules",
    "Notification",
    "NotificationKind",
    "RunEvent",
    "RunEventKind",
    "RunHandle",
    "RunOutcome",
    "RunSpec",
    "RunStatus",
    "SILENT_MARKER",
    "ThreadedRunHandle",
    "UnattendedRunner",
    "should_deliver",
    "CapabilityDescriptor",
    "CorrelationMap",
    "RelayBridge",
    "Transport",
    "build_upgrade_headers",
    "decode_frames",
    "encode_frame",
    "make_error",
    "make_request",
    "make_response",
]
