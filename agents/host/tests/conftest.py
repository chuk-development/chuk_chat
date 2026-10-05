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
