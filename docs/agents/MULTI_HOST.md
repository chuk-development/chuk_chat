# Multi-host: several computers per account, groups across hosts (CHAT-177)

Status: design, 2026-11-22. Owner request: the user's PC and the cloud
computer run at the same time; agents on both can be in one group, talk to
each other and send files.

**Built (2026-11-22):**

- Relay: the `peer` route and `from_device_id` (api_server, live).
- Host, phase 2: `peers.json`, `host_peer_introduce` / `host_peer_forget` /
  `host_peer_list`, the sealed peer body, the peer requests (`task`,
  `agent_list`, `file_get`, `file_push`), group members with `host_id` (a
  sender over the peer route, an offline line), the shared file store, and
  the agent tools `share_file`, `fetch_file`, `send_file_to_agent`,
  `ask_agent`. Wire shapes and the app's part: `docs/WIRE_CONTRACT.md`,
  "Hosts that work together". Code: `agents/host/src/chuk_agents_host/
  peer_hub.py` and its neighbours.
- Open: the app side of phase 2 (introduce, group editor with a computer
  per member). A queued fetch does not start by itself when the other host
  comes back; the agent calls `fetch_file` again and it resumes.
- Known limit: every host's own agent has the app id `host:cowork-host`
  (the crypto peer id is the same on every host). A group must not hold the
  own agents of two hosts: the room keys members by `agent_id`. Agents the
  app made (`local:...`) are unique.

## Today (what blocks it)

- The app keeps ONE trust record (`agents_pairing_store.dart`, key
  `cowork_pairing`) and mirrors ONE row per user (`cowork_pairings`, PK
  `user_id`). A second pairing overwrites the first.
- Every host signs as `cowork-host` (`agents/host/.../identity.py`). The
  app's approved-device map is keyed by that id, so two hosts collide.
- The relay already routes per device: `user_id -> device_id (uuid4) ->
  executor`. Several hosts can be online at once. But executor -> controller
  frames fan out to every app socket WITHOUT the source `device_id`, and
  there is no executor -> executor route.
- Groups (`manager/group_room.py`, `room_store.py`, `room_binding.py`) work
  on one host only. `RoomBinding` maps `agent_id -> TaskSender`; that is the
  seam for a remote member.
- Files: phone -> host (`attachment_put`, 256 KiB chunks, 25 MiB) and host ->
  phone (`send_file_to_user`, 8 MiB). No host -> host path.

## Identity: a host is its relay device id

A host is identified by its relay `device_id` (the uuid4 in `cw_device`).
It is already unique, stable and known to the relay. The crypto peer id
`cowork-host` stays as it is (no change for existing pairings): the app
keeps one trust context per host, so the same peer id in two contexts no
longer collides.

Each host also has a display name (default: hostname; the cloud box:
"Cloud-Computer") and a kind (`pc` | `cloud`).

## Phase 1: several hosts in the app

1. **Supabase:** `cowork_pairings` gets `host_id text` (the relay uuid4),
   PK `(user_id, host_id)`. Existing rows: `host_id` from the record's
   `cw_device` (the app migrates on first load; the column defaults to
   `'legacy'` until then). Ciphertext stays per row, under the account key.
2. **App store:** `AgentsPairingStore` holds a list
   (`cowork_pairings_v2`: map host_id -> record). The old single key is
   read once and moved. Restore syncs the whole list.
3. **Connections:** one relay socket per paired host (`AgentsRelayLink`
   becomes a registry `hostId -> link`). Each link has its own approved
   devices, controller session and reconnect state.
4. **Relay:** executor -> controller frames carry `from_device_id`
   (`cowork_relay.py`, also over the replica mesh). The app drops a frame
   on a link whose host id does not match.
5. **UI:** agents and chats show which computer they live on (a small
   label "PC" / "Cloud"). New agent: pick the computer (default: the one the
   user used last). Settings > Computers lists hosts: name, online, rename,
   remove. No picker anywhere else: a chat belongs to its host.
6. **Cloud box:** the app starts the cloud-box flow also when a PC is
   paired; the box is added, not swapped.
7. Per-user data that is host-specific gets the host id: roster cache,
   `cowork_chats` (column `host_id`, nullable = the first host).

## Phase 2: groups across hosts

**Trust between hosts: the app introduces them.** The app already has a
sealed channel to every host. To link hosts A and B it makes a fresh
32-byte key `K_AB` and sends each host, over its own sealed channel:
`{peer_host_id, peer_ed25519_public_key, K_AB}`. No new pairing ceremony,
no code to type: the user's app is the trusted party that vouches for both
sides. Hosts store peers in `peers.json` (0600). The user can unlink a host
in the app; the app tells the remaining hosts to forget it.

**Relay route executor -> executor:** a new frame kind `peer` with
`target_device_id`. Allowed only when both sockets belong to the same
`user_id` (also across replicas). The relay stays blind: the body is
sealed with `K_AB` (AES-256-GCM, Ed25519-signed by the sender, replay guard
as in `frame.py`). Rate-limited per user.

**Group with members on several hosts:**
- A group has a home host (where it was created). It owns the room store,
  the transcript and the routing (mentions, lead, rounds cap).
- A member is `(host_id, agent_id)`. For a member on another host, the
  `RoomBinding` gets a `RemoteTaskSender`: it sends the task over the peer
  route; the other host runs the agent in its own sandbox and streams the
  reply back. The app reads the group from the home host as today.
- If a member's host is offline, the group says so ("Cloud-Computer is
  offline") and goes on without that member; the home host retries when
  the host comes back.

**Files between agents (pull, content-addressed):**
- An agent shares a file in the group with `share_file(path)`. The file
  stays on its host; the group message carries a reference
  `{host_id, sha256, name, size}`.
- An agent on another host that needs it calls `fetch_file(ref)` (or the
  runtime fetches it on first read). The owner host streams it in sealed
  256 KiB chunks over the peer route; the receiver checks the sha256 and
  stores it in `<workspace>/.agents/inbox/<sha256>/<name>`.
- Why pull: nothing is copied that nobody reads, the same file is moved
  once per host (sha256 cache), and it works for big files (cap 200 MiB per
  file, resumable by chunk index).
- Direct send also exists: `send_file_to_agent(agent, path)` = share +
  push to that one member.
- Both hosts must be online for a transfer (the relay stores nothing). A
  queued fetch runs when the owner host comes back.

**Direct messages without a group:** `ask_agent(agent, text)` sends one
task to an agent on any of the user's hosts and returns its answer. Same
route and sender as a group member; useful for "the cloud agent does the
long crawl, the PC agent uses the result".

## Security notes

- The relay cannot read peer frames or files (sealed with `K_AB`).
- Only hosts of the same account can reach each other; the relay checks
  `user_id` on both sockets.
- A cloud box is a host like any other. Agents on it run as `agent`
  without root; a file fetched from the PC lands only in the requesting
  agent's workspace.
- Unlink a host = the app sends "forget peer" to all other hosts and
  deletes the pairing row.

## Order of work

1. Relay: `from_device_id` on fan-out (+ mesh), `peer` route with same-user
   check, tests.
2. App: pairing list + Supabase migration + link registry + host labels;
   cloud box adds instead of replacing. Test: PC + cloud box online at once.
3. Host: peers store, introduce/forget frames, peer route, `RemoteTaskSender`,
   group members with host id.
4. Files: `share_file`, `fetch_file`, `send_file_to_agent`, sha256 cache.
5. `ask_agent`.

## App, phase 1: where it lives

- **Store:** `agents_pairing_store.dart`, secure key `cowork_pairings_v2`
  (`{"version":2,"hosts":{hostId: record},"last_used":hostId}`). The old
  key `cowork_pairing` is read once, moved, deleted. `hostId` is the
  `cw_device` uuid, else `local:<channel>` (loopback); a record of the same
  channel under a new id replaces the old one (host_route). The record
  carries `name`, `kind` (`pc`|`cloud`) and `legacy_host_agent`.
- **Host agent ids:** every host signs as `cowork-host`, so only the
  computer from before CHAT-177 (`legacy_host_agent`, set on the moved old
  record and on a mirrored `legacy` row) keeps `host:cowork-host`; every
  later computer's own agent is `host:cowork-host@<hostId>`. The flag rides
  in the encrypted record, so all devices pick the same ids.
- **Mirror:** `supabase_pairing_sync.dart` (`AgentsPairingCloud` seam for
  tests), one row per `(user_id, host_id)`, migration
  `supabase/migrations/20261122000000_cowork_pairings_multi_host.sql`
  (NOT applied yet). Apply it before the app ships: the new upsert needs
  the `host_id` column. Old apps then can no longer write or read the
  mirror (best-effort paths; their local pairing keeps working).
- **Restore:** `agents_pairing_restore.dart` restores every row; a paired
  device reads the mirror every 2 min (and on a nudge) for computers added
  elsewhere. A host removed on another device is not removed here yet.
- **Links:** `AgentsRelayLinks` (in `agents_relay_link.dart`):
  `AgentsRelayLink.instance` is the PRIMARY link (the computer of the open
  chat, driven by `AgentsThreadView`, `hostId` param); other computers get
  secondary links, kept up by `AgentsHostLinks` (`agents_host_links.dart`).
  A host switch hands the sockets over (`takeController` / `adopt`), no new
  handshake. `secondaryInbound` tags frames with their host.
- **Relay filter:** `AgentsCloudRelaySocket.acceptsFrameFrom`: a frame with
  `from_device_id` of another host is dropped; no field = old relay, taken.
- **UI:** `AgentsHostTag` / `AgentsHostLabels` (rows, only with 2+ hosts),
  `showAgentHostPicker` (new agent), `AgentsComputersPage` (agent settings
  > Computers). Cloud box flow runs with a PC paired too
  (`AgentsCloudBoxFlow.hasComputer`): it books a new box, or goes on with
  a setup this device began; an existing box it did not set up is left
  alone.
- **Still on the primary link only:** groups (phase 2), skills, automations,
  dashboard, permissions, run ledger and the in-app done notification.
  `AgentsRelayClient.hostCapabilities` is one static for all hosts.
