"""Run: python3 tools/agents-browser-bridge/test_bridge_roundtrip.py

The bridge between two real ends: the MCP server's unix socket on one side, and
Chrome's native-messaging framing on the other. The browser is played by this
test writing the same 4-byte-length frames Chrome writes.
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MCP = ROOT / "tools" / "agents-extension-mcp" / "agents_extension_mcp.py"
BRIDGE = HERE / "agents_browser_bridge.py"

sys.path.insert(0, str(ROOT / "tools" / "agents-extension-mcp"))


def frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode()
    return struct.pack("<I", len(body)) + body


def read_frame(stream) -> dict:
    header = stream.read(4)
    assert len(header) == 4, "the bridge closed without answering"
    (length,) = struct.unpack("<I", header)
    return json.loads(stream.read(length).decode())


def main() -> int:
    socket_path = Path(tempfile.mkdtemp()) / "bridge.sock"

    mcp = subprocess.Popen(
        [sys.executable, str(MCP), str(socket_path)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    for _ in range(200):
        if socket_path.exists():
            break
        time.sleep(0.01)
    assert socket_path.exists(), "the MCP server never bound its socket"
    print("ok  the MCP server binds the socket the browser's bridge dials")

    env = dict(os.environ, AGENTS_BRIDGE_SOCKET=str(socket_path))
    bridge = subprocess.Popen(
        [sys.executable, str(BRIDGE)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
    )

    ready = read_frame(bridge.stdout)
    assert ready["type"] == "bridge_ready", f"expected bridge_ready, got {ready}"
    print("ok  the bridge answers the browser once it has the host")

    # The add-on's hello, in Chrome's framing.
    bridge.stdin.write(frame({"type": "browser_attach", "attached": True, "browser": "chrome"}))
    bridge.stdin.flush()

    # Now a real MCP tool call, which must reach us as a browser_cmd.
    request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": "browser_navigate", "arguments": {"url": "https://example.com"}}}
    mcp.stdin.write((json.dumps(request) + "\n").encode())
    mcp.stdin.flush()

    command = read_frame(bridge.stdout)
    assert command["type"] == "browser_cmd", f"expected browser_cmd, got {command}"
    assert command["op"] == "browser_navigate"
    assert command["args"]["url"] == "https://example.com"
    print("ok  a tool call arrives at the browser as a browser_cmd")

    bridge.stdin.write(frame({
        "type": "browser_result", "cmd_id": command["cmd_id"], "ok": True,
        "data": {"url": "https://example.com", "title": "Example", "nodes": []},
    }))
    bridge.stdin.flush()

    answer = json.loads(mcp.stdout.readline().decode())
    payload = json.loads(answer["result"]["content"][0]["text"])
    assert payload["title"] == "Example", f"the answer did not come back: {answer}"
    print("ok  the browser's answer reaches the model")

    for proc in (bridge, mcp):
        proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    print("\n4 passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
