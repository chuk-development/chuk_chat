"""A real MCP server, in-process or over stdio, for the client tests.

It is a real server on the real SDK, so the client tests exercise the actual
protocol — handshake, tool listing, call, error — with no network at all: stdio
spawns this file as a subprocess, and the HTTP test mounts :func:`build_server`
behind ``httpx.ASGITransport``.

The ``calls`` tool is the proof of the persistent transport thread (§9): it
returns a counter that lives in the *server process*. Two agent-side calls that
answer 1 and then 2 can only have shared one session; a client that reconnected
per call would answer 1 twice.
"""

from __future__ import annotations

import os

from mcp.server import MCPServer

_calls = {"n": 0}
_initializations = {"n": 0}


def build_server(name: str = "fake") -> MCPServer:
    server = MCPServer(name, version="1.0.0")

    @server.tool(description="Echo the text back, uppercased.")
    def shout(text: str) -> str:
        _calls["n"] += 1
        return text.upper()

    @server.tool(description="Return how many tool calls this server process saw.")
    def calls() -> dict:
        _calls["n"] += 1
        return {"calls": _calls["n"], "pid": os.getpid()}

    @server.tool(description="Add two numbers. Takes an integer and an integer.")
    def add(a: int, b: int) -> int:
        _calls["n"] += 1
        return a + b

    @server.tool(description="Always fail, with a long body.")
    def explode(size: int = 100_000) -> str:
        _calls["n"] += 1
        raise RuntimeError("x" * max(1, int(size)))

    # A server with a big tool surface, for the Tool Search threshold (§7.2).
    # `FAKE_MCP_EXTRA_TOOLS=60` is a realistic size: the GitHub and Slack MCP
    # servers each advertise dozens.
    for index in range(int(os.environ.get("FAKE_MCP_EXTRA_TOOLS", "0") or 0)):

        def make(number: int):
            def handler(query: str, limit: int = 20, cursor: str = "") -> dict:
                _calls["n"] += 1
                return {"tool": number, "query": query, "limit": limit, "cursor": cursor}

            return handler

        server.add_tool(
            make(index),
            name=f"records_{index}",
            description=(
                f"Query collection {index} of the remote system. Returns a page "
                "of records with a cursor for the next page and a total count."
            ),
        )

    return server


def main() -> None:
    build_server(os.environ.get("FAKE_MCP_NAME", "fake")).run(transport="stdio")


if __name__ == "__main__":
    main()
