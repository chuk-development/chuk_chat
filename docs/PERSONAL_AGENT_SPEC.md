# Personal agent — voice, reach, context and hands for Agents

**Status:** draft spec, 2026-09-29. Written on the owner's instruction after a
product discussion. Nothing in it is built yet unless §3 says so.
Read this before you touch `lib/assistant/`, `agents/host/src/chuk_agents_host/notify.py`,
`extension/`, the voice-call slot, or the separate repo `/home/user/git/new-voicemode`.

Beads: epic `chuk_chat-lgq2`, milestones M0–M6 = `chuk_chat-lgq2.1` … `.7` (§11, §13).

Sections are numbered so feedback can point at them.

---

## 1. What this is

The Agents coworker becomes a personal agent that:

1. **talks** with the user live, full duplex, and the user can interrupt it;
2. **reaches** the user at the right moment, on the right device — it rings the
   app like a phone call, it does not dial a phone number;
3. **knows the context** — phone locked or not, user at the PC or not,
   headphones connected or not, where the user is (opt-in);
4. **acts** — in the user's own browser (add-on), on the phone (open app,
   navigate, media), on the PC (open URL, media), and in the home (Home Assistant);
5. **shows** a home dashboard that the agent edits on request (todos, calendar,
   weather, activity, home).

The chat is not replaced. Voice, calls and the dashboard are more surfaces on the
same agent, the same thread, the same memory.

## 2. Why

The consumer agent category is complete. OpenAI shipped "Dots" (always-on
agents, own cloud computer, persistent memory, 4000+ connectors) on 2026-09-29.
Meta ships Muse, Ray-Ban Meta Audio and the Muse Charm keychain (Connect 2026).
Rabbit shipped OS3 (cloud agent + local node, BYO keys) on 2026-09-22.

None of them has the full set below. That set is the product gap:

| Capability | Dots | Muse | Rabbit OS3 | Us after this spec |
|---|---|---|---|---|
| Agent calls you **in the app** at the right moment | no | no | no | yes (§6) |
| Picks the device: PC, headphones or phone ring | no | no | no | yes (§7) |
| Dashboard that the agent edits | no | no | no | yes (§9) |
| Drives **your own** browser | no | no | yes (DLAM, USB) | yes (§8.3) |
| Home Assistant, local PC | no | no | PC only | yes (§8, §10) |
| Self-hosted, server is zero-knowledge for credentials | no | no | partly | yes (§4) |

Money reasons, in order:

1. The combination is not available from the big vendors. They avoid
   liability-heavy features (proactive calls, device control, location).
2. It reuses what exists. About 70 % of the parts are built (§3).
3. Voice is the surface that normal users use. Chat-only agents lose them.

## 3. What already exists (verified 2026-09-29 — do not rebuild)

### 3.1 Voice

| Piece | Where | State |
|---|---|---|
| Full-duplex voice agent, barge-in, preemptive TTS, word-aligned truncation | `new-voicemode/server/agent.py` (livekit-agents ~=1.6) | works, prototype, single user |
| Pipeline | Silero VAD, LiveKit `inference.TurnDetector`, Groq `whisper-large-v3-turbo` (batch), Groq `openai/gpt-oss-120b`, Cartesia `sonic-3`, BVC noise cancel | works |
| 19 voice tools, UI cards (`ui.card`, `ui.tool`), phone RPC (`open_link`, `get_location`, `get_device_status`) | `new-voicemode/server/tools.py`, `ui_bridge.py`, `app/lib/services/agent_ui_bridge.dart` | works |
| Proactive speech while a session is open | `new-voicemode/server/background.py:121` (`speak_when_idle`) | works |
| Flutter voice client (LiveKit starter fork) | `new-voicemode/app/` (`livekit_client ^2.10`) | works |
| Android "active call" ongoing notification | `new-voicemode/app/.../MainActivity.kt`, `call_notification_service.dart` | works |
| Dictation in the composer | `lib/platform_specific/chat/handlers/audio_recording_handler.dart`, `lib/services/streaming_transcription_service.dart` | works (text arrives after stop) |
| STT endpoints | `api_server/routers/ai/transcribe.py:56` (POST), `:274` (WS), Groq Whisper, billed | works |
| Android assistant surface (ASSIST gesture, device tools) | `lib/assistant/*`, `android/.../assist/*`, `docs/ASSISTANT_SURFACE.md` | works, but **no speech output** and **no barge-in** (doc is stale on TTS) |
| Voice-mode button | `lib/platform_config.dart:37` `kFeatureVoiceMode` | placeholder ("Coming soon") |
| Voice-call button on the agent profile | `lib/pages/agent_profile_page.dart:287`, `mobile_agent_sheet.dart:144` | disabled placeholder |
| Parked voice-call slot in the chat chrome | `docs/EXPRESSIVE_UI_REDESIGN.md:47` | parked |

### 3.2 Agent backend (host on the user's machine)

| Piece | Where | State |
|---|---|---|
| Sealed relay app ⇄ `api.chuk.chat` ⇄ host, pairing, reconnect | `agents/common/chuk_agents_crypto/`, `host/cloud_relay.py`, `docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md` | works |
| Tool families: shell, terminal, files, web, MCP, secrets, skills, media, browser | `agents/runtime/src/chuk_agents_runtime/runtime.py:365-522` | works |
| Automations: `schedule_task` (cron/every/at), `start_watcher`, `agents_hooks.trigger` | `runtime/automations.py:364-492`, `host/automations.py:307` | works, live-proven |
| Self-started runs | `host.py:1651 _fire_automation` → `executor.py:1554 submit_task` | works |
| Notify: desktop toast, FCM (content-free), ntfy, webhook | `host/notify.py`, `host/desktop_notify.py`, `supabase/functions/notify-run/` | works (cloud table bug `cowork-b55k`) |
| Mem0 memory, persona files, compaction ladder | `runtime/memory.py:306`, `runtime/context.py:534` | works |
| Context hook for each turn | `runtime/loop.py:298` `context_providers` | exists, unused for device context |
| Subagents, group rooms | `runtime/subagents.py`, `manager/group_room.py` | works |
| Unattended runner, cost modes, `[SILENT]`, daily summary | `manager/autonomy.py`, `manager/daily_summary.py` | library only, **not wired into host** |

### 3.3 Device, dashboard, integrations

| Piece | Where | State |
|---|---|---|
| FCM token registry | `lib/services/notifications/push_service.dart`, `cowork_device_tokens` | works; background handler does nothing |
| Phone actions (open app, `google.navigation:` intent, media, volume, dial, SMS draft, timers) | `lib/assistant/assistant_tools.dart:139-669`, `AssistantHostActivity.kt` | works, **only for the overlay and the chat loop** |
| Foreground location | `lib/services/device_services.dart:85` | works, no background, no geofence |
| Notification listener, accessibility service | `AssistNotificationListenerService.kt`, manifest :96-117 | works |
| Inline typed blocks (chart, map, weather, …), ask-user chips, artifacts | `lib/widgets/message_bubble/rich_blocks.dart`, `ask_user_card.dart` | works, but only inside a message |
| Google Calendar + Gmail (OAuth) | `lib/services/google_oauth.dart`, `platform_tools_native.dart:366-436` | works (chat loop only) |
| MCP client with on-device OAuth, catalogue | `lib/services/mcp/*`, `mcp_catalogue.dart` | works |

### 3.4 User browser add-on

| Piece | Where | State |
|---|---|---|
| MV3 add-on (Chrome) + Firefox build, CDP driving, leases, own tab group, snapshot diffing | `extension/src/*` | built, unit-tested, **never run in a real browser** |
| Native messaging bridge + MCP server named `playwright` | `tools/agents-browser-bridge/`, `tools/agents-extension-mcp/` | built, tested |
| Target selection | env `AGENTS_BROWSER_TARGET=user_browser` (`executor/protocol.py:1054-1102`) | host-wide only |

## 4. Hard constraints

These come from existing decisions. This spec does not change them unless it says so.

1. **The host is the truth. The client is a window.** (`docs/PRODUCT_PHILOSOPHY.md`)
2. **chuk's server is zero-knowledge for credentials and execution.**
   Credentials stay in `FlutterSecureStorage` and go sealed to the host.
   (`docs/COWORK_SELF_HOSTED_PIVOT.md`)
3. **No content in push payloads.** A push carries an id only. The app fetches
   the content over the sealed relay.
4. **All app ⇄ host traffic goes through the relay.** No P2P. 1 MB frame cap.
   (`docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md`)
   Voice media is a separate plane through a LiveKit SFU. An SFU is a server,
   not P2P, so this is in line with the decision.
5. **Talk as little as possible.** Proactive contact needs a rule or a clear
   user request. Default is silent. (`docs/PRODUCT_PHILOSOPHY.md`)
6. **Each sensor is its own opt-in.** Location, notification access, PC
   activity and audio route each have a switch, default off.
7. **Context data goes to the user's host only.** Never to Supabase in plain
   text, never into FCM, never into logs (`kDebugMode` guard).
8. **Design:** `ExpressiveScreen`, HugeIcons, one button family, no coloured
   `BoxShadow` (`docs/DESIGN.md`).
9. **A voice call is not end-to-end encrypted.** Rule 7 does not cover it.
   When a call starts, the app puts context into the LiveKit dispatch
   metadata: the last text messages of the thread (at most 10 messages and
   4000 characters) and, for a call that the agent starts, the reason for the
   call. The app sends this metadata to the token endpoint `/v1/voice/token`.
   LiveKit then gives it to the voice worker. The voice worker is a chuk
   service, not the user's host. The worker also receives the audio and the
   transcript of the call. It sends them to its speech and language models.
   Transport encryption (TLS) protects these paths. Chuk's services and the
   model providers can read the data. The token endpoint does not log the
   metadata; it logs only its size. The model path of the worker is not
   end-to-end encrypted. Do not describe it as end-to-end encrypted.

### 4.1 Decisions this spec changes

- **`docs/AGENTS_AGENT_PLATFORM_PLAN.md` §1.1** says access to the user's own
  machine "is explicitly not this product". This spec **overrides** it for three
  surfaces only, each behind its own opt-in: the user browser add-on (§8.3),
  PC actions (§8.2) and PC activity (§7). The sandbox stays the default for
  all other work.
- **`docs/AGENT_SERVICE_APIS.md:273-279`** removed banking ("PSD2 komplett
  raus"). This spec proposes a **read-only FinTS** tool that runs only on the
  self-hosted host with credentials from the secrets vault. No aggregator,
  nothing stored at chuk. **Owner must confirm** (open question Q5).

## 5. Architecture

```
                    ┌────────────────────────── api.chuk.chat ───────────────────────────┐
                    │  /v2/relay/ws (blind, sealed)   /v1/voice/token (new, JWT)   LLM proxy │
                    └──────┬───────────────────────────────┬─────────────────────┬────────┘
                           │ sealed frames                 │ LiveKit token        │
   ┌────────────┐          │                               │                      │
   │ Phone app  │──────────┤                        ┌──────▼──────────┐           │
   │ (Flutter)  │◀─ push ──┤ FCM / UnifiedPush      │  LiveKit SFU    │◀── audio ─┤
   │ call UI,   │  (id)    │                        │  (Cloud first)  │           │
   │ context,   │◀═══════ audio ═══════════════════▶│                 │           │
   │ dashboard  │          │                        └──────▲──────────┘           │
   └────────────┘          │                               │ audio                │
   ┌────────────┐          │                        ┌──────┴──────────┐           │
   │Desktop app │──────────┤                        │  Voice worker   │───────────┘
   │ idle, call │          │                        │  (from new-     │  STT/LLM/TTS
   └────────────┘          │                        │   voicemode)    │
   ┌────────────┐   native │                        └──────┬──────────┘
   │ Browser    │ messaging│                               │ RPC "ask_agent" via the
   │ add-on     │──────┐   │                               │ app that is in the call
   └────────────┘      │   │                               ▼
                   ┌───▼───▼──────────────────────────────────────┐
                   │ Host (agents-host, on the user's machine)     │
                   │ executor · runtime · mem0 · automations ·     │
                   │ notify · presence resolver (new) ·            │
                   │ dashboard store (new) · device bridge (new)   │
                   └──────────────────────────────────────────────┘
```

### 5.1 Where the voice worker runs — decision

**Phase 1 (build now): chuk runs the voice worker** as a LiveKit agent, as the
prototype does today. It is the mouth and the ears. It is **not** the brain for
actions.

- It keeps its fast, cheap voice tools (time, weather, calculate, stay_silent).
- For everything else it calls **`ask_agent(text)`**. That tool sends a LiveKit
  RPC to the app participant in the same room. The app is already a paired,
  sealed controller of the host. It submits the text as a normal turn in the
  agent's thread, waits for the result, and returns a short summary. The worker
  speaks it.
- Why this path: it reuses the existing pairing and seal. The worker never gets
  host credentials. Credentials stay zero-knowledge. The call transcript lands
  in the normal agent thread.
- Model I/O in the worker is not E2E. The pairing plan already says model I/O is
  not E2E (§3 there). Do not claim more.

**Phase 2 (later, self-hosters):** the host joins the room itself with a token
from `/v1/voice/token` and runs the `AgentSession` next to the executor. This
removes the app hop. Spike first: check that `AgentSession.start()` runs on a
room that the host joined with a plain participant token (Q2).

### 5.2 Call context brief

At call start the app asks the host (sealed) for a **brief**: persona name,
top mem0 facts, today's agenda, open todos, the call reason if the agent
started the call. The app passes the brief to the worker as job metadata. The
worker's own per-user JSON memory (`new-voicemode/server/memory.py`) is
**removed**. The host's mem0 is the only memory.

## 6. Voice mode and "the agent calls you"

### 6.1 Voice mode in chuk_chat (user starts the call)

- Port the LiveKit client parts from `new-voicemode/app/lib` into
  `lib/voice/` (controller, room, `agent_ui_bridge`, call notification).
- Surfaces:
  - the parked voice-call slot in the chat chrome (`EXPRESSIVE_UI_REDESIGN.md:47`);
  - the agent profile button (`agent_profile_page.dart:287`) and the mobile agent
    sheet (`mobile_agent_sheet.dart:144`);
  - the `kFeatureVoiceMode` button (replace "Coming soon").
- The voice screen uses `ExpressiveScreen`. It shows a live transcript, the
  agent's `ui.card`s, mute, speaker/headset output select, hang up.
- Text and voice share one thread. What is said is stored as normal messages.
- New api_server endpoint **`POST /v1/voice/token`**: checks the Supabase JWT
  (`auth/ws_auth.py` pattern), mints a room token with minimal grants, dispatches
  the worker with metadata. It replaces the open `new-voicemode/server/token_server.py`.
- Billing: meter voice minutes like `transcribe.py` meters STT (credits, 402 when empty).

### 6.2 Latency targets

| Step | Target |
|---|---|
| User stops speaking → first audio of reply | ≤ 800 ms p50 for voice-only answers |
| `ask_agent` answer (tool work on host) | agent says a short filler ("moment"), then answers; no dead air > 2 s |
| Barge-in → agent audio stops | ≤ 200 ms |

The biggest cost today is batch Whisper. Replace it with a **streaming STT**
with partials (Q3 picks the provider).

### 6.3 The agent calls the user (agent starts the call)

New host tool **`call_user(reason, urgency)`**. `urgency` ∈ `normal | high`.

```
agent turn → call_user(reason)
  → presence resolver picks a route (§7)
  → route "phone ring":
      host → notify.py → content-free data push {kind:"call", call_id}
      phone wakes → fetches call details over the sealed relay
      phone shows the incoming-call screen: "<agent name> — <short reason>"
      user accepts → app gets a token from /v1/voice/token (metadata: call_id)
      worker joins with the brief + reason → agent speaks first
  → route "headphones": auto-join without ringing, one soft tone, agent speaks
  → route "pc": the desktop app rings (or auto-joins) on the PC
  → declined / no answer in 30 s → normal notification with the reason
```

- **Reminders ring:** "remind me in 10 minutes about the pizza" =
  `schedule_task(at=now+10m)` whose fired run calls `call_user`. No Dart
  `Timer`. The in-memory timers in `device_services.dart:363-412` must move to
  the host (or `zonedSchedule` for pure local alarms).
- **Android:** `flutter_callkit_incoming` or own ConnectionService
  (`MANAGE_OWN_CALLS`), `USE_FULL_SCREEN_INTENT`, CallStyle notification,
  foreground service types `phoneCall` + `microphone`. FCM data message with
  priority `high`. UnifiedPush/ntfy as the self-hosted option (the host already
  has an ntfy sink).
- **iOS:** PushKit VoIP push + CallKit. iOS kills the app if a VoIP push does
  not report a call. So VoIP push is used **only** for `call_user`, never for
  other notices. Needs an entitlements file (none today).
- **Desktop:** the desktop app keeps a relay connection; it rings in-app. Linux
  also shows a `notify-send` toast with Accept/Decline.

## 7. Presence and context

### 7.1 Signals

| Signal | Source | How | Opt-in |
|---|---|---|---|
| `phone.interactive`, `phone.locked` | phone app | `PowerManager.isInteractive`, `KeyguardManager.isKeyguardLocked` | on with calls |
| `phone.audio_route` = `bt_headset \| wired \| speaker` | phone app | `AudioManager.getDevices(OUTPUTS)` + `AudioDeviceCallback` | on with calls |
| `phone.location`, geofence enter/leave | phone app | geolocator + OS geofencing, `ACCESS_BACKGROUND_LOCATION` | **separate switch** |
| `phone.activity` = still/walk/drive | phone app | Activity Recognition API | with location |
| `pc.idle_seconds`, `pc.locked` | host (if it runs on the PC) or desktop app | logind `LockedHint`, `org.freedesktop.ScreenSaver`, X11 idle (`xprintidle`) | **separate switch** |
| `pc.audio_route` | host or desktop app | PipeWire default sink (`pactl get-default-sink`) | with PC activity |
| `phone.notifications` (read-only) | phone app | existing `AssistNotificationListenerService` | **separate switch** |

**No camera.** Headphone state comes from the audio route. "Connected" is the
proxy for "worn"; Android does not expose in-ear detection in general.

### 7.2 Transport and storage

- New sealed frame **`context_update`** (app → host): changed signals only,
  debounced (≥ 10 s, location ≥ 100 m or geofence event).
- The host keeps the latest value per signal **in memory** with a TTL
  (default 10 min). It does not write location to disk. Geofence events may
  fire a trigger (§10).
- The runtime gets the snapshot through the existing `context_providers` hook
  (`runtime/loop.py:298`) as one short line, e.g.
  `context: pc active 12s ago · phone locked · headset connected · at "home"`.

### 7.3 Route rule for `call_user` and spoken notices

1. `pc.idle_seconds < 60` and PC not locked → **pc**.
2. `phone.audio_route` is a headset → **headphones** (announce, no ring).
3. else → **phone ring**.
4. `urgency=normal` and the user is in a calendar event marked busy → push
   notification only, no ring.

Android 14+ limits starting a microphone service from the background. If the
headphone auto-join is refused, fall back to ring (rule 3).

## 8. Hands

### 8.1 Phone tools for the host agent (device bridge)

Today the host cannot call phone tools (`agents_tool_call_handler.dart:1-16`).
Add a bridge:

- The host registers `device__*` tools. Execution is forwarded to the app with
  new sealed frames **`device_cmd`** / **`device_result`**.
- The app runs them with the existing code in `lib/assistant/assistant_tools.dart`.
- v1 set: `open_app`, `navigate_to` (`google.navigation:` intent),
  `media_control`, `volume`, `set_alarm`, `open_url`, `get_location` (on demand).
  `send_sms` and `call_contact` need an `approval_request` every time.
- No phone online → the tool returns "phone offline" and the agent falls back
  to a push notification.

### 8.2 PC tools

If the host runs on the user's PC (the normal self-hosted case), it runs these
locally. Else the desktop app runs them via the same `device_cmd` frame.

- `pc_open_url(url)` → `xdg-open` / `open` / `start`. Opens in the user's real browser.
- `pc_media(action)` → `playerctl` (Linux), AppleScript (macOS).
- `pc_notify(title, body)` → existing `desktop_notify.py`.
- Everything more than this goes through the browser add-on (§8.3). Almost all
  daily work happens in the browser.

### 8.3 User browser via add-on — finish the existing work

Keep the design in `docs/PLAN_2026-09-08_BROWSER_EXTENSION.md` and
`docs/RESEARCH_2026-09-08_BROWSER_CONTROL_APIS.md`. Remaining work:

1. **Run it in a real browser once** (runbook `docs/RUNBOOK_2026-09-08_USER_BROWSER.md`;
   fix its `~/git/cowork` paths).
2. **Host-owned socket** that lives as long as the host (`cowork-fa8.10`).
3. **Target per task / per chat** with fallback to the sandbox when no add-on is
   attached. Replace the host-wide env var.
4. **App UI:** "browser attached" indicator, target toggle, pairing screen.
5. **Watch from the phone:** stream screenshots of the leased tab over the relay
   (chunked, 1 MB cap). Today the screen view is off for the user browser.
6. **Safety:** domain allowlist + `approval_request` for new domains; fix the
   CDP exfiltration gap (`cowork-orm0.1`, P0); credential fill (`cowork-orm0.3`).
7. **Remote path** (host not on the browser's machine): wire frames
   `browser_cmd` / `browser_result` / `browser_attach` (`cowork-fa8.3`).
8. **Store builds:** Chrome Web Store listing, signed AMO XPI.

## 9. Dashboard

### 9.1 Model

The host stores one `dashboard.json` per agent workspace (host = truth).

```json
{
  "version": 1,
  "cards": [
    {"id": "c1", "type": "todo_list", "size": "m", "config": {"list": "default"}},
    {"id": "c2", "type": "agenda", "size": "m", "config": {"days": 1}},
    {"id": "c3", "type": "weather", "size": "s", "config": {"place": "home"}},
    {"id": "c4", "type": "activity", "size": "s", "config": {"source": "strava"}}
  ]
}
```

- **Fixed catalogue v1:** `todo_list`, `agenda`, `weather`, `note`, `metric`
  (KPI number + trend), `link_list`, `automation_status`, `activity`,
  `home_entity` (Home Assistant). The agent cannot ship new widget code.
  Unknown `type` → the app skips the card.
- The host validates every change against the catalogue schema before it
  stores it.

### 9.2 Todos

- New table `todos` in the host state DB: `id, list, text, due, done, created_at`.
- Tools: `todo_add`, `todo_list`, `todo_complete`, `todo_remove`.
- A checkbox tap in the app sends a sealed `todo_toggle` frame. No model call.

### 9.3 Agent tools and frames

- Tools: `dashboard_get`, `dashboard_set_card`, `dashboard_remove_card`,
  `dashboard_move_card`.
- Frames: `dashboard_state` (host → app, full state on attach), `dashboard_patch`
  (host → app, on change), `todo_toggle` (app → host).
- "Put my Strava on top and remove the weather" is one agent turn that ends in
  two tool calls.

### 9.4 App

- New **Home** tab first in `lib/platform_specific/mobile/mobile_home.dart`.
  Desktop: a Home entry in the Agents sidebar.
- Cards reuse the existing typed block renderers where possible
  (`rich_blocks.dart` weather, map, chart).
- Card data comes from the host with the state. The app does not call third
  party APIs for the dashboard.

## 10. Proactive loop and integrations

### 10.1 Event loop — make it affordable

A model call every few seconds is too expensive. Use three tiers:

1. **Sources** emit events: `context_update` (geofence, leave time), calendar,
   Home Assistant state changes, mail, watchers.
2. **Filter** without a model: rules and watcher scripts decide if an event
   matters. Only then `agents_hooks.trigger()`.
3. **Agent run** decides: `[SILENT]`, notification, or `call_user`.

Wire the existing `manager/autonomy.py` (`UnattendedRunner`, cost modes,
`[SILENT]`, hash-change wake) and `manager/daily_summary.py` into the host.
Both have tests and no caller today.

### 10.2 Standard automations (templates the user switches on)

| Template | Trigger | Action |
|---|---|---|
| Morning call | user's alarm time (`phone.next_alarm`) or fixed time | `call_user`: agenda, weather, important mail, parcels |
| Leave now | next event − travel time (routing API with traffic) − 5 min | `call_user` or notice + `navigate_to` button |
| Place reminder | geofence enter (e.g. supermarket) | notice with the stored reminder |
| Pizza timer | user request | `schedule_task(at)` → `call_user` |
| Evening summary | fixed time | `daily_summary` → dashboard `note` card |

### 10.3 Integrations

| Integration | How | Notes |
|---|---|---|
| Home Assistant | host MCP client → Home Assistant MCP server integration; a watcher on the HA WebSocket for events | token in the secrets vault |
| Calendar | Google exists (chat loop); add CalDAV via MCP; move calendar tools to the host (`cowork-95i.6`) | |
| Weather | Open-Meteo (no key) as default on the host; Brave rich data stays for chat | |
| Strava / activity | MCP connector with on-device OAuth | feeds `activity` card |
| Bank | read-only FinTS (`python-fints`) on the host, credentials from the secrets vault, no write actions | **needs owner OK (Q5)** |
| Messages | read-only via notification listener | **no automatic WhatsApp replies** — unofficial automation gets numbers banned |
| Payments | out of scope here; see `docs/RESEARCH_2026-09-09_LINK_AGENT_PAYMENTS.md` | |

## 11. Build order

Each milestone ends with green tests, CodeRabbit review and a commit.

### M0 — Fix the prototype's money leaks (first, small)

- `new-voicemode/app/.env` ships `GROQ_API_KEY` inside the APK (`.env` is a
  bundled asset). **Rotate the key** and remove `.env` from the assets.
- `token_server.py` mints tokens for anyone (no auth, CORS `*`). Take it offline
  or put auth on it until `/v1/voice/token` exists.
- Move memory compaction from `add_shutdown_callback` (10 s budget) to
  `on_session_end`.

### M1 — Voice mode in chuk_chat (user starts the call)

- `/v1/voice/token` in api_server (JWT, minimal grants, dispatch, metering).
- Voice worker from `new-voicemode/server` deployed as a chuk service; remove its
  JSON memory; add `ask_agent` (§5.1) and the brief (§5.2).
- `lib/voice/` client, voice screen, the three entry points (§6.1).
- Streaming STT (Q3).
- **Acceptance:** from the agent profile, start a call, ask "what is on my todo
  list and add milk" — the agent answers by voice, the todo appears in the
  thread, barge-in works, first audio ≤ 800 ms p50 for a voice-only answer.

### M2 — The agent calls you

- `call_user` tool, content-free data push, call-details fetch, Android call UI.
- Reminders through `schedule_task` → `call_user`; remove Dart `Timer` alarms.
- iOS PushKit + CallKit (can follow after Android).
- **Acceptance:** "remind me in 2 minutes about the pizza", lock the phone — after
  2 minutes the phone shows an incoming call from the agent; accept → the agent
  says the reminder first.

### M3 — Presence and context

- `context_update` frame, host presence store, `context_providers` line.
- Phone: interactive/locked, audio route. Host/desktop: PC idle/locked, audio sink.
- Route rule (§7.3). Location + geofences behind their own switch.
- **Acceptance:** same pizza test three times: at the PC → rings on the PC;
  headset connected, phone locked → agent speaks into the headset without a ring;
  neither → phone rings.

### M4 — Hands

- Device bridge (`device_cmd`/`device_result`) with the v1 set (§8.1).
- PC tools (§8.2).
- Browser add-on items 1–6 (§8.3); items 7–8 can follow.
- **Acceptance:** by voice from the phone: "open the video <title> on my PC" —
  the add-on opens it in the user's real browser and the phone shows a
  screenshot; "navigate me to <place>" — Maps opens with the route.

### M5 — Dashboard and todos

- `dashboard.json`, catalogue, validation, tools, frames (§9).
- Home tab.
- **Acceptance:** "put my todos on top and remove the weather" changes the Home
  tab within one turn; a checkbox tap marks the todo done without a model call.

### M6 — Proactive loop and integrations

- Wire `autonomy.py` + `daily_summary.py`; templates from §10.2.
- Home Assistant, Open-Meteo, CalDAV, Strava; FinTS after Q5.
- **Acceptance:** morning call at the alarm time with agenda + weather; "leave
  now" call fires with traffic; a Home Assistant state change can wake the agent.

## 12. Money risks

| Risk | Effect | Mitigation |
|---|---|---|
| Google Play: `USE_FULL_SCREEN_INTENT` is only for calling/alarm apps (Android 14+) | review rejection | declare the feature as calling; fallback to CallStyle heads-up notification |
| Google Play: `ACCESS_BACKGROUND_LOCATION` needs a declaration + video | review rejection, delay | location is a separate opt-in; ship M1–M3 without it first |
| iOS: VoIP push without a reported call | app killed, push revoked | VoIP push only for `call_user` |
| Voice minutes (SFU + STT + TTS + LLM) | margin loss | meter and bill per minute from day one; measure cost per minute in M1 |
| Leaked provider key in the APK (today) | direct cost | M0 |
| Automated WhatsApp replies | number ban | read-only only |
| Continuous model polling | token cost | three-tier event loop (§10.1) |

## 13. Tracking

Beads: epic **`chuk_chat-lgq2`** "Personal agent: voice, calls, context, hands, dashboard" with
one child per milestone: M0 `.1`, M1 `.2`, M2 `.3`, M3 `.4`, M4 `.5`, M5 `.6`, M6 `.7`. Existing beads that this spec uses:
`cowork-fa8.3`, `cowork-fa8.7`, `cowork-fa8.10`, `cowork-orm0.1`,
`cowork-orm0.3`, `cowork-orm0.5`, `cowork-b55k`, `cowork-95i.6`, `cowork-z9mo`,
`cowork-g7oc`, `cowork-g85d`, `chuk_chat-8sh`, `chuk_chat-c92`.

## 14. Open questions

- **Q1** Does `new-voicemode` merge into this repo (`agents/voice/` + `lib/voice/`)
  or stay a separate repo that this repo deploys? Recommendation: merge, so one
  bead tracker and one CI.
- **Q2** Phase 2: can the host run `AgentSession` on a room it joined with a
  plain token? Spike before any Phase 2 work.
- **Q3** Streaming STT provider (partials, German quality, price per minute).
  Measure two candidates in M1.
- **Q4** LiveKit Cloud or a self-run LiveKit server for production. Cloud first;
  decide on cost after M1 minutes are measured.
- **Q5** Read-only FinTS on the self-hosted host: allowed despite
  `AGENT_SERVICE_APIS.md` "Banking komplett raus"?
- **Q6** The Android assistant surface (`lib/assistant/`) and the new voice mode
  overlap. Recommendation: the overlay becomes a voice-mode entry point on the
  same worker, and its batch pipeline is removed after M1.
