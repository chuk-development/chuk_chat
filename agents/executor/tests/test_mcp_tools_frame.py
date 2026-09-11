"""The ``mcp_tools`` frame (docs/WIRE_CONTRACT.md).

The app never dials an MCP server: it forwards the connectors and the host does
the dialling, so the app cannot know what a connector offers. Its list therefore
said "0 tools" next to servers that were connected and working. This frame is
the answer coming back — one per task, every connector of the session, including
the ones that refused.
"""

from __future__ import annotations

from types import SimpleNamespace

from cowork_sandbox import LocalEnvironment

from cowork_executor import Executor, loopback_pair
from cowork_executor.protocol import mcp_tools_payload

from wiring import paired_channel


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


def _capture(executor: Executor, monkeypatch) -> list[tuple[str, dict]]:
    sent: list[tuple[str, dict]] = []
    monkeypatch.setattr(executor, "_event", lambda rid, payload: sent.append((rid, payload)))
    return sent


class _FakeManager:
    def __init__(self, connections):
        self.connections = connections


def _connection(tools, error=None):
    return SimpleNamespace(
        tools=[SimpleNamespace(name=name, description=desc) for name, desc in tools],
        error=error,
    )


def test_the_payload_carries_one_entry_per_server():
    payload = mcp_tools_payload(
        session_key="s",
        servers=[{"id": "github", "name": "GitHub", "connected": True, "tools": []}],
    )
    assert payload["type"] == "mcp_tools"
    assert payload["session_key"] == "s"
    assert payload["servers"][0]["id"] == "github"


def test_a_connected_server_reports_its_tools(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    sent = _capture(executor, monkeypatch)
    executor._mcp_entry_meta["sess"] = {
        "GitHub": {"id": "conn-1", "name": "GitHub", "url": "https://mcp.github.example/"}
    }
    manager = _FakeManager(
        {"GitHub": _connection([("list_issues", "Issues of a repository")])}
    )

    executor._send_mcp_tools("sess", "req-1", manager)

    assert len(sent) == 1
    request_id, payload = sent[0]
    assert request_id == "req-1"
    entry = payload["servers"][0]
    assert entry["id"] == "conn-1"
    assert entry["connected"] is True
    assert entry["tools"] == [
        {"name": "list_issues", "description": "Issues of a repository"}
    ]
    assert "error" not in entry


def test_a_refused_server_is_reported_not_dropped(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    sent = _capture(executor, monkeypatch)
    manager = _FakeManager({"Canva": _connection([], error="401 Unauthorized")})

    executor._send_mcp_tools("sess", "req-1", manager)

    entry = sent[0][1]["servers"][0]
    assert entry["name"] == "Canva"
    assert entry["connected"] is False
    assert entry["tools"] == []
    assert entry["error"] == "401 Unauthorized"


def test_no_manager_and_no_connectors_send_nothing(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    sent = _capture(executor, monkeypatch)

    executor._send_mcp_tools("sess", "req-1", None)
    executor._send_mcp_tools("sess", "req-1", _FakeManager({}))

    assert sent == []


def test_a_probe_answers_with_a_terminal_and_never_blocks_the_loop(tmp_path, monkeypatch):
    """The app asks, the host dials, the answer is one terminal frame.

    The dial happens on its own thread, so the assertion waits for it instead of
    assuming the handler is done when it returns — that thread is the whole
    point: a server that is down costs a connect timeout.
    """
    import threading

    executor = _executor(tmp_path)
    terminals: list[tuple[str, dict]] = []
    done = threading.Event()

    def terminal(rid, payload):
        terminals.append((rid, payload))
        done.set()

    monkeypatch.setattr(executor, "_terminal", terminal)
    manager = _FakeManager({"GitHub": _connection([("list_issues", "")])})
    monkeypatch.setattr(
        executor, "_session_mcp_manager", lambda session_key, servers: manager
    )
    executor._mcp_entry_meta["sess"] = {
        "GitHub": {"id": "conn-1", "name": "GitHub", "url": "https://mcp.example/"}
    }

    executor._handle_mcp_probe(
        "req-9",
        {
            "type": "mcp_probe",
            "session_key": "sess",
            "mcp_servers": [{"id": "conn-1", "name": "GitHub", "url": "https://mcp.example/"}],
        },
    )

    assert done.wait(5), "the probe never answered"
    request_id, payload = terminals[0]
    assert request_id == "req-9"
    assert payload["type"] == "mcp_tools"
    assert payload["servers"][0]["tools"][0]["name"] == "list_issues"


def test_a_probe_without_servers_answers_at_once(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    terminals: list[tuple[str, dict]] = []
    monkeypatch.setattr(
        executor, "_terminal", lambda rid, payload: terminals.append((rid, payload))
    )

    executor._handle_mcp_probe("req-10", {"type": "mcp_probe"})

    assert terminals[0][1] == {"type": "mcp_tools", "session_key": "", "servers": []}
