"""Run: python3 tools/agents-extension-mcp/test_agents_extension_mcp.py

The whole loop without a browser: a fake add-on dials the socket and answers,
so the MCP side can be proved on its own.
"""

from __future__ import annotations

import json
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agents_extension_mcp import TOOLS, Bridge, handle, reply  # noqa: E402

passed = 0


def _assert(condition, message):
    if not condition:
        raise AssertionError(message)


def check(what, fn):
    global passed
    fn()
    passed += 1
    print(f"ok  {what}")


def fake_addon(path: Path, answers):
    """Dial the socket like the bridge does, and answer every command."""
    for _ in range(100):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.connect(str(path))
            break
        except OSError:
            time.sleep(0.01)
    else:
        raise AssertionError("the server never came up")

    conn.sendall(json.dumps({"type": "browser_attach", "attached": True, "browser": "chrome"}).encode() + b"\n")
    buffer = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            frame = json.loads(line)
            answer = answers(frame)
            if answer is None:
                return
            conn.sendall(json.dumps(answer).encode() + b"\n")


def with_bridge(answers):
    tmp = Path(tempfile.mkdtemp()) / "bridge.sock"
    bridge = Bridge(tmp)
    thread = threading.Thread(target=fake_addon, args=(tmp, answers), daemon=True)
    thread.start()
    for _ in range(200):
        if bridge.ready:
            break
        time.sleep(0.01)
    assert bridge.ready, "the fake add-on never attached"
    return bridge


check("initialize names the server so tools carry the browser prefix", lambda: (
    lambda r: (
        _assert(r["result"]["serverInfo"]["name"] == "playwright",
                "the agent builds mcp__<server>__<tool>; this name is what makes it "
                "mcp__playwright__browser_navigate, which the rest of Agents matches on"),
        _assert("tools" in r["result"]["capabilities"], "tools capability missing"),
    )
)(handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, None)))

check("tools/list offers the browser vocabulary", lambda: (
    lambda names: (
        _assert("browser_navigate" in names, "navigate missing"),
        _assert("browser_snapshot" in names, "snapshot missing"),
        _assert("browser_tabs" in names, "tabs missing — this is how a user's open page is taken over"),
        _assert("browser_handoff" in names, "handoff missing"),
        _assert(all("inputSchema" in t for t in TOOLS), "every tool needs a schema"),
    )
)([t["name"] for t in handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, None)["result"]["tools"]]))

check("an initialized notification is not answered", lambda: _assert(
    handle({"jsonrpc": "2.0", "method": "notifications/initialized"}, None) is None,
    "a notification has no id, so answering it corrupts the stream"))


def _tool_call():
    seen = {}

    def answers(frame):
        seen["frame"] = frame
        return {
            "type": "browser_result",
            "cmd_id": frame["cmd_id"],
            "ok": True,
            "data": {"url": "https://example.com", "nodes": [{"ref": "e1", "role": "link"}]},
        }

    bridge = with_bridge(answers)
    response = handle(
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "browser_navigate", "arguments": {"url": "https://example.com"}}},
        bridge,
    )
    _assert(seen["frame"]["type"] == "browser_cmd", "the add-on must see a browser_cmd frame")
    _assert(seen["frame"]["op"] == "browser_navigate", "the op is the tool name")
    _assert(seen["frame"]["args"]["url"] == "https://example.com", "arguments travel through")
    payload = json.loads(response["result"]["content"][0]["text"])
    _assert(payload["url"] == "https://example.com", "the add-on's answer reaches the model")
    _assert(not response["result"].get("isError"), "a good call is not an error")


check("a tool call becomes a browser_cmd and the answer comes back", _tool_call)


def _failure_is_a_result():
    bridge = with_bridge(lambda frame: {
        "type": "browser_result", "cmd_id": frame["cmd_id"], "ok": False,
        "error": "no lease on tab 12",
    })
    response = handle(
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "browser_click", "arguments": {"ref": "e9"}}},
        bridge,
    )
    _assert(response["result"]["isError"] is True, "a refused command is an error result")
    _assert("no lease" in response["result"]["content"][0]["text"], "the reason reaches the model")


check("a refused command comes back as a readable error, not a crash", _failure_is_a_result)


def _no_addon():
    import tempfile as tf
    bridge = Bridge(Path(tf.mkdtemp()) / "bridge.sock")  # nobody dials in
    response = handle(
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "browser_snapshot", "arguments": {}}},
        bridge,
    )
    _assert(response["result"]["isError"] is True, "no add-on is an error")
    text = response["result"]["content"][0]["text"]
    _assert("add-on is not connected" in text, "the model must be told what to ask the user for")


check("with no add-on the model is told what is missing", _no_addon)


print(f"\n{passed} passed")
