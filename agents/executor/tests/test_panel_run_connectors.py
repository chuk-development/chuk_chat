"""A run with no forwarded connectors keeps the session's connectors.

A message from the browser panel (or an automation, a mail, Telegram) carries
no ``mcp_servers``. The run path then adds the browser entry to what the
session's last task forwarded. Before the fix, the run built a manager from the
browser entry alone: the session's cached manager was replaced by one without
the other connectors. Managers are built but never started here: no network,
no subprocess.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import Executor, loopback_pair
from chuk_agents_executor import user_browser as ub
from chuk_agents_executor.executor import _Run

from wiring import paired_channel

FIXTURE = Path(__file__).resolve().parents[3] / "test/fixtures/mcp_forward_payload.json"
BROWSER = {"name": "playwright", "command": sys.executable, "args": ["browser.py"]}


def _servers() -> list[dict]:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["mcp_servers"]


def _executor(tmp_path) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    return Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=lambda: None,
    )


def _run(origin: str, mcp_servers: list[dict] | None) -> _Run:
    return _Run(
        request_id="t", session_key="s", prompt="hi", kill=None,
        mcp_servers=mcp_servers, origin=origin,
    )


def _manager_for(executor: Executor, run: _Run):
    """What the run path does: the forwarded list plus the browser entry."""
    servers = executor._forwarded_mcp_servers(run, "s") + [dict(BROWSER)]
    return executor._session_mcp_manager("s", servers)


def test_a_panel_run_keeps_the_sessions_connectors_and_the_cache(tmp_path):
    executor = _executor(tmp_path)
    try:
        first = _manager_for(executor, _run("app", _servers()))
        assert first is not None
        names = {c.name for c in first.configs}
        assert "playwright" in names and len(names) > 1

        panel = _manager_for(executor, _run(ub.PANEL_ORIGIN, None))
        assert panel is first
        assert {c.name for c in panel.configs} == names
        assert executor._mcp_managers["s"] is first
    finally:
        executor._close_mcp_managers()


def test_other_connectorless_origins_keep_them_too(tmp_path):
    executor = _executor(tmp_path)
    try:
        first = _manager_for(executor, _run("app", _servers()))
        for origin in ("automation", "telegram"):
            assert _manager_for(executor, _run(origin, None)) is first
    finally:
        executor._close_mcp_managers()


def test_an_app_task_with_an_empty_list_still_disconnects(tmp_path):
    executor = _executor(tmp_path)
    try:
        _manager_for(executor, _run("app", _servers()))
        assert executor._forwarded_mcp_servers(_run("app", []), "s") == []
        # The app's empty list is the new choice: a later panel run has only
        # the browser.
        panel = _manager_for(executor, _run(ub.PANEL_ORIGIN, None))
        assert {c.name for c in panel.configs} == {"playwright"}
    finally:
        executor._close_mcp_managers()


def test_an_app_task_without_a_list_does_not_borrow_one(tmp_path):
    executor = _executor(tmp_path)
    _manager_for(executor, _run("app", _servers()))
    assert executor._forwarded_mcp_servers(_run("app", None), "s") == []
    executor._close_mcp_managers()
