"""Per-action approvals (docs/WIRE_CONTRACT.md, "Per-action approvals"),
bead chuk_chat-mxxm: the policy, the decision scopes, and the loop asking,
skipping and refusing by class. No network."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from chuk_agents_runtime.action_policy import (
    BROWSER_ACT,
    MCP_DESTRUCTIVE,
    PUBLISH,
    SCOPE_AGENT,
    SCOPE_DENY,
    SCOPE_ONCE,
    SCOPE_SITE,
    SEND_EXTERNAL,
    ActionApprovals,
    ActionDecision,
    ActionPolicy,
    ActionPolicyError,
    ActionRequest,
    describe_browser,
    describe_mail,
    is_destructive,
    normalize_site,
    options_for,
    parse_scope,
)
from chuk_agents_runtime.herenow import HereNowConfig, register_herenow_tools
from chuk_agents_runtime.environment import LocalEnvironment
from chuk_agents_runtime.loop import AgentLoop, StopReason
from chuk_agents_runtime.mcp_client import MCPToolInfo, _annotations, tool_name
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.pai.wiring import loop_setup
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore


# -- the policy -----------------------------------------------------------------


def test_defaults_ask_for_outward_classes_and_allow_the_browser():
    policy = ActionPolicy()
    assert policy.evaluate(PUBLISH) == "ask"
    assert policy.evaluate(SEND_EXTERNAL) == "ask"
    assert policy.evaluate(MCP_DESTRUCTIVE) == "ask"
    assert policy.evaluate(BROWSER_ACT, "github.com") == "allow"
    wire = policy.to_dict()
    assert wire["classes"] == {
        "publish": "ask",
        "send_external": "ask",
        "mcp_destructive": "ask",
        "browser_act": "allow",
    }
    assert wire["sites"] == {"browser_act": []}
    assert wire["defaults"]["browser_act"] == "allow"
    assert policy.to_stored() == {}


def test_a_site_allows_itself_and_its_subdomains_but_never_lifts_a_deny():
    policy = ActionPolicy(modes={BROWSER_ACT: "ask"}, sites={BROWSER_ACT: ("github.com",)})
    assert policy.evaluate(BROWSER_ACT, "github.com") == "allow"
    assert policy.evaluate(BROWSER_ACT, "https://www.github.com/login") == "allow"
    assert policy.evaluate(BROWSER_ACT, "gist.github.com") == "allow"
    assert policy.evaluate(BROWSER_ACT, "evilgithub.com") == "ask"
    assert policy.evaluate(BROWSER_ACT, "") == "ask"
    denied = ActionPolicy(modes={BROWSER_ACT: "deny"}, sites={BROWSER_ACT: ("github.com",)})
    assert denied.evaluate(BROWSER_ACT, "github.com") == "deny"


@pytest.mark.parametrize(
    ("raw", "canon"),
    [
        ("GitHub.com", "github.com"),
        ("https://www.shop.example.de:8443/cart?x=1", "shop.example.de"),
        ("accounts.google.com.", "accounts.google.com"),
        ("", None),
        ("not a host", None),
        ("[::1]", None),
        (42, None),
    ],
)
def test_normalize_site(raw, canon):
    assert normalize_site(raw) == canon


def test_updated_merges_classes_replaces_sites_and_is_strict():
    policy = ActionPolicy().updated(
        {"classes": {"send_external": "allow", "browser_act": "ask"}, "sites": {"browser_act": ["Shop.example.com", "shop.example.com"]}}
    )
    assert policy.mode(SEND_EXTERNAL) == "allow"
    assert policy.sites[BROWSER_ACT] == ("shop.example.com",)
    assert policy.to_stored() == {
        "classes": {"send_external": "allow", "browser_act": "ask"},
        "sites": {"browser_act": ["shop.example.com"]},
    }
    # Sites replace the whole list; an empty list clears it.
    cleared = policy.updated({"sites": {"browser_act": []}})
    assert cleared.sites == {}
    for bad in (
        {"classes": {"payments": "ask"}},
        {"classes": {"send_external": "maybe"}},
        {"sites": {"send_external": ["x.com"]}},
        {"sites": {"browser_act": ["not a site"]}},
        {"sites": {"browser_act": "x.com"}},
        {"other": 1},
        [],
    ):
        with pytest.raises(ActionPolicyError):
            policy.updated(bad)
    with pytest.raises(ActionPolicyError):
        ActionPolicy.from_stored({"classes": {"send_external": True}})


def test_remembered_scopes():
    policy = ActionPolicy()
    assert policy.remembered(SEND_EXTERNAL, SCOPE_ONCE) == policy
    assert policy.remembered(SEND_EXTERNAL, SCOPE_DENY) == policy
    assert policy.remembered(SEND_EXTERNAL, SCOPE_AGENT).mode(SEND_EXTERNAL) == "allow"
    sited = policy.remembered(BROWSER_ACT, SCOPE_SITE, "https://www.shop.example.com/x")
    assert sited.sites[BROWSER_ACT] == ("shop.example.com",)
    # A covered subdomain adds nothing; a site scope on a non-site class is a no-op.
    assert sited.remembered(BROWSER_ACT, SCOPE_SITE, "a.shop.example.com") == sited
    assert policy.remembered(SEND_EXTERNAL, SCOPE_SITE, "x.com") == policy


def test_options_and_scope_parsing_never_reach_further_than_the_card():
    assert options_for(SEND_EXTERNAL) == ("once", "always_this_agent", "deny")
    assert options_for(BROWSER_ACT, "x.com") == ("once", "always_this_agent", "always_this_site", "deny")
    assert options_for(BROWSER_ACT, "") == ("once", "always_this_agent", "deny")
    mail = options_for(SEND_EXTERNAL)
    # An older app: approved=true and no scope is "once".
    assert parse_scope(True, None, mail) == SCOPE_ONCE
    assert parse_scope(True, "always_this_agent", mail) == SCOPE_AGENT
    # Not offered -> once; unknown -> once; not an explicit yes -> deny.
    assert parse_scope(True, "always_this_site", mail) == SCOPE_ONCE
    assert parse_scope(True, "forever", mail) == SCOPE_ONCE
    assert parse_scope(1, "once", mail) == SCOPE_DENY
    assert parse_scope(False, "always_this_agent", mail) == SCOPE_DENY
    assert parse_scope(True, "deny", mail) == SCOPE_DENY


def test_describers_never_show_typed_text():
    card = describe_browser("browser_type", {"element": "Password", "ref": "e3", "text": "hunter2", "submit": True}, "bank.example")
    assert card.action_class == BROWSER_ACT
    assert "hunter2" not in repr(card)
    assert card.details == {"browser_tool": "browser_type", "element": "Password", "submit": True}
    assert card.summary == "Type into Password on bank.example"
    assert card.options == ("once", "always_this_agent", "always_this_site", "deny")
    mail = describe_mail("mail_send", {"to": "a@x.com, b@y.org", "subject": "Hi", "text": "Hello there"})
    assert mail.summary == "Send a mail to a@x.com, b@y.org"
    assert mail.details == {"to": ["a@x.com", "b@y.org"], "subject": "Hi", "preview": "Hello there"}


def test_mcp_annotations_are_read_strictly():
    assert _annotations(None) == {}
    assert _annotations({"destructiveHint": True, "readOnlyHint": "no"}) == {"destructiveHint": True}
    assert _annotations(SimpleNamespace(readOnlyHint=True, destructiveHint=None)) == {"readOnlyHint": True}
    assert is_destructive({"destructiveHint": True})
    assert not is_destructive({"destructiveHint": True, "readOnlyHint": True})
    assert not is_destructive({})  # the spec's implicit default does not count
    assert not is_destructive(None)


# -- the loop ---------------------------------------------------------------------


class _Store:
    """Stands in for the host's store: the live policy and what was remembered."""

    def __init__(self, policy: ActionPolicy | None = None) -> None:
        self.policy = policy or ActionPolicy()
        self.remembered: list[tuple[str, str, str]] = []

    def remember(self, action_class: str, scope: str, site: str) -> None:
        self.remembered.append((action_class, scope, site))
        self.policy = self.policy.remembered(action_class, scope, site)


def _binding(store: _Store, answers: list, site: str = "") -> tuple[ActionApprovals, list[ActionRequest]]:
    asked: list[ActionRequest] = []

    def ask(request: ActionRequest):
        asked.append(request)
        return answers.pop(0)

    return (
        ActionApprovals(policy=lambda: store.policy, ask=ask, remember=store.remember, site=lambda: site),
        asked,
    )


def _mail_registry(sent: list) -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "mail_send",
        {
            "description": "Send a mail.",
            "type": "object",
            "properties": {"to": {"type": "string"}, "subject": {"type": "string"}, "text": {"type": "string"}},
        },
        lambda to="", subject="", text="", cc=None, attachments=None: sent.append(to) or {"ok": True, "status": "sent"},
    )
    return reg


def _run(reg, binding, calls, *, tmp_path: Path, mcp=None, herenow=None, env=None):
    model = MockModelClient([tool_call_response(*calls), "done"])
    _, extra = loop_setup(
        model,
        env=env or LocalEnvironment(),
        herenow_config=herenow,
        herenow_gate=None,
        registry=reg,
        mcp=mcp,
        action_approvals=binding,
    )
    store = StateStore(str(tmp_path / "state.db"))
    loop = AgentLoop(model, reg, store, approval_policy=extra["approval_policy"])
    result = loop.run("s", "go")
    rows = [m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool"]
    return result, rows, extra["approval_policy"]


def test_send_asks_and_always_this_agent_stops_the_next_ask_in_the_same_run(tmp_path):
    sent: list = []
    store = _Store()
    binding, asked = _binding(store, [ActionDecision(True, SCOPE_AGENT)])
    result, rows, policy = _run(
        _mail_registry(sent),
        binding,
        [
            ("mail_send", {"to": "bob@example.com", "subject": "A", "text": "one"}),
            ("mail_send", {"to": "bob@example.com", "subject": "B", "text": "two"}),
        ],
        tmp_path=tmp_path,
    )
    assert result.reason is StopReason.FINISHED
    assert len(asked) == 1  # the second call followed the remembered "allow"
    assert asked[0].action_class == SEND_EXTERNAL
    assert asked[0].options == ("once", "always_this_agent", "deny")
    assert asked[0].details["to"] == ["bob@example.com"]
    assert store.remembered == [(SEND_EXTERNAL, SCOPE_AGENT, "")]
    assert sent == ["bob@example.com", "bob@example.com"]
    assert not policy.requires_approval("mail_send")


def test_an_older_gate_answering_true_is_once_and_nothing_is_remembered(tmp_path):
    sent: list = []
    store = _Store()
    binding, asked = _binding(store, [True, True])
    _run(
        _mail_registry(sent),
        binding,
        [("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"}), ("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"})],
        tmp_path=tmp_path,
    )
    assert len(asked) == 2
    assert store.remembered == []
    assert sent == ["a@x.com", "a@x.com"]


def test_a_no_does_not_send_and_tells_the_model(tmp_path):
    sent: list = []
    binding, asked = _binding(_Store(), [ActionDecision(False, SCOPE_DENY)])
    _, rows, _ = _run(_mail_registry(sent), binding, [("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"})], tmp_path=tmp_path)
    assert sent == []
    assert rows[0]["content"]["declined"] is True
    assert rows[0]["content"]["action_class"] == SEND_EXTERNAL
    assert "declined" in rows[0]["content"]["error"]


def test_deny_mode_refuses_without_asking(tmp_path):
    sent: list = []
    store = _Store(ActionPolicy(modes={SEND_EXTERNAL: "deny"}))
    binding, asked = _binding(store, [])
    _, rows, _ = _run(_mail_registry(sent), binding, [("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"})], tmp_path=tmp_path)
    assert asked == [] and sent == []
    assert "not allowed" in rows[0]["content"]["error"]


def test_allow_mode_runs_without_asking(tmp_path):
    sent: list = []
    store = _Store(ActionPolicy(modes={SEND_EXTERNAL: "allow"}))
    binding, asked = _binding(store, [])
    _, _, policy = _run(_mail_registry(sent), binding, [("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"})], tmp_path=tmp_path)
    assert asked == [] and sent == ["a@x.com"]
    assert not policy.requires_approval("mail_send")


def test_unattended_run_refuses(tmp_path):
    sent: list = []
    store = _Store()
    binding = ActionApprovals(policy=lambda: store.policy, ask=None)
    _, rows, _ = _run(_mail_registry(sent), binding, [("mail_send", {"to": "a@x.com", "subject": "s", "text": "t"})], tmp_path=tmp_path)
    assert sent == []
    assert "no one can approve" in rows[0]["content"]["error"]


class _Conn:
    def __init__(self, tools):
        self.tools = tools

    def alive(self):
        return True


def _mcp_setup(clicked: list):
    """A browser server (it can navigate) and a connector with one tool marked
    destructive and one that is not."""
    browser = _Conn(
        [
            MCPToolInfo("browser_navigate", "", {"type": "object"}),
            MCPToolInfo("browser_tabs", "", {"type": "object"}),
            MCPToolInfo("browser_click", "", {"type": "object"}),
            MCPToolInfo("browser_snapshot", "", {"type": "object"}),
        ]
    )
    github = _Conn(
        [
            MCPToolInfo("delete_repo", "", {"type": "object"}, annotations={"destructiveHint": True}),
            MCPToolInfo("list_repos", "", {"type": "object"}, annotations={"readOnlyHint": True}),
            MCPToolInfo("create_issue", "", {"type": "object"}),
        ]
    )
    manager = SimpleNamespace(connections={"pw": browser, "github": github})
    reg = ToolRegistry()
    schema = {"description": "x", "type": "object", "properties": {}}
    for server, conn in manager.connections.items():
        for info in conn.tools:
            full = tool_name(server, info.name)
            reg.register(full, schema, lambda _f=full, **kw: clicked.append(_f) or {"ok": True})
    return manager, reg


def test_classification_is_structural(tmp_path):
    from chuk_agents_runtime.pai.approvals import action_rules

    manager, reg = _mcp_setup([])
    rules = action_rules(reg, manager, ActionApprovals(policy=ActionPolicy, ask=None))
    assert {name: rule.action_class for name, rule in rules.items()} == {
        "mcp__pw__browser_click": BROWSER_ACT,
        "mcp__github__delete_repo": MCP_DESTRUCTIVE,
    }


def test_browser_act_per_site(tmp_path):
    clicked: list = []
    manager, reg = _mcp_setup(clicked)
    store = _Store(ActionPolicy(modes={BROWSER_ACT: "ask"}))
    binding, asked = _binding(store, [ActionDecision(True, SCOPE_SITE)], site="shop.example.com")
    _run(
        reg,
        binding,
        [("mcp__pw__browser_click", {"element": "Buy now", "ref": "e1"}), ("mcp__pw__browser_click", {"element": "Confirm", "ref": "e2"})],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert len(asked) == 1
    assert asked[0].site == "shop.example.com"
    assert asked[0].summary == "Click Buy now on shop.example.com"
    assert "always_this_site" in asked[0].options
    assert store.remembered == [(BROWSER_ACT, SCOPE_SITE, "shop.example.com")]
    assert store.policy.mode(BROWSER_ACT) == "ask"  # the class stays "ask" elsewhere
    assert store.policy.evaluate(BROWSER_ACT, "other.example") == "ask"
    assert clicked == ["mcp__pw__browser_click", "mcp__pw__browser_click"]


def test_browser_act_default_allow_never_asks(tmp_path):
    clicked: list = []
    manager, reg = _mcp_setup(clicked)
    binding, asked = _binding(_Store(), [], site="shop.example.com")
    _, _, policy = _run(reg, binding, [("mcp__pw__browser_click", {"element": "x"})], tmp_path=tmp_path, mcp=manager)
    assert asked == [] and clicked == ["mcp__pw__browser_click"]
    assert not policy.requires_approval("mcp__pw__browser_click")


def test_destructive_connector_tool_asks_and_read_only_does_not(tmp_path):
    called: list = []
    manager, reg = _mcp_setup(called)
    binding, asked = _binding(_Store(), [ActionDecision(True, SCOPE_ONCE)])
    _run(
        reg,
        binding,
        [("mcp__github__list_repos", {}), ("mcp__github__delete_repo", {"repo": "old"})],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert [r.action_class for r in asked] == [MCP_DESTRUCTIVE]
    assert asked[0].details == {"server": "github", "remote_tool": "delete_repo", "arguments": '{"repo": "old"}'}
    assert called == ["mcp__github__list_repos", "mcp__github__delete_repo"]


def _herenow(monkeypatch, approval: str):
    import chuk_agents_runtime.herenow as herenow

    env = LocalEnvironment()
    modes: list[str] = []

    def fake_publisher(env_, mode, config, args):
        modes.append(mode)
        if mode == "scan":
            return {"ok": True, "file_count": 1, "total_bytes": 10}
        return {"ok": True, "url": "https://x.here.now"}

    monkeypatch.setattr(herenow, "_run_publisher", fake_publisher)
    config = HereNowConfig(enabled=True, approval=approval)
    reg = ToolRegistry()
    register_herenow_tools(reg, env, config, gate=lambda request: True)
    return env, reg, config, modes


def test_publish_follows_the_policy(monkeypatch, tmp_path):
    env, reg, config, modes = _herenow(monkeypatch, "ask")
    store = _Store()
    binding, asked = _binding(store, [ActionDecision(True, SCOPE_AGENT)])
    _run(reg, binding, [("herenow_publish", {"path": "site", "name": "Demo"})], tmp_path=tmp_path, herenow=config, env=env)
    assert asked[0].action_class == PUBLISH
    assert asked[0].publish.file_count == 1  # the honest scan still runs first
    assert asked[0].summary == "Publish Demo on the open internet"
    assert store.remembered == [(PUBLISH, SCOPE_AGENT, "")]
    assert modes[-1] == "publish"


def test_publish_auto_mode_still_honours_a_deny(monkeypatch, tmp_path):
    env, reg, config, modes = _herenow(monkeypatch, "auto")
    binding, asked = _binding(_Store(ActionPolicy(modes={PUBLISH: "deny"})), [])
    _, rows, _ = _run(reg, binding, [("herenow_publish", {"path": "site"})], tmp_path=tmp_path, herenow=config, env=env)
    assert asked == [] and modes == []
    assert "not allowed to publish" in rows[0]["content"]["error"]
    # Auto mode with the default policy publishes without a card.
    env, reg, config, modes = _herenow(monkeypatch, "auto")
    binding, asked = _binding(_Store(), [])
    (tmp_path / "b").mkdir()
    _run(reg, binding, [("herenow_publish", {"path": "site"})], tmp_path=tmp_path / "b", herenow=config, env=env)
    assert asked == [] and modes[-1] == "publish"


def test_a_deferred_destructive_tool_asks_after_tool_search(tmp_path):
    """Real MCP tools are deferred behind ``search_tools``: a tool that is both
    deferred and behind an approval is revealed by the search, then asks."""
    import httpx2

    from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
    from pai_fakes import FakeChatEndpoint, FakeSession, text_turn, tool_turn

    deleted: list = []
    conn = _Conn([MCPToolInfo("delete_customer", "", {"type": "object"}, annotations={"destructiveHint": True})])
    manager = SimpleNamespace(connections={"crm": conn})
    reg = ToolRegistry()
    reg.register(
        "mcp__crm__delete_customer",
        {"description": "Delete a customer record.", "type": "object", "properties": {"customer": {"type": "string"}}},
        lambda customer="": deleted.append(customer) or {"ok": True},
        deferrable=True,
    )
    reg.defer("mcp__crm__delete_customer")
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["delete customer"]})]),
            tool_turn([("c1", "mcp__crm__delete_customer", {"customer": "ACME"})]),
            text_turn(["gone"]),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    binding, asked = _binding(_Store(), [ActionDecision(True, SCOPE_ONCE)])
    _, extra = loop_setup(
        model, env=LocalEnvironment(), herenow_config=None, herenow_gate=None,
        registry=reg, mcp=manager, action_approvals=binding,
    )
    loop = AgentLoop(
        model, reg, StateStore(str(tmp_path / "s.db")), model_settings=settings,
        deferred_mode="pai", approval_policy=extra["approval_policy"],
    )
    assert loop.run("s", "delete ACME").final_answer == "gone"
    assert [r.action_class for r in asked] == [MCP_DESTRUCTIVE]
    assert deleted == ["ACME"]


def _unsearched_loop(tmp_path, reg, manager, binding, turns):
    """A Pydantic AI loop whose model calls deferred tools without a search."""
    import httpx2

    from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
    from pai_fakes import FakeChatEndpoint, FakeSession

    endpoint = FakeChatEndpoint(turns)
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    _, extra = loop_setup(
        model, env=LocalEnvironment(), herenow_config=None, herenow_gate=None,
        registry=reg, mcp=manager, action_approvals=binding,
    )
    store = StateStore(str(tmp_path / "s.db"))
    loop = AgentLoop(
        model, reg, store, model_settings=settings,
        deferred_mode="pai", approval_policy=extra["approval_policy"],
    )
    return loop, store, extra["approval_policy"]


@pytest.mark.parametrize("approved", [True, False])
def test_an_unsearched_deferred_call_behind_a_card_runs_once_when_approved(tmp_path, approved):
    """chuk_chat-3oh6: the model calls a deferred tool it never searched for,
    and the tool asks. Pydantic AI refuses the call ("not available yet")
    before its approval step; the loop shows the one card and, on a yes, runs
    the call itself, exactly once. A no runs nothing."""
    from pai_fakes import text_turn, tool_turn

    deleted: list = []
    conn = _Conn([MCPToolInfo("delete_customer", "", {"type": "object"}, annotations={"destructiveHint": True})])
    manager = SimpleNamespace(connections={"crm": conn})
    reg = ToolRegistry()
    reg.register(
        "mcp__crm__delete_customer",
        {"description": "Delete a customer record.", "type": "object", "properties": {"customer": {"type": "string"}}},
        lambda customer="": deleted.append(customer) or {"ok": True, "deleted": customer},
        deferrable=True,
    )
    reg.defer("mcp__crm__delete_customer")
    binding, asked = _binding(_Store(), [ActionDecision(approved, SCOPE_ONCE)])
    loop, store, _ = _unsearched_loop(
        tmp_path, reg, manager, binding,
        [tool_turn([("c1", "mcp__crm__delete_customer", {"customer": "ACME"})]), text_turn(["ok"])],
    )
    result = loop.run("s", "delete ACME")
    assert result.final_answer == "ok"
    assert [r.action_class for r in asked] == [MCP_DESTRUCTIVE]
    rows = [m.content for m in store.get_conversation(result.session_id) if m.role == "tool"]
    assert len(rows) == 1
    assert "not available yet" not in str(rows)
    if approved:
        assert deleted == ["ACME"]
        assert rows[0]["content"] == {"ok": True, "deleted": "ACME"}
    else:
        assert deleted == []
        assert rows[0]["content"]["declined"] is True


def test_an_unsearched_browser_act_approved_for_the_site_runs_both_presses(tmp_path):
    """The flow of chuk_chat-3oh6 in one run: two unsearched page-changing
    calls, one card answered "always this site". Both run, one card."""
    from pai_fakes import text_turn, tool_turn

    clicked: list = []
    manager = SimpleNamespace(connections={"pw": _Conn([
        MCPToolInfo("browser_navigate", "", {"type": "object"}),
        MCPToolInfo("browser_click", "", {"type": "object"}),
    ])})
    reg = ToolRegistry()
    for info in manager.connections["pw"].tools:
        full = tool_name("pw", info.name)
        reg.register(
            full, {"description": "x", "type": "object", "properties": {"ref": {"type": "string"}}},
            lambda _f=full, **kw: clicked.append(_f) or {"ok": True}, deferrable=True,
        )
        reg.defer(full)
    store_ = _Store(ActionPolicy(modes={BROWSER_ACT: "ask"}))
    binding, asked = _binding(store_, [ActionDecision(True, SCOPE_SITE)], site="https://shop.example/cart")
    loop, store, _ = _unsearched_loop(
        tmp_path, reg, manager, binding,
        [
            tool_turn([("c1", "mcp__pw__browser_click", {"ref": "e1"})]),
            tool_turn([("c2", "mcp__pw__browser_click", {"ref": "e2"})]),
            text_turn(["clicked twice"]),
        ],
    )
    result = loop.run("s", "click twice")
    assert result.final_answer == "clicked twice"
    assert [r.action_class for r in asked] == [BROWSER_ACT]
    assert clicked == ["mcp__pw__browser_click", "mcp__pw__browser_click"]
    rows = [m.content for m in store.get_conversation(result.session_id) if m.role == "tool"]
    assert "not available yet" not in str(rows)
