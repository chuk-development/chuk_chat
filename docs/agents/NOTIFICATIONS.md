# Sidekick notifications: answer text and avatar (CHAT-128)

A Sidekick notification shows the agent's own avatar and the start of its
answer, on every platform. It never says only "the answer is ready".

## Rules

1. **Title** is the agent's name (or "agent: automation", as
   `notification_text.RunLabels.headline` builds it).
2. **Body** is the answer preview: the final answer, markdown removed
   (code fences, `#`, `*`, `_`, backticks, link syntax `[t](u)` -> `t`),
   whitespace collapsed to single spaces, clipped to 300 characters with
   `…`. A failed or stopped run keeps its plain sentence.
3. **Icon** is the agent's avatar PNG (the same face the app draws), not the
   app logo. No avatar known: the app logo, as before.
4. **Nothing readable leaves the user's devices.** The push through Supabase
   and FCM is not end-to-end, so its preview is sealed (below). Local
   toasts (host desktop toast, app toasts) show the text directly.

## Sealed preview (host -> push -> app)

Key, per pairing (both sides hold the 32-byte `channel_key` of the stored
pairing / trust record):

```
push_key = HMAC-SHA256(channel_key, "cowork/push/preview/v1")
```

(`mac(key, label, b"")` in `controller_sessions.py`: HMAC over
`label.encode() + message` with an empty message.)

Plaintext, UTF-8 JSON:

```json
{"v": 1, "title": "<title>", "body": "<preview>", "agent_id": "<id>",
 "session_key": "<thread>", "run_id": "<run>"}
```

Cipher: AES-256-GCM, 12-byte random nonce, no AAD.
Sealed value: `base64( nonce || ciphertext || 16-byte tag )`.

The host seals once per stored trust record and writes the column
`cowork_run_notifications.preview_sealed` (jsonb):

```json
{"<channel_id>": "<sealed b64>", ...}
```

`title` and `body` of the row stay generic ("The answer is ready.") as the
fallback for a device that cannot open the seal.

### Test vector

The host writes the plaintext as compact JSON (no spaces), keys in the order
above, UTF-8 without `\u` escapes (`push_preview.preview_plaintext`). The
app only decodes it, so it needs no byte-equal encoder. The vector below is
pinned by `agents/host/tests/test_push_preview.py`; the Dart side asserts the
same bytes.

| Field | Value |
|---|---|
| `channel_key` (hex) | `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` |
| `push_key` (hex) | `bf24d707c4f25e9fcc144ddf730cac87c573cc2592c7fe4bf33d28f094122bb0` |
| `nonce` (hex) | `101112131415161718191a1b` |

Plaintext (UTF-8, 121 bytes; "Schön" has one 2-byte character):

```
{"v":1,"title":"Ada","body":"Die Summe ist 210. Schön!","agent_id":"local:a1","session_key":"local:a1","run_id":"run-1"}
```

Expected sealed value (base64 of nonce || ciphertext || tag):

```
EBESExQVFhcYGRobFu8WALfXR0Ufwdw2EGA8/XP1RQSZwRI2J/aV1yljHdoStej4/sBOVhkBCnGVsSSD5teX4UQWLBhsNC+GYAj0zd1zvgZ1pcTzc7ZPvtfqyDKiY/i9jJkcbC2xk6z57JjqPIiRF4s93fCfn55JMDKRVCM3NQCXvtFWItO+xmoed3IOPVDSDG7OYSw=
```

`agent_id` in the plaintext is the app's agent id of the run: the run's
`session_key` when the app registered it as an agent, else the host's own
agent (`host:<device id>`). The `agent_id` field of the row and of the push
`data` is the host's roster id, as before; use the one in the seal.

## Push (supabase/functions/notify-run)

- **Android:** data-only message (no `notification` block), `priority:
  high`. `data` carries the old fields plus `preview_sealed` (the JSON
  object as a string) and `title`/`body` (the generic fallback). The app's
  background handler opens the seal and shows the local notification. If
  `data` would exceed 3.5 KB, `preview_sealed` is dropped.
- **iOS:** keeps the `notification` block (generic text) with
  `mutable-content: 1` and the same `data`, so a Notification Service
  Extension can replace the text. The extension is not built yet (iOS is not
  shipped).

## Avatar on the host (app -> host)

The host draws no avatar itself. The app sends it over the sealed relay:

```json
{"type": "agent_avatar_set", "agent_id": "<id>", "png_b64": "<PNG, <=128 KB>"}
```

The host checks the PNG signature and the size, and stores it as
`<workspace>/avatars/<agent_id>.png` (a `:` in the id becomes `_` in the file
name; an id must match `[A-Za-z0-9:_.-]{1,128}`). The host answers with one
terminal frame `{"type": "agent_avatar", "agent_id": "<id>", "ok": true}`, or
`"ok": false` with an `error`. A host that keeps avatars names `agent_avatar`
in `host_route.capabilities`. The desktop toast uses that file as
its icon. The app sends it when an agent is created, renamed or its photo
changes, and once per agent after pairing (the host may have none yet).

## Platforms

| Platform | Who shows it | Icon | Body |
|---|---|---|---|
| Linux (host PC) | host `notify-send` / `gdbus` | `avatars/<id>.png` | preview |
| Windows (host PC) | host PowerShell toast | `avatars/<id>.png` | preview |
| macOS (host PC) | host `osascript` (no custom icon possible) | app | preview |
| Android | app: FCM data -> local notification | large icon = avatar | opened seal |
| iOS | FCM notification (NSE later) | app | generic until NSE |
| Linux / Windows / macOS app | `flutter_local_notifications` | avatar file | preview |

## Phones without Google Play (UnifiedPush)

FCM needs Google Play services. A phone without them uses
[UnifiedPush](https://unifiedpush.org): a distributor app (ntfy, or any
other) keeps ONE connection for all apps, so there is no polling and no
battery cost for this app.

- The app registers with the distributor (Flutter package `unifiedpush`)
  when FCM is not available, and stores the endpoint URL in
  `cowork_device_tokens` with `platform = 'unifiedpush'` and
  `token = <endpoint URL>`.
- `notify-run` POSTs to that URL (https only), with `Content-Type:
  application/json`, `TTL: 86400` and `Urgency: high`. The body is the same
  JSON as the FCM `data` (with `preview_sealed`). A 404 or 410 removes the
  token row. The distributor sees only ciphertext and
  the generic fallback text.
- The app's UnifiedPush message handler opens the seal exactly like the FCM
  background handler and shows the same local notification.
- No FCM and no distributor: no push. Settings show one line that says how
  to get it (install a UnifiedPush distributor such as ntfy). There is no
  polling fallback.

## Firebase project

`android/app/google-services.json` turns FCM on in the Android build
(`android/app/build.gradle.kts`). The Edge Function needs the FCM service
account in the Supabase secret `FCM_SERVICE_ACCOUNT` (see
`supabase/functions/notify-run/index.ts`).

## App implementation

Code in `lib/services/notifications/` unless named otherwise.

- **Avatar PNG:** `notification_avatar.dart` (`AgentNotificationAvatar`).
  It paints the agent's face with `paintShareTargetIcon(badge: true)`
  (`lib/services/share/share_target_icon.dart`): a 192 px round badge with
  transparent corners, the user's photo or the figure the profile picks.
  The file is `<app support>/notification_avatars/<id>.png`. A `<id>.key`
  file next to it holds a fingerprint (name, photo, colour, figure). A
  changed fingerprint paints again. A PNG over 128 KB is painted at 160,
  128 or 96 px. The push isolate only reads the file (`cachedPath`).
- **Local toast:** `local_notifications.dart`. Title = agent name, body =
  `notificationPreview` (rule 2, 300 characters), a stopped run keeps its
  plain sentence. "Show answer preview in notifications" is on by default
  (`notifications_show_answer_preview`); off gives the generic body. Icon:
  Android `largeIcon` (the small icon stays `ic_notification`), Linux
  `FilePathLinuxIcon`, macOS/iOS an attachment (a copy, the OS moves it),
  Windows `appLogoOverride` with a circle crop. Windows is on
  (`flutter_local_notifications_windows`, AUMID `dev.chuk.chat`).
- **Seal:** `sealed_preview.dart` (pure Dart, `package:cryptography`).
  `test/services/notifications/sealed_preview_test.dart` checks the host
  vector above and a second vector made with Python `cryptography`.
- **Push:** `push_presenter.dart` turns one push `data` map into one toast.
  It loads the pairing (secure storage), opens the seal for its
  `channel_id` and shows name, preview and the cached face. Any failure
  shows the generic `title`/`body`. Callers: the FCM background handler
  (`agentsPushBackgroundHandler`, skips a push with a `notification`
  block), FCM `onMessage` (skipped when the thread is on screen) and
  UnifiedPush.
- **UnifiedPush:** `unified_push_transport.dart`, package `unifiedpush`
  6.1.0 (6.2.0 needs `window_manager` 0.5, the app is on 0.7). Used on
  Android when FCM gives no token in 15 s. The endpoint URL goes to
  `cowork_device_tokens` with `platform = 'unifiedpush'`. With the app
  closed, the plugin's service starts `main(['--unifiedpush-bg'])`; `main`
  then runs `unifiedPushBackgroundMain` only. No FCM and no distributor:
  `PushService.channel` is `unavailable` and Settings > Customization >
  Notifications shows how to get push.
- **Avatar to the host:** `lib/services/agents/agent_avatar_sync.dart`.
  The shell runs it 2 s after a roster change, a profile change, an
  `agent_list` answer or a change of `hostCapabilities`. It sends
  `agent_avatar_set` only when the host names `agent_avatar`. It remembers
  per host which fingerprint it sent (`cowork_agent_avatar_sent_v1` in
  SharedPreferences), so a launch with nothing new sends nothing. The
  host's `agent_avatar` answer is not read yet: a rejected PNG is not sent
  again until the picture changes.
