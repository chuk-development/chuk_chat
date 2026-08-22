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

So a room already: syncs to the host, drives its members through `RoomDriver`,
and streams turns back — **but every member reports offline**, because nothing
registers a per-member `TaskSender` in the host's `RoomBinding`.

## The one thing left: register per-member senders

`RoomService` drives members via `self._binding.member_runner()`. A member is
online only when the host has called `binding.register(agent_id, sender)` for it.
Wire that as each member agent's executor connects:

```python
# on the host, when agent <agent_id>'s executor is running and reachable:
from cowork_executor import make_room_task_sender
sender = make_room_task_sender(controller, session_key=f"room:{room_id}")
room_binding.register(agent_id, sender)          # -> member is now online
# on disconnect:
room_binding.unregister(agent_id)
```

`self._room_binding` is already a persistent field on `LocalHost`. The senders
are the only missing call.

## The real constraint: one executor per member, not the serving one

A room turn sends a task to a member's executor and waits for its answer. The
executor that is **handling the room frame cannot also serve itself** — it is
inside `on_room_frame` and single-threaded, so a self-directed task would
deadlock. So each room member needs **its own executor** (its own loopback +
`ControllerSession`), separate from the one the party frames arrive on.

Today `LocalHost` runs exactly one agent/executor. Going live therefore means:

1. **Multi-agent host** — start an executor per roster agent that is a room
   member (each its own `BaseEnvironment`/container, §6, and its own
   `ControllerSession` over its own loopback). This spends model credits per
   member, so it is gated.
2. Register each with `make_room_task_sender(...) → room_binding.register(...)`.
3. **Prod relay** — point CoWork at the prod `relay-crossreplica` endpoint
   (`docs/COWORK_AGENT_PLATFORM_PLAN.md` §14; the chat-side fix already shipped as
   `d0732c1`). This is the "can take chat down" deploy — do it with a human.

## Verify without prod first

Before the prod relay, prove multi-member drive locally with mock models:
extend a test like `test_room_sender.py::test_a_whole_room_runs_over_encrypted_executors`
to N members through the **host's** `RoomService` (not a bare `RoomDriver`), each
member a loopback executor with a `MockModelClient`, registered in the binding.
That exercises the exact production path with no credits and no relay.

## Checklist

- [ ] Multi-agent host: one executor + `ControllerSession` per member agent.
- [ ] Register/unregister senders in `_room_binding` on connect/disconnect.
- [ ] Local mock-model test: a room drives N members through `RoomService`.
- [ ] Point at the prod relay (with a human; it can take chat down).
- [ ] One small real-credit room run to confirm end to end.
