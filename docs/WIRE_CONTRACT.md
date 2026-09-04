# CoWork wire contract: run state, replay cursor, completion

This file is the contract between the Flutter app and the Python executor for the
frames that carry run state, history replay and run completion. Three sessions work
on the executor and protocol at the same time. All of them must use the same frame
shapes. This file is the reference.

Status: the Python side (executor, host, state store) implements this contract.
The app (Dart) side codes to it; until the app sends `after_id` and `run_ack`, the
executor treats a replay as a full replay and a run as unseen. Both sides ignore
fields they do not know.

## Rules

- All frames travel inside the sealed CoWork frame, as today.
- The contract is additive. A receiver MUST ignore unknown fields. A sender MUST NOT
  remove or rename an existing field.
- `session_key` selects the thread on the executor. It equals the agent's thread key
  in the app (one session per agent).

## Outbound: app → executor

| type | fields | notes |
|---|---|---|
| `task` | `prompt`, `session_key`, `model`?, `provider`?, `reasoning_effort`?, `mcp_servers`?, `herenow`?, `debug`? | Existing. Field names are `model` and `provider` (NOT `model_id` / `provider_slug`). There is no `fast_mode` field; Fast mode is a model + `reasoning_effort` chosen by the app. |
| `stop` | `session_key` | Existing. |
| `replay` | `session_key`, `after_id`? (int, default 0) | `after_id` is NEW. Replay only the messages with `mid > after_id`. `0` replays the full history (fresh install). |
| `run_ack` | `run_id` | NEW. The app sends it after it rendered a live `done`. The host marks the run as seen (`runs.seen_at`), so a later replay does not flag it `while_away`, and it can skip a push notification. |
| `account_authentication` | (existing provisioning fields) | Existing. NEW rule: it can arrive again during a session (token rotation, re-provision). The executor MUST route it to the host as a re-provision and MUST NOT treat it as a task. |

### `mcp_servers` on `task` (extended, additive)

One entry per connector the user has configured, assembled by
`McpStore.forwardPayloads()` and read by `mcp_client.configs_from_entries()`.
The frozen example both sides assert against is
`app/test/fixtures/mcp_forward_payload.json`.

```json
{"name": "<connector name>", "url": "<https endpoint>", "auth": "oauth" | "appSession",
 "access_token": "<bearer>"?,
 "oauth": {"token_endpoint": "<url>", "client_id": "<id>", "client_secret": "<secret>"?,
           "refresh_token": "<token>", "expires_at": "<iso 8601>"?, "resource": "<url>"?,
           "scope": "<space separated>"?, "issuer": "<url>"?}?}
```

The `oauth` block is NEW. Everything else is unchanged, and a receiver that does
not know the block keeps working off `access_token` alone.

Who authenticates what:

- `auth: "oauth"` — the device ran the sign-in (browser + loopback redirect, see
  `lib/services/mcp/mcp_oauth.dart`). `access_token` is the bearer it holds; the
  app refreshes it before forwarding when it has already lapsed, so a running app
  always hands over a live one.
- `oauth` — present only when the record holds a `refresh_token` AND a
  `token_endpoint`. It is what lets the host outlive the app: with the app closed
  there is nobody to open a browser, so the executor mints its own access tokens
  from `refresh_token` at `token_endpoint` (RFC 6749, `client_secret` via HTTP
  Basic when the server issued one). A connector signed in by a build before P5
  has a bearer and no block; it works until that bearer dies, then the user signs
  in again.
- `auth: "appSession"` — no device token. The executor authenticates with its own
  account bearer.
- An API-key connector carries neither `auth` nor `access_token`: its credentials
  are already query parameters on `url`. Unchanged.

`expires_at` is informational — the host may treat the token as live until a `401`
— and it is the field to drop, together with `access_token` and
`oauth.refresh_token`, when hashing this list to decide whether an MCP manager has
to be rebuilt. A rotated token is not a changed connector.

## Inbound: executor → app

Existing event types stay as they are: `delta`, `reasoning`, `tool`, `file`,
`subagent`, `user`, `done`, `error`, `debug_context`, `approval_request`, `room_*`,
`browser_*`. The changes below are additive.

### `browser_view` `started` (extended, additive)

```json
{"type": "browser_view", "status": "started", "message": "<text>", "password": "<vnc secret>"?}
```

`password` is optional: the per-view VNC secret the executor set on the sandbox
`x11vnc`. The app passes it to its RFB client; an old app ignores it.

### `run_state` (NEW)

Emitted first in every replay response.

```json
{"type": "run_state", "session_key": "<key>", "state": "running" | "idle",
 "run_id": "<uuid>"?, "started_at": <unix seconds>?, "prompt": "<text>"?}
```

- `running`: a run for this session is in flight on the host (it may have started
  before this app connected). The app shows "Working…" with the original prompt.
- `idle`: no run in flight.

### `mid` on replayed events (NEW field)

Every replayed `user`, `delta` and `tool` event carries the row id of the message
store: `"mid": <int>`. The app keeps the highest `mid` it saw per session as the
replay cursor and sends it back as `after_id`. Live events may carry `mid` later;
the app treats it as optional.

### `done` (extended)

```json
{"type": "done", "final_answer": "<text>"?, "reason": "<reason>", "iterations": <int>,
 "tokens_spent": <int>, "replay": true | false, "run_id": "<uuid>"?, "while_away": true | false}
```

Semantics, in this order:

1. `reason == "replay"`: the history-end marker. It closes a replay stream. The app
   renders nothing for it and ends replay mode. This is the existing behaviour and
   stays so old clients keep working.
2. `replay == true` and `reason != "replay"` (for example `"finished"`): a persisted
   run terminal replayed from the host. The app renders it as a real completion card.
   `while_away == true` means the run finished with no app attached; the app shows an
   "Answer ready" affordance.
3. `replay == false`: a live run ended, as today.

Persisted run terminals are replayed in message-id order, interleaved with the
messages of that run.

App-side helpers on `CoworkRelayDone`:

- `isHistoryEnd` = `reason == 'replay'`
- `isReplay` = `replay == true || reason == 'replay'` (kept for compatibility)
- `whileAway`, `runId`

## Host-side record (informative)

The executor keeps a `runs` table in the same SQLite file as the messages
(`run_id` PK, `session_id`, `session_key`, `prompt`, `state` running|finished|failed,
`reason`, `final_answer`, `iterations`, `tokens_spent`, `first_mid`, `last_mid`,
`started_at`, `finished_at`, `notified_at`, `seen_at`). `notified_at` is the dedup
key for notifications (set once, whichever channel fires first). `seen_at` is set by
`run_ack`: the app showed the live `done`. `while_away` in a replayed `done` is
`seen_at IS NULL`. On host start, rows left in `running` are set to
`failed` / `host_restarted`.

## Detachment rule (informative)

A run belongs to the host process, not to a socket. When the app disconnects the run
keeps going, the transcript keeps landing in the message store, and result frames
for an absent controller are dropped (not buffered). When the app reconnects it
re-binds the frame codec and requests `replay` with its cursor.
