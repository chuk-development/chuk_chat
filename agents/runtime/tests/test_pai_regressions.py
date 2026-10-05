"""Regressions a review of the Pydantic AI loop found, each pinned by a test.

1. A Stop must never record a tool that ran as "not run" (the next task would
   repeat its side effect).
2. A thinking-only reply cut off by ``length`` / ``content_filter`` finishes
   the run with no answer; it is not a crash and leaves no nudge row.
3. Whitespace is text (Pydantic AI's rule); answers are stripped; the nudge
   row exists only when a retry follows.
4. SDK retries are counted on the run row; a stalled stream is aborted.
5. 402 / 429 reach the app as a message the user can act on.
6. A Stop mid-stream never stores a tool call with broken JSON.
8. The per-run HTTP client is closed when the run ends.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import httpx2
import pytest

import chuk_agents_runtime.loop as loop_module
from chuk_agents_runtime.loop import (
    INTERRUPTED_TOOL_RESULT,
    STOPPED_TOOL_RESULT,
    AgentLoop,
    FirstEventTimeout,
    KillSwitch,
    ModelServiceError,
    StopReason,
)
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

from pai_fakes import FakeChatEndpoint, FakeSession, chunk, sse, text_turn


def _store(tmp_path: Path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _model(endpoint: FakeChatEndpoint, **spec):
    return chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m", **spec), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )


def _tool_rows(store: StateStore, session_id: int) -> list[dict]:
    return [m.content for m in store.get_conversation(session_id) if m.content.get("role") == "tool"]


# -- 1. a Stop never denies a side effect ------------------------------------


def _sending_registry(sent: list[str], seconds: float) -> ToolRegistry:
    reg = ToolRegistry()

    def send_mail(to: str = "") -> dict:
        time.sleep(seconds)
        sent.append(to)  # the side effect, at the end of the call
        return {"ok": True, "sent_to": to}

    reg.register("send_mail", {"type": "object", "properties": {"to": {"type": "string"}}}, send_mail)
    return reg


def _stop_after(kill: KillSwitch, seconds: float) -> None:
    threading.Timer(seconds, kill.interrupt).start()


def test_a_stopped_call_that_finishes_inside_the_settle_time_keeps_its_real_result(tmp_path):
    sent: list[str] = []
    kill = KillSwitch()
    store = _store(tmp_path)
    loop = AgentLoop(
        MockModelClient([tool_call_response(("send_mail", {"to": "a@b.c"})), "never"]),
        _sending_registry(sent, 2.5), store, kill_switch=kill,
    )
    _stop_after(kill, 0.8)
    result = loop.run("s", "mail it")
    assert result.reason is StopReason.INTERRUPTED
    assert sent == ["a@b.c"]
    assert _tool_rows(store, result.session_id)[0]["content"] == {"ok": True, "sent_to": "a@b.c"}


def test_a_started_call_past_the_settle_time_is_unknown_never_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(loop_module, "STOP_SETTLE_S", 0.3)
    monkeypatch.setattr(AgentLoop._settle_inflight, "__defaults__", (0.3,))
    sent: list[str] = []
    kill = KillSwitch()
    store = _store(tmp_path)
    loop = AgentLoop(
        MockModelClient([tool_call_response(("send_mail", {"to": "x@y.z"})), "never"]),
        _sending_registry(sent, 2.0), store, kill_switch=kill,
    )
    _stop_after(kill, 0.5)
    result = loop.run("s", "mail it")
    row = _tool_rows(store, result.session_id)[0]
    assert row["content"] == STOPPED_TOOL_RESULT
    assert row["content"] != INTERRUPTED_TOOL_RESULT
    time.sleep(2.0)
    assert sent == ["x@y.z"]  # it did run: the row must not have said otherwise


def test_a_call_that_never_started_is_not_run_and_never_runs_later(tmp_path):
    sent: list[str] = []
    kill = KillSwitch()
    store = _store(tmp_path)
    reg = _sending_registry(sent, 1.5)
    loop = AgentLoop(
        MockModelClient([tool_call_response(("send_mail", {"to": "1"}), ("send_mail", {"to": "2"})), "never"]),
        reg, store, kill_switch=kill,
    )
    _stop_after(kill, 0.5)
    result = loop.run("s", "two mails")
    rows = _tool_rows(store, result.session_id)
    assert rows[0]["content"] == {"ok": True, "sent_to": "1"}
    assert rows[1]["content"] == INTERRUPTED_TOOL_RESULT
    time.sleep(2.0)
    assert sent == ["1"]


def test_the_call_record_never_starts_after_it_was_closed():
    from chuk_agents_runtime.pai.tools import CallRecord

    record = CallRecord(started_at=0.0)
    assert record.close_unstarted() is True
    assert record.begin() is False
    started = CallRecord(started_at=0.0)
    assert started.begin() is True
    assert started.close_unstarted() is False


# -- 2 + 3. empty replies ------------------------------------------------------


def _thinking_only(finish: str) -> bytes:
    return sse(
        [
            chunk({"role": "assistant", "content": ""}),
            chunk({"reasoning_content": "thinking about it"}),
            chunk({}, finish=finish, usage={"prompt_tokens": 5, "completion_tokens": 9, "total_tokens": 14}),
        ]
    )


@pytest.mark.parametrize("finish", ["length", "content_filter"])
def test_a_cut_off_thinking_only_reply_finishes_without_an_answer(tmp_path, finish):
    endpoint = FakeChatEndpoint([_thinking_only(finish)])
    model, settings = _model(endpoint)
    store = _store(tmp_path)
    result = AgentLoop(model, ToolRegistry(), store, model_settings=settings).run("s", "q")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer is None
    assert result.note == finish
    assert len(endpoint.requests) == 1  # no retry
    assert [m.role for m in store.get_conversation(result.session_id)] == ["user", "assistant"]


def test_a_whitespace_reply_is_no_answer_and_leaves_no_nudge_row(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["   "])])
    model, settings = _model(endpoint)
    store = _store(tmp_path)
    result = AgentLoop(model, ToolRegistry(), store, model_settings=settings).run("s", "q")
    assert result.final_answer is None
    assert "context" not in [m.role for m in store.get_conversation(result.session_id)]
    assert len(endpoint.requests) == 1


def test_the_answer_is_stripped(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["  hello ", "there \n"])])
    model, settings = _model(endpoint)
    store = _store(tmp_path)
    result = AgentLoop(model, ToolRegistry(), store, model_settings=settings).run("s", "q")
    assert result.final_answer == "hello there"
    assert store.get_conversation(result.session_id)[-1].content["content"] == "hello there"


# -- 4. retries and stalls ------------------------------------------------------


def test_an_sdk_retry_is_counted_on_the_run_row(tmp_path):
    endpoint = FakeChatEndpoint([500, text_turn(["ok"])])
    model, settings = _model(endpoint)
    result = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert result.final_answer == "ok"
    assert result.timings.retries == 1
    assert len(endpoint.requests) == 2


def test_the_sdk_retries_at_most_once(tmp_path):
    endpoint = FakeChatEndpoint([500, 500, text_turn(["late"])])
    model, settings = _model(endpoint)
    with pytest.raises(Exception):
        AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert len(endpoint.requests) == 2


def test_a_stream_that_sends_only_keep_alives_is_aborted(tmp_path, monkeypatch):
    monkeypatch.setattr(loop_module, "FIRST_EVENT_TIMEOUT_S", 0.5)

    class KeepAlive(httpx2.AsyncByteStream):
        async def __aiter__(self):
            import asyncio

            for _ in range(40):
                yield b": keep-alive\n\n"
                await asyncio.sleep(0.1)

    def handler(request):
        return httpx2.Response(200, stream=KeepAlive(), headers={"content-type": "text/event-stream"})

    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(handler),
    )
    started = time.monotonic()
    with pytest.raises(FirstEventTimeout) as caught:
        AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert time.monotonic() - started < 3.0
    assert "sent nothing" in caught.value.user_message


# -- 5. errors the user can act on --------------------------------------------------


@pytest.mark.parametrize(
    ("status", "message"),
    [(402, "no credits left"), (429, "rate limited, try again shortly")],
)
def test_402_and_429_become_messages_for_the_app(tmp_path, status, message):
    endpoint = FakeChatEndpoint([status, status])
    model, settings = _model(endpoint)
    with pytest.raises(ModelServiceError) as caught:
        AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert caught.value.user_message == message


# -- 6. a Stop mid-stream never stores broken JSON ---------------------------------


def test_a_tool_call_cut_off_mid_stream_is_not_stored(tmp_path):
    import json

    kill = KillSwitch()

    class HalfCall(httpx2.AsyncByteStream):
        async def __aiter__(self):
            import asyncio

            yield b"data: " + json.dumps(chunk({"role": "assistant", "content": "Let me mail."})).encode() + b"\n\n"
            yield b"data: " + json.dumps(chunk({"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "send_mail", "arguments": '{"to": "a@'}}]})).encode() + b"\n\n"
            kill.interrupt()
            await asyncio.sleep(30)

    def handler(request):
        return httpx2.Response(200, stream=HalfCall(), headers={"content-type": "text/event-stream"})

    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(handler),
    )
    store = _store(tmp_path)
    result = AgentLoop(model, _sending_registry([], 0.0), store, kill_switch=kill, model_settings=settings).run("s", "q")
    assert result.reason is StopReason.INTERRUPTED
    rows = [m.content for m in store.get_conversation(result.session_id)]
    assert rows[-1] == {"role": "assistant", "content": "Let me mail."}
    assert not any(r.get("tool_calls") for r in rows)
    assert not _tool_rows(store, result.session_id)


# -- 8. the per-run client is closed ------------------------------------------------


def test_a_model_built_per_run_is_closed_when_the_run_ends(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["one"]), text_turn(["two"])])
    built = []

    def factory():
        model, _ = _model(endpoint)
        built.append(model)
        return model

    _, settings = _model(endpoint)
    loop = AgentLoop(MockModelClient([]), ToolRegistry(), _store(tmp_path), model_factory=factory, model_settings=settings)
    assert loop.run("s", "a").final_answer == "one"
    assert loop.run("s", "b").final_answer == "two"
    assert len(built) == 2
    assert all(m.client.is_closed() for m in built)
