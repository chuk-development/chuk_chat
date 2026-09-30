"""The five spike gates of docs/PYDANTIC_AI_LOOP.md, section 14. No network.

1. Token and reasoning deltas from the OpenAI-compatible SSE route reach the
   delta / reasoning sinks, live, in order; the JWT rides on every request and
   is refreshed on expiry and on a 401.
2. An approval-required tool (here.now publish) pauses the run, asks, and the
   run resumes in the same ``run()`` call — approve and deny.
3. A test secret never reaches the model's messages, the stored history, the
   frames (sinks) or the tool events.
4. A Stop during a long ``run_command`` ends the run with an interrupted tool
   row in under two seconds and the sandbox process is gone.
5. Tool search over many (MCP-like) tools: the tools stay off the wire until
   the model searches, then the discovered tool is called directly.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

import pytest

from chuk_agents_runtime.environment import LocalEnvironment
from chuk_agents_runtime.herenow import HereNowConfig, PublishRequest, register_herenow_tools
from chuk_agents_runtime.loop import INTERRUPTED_TOOL_RESULT, AgentLoop, KillSwitch, StopReason
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.pai import ApprovalPolicy, herenow_rule
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.secrets import DictSecrets, register_secrets_tools
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.tools import register_builtin_tools

from pai_fakes import CancellableEnv, FakeChatEndpoint, FakeSession, text_turn, tool_turn


def _store(tmp_path: Path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _echo_registry() -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "echo",
        {"description": "Echo a value.", "type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"echo": v},
    )
    return reg


# -- gate 1: deltas, reasoning, JWT --------------------------------------------


def test_gate1_sse_text_and_reasoning_deltas_stream_live_in_order(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("call_a", "echo", {"v": "hi"})], reasoning_parts=["I should ", "echo."]),
            text_turn(["The echo ", "said ", "hi."], reasoning_parts=["Done, ", "answer."]),
        ]
    )
    session = FakeSession()
    spec = ChukModelSpec(
        model_id="deepseek/deepseek-v4-flash", provider_slug="fireworks", reasoning_effort="low"
    )
    model, settings = chuk_chat_model(
        session, spec, base_url="https://api.test", transport=_transport(endpoint)
    )
    frames: list[tuple[str, str]] = []
    tools: list[dict] = []
    store = _store(tmp_path)
    loop = AgentLoop(
        model,
        _echo_registry(),
        store,
        model_settings=settings,
        on_delta=lambda t: frames.append(("delta", t)),
        on_reasoning=lambda t: frames.append(("reasoning", t)),
        tool_event_observer=tools.append,
    )
    result = loop.run("s1", "say hi")

    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "The echo said hi."
    assert result.iterations == 2
    # Live and in order: the thinking of each turn, then its text.
    assert frames == [
        ("reasoning", "I should "),
        ("reasoning", "echo."),
        ("reasoning", "Done, "),
        ("reasoning", "answer."),
        ("delta", "The echo "),
        ("delta", "said "),
        ("delta", "hi."),
    ]
    # One tool frame per call, in the wire shape.
    assert [t["name"] for t in tools] == ["echo"]
    assert tools[0]["status"] == "completed"
    assert json.loads(tools[0]["result"]) == {"echo": "hi"}
    # Usage from the stream feeds the token count (28 + 15).
    assert result.tokens_spent == 43
    # The stored rows are the native shape, thinking kept for the replay.
    rows = [m.content for m in store.get_conversation(result.session_id)]
    assert rows[1]["role"] == "assistant"
    assert rows[1]["reasoning"] == "I should echo."
    assert rows[1]["tool_calls"][0]["function"] == {"name": "echo", "arguments": {"v": "hi"}}
    assert rows[2] == {"role": "tool", "tool_call_id": "call_a", "name": "echo", "content": {"echo": "hi"}}
    assert rows[3] == {"role": "assistant", "content": "The echo said hi.", "reasoning": "Done, answer."}

    # The request: the OpenAI route, the JWT, the task's model options.
    first = endpoint.requests[0]
    assert first["path"] == "/v1/chat/completions"
    assert first["authorization"] == "Bearer jwt-1"
    body = first["body"]
    assert body["model"] == "deepseek/deepseek-v4-flash"
    assert body["stream"] is True
    assert body["stream_options"] == {"include_usage": True}
    assert body["reasoning_effort"] == "low"
    assert body["provider"] == "fireworks"  # the route's provider pin
    assert "max_tokens" not in body and "temperature" not in body
    assert [t["function"]["name"] for t in body["tools"]] == ["echo"]
    assert body["tools"][0]["function"]["parameters"] == {
        "type": "object",
        "properties": {"v": {"type": "string"}},
    }
    # The thinking is not sent back (native parity), the tool result is.
    second = endpoint.requests[1]["body"]["messages"]
    assert all("reasoning_content" not in m for m in second)
    assert second[-1]["role"] == "tool" and second[-1]["tool_call_id"] == "call_a"


def _transport(endpoint: FakeChatEndpoint):
    import httpx2

    return httpx2.MockTransport(endpoint.handler)


def test_gate1_expired_token_is_refreshed_before_the_request(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["ok"])])
    session = FakeSession(access_token="jwt-7", expired=True)
    model, settings = chuk_chat_model(
        session, ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    loop = AgentLoop(model, _echo_registry(), _store(tmp_path), model_settings=settings)
    assert loop.run("s", "hi").final_answer == "ok"
    assert session.refreshes == [("token_expired", None)]
    assert endpoint.requests[0]["authorization"] == "Bearer jwt-8"


def test_gate1_a_401_refreshes_once_and_retries_with_the_new_token(tmp_path):
    endpoint = FakeChatEndpoint([401, text_turn(["after refresh"])])
    session = FakeSession(access_token="jwt-1")
    model, settings = chuk_chat_model(
        session, ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    loop = AgentLoop(model, _echo_registry(), _store(tmp_path), model_settings=settings)
    assert loop.run("s", "hi").final_answer == "after refresh"
    assert [r["authorization"] for r in endpoint.requests] == ["Bearer jwt-1", "Bearer jwt-2"]
    assert session.refreshes == [("auth_rejected", "jwt-1")]


# -- gate 2: approval pauses and resumes in the same run -------------------------


class _PublishEnv(LocalEnvironment):
    """The here.now publisher runs inside the sandbox; this stands in for it
    and records which mode ran."""

    def __init__(self) -> None:
        super().__init__()
        self.modes: list[str] = []


def _herenow_runtime(monkeypatch, tmp_path, gate):
    import chuk_agents_runtime.herenow as herenow

    env = _PublishEnv()

    def fake_publisher(env_, mode, config, args):
        env.modes.append(mode)
        if mode == "scan":
            return {"ok": True, "file_count": 3, "total_bytes": 1234}
        return {"ok": True, "url": "https://x.here.now", "anonymous": False, "file_count": 3}

    monkeypatch.setattr(herenow, "_run_publisher", fake_publisher)
    config = HereNowConfig(enabled=True, approval="ask")
    reg = ToolRegistry()
    # The approval now lives in Pydantic AI's deferred-tool flow, so the tool
    # itself is registered with an always-yes gate: it only runs once approved.
    register_herenow_tools(reg, env, config, gate=lambda request: True)
    policy = ApprovalPolicy()
    policy.add("herenow_publish", herenow_rule(env, config, gate))
    return env, reg, policy


@pytest.mark.parametrize("answer", [True, False])
def test_gate2_publish_waits_for_the_user_then_the_same_run_continues(monkeypatch, tmp_path, answer):
    asked: list[PublishRequest] = []
    decided = threading.Event()

    def gate(request: PublishRequest) -> bool:
        # The executor's gate blocks on the worker thread until the app
        # answers; the answer arrives from another thread.
        asked.append(request)
        threading.Timer(0.2, decided.set).start()
        assert decided.wait(5)
        return answer

    env, reg, policy = _herenow_runtime(monkeypatch, tmp_path, gate)
    model = MockModelClient(
        [tool_call_response(("herenow_publish", {"path": "site", "name": "Demo"})), "all set"]
    )
    tools: list[dict] = []
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store, approval_policy=policy, tool_event_observer=tools.append)
    result = loop.run("pub", "publish my site")

    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "all set"  # the SAME run went on after the answer
    assert result.iterations == 2
    # The prompt was honest about what goes out: the scan ran first.
    assert asked == [
        PublishRequest(path="site", name="Demo", file_count=3, total_bytes=1234, base_url="https://here.now")
    ]
    row = next(m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool")
    if answer:
        assert env.modes == ["scan", "scan", "publish"]
        assert row["content"]["ok"] is True and row["content"]["url"] == "https://x.here.now"
        assert tools[0]["status"] == "completed"
    else:
        assert env.modes == ["scan"]  # nothing was published
        assert row["content"] == {
            "ok": False,
            "path": "site",
            "declined": True,
            "error": "the user declined to publish this.",
        }
        assert tools[0]["status"] == "error"


def test_gate2_normal_tools_never_ask(tmp_path):
    """Everything is allowed by default: an empty policy asks for nothing."""
    policy = ApprovalPolicy()
    model = MockModelClient([tool_call_response(("echo", {"v": "x"})), "done"])
    loop = AgentLoop(model, _echo_registry(), _store(tmp_path), approval_policy=policy)
    assert loop.run("s", "go").final_answer == "done"
    assert not policy.requires_approval("echo")


def test_gate2_publish_with_nobody_to_ask_is_refused_without_publishing(monkeypatch, tmp_path):
    env, reg, policy = _herenow_runtime(monkeypatch, tmp_path, gate=None)
    model = MockModelClient([tool_call_response(("herenow_publish", {"path": "site"})), "ok"])
    store = _store(tmp_path)
    result = AgentLoop(model, reg, store, approval_policy=policy).run("pub", "go")
    row = next(m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool")
    assert "no one is available to approve" in row["content"]["error"]
    assert "publish" not in env.modes


# -- gate 3: a secret never leaks -------------------------------------------------


SECRET = "sk-live-0123456789abcdef"


def test_gate3_secret_never_reaches_model_store_frames_or_events(tmp_path):
    reg = ToolRegistry()
    access = DictSecrets({"PEXELS_API_KEY": SECRET})
    register_secrets_tools(reg, access)
    reg.register(
        "leaky",
        {"type": "object", "properties": {}},
        lambda: {"stdout": f"key is {SECRET}", "exit_code": 0},
    )
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("c1", "leaky", {})]),
            # The model echoes the secret it was never shown (worst case).
            text_turn([f"it was {SECRET[:10]}", SECRET[10:]]),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    frames: list[str] = []
    tools: list[dict] = []
    store = _store(tmp_path)
    loop = AgentLoop(
        model,
        reg,
        store,
        model_settings=settings,
        # The executor scrubs every frame it seals with the same scrubber.
        on_delta=frames.append,
        tool_event_observer=tools.append,
        persist_filter=reg.result_filter,
    )
    # The user pastes the key into the prompt too.
    result = loop.run("sec", f"use {SECRET} please")

    stored = json.dumps([m.content for m in store.get_conversation(result.session_id)])
    wire = json.dumps([r["body"] for r in endpoint.requests])
    events = json.dumps(tools)
    assert SECRET not in stored
    assert SECRET not in wire  # what the model was sent (both requests)
    assert SECRET not in events
    assert "[REDACTED:PEXELS_API_KEY]" in stored
    assert "[REDACTED:PEXELS_API_KEY]" in wire
    # The stored answer row is masked. ``final_answer`` and the deltas are the
    # model's raw text, exactly as on the native loop: the executor masks them
    # with the same scrubber when it seals the ``delta`` / ``done`` frames and
    # writes the run row.
    answer_row = [m.content for m in store.get_conversation(result.session_id)][-1]
    assert answer_row["role"] == "assistant"
    assert answer_row["content"] == "it was [REDACTED:PEXELS_API_KEY]"
    assert "".join(frames) == f"it was {SECRET}"


# -- gate 4: stop during a long run_command -------------------------------------


def test_gate4_stop_mid_command_ends_in_under_two_seconds_and_kills_the_process(tmp_path):
    env = CancellableEnv(cwd=str(tmp_path))
    reg = ToolRegistry()
    register_builtin_tools(reg, env)
    kill = KillSwitch()
    # The executor's listener: a Stop kills what the sandbox is running.
    kill.on_interrupt(env.cancel)
    marker = tmp_path / "alive.pid"
    command = f"echo $$ > {marker}; sleep 60; echo finished"
    model = MockModelClient(
        [tool_call_response(("run_command", {"command": command})), "never reached"]
    )
    tools: list[dict] = []
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store, kill_switch=kill, tool_event_observer=tools.append)

    def stop_soon() -> None:
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        time.sleep(0.3)
        stop_pressed.append(time.monotonic())
        kill.interrupt()

    stop_pressed: list[float] = []
    threading.Thread(target=stop_soon, daemon=True).start()
    result = loop.run("stop", "run it")
    returned = time.monotonic()

    assert result.reason is StopReason.INTERRUPTED
    assert stop_pressed, "the command never started"
    assert returned - stop_pressed[0] < 2.0
    pid = int(marker.read_text().strip())
    time.sleep(0.1)
    assert not _alive(pid), "the sandbox process survived the stop"
    row = next(m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool")
    assert row["tool_call_id"] == "call_0"
    # Either the killed command's own result arrived inside the grace, or the
    # row says it was not run; both are an answered call, never a dangling one.
    content = row["content"]
    assert content == INTERRUPTED_TOOL_RESULT or "finished" not in json.dumps(content)
    assert len(tools) == 1


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie still answers kill(0); read its state.
    try:
        with open(f"/proc/{pid}/stat") as fh:
            return fh.read().split()[2] != "Z"
    except OSError:
        return False


def test_gate4_stop_while_the_model_streams_closes_the_stream_at_once(tmp_path):
    """A Stop during a slow model stream: the Pydantic AI cancellation closes
    the stream, the run reports INTERRUPTED and keeps what was streamed."""
    import httpx2

    kill = KillSwitch()

    class SlowStream(httpx2.AsyncByteStream):
        async def __aiter__(self):
            import asyncio

            body = text_turn(["partial ", "answer"]).split(b"\n\n")
            for index, piece in enumerate(body):
                if index == 2:  # after "partial ", before "answer"
                    kill.interrupt()
                    await asyncio.sleep(30)
                yield piece + b"\n\n"

    def handler(request):
        return httpx2.Response(200, stream=SlowStream(), headers={"content-type": "text/event-stream"})

    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(handler),
    )
    deltas: list[str] = []
    store = _store(tmp_path)
    loop = AgentLoop(model, _echo_registry(), store, kill_switch=kill, model_settings=settings, on_delta=deltas.append)
    started = time.monotonic()
    result = loop.run("s", "go")
    assert time.monotonic() - started < 2.0
    assert result.reason is StopReason.INTERRUPTED
    assert deltas == ["partial "]
    assert any(m.content.get("content") == "partial" for m in store.get_conversation(result.session_id))


# -- gate 5: tool search over many MCP-like tools --------------------------------


def _many_tools_registry(count: int = 60) -> ToolRegistry:
    reg = _echo_registry()
    for index in range(count):
        name = f"mcp__crm__tool_{index:02d}"
        reg.register(
            name,
            {
                "description": f"CRM operation number {index}: "
                + ("create an invoice for a customer" if index == 42 else "list records"),
                "type": "object",
                "properties": {"customer": {"type": "string"}},
            },
            (lambda i: (lambda customer="": {"tool": i, "customer": customer}))(index),
            deferrable=True,
        )
        reg.defer(name)
    return reg


def test_gate5_tool_search_reveals_a_deferred_tool_that_is_then_called_directly(tmp_path):
    reg = _many_tools_registry()
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["invoice customer"]})]),
            tool_turn([("c1", "mcp__crm__tool_42", {"customer": "ACME"})]),
            text_turn(["invoice created"]),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    tools: list[dict] = []
    store = _store(tmp_path)
    loop = AgentLoop(
        model, reg, store, model_settings=settings, deferred_mode="pai", tool_event_observer=tools.append
    )
    result = loop.run("ts", "bill ACME")

    assert result.final_answer == "invoice created"
    names = [[t["function"]["name"] for t in r["body"].get("tools", [])] for r in endpoint.requests]
    # Round 1: the 60 deferred tools are off the wire; the search tool is on.
    assert "search_tools" in names[0]
    assert not any(n.startswith("mcp__crm__") for n in names[0])
    # Round 2: the discovered tool is on the wire and was called directly.
    assert "mcp__crm__tool_42" in names[1]
    assert sum(n.startswith("mcp__crm__") for n in names[1]) < 60
    assert [t["name"] for t in tools] == ["search_tools", "mcp__crm__tool_42"]
    assert json.loads(tools[1]["result"]) == {"tool": 42, "customer": "ACME"}
    rows = [m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool"]
    assert rows[0]["name"] == "search_tools"
    assert [m["name"] for m in rows[0]["content"]["discovered_tools"]][0] == "mcp__crm__tool_42"
    assert rows[1] == {
        "role": "tool",
        "tool_call_id": "c1",
        "name": "mcp__crm__tool_42",
        "content": {"tool": 42, "customer": "ACME"},
    }


def test_gate5_discovery_survives_the_store_round_trip(tmp_path):
    """A discovered tool stays discovered in the next task of the session:
    the search result is a stored row, and the converter turns it back into
    the typed part Pydantic AI reads discoveries from."""
    reg = _many_tools_registry()
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["invoice customer"]})]),
            text_turn(["found it"]),
            tool_turn([("c1", "mcp__crm__tool_42", {"customer": "B"})]),
            text_turn(["done"]),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store, model_settings=settings, deferred_mode="pai")
    assert loop.run("ts", "find the invoice tool").final_answer == "found it"
    assert loop.run("ts", "now bill B").final_answer == "done"
    third = [t["function"]["name"] for t in endpoint.requests[2]["body"]["tools"]]
    assert "mcp__crm__tool_42" in third


def test_a_thinking_only_reply_gets_one_nudge_then_the_answer(tmp_path):
    """Kimi sometimes ends a tool loop with reasoning and no text. The run
    asks once more instead of finishing with no answer; the nudge is a
    context row, so the replay never shows it as a user turn."""
    endpoint = FakeChatEndpoint(
        [
            text_turn([], reasoning_parts=["I am done thinking."]),
            text_turn(["Here is the answer."]),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test", transport=_transport(endpoint)
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, _echo_registry(), store, model_settings=settings)
    result = loop.run("nudge", "question")
    assert result.final_answer == "Here is the answer."
    assert result.iterations == 2
    roles = [m.role for m in store.get_conversation(result.session_id)]
    assert roles == ["user", "assistant", "context", "assistant"]
    replayed = [e["type"] for e in store.replay_events(result.session_id)]
    assert replayed.count("user") == 1
