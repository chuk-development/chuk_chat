"""MCP credential forwarding (§9, §10): the ``mcp_servers`` list rides inside the
sealed task frame, and the executor turns it into a per-session ``MCPManager``
with the right bearer attached.

No network: the bearer-selection and per-session lifetime are asserted on the
built ``MCPManager`` (its configs are inspected, never started), and the one
end-to-end task drives a real loop against a stdio MCP subprocess — the same
no-socket pattern the agent's own MCP tests use.
"""

from __future__ import annotations

import sys
from pathlib import Path

from cowork_agent import MockModelClient, tool_call_response
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.protocol import decode_payload, encode_payload, task_payload

from wiring import paired_channel

FAKE_STDIO = str(Path(__file__).parent / "fake_mcp_stdio.py")


# -- protocol: the additive task field ------------------------------------


def test_task_payload_carries_mcp_servers_round_trip():
    servers = [
        {"name": "gh", "url": "https://api.example/v1/mcp/github",
         "transport": "http", "auth": "appSession"},
    ]
    payload = task_payload("do it", "s", mcp_servers=servers)
    restored = decode_payload(encode_payload(payload))
    assert restored["type"] == "task"
    assert restored["prompt"] == "do it"
    assert restored["session_key"] == "s"
    assert restored["mcp_servers"] == servers


def test_task_payload_without_mcp_servers_is_unchanged():
    # Byte-for-byte the old frame: no stray key, behavior unchanged.
    assert task_payload("hi") == {"type": "task", "prompt": "hi", "session_key": "default"}
    assert "mcp_servers" not in task_payload("hi", mcp_servers=None)
    assert "mcp_servers" not in task_payload("hi", mcp_servers=[])


# -- per-session MCPManager wiring ----------------------------------------


def _executor(tmp_path, *, account_token="ACCOUNT-BEARER") -> Executor:
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    return Executor(
        name="ex",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
        account_token_provider=(lambda: account_token) if account_token else None,
    )


def test_session_manager_selects_bearer_by_auth(tmp_path):
    ex = _executor(tmp_path, account_token="ACCT")
    manager = ex._session_mcp_manager(
        "s",
        [
            {"name": "gh", "url": "https://x/v1/mcp/github",
             "transport": "http", "auth": "appSession"},
            {"name": "tickets", "url": "https://y/mcp",
             "transport": "http", "auth": "oauth", "access_token": "DEV-TOK"},
        ],
    )
    assert manager is not None
    by_name = {c.name: c for c in manager.configs}
    # appSession -> the executor's account bearer; oauth -> the forwarded token.
    assert by_name["gh"].auth_token == "ACCT"
    assert by_name["tickets"].auth_token == "DEV-TOK"
    ex._close_mcp_managers()


def test_session_manager_appsession_without_account_is_unauthed(tmp_path):
    ex = _executor(tmp_path, account_token=None)
    manager = ex._session_mcp_manager(
        "s", [{"name": "gh", "url": "https://x/mcp", "auth": "appSession"}]
    )
    assert manager is not None
    assert manager.configs[0].auth_token is None
    ex._close_mcp_managers()


def test_session_manager_is_reused_and_rebuilt(tmp_path):
    ex = _executor(tmp_path)
    entries = [{"name": "a", "url": "https://x/mcp", "auth": "none"}]
    first = ex._session_mcp_manager("s", entries)
    second = ex._session_mcp_manager("s", list(entries))
    # Same session, same connections -> the same manager object, not a rebuild.
    assert first is second
    # A changed connection set rebuilds the manager (the UI edited it).
    third = ex._session_mcp_manager(
        "s", [{"name": "b", "url": "https://z/mcp", "auth": "none"}]
    )
    assert third is not first
    ex._close_mcp_managers()


def test_session_manager_absent_is_none(tmp_path):
    ex = _executor(tmp_path)
    assert ex._session_mcp_manager("s", None) is None
    assert ex._session_mcp_manager("s", []) is None


def test_session_manager_bad_entries_are_not_fatal(tmp_path):
    ex = _executor(tmp_path)
    # One good, several broken: the manager holds only the good one.
    manager = ex._session_mcp_manager(
        "s",
        [
            {"name": "good", "url": "https://ok/mcp", "auth": "none"},
            {"url": "https://noname/mcp"},   # missing name
            {"name": "bad", "url": "ftp://nope"},
            "not-an-object",
        ],
    )
    assert manager is not None
    assert [c.name for c in manager.configs] == ["good"]
    # All-bad -> no manager cached, task runs without MCP.
    assert ex._session_mcp_manager("s2", [{"url": "ftp://x"}]) is None
    ex._close_mcp_managers()


# -- end to end: a forwarded server's tool is live in the task ------------


def test_forwarded_server_tool_is_registered_and_dispatchable(tmp_path):
    """A task whose frame carries an ``mcp_servers`` list runs a loop in which the
    forwarded server's tool is registered and callable — proven by dispatching it
    on the session's live manager after the run."""
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    def factory() -> MockModelClient:
        # Turn 1 calls the forwarded MCP tool; turn 2 finishes.
        return MockModelClient(
            [
                tool_call_response(("mcp__fake__shout", {"text": "via mcp"})),
                "done",
            ]
        )

    executor = Executor(
        name="ex",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=factory,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        request_id = controller.send_payload(
            task_payload(
                "use the tool",
                "thread-1",
                mcp_servers=[
                    {
                        "name": "fake",
                        "command": sys.executable,
                        "args": [FAKE_STDIO],
                        "auth": "none",
                        "connect_timeout": 30.0,
                        "call_timeout": 30.0,
                    }
                ],
            )
        )
        events = controller.collect(request_id, timeout=30.0)

        assert events[-1]["type"] == "done"
        # The session's manager was built from the forwarded entry and its tool
        # is live and dispatchable.
        manager = executor._mcp_managers["thread-1"]
        assert manager.is_alive("fake")
        assert manager.call("fake", "shout", {"text": "hi"})["content"] == "HI"
    finally:
        executor.stop()

    # stop() closed the per-session managers.
    assert executor._mcp_managers == {}
