"""The spike gates live, against ``POST https://api.chuk.chat/v1/chat/completions``.

Runs only with ``AGENTS_LIVE=1``. Spends credits. The access token is the one
the running desktop app keeps in its SharedPreferences; it is read from the
file for every request, never printed and never refreshed here (a refresh
would rotate the app's refresh token under the running app). The app refreshes
it itself; this session just reads the newest one.

Models: ``AGENTS_LIVE_MODELS`` (comma separated), default
``deepseek/deepseek-v4-flash,moonshotai/kimi-k2.6``.
"""

from __future__ import annotations

import base64
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

import httpx2
import pytest

from chuk_agents_runtime.herenow import HereNowConfig, PublishRequest, register_herenow_tools
from chuk_agents_runtime.loop import INTERRUPTED_TOOL_RESULT, AgentLoop, KillSwitch, StopReason
from chuk_agents_runtime.pai import ApprovalPolicy, herenow_rule
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.secrets import DictSecrets, register_secrets_tools
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.tools import register_builtin_tools

from pai_fakes import CancellableEnv

LIVE_ENV = "AGENTS_LIVE"
BASE_URL = "https://api.chuk.chat"
APP_PREFS = (
    Path.home() / ".local/share/dev.chuk.chat/shared_preferences.json",
    Path.home() / ".local/share/dev.chuk.cowork/shared_preferences.json",
)
MODELS = [
    m.strip()
    for m in os.environ.get(
        "AGENTS_LIVE_MODELS", "deepseek/deepseek-v4-flash,moonshotai/kimi-k2.6"
    ).split(",")
    if m.strip()
]

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(os.environ.get(LIVE_ENV) != "1", reason=f"set {LIVE_ENV}=1 to run"),
]


def _app_token() -> str | None:
    for path in APP_PREFS:
        if not path.exists():
            continue
        try:
            prefs = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for key, value in prefs.items():
            if key.endswith("-auth-token") and isinstance(value, str):
                try:
                    token = json.loads(value).get("access_token")
                except ValueError:
                    continue
                if isinstance(token, str) and token:
                    return token
    return None


def _expiry(token: str) -> float:
    try:
        payload = token.split(".")[1]
        return float(json.loads(base64.urlsafe_b64decode(payload + "==="))["exp"])
    except (IndexError, KeyError, ValueError):
        return 0.0


class AppFileSession:
    """The app's session, read-only: the token comes from the app's own file
    on every read, and a "refresh" only re-reads that file."""

    refreshes = 0

    @property
    def access_token(self) -> str:
        token = _app_token()
        if not token:
            pytest.skip("no signed-in desktop app session found")
        return token

    def is_expired(self) -> bool:
        return time.time() >= _expiry(self.access_token) - 30

    def refresh(self, *, reason: str = "", seen_token: str | None = None) -> None:
        self.refreshes += 1  # nothing to spend: the app rotates the token itself


class Recorder(httpx2.AsyncBaseTransport):
    """The real network, with every request body kept for the assertions.
    Headers are not kept (the bearer must not land in a test report)."""

    def __init__(self) -> None:
        self._inner = httpx2.AsyncHTTPTransport()
        self.bodies: list[dict] = []
        self.statuses: list[int] = []

    async def handle_async_request(self, request: httpx2.Request) -> httpx2.Response:
        try:
            self.bodies.append(json.loads(request.content or b"{}"))
        except ValueError:
            self.bodies.append({})
        response = await self._inner.handle_async_request(request)
        self.statuses.append(response.status_code)
        return response


@pytest.fixture(scope="module")
def session() -> AppFileSession:
    s = AppFileSession()
    token = _app_token()
    if not token:
        pytest.skip("no signed-in desktop app session found")
    if time.time() >= _expiry(token) - 60:
        pytest.skip("the app's access token is about to expire; open the app and retry")
    return s


def _model(session: AppFileSession, model_id: str, recorder: Recorder, **spec: Any):
    return chuk_chat_model(
        session, ChukModelSpec(model_id=model_id, **spec), base_url=BASE_URL, transport=recorder
    )


def _echo_registry() -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "lookup_code",
        {
            "description": "Look up the secret code word for a city. Always use it when asked for a code.",
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
        lambda city="": {"city": city, "code": f"ZEBRA-{len(city)}"},
    )
    return reg


@pytest.mark.parametrize("model_id", MODELS)
def test_live_gate1_deltas_reasoning_and_a_tool_round(tmp_path, session, model_id):
    recorder = Recorder()
    model, settings = _model(session, model_id, recorder, reasoning_effort="low")
    frames: list[tuple[str, str]] = []
    tools: list[dict] = []
    store = StateStore(str(tmp_path / "s.db"))
    loop = AgentLoop(
        model,
        _echo_registry(),
        store,
        model_settings=settings,
        on_delta=lambda t: frames.append(("delta", t)),
        on_reasoning=lambda t: frames.append(("reasoning", t)),
        tool_event_observer=tools.append,
        max_iterations=6,
    )
    started = time.monotonic()
    result = loop.run("live1", "What is the secret code word for Paris? Use the tool, then answer in one short sentence.")
    elapsed = time.monotonic() - started

    assert result.reason is StopReason.FINISHED, result
    assert [t["name"] for t in tools][:1] == ["lookup_code"], tools
    assert "ZEBRA-5" in (result.final_answer or "")
    deltas = [t for kind, t in frames if kind == "delta"]
    assert len(deltas) > 1, "the answer did not stream in chunks"
    assert "".join(deltas).strip() == (result.final_answer or "").strip()
    assert result.tokens_spent > 0
    assert all(s == 200 for s in recorder.statuses)
    assert all(b["model"] == model_id and b["stream"] is True for b in recorder.bodies)
    rows = [m.content for m in store.get_conversation(result.session_id)]
    assert rows[-1]["role"] == "assistant" and rows[-1]["content"]
    reasoning = [t for kind, t in frames if kind == "reasoning"]
    print(
        f"\n[{model_id}] {elapsed:.1f}s rounds={result.iterations} tokens={result.tokens_spent} "
        f"delta_chunks={len(deltas)} reasoning_chunks={len(reasoning)}"
    )


@pytest.mark.parametrize("model_id", MODELS[:1])
def test_live_gate2_publish_asks_and_the_same_run_goes_on(tmp_path, session, model_id, monkeypatch):
    import chuk_agents_runtime.herenow as herenow

    modes: list[str] = []

    def fake_publisher(env, mode, config, args):
        modes.append(mode)
        if mode == "scan":
            return {"ok": True, "file_count": 1, "total_bytes": 42}
        return {"ok": True, "url": "https://demo.here.now", "anonymous": False, "file_count": 1}

    monkeypatch.setattr(herenow, "_run_publisher", fake_publisher)
    config = HereNowConfig(enabled=True, approval="ask")
    reg = ToolRegistry()
    register_herenow_tools(reg, None, config, gate=lambda r: True)
    asked: list[PublishRequest] = []

    def gate(request: PublishRequest) -> bool:
        asked.append(request)
        time.sleep(0.5)  # the user reads the dialog
        return True

    policy = ApprovalPolicy()
    policy.add("herenow_publish", herenow_rule(None, config, gate))
    model, settings = _model(session, model_id, Recorder())
    loop = AgentLoop(model, reg, StateStore(str(tmp_path / "s.db")), model_settings=settings, approval_policy=policy, max_iterations=5)
    result = loop.run("live2", "Publish the folder `site` with herenow_publish (name: Demo) and tell me the URL.")
    assert asked and asked[0].path == "site"
    assert modes[-1] == "publish"
    assert result.reason is StopReason.FINISHED
    assert "demo.here.now" in (result.final_answer or "")


@pytest.mark.parametrize("model_id", MODELS[:1])
def test_live_gate3_the_secret_never_goes_on_the_wire(tmp_path, session, model_id):
    secret = "sk-live-" + "9f3a" * 6
    reg = ToolRegistry()
    register_secrets_tools(reg, DictSecrets({"DEMO_API_KEY": secret}))
    reg.register(
        "read_config",
        {"description": "Read the app config file.", "type": "object", "properties": {}},
        lambda: {"stdout": f"API_KEY={secret}\nREGION=eu", "exit_code": 0},
    )
    recorder = Recorder()
    model, settings = _model(session, model_id, recorder)
    frames: list[str] = []
    tools: list[dict] = []
    store = StateStore(str(tmp_path / "s.db"))
    loop = AgentLoop(
        model, reg, store, model_settings=settings, on_delta=frames.append,
        tool_event_observer=tools.append, persist_filter=reg.result_filter, max_iterations=5,
    )
    result = loop.run("live3", f"My key is {secret}. Call read_config and tell me the REGION.")
    assert result.reason is StopReason.FINISHED
    assert secret not in json.dumps(recorder.bodies)
    assert "[REDACTED:DEMO_API_KEY]" in json.dumps(recorder.bodies)
    assert secret not in json.dumps([m.content for m in store.get_conversation(result.session_id)])
    assert secret not in json.dumps(tools)


@pytest.mark.parametrize("model_id", MODELS[:1])
def test_live_gate4_stop_during_a_long_command(tmp_path, session, model_id):
    env = CancellableEnv(cwd=str(tmp_path))
    reg = ToolRegistry()
    register_builtin_tools(reg, env)
    kill = KillSwitch()
    kill.on_interrupt(env.cancel)
    marker = tmp_path / "pid"
    model, settings = _model(session, model_id, Recorder())
    loop = AgentLoop(model, reg, StateStore(str(tmp_path / "s.db")), model_settings=settings, kill_switch=kill, max_iterations=5)
    pressed: list[float] = []

    def stop_when_running() -> None:
        deadline = time.monotonic() + 90
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(0.3)
        pressed.append(time.monotonic())
        kill.interrupt()

    threading.Thread(target=stop_when_running, daemon=True).start()
    result = loop.run(
        "live4",
        f"Run exactly this command with run_command and wait for it: echo $$ > {marker}; sleep 120; echo done",
    )
    returned = time.monotonic()
    assert pressed, "the model never started the command"
    assert result.reason is StopReason.INTERRUPTED
    assert returned - pressed[0] < 2.0
    pid = int(marker.read_text().strip())
    assert not Path(f"/proc/{pid}").exists() or open(f"/proc/{pid}/stat").read().split()[2] == "Z"
    rows = [m.content for m in loop.store.get_conversation(result.session_id) if m.content.get("role") == "tool"]
    assert rows and (rows[-1]["content"] == INTERRUPTED_TOOL_RESULT or "done" not in json.dumps(rows[-1]["content"]))


@pytest.mark.parametrize("model_id", MODELS)
def test_live_gate5_tool_search_over_many_tools(tmp_path, session, model_id):
    reg = ToolRegistry()
    topics = ["weather", "stocks", "flights", "hotels", "recipes", "news", "sports", "movies", "music", "books"]
    for index in range(60):
        topic = topics[index % len(topics)]
        name = f"mcp__hub__{topic}_{index:02d}"
        description = f"[MCP: hub] Look up {topic} data, dataset {index}."
        handler = (lambda i: (lambda query="": {"dataset": i, "query": query}))(index)
        if index == 37:
            name = "mcp__crm__create_invoice"
            description = "[MCP: crm] Create an invoice for a customer. Returns the invoice number."
            handler = lambda customer="", amount=0, query="": {"invoice": "INV-7788", "customer": customer, "amount": amount}  # noqa: E731
        reg.register(
            name,
            {"description": description, "type": "object", "properties": {"customer": {"type": "string"}, "amount": {"type": "number"}, "query": {"type": "string"}}},
            handler,
            deferrable=True,
        )
        reg.defer(name)
    recorder = Recorder()
    model, settings = _model(session, model_id, recorder)
    tools: list[dict] = []
    loop = AgentLoop(model, reg, StateStore(str(tmp_path / "s.db")), model_settings=settings, deferred_mode="pai", tool_event_observer=tools.append, max_iterations=8)
    result = loop.run("live5", "Create an invoice for customer ACME over 120 and tell me the invoice number.")
    names = [t["name"] for t in tools]
    first_tools = [t["function"]["name"] for t in recorder.bodies[0].get("tools", [])]
    assert "search_tools" in first_tools
    assert not any(n.startswith("mcp__") for n in first_tools)
    assert "search_tools" in names, names
    assert "mcp__crm__create_invoice" in names, names
    assert "INV-7788" in (result.final_answer or "")
    assert names.count("mcp__crm__create_invoice") == 1, names  # no repeated side effect
    print(f"\n[{model_id}] tool search path: {names}")


@pytest.mark.parametrize("model_id", MODELS)
def test_live_housekeeping_complete_on_the_same_route(session, model_id):
    """The blocking path (context summary, memory extraction) on the same
    route, same auth, reasoning off and a small cap: the cheap clone."""
    from chuk_agents_runtime.backend import BackendModelClient

    client = BackendModelClient(session, model_id=model_id, reasoning_effort="high").cheap_clone(max_tokens=64)
    response = client.complete(
        [
            {"role": "system", "content": "Answer with one word."},
            {"role": "user", "content": "What colour is a clear daytime sky?"},
        ]
    )
    assert response.text and "blue" in response.text.lower()
    assert response.raw["usage"]["total_tokens"] > 0
