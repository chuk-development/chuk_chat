"""chuk-voice — the voice worker for chuk_chat voice calls.

Forked from new-voicemode/server. This copy adds the chuk_chat contract:
dispatch metadata (mode, chat context, delegation), the ``delegate_task`` /
``chuk.task_result`` RPC pair, and agent-started calls. See README.md.

The worker holds NO provider keys. LLM, STT and TTS run through the chuk API
proxy (``CHUK_API_BASE``, api.chuk.chat), which bills the user's credits. Each
request carries a short-lived worker JWT and the call's voice grant
(``chuk_proxy``). A job without a voice grant does not start the pipeline.

    mic → VAD (Silero) → STT (Whisper via proxy) → LLM (via proxy, + tools)
        → TTS (Inworld via proxy)

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
import re
import uuid
from pathlib import Path
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
from livekit.plugins import noise_cancellation, openai, silero

import call_config
import chuk_proxy
import delegation
import tools as agent_tools
from background import BackgroundRunner
from tools import SessionData
from ui_bridge import UiBridge
from vision import VideoNarrator

# agents/voice/.env.local holds only LIVEKIT_URL, LIVEKIT_API_KEY,
# LIVEKIT_API_SECRET (and optionally CHUK_API_BASE). Values already in the
# environment win.
load_dotenv(Path(__file__).resolve().parent / ".env.local")

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

# ---------------------------------------------------------------------------
# Models behind the chuk API proxy (placeholders until api_server recommends)
# ---------------------------------------------------------------------------

#: The conversation LLM, sent with the extra body ``provider``. Default from
#: the 2026-10-01 RunAnywhere benchmark on the production route: deepseek
#: v4.1 flash with reasoning off had the lowest time to first token (0.72 s
#: plain, 0.76 s tool call) and 12/12 correct tool calls.
_LLM_MODEL = os.environ.get("VOICE_LLM_MODEL", "deepseek/deepseek-v4.1-flash")
_LLM_PROVIDER = os.environ.get("VOICE_LLM_PROVIDER", "runanywhere").strip()
#: "none" keeps the first token fast; empty sends no reasoning_effort.
_LLM_REASONING = os.environ.get("VOICE_LLM_REASONING", "none").strip()

#: Groq Whisper through ``POST {base}/audio/transcriptions``. Batch STT: the
#: SDK wraps it with VAD.
_STT_MODEL = os.environ.get("VOICE_STT_MODEL", "whisper-large-v3-turbo")

#: Inworld through ``POST {base}/audio/speech`` (streamed 24 kHz pcm).
_TTS_MODEL = os.environ.get("VOICE_TTS_MODEL", "inworld-tts-2-flash")
#: German voice that also speaks English (the proxy's default).
_TTS_VOICE = os.environ.get("VOICE_TTS_VOICE", "Bastian")

#: A voice id from the app is used only when it looks like an Inworld voice
#: name ("Ashley", "Dennis"). An old Cartesia UUID would break every reply.
_VOICE_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z _-]{0,39}$")

#: Seconds to wait for the app before the no-grant line is sent.
_NO_GRANT_WAIT = 10.0

#: Agent-started call: seconds to wait for the app before the greeting.
_GREETING_WAIT = 15.0

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


#: The conversation LLM is text-only. Continuous video narration runs on a
#: separate multimodal model behind the proxy. Unset: no narration.
_VISION_MODEL = os.environ.get("VOICE_VISION_MODEL", "").strip()

#: Continuous video narration costs one vision call every few seconds while the
#: camera is on (billed to the user). Off switches it off.
_NARRATION_ENABLED = bool(_VISION_MODEL) and os.environ.get("VISION_NARRATION", "1") not in (
    "0",
    "false",
    "no",
)

#: Attach the latest camera frame to each user turn. Only for a main LLM that
#: takes images; the default model is text-only, so it is off.
_LLM_IMAGES = os.environ.get("VOICE_LLM_IMAGES", "0") in ("1", "true", "yes")


def _build_llm(client: Any, model: str) -> Any:
    """The conversation LLM through the chuk proxy."""
    kwargs: dict[str, Any] = {"client": client, "model": model}
    extra: dict[str, Any] = {}
    if _LLM_PROVIDER:
        extra["provider"] = _LLM_PROVIDER
    if _LLM_REASONING:
        extra["reasoning_effort"] = _LLM_REASONING
    if extra:
        kwargs["extra_body"] = extra
    return openai.LLM(**kwargs)


def _build_stt(client: Any, language: str) -> Any:
    """Whisper through the chuk proxy (batch, OpenAI-compatible)."""
    return openai.STT(client=client, model=_STT_MODEL, language=language, use_realtime=False)


def _pick_voice(app_voice: str | None) -> str:
    """The app's voice id when it is an Inworld voice name, else the default."""
    if app_voice and _VOICE_NAME_RE.match(app_voice):
        return app_voice
    if app_voice:
        logger.info("ignoring voice_id from the app (not an Inworld voice name)")
    return _TTS_VOICE


def _build_tts(client: Any, voice: str) -> Any:
    """Inworld TTS through the chuk proxy (streamed pcm)."""
    return openai.TTS(client=client, model=_TTS_MODEL, voice=voice, response_format="pcm")


async def _refuse_without_grant(ctx: agents.JobContext, cfg: call_config.CallConfig) -> None:
    """No voice grant: send one text line and leave. No pipeline starts.

    The line goes out as a final agent transcription (text, not speech):
    every TTS call needs the grant, so the worker cannot speak here.
    """
    logger.warning("job without voice_grant — not starting the pipeline")
    try:
        await ctx.connect()
        try:
            await asyncio.wait_for(
                ctx.wait_for_participant(
                    identity=cfg.app_identity if cfg.user_id != "default" else None
                ),
                timeout=_NO_GRANT_WAIT,
            )
        except TimeoutError:
            pass
        await ctx.room.local_participant.send_text(
            call_config.no_grant_text(cfg),
            topic="lk.transcription",
            attributes={
                "lk.segment_id": f"SG_{uuid.uuid4().hex[:12]}",
                "lk.transcription_final": "true",
            },
        )
        # Give the text stream a moment to reach the app before we leave.
        await asyncio.sleep(1.0)
    except Exception as e:  # noqa: BLE001 — leave in any case
        logger.debug("no-grant notice not sent: %s", e)
    ctx.shutdown(reason="no voice grant")


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
#
# In `start` mode LiveKit marks the worker as full when CPU load is above its
# load threshold (0.7 by default) and dispatches no jobs to it. A personal
# worker on a busy desktop is always above that, so VOICE_LOAD_THRESHOLD can
# raise it ("inf" turns the check off). Unset keeps the SDK default.
_server_kwargs: dict[str, Any] = {"port": HEALTH_PORT, "setup_fnc": _setup_process}
_load_threshold = os.environ.get("VOICE_LOAD_THRESHOLD", "").strip()
if _load_threshold:
    _server_kwargs["load_threshold"] = float(_load_threshold)
server = agents.AgentServer(**_server_kwargs)


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
        self._narrator = (
            VideoNarrator(vision_llm=vision_llm, chat_ctx=self.chat_ctx)
            if vision_llm is not None
            else None
        )

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
        if self._narrator is not None:
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
        if _NARRATION_ENABLED and self._narrator is not None:
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
        if frame is None or not _LLM_IMAGES:
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
        if self._narrator is not None:
            await self._narrator.aclose()


@server.rtc_session(agent_name=AGENT_NAME)
async def chuk_voice(ctx: agents.JobContext):
    # ---- Parse metadata from the app ----------------------------------------
    # Unknown keys are ignored, missing or malformed keys get defaults.
    cfg = call_config.parse_metadata(ctx.job.metadata)
    stt_language = cfg.stt_language
    # The model is the worker's choice (VOICE_LLM_MODEL): the proxy routes and
    # bills it with the given provider. An llm_model from the app is ignored.
    llm_model = _LLM_MODEL

    logger.info(
        "New session — room=%s mode=%s delegate=%s initiated_by=%s grant=%s",
        ctx.room.name,
        cfg.mode,
        cfg.delegate_available,
        cfg.initiated_by,
        "yes" if cfg.voice_grant else "no",
    )

    # ---- No grant, no pipeline ------------------------------------------------
    if not cfg.voice_grant:
        await _refuse_without_grant(ctx, cfg)
        return

    # ---- The chuk API proxy -----------------------------------------------------
    # One client per call: worker JWT (re-minted before expiry) + this call's
    # voice grant on every request. No provider key exists on this machine.
    proxy = chuk_proxy.make_client(chuk_proxy.WorkerToken.from_env(), cfg.voice_grant)

    ui = UiBridge(ctx.room, preferred_identity=cfg.app_identity)

    stt = _build_stt(proxy, stt_language)
    tts = _build_tts(proxy, _pick_voice(cfg.voice_id))
    llm = _build_llm(proxy, llm_model)
    # Open the connection now so the first token isn't paying for a TLS
    # handshake on top of inference.
    llm.prewarm()

    # A separate multimodal model for the live video narrator (optional).
    vision_llm = _build_llm(proxy, _VISION_MODEL) if _NARRATION_ENABLED else None

    agent = VisionAgent(
        room=ctx.room,
        instructions=call_config.build_instructions(cfg),
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
        # The proxy TTS (OpenAI-compatible) returns no word timings. Aligned
        # transcripts stay off, so LiveKit paces the transcript itself and
        # does not warn on every reply.
        use_tts_aligned_transcript=False,
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
            # The STT is batch Whisper (wrapped with VAD); the detector reads
            # the audio, and where it cannot help the SDK uses plain VAD.
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
        "proxy models: llm=%s stt=%s tts=%s language=%s",
        llm_model,
        _STT_MODEL,
        _TTS_MODEL,
        stt_language,
    )
    session.userdata = SessionData(ui=ui, runner=runner, tasks=tasks, proxy=proxy)

    # No transcript persistence and no memory: the chat in the app is the
    # record of the call (it is built from the transcription streams), and
    # the host agent holds the user's memory.
    async def _shutdown() -> None:
        await runner.aclose()
        await agent.aclose()
        await proxy.close()

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
        voice = _pick_voice(str(new_voice_id))
        # update_options swaps the live pipeline properly (agents 1.6.6+).
        agent.update_options(tts=_build_tts(proxy, voice))
        return json.dumps({"status": "ok", "voice_id": voice})

    @ctx.room.local_participant.register_rpc_method("change_model")
    async def handle_change_model(data: rtc.RpcInvocationData) -> str:
        payload = json.loads(data.payload)
        new_model = payload.get("model")
        if not new_model:
            return json.dumps({"status": "error", "message": "No model provided"})
        new_llm = _build_llm(proxy, str(new_model))
        new_llm.prewarm()
        agent.update_options(llm=new_llm)
        return json.dumps({"status": "ok", "model": new_model})


if __name__ == "__main__":
    agents.cli.run_app(server)
