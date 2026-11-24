"""Vault payment cards and contacts, host side (CHAT-185): the store in the
secrets vault (at rest, encrypted), the frames and their replies, the default
card, the scrubber, and the guard on every session's MCP manager."""

from __future__ import annotations

import json
import sys

import pytest

from chuk_agents_runtime.vault import VaultGuard

from chuk_agents_executor import SecretsVault
from chuk_agents_executor.vault_frames import handle_vault_frame, vault_guard
from chuk_agents_executor.vault_items import VaultItemError

from test_login_vault import _boot

NUMBER = "378282246310005"
SPACED = "3782 822463 10005"
CVC = "7391"
KEY = bytes(range(32))


def _vault(tmp_path) -> SecretsVault:
    return SecretsVault(path=tmp_path / "secrets.enc", key=KEY)


def _card(vault, **kw):
    body = {"number": SPACED, "exp_month": 3, "exp_year": 29, "cvc": CVC, "name": "Jane", "label": "Personal"}
    body.update(kw)
    return vault.card_set(body)


def test_card_round_trip_at_rest_is_encrypted_and_public_view_has_no_number(tmp_path):
    vault = _vault(tmp_path)
    public = _card(vault)
    assert public["brand"] == "amex" and public["last4"] == "0005"
    assert public["exp_year"] == 2029 and public["has_cvc"] is True
    assert public["is_default"] is True  # the first card becomes the default
    assert NUMBER not in json.dumps(vault.card_entries()) and CVC not in json.dumps(vault.card_entries())
    raw = (tmp_path / "secrets.enc").read_text()
    assert NUMBER not in raw and CVC not in raw and "Personal" not in raw

    again = _vault(tmp_path)
    again.load()
    assert again.card_full(public["id"])["number"] == NUMBER
    assert again.card_full(public["id"])["cvc"] == CVC
    assert again.default_card_id == public["id"]


def test_card_checks(tmp_path):
    vault = _vault(tmp_path)
    with pytest.raises(VaultItemError) as exc:
        _card(vault, number="4242424242424241")
    assert "4242" not in str(exc.value)
    with pytest.raises(VaultItemError):
        _card(vault, exp_month=13)
    with pytest.raises(VaultItemError):
        _card(vault, cvc="12a")
    with pytest.raises(VaultItemError):
        vault.card_set({"id": "nope", "label": "x"})


def test_default_card_and_update_keep_number(tmp_path):
    vault = _vault(tmp_path)
    first = _card(vault)
    second = _card(vault, number="4242424242424242", label="Work")
    assert vault.default_card_id == first["id"]
    vault.card_set_default(second["id"])
    assert [c["is_default"] for c in vault.card_entries()] == [True, False]
    vault.card_set({"id": second["id"], "label": "Work 2"})
    assert vault.card_full(second["id"])["number"] == "4242424242424242"
    vault.card_delete(second["id"])
    assert vault.default_card_id is None


def test_scrub_values_mask_the_number_in_every_rendering(tmp_path):
    vault = _vault(tmp_path)
    _card(vault)
    scrubbed = vault.scrubber().scrub_text(f"a {NUMBER} b {SPACED} c 3782-8224-6310-005")
    assert NUMBER not in scrubbed and SPACED not in scrubbed and "3782-8224-6310-005" not in scrubbed
    assert CVC not in json.dumps(list(vault.scrub_values().values()))


def test_contacts_round_trip(tmp_path):
    vault = _vault(tmp_path)
    saved = vault.contact_set(
        {"label": "Home", "name": "Jane Appleseed",
         "phones": [{"number": "(555) 010-2001"}, {"number": "555-9", "primary": True}],
         "emails": ["jane@example.com"], "address": {"street": "1 Main St", "city": "Springfield"}}
    )
    assert [p["primary"] for p in saved["phones"]] == [False, True]
    assert saved["emails"] == [{"address": "jane@example.com", "primary": True}]
    with pytest.raises(VaultItemError):
        vault.contact_set({"label": "home"})
    with pytest.raises(VaultItemError):
        vault.contact_set({"label": "a:b"})
    again = _vault(tmp_path)
    again.load()
    assert again.contact_entries()[0]["address"]["city"] == "Springfield"


def test_frames_reply_without_card_values(tmp_path):
    vault = _vault(tmp_path)
    reply = handle_vault_frame(
        vault, "payment_vault_set",
        {"type": "payment_vault_set", "request_id": "r1", "number": NUMBER, "exp_month": 1,
         "exp_year": 2030, "cvc": CVC, "label": "Card"},
    )
    assert reply["type"] == "payment_vault" and reply["request_id"] == "r1"
    card_id = reply["saved"]["id"]
    assert reply["default_id"] == card_id
    assert NUMBER not in json.dumps(reply) and CVC not in json.dumps(reply)
    bad = handle_vault_frame(vault, "payment_vault_set", {"number": "1234"})
    assert "error" in bad and len(bad["entries"]) == 1
    assert handle_vault_frame(vault, "payment_vault_default", {"id": None})["default_id"] is None
    assert handle_vault_frame(vault, "payment_vault_delete", {"id": "x"})["error"]
    contact = handle_vault_frame(vault, "contact_vault_set", {"label": "Work", "name": "J"})
    assert contact["type"] == "contact_vault" and contact["entries"][0]["label"] == "Work"
    assert handle_vault_frame(None, "contact_vault_list", {})["error"]


def test_the_sealed_frames_round_trip_through_the_executor(tmp_path):
    vault = _vault(tmp_path)
    executor, controller = _boot(tmp_path, vault)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "payment_vault_set", "number": NUMBER, "exp_month": 1, "exp_year": 2030, "cvc": CVC}
        )
        set_reply = controller.collect(rid, timeout=10.0)
        rid = controller.send_payload({"type": "contact_vault_list"})
        contact_reply = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert set_reply[-1]["type"] == "payment_vault"
    assert set_reply[-1]["entries"][0]["last4"] == "0005"
    assert NUMBER not in json.dumps(set_reply) and CVC not in json.dumps(set_reply)
    assert contact_reply[-1]["type"] == "contact_vault"


def test_every_session_mcp_manager_gets_the_vault_guard_with_an_approver(tmp_path):
    vault = _vault(tmp_path)
    executor, _controller = _boot(tmp_path, vault)
    servers = [{"name": "fake", "command": sys.executable, "args": ["-c", "pass"], "auth": "none"}]
    manager = executor._session_mcp_manager("s1", servers)
    try:
        assert isinstance(manager.call_guard, VaultGuard)
        assert callable(manager.call_guard.approver)
        # No live run of the session: the approver says no, never yes.
        from chuk_agents_runtime.vault import describe_payment

        assert executor._payment_approver("s1")(
            describe_payment({"brand": "amex", "last4": "0005"}, "https://shop.example", [], ["number"])
        ) is False
    finally:
        manager.close()


def test_vault_guard_without_vault_refuses_cards():
    guard = vault_guard(None, "s1")
    calls = []

    class Manager:
        def call(self, server, tool, args):
            calls.append(tool)
            return {"ok": True, "content": "### Open tabs\n- 0: (current) [x](https://shop.example/)\n"}

    result = guard(Manager(), "pw", "browser_type", {"ref": "e1", "text": "{{card:default:number}}"},
                   lambda a: {"ok": True})
    assert result["ok"] is False
