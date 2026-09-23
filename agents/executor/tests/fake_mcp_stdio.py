"""A tiny real stdio MCP server for the executor's forwarding e2e test.

Self-contained (not the agent package's fixture) so the executor test does not
reach across packages. One ``shout`` tool is enough to prove a forwarded MCP
server's tool is registered into a real task's registry and dispatchable.
"""

from __future__ import annotations

import os

from mcp.server import MCPServer


def build_server(name: str = "exec-fake") -> MCPServer:
    server = MCPServer(name, version="1.0.0")

    @server.tool(description="Echo the text back, uppercased.")
    def shout(text: str) -> str:
        return text.upper()

    return server


def main() -> None:
    build_server(os.environ.get("FAKE_MCP_NAME", "exec-fake")).run(transport="stdio")


if __name__ == "__main__":
    main()
