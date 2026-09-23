"""The MCP manager cache key ignores rotating credentials (docs/WIRE_CONTRACT.md).

The executor caches one MCPManager per session and rebuilds it only when the
forwarded ``mcp_servers`` list changed. The app refreshes tokens before every
forward, so hashing the raw list rebuilt the manager on every task — transport
threads torn down, tool lists re-fetched — for connectors that had not changed.
The signature is a redacted projection: ``access_token``, ``oauth.refresh_token``
and ``oauth.expires_at`` are dropped; everything that identifies the connector
stays.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

from chuk_agents_executor.executor import _mcp_signature

FIXTURE = Path(__file__).resolve().parents[3] / "test/fixtures/mcp_forward_payload.json"


def _fixture_servers() -> list[dict]:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["mcp_servers"]


def test_rotated_tokens_keep_the_signature():
    before = _fixture_servers()
    after = copy.deepcopy(before)
    for entry in after:
        if "access_token" in entry:
            entry["access_token"] = entry["access_token"] + "-rotated"
        oauth = entry.get("oauth")
        if isinstance(oauth, dict):
            oauth["refresh_token"] = "rt-rotated"
            oauth["expires_at"] = "2099-01-01T00:00:00Z"

    assert _mcp_signature(before) == _mcp_signature(after)


def test_a_real_connector_change_changes_the_signature():
    base = _fixture_servers()

    repointed = copy.deepcopy(base)
    repointed[0]["url"] = "https://elsewhere.example/mcp"
    assert _mcp_signature(repointed) != _mcp_signature(base)

    reauthorized = copy.deepcopy(base)
    reauthorized[0]["oauth"]["client_id"] = "another-client"
    assert _mcp_signature(reauthorized) != _mcp_signature(base)

    removed = copy.deepcopy(base)[1:]
    assert _mcp_signature(removed) != _mcp_signature(base)

    added = copy.deepcopy(base) + [{"name": "New", "url": "https://new.example/mcp"}]
    assert _mcp_signature(added) != _mcp_signature(base)


def test_signature_is_order_insensitive_within_an_entry_and_never_raises():
    a = [{"name": "X", "url": "https://x.example/mcp", "auth": "oauth"}]
    b = [{"auth": "oauth", "url": "https://x.example/mcp", "name": "X"}]
    assert _mcp_signature(a) == _mcp_signature(b)

    # A non-dict entry and an unserializable value both degrade, never raise.
    weird = [{"name": "Y", "url": "https://y.example", "blob": object()}, "not-a-dict"]
    assert isinstance(_mcp_signature(weird), str)


def test_the_projection_does_not_mutate_the_input():
    servers = _fixture_servers()
    snapshot = copy.deepcopy(servers)
    _mcp_signature(servers)
    assert servers == snapshot
