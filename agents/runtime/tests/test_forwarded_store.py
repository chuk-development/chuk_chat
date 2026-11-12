"""The forwarded connector list survives a restart, sealed (CHAT-37)."""

import json
import os

from chuk_agents_runtime.mcp_client import ForwardedConnectorStore, OAuthGrantStore

ENTRY = {
    "name": "Fastmail",
    "url": "https://api.fastmail.com/mcp",
    "auth": "oauth",
    "access_token": "AT-secret",
    "oauth": {"refresh_token": "RT-secret", "token_endpoint": "https://x/token", "client_id": "c"},
}


def _grants(key: bytes | None) -> OAuthGrantStore:
    grants = OAuthGrantStore()
    grants.set_key(key)
    return grants


def test_round_trip_after_restart_without_access_token(tmp_path):
    key = os.urandom(32)
    path = tmp_path / "mcp-forwarded.json"
    ForwardedConnectorStore(_grants(key), path).put("local:Mail:14", [ENTRY])
    raw = path.read_text()
    assert "RT-secret" not in raw and "Fastmail" not in raw  # sealed
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    again = ForwardedConnectorStore(_grants(key), path).get("local:Mail:14")
    assert again is not None and again[0]["name"] == "Fastmail"
    assert "access_token" not in again[0]
    assert again[0]["oauth"]["refresh_token"] == "RT-secret"


def test_no_key_writes_nothing(tmp_path):
    path = tmp_path / "mcp-forwarded.json"
    ForwardedConnectorStore(_grants(None), path).put("s", [ENTRY])
    assert not path.exists()


def test_foreign_key_reads_empty(tmp_path):
    path = tmp_path / "mcp-forwarded.json"
    ForwardedConnectorStore(_grants(os.urandom(32)), path).put("s", [ENTRY])
    assert ForwardedConnectorStore(_grants(os.urandom(32)), path).get("s") is None
    assert json.loads(path.read_text())["version"] == 1
