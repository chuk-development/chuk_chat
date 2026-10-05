"""One sandbox browser per box, shared by the threads of its coworker, started
on first use (bead chuk_chat-wrdv, ``chuk_agents_executor.box_browser``).

The box has one Chromium profile and its owner script refuses a second
Playwright MCP server on it. These tests stand in for that server with a fake
that refuses a second live owner the same way.
"""

from __future__ import annotations

import threading
import time

import pytest
from chuk_agents_runtime import (
    MCPToolInfo,
    MockModelClient,
    ToolRegistry,
    open_browser_gui_async,
    register_mcp_tools,
)

from chuk_agents_executor import Executor, loopback_pair
from chuk_agents_executor import box_browser as box_mod
from chuk_agents_executor.box_browser import BoxBrowser, box_of

from wiring import paired_channel

TOOLS = ["browser_navigate", "browser_tabs", "browser_click"]


class _Box:
    """The box's profile: at most one live server may own it."""

    def __init__(self) -> None:
        self.owner: _FakeServer | None = None
        self.started = 0
        self.active_calls = 0
        self.max_parallel = 0
        self.lock = threading.Lock()


class _FakeServer:
    """A Playwright MCP server over ``docker exec``; refuses a second owner
    like ``browser-mcp-owner.py`` does."""

    box = _Box()

    def __init__(self, config, **_kw) -> None:
        self.config = config
        self._alive = False
        self.error = None
        self.calls: list[tuple[str, dict]] = []

    @property
    def tools(self) -> list[MCPToolInfo]:
        return [MCPToolInfo(name=t, description=t, schema={"type": "object"}) for t in TOOLS]

    def start(self) -> bool:
        box = self.box
        with box.lock:
            if box.owner is not None and box.owner._alive:
                self.error = "browser profile still has a live owner"
                return False
            box.owner = self
            box.started += 1
        self._alive = True
        return True

    def alive(self) -> bool:
        return self._alive

    def call(self, tool: str, arguments: dict | None = None) -> dict:
        box = self.box
        with box.lock:
            box.active_calls += 1
            box.max_parallel = max(box.max_parallel, box.active_calls)
        time.sleep(0.02)
        with box.lock:
            box.active_calls -= 1
        self.calls.append((tool, dict(arguments or {})))
        return {"ok": True, "server": self.config.name, "tool": tool, "content": "done"}

    def close(self) -> None:
        self._alive = False


@pytest.fixture(autouse=True)
def fake_server(monkeypatch):
    _FakeServer.box = _Box()
    monkeypatch.setattr(box_mod, "MCPConnection", _FakeServer)
    return _FakeServer.box


class _FakeCli:
    binary = "docker"


class _FakeDockerEnv:
    def __init__(self) -> None:
        self._cli = _FakeCli()
        self._user = "agents"
        self.container_id = "cid-box1"

    def run_bash(self, cmd, *, timeout=120, internal=False):  # noqa: ANN001
        return None

    def cleanup(self) -> None:
        pass


def _executor(tmp_path) -> Executor:
    channel = paired_channel()
    _c, executor_ep = loopback_pair()
    return Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=_FakeDockerEnv(),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
        browser_mcp=True,
    )


def _task_registry(executor: Executor, session_key: str) -> ToolRegistry:
    """What a task of ``session_key`` gets: its manager, started and
    registered, like ``build_runtime`` does."""
    manager = executor._session_mcp_manager(session_key, [executor._browser_mcp_entry(session_key)])
    registry = ToolRegistry()
    register_mcp_tools(registry, manager)
    return registry


def test_two_threads_of_one_coworker_both_get_the_browser(tmp_path, fake_server):
    executor = _executor(tmp_path)
    try:
        first = _task_registry(executor, "thread-a")
        second = _task_registry(executor, "thread-b")
        for registry in (first, second):
            assert registry.has("mcp__playwright__browser_navigate")
            assert registry.available("mcp__playwright__browser_navigate")
        a = first.dispatch("mcp__playwright__browser_navigate", {"url": "https://a.example"})
        b = second.dispatch("mcp__playwright__browser_navigate", {"url": "https://b.example"})
        assert a["ok"] is True and b["ok"] is True
        # One server for the box; nobody was refused the profile.
        assert fake_server.started == 1
        assert [c[1]["url"] for c in fake_server.owner.calls] == [
            "https://a.example",
            "https://b.example",
        ]
    finally:
        executor._close_mcp_managers()
    assert fake_server.owner._alive is False  # executor stop stops the server


def test_a_thread_that_never_browses_starts_nothing(tmp_path, fake_server):
    """The tool list of the first connection is kept, so a later host start
    registers the browser tools without starting a server: the server starts
    on the first browser call, not with the task."""
    learning = _executor(tmp_path)
    try:
        _task_registry(learning, "thread-a")  # first connection ever: learns the tools
    finally:
        learning._close_mcp_managers()
    assert fake_server.started == 1

    fake_server.owner = None
    restarted = _executor(tmp_path)  # the same state dir: the cached tool list
    try:
        registry = _task_registry(restarted, "mail:x")
        assert registry.has("mcp__playwright__browser_click")
        assert registry.available("mcp__playwright__browser_click")
        # Auto-open at task start leaves an unstarted browser alone.
        manager = restarted._mcp_managers["mail:x"]
        assert open_browser_gui_async(manager) is None
        assert fake_server.started == 1  # nothing new started
        result = registry.dispatch("mcp__playwright__browser_click", {"ref": "e1"})
        assert result["ok"] is True
        assert fake_server.started == 2  # started on first use
    finally:
        restarted._close_mcp_managers()


def test_a_rebuilt_thread_manager_does_not_stop_the_shared_server(tmp_path, fake_server):
    executor = _executor(tmp_path)
    try:
        first = _task_registry(executor, "thread-a")
        _task_registry(executor, "thread-b")
        # thread-b's connectors go away: its manager is closed.
        executor._session_mcp_manager("thread-b", None)
        assert first.dispatch("mcp__playwright__browser_tabs", {"action": "list"})["ok"] is True
        assert fake_server.started == 1
    finally:
        executor._close_mcp_managers()


def test_the_live_view_starts_the_box_browser(tmp_path, fake_server, monkeypatch):
    """Opening the view is a use: an unstarted box browser starts, so its
    launcher brings the display up for the view to serve."""
    executor = _executor(tmp_path)
    try:
        _task_registry(executor, "thread-a")  # learn the tools
        executor._close_mcp_managers()
        fake_server.owner = None
        _task_registry(executor, "thread-a")  # a task that does not browse
        assert fake_server.started == 1
        assert not executor._box_browsers["cid-box1"].launched
        executor._launch_box_browser("cid-box1")
        assert executor._box_browsers["cid-box1"].launched
        monkeypatch.setenv("AGENTS_BROWSER_AUTO_OPEN", "0")
        executor._box_browsers["cid-box1"]._conn.close()
        executor._launch_box_browser("cid-box1")  # the switch keeps it lazy
        assert not executor._box_browsers["cid-box1"].launched
    finally:
        executor._close_mcp_managers()


def test_calls_from_two_threads_run_one_at_a_time(fake_server):
    from chuk_agents_runtime import MCPServerConfig

    config = MCPServerConfig(
        name="playwright", command="docker", args=["exec", "-i", "cid-x", "agents-browser-mcp"]
    )
    shared = BoxBrowser(config)
    threads = [
        threading.Thread(target=shared.call, args=("browser_click", {"ref": f"e{i}"}))
        for i in range(4)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(5)
    assert fake_server.started == 1
    assert fake_server.max_parallel == 1
    assert len(fake_server.owner.calls) == 4
    shared.close()  # a thread's manager letting go: the server stays
    assert fake_server.owner._alive
    shared.shutdown()
    assert not fake_server.owner._alive


def test_box_of_names_only_sandbox_browser_entries():
    from chuk_agents_runtime import MCPServerConfig

    browser = MCPServerConfig(
        name="playwright", command="docker",
        args=["exec", "-i", "-u", "agents", "cid-1", "agents-browser-mcp"],
    )
    extension = MCPServerConfig(name="playwright", command="agents-extension-mcp", args=[])
    remote = MCPServerConfig(name="crm", url="https://crm.example/mcp")
    assert box_of(browser) == "cid-1"
    assert box_of(extension) is None
    assert box_of(remote) is None


def test_a_failed_start_is_reported_and_tried_again(fake_server, tmp_path):
    from chuk_agents_runtime import MCPServerConfig

    config = MCPServerConfig(
        name="playwright", command="docker", args=["exec", "-i", "cid-y", "agents-browser-mcp"]
    )
    blocker = _FakeServer(config)
    assert blocker.start()  # someone else owns the profile
    shared = BoxBrowser(config, tools_path=str(tmp_path / "tools.json"))
    assert shared.start() is False
    assert "live owner" in (shared.error or "")
    assert shared.call("browser_tabs", {})["ok"] is False
    blocker.close()
    assert shared.start() is True
    assert shared.call("browser_tabs", {})["ok"] is True


def test_two_executors_on_one_box_share_its_browser(tmp_path, fake_server):
    """Two executors in one process that serve the same box (each roster
    agent has its own executor) still start one server; the last one to stop
    stops it."""
    one, two = _executor(tmp_path), _executor(tmp_path)
    try:
        a = _task_registry(one, "thread-a")
        b = _task_registry(two, "thread-b")
        assert a.dispatch("mcp__playwright__browser_tabs", {"action": "list"})["ok"] is True
        assert b.dispatch("mcp__playwright__browser_tabs", {"action": "list"})["ok"] is True
        assert fake_server.started == 1
        one._close_mcp_managers()
        assert fake_server.owner._alive  # two still holds the box
        assert b.dispatch("mcp__playwright__browser_tabs", {"action": "list"})["ok"] is True
    finally:
        one._close_mcp_managers()
        two._close_mcp_managers()
    assert not fake_server.owner._alive


def test_a_changed_schema_with_the_same_names_is_saved_again(tmp_path):
    from chuk_agents_runtime import MCPServerConfig

    path = tmp_path / "tools.json"
    old = [MCPToolInfo(name=t, description=t, schema={"type": "string"}) for t in TOOLS]
    box_mod.save_tools(str(path), old)
    assert box_mod.load_tools(str(path))[0].schema == {"type": "string"}
    config = MCPServerConfig(
        name="playwright", command="docker", args=["exec", "-i", "cid-z", "agents-browser-mcp"]
    )
    shared = BoxBrowser(config, tools_path=str(path))
    assert shared.ensure() is True
    # The server's list has the same names but a new schema: the file follows.
    assert [t.schema for t in box_mod.load_tools(str(path))] == [{"type": "object"}] * len(TOOLS)
    assert box_mod.same_tools(shared.tools, box_mod.load_tools(str(path)))
    assert not box_mod.same_tools(old, shared.tools)


def test_save_tools_uses_its_own_temp_file_and_removes_it_on_failure(tmp_path, monkeypatch):
    path = tmp_path / "tools.json"
    tools = [MCPToolInfo(name="browser_tabs", description="d", schema={})]
    seen: list[str] = []
    real_replace = box_mod.os.replace

    def failing_replace(src, dst):
        seen.append(str(src))
        raise OSError("rename failed")

    monkeypatch.setattr(box_mod.os, "replace", failing_replace)
    box_mod.save_tools(str(path), tools)  # best effort: no raise
    assert seen and seen[0] != f"{path}.tmp"
    assert f".{box_mod.os.getpid()}.{threading.get_ident()}." in seen[0]
    assert list(tmp_path.iterdir()) == []
    monkeypatch.setattr(box_mod.os, "replace", real_replace)
    box_mod.save_tools(str(path), tools)
    assert [p.name for p in tmp_path.iterdir()] == ["tools.json"]


class _NamedDockerEnv(_FakeDockerEnv):
    """A box known by its fixed name; the container appears on first use."""

    def __init__(self) -> None:
        super().__init__()
        self.container_name = "agents-coworker-abc"
        self.container_id = None
        self.realized = 0

    def run_bash(self, cmd, *, timeout=120, internal=False):  # noqa: ANN001
        self.realized += 1
        self.container_id = "cid-real"
        return None


def _named_executor(tmp_path, env) -> Executor:
    channel = paired_channel()
    _c, executor_ep = loopback_pair()
    return Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=env,
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
        browser_mcp=True,
    )


def test_the_box_comes_up_on_the_first_browser_call_not_at_task_start(tmp_path, fake_server):
    """bead chuk_chat-5o8j: a task whose tools are known registers the browser
    without creating the container; the first browser call brings it up and
    the server execs into the real container."""
    env = _NamedDockerEnv()
    learning = _named_executor(tmp_path, env)
    try:
        _task_registry(learning, "thread-a")  # first ever: learns the tools
    finally:
        learning._close_mcp_managers()
    assert fake_server.owner.config.args[-2] == "cid-real"

    env = _NamedDockerEnv()  # the host restarted; the box is not up yet
    fake_server.owner = None
    executor = _named_executor(tmp_path, env)
    try:
        registry = _task_registry(executor, "thread-a")
        assert registry.available("mcp__playwright__browser_tabs")
        manager = executor._mcp_managers["thread-a"]
        assert manager.configs[0].args[-2] == "agents-coworker-abc"
        assert env.realized == 0 and env.container_id is None
        assert executor._browser_server_targets("thread-a", "") == []
        result = registry.dispatch("mcp__playwright__browser_tabs", {"action": "list"})
        assert result["ok"] is True
        assert env.realized == 1
        assert fake_server.owner.config.args == [
            "exec", "-i", "-u", "agents", "cid-real", "agents-browser-mcp",
        ]
        shared = executor._box_browsers["agents-coworker-abc"]
        assert shared.target == "cid-real"
        # The view finds the box by its real container.
        targets = executor._browser_server_targets("thread-a", "cid-real")
        assert [box for _p, box, _m in targets] == ["cid-real"]
    finally:
        executor._close_mcp_managers()


def test_the_live_view_starts_a_named_box_by_its_container_id(tmp_path, fake_server):
    env = _NamedDockerEnv()
    executor = _named_executor(tmp_path, env)
    try:
        _task_registry(executor, "thread-a")  # learn the tools
        executor._close_mcp_managers()
        fake_server.owner = None
        _task_registry(executor, "thread-a")  # a task that does not browse
        shared = executor._box_browsers["agents-coworker-abc"]
        assert not shared.launched
        env.run_bash("true")  # the view realized the box (_vnc_exec_prefix)
        executor._launch_box_browser("cid-real")
        assert shared.launched and shared.target == "cid-real"
    finally:
        executor._close_mcp_managers()
