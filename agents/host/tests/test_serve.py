"""TaskServer wiring — the account token reaches the Executor.

The task server forwards an ``account_token_provider`` to every Executor it
builds, so ``appSession`` MCP connectors (GitHub etc.) authenticate server-side
with the account's live access token. This proves the provider is threaded
through and is a live accessor, not a snapshot.
"""

from __future__ import annotations

from types import SimpleNamespace

import chuk_agents_host.serve as serve
from chuk_agents_host import TaskServer


class _RecordingExecutor:
    """Captures the kwargs the factory built it with, so the test can read back
    the account_token_provider without running a real agent loop."""

    last_kwargs: dict = {}

    def __init__(self, **kwargs):
        type(self).last_kwargs = kwargs

    def start(self):  # pragma: no cover - never started in this test
        pass

    def stop(self):  # pragma: no cover
        pass

    @property
    def name(self):  # pragma: no cover
        return type(self).last_kwargs.get("name", "rec")


def _make_server(provider, session_provider=None):
    return TaskServer(
        roster=None,
        agent_id="agent-1",
        opener=object(),
        sealer=object(),
        environment=object(),
        model_factory=lambda: None,
        db_path=":memory:",
        send_frame=lambda _b64: None,
        account_token_provider=provider,
        account_session_provider=session_provider,
    )


def test_task_server_forwards_a_live_account_token_provider(monkeypatch):
    monkeypatch.setattr(serve, "Executor", _RecordingExecutor)

    # A live session whose token can be refreshed; the provider reads it each call.
    session = SimpleNamespace(access_token="tok-initial")
    server = _make_server(lambda: session.access_token)

    # Build one Executor the way the supervisor would, with a minimal agent.
    agent = SimpleNamespace(name="agent-1", workspace_dir=None)
    server.supervisor._factory(agent)

    provider = _RecordingExecutor.last_kwargs["account_token_provider"]
    assert provider is not None
    assert provider() == "tok-initial"

    # A token refreshed on the session carries to the next task — the provider
    # is a live accessor, not a captured string.
    session.access_token = "tok-refreshed"
    assert provider() == "tok-refreshed"


def test_task_server_forwards_live_search_session(monkeypatch):
    monkeypatch.setattr(serve, "Executor", _RecordingExecutor)
    current = [SimpleNamespace(access_token="initial")]
    server = _make_server(None, lambda: current[0])
    server.supervisor._factory(SimpleNamespace(name="agent-1", workspace_dir=None))
    provider = _RecordingExecutor.last_kwargs["account_session_provider"]
    assert provider() is current[0]
    current[0] = SimpleNamespace(access_token="replacement")
    assert provider() is current[0]


def test_task_server_provider_defaults_to_none(monkeypatch):
    monkeypatch.setattr(serve, "Executor", _RecordingExecutor)

    server = _make_server(None)
    agent = SimpleNamespace(name="agent-1", workspace_dir=None)
    server.supervisor._factory(agent)

    # No provider wired -> the Executor gets None and appSession connectors
    # simply do not authenticate (never a crash).
    assert _RecordingExecutor.last_kwargs["account_token_provider"] is None
