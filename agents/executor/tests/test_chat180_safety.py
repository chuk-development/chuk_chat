"""CHAT-180 through the executor: "allow for this chat" grants in the run's
approval binding, and the purge of a disconnected connector's data."""

from __future__ import annotations

from types import SimpleNamespace

from chuk_agents_runtime import StateStore
from chuk_agents_runtime import chat_grants
from chuk_agents_runtime.action_policy import (
    MODE_ALLOW,
    MODE_ASK,
    PAYMENT,
    SCOPE_AGENT,
    SCOPE_CHAT,
    SEND_EXTERNAL,
)
from chuk_agents_runtime.connector_purge import PURGED_RESULT

from test_action_approvals import _executor, _Hook, _no_kill


def test_a_chat_grant_is_kept_per_chat_and_never_reaches_the_agent_policy(tmp_path):
    hook = _Hook()
    executor = _executor(tmp_path, hook=hook)
    binding = executor._action_approvals_binding("req-1", _no_kill(), "chat-a")
    assert binding.chat_scope is True
    assert binding.current().evaluate(SEND_EXTERNAL) == MODE_ASK
    binding.remember(SEND_EXTERNAL, SCOPE_CHAT, "")
    assert hook.remembered == []  # the agent's stored policy is not touched
    assert binding.current().evaluate(SEND_EXTERNAL) == MODE_ALLOW
    # Another chat of the same agent still asks.
    other = executor._action_approvals_binding("req-2", _no_kill(), "chat-b")
    assert other.current().evaluate(SEND_EXTERNAL) == MODE_ASK
    # A payment is never granted for a chat.
    binding.remember(PAYMENT, SCOPE_CHAT, "")
    assert binding.current().evaluate(PAYMENT) == MODE_ASK
    # Other scopes still go to the host.
    binding.remember(SEND_EXTERNAL, SCOPE_AGENT, "")
    assert hook.remembered == [("chat-a", SEND_EXTERNAL, SCOPE_AGENT, "")]


def test_the_grant_survives_a_new_executor(tmp_path):
    executor = _executor(tmp_path, hook=_Hook())
    executor._action_approvals_binding("r", _no_kill(), "chat-a").remember(SEND_EXTERNAL, SCOPE_CHAT, "")
    again = _executor(tmp_path, hook=_Hook())
    assert again._action_approvals_binding("r", _no_kill(), "chat-a").current().evaluate(SEND_EXTERNAL) == MODE_ALLOW
    store = StateStore(str(tmp_path / "state.db"))
    assert chat_grants.chat_classes(store, "chat-a") == frozenset({SEND_EXTERNAL})
    store.close()


def test_sign_out_purges_the_connectors_chat_rows(tmp_path):
    executor = _executor(tmp_path)
    store = StateStore(str(tmp_path / "state.db"))
    sid = store.route("chat-a")
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "c", "name": "mcp__fastmail__search", "content": {"t": "secret mail"}},
    )
    store.close()
    # The session that holds the grant names the server.
    config = SimpleNamespace(
        name="fastmail", oauth={"token_endpoint": "https://fm.example/token", "client_id": "cid", "refresh_token": "rt"}
    )
    executor._mcp_managers["chat-a"] = SimpleNamespace(configs=[config], close=lambda: None)
    executor._forget_session_mcp = lambda **kw: None  # type: ignore[method-assign]
    acked = executor._forget_signed_out(
        [{"token_endpoint": "https://fm.example/token", "client_id": "cid"}]
    )
    assert acked == [{"token_endpoint": "https://fm.example/token", "client_id": "cid"}]
    store = StateStore(str(tmp_path / "state.db"))
    rows = [m.content for m in store.get_conversation(sid)]
    assert rows[-1]["content"] == PURGED_RESULT
    store.close()


def test_sign_out_entry_may_name_its_server(tmp_path):
    executor = _executor(tmp_path)
    seen: list[list[str]] = []
    executor._purge_connector_data = lambda servers: seen.append(servers) or {}  # type: ignore[method-assign]
    executor._forget_signed_out(
        [{"token_endpoint": "https://n.example/token", "client_id": "c2", "server": "notion"}]
    )
    assert seen == [["notion"]]
    # No server known: nothing to purge, the grant is still forgotten.
    seen.clear()
    executor._forget_signed_out([{"token_endpoint": "https://n.example/token", "client_id": "c3"}])
    assert seen == []
