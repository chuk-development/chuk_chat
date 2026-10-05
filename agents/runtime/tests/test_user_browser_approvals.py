"""The user's own browser asks before it acts (docs/WIRE_CONTRACT.md, "The
user's own browser"; bead chuk_chat-rixw). The same ``browser_act`` class,
policy and site allow-list as the sandbox browser, with two differences: the
class asks by default there, and opening a page or taking over a tab counts as
an action. No network."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from chuk_agents_runtime.action_policy import (
    BROWSER_ACT,
    SCOPE_ONCE,
    SCOPE_SITE,
    ActionApprovals,
    ActionDecision,
    ActionPolicy,
    user_browser_policy,
    user_browser_tool_acts,
)
from chuk_agents_runtime.environment import LocalEnvironment
from chuk_agents_runtime.loop import AgentLoop
from chuk_agents_runtime.mcp_client import MCPToolInfo, tool_name
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.pai.wiring import loop_setup
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore


# -- the policy -----------------------------------------------------------------


def test_the_user_browser_asks_unless_the_user_chose_otherwise():
    assert user_browser_policy(ActionPolicy()).evaluate(BROWSER_ACT, "github.com") == "ask"
    # An allowed site lifts the ask, exactly like the sandbox's list.
    listed = ActionPolicy(sites={BROWSER_ACT: ("github.com",)})
    assert user_browser_policy(listed).evaluate(BROWSER_ACT, "api.github.com") == "allow"
    assert user_browser_policy(listed).evaluate(BROWSER_ACT, "bank.example") == "ask"
    # The user's explicit choice for the coworker wins either way.
    assert user_browser_policy(ActionPolicy(modes={BROWSER_ACT: "allow"})).evaluate(BROWSER_ACT) == "allow"
    assert user_browser_policy(ActionPolicy(modes={BROWSER_ACT: "deny"})).evaluate(
        BROWSER_ACT, "github.com"
    ) == "deny"


def test_the_stored_policy_is_never_rewritten():
    stored = ActionPolicy()
    user_browser_policy(stored)
    assert stored.modes == {}
    assert stored.to_dict()["classes"][BROWSER_ACT] == "allow"


def test_which_extra_calls_act():
    assert user_browser_tool_acts("browser_navigate", {"url": "https://x.example"})
    assert user_browser_tool_acts("browser_navigate_back", {})
    assert user_browser_tool_acts("browser_tabs", {"action": "select", "tabId": 4})
    assert not user_browser_tool_acts("browser_tabs", {"action": "list"})
    assert not user_browser_tool_acts("browser_tabs", {"action": "new"})
    assert not user_browser_tool_acts("browser_snapshot", {})


# -- the loop ---------------------------------------------------------------------


class _Conn:
    def __init__(self, tools):
        self.tools = tools

    def alive(self):
        return True


def _extension_setup(called: list):
    """The add-on's server as ``agents-extension-mcp`` offers it."""
    names = [
        "browser_navigate",
        "browser_navigate_back",
        "browser_snapshot",
        "browser_click",
        "browser_type",
        "browser_press_key",
        "browser_tabs",
        "browser_close",
    ]
    manager = SimpleNamespace(
        connections={"playwright": _Conn([MCPToolInfo(n, "", {"type": "object"}) for n in names])}
    )
    reg = ToolRegistry()
    schema = {"description": "x", "type": "object", "properties": {}}
    for name in names:
        full = tool_name("playwright", name)
        reg.register(full, schema, lambda _f=full, **kw: called.append((_f, kw)) or {"ok": True})
    return manager, reg


class _Store:
    def __init__(self, policy: ActionPolicy | None = None) -> None:
        self.policy = policy or ActionPolicy()
        self.remembered: list[tuple[str, str, str]] = []

    def remember(self, action_class: str, scope: str, site: str) -> None:
        self.remembered.append((action_class, scope, site))
        self.policy = self.policy.remembered(action_class, scope, site)


def _binding(store: _Store, answers: list, *, site: str, tabs: dict[int, str] | None = None):
    asked: list = []

    def ask(request):
        asked.append(request)
        return answers.pop(0)

    def site_for(tool, args):
        if tool == "browser_navigate":
            from urllib.parse import urlsplit

            return (urlsplit(args.get("url") or "").hostname or "").lower()
        if tool == "browser_tabs" and args.get("action") == "select":
            return (tabs or {}).get(args.get("tabId"), "")
        return None

    binding = ActionApprovals(
        policy=lambda: user_browser_policy(store.policy),
        ask=ask,
        remember=store.remember,
        site=lambda: site,
        user_browser=True,
        site_for=site_for,
    )
    return binding, asked


def _run(reg, binding, calls, *, tmp_path: Path, mcp):
    model = MockModelClient([tool_call_response(*calls), "done"])
    _, extra = loop_setup(
        model,
        env=LocalEnvironment(),
        herenow_config=None,
        herenow_gate=None,
        registry=reg,
        mcp=mcp,
        action_approvals=binding,
    )
    store = StateStore(str(tmp_path / "state.db"))
    loop = AgentLoop(model, reg, store, approval_policy=extra["approval_policy"])
    result = loop.run("s", "go")
    rows = [m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool"]
    return rows, extra["approval_policy"]


def test_opening_a_page_asks_for_that_site_and_always_this_site_covers_the_clicks(tmp_path):
    called: list = []
    manager, reg = _extension_setup(called)
    store = _Store()
    binding, asked = _binding(store, [ActionDecision(True, SCOPE_SITE)], site="github.com")
    _run(
        reg,
        binding,
        [
            ("mcp__playwright__browser_navigate", {"url": "https://github.com/settings"}),
            ("mcp__playwright__browser_click", {"element": "Save", "ref": "e3"}),
        ],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert len(asked) == 1, "the click on the allowed site must not ask again"
    card = asked[0]
    assert card.action_class == BROWSER_ACT
    assert card.site == "github.com"
    assert card.summary == "Open github.com"
    assert card.details["browser"] == "user_browser"
    assert card.details["url"] == "https://github.com/settings"
    assert "always_this_site" in card.options
    assert store.remembered == [(BROWSER_ACT, SCOPE_SITE, "github.com")]
    assert [c[0] for c in called] == [
        "mcp__playwright__browser_navigate",
        "mcp__playwright__browser_click",
    ]


def test_a_click_asks_where_the_sandbox_would_not(tmp_path):
    called: list = []
    manager, reg = _extension_setup(called)
    binding, asked = _binding(_Store(), [ActionDecision(False, SCOPE_ONCE)], site="shop.example")
    rows, _ = _run(
        reg,
        binding,
        [("mcp__playwright__browser_click", {"element": "Buy now", "ref": "e1"})],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert len(asked) == 1
    assert asked[0].summary == "Click Buy now on shop.example"
    assert asked[0].details["browser"] == "user_browser"
    assert called == [], "a no must not reach the browser"
    assert rows[0]["content"]["declined"] is True


def test_reading_never_asks(tmp_path):
    called: list = []
    manager, reg = _extension_setup(called)
    binding, asked = _binding(_Store(), [], site="github.com")
    _, policy = _run(
        reg,
        binding,
        [
            ("mcp__playwright__browser_tabs", {"action": "list"}),
            ("mcp__playwright__browser_snapshot", {}),
            ("mcp__playwright__browser_close", {}),
        ],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert asked == []
    # A tab list is deferred for the policy check and runs after the others.
    assert sorted(c[0] for c in called) == [
        "mcp__playwright__browser_close",
        "mcp__playwright__browser_snapshot",
        "mcp__playwright__browser_tabs",
    ]
    assert not policy.requires_approval("mcp__playwright__browser_snapshot")


def test_taking_over_a_tab_asks_with_the_site_of_that_tab(tmp_path):
    called: list = []
    manager, reg = _extension_setup(called)
    binding, asked = _binding(
        _Store(), [ActionDecision(True, SCOPE_ONCE)], site="", tabs={812: "mail.example.org"}
    )
    _run(
        reg,
        binding,
        [("mcp__playwright__browser_tabs", {"action": "select", "tabId": 812})],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert len(asked) == 1
    assert asked[0].summary == "Take over your tab on mail.example.org"
    assert asked[0].details["tab_id"] == 812
    assert asked[0].site == "mail.example.org"
    assert len(called) == 1


def test_a_deny_for_the_coworker_refuses_without_a_card(tmp_path):
    called: list = []
    manager, reg = _extension_setup(called)
    binding, asked = _binding(_Store(ActionPolicy(modes={BROWSER_ACT: "deny"})), [], site="github.com")
    rows, _ = _run(
        reg,
        binding,
        [("mcp__playwright__browser_navigate", {"url": "https://github.com"})],
        tmp_path=tmp_path,
        mcp=manager,
    )
    assert asked == [] and called == []
    assert "not allowed" in rows[0]["content"]["error"]


def test_the_sandbox_browser_is_unchanged(tmp_path):
    """Without ``user_browser`` the extra tools stay free and the class keeps
    its ``allow`` default."""
    from chuk_agents_runtime.pai.approvals import action_rules

    manager, reg = _extension_setup([])
    rules = action_rules(reg, manager, ActionApprovals(policy=ActionPolicy, ask=None))
    assert set(rules) == {
        "mcp__playwright__browser_click",
        "mcp__playwright__browser_type",
        "mcp__playwright__browser_press_key",
    }
    user_rules = action_rules(
        reg, manager, ActionApprovals(policy=ActionPolicy, ask=None, user_browser=True)
    )
    assert set(user_rules) == set(rules) | {
        "mcp__playwright__browser_navigate",
        "mcp__playwright__browser_navigate_back",
        "mcp__playwright__browser_tabs",
    }
