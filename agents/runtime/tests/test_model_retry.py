"""The autonomous retry of a failed model call (CHAT-31, ``model_retry``).

The host keeps running when the app is closed, so a provider failure must not
wait for a "Resend" tap: the loop asks the model again by itself, quick first,
then once per minute, for a bounded time. Only the model call is asked again;
a tool that already ran is never run twice.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import httpx2
import pytest

from chuk_agents_runtime.loop import (
    AgentLoop,
    FirstEventTimeout,
    KillSwitch,
    ModelServiceError,
    StopReason,
)
from chuk_agents_runtime.model_retry import (
    EmptyModelResponse,
    RetryPolicy,
    RetryTracker,
    classify,
    retry_after_seconds,
)
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

from pai_fakes import FakeChatEndpoint, FakeSession, chunk, sse, text_turn, tool_turn

FAST = RetryPolicy(quick_delays=(0.01, 0.01), slow_interval=0.01, window=30.0)


class _Status(Exception):
    def __init__(self, status: int, headers: dict | None = None) -> None:
        super().__init__(f"HTTP {status}")
        self.status_code = status
        self.headers = headers


# -- the policy ----------------------------------------------------------------


def test_quick_retries_first_then_once_per_minute():
    policy = RetryPolicy()
    assert [policy.delay(n) for n in range(1, 8)] == [2, 5, 15, 30, 60, 60, 60]


def test_retry_after_is_kept_but_never_longer_than_the_slow_interval():
    policy = RetryPolicy()
    assert policy.delay(1, retry_after=20) == 20
    assert policy.delay(1, retry_after=3600) == 60
    assert policy.delay(3, retry_after=1) == 15


def test_the_window_comes_from_the_environment(monkeypatch):
    monkeypatch.setenv("AGENTS_MODEL_RETRY_WINDOW_S", "120")
    assert RetryPolicy.from_env().window == 120
    monkeypatch.setenv("AGENTS_MODEL_RETRY_WINDOW_S", "0")
    assert not RetryPolicy.from_env().enabled
    monkeypatch.setenv("AGENTS_MODEL_RETRY_WINDOW_S", "")
    assert RetryPolicy.from_env().window == 30 * 60


@pytest.mark.parametrize("status", [408, 425, 429, 500, 502, 503, 504, 524])
def test_service_failures_are_retried(status):
    assert classify(_Status(status))[0] is True


@pytest.mark.parametrize("status", [400, 401, 402, 403, 404, 422])
def test_a_wrong_request_is_not_retried(status):
    retryable, reason = classify(_Status(status))
    assert retryable is False and reason == f"HTTP {status}"


def test_network_errors_timeouts_and_empty_answers_are_retried():
    assert classify(httpx2.ConnectError("down")) == (True, "network error")
    assert classify(TimeoutError()) == (True, "network error")
    assert classify(FirstEventTimeout(90)) == (True, "no answer")
    assert classify(EmptyModelResponse()) == (True, "empty answer")
    assert classify(ValueError("bug")) == (False, "ValueError")


def test_the_cause_chain_is_read():
    try:
        try:
            raise _Status(503)
        except _Status as inner:
            raise RuntimeError("wrapped") from inner
    except RuntimeError as outer:
        assert classify(outer) == (True, "HTTP 503")


def test_retry_after_header_is_read():
    assert retry_after_seconds(_Status(429, {"retry-after": "12"})) == 12
    assert retry_after_seconds(_Status(429, {})) is None


def test_the_tracker_gives_up_when_the_window_is_used_up():
    now = [0.0]
    tracker = RetryTracker(RetryPolicy(window=100), clock=lambda: now[0])
    delays = []
    while (delay := tracker.next_delay(_Status(503))) is not None:
        delays.append(delay)
        now[0] += delay
    assert delays == [2, 5, 15, 30]  # 52 s; one more minute would pass 100 s
    assert tracker.gave_up and tracker.attempts == 4
    assert "last error: HTTP 503" in tracker.give_up_message()


def test_a_wrong_request_is_not_a_give_up():
    tracker = RetryTracker(RetryPolicy())
    assert tracker.next_delay(_Status(402)) is None
    assert not tracker.gave_up


def test_window_zero_turns_the_retry_off():
    tracker = RetryTracker(RetryPolicy(window=0))
    assert tracker.next_delay(_Status(503)) is None
    assert not tracker.gave_up


# -- the loop ------------------------------------------------------------------


def _store(tmp_path: Path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _model(endpoint: FakeChatEndpoint):
    return chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )


def _mail_registry(sent: list[str]) -> ToolRegistry:
    reg = ToolRegistry()

    def send_mail(to: str = "") -> dict:
        sent.append(to)
        return {"ok": True, "sent_to": to}

    reg.register("send_mail", {"type": "object", "properties": {"to": {"type": "string"}}}, send_mail)
    return reg


def test_a_failed_call_after_a_tool_is_retried_and_the_tool_runs_once(tmp_path):
    """The tool ran, then the next model call failed twice (each failure is
    two 503s: the SDK's own retry and its last try). The loop retries the model
    call only; the mail goes out once and the answer arrives."""
    sent: list[str] = []
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("c1", "send_mail", {"to": "a@b.c"})]),
            503, 503,
            503, 503,
            text_turn(["sent it"]),
        ]
    )
    model, settings = _model(endpoint)
    seen: list[dict | None] = []
    loop = AgentLoop(
        model, _mail_registry(sent), _store(tmp_path), model_settings=settings,
        retry_policy=FAST, retry_observer=seen.append,
    )
    result = loop.run("s", "mail a@b.c")
    assert result.final_answer == "sent it"
    assert sent == ["a@b.c"]
    assert result.reason == StopReason.FINISHED
    # Two model steps counted (tool turn, answer); the failed ones are not.
    assert result.iterations == 2
    waits = [info for info in seen if info is not None]
    assert [w["attempt"] for w in waits] == [1, 2]
    assert waits[0]["reason"] == "HTTP 503" and waits[0]["gives_up_in"] > 0
    assert seen[-1] is None  # the last wait closed before the attempt
    # The retried request still holds the tool result.
    last_messages = endpoint.requests[-1]["body"]["messages"]
    assert any(m.get("role") == "tool" for m in last_messages)


def test_a_network_error_is_retried(tmp_path):
    calls = {"n": 0}
    endpoint = FakeChatEndpoint([text_turn(["back"])])

    def flaky(request: httpx2.Request) -> httpx2.Response:
        calls["n"] += 1
        if calls["n"] <= 2:  # SDK try + SDK retry both fail
            raise httpx2.ConnectError("network is unreachable")
        return endpoint.handler(request)

    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(flaky),
    )
    loop = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings, retry_policy=FAST)
    assert loop.run("s", "q").final_answer == "back"


def test_an_empty_stream_is_retried(tmp_path):
    endpoint = FakeChatEndpoint([sse([chunk({"role": "assistant", "content": ""})]), text_turn(["ok"])])
    model, settings = _model(endpoint)
    loop = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings, retry_policy=FAST)
    assert loop.run("s", "q").final_answer == "ok"
    assert len(endpoint.requests) == 2


def test_the_turn_fails_with_a_clear_reason_when_the_window_is_used_up(tmp_path):
    endpoint = FakeChatEndpoint([500] * 200)
    model, settings = _model(endpoint)
    policy = RetryPolicy(quick_delays=(0.02,), slow_interval=0.02, window=0.1)
    loop = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings, retry_policy=policy)
    with pytest.raises(ModelServiceError) as info:
        loop.run("s", "q")
    assert "did not answer" in info.value.user_message
    assert "HTTP 500" in info.value.user_message


def test_no_credits_is_not_retried(tmp_path):
    endpoint = FakeChatEndpoint([402, text_turn(["never"])])
    model, settings = _model(endpoint)
    loop = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings, retry_policy=FAST)
    with pytest.raises(ModelServiceError) as info:
        loop.run("s", "q")
    assert info.value.user_message == "no credits left"
    assert len(endpoint.requests) == 1


def test_a_stop_during_the_wait_ends_the_run_at_once(tmp_path):
    endpoint = FakeChatEndpoint([503, 503, text_turn(["never"])])
    model, settings = _model(endpoint)
    kill = KillSwitch()
    slow = RetryPolicy(quick_delays=(30.0,), slow_interval=30.0, window=600)
    waiting = threading.Event()
    loop = AgentLoop(
        model, ToolRegistry(), _store(tmp_path), model_settings=settings, kill_switch=kill,
        retry_policy=slow, retry_observer=lambda info: info and waiting.set(),
    )
    threading.Thread(target=lambda: waiting.wait(10) and kill.interrupt(), daemon=True).start()
    started = time.monotonic()
    result = loop.run("s", "q")
    assert result.reason == StopReason.INTERRUPTED
    assert time.monotonic() - started < 10
    assert len(endpoint.requests) == 2
