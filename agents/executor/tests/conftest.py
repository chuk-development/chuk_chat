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
