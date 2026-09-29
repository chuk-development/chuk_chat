# chuk-voice

chuk-voice is the voice worker for voice calls in chuk_chat. It is a LiveKit
agent. It listens to the user, thinks, and speaks. The pipeline is:

    mic → VAD (Silero) → STT (Groq Whisper) → LLM (+ tools) → TTS (Cartesia)

This package is a fork of `new-voicemode/server`. The pipeline, the tools and
the latency settings are the same. This fork adds the chuk_chat contract:
dispatch metadata, task delegation to the app, and calls that the agent starts.

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
- `GROQ_API_KEY`: STT, the default LLM, vision, web search.
- `CARTESIA_API_KEY`: TTS.

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
  "stt_language": "de | en | null",
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
- `stt_language = "de"`: the assistant speaks German by default.
- `initiated_by = "agent"`: the agent started the call. The assistant speaks
  first. It greets the user and tells the reason from `call_reason` in one or
  two short sentences. Then it listens. When `call_reason` is empty, it says
  that it called and asks what the user needs.
  Before the greeting, the worker waits up to 15 s for the app to join.

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

### Unchanged from new-voicemode

- Data topics `ui.card` and `ui.tool`: same names, same payloads.
- Phone RPCs `open_link`, `get_location`, `get_device_status`: same names and
  payloads. When the app answers with an error, the tool returns a short
  failure line. The session continues.
- RPCs `change_voice` and `change_model`.
- Transcriptions: LiveKit publishes them on `lk.transcription`, aligned to the
  TTS audio. The app builds the chat transcript from them.

### Differences from new-voicemode

- The worker does not resume the transcript of earlier calls, and it does not
  summarise a call after it ends. The app sends the chat context instead. The
  worker keeps only the facts from the `remember` tool.
- In agents mode with delegation, the tool `research_in_background` is not
  available. `delegate_task` does that work.

## Files

- `agent.py`: worker entry point, session setup, RPC handlers.
- `call_config.py`: metadata parsing, system prompt, greeting. No LiveKit.
- `delegation.py`: task list and delegation texts. No LiveKit.
- `tools.py`: the function tools.
- `background.py`: background jobs and speech at quiet moments.
- `ui_bridge.py`: `ui.card`, `ui.tool` and RPCs to the app.
- `vision.py`: camera and screen narration.
- `memory.py`: facts from the `remember` tool.
- `tests/`: pytest tests for `call_config.py` and `delegation.py`.
