# Assistant surface

Chuk Chat can take the Android assistant role. Holding the home gesture opens a
translucent surface over whatever app is on screen: it listens, sees the
screen, answers out loud, and acts on the device.

Ported from the `assistend` prototype (`/home/user/git/assistend`). Groq and
LiveKit did not come with it — speech and model both run through the API proxy
the chat already uses.

## Where it lives

| Layer | Files |
|---|---|
| Overlay UI | `lib/assistant/assistant_overlay.dart` |
| Result cards | `lib/assistant/assistant_cards.dart`, `lib/assistant/assistant_result.dart` |
| Turn loop | `lib/assistant/assistant_session.dart` |
| Endpointed mic | `lib/assistant/assistant_microphone.dart` |
| Tools | `lib/assistant/assistant_tools.dart` |
| Model pin + prefs | `lib/assistant/assistant_config.dart` |
| Native channel wrappers | `lib/assistant/assistant_bridge.dart` |
| Settings page | `lib/pages/assistant_settings_page.dart` |
| Kotlin | `android/app/src/main/kotlin/dev/chuk/chat/assist/` |

Kotlin classes: `AssistantHostActivity` (the `chuk/assistant` MethodChannel —
`MainActivity` extends it), `AssistOverlayActivity` (the `ASSIST` intent,
transparent, own task affinity), `AssistAccessibilityService` (screen text,
scrolling, taps, screenshots), `AssistNotificationListenerService`,
`VoiceForegroundService`, `AssistantRuntime`.

## One turn

1. `AssistantMicrophone` streams PCM16 at 16 kHz through `record` and decides
   where an utterance ends (see below). It hands over a WAV.
2. `ChatApiService.transcribeAudioBytes` posts it to
   `POST /v1/ai/transcribe-audio` with the Supabase JWT.
3. `WebSocketChatService.sendStreamingChat` runs the turn over the shared
   `/v2/ws` multiplex socket with `tools: assistantToolSchemas`.
4. Native `tool_calls` come back as `ChatStreamEvent.toolCalls`. Each call runs
   against `AssistantBridge` or the server proxy; the results go into the
   history as `role: "assistant"` + `tool_calls` followed by one `role: "tool"`
   message per result, and the next pass sends an **empty** message — the tool
   results are the model's input, not a synthetic user turn. Same shape the
   chat tool loop uses (`tool_call_handler.dart`).
5. The answer is spoken through `flutter_tts` (offline, Android). The
   microphone pauses while speaking, otherwise the assistant transcribes
   itself.

## The model is pinned, and reasoning cannot be turned off

`kAssistantModelId = 'z-ai/glm-5.3-flash'`, `fireworks/serverless`,
`kAssistantReasoningEffort = 'low'`.

`low` is **not** a preference, it is the floor. GLM 5.3 is a thinking-only
model. Verified live against both routes on 2026-09-12:

- OpenRouter, `reasoning: {effort: "none"}` →
  `400 Reasoning is mandatory for this endpoint and cannot be disabled.`
  Model-level `reasoning: {mandatory: true, supported_efforts: [max, high, low],
  default_effort: max}`.
- Fireworks direct, `reasoning_effort: "none"` →
  `400 GLM-5.3 is a thinking-only model; disabling thinking
  (reasoning_effort='none') is not supported.` `chat_template_kwargs:
  {thinking: false}` fails with the same error.

The API server already drops a `none` for models flagged
`reasoning_mandatory` (`api_server/chat/reasoning.py`, pinned by
`tests/test_reasoning_mandatory.py`), so sending one would not disable
anything — it would silently fall back to the provider default `max`, which is
slower. `assistant_tools_test.dart` asserts the constant stays off `none`.

To get reasoning genuinely off, the model has to change. Tool-capable
alternatives with `reasoning_mandatory: false` and a `none` level:
`deepseek/deepseek-v4-flash-0731`, `deepseek/deepseek-v4-pro-0813`,
`moonshotai/kimi-k3`, `qwen/qwen3.6-27b`. It is a one-line change in
`assistant_config.dart`.

## Endpointing is energy-based, not Silero

The `vad` package (Silero ONNX, what `assistend` used) pins `record` at
`^6.1.2`; this app is on `^7.1.1` and its whole voice-input path depends on the
7.x API. Taking `vad` would mean downgrading that. So `AssistantMicrophone`
does the endpointing itself on the PCM stream:

- RMS per chunk, adaptive noise floor (rises slowly, falls fast), speech is
  `max(0.012, floor × 3.2)`.
- 320 ms pre-roll so the first syllable is not clipped.
- 750 ms of silence closes the utterance; under 350 ms of voiced audio is
  discarded as a cough; 30 s is the hard cap.

`debugFeed` is the test hook — `test/assistant/assistant_microphone_test.dart`
drives the whole state machine without a recorder or a binding.

## Tools

`assistantTools` is deliberately **not** the chat registry. The surface is
latency-critical and every schema is paid for in every spoken turn, so
artifacts, sandboxes, GitHub and the rest stay out (a test pins this).

Device: `read_screen`, `find_on_screen`, `look_at_screen`, `tap_text`,
`system_action`, `open_app`, `open_maps`, `list_apps`, `find_contact`,
`call_contact`, `send_sms`, `set_timer`, `set_alarm`, `clock_action`,
`media_control`, `now_playing`, `volume`, `get_location`,
`recent_notifications`, `get_time`.

Server, through the proxy: `web_search` (`/v1/tools/brave/search`),
`search_places` and `search_restaurants` (Brave Local, via
`searchPlacesWithMap` / `searchRestaurantsWithMap` in `map_tools.dart`),
`weather`.

`look_at_screen` takes an accessibility screenshot and sends it to the same
model as a `data:image/jpeg;base64,…` image — GLM 5.3 Flash is multimodal, so
there is no second vision model.

**Navigation goes through `open_maps`**, which fires a `geo:` intent with no
package, so the user's own maps app handles it. `open_app` with a guessed name
like "Google Maps" opens whatever the fuzzy match finds, and many devices have
no Google Maps at all.

A tool returns an `AssistantToolOutcome`: the JSON the model reads, plus an
optional `AssistantCard` the surface draws. Cards are built from the data the
tool already holds — waiting for the model to copy an address or a rating into
a tag costs a round trip and gets it wrong often enough to matter.

## Adding a device capability

Three edits, in this order:

1. a wrapper in `lib/assistant/assistant_bridge.dart`,
2. a handler branch in `AssistantHostActivity.kt`,
3. an `AssistantTool` entry in `lib/assistant/assistant_tools.dart`.

## Traps

- **`home:` and `onGenerateInitialRoutes:` are mutually exclusive.** Flutter
  asserts on the pair and the app dies on the first frame. `lib/main.dart`
  therefore builds the app home inside the default branch of
  `onGenerateInitialRoutes`. The assist activity starts Flutter on
  `/assistant-overlay` and must get a stack of exactly **one** route —
  otherwise closing the surface only pops back to the app home inside the
  assist task instead of finishing the activity.
- The route name is in two places that have to agree:
  `assistantOverlayRouteName` in `assistant_overlay.dart` and
  `getInitialRoute()` in `AssistOverlayActivity.kt`.
- Screenshots go to a model, so `AssistAccessibilityService` scales the long
  edge to 1280 px and encodes JPEG. Full-resolution PNG is too large.
- The surface shows the quoted request and the answer only once the turn is
  done (`busy == false`). While it runs it shows the state, the tool list and
  the waveform — never half-written text.
- Nothing in `lib/assistant/` may carry its own palette. Every colour comes off
  `Theme.of(context).colorScheme`, which Chuk Chat derives from the user's
  accent, background and contrast.

## Permissions

The settings page (`Settings → AI & Chat → Assistent`) sets the assistant role
and shows the state of each permission. All of them are granted in a system
screen, so the page re-reads them on `AppLifecycleState.resumed`.

| What | Needed for |
|---|---|
| Assistant role | The home gesture opening Chuk Chat at all |
| Accessibility service | Screen text, screenshots, tapping in other apps |
| Notification access | Recent notifications, media transport control |
| Contacts | `call_contact`, `send_sms` |
| Location | Places nearby, navigation |
| Microphone | Everything |

The onboarding tour points at the settings tile as its last step
(`_Step.pointerSettingsAssistant`), and skips straight to the finale on every
platform that is not Android.
