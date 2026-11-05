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
| Routing of one row (screen, headless) | `lib/services/offline_send_executor.dart` |
| Send on the open chat screen | `lib/platform_specific/chat/outbox_screen_turn.dart` |
| Headless send with the full tool loop | `lib/platform_specific/chat/headless_chat_turn.dart`, `lib/services/headless_turn_scope.dart` |
| Follow-ups of a chat no screen holds | `lib/services/follow_up_dispatcher.dart` |
| Startup sweep of orphan files | `lib/services/offline_file_sweeper.dart` |
| Web byte store (IndexedDB) | `lib/services/offline_blob_store*.dart`, `lib/services/offline_blob_handle.dart` |
| Agents link with no thread view | `lib/services/agents/agents_background_link.dart` |
| Voice: recording file, transcription step | `lib/services/voice_spool_service.dart`, `lib/services/voice_outbox_preparer.dart` |
| Images: offline image store, upload step | `lib/services/image_storage_service.dart` (`offline://img/`), `lib/services/offline_image_preparer.dart` |
| Follow-ups typed during a reply | `lib/services/follow_up_parking_service.dart` |
| Shared screen logic | `lib/platform_specific/chat/offline_send_bridge.dart` |
| Request ids (`client_request_id`) | `lib/services/client_request_ids.dart`, `WebSocketChatService.runIdempotent` |
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
auto-send setting, and `clientRequestBase` (see "Request ids").

### Encryption

The payload is sealed with the user's chat key (`EncryptionService.encrypt`,
AES-256-GCM), the same key that seals the chats in the cloud. If no key is
loaded yet, the row is stored in plaintext with `encrypted = 0`, and it is
sealed at the next flush that has a key. A row that cannot be opened (wrong
key) is kept and marked locked. It is not sent and not deleted.

The Agents outbox (`kv_cache`, keys `agents.task_outbox.*`) is sealed the same
way. Follow-ups are sealed in `kv_cache` under `outbox.followups.<user>.<chat>`.
Voice recordings are sealed with the same key (`EncryptionService.encryptBytes`)
and written as `voice_spool/<user>/<uuid>.wav.enc` (web: the same key in
IndexedDB). A recording is never written in plaintext: when no key can be
loaded, it stays in memory under its final path and is written, sealed, as
soon as a key is there (the next save with a key, or the next flush,
`VoiceSpoolService.sealPending`). If the app dies before that, the recording
is lost and its row fails with "recording missing". Offline images are
already encrypted files in `offline_images/<user>/`.

### Owner and sign-out

Every row has a `user_id`. The flush only touches rows of the signed-in user.
An explicit sign-out (`AuthService.signOut`) calls
`OfflineSendCoordinator.wipeUser`: it deletes the user's rows, every row
with no owner (version 1 rows, rows queued before a session was known; the
next account must never claim and send them), their voice files and offline
images, the parked follow-ups and the Agents outbox. A
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
| `queued` | Waits for the next flush or its backoff time | Clock, "Waiting for network". Retry and Delete after 2 min |
| `preparing` | A preparer runs | "Transcribing…" (voice) or "Uploading…" (images) |
| `sending` | The request is on its way | "Sending…" |
| `failed` | Gave up. Never retried by itself | Error icon, "Failed to send", Retry, Delete |
| `held` | Voice transcript ready, auto-send is off | "Transcript ready", Send, Delete |

A voice bubble with no transcript yet shows "Recording saved — will transcribe
when online" in place of the text.

The bubble keeps `status: pending` and the `queueId` in the chat. The cloud
copy of the chat does not: a `pending` or `failed` user message is synced as a
plain message (`neutralizeOutboxState` in `chat_storage_sync.dart`), because
other devices cannot send it. Every cloud write (save, update, rename,
re-encrypt) encodes both copies with `encodeChatPayloadPair`: the neutral one
goes to `encrypted_chats`, the local cache keeps the one with the state. Old clients read it as a sent message, which is
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
   queued; a regenerate, a continue or a later tool pass is not. The mobile
   screen keeps the payload of a fresh send only until its turn ends; an
   edit, a resend, an outbox send or a continue drops it first, so they never
   queue an older message.
5. A voice recording cannot be transcribed (offline, no session, the
   transcription socket and the upload fail on the network). The voice
   bubble goes into the chat that started the recording, also when the user
   switched chats while it was queued (`OfflineSendBridge.voiceBubbleOffScreen`).

A send of a fresh message that fails AFTER the server accepted it is not
queued: the user sees the error and the answer so far, and can retry or
continue. Queued rows are different: a row that the server took but whose
socket died is sent again by itself, with the same request ids, so the
server answers it once (see "Request ids").

Follow-ups that the user types while a reply streams are kept in memory as
before, and also parked on disk. The open chat sends them when its turn
ends; a chat that no screen holds any more sends them through the outbox
(see "Follow-ups" below).

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
| Server had accepted the request, then the socket died (`connection_lost`) or the answer was still being written (`request_pending`), and no tool ran | `queued` with backoff. The re-send has the same request ids, so the server answers it from its record and bills it once. Headless and plain path only |
| Server had accepted the request, any other end (also the cases above after a tool ran, or on the screen path) | Sent. What the turn wrote (also an error text after acceptance) is the answer, like a send on screen. Not sent again by itself: a fresh run would bill again, or run its tools again |
| No session, no key, a turn of the chat runs (also between two tool passes) | `queued`, no attempt counted |
| The device is offline | The flush does not start; a manual Retry probes once |
| Voice: recording file missing, empty transcript | `failed` |
| Image: offline file missing | `failed` |

Retry puts a row back to `queued` with attempts cleared and flushes. Delete
removes the row, its files and its bubble.

## Request ids (no double billing)

Every chat frame on `/v2/ws` carries a `client_request_id` (api_server
`CLAUDE.md`, "/v2/ws", request idempotency). One id per pass of a turn,
`<base>-p<n>`; every re-send of the same pass (a reconnect retry, a
`cache_miss` retry, an outbox re-send after a restart) has the same id. A
new pass, a message-level retry or a new send has a new one. The server
runs and bills each id once:

- `duplicate`: the stored answer of the id. It reaches the turn as a normal
  answer (content, tool calls, usage, meta). A minimal record
  (`truncated: true`, no content) shows `kAnswerUnavailableNotice`; the
  answer was billed but cannot be shown, and a new send asks again with
  new ids.
- `duplicate_in_flight`: the request still runs (detached after its socket
  died). The send waits the hint and asks again, up to 6 times, then ends
  with `request_pending` (`kAnswerPendingNotice`); the pass retry asks
  again with the same id.
- `client_request_id_conflict` / `invalid_client_request_id`: one re-send
  with a fresh id.
- The user's Stop sends `cancel` with the running pass's id
  (`WebSocketChatService.declareStopIntent`), so a detached request stops
  too.

A pass whose socket died (`connection_lost`) or whose answer is still
being written (`request_pending`) is asked again under the same id, up to
3 times with backoff, on desktop and mobile alike
(`ClientRequestIds.resendPassOnSameId`; never in an Agents thread; bead
chuk_chat-074s). When the turn still ends with one of these codes, its
base is kept for that user message (`ClientRequestIds.keepForRetry`, keyed
by `messageId`, else `sentAt`); the user's Retry of the same message takes
it (`takeForRetry`), so the server answers from its record instead of
billing the turn twice (bead chuk_chat-3e67).

The base of a turn on screen is random. The base of an outbox row is
`ob-<row id>`, written into the payload at enqueue (`clientRequestBase`,
sealed with the row). A screen send that never reached the server keeps its
own base when it goes into the outbox, because the server may have taken
the first pass without a frame coming back. The send paths take the base
the outbox armed for the chat (`ClientRequestIds.arm` / `take`), the screen
path and the headless turn alike. So a row killed mid-send (`sending` at
start goes back to `queued`) is sent again with the same ids, and the
server answers instead of billing a second time (bead chuk_chat-vnan).

## How one row is sent (with tools)

`OfflineSendExecutor.execute` picks the path. Both run the full tool loop,
so the answer is the one a normal send gives.

1. **The chat is open on a screen** (`OutboxScreen`, mixed into both chat
   screens by `OutboxScreenTurnMixin`). The screen reloads the chat from
   storage (a preparer may have written a transcript or an image path), and
   when the queued bubble is the LAST message and no turn runs, it sends the
   bubble through the Retry path (`submitEditedMessage`). The user sees it
   stream. When the turn ends: the server accepted it (any frame back, tool
   calls, content blocks) → success. It never reached the server → the error
   row goes, the bubble waits again (`OutboxScreenRules.restoreWaiting`) and
   the row is retried with backoff.
2. **Otherwise: headless** (`HeadlessChatTurn`). It runs the mobile screen's
   `StreamingMessageHandler` with no screen, on a copy of the chat up to the
   queued message (only delivered messages), the queued message itself (as
   delivered, with its send time and the queued text, so its `[Sent: …]`
   line and prompt context are the ones a screen send has) plus a
   placeholder. A long chat is compacted before the first pass like any
   send; the summary goes onto the stored row it marked. The handler's
   callbacks fill the placeholder (text, reasoning, tool calls, content
   blocks, tool images, `interrupted`). At the end the placeholder is written
   right after its question; later queued messages stay after it. The chat's
   `ChatRuntime.isSending` is true for the whole turn, so the screen (and the
   executor) treat the chat as busy, also between two tool passes.

The settings come from the same places as on screen: the user settings
(`AppThemeService`: tool calling, discovery, history options), the queued
system prompt (or, for a row queued with `resolvePromptAtSend`, the prompt
resolved at send time), model, provider, reasoning effort and images.

### Tools with no screen

The headless turn runs in `HeadlessTurnScope` (a zone value):

- `artifact_manager` and `typst_compile` take the queued chat from the scope,
  not the chat that is open on screen.
- `device` actions that open another app's screen (`create_calendar_event`,
  `sms_draft`, `email_draft`) return a tool error ("needs the app open on
  screen"). `get_location` does not ask for a missing permission; it returns
  a tool error instead. Nothing waits for a screen that is not there.
- `ask_user` and `request_mcp_server` only return text the bubble renders,
  so they work as on screen.

The plain request (no tools) in `OfflineSendExecutor` is only the fallback
when no tool path is installed (its unit tests).

The open chat screen listens to the outbox events (`OfflineSendBridge.listen`)
and reloads the chat from storage after a headless send. It does not reload
while its own turn runs.

## Follow-ups

Follow-ups typed while a reply streams stay in the screen's memory and are
parked on disk per chat (`FollowUpParkingService`). When the user leaves the
chat, the screen drops them from memory (they never go into the next chat),
and `FollowUpDispatcher` takes over: once the chat's turn is over (and 3 s
more, so the answer's save lands first) and no screen shows the chat, each
parked follow-up becomes an outbox row with a waiting bubble at the end of
the chat, in order, and leaves the park. The dispatcher runs on every outbox
kick (start, resume, back online, server connect), on a chat switch and when
a screen goes away, and polls every 3 s while a parked chat waits. A chat on
screen restores and sends its own parked follow-ups when it is opened (on
desktop also on the fast path for a chat already in the cache). The
dispatcher reads the chat before it takes the follow-ups off the park, so a
failed read loses nothing.

Both screens hold the follow-ups in one `ComposerFollowUps`
(`lib/services/composer/composer_follow_ups.dart`); the queue dock above
the composer draws them (edit, remove, "send now as steer"). A busy send is
either queued (a new turn after the reply) or a steer: `SteerInbox` hands
it to the running tool loop, which adds it as a user message after the
round (`ToolCallHandler`, next to the skill bodies), and the answer shows
it as a small user bubble at that place (`ContentBlock.steer`). A steer the
turn did not take (no further pass) becomes a queued message when the turn
ends.
Agents threads always queue. A queued message goes out through the
voice-task path (`voiceText`), so a draft in the composer is never
overwritten. Stop (button or Esc twice within 500 ms) puts the queue back
into the composer instead of dropping it. If the outbox refuses a send that
was never accepted, the draft comes back into the composer.

## Files a crash left behind

`OfflineFileSweeper` runs once per app run and user, on the first outbox kick
with a key. It lists the user's voice recordings (and the `anon` folder) and
offline images. A file that a row names is kept at any age; paths are
compared with `/` and `\` as one separator, because a directory listing on
Windows joins with `\`. A file no row
names is deleted when it is older than 6 hours (a newer one may belong to a
recording or a composer that is still open). If any row of the user cannot
be opened, nothing is deleted. Promotion markers (`.promoted`) are kept.

## Voice

1. The recorder keeps every PCM chunk in memory, also while it streams to
   the transcription socket. A dropped socket loses nothing.
2. On stop, the WAV is sealed and written to `voice_spool/<user>/` BEFORE
   any transcription attempt (with no key: held in memory, see
   "Encryption"). The buffer is only cleared after the file exists.
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
- A task that went to the socket but was never confirmed by the host
  (`AgentsPendingTasks`) is not dropped after 3 sends either: it becomes a
  failed outbox entry under the SAME task id, the bubble shows Retry and
  Delete, and a Retry is the same task to the host (it dedupes).
- A `task_ack` for any thread clears that thread's record app-wide
  (`AgentsOutboxFlusher`), so a task that arrived is never shown as failed.
- The host task id is minted at enqueue time and sent with every flush, so
  the host dedupes a double flush.
- `AgentsOutboxFlusher` flushes every thread on each `paired` transition,
  also with no thread view mounted.
- With no thread view holding a link, `AgentsBackgroundLink` opens one when
  work waits (a due entry or an unconfirmed task), a user is signed in and a
  pairing is stored: it builds the controller (`agents_relay_factory.dart`),
  binds it and reconnects with no code. The flusher sends the queue and
  re-sends unconfirmed tasks. The link closes when nothing is left, and
  steps back at once when a thread view binds its own controller (a view
  unbinds its controller when it goes away). A controller of its own that
  died (`closed`, or `error` after a reconnect that failed) is dropped and a
  fresh one is built on the same look while work is left. Checks every 15 s
  and on every outbox change or network change.
- Pictures and files go out with the prompt (docs/WIRE_CONTRACT.md,
  "Attachments to Agents"). A picture is kept like any composer image
  (encrypted, `offline://img/` or the bucket). Any other file is sealed with
  the chat key in `agents_attachments/<user>/` and named `agents-att://…`
  (`lib/services/agents/agents_attachment_store.dart`). The queued entry
  keeps these paths; the flush uploads each file in 256 KiB
  `attachment_put` chunks (`lib/services/agents/agents_attachments.dart`)
  and sends the task with the `blob_id`s only when every file is complete.
  An unconfirmed task is re-sent with the same `blob_id`s. The sweeper keeps
  every offline picture a queued entry names. Sign-out wipes the sealed
  files with the outbox.

## Web

Web has no file system. The outbox rows live in SharedPreferences as
before; voice recordings and offline images live in IndexedDB
(`OfflineBlobStore`, database `chuk_offline_outbox`, store `blobs`, value
`[bytes, writtenAtMs]`) under the same layout as the native files: a
recording path is `idb:voice_spool/<user>/<uuid>.wav.enc` (sealed bytes), an offline image key
is `offline_images/<user>/<id>.enc` (and `.promoted`). So voice and images
are kept and sent later on web too. A browser without IndexedDB falls back
to the old behaviour (voice transcribed live only, no offline images).

## Known limits

- A row of the chat outbox whose bubble was replaced by a cloud copy from
  another device is matched by its text; if it is not found, the question is
  added again with the reply.
- In an Agents thread, a full host replay can replace the local bubble of a
  queued voice message; the row itself stays and is sent.
- The screen path takes a row only when its bubble is the last message;
  earlier rows of the open chat go out headless and the screen reloads.
- A headless turn that the app is killed in the middle of goes back to
  `queued` at start and is sent again with the same request ids, so the
  server answers the passes it took from its record. Client-side tools of
  those passes run again (the server only stores the answer).
- A request id the server refused as a conflict is replaced for that send
  only; it is not written back into the row.
