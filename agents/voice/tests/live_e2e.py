"""Live end-to-end test of the chuk-voice worker. The script acts as the app.

Run from agents/voice:

    uv run python tests/live_e2e.py

The worker must already run (``./run.sh dev``) and register as
``chuk-voice``. This script does not start or stop it.

What the script does:

1. It gets a token from the token server of the app (``VOICE_TOKEN_URL`` in
   the repository ``.env``). The request body is the same as the body that
   ``lib/voice/voice_protocol.dart`` sends.
2. It joins the room as ``chuk-e2e-test`` and registers the app RPCs:
   ``chuk.delegate``, ``open_link`` and ``get_location``. Four seconds after
   the first delegate call, it sends ``chuk.task_result`` to the agent.
3. It reads the ``lk.transcription`` text streams and the ``ui.card`` and
   ``ui.tool`` data packets.
4. It publishes a microphone track. Cartesia TTS makes the speech. The WAV
   cache is in ``_scratch/e2e_audio`` (gitignored), so a rerun costs no TTS.
5. It measures the latency from the last speech frame to the first agent
   transcript segment, per turn.
6. It stops after 150 s at most, always disconnects, and prints a PASS/FAIL
   table. It also prints the new error and warning lines of
   ``_scratch/voice_worker.log``.

The script never prints a secret: not the token URL, not the token, not an
API key.

This file is not a pytest test (the name does not start with ``test_``).
It costs real TTS, STT and LLM money. Keep runs few.
"""

from __future__ import annotations

import array
import asyncio
import hashlib
import json
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import httpx
from dotenv import dotenv_values
from livekit import api, rtc

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parents[3]
APP_ENV = REPO / ".env"
VOICEMODE_ENV = Path("/home/user/git/new-voicemode/server/.env.local")
WORKER_LOG = REPO / "_scratch" / "voice_worker.log"
AUDIO_DIR = REPO / "_scratch" / "e2e_audio"

AGENT_NAME = "chuk-voice"
USER_ID = "e2e-test"
IDENTITY = f"chuk-{USER_ID}"
METADATA = {
    "user_id": USER_ID,
    "mode": "agents",
    "agent_name": "Testy",
    "chat_title": "E2E",
    "context": "User: hi\nAssistant: hello",
    "stt_language": "en",
    "delegate_available": True,
    "initiated_by": "user",
}
TASK_RESULT = {
    "task_id": "t1",
    "status": "done",
    "result": "The invoice for ACME was sent. Total 420 euros.",
}
TASK_RESULT_DELAY = 4.0

HARD_TIMEOUT = 150.0
SAMPLE_RATE = 48000
FRAME_MS = 20
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000
FRAME_BYTES = FRAME_SAMPLES * 2
SILENCE = bytes(FRAME_BYTES)

UTTER_HELLO = "Hi, can you hear me?"
UTTER_INVOICE = "Please send the invoice to ACME for me."
UTTER_NUDGE = "Yes, please hand that off now. All the details are in the system."
UTTER_BYE = "Thanks, bye!"

# A Cartesia voice for the test user. The worker's default voice is the
# fallback when this one does not exist on the account.
USER_VOICES = ["a0e99841-438c-4a64-b679-ae501e7d6091", "a57ad970-c054-4229-90e1-5e9620838b07"]
CARTESIA_URL = "https://api.cartesia.ai/tts/bytes"
CARTESIA_VERSION = "2025-04-16"

RESULT_RE = re.compile(r"420|four hundred|acme", re.IGNORECASE)

T0 = time.monotonic()


def now() -> float:
    return time.monotonic() - T0


def log(msg: str) -> None:
    print(f"[{now():7.2f}s] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Secrets (read, never print)
# ---------------------------------------------------------------------------


def read_secret(path: Path, key: str) -> str:
    value = (dotenv_values(path).get(key) or "").strip()
    if not value:
        raise SystemExit(f"{key} is missing in {path}")
    return value


# ---------------------------------------------------------------------------
# Speech synthesis (Cartesia, cached)
# ---------------------------------------------------------------------------


def trim_silence(pcm: bytes, threshold: int = 400) -> bytes:
    """Cut the quiet start and end, so the last frame is real speech.

    Keep 150 ms before the first loud sample (soft onsets such as "h") and
    30 ms after the last one.
    """
    samples = array.array("h")
    samples.frombytes(pcm)
    loud = [i for i in range(0, len(samples), 48) if abs(samples[i]) > threshold]
    if not loud:
        return pcm
    first = max(0, loud[0] - SAMPLE_RATE * 150 // 1000)
    last = min(len(samples), loud[-1] + SAMPLE_RATE * 30 // 1000)
    return samples[first:last].tobytes()


async def synthesize(client: httpx.AsyncClient, api_key: str, text: str) -> bytes:
    """Return 48 kHz mono s16le PCM for ``text``. Uses the cache when it can."""
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    for voice in USER_VOICES:
        digest = hashlib.sha1(f"{voice}|{text}".encode()).hexdigest()[:16]
        cached = AUDIO_DIR / f"{digest}.raw.pcm"
        if cached.exists():
            return trim_silence(cached.read_bytes())
        body = {
            "model_id": "sonic-3",
            "transcript": text,
            "voice": {"mode": "id", "id": voice},
            "output_format": {
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": SAMPLE_RATE,
            },
            "language": "en",
        }
        headers = {"X-API-Key": api_key, "Cartesia-Version": CARTESIA_VERSION}
        resp = await client.post(CARTESIA_URL, json=body, headers=headers, timeout=30)
        if resp.status_code != 200:
            log(f"TTS: voice {voice[:8]} gave HTTP {resp.status_code}, next voice")
            continue
        cached.write_bytes(resp.content)
        pcm = trim_silence(resp.content)
        # A WAV copy for a human who wants to listen.
        write_wav(AUDIO_DIR / f"{digest}.wav", pcm)
        return pcm
    raise SystemExit(f"TTS failed for {text!r}")


def write_wav(path: Path, pcm: bytes) -> None:
    import wave

    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)


# ---------------------------------------------------------------------------
# Microphone: real-time pump, silence between utterances
# ---------------------------------------------------------------------------


class Mic:
    def __init__(self, source: rtc.AudioSource) -> None:
        self._source = source
        self._frames: list[bytes] = []
        self._done: asyncio.Future[float] | None = None
        self._stop = False

    def stop(self) -> None:
        self._stop = True

    async def run(self) -> None:
        start = time.monotonic()
        n = 0
        while not self._stop:
            n += 1
            delay = start + n * FRAME_MS / 1000 - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            elif delay < -0.25:  # the loop stalled: start a new schedule
                start, n = time.monotonic(), 0
            data = self._frames.pop(0) if self._frames else SILENCE
            last = data is not SILENCE and not self._frames
            await self._source.capture_frame(
                rtc.AudioFrame(data, SAMPLE_RATE, 1, FRAME_SAMPLES)
            )
            if last and self._done is not None and not self._done.done():
                self._done.set_result(now())

    async def say(self, pcm: bytes, label: str) -> float:
        """Send one utterance. Return the time of the last speech frame."""
        frames = [pcm[i : i + FRAME_BYTES] for i in range(0, len(pcm), FRAME_BYTES)]
        if len(frames[-1]) < FRAME_BYTES:
            frames[-1] = frames[-1] + bytes(FRAME_BYTES - len(frames[-1]))
        self._done = asyncio.get_running_loop().create_future()
        log(f"USER SAYS  {label!r} ({len(pcm) / 2 / SAMPLE_RATE:.2f} s)")
        self._frames.extend(frames)
        end = await self._done
        log(f"user speech end (last frame sent) for {label!r}")
        return end


# ---------------------------------------------------------------------------
# Observed state
# ---------------------------------------------------------------------------


@dataclass
class Segment:
    who: str
    first_t: float
    text: str = ""
    end_t: float | None = None


@dataclass
class State:
    room: rtc.Room
    agent_identity: str | None = None
    agent_joined_t: float | None = None
    agent_state: str = ""
    agent_subscribed_t: float | None = None
    mic_sid: str = ""
    agent_segments: list[Segment] = field(default_factory=list)
    user_finals: list[tuple[float, str]] = field(default_factory=list)
    open_agent_streams: int = 0
    delegate_calls: list[tuple[float, str]] = field(default_factory=list)
    task_result_sent_t: float | None = None
    task_result_answer: str | None = None
    result_segment: Segment | None = None
    device_rpcs: list[str] = field(default_factory=list)
    cards: list[str] = field(default_factory=list)
    tools: list[str] = field(default_factory=list)
    agent_left_t: float | None = None
    disconnected_t: float | None = None
    disconnect_reason: str = ""
    background: set[asyncio.Task] = field(default_factory=set)
    mic: Mic | None = None

    def spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self.background.add(task)
        task.add_done_callback(self.background.discard)

    def first_agent_segment_after(self, t: float) -> Segment | None:
        for seg in self.agent_segments:
            if seg.first_t > t:
                return seg
        return None


def decode_chunk(chunk: str) -> str:
    """Plain text, or the text of JSON TimedString lines (json_format)."""
    s = chunk.strip()
    if s.startswith("{") and '"text"' in s:
        out = []
        for line in chunk.splitlines():
            try:
                out.append(json.loads(line).get("text", ""))
            except (json.JSONDecodeError, AttributeError):
                out.append(line)
        return "".join(out)
    return chunk


def install_handlers(st: State) -> None:
    room = st.room

    def is_agent(p: rtc.RemoteParticipant) -> bool:
        return p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT or p.identity.startswith(
            "agent-"
        )

    def note_agent(p: rtc.RemoteParticipant) -> None:
        if st.agent_identity is None and is_agent(p):
            st.agent_identity = p.identity
            st.agent_joined_t = now()
            log(f"agent joined: {p.identity}")
            state = p.attributes.get("lk.agent.state")
            if state:
                st.agent_state = state

    @room.on("participant_connected")
    def _on_join(p: rtc.RemoteParticipant) -> None:
        note_agent(p)

    @room.on("participant_disconnected")
    def _on_leave(p: rtc.RemoteParticipant) -> None:
        if p.identity == st.agent_identity:
            st.agent_left_t = now()
            log(f"agent left: {p.identity}")

    @room.on("participant_attributes_changed")
    def _on_attrs(changed: dict, p: rtc.Participant) -> None:
        if p.identity == st.agent_identity and "lk.agent.state" in changed:
            st.agent_state = changed["lk.agent.state"]
            log(f"agent state -> {st.agent_state}")

    @room.on("local_track_subscribed")
    def _on_local_sub(track: rtc.Track) -> None:
        if st.agent_subscribed_t is None:
            st.agent_subscribed_t = now()
            log("agent subscribed to the mic track")

    @room.on("disconnected")
    def _on_disconnected(reason) -> None:
        st.disconnected_t = now()
        try:
            st.disconnect_reason = rtc.DisconnectReason.Name(reason)
        except Exception:  # noqa: BLE001
            st.disconnect_reason = str(reason)
        log(f"room disconnected: {st.disconnect_reason}")

    @room.on("data_received")
    def _on_data(pkt: rtc.DataPacket) -> None:
        if pkt.topic not in ("ui.card", "ui.tool"):
            return
        try:
            body = json.loads(pkt.data.decode("utf-8"))
        except Exception:  # noqa: BLE001
            log(f"{pkt.topic}: undecodable packet")
            return
        if pkt.topic == "ui.card":
            line = f"kind={body.get('kind')} title={body.get('title')!r}"
            st.cards.append(line)
        else:
            line = (
                f"name={body.get('name')!r} status={body.get('status')} "
                f"msg={(body.get('message') or '')[:80]!r}"
            )
            st.tools.append(line)
        log(f"{pkt.topic}: {line}")

    async def consume(reader: rtc.TextStreamReader, identity: str) -> None:
        attrs = reader.info.attributes
        track = attrs.get("lk.transcribed_track_id", "")
        user = identity == IDENTITY or (st.mic_sid and track == st.mic_sid)
        if user:
            text = decode_chunk(await reader.read_all())
            if attrs.get("lk.transcription_final") == "true" and text.strip():
                st.user_finals.append((now(), text.strip()))
                log(f"TRANSCRIPT user : {text.strip()!r}")
            return
        seg: Segment | None = None
        st.open_agent_streams += 1
        try:
            async for chunk in reader:
                if seg is None:
                    seg = Segment(who="agent", first_t=now())
                    st.agent_segments.append(seg)
                seg.text += decode_chunk(chunk)
                if (
                    st.result_segment is None
                    and st.task_result_sent_t is not None
                    and seg.first_t > st.task_result_sent_t
                    and RESULT_RE.search(seg.text)
                ):
                    st.result_segment = seg
        except Exception as e:  # noqa: BLE001 — a stream can end with the room
            log(f"agent stream error: {type(e).__name__}")
        finally:
            st.open_agent_streams -= 1
        if seg is not None:
            seg.end_t = now()
            log(
                f"TRANSCRIPT agent: {seg.text.strip()!r} "
                f"(first chunk +{seg.first_t:.2f}s, end +{seg.end_t:.2f}s)"
            )

    def on_stream(reader: rtc.TextStreamReader, identity: str) -> None:
        st.spawn(consume(reader, identity))

    room.register_text_stream_handler("lk.transcription", on_stream)


def install_rpcs(st: State) -> None:
    lp = st.room.local_participant

    async def send_result() -> None:
        await asyncio.sleep(TASK_RESULT_DELAY)
        if not st.agent_identity:
            log("task_result: no agent in the room")
            return
        st.task_result_sent_t = now()
        log("RPC -> chuk.task_result t1 (done)")
        try:
            st.task_result_answer = await lp.perform_rpc(
                destination_identity=st.agent_identity,
                method="chuk.task_result",
                payload=json.dumps(TASK_RESULT),
                response_timeout=10,
            )
        except Exception as e:  # noqa: BLE001
            st.task_result_answer = f"ERROR {type(e).__name__}: {e}"
        log(f"chuk.task_result answer: {st.task_result_answer}")

    @lp.register_rpc_method("chuk.delegate")
    async def _delegate(data: rtc.RpcInvocationData) -> str:
        try:
            task = json.loads(data.payload).get("task", "")
        except (json.JSONDecodeError, AttributeError):
            task = data.payload
        st.delegate_calls.append((now(), task))
        n = len(st.delegate_calls)
        task_id = f"t{n}"
        log(f"RPC <- chuk.delegate from {data.caller_identity}: {task!r} -> {task_id}")
        if n == 1:
            st.spawn(send_result())
        return json.dumps({"task_id": task_id, "status": "started"})

    @lp.register_rpc_method("open_link")
    async def _open_link(data: rtc.RpcInvocationData) -> str:
        st.device_rpcs.append(f"open_link {data.payload[:120]}")
        log(f"RPC <- open_link {data.payload[:120]}")
        return json.dumps({"ok": True})

    @lp.register_rpc_method("get_location")
    async def _get_location(data: rtc.RpcInvocationData) -> str:
        st.device_rpcs.append("get_location")
        log("RPC <- get_location -> permission denied")
        return json.dumps({"error": "permission denied"})


# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------


async def wait_until(pred, timeout: float, step: float = 0.05) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        await asyncio.sleep(step)
    return pred()


async def wait_reply(st: State, after: float, timeout: float) -> Segment | None:
    await wait_until(lambda: st.first_agent_segment_after(after) is not None, timeout)
    return st.first_agent_segment_after(after)


async def wait_idle(st: State, timeout: float, quiet: float = 1.2) -> bool:
    """Wait until the agent listens and sends no transcript for ``quiet`` s."""
    end = time.monotonic() + timeout
    since: float | None = None
    while time.monotonic() < end:
        idle = st.agent_state in ("listening", "idle", "") and st.open_agent_streams == 0
        if idle:
            since = since or time.monotonic()
            if time.monotonic() - since >= quiet:
                return True
        else:
            since = None
        await asyncio.sleep(0.05)
    return False


def hung_up(st: State) -> bool:
    return st.agent_left_t is not None or st.disconnected_t is not None


# ---------------------------------------------------------------------------
# The scenario
# ---------------------------------------------------------------------------


@dataclass
class Results:
    room_name: str = ""
    token_ok: bool = False
    turns: dict[str, dict] = field(default_factory=dict)
    nudged: bool = False
    bye_end_t: float | None = None
    room_gone: bool | None = None
    notes: list[str] = field(default_factory=list)


async def scenario(st: State, res: Results, speech: dict[str, bytes]) -> None:
    room = st.room

    if not await wait_until(lambda: st.agent_identity is not None, 25):
        res.notes.append("agent did not join in 25 s")
        return
    await wait_until(lambda: st.agent_subscribed_t is not None, 10)
    await asyncio.sleep(1.0)

    async def turn(key: str, text: str, reply_timeout: float = 20) -> Segment | None:
        end = await mic.say(speech[text], text)
        seg = await wait_reply(st, end, reply_timeout)
        res.turns[key] = {
            "end": end,
            "latency": (seg.first_t - end) if seg else None,
            "seg": seg,
        }
        if seg is None:
            log(f"no agent reply for turn {key}")
        return seg

    mic = st.mic
    assert mic is not None

    # a) hello
    await turn("a", UTTER_HELLO)
    await wait_idle(st, 25)

    # b) delegate
    seg_b = await turn("b", UTTER_INVOICE)
    got_rpc = await wait_until(lambda: bool(st.delegate_calls), 15)
    if not got_rpc and room.isconnected():
        await wait_idle(st, 15)
        if not st.delegate_calls:
            log("no delegate call yet: nudge once")
            res.nudged = True
            await turn("b2", UTTER_NUDGE)
            await wait_until(lambda: bool(st.delegate_calls), 15)
    if st.delegate_calls:
        # The result goes out 4 s after the RPC; then wait for the announcement.
        await wait_until(lambda: st.task_result_sent_t is not None, TASK_RESULT_DELAY + 3)
        await wait_until(lambda: st.result_segment is not None, 35)
    _ = seg_b
    await wait_idle(st, 25)

    # c) bye
    if not room.isconnected():
        return
    end_c = await mic.say(speech[UTTER_BYE], UTTER_BYE)
    res.bye_end_t = end_c
    seg_c = await wait_reply(st, end_c, 20)
    res.turns["c"] = {
        "end": end_c,
        "latency": (seg_c.first_t - end_c) if seg_c else None,
        "seg": seg_c,
    }
    await wait_until(lambda: hung_up(st), 25)


async def check_room_gone(url: str, key: str, secret: str, name: str) -> bool | None:
    http_url = url.replace("wss://", "https://").replace("ws://", "http://")
    lk = api.LiveKitAPI(http_url, key, secret)
    try:
        rooms = await lk.room.list_rooms(api.ListRoomsRequest(names=[name]))
        return len(rooms.rooms) == 0
    except Exception as e:  # noqa: BLE001
        log(f"room check failed: {type(e).__name__}")
        return None
    finally:
        await lk.aclose()


async def delete_room(url: str, key: str, secret: str, name: str) -> None:
    http_url = url.replace("wss://", "https://").replace("ws://", "http://")
    lk = api.LiveKitAPI(http_url, key, secret)
    try:
        await lk.room.delete_room(api.DeleteRoomRequest(room=name))
    except Exception:  # noqa: BLE001 — the room is usually gone already
        pass
    finally:
        await lk.aclose()


# ---------------------------------------------------------------------------
# Worker log
# ---------------------------------------------------------------------------

ANSI = re.compile(r"\x1b\[[0-9;]*m")
SECRETISH = re.compile(
    r"(Bearer\s+\S+|\b(?:sk|gsk|csk|pk)[-_][A-Za-z0-9_\-]{8,}|eyJ[A-Za-z0-9_\-.]{20,}"
    r"|\b[A-Za-z0-9_]{32,}\b)"
)


def worker_log_issues(offset: int) -> list[str]:
    if not WORKER_LOG.exists():
        return ["(worker log not found)"]
    with WORKER_LOG.open("rb") as f:
        f.seek(offset)
        text = f.read().decode("utf-8", "replace")
    out = []
    for raw in text.splitlines():
        line = ANSI.sub("", raw)
        if re.search(r"ERROR|CRITICAL|WARNING|Traceback|Exception|error", line):
            line = SECRETISH.sub("<redacted>", line)
            tag = " [groq, ignored]" if "groq" in line.lower() else ""
            out.append(line[:300] + tag)
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def fmt_lat(v: float | None) -> str:
    return f"{v:.2f} s" if v is not None else "n/a"


def report(st: State, res: Results, log_lines: list[str]) -> bool:
    rows: list[tuple[str, bool, str]] = []

    rows.append(
        (
            "agent joined",
            st.agent_joined_t is not None,
            f"{st.agent_identity} at +{st.agent_joined_t:.2f}s" if st.agent_joined_t else "never",
        )
    )

    a = res.turns.get("a", {})
    seg_a = a.get("seg")
    rows.append(("first reply (turn a)", seg_a is not None, repr(seg_a.text.strip()[:90]) if seg_a else "none"))

    task = st.delegate_calls[0][1] if st.delegate_calls else ""
    sensible = bool(task) and "invoice" in task.lower() and "acme" in task.lower()
    first_ask = bool(st.delegate_calls) and not res.nudged
    seg_b = res.turns.get("b", {}).get("seg")
    rows.append(
        (
            "delegate on the first ask (turn b)",
            first_ask,
            "delegated at once"
            if first_ask
            else f"no RPC; reply was {seg_b.text.strip()[:70]!r}" if seg_b else "no RPC, no reply",
        )
    )
    detail = repr(task[:110]) if task else "no chuk.delegate RPC"
    if res.nudged:
        detail += " (after one nudge)"
    if len(st.delegate_calls) > 1:
        detail += f" ({len(st.delegate_calls)} calls)"
    rows.append(("delegate RPC, sensible task", sensible, detail))

    # The "I am on it" line: the first agent segment after the delegate RPC
    # that is not the result announcement.
    ack = None
    if st.delegate_calls:
        ack = st.first_agent_segment_after(st.delegate_calls[0][0])
        if ack is st.result_segment:
            ack = None
    rows.append(("ack after delegation", ack is not None, repr(ack.text.strip()[:90]) if ack else "none"))

    rs = st.result_segment
    rows.append(
        (
            "result spoken (420/ACME)",
            rs is not None,
            (
                f"{rs.text.strip()[:90]!r}, {rs.first_t - st.task_result_sent_t:.2f} s after task_result"
                if rs and st.task_result_sent_t is not None
                else f"task_result answer={st.task_result_answer}"
            ),
        )
    )

    c = res.turns.get("c", {})
    seg_c = c.get("seg")
    hang_ok = seg_c is not None and hung_up(st) and res.bye_end_t is not None
    how = []
    if st.agent_left_t is not None:
        how.append(f"agent left +{st.agent_left_t:.2f}s")
    if st.disconnected_t is not None:
        how.append(f"room disconnect {st.disconnect_reason} +{st.disconnected_t:.2f}s")
    if res.room_gone is not None:
        how.append(f"room gone={res.room_gone}")
    goodbye = repr(seg_c.text.strip()[:60]) if seg_c else "no goodbye"
    rows.append(("hang-up by intent", hang_ok, f"{goodbye}; {', '.join(how) or 'no hang-up'}"))

    lats = {k: res.turns.get(k, {}).get("latency") for k in ("a", "b", "c")}
    lat_ok = all(v is not None for v in lats.values())
    rows.append(
        (
            "latency (speech end -> 1st agent seg)",
            lat_ok,
            ", ".join(f"{k}={fmt_lat(v)}" for k, v in lats.items()),
        )
    )

    print("\n" + "=" * 100)
    print(f"{'check':<40} {'result':<6} detail")
    print("-" * 100)
    for name, ok, det in rows:
        print(f"{name:<40} {'PASS' if ok else 'FAIL':<6} {det}")
    print("-" * 100)
    if st.user_finals:
        print("STT heard:", " | ".join(t for _, t in st.user_finals))
    if st.cards:
        print("ui.card:", "; ".join(st.cards))
    if st.tools:
        print("ui.tool:", "; ".join(st.tools[:12]))
    if st.device_rpcs:
        print("device RPCs:", "; ".join(st.device_rpcs))
    if res.nudged and seg_b is not None:
        print(f"turn b reply before the nudge: {seg_b.text.strip()!r}")
    for n in res.notes:
        print("note:", n)
    print(f"\nworker log, error/warning lines during the run ({len(log_lines)}):")
    for line in log_lines[:40]:
        print("  " + line)
    print("=" * 100)
    return all(ok for _, ok, _ in rows)


async def main() -> int:
    token_url = read_secret(APP_ENV, "VOICE_TOKEN_URL")
    cartesia_key = read_secret(VOICEMODE_ENV, "CARTESIA_API_KEY")
    lk_url = read_secret(VOICEMODE_ENV, "LIVEKIT_URL")
    lk_key = read_secret(VOICEMODE_ENV, "LIVEKIT_API_KEY")
    lk_secret = read_secret(VOICEMODE_ENV, "LIVEKIT_API_SECRET")

    log_offset = WORKER_LOG.stat().st_size if WORKER_LOG.exists() else 0
    res = Results(room_name=f"chuk-voice-e2e-{uuid.uuid4().hex[:8]}")

    async with httpx.AsyncClient() as client:
        speech = {}
        for text in (UTTER_HELLO, UTTER_INVOICE, UTTER_NUDGE, UTTER_BYE):
            speech[text] = await synthesize(client, cartesia_key, text)
        log("speech ready (cached in _scratch/e2e_audio)")

        body = {
            "room_name": res.room_name,
            "participant_identity": IDENTITY,
            "participant_name": "E2E Test",
            "room_config": {
                "agents": [{"agent_name": AGENT_NAME, "metadata": json.dumps(METADATA)}]
            },
        }
        try:
            resp = await client.post(
                token_url, json=body, headers={"Content-Type": "application/json"}, timeout=12
            )
        except httpx.HTTPError as e:
            raise SystemExit(f"token server not reachable ({type(e).__name__})") from None
        if resp.status_code // 100 != 2:
            raise SystemExit(f"token server answered {resp.status_code}")
        data = resp.json()
        server_url = data.get("server_url") or data.get("serverUrl")
        token = data.get("participant_token") or data.get("participantToken")
        if not server_url or not token:
            raise SystemExit("token response lacks url or token")
        res.token_ok = True
        log(f"token ok, room {res.room_name}")

    room = rtc.Room()
    st = State(room=room)
    install_handlers(st)
    mic_task: asyncio.Task | None = None
    try:
        await room.connect(server_url, token, rtc.RoomOptions(auto_subscribe=True))
        log(f"connected as {room.local_participant.identity}")
        install_rpcs(st)
        for p in room.remote_participants.values():
            if p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT or p.identity.startswith("agent-"):
                st.agent_identity, st.agent_joined_t = p.identity, now()
                log(f"agent already in room: {p.identity}")

        source = rtc.AudioSource(SAMPLE_RATE, 1, queue_size_ms=200)
        track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
        pub = await room.local_participant.publish_track(
            track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        )
        st.mic_sid = pub.sid
        mic = Mic(source)
        st.mic = mic
        mic_task = asyncio.create_task(mic.run())
        log("mic track published")

        remaining = HARD_TIMEOUT - now()
        try:
            await asyncio.wait_for(scenario(st, res, speech), timeout=remaining)
        except asyncio.TimeoutError:
            res.notes.append(f"hard timeout ({HARD_TIMEOUT:.0f} s) reached")
            log("HARD TIMEOUT")
        # Check before we leave: after our own disconnect an empty room closes too.
        # The agent leaves first, the room delete follows, so wait for it.
        if hung_up(st):
            await wait_until(lambda: st.disconnected_t is not None, 5)
            res.room_gone = await check_room_gone(lk_url, lk_key, lk_secret, res.room_name)
    finally:
        if mic_task is not None and st.mic is not None:
            st.mic.stop()
            mic_task.cancel()
        # Let the last transcript streams close.
        await asyncio.sleep(0.5)
        try:
            await asyncio.wait_for(room.disconnect(), 5)
        except Exception:  # noqa: BLE001
            pass
        log("disconnected")

    if not res.room_gone:
        await delete_room(lk_url, lk_key, lk_secret, res.room_name)
    await asyncio.sleep(2.0)  # the worker writes its shutdown lines
    ok = report(st, res, worker_log_issues(log_offset))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
