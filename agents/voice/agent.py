"""chuk-voice — the voice worker for chuk_chat voice calls.

Forked from new-voicemode/server. The pipeline is unchanged; this copy adds the
chuk_chat contract: dispatch metadata (mode, chat context, delegation), the
``delegate_task`` / ``chuk.task_result`` RPC pair, and agent-started calls.
See README.md for the contract.

The full pipeline runs server-side.

    mic → VAD (Silero) → STT (Groq Whisper) → LLM (+ tools) → TTS (Cartesia)

The LLM owns a toolset (``tools.ALL_TOOLS``) that reaches the live web, the
user's phone, and everything in between.  Each tool speaks a short answer *and*
pushes a structured card to the Flutter app over the ``ui.card`` data topic, so
"what's the weather" produces both a spoken reply and a forecast card on screen.

Tool lifecycle is mirrored to the app on ``ui.tool`` so the UI can show what
the assistant is doing while it does it.
"""

import asyncio
import json
import logging
import os
from typing import Any

from dotenv import load_dotenv

from livekit import agents, rtc
from livekit.agents import (
    Agent,
    AgentSession,
    AudioConfig,
    BackgroundAudioPlayer,
    BuiltinAudioClip,
    EndpointingOptions,
    InterruptionOptions,
    PreemptiveGenerationOptions,
    ToolExecutionUpdatedEvent,
    TurnHandlingOptions,
    UserStateChangedEvent,
    get_job_context,
    inference,
    room_io,
)
from livekit.agents.llm import ChatContext, ChatMessage, ImageContent
from livekit.plugins import cartesia, groq, noise_cancellation, openai, silero

import call_config
import delegation
import memory as conversation_memory
import tools as agent_tools
from background import BackgroundRunner
from tools import SessionData
from ui_bridge import UiBridge
from vision import VideoNarrator

# run.sh points VOICE_ENV_FILE at agents/voice/.env.local, or at the
# new-voicemode one as a fallback. Values already in the environment win.
load_dotenv(os.environ.get("VOICE_ENV_FILE", ".env.local"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Quiet by default: only warnings/errors.  The LiveKit CLI configures the root +
# plugin loggers from LIVEKIT_LOG_LEVEL; we default it to WARNING so the console
# shows real problems, not the INFO/DEBUG firehose.  Override anytime with
# `--log-level debug` or `LIVEKIT_LOG_LEVEL=error`.
# NOTE: we deliberately do NOT call logging.basicConfig() — the CLI installs its
# own handler, and adding ours duplicated every line.
os.environ.setdefault("LIVEKIT_LOG_LEVEL", "warn")

logger = logging.getLogger("voice-agent")

#: The name the app dispatches. It must differ from the deployed
#: new-voicemode worker ("voice-assistant"), so a chuk_chat call never lands
#: there and a new-voicemode call never lands here.
AGENT_NAME = "chuk-voice"

#: Worker health port. new-voicemode uses 8083, so a local run of both does
#: not collide.
HEALTH_PORT = int(os.environ.get("VOICE_HEALTH_PORT", "8093"))

#: Cartesia voice used when the app sends no voice_id.
_DEFAULT_VOICE_ID = "a57ad970-c054-4229-90e1-5e9620838b07"

#: Agent-started call: seconds to wait for the app before the greeting.
_GREETING_WAIT = 15.0

#: STT backend. All but "groq" stream and deliver word-aligned transcripts,
#: which is what adaptive interruption and turn detection need:
#:   cartesia — Cartesia ink-whisper, reuses CARTESIA_API_KEY (default)
#:   deepgram — Deepgram nova-3 through LiveKit Inference (LiveKit credentials)
#:   groq     — the old batch Groq Whisper path; fallback only. Batch STT makes
#:              the SDK fall back to plain VAD interruption.
_STT_BACKEND = os.environ.get("VOICE_STT", "cartesia").lower()

#: Silence (s) after which the user counts as away. Then the agent asks once
#: whether they are still there, and hangs up after _AWAY_HANGUP_AFTER more.
_USER_AWAY_TIMEOUT = float(os.environ.get("VOICE_AWAY_TIMEOUT", "30"))
_AWAY_HANGUP_AFTER = float(os.environ.get("VOICE_AWAY_HANGUP", "20"))

#: While a task or reminder is pending, the away check waits and looks again
#: this often, instead of giving up (LiveKit sets "away" again only after the
#: user speaks, so a check that gives up never comes back).
_AWAY_POLL = 10.0

#: Hard cap on one call. Near the end the agent says goodbye and hangs up.
_MAX_CALL_SECONDS = float(os.environ.get("VOICE_MAX_CALL_SECONDS", "3600"))

#: The longest the goodbye may take before the room is deleted anyway.
_GOODBYE_TIMEOUT = 15.0

#: Keyboard sound while the agent thinks or runs tools. "0" switches it off.
_THINKING_SOUND = os.environ.get("VOICE_THINKING_SOUND", "1") not in ("0", "false", "no")


# ---------------------------------------------------------------------------
# LLM provider
# ---------------------------------------------------------------------------
# VOICE_PROVIDER picks where LLM inference runs. Time-to-first-token is what the
# user actually feels in a voice call, and measured on gpt-oss-120b Groq answers
# in ~0.2s against Together's ~1.0s — so Groq is the default. Cerebras is faster
# still on paper, but the key configured here has no quota (HTTP 402
# payment_required), so it stays opt-in. TTS is always native Cartesia.
_PROVIDER = os.environ.get("VOICE_PROVIDER", "groq").lower()

_TOGETHER_API_KEY = os.environ.get("TOGETHER_API_KEY", "")
_CEREBRAS_API_KEY = os.environ.get("CEREBRAS_API_KEY", "")

#: Default model per provider. All three are tool-capable.
_DEFAULT_MODELS = {
    "cerebras": "gpt-oss-120b",
    "groq": "openai/gpt-oss-120b",
    "together": "openai/gpt-oss-120b",
}

#: The conversation LLM is picked for speed and is text-only, so vision runs on
#: a dedicated multimodal model (Groq, always — it is the cheapest fast option
#: and we already hold the key for STT).
_VISION_MODEL = os.environ.get("VISION_MODEL", "meta-llama/llama-4-scout-17b-16e-instruct")

#: Continuous video narration costs one vision call every few seconds while the
#: camera is on. Off switches back to look-on-demand only.
_NARRATION_ENABLED = os.environ.get("VISION_NARRATION", "1") not in ("0", "false", "no")


def _build_llm(model: str) -> Any:
    """Construct the LLM client for the configured provider."""
    if _PROVIDER == "cerebras":
        return openai.LLM.with_cerebras(model=model, api_key=_CEREBRAS_API_KEY)
    if _PROVIDER == "together":
        return openai.LLM.with_together(model=model, api_key=_TOGETHER_API_KEY)
    return groq.LLM(model=model)


def _build_stt(stt_language: str | None) -> Any:
    """Construct the STT for the configured backend (``VOICE_STT``)."""
    if _STT_BACKEND == "deepgram":
        return inference.STT("deepgram/nova-3", language=stt_language or "de")
    if _STT_BACKEND == "groq":
        # The old batch path. No streaming, no aligned transcript: adaptive
        # interruption falls back to VAD. Keep it only as a fallback.
        if _PROVIDER == "together":
            return openai.STT(
                model="openai/whisper-large-v3",
                base_url="https://api.together.xyz/v1",
                api_key=_TOGETHER_API_KEY,
                detect_language=not stt_language,
                language=stt_language or "en",
            )
        if stt_language:
            return groq.STT(model="whisper-large-v3-turbo", language=stt_language)
        return groq.STT(model="whisper-large-v3-turbo", detect_language=True)
    if _STT_BACKEND != "cartesia":
        logger.warning("unknown VOICE_STT=%r — using cartesia", _STT_BACKEND)
    return cartesia.STT(model="ink-whisper", language=stt_language or "de")


# The system prompt is built per call from the dispatch metadata, see
# call_config.build_instructions (mode, chat context, delegation, language).

#: Appended to an assistant message that got cut off mid-sentence. The chat
#: context already holds only the words that reached the speaker (LiveKit trims
#: it against the TTS-aligned playout position), but `ChatMessage.interrupted`
#: is framework metadata the LLM never sees — so we make the cut visible in the
#: text itself.
_INTERRUPTED_MARKER = "…"


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

def _setup_process(proc: agents.JobProcess) -> None:
    """Load the heavy models once per worker process, not once per call.

    Silero VAD and the multilingual turn detector both cost hundreds of ms to
    initialise; doing it here means the first turn of a call is as fast as the
    tenth.
    """
    proc.userdata["vad"] = silero.VAD.load()

    # Two turn detector variants:
    #
    #   inference (default) — LiveKit's Turn Detector; the SDK picks the model
    #     version (v1 on LiveKit Cloud and in dev mode).
    #   local — pinned to the small "v1-mini" model. It replaces the old
    #     turn-detector plugin (MultilingualModel), which 2.0 removes.
    if os.environ.get("TURN_DETECTOR", "inference").lower() == "local":
        proc.userdata["turn_detector"] = inference.TurnDetector(version="v1-mini")
    else:
        proc.userdata["turn_detector"] = inference.TurnDetector()


# Use a non-default worker health port to avoid conflicts with other
# local agent workers (LiveKit default 8081, new-voicemode 8083).
server = agents.AgentServer(port=HEALTH_PORT, setup_fnc=_setup_process)


class VisionAgent(Agent):
    """Agent that can both look and watch.

    Two complementary paths, because they answer different questions:

    * **Look** — the latest frame is attached to each user message, so "what is
      this?" gets full-resolution detail exactly when asked. ``room_io.RoomOptions
      (video_input=True)`` subscribes the track, but a text-LLM pipeline does
      not auto-inject frames, so we do it here.
    * **Watch** — a :class:`VideoNarrator` samples the same track continuously
      and keeps a rolling description in the context. That is what lets the
      agent notice things it was never asked about, at a fixed context cost.
    """

    def __init__(
        self,
        room: rtc.Room,
        vision_llm: Any,
        *,
        greeting: str | None = None,
        app_identity: str | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self._room = room
        #: Set for agent-started calls: the first reply, spoken in on_enter.
        self._greeting = greeting
        self._app_identity = app_identity
        self._latest_frame: rtc.VideoFrame | None = None
        self._video_tasks: dict[str, asyncio.Task[None]] = {}
        self._narrator = VideoNarrator(vision_llm=vision_llm, chat_ctx=self.chat_ctx)

        for participant in room.remote_participants.values():
            for pub in participant.track_publications.values():
                self._maybe_watch(pub)

        room.on("track_subscribed", self._on_track_subscribed)
        room.on("track_unsubscribed", self._on_track_unsubscribed)

    def _on_track_subscribed(
        self,
        track: rtc.Track,
        publication: rtc.TrackPublication,
        participant: rtc.RemoteParticipant,
    ) -> None:
        if track.kind == rtc.TrackKind.KIND_VIDEO:
            self._start_reader(track, publication.sid)

    def _on_track_unsubscribed(
        self,
        track: rtc.Track,
        publication: rtc.TrackPublication,
        participant: rtc.RemoteParticipant,
    ) -> None:
        if track.kind != rtc.TrackKind.KIND_VIDEO:
            return
        task = self._video_tasks.pop(publication.sid, None)
        if task is not None:
            task.cancel()
        self._latest_frame = None
        # Camera off means the narration is stale; drop it so the agent stops
        # answering about a scene it can no longer see.
        self._narrator.detach()

    def _maybe_watch(self, pub: rtc.TrackPublication) -> None:
        if pub.kind == rtc.TrackKind.KIND_VIDEO and pub.track is not None:
            self._start_reader(pub.track, pub.sid)

    def _start_reader(self, track: rtc.Track, sid: str) -> None:
        if sid in self._video_tasks:
            return

        async def _read() -> None:
            stream = rtc.VideoStream(track)
            try:
                async for event in stream:
                    self._latest_frame = event.frame
            finally:
                await stream.aclose()

        self._video_tasks[sid] = asyncio.create_task(_read(), name=f"video-{sid}")
        if _NARRATION_ENABLED:
            self._narrator.attach(track)

    async def on_enter(self) -> None:
        """Agent-started call: speak first, once the app is in the room.

        Waits up to ``_GREETING_WAIT`` s for the app participant, else the
        greeting plays to nobody. After the timeout it greets anyway. The
        end_call tool is hidden here (``ignore_on_enter``), and tool_choice
        "none" keeps the greeting free of tool calls.
        """
        if self._greeting is None:
            return
        try:
            await asyncio.wait_for(
                get_job_context().wait_for_participant(identity=self._app_identity),
                timeout=_GREETING_WAIT,
            )
        except TimeoutError:
            logger.warning("app did not join within %.0fs — greeting anyway", _GREETING_WAIT)
        self.session.generate_reply(instructions=self._greeting, tool_choice="none")

    async def on_user_turn_completed(
        self, turn_ctx: ChatContext, new_message: ChatMessage
    ) -> None:
        frame = self._latest_frame
        if frame is None:
            return
        # Core auto-encodes the VideoFrame to a base64 JPEG image_url for the
        # Groq/OpenAI format; inference_width/height downscale before sending.
        new_message.content.append(
            ImageContent(
                image=frame,
                inference_width=1024,
                inference_height=1024,
            )
        )

    async def aclose(self) -> None:
        for task in self._video_tasks.values():
            task.cancel()
        self._video_tasks.clear()
        await self._narrator.aclose()


@server.rtc_session(agent_name=AGENT_NAME)
async def chuk_voice(ctx: agents.JobContext):
    # ---- Parse metadata from the app ----------------------------------------
    # Unknown keys are ignored, missing or malformed keys get defaults.
    cfg = call_config.parse_metadata(ctx.job.metadata)
    stt_language = cfg.stt_language
    voice_id = cfg.voice_id or _DEFAULT_VOICE_ID
    llm_model = cfg.llm_model or _DEFAULT_MODELS.get(_PROVIDER, _DEFAULT_MODELS["groq"])
    user_id = cfg.user_id

    logger.info(
        "New session — room=%s provider=%s mode=%s delegate=%s initiated_by=%s",
        ctx.room.name,
        _PROVIDER,
        cfg.mode,
        cfg.delegate_available,
        cfg.initiated_by,
    )

    ui = UiBridge(ctx.room, preferred_identity=cfg.app_identity)

    # ---- Remembered facts ------------------------------------------------------
    # Only the facts from the remember tool carry over. The old transcript is
    # NOT resumed: in chuk_chat every call belongs to one chat (or agent), and
    # the app sends that chat's recent messages as `context`. Resuming the
    # transcript of an unrelated earlier call would mix two conversations.
    memory = conversation_memory.load_for(user_id)

    # ---- STT ----------------------------------------------------------------
    stt = _build_stt(stt_language)

    # ---- TTS ----------------------------------------------------------------
    tts = cartesia.TTS(model="sonic-3", voice=voice_id)

    # ---- LLM ----------------------------------------------------------------
    llm = _build_llm(llm_model)
    # Open the HTTP/2 connection now so the first token isn't paying for a TLS
    # handshake on top of inference (agents 1.6.7+).
    llm.prewarm()

    # A separate multimodal model for the live video narrator: the main LLM is
    # picked for speed and is text-only, and narration runs on its own cadence.
    vision_llm = groq.LLM(model=_VISION_MODEL)

    agent = VisionAgent(
        room=ctx.room,
        instructions=call_config.build_instructions(cfg, memory.preamble()),
        tools=agent_tools.build_tools(
            mode=cfg.mode, delegate_available=cfg.delegate_available
        ),
        vision_llm=vision_llm,
        greeting=call_config.greeting_instructions(cfg) if cfg.agent_started else None,
        app_identity=cfg.app_identity if cfg.user_id != "default" else None,
    )

    session = AgentSession(
        stt=stt,
        llm=llm,
        tts=tts,
        vad=ctx.proc.userdata["vad"],
        tts_text_transforms=["filter_markdown", "filter_emoji"],
        # Cartesia emits word-level timestamps, so the transcript can be aligned
        # to actual audio playout. That is what makes an interrupted message get
        # trimmed at the word the user cut in on, instead of somewhere near it.
        use_tts_aligned_transcript=True,
        # A tool round-trip is cheap now that tools are server-side, so allow a
        # deeper chain (search → read page → answer) before forcing a reply.
        max_tool_steps=8,
        # LiveKit's default is 15 s; the away flow below is tuned for this.
        user_away_timeout=_USER_AWAY_TIMEOUT,
        turn_handling=TurnHandlingOptions(
            turn_detection=ctx.proc.userdata["turn_detector"],
            # "dynamic" adapts the endpointing delay to the user's actual pause
            # pattern instead of a fixed guess; min_delay below the 0.5 default
            # because the turn detector already guards against cutting people off.
            endpointing=EndpointingOptions(mode="dynamic", min_delay=0.3, max_delay=2.5),
            # Adaptive interruption tells a real interruption apart from an
            # "mhm" backchannel, so the agent isn't derailed by acknowledgements.
            # Needs a streaming STT with aligned transcripts (see _build_stt);
            # with batch STT the SDK silently falls back to plain VAD.
            # resume_false_interruption: a cough or a short noise pauses the
            # agent, and the agent resumes where it stopped.
            interruption=InterruptionOptions(
                mode="adaptive",
                min_duration=0.4,
                resume_false_interruption=True,
            ),
            # Start the LLM on the partial transcript, and TTS with it. Costs
            # some wasted tokens on cancelled turns, buys a big latency drop —
            # exactly the trade we want here.
            preemptive_generation=PreemptiveGenerationOptions(
                enabled=True,
                preemptive_tts=True,
            ),
        ),
    )

    # Tools need the session to hand work off and speak up on their own, so the
    # runner can only be built once the session exists.
    runner = BackgroundRunner(session)
    tasks = delegation.TaskBook()
    logger.info(
        "STT backend=%s language=%s, adaptive interruption requested", _STT_BACKEND, stt_language
    )
    session.userdata = SessionData(ui=ui, memory=memory, runner=runner, tasks=tasks)

    # No transcript persistence and no post-call compaction: the chat in the
    # app is the record of the call (it is built from the transcription
    # streams). Facts are saved by the remember tool itself.
    async def _shutdown() -> None:
        await runner.aclose()
        await agent.aclose()

    ctx.add_shutdown_callback(_shutdown)

    # ---- Make interruptions visible to the model ----------------------------
    # LiveKit already trims an interrupted assistant message down to the words
    # that actually played, and flags it with `interrupted=True`. That flag is
    # framework-internal though: no provider format serialises it, so the model
    # would read the truncated text as a complete thought and assume the user
    # heard all of it. Marking the text itself closes that gap — the model can
    # see it was cut off and pick up from there, which is what makes the
    # back-and-forth feel human instead of stateless.
    #
    # Done here rather than in `on_user_turn_completed` on purpose: mutating the
    # per-turn context in that hook invalidates preemptive generation (the
    # framework compares the pre- and post-hook contexts), which would cost the
    # latency win. This mutates the message once, at creation.
    @session.on("conversation_item_added")
    def _on_item_added(ev: Any) -> None:
        item = ev.item
        if getattr(item, "role", None) != "assistant" or not getattr(item, "interrupted", False):
            return
        content = getattr(item, "content", None)
        if not content or not isinstance(content[-1], str):
            return
        text = content[-1].rstrip()
        if text and not text.endswith(_INTERRUPTED_MARKER):
            content[-1] = f"{text}{_INTERRUPTED_MARKER}"

    # ---- Mirror tool lifecycle to the app -----------------------------------
    # The event handler is sync, so each publish is fired as a task. Keep a
    # strong reference until it settles or the GC can cancel it mid-flight.
    pending_pushes: set[asyncio.Task[None]] = set()

    def _push(coro: Any) -> None:
        task = asyncio.create_task(coro)
        pending_pushes.add(task)
        task.add_done_callback(pending_pushes.discard)

    @session.on("tool_execution_updated")
    def _on_tool_update(ev: ToolExecutionUpdatedEvent) -> None:
        update = ev.update
        kind = update.type

        if kind == "tool_call_started":
            call = update.function_call
            args: dict[str, Any] = {}
            try:
                args = json.loads(call.arguments or "{}")
            except json.JSONDecodeError:
                pass
            payload = dict(
                call_id=call.call_id,
                name=call.name,
                status="running",
                message=", ".join(f"{k}: {v}" for k, v in args.items())[:160] or None,
            )
        elif kind == "tool_call_updated":
            payload = dict(
                call_id=update.call_id,
                name="",
                status="running",
                message=update.message,
            )
        elif kind == "tool_call_ended":
            payload = dict(
                call_id=update.call_id,
                name="",
                status=update.status,
                message=update.message,
            )
        else:  # tool_reply_updated — internal scheduling, not user-visible
            return

        _push(ui.tool_status(**payload))

    await session.start(
        room=ctx.room,
        agent=agent,
        room_options=room_io.RoomOptions(
            video_input=True,
            audio_input=room_io.AudioInputOptions(
                # Runs ahead of VAD, STT and turn detection, so one filter
                # improves every downstream signal at once. BVC also strips
                # competing voices, which is what stops a TV in the background
                # from taking a turn. Included on LiveKit Cloud; requires a
                # Cloud connection.
                noise_cancellation=noise_cancellation.BVC(),
            ),
        ),
    )

    # ---- Thinking sound -------------------------------------------------------
    # Soft keyboard typing while the agent thinks or a tool runs, so a slow
    # tool never sounds like a dropped call. Language-neutral, unlike a spoken
    # filler. Published as its own audio track.
    if _THINKING_SOUND:
        background_audio = BackgroundAudioPlayer(
            thinking_sound=[AudioConfig(BuiltinAudioClip.KEYBOARD_TYPING, volume=0.6)],
        )
        await background_audio.start(room=ctx.room, agent_session=session)

        async def _close_background_audio() -> None:
            await background_audio.aclose()

        ctx.add_shutdown_callback(_close_background_audio)

    # ---- Hang up (away, call-length cap) ---------------------------------------
    # Say a goodbye, wait for it (bounded), then delete the room. Deleting the
    # room disconnects the app, which then saves the transcript.
    hanging_up = False

    async def _delete_room() -> None:
        await ctx.delete_room()

    async def _hang_up(reason: str, goodbye: str) -> None:
        nonlocal hanging_up
        if hanging_up:
            return
        hanging_up = True
        logger.info("ending the call: %s", reason)
        try:
            handle = session.generate_reply(
                instructions=goodbye, tool_choice="none", allow_interruptions=False
            )
            await asyncio.wait_for(handle.wait_for_playout(), timeout=_GOODBYE_TIMEOUT)
        except Exception as e:  # noqa: BLE001 — hang up even if the goodbye fails
            logger.debug("goodbye not played: %s", e)
        ctx.add_shutdown_callback(_delete_room)
        ctx.shutdown(reason=reason)

    # ---- User away: ask once, then hang up --------------------------------------
    # The session marks the user "away" after _USER_AWAY_TIMEOUT s of silence
    # on both sides. Then ask once whether they are still there; after
    # _AWAY_HANGUP_AFTER more seconds of silence say goodbye and end the call.
    # While a task or reminder is pending, wait and look again every
    # _AWAY_POLL s: the user may just wait for its result. Each result
    # announcement calls session.reset_away_timer() (background.py), which
    # moves the user back to "listening" and cancels this check; a new silence
    # starts a fresh one.
    away_task: asyncio.Task[None] | None = None

    async def _away_check() -> None:
        try:
            while tasks.pending or runner.pending:
                await asyncio.sleep(_AWAY_POLL)
            await session.generate_reply(
                instructions=call_config.still_there_instructions(cfg), tool_choice="none"
            )
            await asyncio.sleep(_AWAY_HANGUP_AFTER)
            if session.user_state != "away":
                return
            if tasks.pending or runner.pending:
                # A task started in the meantime: begin again.
                away_task_restart()
                return
            await _hang_up("user away", call_config.away_goodbye_instructions(cfg))
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 — the session may close under us
            logger.debug("away check stopped: %s", e)

    def away_task_restart() -> None:
        nonlocal away_task
        away_task = asyncio.create_task(_away_check(), name="away-check")

    @session.on("user_state_changed")
    def _on_user_state(ev: UserStateChangedEvent) -> None:
        if ev.new_state == "away":
            if away_task is None or away_task.done():
                away_task_restart()
        elif away_task is not None and not away_task.done():
            away_task.cancel()

    # ---- Call-length cap -------------------------------------------------------
    async def _call_limit() -> None:
        await asyncio.sleep(max(0.0, _MAX_CALL_SECONDS))
        await _hang_up("call length limit", call_config.call_limit_goodbye_instructions(cfg))

    call_limit_task = asyncio.create_task(_call_limit(), name="call-limit")

    async def _cancel_call_limit() -> None:
        call_limit_task.cancel()

    ctx.add_shutdown_callback(_cancel_call_limit)

    # ---- RPC: result of a delegated task -------------------------------------
    # The app calls this when a task from delegate_task is done. Answer at
    # once; the announcement waits for a quiet moment on its own.
    @ctx.room.local_participant.register_rpc_method(delegation.TASK_RESULT_METHOD)
    async def handle_task_result(data: rtc.RpcInvocationData) -> str:
        try:
            result = delegation.parse_task_result(data.payload)
        except ValueError as e:
            logger.warning("bad %s payload from %s: %s", delegation.TASK_RESULT_METHOD, data.caller_identity, e)
            return json.dumps({"ok": False, "error": str(e)})

        task = tasks.resolve(result.task_id, result.status, result.result)
        if not task.known:
            logger.warning("result for unknown task_id %s — announcing anyway", result.task_id)
        else:
            logger.info("task %s %s", task.task_id, task.status)
        runner.speak_soon(delegation.announcement_for(task))
        return json.dumps({"ok": True})

    # ---- RPC: mid-call voice / model switching ------------------------------
    @ctx.room.local_participant.register_rpc_method("change_voice")
    async def handle_change_voice(data: rtc.RpcInvocationData) -> str:
        payload = json.loads(data.payload)
        new_voice_id = payload.get("voice_id")
        if not new_voice_id:
            return json.dumps({"status": "error", "message": "No voice_id provided"})
        # update_options swaps the live pipeline properly (agents 1.6.6+);
        # assigning session._tts used to leave the running stream on the old voice.
        agent.update_options(tts=cartesia.TTS(model="sonic-3", voice=new_voice_id))
        return json.dumps({"status": "ok", "voice_id": new_voice_id})

    @ctx.room.local_participant.register_rpc_method("change_model")
    async def handle_change_model(data: rtc.RpcInvocationData) -> str:
        payload = json.loads(data.payload)
        new_model = payload.get("model")
        if not new_model:
            return json.dumps({"status": "error", "message": "No model provided"})
        new_llm = _build_llm(new_model)
        new_llm.prewarm()
        agent.update_options(llm=new_llm)
        return json.dumps({"status": "ok", "model": new_model})


if __name__ == "__main__":
    agents.cli.run_app(server)
