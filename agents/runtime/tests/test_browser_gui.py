"""The browser always opens a GUI (bead cowork-bxvh).

The app's live view (§9.1) streams the pixels of the display the browser paints
on. Two separate things used to leave that view black, and both are pinned here:

* :class:`~cowork_agent.browser.BrowserUseRunner` launched **headless**, so its
  Chromium painted on no display at all. It is headful now, it starts a display
  when the machine has none, and it refuses rather than quietly going headless.
* The Playwright MCP server in the sandbox launches **no browser at all** until
  its first browser tool call. Until the agent browsed, the display x11vnc
  served was an empty root window. ``open_browser_gui`` makes that first call
  when the server connects.
"""

from __future__ import annotations

import subprocess
import sys
import time
import types

import pytest

from cowork_agent.browser import (
    DISPLAY_ENV_VAR,
    EXECUTABLE_ENV_VAR,
    HEADLESS_ENV_VAR,
    BrowserTaskSpec,
    BrowserUnavailable,
    BrowserUseRunner,
    display_available,
    ensure_display,
    headless_requested,
)
from cowork_agent.mcp_client import (
    BROWSER_LAUNCH_TOOL,
    BROWSER_OPEN_TOOL,
    DEFAULT_BROWSER_HOME,
    MCPManager,
    MCPToolInfo,
    auto_open_enabled,
    browser_home,
    browser_servers,
    open_browser_gui,
    open_browser_gui_async,
)

# -- a fake browser-use, just enough of it ------------------------------------


class _FakeHistory:
    def final_result(self):
        return "done"

    def is_done(self):
        return True

    def number_of_steps(self):
        return 1


class _FakeAgent:
    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.state = types.SimpleNamespace(n_steps=1)

    async def run(self, max_steps=None):
        return _FakeHistory()

    async def close(self):
        return None


@pytest.fixture
def fake_browser_use(monkeypatch):
    """Install a ``browser_use`` that records the profile it was handed."""
    seen: dict = {}

    class FakeProfile:
        def __init__(self, **kwargs):
            seen.clear()
            seen.update(kwargs)

    class FakeSession:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    module = types.ModuleType("browser_use")
    module.BrowserSession = FakeSession
    module.Agent = _FakeAgent
    browser_pkg = types.ModuleType("browser_use.browser")
    profile_mod = types.ModuleType("browser_use.browser.profile")
    profile_mod.BrowserProfile = FakeProfile
    monkeypatch.setitem(sys.modules, "browser_use", module)
    monkeypatch.setitem(sys.modules, "browser_use.browser", browser_pkg)
    monkeypatch.setitem(sys.modules, "browser_use.browser.profile", profile_mod)
    return seen


@pytest.fixture
def chromium(tmp_path, monkeypatch):
    binary = tmp_path / "chromium"
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    monkeypatch.setenv(EXECUTABLE_ENV_VAR, str(binary))
    return str(binary)


def run_once(runner, spec=None):
    import asyncio

    spec = spec or BrowserTaskSpec(
        task="look", start_url="https://example.com", max_steps=2, allowed_domains=["example.com"]
    )
    return asyncio.run(runner.run(spec, llm=object()))


# -- the runner launches headful ----------------------------------------------


def test_the_browser_is_not_launched_headless(fake_browser_use, chromium, monkeypatch):
    """The regression this bead is about: ``headless=True`` was the default."""
    monkeypatch.delenv(HEADLESS_ENV_VAR, raising=False)
    displays: list[str] = []
    monkeypatch.setattr(
        "cowork_agent.browser.ensure_display", lambda: displays.append(":99") or ":99"
    )

    run_once(BrowserUseRunner())

    assert fake_browser_use["headless"] is False
    assert displays == [":99"], "a headful launch must make sure a display exists"


def test_headless_is_possible_but_has_to_be_asked_for(
    fake_browser_use, chromium, monkeypatch
):
    monkeypatch.setenv(HEADLESS_ENV_VAR, "1")
    monkeypatch.setattr(
        "cowork_agent.browser.ensure_display",
        lambda: pytest.fail("headless must not start a display"),
    )

    run_once(BrowserUseRunner())

    assert fake_browser_use["headless"] is True


def test_an_explicit_argument_still_wins_over_the_environment(
    fake_browser_use, chromium, monkeypatch
):
    monkeypatch.setenv(HEADLESS_ENV_VAR, "1")
    monkeypatch.setattr("cowork_agent.browser.ensure_display", lambda: ":99")

    run_once(BrowserUseRunner(headless=False))

    assert fake_browser_use["headless"] is False


def test_an_attached_browser_needs_no_display_of_ours(
    fake_browser_use, monkeypatch
):
    """With a CDP endpoint the browser is somebody else's process."""
    monkeypatch.delenv(HEADLESS_ENV_VAR, raising=False)
    monkeypatch.setattr(
        "cowork_agent.browser.ensure_display",
        lambda: pytest.fail("a CDP browser paints on its own display"),
    )

    run_once(BrowserUseRunner(cdp_url="http://127.0.0.1:9222"))

    assert fake_browser_use["headless"] is False


def test_a_finished_run_reports_its_step_count(fake_browser_use, chromium, monkeypatch):
    """``n_steps`` sat after a ``raise`` and was never read on the success path."""
    monkeypatch.setattr("cowork_agent.browser.ensure_display", lambda: ":99")

    outcome = run_once(BrowserUseRunner())

    assert outcome.budget_exhausted is False


@pytest.mark.parametrize(
    "raw,expected",
    [("", False), ("0", False), ("no", False), ("1", True), ("true", True), ("ON", True)],
)
def test_headless_requested_reads_the_switch(raw, expected):
    assert headless_requested(raw) is expected


# -- the display -------------------------------------------------------------


def test_a_live_display_is_used_as_it_is(monkeypatch):
    monkeypatch.setenv(DISPLAY_ENV_VAR, ":7")
    monkeypatch.setattr("cowork_agent.browser.display_available", lambda name=None: True)
    monkeypatch.setattr(
        "cowork_agent.browser.start_xvfb",
        lambda **kw: pytest.fail("a working display must not be replaced"),
    )

    assert ensure_display() == ":7"


def test_a_missing_display_is_started_not_worked_around(monkeypatch):
    monkeypatch.delenv(DISPLAY_ENV_VAR, raising=False)
    monkeypatch.setattr("cowork_agent.browser.display_available", lambda name=None: False)
    monkeypatch.setattr("cowork_agent.browser.start_xvfb", lambda **kw: ":99")

    import os

    assert ensure_display() == ":99"
    assert os.environ[DISPLAY_ENV_VAR] == ":99"


def test_no_display_and_no_xvfb_is_an_error_not_a_silent_headless(monkeypatch):
    monkeypatch.delenv(DISPLAY_ENV_VAR, raising=False)
    monkeypatch.setattr("cowork_agent.browser.display_available", lambda name=None: False)
    monkeypatch.setattr("cowork_agent.browser.start_xvfb", lambda **kw: None)

    with pytest.raises(BrowserUnavailable) as excinfo:
        ensure_display()
    assert HEADLESS_ENV_VAR in str(excinfo.value)


def test_an_unset_display_is_never_available(monkeypatch):
    monkeypatch.delenv(DISPLAY_ENV_VAR, raising=False)
    assert display_available() is False


def test_a_dead_display_is_reported_dead(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: "/usr/bin/xdpyinfo")
    monkeypatch.setattr(
        "subprocess.run",
        lambda *a, **k: subprocess.CompletedProcess(a[0], 1, b"", b"cannot open display"),
    )
    assert display_available(":123") is False


# -- the MCP browser server is opened on sight --------------------------------


class _FakeConnection:
    """The slice of :class:`MCPConnection` the opener touches."""

    def __init__(self, name: str, tools: list[str], *, alive: bool = True):
        self.config = types.SimpleNamespace(name=name)
        self.tools = [MCPToolInfo(name=tool, description="", schema={}) for tool in tools]
        self._alive = alive
        self.calls: list[tuple[str, dict]] = []

    def alive(self) -> bool:
        return self._alive

    def call(self, tool: str, arguments: dict | None = None) -> dict:
        self.calls.append((tool, dict(arguments or {})))
        return {"ok": True, "server": self.config.name, "tool": tool, "content": ""}


def manager_with(*connections: _FakeConnection) -> MCPManager:
    manager = MCPManager([])
    for connection in connections:
        manager.connections[connection.config.name] = connection  # type: ignore[assignment]
    return manager


PLAYWRIGHT_TOOLS = [BROWSER_OPEN_TOOL, BROWSER_LAUNCH_TOOL, "browser_click"]


def test_a_browser_server_is_recognised_by_its_tools():
    browser = _FakeConnection("playwright", PLAYWRIGHT_TOOLS)
    other = _FakeConnection("records", ["search"])

    assert browser_servers(manager_with(browser, other)) == ["playwright"]


def test_a_dead_browser_server_is_not_poked():
    dead = _FakeConnection("playwright", PLAYWRIGHT_TOOLS, alive=False)
    assert browser_servers(manager_with(dead)) == []


def test_opening_the_gui_touches_no_page_the_last_task_left_open():
    """Listing the tabs launches the browser (measured against the real image)
    and, unlike a navigation, throws nothing away."""
    browser = _FakeConnection("playwright", PLAYWRIGHT_TOOLS)
    other = _FakeConnection("records", ["search"])

    opened = open_browser_gui(manager_with(browser, other))

    assert opened == ["playwright"]
    assert browser.calls == [(BROWSER_OPEN_TOOL, {"action": "list"})]
    assert other.calls == []


def test_a_server_without_the_tab_tool_is_opened_by_a_navigation(monkeypatch):
    monkeypatch.delenv("COWORK_BROWSER_HOME", raising=False)
    browser = _FakeConnection("playwright", [BROWSER_LAUNCH_TOOL])

    assert open_browser_gui(manager_with(browser)) == ["playwright"]
    assert browser.calls == [(BROWSER_LAUNCH_TOOL, {"url": DEFAULT_BROWSER_HOME})]


def test_a_browser_that_refuses_to_open_does_not_raise():
    class Refusing(_FakeConnection):
        def call(self, tool, arguments=None):
            super().call(tool, arguments)
            return {"ok": False, "error": "browser launch failed"}

    browser = Refusing("playwright", PLAYWRIGHT_TOOLS)

    assert open_browser_gui(manager_with(browser)) == []
    assert browser.calls, "it was still tried"


def test_the_fallback_landing_page_can_be_configured(monkeypatch):
    monkeypatch.setenv("COWORK_BROWSER_HOME", "https://example.com/start")
    assert browser_home() == "https://example.com/start"
    browser = _FakeConnection("playwright", [BROWSER_LAUNCH_TOOL])
    open_browser_gui(manager_with(browser))
    assert browser.calls[0][1] == {"url": "https://example.com/start"}


def test_the_open_runs_off_the_critical_path(monkeypatch):
    monkeypatch.delenv("COWORK_BROWSER_AUTO_OPEN", raising=False)
    browser = _FakeConnection("playwright", PLAYWRIGHT_TOOLS)

    thread = open_browser_gui_async(manager_with(browser))

    assert thread is not None and thread.daemon
    thread.join(timeout=5)
    assert browser.calls, "the window is opened, just not on the caller's thread"


def test_without_a_browser_server_nothing_is_started():
    assert open_browser_gui_async(manager_with(_FakeConnection("records", ["search"]))) is None
    assert open_browser_gui_async(None) is None


def test_the_eager_open_can_be_turned_off(monkeypatch):
    monkeypatch.setenv("COWORK_BROWSER_AUTO_OPEN", "0")
    browser = _FakeConnection("playwright", PLAYWRIGHT_TOOLS)

    assert auto_open_enabled() is False
    assert open_browser_gui_async(manager_with(browser)) is None
    assert browser.calls == []


# -- the runtime does it without being asked ---------------------------------


def test_building_a_runtime_opens_the_browser_it_was_given(tmp_path):
    """The wiring, end to end: a session with a browser MCP server has a window
    on its display before the model has said a word."""
    from cowork_agent.model import MockModelClient
    from cowork_agent.runtime import build_runtime

    browser = _FakeConnection("playwright", PLAYWRIGHT_TOOLS)
    manager = manager_with(browser)

    loop = build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path),
        version_workspace=False,
        enable_chat_search=False,
        mcp=manager,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not browser.calls:
            time.sleep(0.02)
        assert browser.calls == [(BROWSER_OPEN_TOOL, {"action": "list"})]
    finally:
        loop.mcp = None  # the fakes own no transport to close


def test_a_runtime_without_a_browser_server_opens_nothing(tmp_path):
    from cowork_agent.model import MockModelClient
    from cowork_agent.runtime import build_runtime

    other = _FakeConnection("records", ["search"])
    loop = build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path),
        version_workspace=False,
        enable_chat_search=False,
        mcp=manager_with(other),
    )
    loop.mcp = None
    time.sleep(0.2)
    assert other.calls == []
