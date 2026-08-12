"""CoWork Manager — the host control plane (§5 of the platform plan).

The Manager holds the agent roster, supervises per-agent sandboxes, runs the
scheduler (§13), and bridges the relay frame contract (§14). This package is the
control-plane skeleton: real container lifecycle and a real network relay wire in
later behind the interfaces defined here.
"""

from cowork_manager.names import random_name
from cowork_manager.roster import Agent, RosterStore
from cowork_manager.supervisor import (
    AgentSupervisor,
    RuntimeState,
    RuntimeStatus,
    StubSupervisor,
)
from cowork_manager.scheduler import (
    Job,
    JobMode,
    Scheduler,
    parse_schedule,
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
    "AgentSupervisor",
    "RuntimeState",
    "RuntimeStatus",
    "StubSupervisor",
    "Job",
    "JobMode",
    "Scheduler",
    "parse_schedule",
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
