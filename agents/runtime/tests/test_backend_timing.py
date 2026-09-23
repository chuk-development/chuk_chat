"""The model client's two deadlines, its retry accounting and its log line.

Every test here drives a **fake clock** and a **fake socket**: nothing sleeps,
so a 180-second backstop and a 45-second first-frame budget are both asserted
in microseconds of real time.
"""

from __future__ import annotations

import json
import logging

import pytest
from websockets.exceptions import ConnectionClosed

from chuk_agents_runtime.backend import (
    DEFAULT_FIRST_FRAME_TIMEOUT,
    DEFAULT_RECV_TIMEOUT,
    BackendModelClient,
    BackendModelError,
    SupabaseSession,
)


class FakeClock:
    """A monotonic clock the test moves by hand."""

    def __init__(self, start: float = 1000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class FakeSocket:
    """One connection. ``script`` is a list of ``(delay_seconds, item)``.

    ``item`` is a frame dict, or an exception instance to raise. A ``recv``
    whose ``timeout`` expires before the scripted delay advances the clock by
    exactly the timeout and raises ``TimeoutError`` — which is what a real
    socket that says nothing does.
    """

    def __init__(self, clock: FakeClock, script: list[tuple[float, object]]) -> None:
        self._clock = clock
        self._script = list(script)
        self._index = 0
        self._req_id: str | None = None
        self.closed = False
        self.sent: list[dict] = []

    def send(self, raw: str) -> None:
        frame = json.loads(raw)
        self.sent.append(frame)
        if frame.get("type") == "chat":
            self._req_id = frame.get("req_id")

    def recv(self, timeout: float | None = None):
        if self._index >= len(self._script):
            raise ConnectionClosed(None, None)
        delay, item = self._script[self._index]
        if timeout is not None and delay > timeout:
            # The socket stayed silent for the whole budget.
            self._clock.advance(timeout)
            raise TimeoutError("recv timed out")
        self._clock.advance(delay)
        self._index += 1
        if isinstance(item, BaseException):
            raise item
        frame = dict(item)  # type: ignore[arg-type]
        if "kind" in frame:
            frame.setdefault("req_id", self._req_id)
        return json.dumps(frame)

    def close(self) -> None:
        self.closed = True


AUTH_OK = (0.0, {"type": "auth_ok"})
DONE = (0.0, {"kind": "done"})


def _client(clock: FakeClock, sockets: list[FakeSocket], **kw) -> BackendModelClient:
    opened: list[FakeSocket] = []

    def connect(url, **_kw):
        socket = sockets[len(opened)]
        opened.append(socket)
        return socket

    client = BackendModelClient(
        SupabaseSession(
            access_token="token",
            refresh_token="refresh",
            supabase_url="https://proj.supabase.co",
            anon_key="anon",
        ),
        model_id="z-ai/glm-5.3-flash",
        provider_slug="fireworks/serverless",
        base_url="https://api.example.test",
        connect=connect,
        clock=clock,
        **kw,
    )
    client.opened = opened  # type: ignore[attr-defined]
    return client


# -- the first-frame budget -------------------------------------------------


def test_a_stalled_first_frame_reconnects_at_the_short_budget_not_the_long_one():
    """Silence after the request is a dead socket, and we notice in 45 s.

    Before this, the same silence cost the full 180 s deadline and then failed
    the turn outright, because a breached ``recv_timeout`` raises a timeout that
    nothing retries.
    """
    clock = FakeClock()
    stalled = FakeSocket(clock, [AUTH_OK, (10_000.0, {"kind": "content", "data": "x"})])
    healthy = FakeSocket(
        clock, [AUTH_OK, (3.0, {"kind": "content", "data": "hi"}), DONE]
    )
    client = _client(clock, [stalled, healthy])

    started = clock.now
    response = client.complete([{"role": "user", "content": "q"}])
    elapsed = clock.now - started

    assert response.text == "hi"
    # 45 s of silence + 3 s of real answer — not 180, and not a failure.
    assert DEFAULT_FIRST_FRAME_TIMEOUT <= elapsed < DEFAULT_FIRST_FRAME_TIMEOUT + 10
    assert elapsed < DEFAULT_RECV_TIMEOUT
    assert len(client.opened) == 2  # type: ignore[attr-defined]
    assert stalled.closed
    timing = response.raw["timing"]
    assert timing["attempts"] == 2
    assert timing["retry_reason"] == "first_frame_stalled"
    assert timing["wasted_ms"] == pytest.approx(DEFAULT_FIRST_FRAME_TIMEOUT * 1000, rel=0.01)


def test_the_retry_after_a_stall_runs_without_the_short_budget():
    """A provider that really does need minutes for its first byte must not be
    cut off twice. The second attempt keeps only the 180 s backstop, so the
    short budget can never become a new way to fail a working run."""
    clock = FakeClock()
    stalled = FakeSocket(clock, [AUTH_OK, (10_000.0, {"kind": "done"})])
    slow_but_real = FakeSocket(
        clock, [AUTH_OK, (120.0, {"kind": "content", "data": "late"}), DONE]
    )
    client = _client(clock, [stalled, slow_but_real])

    response = client.complete([{"role": "user", "content": "q"}])

    assert response.text == "late"
    assert response.raw["timing"]["attempts"] == 2
    # 120 s > the 45 s budget: it survived only because the retry disarmed it.
    assert response.raw["timing"]["first_frame_ms"] == pytest.approx(120_000, rel=0.01)


def test_a_slow_but_alive_stream_is_never_cut_off():
    """Frames keep arriving, each one slower than the first-frame budget. The
    budget is already disarmed by then, so only the overall deadline applies and
    the stream runs to ``done``."""
    clock = FakeClock()
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (40.0, {"kind": "content", "data": "a"}),
            (40.0, {"kind": "content", "data": "b"}),
            (40.0, {"kind": "content", "data": "c"}),
            (35.0, {"kind": "done"}),
        ],
    )
    client = _client(clock, [socket])

    started = clock.now
    response = client.complete([{"role": "user", "content": "q"}])

    assert response.text == "abc"
    assert response.raw["timing"]["attempts"] == 1
    assert len(client.opened) == 1  # type: ignore[attr-defined]
    assert clock.now - started == pytest.approx(155.0)


def test_the_overall_deadline_is_still_the_backstop():
    """The short budget sits INSIDE the long one; the long one still fails a
    stream that never ends."""
    clock = FakeClock()
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (10.0, {"kind": "content", "data": "a"}),
            (10_000.0, {"kind": "done"}),
        ],
    )
    client = _client(clock, [socket], recv_timeout=60.0)

    with pytest.raises(BackendModelError) as excinfo:
        client.complete([{"role": "user", "content": "q"}])
    assert excinfo.value.code == "timeout"


def test_both_deadlines_are_constructor_parameters():
    clock = FakeClock()
    stalled = FakeSocket(clock, [AUTH_OK, (10_000.0, DONE[1])])
    healthy = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [stalled, healthy], first_frame_timeout=5.0, recv_timeout=90.0)

    started = clock.now
    client.complete([{"role": "user", "content": "q"}])

    assert clock.now - started == pytest.approx(6.0)


def test_the_first_frame_budget_can_be_switched_off():
    clock = FakeClock()
    socket = FakeSocket(
        clock, [AUTH_OK, (100.0, {"kind": "content", "data": "ok"}), DONE]
    )
    client = _client(clock, [socket], first_frame_timeout=None)

    response = client.complete([{"role": "user", "content": "q"}])

    assert response.text == "ok"
    assert len(client.opened) == 1  # type: ignore[attr-defined]


# -- retry accounting -------------------------------------------------------


def test_a_dropped_socket_lands_in_timing_as_a_counted_retry():
    clock = FakeClock()
    dropped = FakeSocket(clock, [AUTH_OK, (7.0, ConnectionClosed(None, None))])
    healthy = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [dropped, healthy])

    response = client.complete([{"role": "user", "content": "q"}])

    timing = response.raw["timing"]
    assert timing["attempts"] == 2
    assert timing["retry_reason"] == "connection_closed"
    assert timing["wasted_ms"] == pytest.approx(7000, rel=0.01)


def test_a_retry_is_warned_about_because_it_is_paid_for_twice(caplog):
    clock = FakeClock()
    dropped = FakeSocket(clock, [AUTH_OK, (7.0, ConnectionClosed(None, None))])
    healthy = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [dropped, healthy])

    with caplog.at_level(logging.WARNING, logger="chuk_agents_runtime.backend"):
        client.complete([{"role": "user", "content": "q"}])

    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert warnings, "a thrown-away attempt must not be silent"
    message = warnings[0].getMessage()
    assert "connection_closed" in message
    assert "dead_attempt_ms=7000" in message


def test_a_call_with_no_retry_says_so():
    clock = FakeClock()
    socket = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [socket])

    timing = client.complete([{"role": "user", "content": "q"}]).raw["timing"]

    assert timing["attempts"] == 1
    assert timing["retry_reason"] is None
    assert timing["wasted_ms"] == 0.0


# -- the log line -----------------------------------------------------------


def _model_call_lines(caplog) -> list[str]:
    return [
        r.getMessage()
        for r in caplog.records
        if r.levelno == logging.INFO and r.getMessage().startswith("model call")
    ]


def test_every_model_call_leaves_one_info_line(caplog):
    clock = FakeClock()
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (2.0, {"kind": "reasoning", "data": "hm"}),
            (1.0, {"kind": "content", "data": "ok"}),
            (0.5, {"kind": "usage", "data": {"prompt_tokens": 40000, "completion_tokens": 12}}),
            DONE,
        ],
    )
    client = _client(clock, [socket])

    with caplog.at_level(logging.INFO, logger="chuk_agents_runtime.backend"):
        client.complete([{"role": "user", "content": "q"}])

    lines = _model_call_lines(caplog)
    assert len(lines) == 1
    line = lines[0]
    for field in (
        "prepare_ms=", "connect_ms=", "first_frame_ms=", "first_token_ms=",
        "stream_ms=", "total_ms=", "attempts=", "prompt_tokens=",
        "prompt_tokens_est=", "completion_tokens=",
    ):
        assert field in line, field
    assert "first_token_ms=2000" in line
    assert "prompt_tokens=40000" in line


def test_the_log_line_carries_the_first_token_time_even_on_an_error(caplog):
    """A turn that died after four minutes is exactly the turn someone reads the
    log for. Without ``first_token_ms`` the line cannot say whether the model
    was slow or the socket stalled, so the error path must carry it too."""
    clock = FakeClock()
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (3.0, {"kind": "content", "data": "partial"}),
            (2.0, ConnectionClosed(None, None)),
        ],
    )
    client = _client(clock, [socket])

    with caplog.at_level(logging.INFO, logger="chuk_agents_runtime.backend"):
        with pytest.raises(BackendModelError) as excinfo:
            client.complete([{"role": "user", "content": "q"}])

    assert excinfo.value.code == "stream_interrupted"
    lines = _model_call_lines(caplog)
    assert len(lines) == 1
    assert "failed[stream_interrupted]" in lines[0]
    assert "first_token_ms=3000" in lines[0]
    assert "first_frame_ms=3000" in lines[0]


def test_the_backend_s_own_timing_block_is_folded_in_not_shadowed():
    clock = FakeClock()
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (1.0, {"kind": "timing", "data": {"queue_ms": 900, "prefill_ms": 120}}),
            (0.5, {"kind": "content", "data": "ok"}),
            DONE,
        ],
    )
    client = _client(clock, [socket])

    timing = client.complete([{"role": "user", "content": "q"}]).raw["timing"]

    assert timing["server"] == {"queue_ms": 900, "prefill_ms": 120}
