# Offline send

When the app cannot send a message, it keeps the message and sends it
later. This applies to text, images and voice, in the normal chat and in the
Agents view. Nothing is lost, also not after an app restart.

## The parts

| Part | File |
|------|------|
| Row model and states | `lib/models/queued_message.dart` |
| Outbox store (SQLite, web: SharedPreferences) | `lib/services/offline_queue_service_native.dart`, `..._web.dart` |
| Encryption at rest | `lib/services/offline_outbox_cipher.dart` |
| Flush, triggers, backoff, preparers | `lib/services/offline_retry_manager.dart` |
| Payload schema, enqueue, Retry, Delete, sign-out wipe | `lib/services/offline_send_coordinator.dart` |
| Headless send of one row | `lib/services/offline_send_executor.dart` |
| Voice: recording file, transcription step | `lib/services/voice_spool_service.dart`, `lib/services/voice_outbox_preparer.dart` |
| Images: offline image store, upload step | `lib/services/image_storage_service.dart` (`offline://img/`), `lib/services/offline_image_preparer.dart` |
| Follow-ups typed during a reply | `lib/services/follow_up_parking_service.dart` |
| Shared screen logic | `lib/platform_specific/chat/offline_send_bridge.dart` |
| Bubble status line, chat list badge | `lib/widgets/message_bubble/outbox_status_line.dart`, `SbOutboxBadge` in `lib/widgets/sidebar/sidebar_chrome.dart` |
| Agents prompts | `lib/services/agents/agents_task_outbox.dart`, `lib/services/agents/agents_outbox_flusher.dart` |

## Storage

The chat outbox is the SQLite file `offline_queue.db` in the app support
directory, table `pending_messages`. One row is one message.

Columns: `id` (the queue id, also written into the bubble as `queueId`),
`chat_id`, `message_json` (the payload), `encrypted`, `user_id`, `kind`
(`text` or `voice`), `state`, `attempt_count`, `next_attempt_at`,
`last_error`, `seq`, `created_at`, `updated_at`.

The payload (`OfflineSendPayload`) holds: the text exactly as it goes to the
model (documents are already inlined as markdown), the model, the provider,
the system prompt resolved at send time, the image storage paths, the
document list, the original attachment list, the response budget, the
reasoning effort, and for voice the recording path, its length and the
auto-send setting.

### Encryption

The payload is sealed with the user's chat key (`EncryptionService.encrypt`,
AES-256-GCM), the same key that seals the chats in the cloud. If no key is
loaded yet, the row is stored in plaintext with `encrypted = 0`, and it is
sealed at the next flush that has a key. A row that cannot be opened (wrong
key) is kept and marked locked. It is not sent and not deleted.

The Agents outbox (`kv_cache`, keys `agents.task_outbox.*`) is sealed the same
way. Follow-ups are sealed in `kv_cache` under `outbox.followups.<user>.<chat>`.
Voice recordings are WAV files in `voice_spool/<user>/`. Offline images are
already encrypted files in `offline_images/<user>/`.

### Owner and sign-out

Every row has a `user_id`. The flush only touches rows of the signed-in user.
An explicit sign-out (`AuthService.signOut`) calls
`OfflineSendCoordinator.wipeUser`: it deletes the user's rows, their voice
files and offline images, the parked follow-ups and the Agents outbox. A
session that expires (no explicit sign-out) wipes nothing; the rows wait for
the same user.

### Migration from version 1

Version 1 of `offline_queue.db` had plaintext rows with no owner. The schema
upgrade adds the new columns and gives the old rows a `seq` in their old
order. The first signed-in user claims the rows without owner and seals them
(`claimLegacyRows`). No queued message is dropped.

## States

| State | Meaning | Bubble |
|-------|---------|--------|
| `queued` | Waits for the next flush or its backoff time | Clock, "Waiting for network". Retry after 2 min |
| `preparing` | A preparer runs | "Transcribing…" (voice) or "Uploading…" (images) |
| `sending` | The request is on its way | "Sending…" |
| `failed` | Gave up. Never retried by itself | Error icon, "Failed to send", Retry, Delete |
| `held` | Voice transcript ready, auto-send is off | "Transcript ready", Send, Delete |

A voice bubble with no transcript yet shows "Recording saved — will transcribe
when online" in place of the text.

The bubble keeps `status: pending` and the `queueId` in the chat. The cloud
copy of the chat does not: a `pending` or `failed` user message is synced as a
plain message (`neutralizeOutboxState` in `chat_storage_sync.dart`), because
other devices cannot send it. Old clients read it as a sent message, which is
what they did before.

## When a message goes into the outbox

1. The device is offline when the user sends.
2. The chat already has rows waiting (queued, preparing or sending). A new
   message must not overtake them. Failed and held rows do not count.
3. An attached image is only in the offline image store.
4. The send fails on the network before the server accepted it. "Accepted"
   means the server sent any frame back (meta, heartbeat, a token); see
   `StreamingManagerBase.serverAccepted`. This covers mobile
   (`StreamingMessageHandler.onSendNotAccepted`) and desktop
   (`desktop_send_logic.dart`). Only the first pass of a fresh send is
   queued; a regenerate, a continue or a later tool pass is not.
5. A voice recording cannot be transcribed (offline, no session, the
   transcription socket and the upload fail on the network).

A send that fails AFTER the server accepted it is never queued and never
re-sent by itself, because the server may already bill the turn. The normal
error shows, and the user can retry.

Follow-ups that the user types while a reply streams are kept in memory as
before, and also parked on disk. When the app restarts (or the user comes
back to the thread), the open chat restores and sends them.

## When the outbox is flushed

- App start, once a user is signed in and the key is loaded.
- App resume.
- The network comes back (offline to online).
- A successful `/v2/ws` handshake (`MultiplexConnection.onAuthenticated`).
- Every 45 s while a row is `queued`.
- A manual Retry.

Only one flush runs at a time. A trigger during a flush runs it once more.
Rows left in `preparing` or `sending` by a killed app go back to `queued` at
start.

## How a flush works

1. Group the user's rows by chat, in `seq` order.
2. Per chat, go row by row. Rows that wait for the user (failed, held) or
   cannot be opened (locked) are skipped. Stop the chat at the first other
   row that does not go out (backoff time not reached, or the send fails).
   So a later message never overtakes an earlier one that is still trying.
3. Per row: run the preparers that apply (voice transcription, then image
   upload), then send. A chuk_chat row goes to `OfflineSendExecutor`. A
   prepared row of an Agents thread is handed to the Agents outbox.
4. Success: delete the row, run the preparers' cleanup (delete the voice
   file, leftover image files), emit `success`.

### Failure handling

| Case | Result |
|------|--------|
| Network error, 5xx, 429 | `queued`, one attempt more, next try after 5 s, 15 s, 30 s, 1 min, 2 min, 5 min, 10 min, 15 min. After that: `failed` |
| Other error (4xx, bad payload, chat not found) | `failed` at once |
| Server had accepted the request | `failed` at once (no double billing) |
| No session, no key, chat streaming on screen | `queued`, no attempt counted |
| The device is offline | The flush does not start; a manual Retry probes once |
| Voice: recording file missing, empty transcript | `failed` |
| Image: offline file missing | `failed` |

Retry puts a row back to `queued` with attempts cleared and flushes. Delete
removes the row, its files and its bubble.

## The headless send

`OfflineSendExecutor` sends without a chat screen. It uses the history before
the queued message (only delivered messages), the queued system prompt,
images, model, provider and reasoning effort. The response budget comes from
the model's limits at flush time; when they are not loaded yet, a queued
budget above 512 is kept, else 4096.

It does not run tools. The tool loop needs the mounted chat screen (tool
executor, approval cards, MCP sessions). The answer is a plain answer; the
user can regenerate in the chat for a tool-using one.

The reply is written right after its question, the bubble loses its waiting
state, and the chat is saved on the device and then synced. The open chat
screen listens to the outbox events (`OfflineSendBridge.listen`) and reloads
the chat from storage. It does not reload while its own turn runs, and the
executor leaves a chat alone while it streams on screen, so neither
overwrites the other.

## Voice

1. The recorder keeps every PCM chunk in memory, also while it streams to
   the transcription socket. A dropped socket loses nothing.
2. On stop, the WAV is written to `voice_spool/<user>/` BEFORE any
   transcription attempt. The buffer is only cleared after the file exists.
3. Transcription works: the file is deleted, the text goes to the composer
   as before.
4. Transcription cannot connect: the result is `queueable`. The screen adds
   a voice bubble (`inputMode: voice`, `status: pending`) and a `voice` row.
5. On flush: transcribe the file, write the transcript into the bubble, then
   send it (auto-send on) or hold it (auto-send off; the user taps Send).
   The file is deleted only after the row is gone.

The Agents view uses the same screen, so voice works there too. After the
transcript, the prompt goes to the Agents outbox.

## Images

On attach while offline, or when the upload fails on the network, the image
is compressed, encrypted and stored as `offline://img/<user>/<id>`. It shows
from the local file. On flush, the image preparer uploads it, replaces the
path in the bubble and in the payload, and then the message is sent. While
the image is still in the composer and the network comes back, it is uploaded
in the background.

## Agents

An Agents prompt that cannot reach the host waits in `AgentsTaskOutbox`:

- An entry is never deleted after its attempts run out. It is marked failed
  and kept for Retry.
- The host task id is minted at enqueue time and sent with every flush, so
  the host dedupes a double flush.
- `AgentsOutboxFlusher` flushes every thread on each `paired` transition,
  also with no thread view mounted.
- Images in Agents are not sent yet (no attachment frame). The text goes out
  and the user sees "Images are not supported in Agents yet".

## Known limits

- The headless send does not run tools (see above).
- A row of the chat outbox whose bubble was replaced by a cloud copy from
  another device is matched by its text; if it is not found, the question is
  added again with the reply.
- In an Agents thread, a full host replay can replace the local bubble of a
  queued voice message; the row itself stays and is sent.
- The Agents relay is connected by a thread view. If no thread view was ever
  mounted since start, nothing connects, so nothing flushes.
- Follow-ups are restored when their chat is opened, not in the background.
- Web has no offline image store and no voice spool.
