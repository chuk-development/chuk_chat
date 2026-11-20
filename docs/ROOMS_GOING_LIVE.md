# Rooms: going live (the one gated step)

> **Groups (2026-11-20).** In the app a room is now called a **group**
> ("Gruppe"). The section "Groups" at the end of this file tells why groups
> did not work for the owner, what changed, and the wire frames. Read it
> first.

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
agent a room is about to run, it starts **its own** `Executor` on **its own**
sealed loopback, wraps a `ControllerSession` around the other end, and registers
`make_room_task_sender(...)` in the host's `RoomBinding`. `RoomService` calls it
through one new seam, `members_ready`, at the top of `handle_room_task`, so
members are started **on demand** — a room nobody opens costs nothing — and stay
warm for the next message. `LocalHost.stop()` shuts them all down, which
unregisters every sender.

A member is one thread, one sealed in-process link and one SQLite file. It is
**not** a second sandbox: the environment comes from `LocalHost._environment_for`,
so an agent keeps the one box it already had (§6, bead cowork-jo2) whether the
app drives it or a room does. A six-member room therefore adds six executor
threads on top of the containers those agents already have.

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
   task; the environment is the agent's existing one, so two members are two
   boxes only because they are two agents.
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

## Groups (2026-11-20)

### Why groups did not work for the owner

The owner said: "We still have no real groups." We examined the live host
and the code. These were the causes:

1. **The app forgot every group.** `LocalRoomSource` kept the groups in
   memory only. The host did not send a list. After each app start the list
   was empty.
2. **No group ever ran on the live host.** `~/.local/share/chuk-agents/rooms.db`
   had zero rows. The directory `room-agents/` did not exist. The pool starts
   it for the first member.
3. **A running group blocked the session.** The executor called
   `on_room_frame` on its reader thread. `RoomService.handle_room_task` ran
   the full exchange there. During a group run (several agent runs) the
   one-to-one chat, Stop and approvals did not move.
4. **The thread showed only the last exchange.** The host cleared the
   transcript on each message. The user's own messages were not kept.
5. **Each message woke every member.** There was no way to say who answers.
6. **Members did not know the group.** The prompt had no group name, no
   member names, no shared instructions and no earlier conversation.
7. **The words were wrong.** The UI said "room" and "Control Rooms", in
   English only.

The engine itself worked. A probe with two real agents on DeepSeek V4.1
Flash answered in 8 s (`scripts/agents_room_probe.py`).

### What a group has now

- **Settings on the host** (`rooms` table, new columns): `responder`,
  `lead_agent_id`, `fallback_agent_id`, `bulletin` (max 12 000 characters),
  `workdir`. Old files get the columns on open.
- **Who answers** (`manager/room_routing.py`, `route_first_round`), in this
  order:
  1. `@all`, `@everyone` or `@room`: every member.
  2. `@handle`: the named members.
  3. Nobody named: the `responder` mode.
     - `everyone`: every member (the old behaviour, the default).
     - `mentions`: nobody. The exchange ends with `no_addressee`.
     - `auto`: the cheap model (`ROOM_AUTO_MODEL_ID`, DeepSeek V4.1 Flash,
       reasoning off) picks one member, or more. A pick under 0.6, a bad
       answer, an error or a slow answer gives the fallback member. The host
       waits 2.5 s (`ROOM_AUTO_TIMEOUT_SECONDS`). We measured 1.1 to 1.9 s
       per pick, so 1.5 s fell back about half the time. The reply carries
       `routed_by` and the app shows "Picked by auto · 94%".
     - `lead`: the lead member answers. It can give tasks to members with
       the tool `hand_off_tasks` (`runtime/room_handoff.py`). The members
       run at the same time. The lead is woken once with their results.
       Limits per user message: 3 lead turns and 8 tasks
       (`manager/room_lead.py`). The tool refuses a task over a limit and
       tells the model why. If the model writes `@member` and does not use
       the tool, the first lead turn still gives that member a task.
- **Agent to agent**: an `@mention` in a reply pulls a member in, within the
  old `RoomCaps` (3 rounds). Lead mode uses its own limits.
- **The prompt** (`RoomContext.as_prompt`): group name, the other members
  with names, the shared instructions, the shared folder, up to 24 earlier
  entries (6 000 characters), the current exchange, a role note.
- **The transcript** keeps the whole conversation: user messages
  (`kind: user`), replies (`agent`) and tasks (`handoff`). It keeps the last
  200 entries per group.
- **The run is in the background.** `RoomService(background=True)` runs each
  exchange on its own thread. Two messages to one group run in order. The
  stores are safe across threads (one lock each).
- **A member runs on its own model** (`session_features.agent_model` of the
  agent, see `docs/agents/AGENT_MODEL.md`), else the host default.
- **Shared folder**: stored and named in the prompt. It is not mounted into
  the docker sandboxes yet (open point).

### Wire frames (all new keys are optional)

App to host:

- `room_create` + `responder`, `lead_agent_id`, `fallback_agent_id`,
  `bulletin`, `workdir`. A missing key keeps the stored value.
- `room_settings` `{room_id, <any setting key>}`: only the given keys change.
- `room_list_request` `{}`: the host answers `room_list`.
- `room_stop` `{room_id}`: stops the run after the current turn.

Host to app:

- `room_list` `{rooms: [{room_id, name, members, agent_to_agent, responder,
  lead_agent_id, fallback_agent_id, bulletin, workdir}]}`.
- `room_working` `{room_id, agent_id, handle}`: a member started its turn.
- `room_turn` + `kind` (`handoff` only; `agent` is left out),
  `routed_by` (`{"mode": "auto", "confidence": 0.94, "fallback": false}` or
  `{"mode": "lead"}`), `to_agent_id`, `to_handle`.
- `room_history` turns + `kind` (`agent`, `user`, `handoff`) and the same
  optional keys.
- `room_done` reasons + `no_addressee`, `lead_done`.

### Prove it

- Tests: `manager/tests/test_room_groups.py`, `host/tests/test_room_groups.py`
  (lead mode through real executors and the real tool, mock models),
  `runtime/tests/test_room_handoff.py`.
- Live probe (real model, spends a few cents):
  `agents/host/.venv/bin/python scripts/agents_room_probe.py "<message>"
  [--responder auto|lead|mentions|everyone] [--lead ID] AGENT_ID AGENT_ID`.
  With `--live` it writes into the host's `rooms.db` and
  `room-transcript.db`. Back them up into `_scratch/` first.
