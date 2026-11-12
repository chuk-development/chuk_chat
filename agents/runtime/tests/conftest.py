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


@pytest.fixture(autouse=True)
def _private_git_state(tmp_path_factory, monkeypatch):
    """The host state of workspace git (private git dirs, rewind ledgers) of
    every test goes to a temp dir, never to the real host state."""
    monkeypatch.setenv("AGENTS_GIT_STATE_DIR", str(tmp_path_factory.mktemp("git-state")))


@pytest.fixture(autouse=True)
def _no_model_retry_wait(monkeypatch):
    """The autonomous model retry (CHAT-31) waits minutes; the tests of one
    failed call see the single attempt. ``test_model_retry.py`` passes its
    own :class:`RetryPolicy`."""
    monkeypatch.setenv("AGENTS_MODEL_RETRY_WINDOW_S", "0")
