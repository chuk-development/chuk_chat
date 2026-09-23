# Rooms: going live (the one gated step)

Group rooms (§16.1) are built and tested on every layer that does not need live
multi-agent transport. This is the runbook for the last step — making a room
drive **real** members — which is gated because it spends credits and touches the
prod relay. Everything it wires already exists; nothing new needs designing.

## What already works (local, proven by tests)

- `manager/group_room.py` — caps, `@mention` routing (`@all` too), `RoomSession`.
- `manager/room_store.py`, `room_transcript.py` — durable rooms + transcripts.
- `manager/room_driver.py` (`RoomDriver`) — routes each turn to its member.
- `manager/room_binding.py` (`RoomBinding`) — the reachable-member registry.
- `executor/room_sender.py` (`make_room_task_sender`) — one member's turn over
  the sealed relay. **Proven end to end** in `executor/tests/test_room_sender.py`:
  `RoomBinding → RoomDriver → two real encrypted executors` over the loopback.
- `host/room_service.py` (`RoomService`, `dispatch_room_frame`) — receives the
  app's room frames (via the executor's `on_room_frame`) and drives the room.
- App: full room UI, offline→host sync (reconcile on open, delete-flush on
  reconnect), reconnect auto-rebind.
- `host/room_agents.py` (`RoomAgentPool`) — one executor + `ControllerSession`
  per member, registered in the binding on demand. **This is what used to be
  missing**; with it a member answers instead of reporting offline.

## Done: the per-member senders are registered

`host/room_agents.py` (`RoomAgentPool`) is the multi-agent host. For every
coworker a room is about to run, it starts **its own** `Executor` on **its own**
sealed loopback, wraps a `ControllerSession` around the other end, and registers
`make_room_task_sender(...)` in the host's `RoomBinding`. `RoomService` calls it
through one new seam, `members_ready`, at the top of `handle_room_task`, so
members are started **on demand** — a room nobody opens costs nothing — and stay
warm for the next message. `LocalHost.stop()` shuts them all down, which
unregisters every sender.

A member is one thread, one sealed in-process link and one SQLite file. It is
**not** a second sandbox: the environment comes from `LocalHost._environment_for`,
so a coworker keeps the one box it already had (§6, bead cowork-jo2) whether the
app drives it or a room does. A six-member room therefore adds six executor
threads on top of the containers those coworkers already have.

What is proven, with mock models and no credits, in
`host/tests/test_room_live.py`: three members all answer through `RoomService`;
**agent A writes `@cobalt` and agent B speaks next**; members appear only when a
room runs and disappear on shutdown; a member whose runtime cannot start is one
offline line, not a dead room; and no model wiring yet is offline, not a crash.

## How it is wired: register per-member senders

`RoomService` drives members via `self._binding.member_runner()`. A member is
online only when the host has called `binding.register(agent_id, sender)` for it.
Wire that as each member agent's executor connects:

```python
# on the host, when agent <agent_id>'s executor is running and reachable:
from chuk_agents_executor import make_room_task_sender
sender = make_room_task_sender(controller, session_key=f"room:{room_id}")
room_binding.register(agent_id, sender)          # -> member is now online
# on disconnect:
room_binding.unregister(agent_id)
```

`self._room_binding` is a persistent field on `LocalHost`, and `RoomAgentPool`
now makes exactly these two calls.

## The real constraint: one executor per member, not the serving one

A room turn sends a task to a member's executor and waits for its answer. The
executor that is **handling the room frame cannot also serve itself** — it is
inside `on_room_frame` and single-threaded, so a self-directed task would
deadlock. So each room member needs **its own executor** (its own loopback +
`ControllerSession`), separate from the one the party frames arrive on.

`LocalHost` used to run exactly one agent/executor. Going live therefore meant:

1. **Multi-agent host** — start an executor per roster agent that is a room
   member (each its own `BaseEnvironment`/container, §6, and its own
   `ControllerSession` over its own loopback). This spends model credits per
   member, so it is gated. **Done:** `RoomAgentPool`, started on demand per room
   task; the environment is the coworker's existing one, so two members are two
   boxes only because they are two coworkers.
2. Register each with `make_room_task_sender(...) → room_binding.register(...)`.
   **Done:** `RoomAgentPool.ensure_member`, per room, with session key
   `room:<room_id>`.
3. **Prod relay** — point Agents at the prod `relay-crossreplica` endpoint
   (`docs/AGENTS_AGENT_PLATFORM_PLAN.md` §14; the chat-side fix already shipped as
   `d0732c1`). This is the "can take chat down" deploy — do it with a human.

## Verify without prod first — done

`host/tests/test_room_live.py` is that test: N members through the **host's**
`RoomService` (not a bare `RoomDriver`), each member a loopback executor with a
`MockModelClient`, each registered in the binding by the pool. It exercises the
production path with no credits and no relay. Run it with
`cd host && uv run pytest tests/test_room_live.py`.

## Checklist

- [x] Multi-agent host: one executor + `ControllerSession` per member agent.
      (`host/room_agents.py`, `RoomAgentPool`.)
- [x] Register/unregister senders in `_room_binding` on connect/disconnect.
      (`RoomAgentPool.ensure_room` / `.release` / `.shutdown`, called from
      `RoomService(members_ready=...)` and `LocalHost.stop()`.)
- [x] Local mock-model test: a room drives N members through `RoomService`.
      (`host/tests/test_room_live.py`, five cases, no relay and no credits.)
- [ ] Point at the prod relay (with a human; it can take chat down).
- [ ] One small real-credit room run to confirm end to end.
