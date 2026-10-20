"""Make the shared ``wiring`` helper importable from test modules."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

# Keep the user-browser broker (``chuk_agents_executor.user_browser``) of every
# test off the real runtime directory, where a running Agents host listens.
import tempfile as _tempfile

_BROWSER_SOCKETS = _tempfile.mkdtemp(prefix="agents-browser-test-")
os.environ.setdefault("AGENTS_BRIDGE_SOCKET", os.path.join(_BROWSER_SOCKETS, "browser-bridge.sock"))
os.environ.setdefault(
    "AGENTS_BROWSER_BROKER_SOCKET", os.path.join(_BROWSER_SOCKETS, "browser-broker.sock")
)

import pytest as _pytest


@_pytest.fixture(autouse=True)
def _fresh_mcp_grants():
    """Each test starts with an empty process-wide OAuth grant store, and no
    test writes the grant file of a real host (bead chuk_chat-mj2o)."""
    from chuk_agents_runtime import mcp_client

    mcp_client.GRANTS.reset()
    yield
    mcp_client.GRANTS.reset()
