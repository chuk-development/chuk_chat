"""Keep the user-browser broker of every test off the real runtime directory.

``Host.start`` and the executor start the broker
(``chuk_agents_executor.user_browser``); without this a test run would bind the
sockets a running Agents host uses.
"""

import os
import tempfile

_SOCKETS = tempfile.mkdtemp(prefix="agents-browser-test-")
os.environ.setdefault("AGENTS_BRIDGE_SOCKET", os.path.join(_SOCKETS, "browser-bridge.sock"))
os.environ.setdefault("AGENTS_BROWSER_BROKER_SOCKET", os.path.join(_SOCKETS, "browser-broker.sock"))

import pytest as _pytest


@_pytest.fixture(autouse=True)
def _fresh_mcp_grants():
    """Each test starts with an empty process-wide OAuth grant store, and no
    test writes the grant file of a real host (bead chuk_chat-mj2o)."""
    from chuk_agents_runtime import mcp_client

    mcp_client.GRANTS.reset()
    yield
    mcp_client.GRANTS.reset()


@_pytest.fixture(autouse=True)
def _private_git_state(tmp_path_factory, monkeypatch):
    """The host state of workspace git (private git dirs, rewind ledgers) of
    every test goes to a temp dir, never to the real host state."""
    monkeypatch.setenv("AGENTS_GIT_STATE_DIR", str(tmp_path_factory.mktemp("git-state")))
