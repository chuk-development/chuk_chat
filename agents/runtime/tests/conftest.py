"""Shared fixtures of the runtime tests."""

import pytest


@pytest.fixture(autouse=True)
def _fresh_mcp_grants():
    """Each test starts with an empty process-wide OAuth grant store
    (bead chuk_chat-mj2o)."""
    from chuk_agents_runtime import mcp_client

    mcp_client.GRANTS.reset()
    yield
    mcp_client.GRANTS.reset()
