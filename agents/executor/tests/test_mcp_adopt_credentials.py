"""Cache hit adopts rotating credentials (bead cowork-lwc).

The session's MCPManager is reused when the forwarded ``mcp_servers`` list has
the same connectors (``_mcp_signature`` ignores the rotating fields). A hit must
still carry the incoming ``access_token`` / ``oauth`` block into the cached
configs — the app refreshes before every forward, so those are the freshest
credentials anyone has — or the device's newer bearer is ignored and each
connector pays an unnecessary refresh round-trip. Managers are built but never
started here: no network, no subprocess.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

from cowork_sandbox import LocalEnvironment

from cowork_executor import Executor, loopback_pair

from wiring import paired_channel

FIXTURE = Path(__file__).resolve().parents[2] / "app/test/fixtures/mcp_forward_payload.json"


def _servers() -> list[dict]:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["mcp_servers"]


def _executor(tmp_path) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    return Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=lambda: None,
    )


def _config(manager, name: str):
    return next(c for c in manager.configs if c.name == name)


def test_a_cache_hit_adopts_the_fresher_tokens(tmp_path):
    executor = _executor(tmp_path)
    servers = _servers()

    first = executor._session_mcp_manager("s", servers)
    assert first is not None
    assert _config(first, "Notion").auth_token == "at-notion"

    rotated = copy.deepcopy(servers)
    notion = next(e for e in rotated if e["name"] == "Notion")
    notion["access_token"] = "at-notion-2"
    notion["oauth"]["refresh_token"] = "rt-notion-2"
    notion["oauth"]["expires_at"] = "2099-01-01T00:00:00Z"

    second = executor._session_mcp_manager("s", rotated)

    # Same connectors -> the SAME manager (no rebuild) ...
    assert second is first
    # ... carrying the incoming credentials.
    config = _config(first, "Notion")
    assert config.auth_token == "at-notion-2"
    assert config.oauth.get("refresh_token") == "rt-notion-2"
    assert config.oauth.get("expires_at") == "2099-01-01T00:00:00Z"
    # The identity fields were untouched.
    assert config.oauth.get("client_id") == notion["oauth"]["client_id"]


def test_an_entry_without_a_bearer_does_not_wipe_a_minted_one(tmp_path):
    """The host may have minted its own access token from the refresh token
    (mcp_client.refresh_token). A later forward that carries no bearer for that
    connector must not erase it."""
    executor = _executor(tmp_path)
    servers = _servers()
    manager = executor._session_mcp_manager("s", servers)
    assert manager is not None
    legacy = _config(manager, "Legacy")
    assert legacy.auth_token == "at-legacy"
    legacy.auth_token = "at-minted-by-host"

    stripped = copy.deepcopy(servers)
    next(e for e in stripped if e["name"] == "Legacy").pop("access_token")

    again = executor._session_mcp_manager("s", stripped)

    assert again is manager
    assert _config(manager, "Legacy").auth_token == "at-minted-by-host"


def test_a_changed_connector_still_rebuilds(tmp_path):
    executor = _executor(tmp_path)
    servers = _servers()
    first = executor._session_mcp_manager("s", servers)

    repointed = copy.deepcopy(servers)
    next(e for e in repointed if e["name"] == "Notion")["url"] = "https://moved.example/mcp"

    second = executor._session_mcp_manager("s", repointed)

    assert second is not None and second is not first
    assert _config(second, "Notion").url == "https://moved.example/mcp"
