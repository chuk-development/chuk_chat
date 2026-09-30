# chuk-voice

chuk-voice is the voice worker for voice calls in chuk_chat. It is a LiveKit
agent. It listens to the user, thinks, and speaks. The pipeline is:

    mic → noise cancellation (BVC) → VAD (Silero) → STT (Cartesia ink-whisper,
    streaming) → LLM (Groq, native tool calls) → TTS (Cartesia sonic-3)

This package is a fork of `new-voicemode/server`. The tools and the latency
settings are the same. This fork adds the chuk_chat contract: dispatch
metadata, task delegation to the app, calls that the agent starts, hang-up by
intent, and a streaming STT.

Versions: `livekit-agents` 1.8.3, `livekit-plugins-noise-cancellation` 0.3.2,
`livekit-api` 1.2.1 (see `uv.lock`).

The worker registers with the agent name `chuk-voice`. The deployed
new-voicemode worker uses `voice-assistant`. Thus a chuk_chat call goes only
to this worker.

Background: `docs/PERSONAL_AGENT_SPEC.md`, sections 5 and 6.

## Run

The worker needs [uv](https://docs.astral.sh/uv/). Do not use bare `python` or
`pip`.

```bash
cd agents/voice
./run.sh dev      # development mode
./run.sh start    # production mode
uv sync && uv run pytest -q   # tests
```

`run.sh` passes extra arguments to the LiveKit CLI. For example, use
`./run.sh dev --log-level info` to see the "registered worker" line. The
default log level is `warn`.

The worker health server listens on port 8093. The new-voicemode worker uses
port 8083, so both can run on one machine.

### Env file

The worker reads its settings from an env file. `run.sh` selects the file:

1. `VOICE_ENV_FILE`, when you set it.
2. `agents/voice/.env.local`, when it exists.
3. `new-voicemode/server/.env.local` as the fallback.

`run.sh` reads the fallback file in place. It does not copy it. Values that
are already in the environment win over the file.

Never commit an env file. This repository is public. `.gitignore` ignores
`.env.local*`.

### Environment variables

Names only. Get the values from the owner.

Required:

- `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`: the LiveKit project.
  LiveKit Inference (turn detector, adaptive interruption, Deepgram STT) also
  uses these.
- `GROQ_API_KEY`: the default LLM, vision, web search.
- `CARTESIA_API_KEY`: STT (default) and TTS.

Optional:

- `VOICE_PROVIDER`: `groq` (default), `together` or `cerebras`.
- `TOGETHER_API_KEY`, `CEREBRAS_API_KEY`: only for those providers.
- `VISION_MODEL`, `VISION_NARRATION`, `VISION_INTERVAL`: camera and screen
  vision.
- `TURN_DETECTOR`: `inference` (default, hosted) or `local`.
- `GROQ_SEARCH_MODEL`, `GROQ_RESEARCH_MODEL`: web search models.
- `MEMORY_DIR`, `MEMORY_MAX_ITEMS`: storage for facts from the `remember` tool.
- `LIVEKIT_LOG_LEVEL`: log level (default `warn`).
- `VOICE_ENV_FILE`: the env file (see above).
- `VOICE_HEALTH_PORT`: the health port (default 8093).
- `VOICE_STT`: `cartesia` (default, ink-whisper), `deepgram` (nova-3 through
  LiveKit Inference) or `groq` (old batch Whisper, fallback only).
- `VOICE_AWAY_TIMEOUT`: seconds of silence until the user counts as away
  (default 30).
- `VOICE_AWAY_HANGUP`: seconds after the "still there?" question until the
  worker hangs up (default 20).
- `VOICE_THINKING_SOUND`: `0` switches off the thinking sound (default on).
- `VOICE_MAX_CALL_SECONDS`: the longest call (default 3600). Then the agent
  says goodbye and deletes the room.

## Voice behaviour

- STT: the default STT streams and gives word-aligned transcripts. Adaptive
  interruption needs that: it tells a real interruption from an "mhm". With
  `VOICE_STT=groq` (batch), the SDK falls back to plain VAD interruption. At
  session start the log shows `adaptive interruption detector initialized`.
  The log must not show `interruption_detection is provided, but it's not
  compatible`.
- False interruption: a cough or a short noise pauses the agent. After 2 s of
  silence the agent continues where it stopped.
- Hang-up: the model calls the `end_call` tool when the user wants to end the
  call, in any wording ("tschüss", "ciao", "leg auf", "du kannst gehen",
  "das war's", "danke, reicht"). The model decides by intent. It does not use
  keyword matching. After the tool call it says one short goodbye, then the
  worker deletes the room. The app sees the disconnect and saves the
  transcript.
- User away: after 30 s of silence on both sides, the agent asks once "Bist
  du noch da?". After 20 s more of silence it says goodbye and deletes the
  room. While a delegated task or a background job runs, the worker waits and
  checks again every 10 s. After each result announcement the worker restarts
  the away countdown (`session.reset_away_timer()`).
- Call length: after `VOICE_MAX_CALL_SECONDS` (default 3600 s) the agent says
  goodbye and deletes the room.
- Reminders: with `delegate_available`, the model gives reminders to
  `delegate_task`. The host agent schedules them and can call back with
  `call_user`. `set_reminder` (a timer inside the call, lost at hang-up) exists
  only in calls without a delegate.
- Location: `get_device_location` asks the app (`get_location`, answer
  `{latitude, longitude, accuracy}` or `{error}`). The worker looks up the
  town name. When the app gives no position, the agent says it cannot see
  the location and asks for the place.
- Thinking sound: soft keyboard typing plays while the agent thinks or a tool
  runs. It comes on a second audio track from the agent participant.
- Tools: every tool is a LiveKit `@function_tool`. The Groq LLM
  (`livekit.plugins.groq.LLM`, an OpenAI-compatible client) gets them as
  native OpenAI `tools`. It returns structured `tool_calls`. The worker never
  parses tool calls from text.

## Contract with the app

### Dispatch metadata

The app dispatches the worker with a JSON string in `ctx.job.metadata`:

```json
{
  "user_id": "str",
  "mode": "chat | agents",
  "chat_title": "str | null",
  "agent_name": "str | null",
  "context": "str (max 4000 chars, can be empty)",
  "stt_language": "de | en | ... (device locale) | null",
  "delegate_available": true,
  "voice_id": "str | null",
  "llm_model": "str | null",
  "initiated_by": "user | agent",
  "call_id": "str | null",
  "call_reason": "str | null (max 1000 chars)"
}
```

The worker ignores unknown keys. A missing key gets its default. The defaults
are: `mode` = `chat`, `delegate_available` = `false`, `initiated_by` = `user`,
and the new-voicemode defaults for voice, model and language.

- `mode = "chat"`: the worker is a voice assistant in the chat `chat_title`.
  When its own tools are not sufficient, it can use `delegate_task` to give
  the request to the full chat model.
- `mode = "agents"`: the worker is the voice of the coworker agent
  `agent_name`. It uses `delegate_task` for all real work: files, browser,
  research, code. It keeps talking while the task runs.
- `context`: the recent chat messages. The worker puts them at the start of
  the system prompt. Thus the voice agent knows the topic of the chat.
- `stt_language`: the device language. The worker takes the first part of a
  locale (`de-DE` gives `de`). STT (Cartesia, Deepgram, Groq) and the default
  reply language use it. When the key is missing, the worker uses `de`.
- `initiated_by = "agent"`: the agent started the call. The assistant speaks
  first. It greets the user and tells the reason from `call_reason` in one or
  two short sentences. Then it listens. When `call_reason` is empty, it says
  that it called and asks what the user needs.
  The greeting runs in `Agent.on_enter`. Before it, the worker waits up to
  15 s for the app to join.

### Participants

The app joins with the identity `chuk-<user_id>`. The worker is the agent
participant. All RPCs from the worker go to `chuk-<user_id>`. When that
participant is not in the room, they go to the first non-agent participant.

### Delegation

Tool `delegate_task(task)`. The worker registers it only when
`delegate_available` is `true`.

1. The worker calls the RPC `chuk.delegate` on the app with the payload
   `{"task": "..."}`. The response timeout is 10 s.
2. The app answers `{"task_id": "...", "status": "started"}` or
   `{"error": "..."}`.
3. The tool returns at once. It does not wait for the result. The worker
   records the task as pending.

RPC `chuk.task_result`. The worker registers it on its local participant.

1. The app calls it with `{"task_id": "...", "status": "done | failed",
   "result": "..."}`.
2. The worker answers `{"ok": true}` at once. A bad payload gets
   `{"ok": false, "error": "..."}`.
3. The worker cuts the result to 6000 characters and marks the task done or
   failed.
4. The assistant tells the user the result when the user and the agent are
   both silent. It does not interrupt the user.

An unknown `task_id` does not change the task list. The worker logs a warning
and still announces the result, because the app is the source of truth.

Tool `check_tasks()` lists the tasks of this call with id, short text and
status.

### Cards on screen (`ui.card`)

The worker sends a card when a picture helps: weather, search results, places,
lists, links. The prompt tells the model to show a card ("ich zeig's dir").
The worker publishes each card as JSON on the data topic `ui.card`
(reliable). The app ignores a card with an unknown `v` and renders an unknown
`kind` with a generic body.

Envelope:

```json
{
  "v": 1,
  "id": "uuid4 string",
  "kind": "weather | search | news | article | map | list | calc | time | currency | stock | memory | task | reminder",
  "title": "str",
  "subtitle": "str | null",
  "source": "str | null (attribution, e.g. \"Open-Meteo\")",
  "data": { "kind-specific, see below" },
  "ts": 1727640000.0
}
```

`data` per `kind` (tool that sends it in brackets):

- `weather` (`get_weather`): `icon`, `condition`, `temperature`, `apparent`,
  `humidity`, `wind`, `precipitation`, `is_day` (bool), `units` (object),
  `hourly` (max 12 × `{time, temp, precip_prob, icon}`), `daily`
  (`{date, code, icon, condition, max, min, precip_prob}` per day),
  `latitude`, `longitude`. Title: place. Subtitle: country.
- `search` (`search_web`): `answer` (str), `results` (max 6 ×
  `{title, url, snippet}`), `summary` (`{title, extract, image, url}` from
  Wikipedia, or null). Title: query. Subtitle: the answer or null.
- `news` (`get_news`): `items` (max 8 × `{title, url, source, published}`).
- `article` (`read_page`): `url`, `text` (max 8000 chars).
- `map` (`show_place`): `latitude`, `longitude`, `name`, `detail`,
  `population`, `elevation`.
- `list` (`show_list`): `items` (max 20 × `{title, url?}`). `url` is present
  only for an http(s) link. Subtitle: "N Einträge".
- `calc` (`calculate`): `expression`, `result`.
- `time` (`get_time`): `iso`, `time`, `date`, `timezone`, `location`.
- `currency` (`convert_currency`): `amount`, `from`, `to`, `result`, `rate`,
  `date`.
- `stock` (`get_stock`): `symbol`, `name`, `price`, `change`, `change_pct`,
  `currency`, `series` (max 60 numbers).
- `memory` (`remember`): `facts` (list of str).
- `task` (`research_in_background`): `job_id`, `label`, `status`
  (`running`).
- `reminder` (`set_reminder`): `job_id`, `about`, `due_iso`.

Tool status goes on the data topic `ui.tool`:
`{"v": 1, "call_id": str, "name": str, "status": "running | done | error |
cancelled", "message": str | null, "ts": float}`. Only the first event of a
call carries `name`; later events have `name: ""`.

### Unchanged from new-voicemode

- Data topics `ui.card` and `ui.tool`: same names, same payloads. The new
  `list` kind is the only addition.
- Phone RPCs `open_link` and `get_location`: same names and payloads. When
  the app answers with an error, the tool returns a short failure line. The
  session continues. The worker no longer calls `get_device_status`.
- RPCs `change_voice` and `change_model`.
- Transcriptions: LiveKit publishes them on `lk.transcription`, aligned to the
  TTS audio. The app builds the chat transcript from them.

### Differences from new-voicemode

- The worker does not resume the transcript of earlier calls, and it does not
  summarise a call after it ends. The app sends the chat context instead. The
  worker keeps only the facts from the `remember` tool.
- In agents mode with delegation, the tool `research_in_background` is not
  available. `delegate_task` does that work.
- New tools: `end_call`, `show_list`.
- Wikipedia requests send a user agent with a contact URL. Wikimedia blocks
  the old generic user agent with HTTP 403.

## Files

- `agent.py`: worker entry point, session setup, RPC handlers.
- `call_config.py`: metadata parsing, system prompt, greeting, end-call and
  away texts. No LiveKit.
- `delegation.py`: task list and delegation texts. No LiveKit.
- `tools.py`: the function tools.
- `background.py`: background jobs and speech at quiet moments.
- `ui_bridge.py`: `ui.card`, `ui.tool` and RPCs to the app.
- `vision.py`: camera and screen narration.
- `memory.py`: facts from the `remember` tool.
- `tests/`: pytest tests for `call_config.py` and `delegation.py`.
