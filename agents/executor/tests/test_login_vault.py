"""Login vault for the browser (Hermes H32), host side: the store in the
secrets vault (at rest, encrypted), the three app frames and their terminal
reply, the audit file, and the guard on every session's MCP manager."""

from __future__ import annotations

import json
import os
import sys

from chuk_agents_runtime.login_vault import LoginGuard
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, SecretsVault, loopback_pair
from chuk_agents_executor.login_vault import handle_login_vault_frame
from chuk_agents_executor.secrets import LOGIN_AUDIT_FILENAME, LoginVaultError

from wiring import paired_channel

PASSWORD = "correct-horse-battery-staple"
TOTP = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
KEY = bytes(range(32))


def _vault(tmp_path, key: bytes = KEY) -> SecretsVault:
    return SecretsVault(path=tmp_path / "secrets.enc", key=key)


def _set(vault, **kw):
    args = {"origin": "https://github.com/login", "username": "octo", "password": PASSWORD}
    args.update(kw)
    return vault.login_set(**args)


# -- the store -------------------------------------------------------------------


def test_round_trip_at_rest_is_encrypted(tmp_path):
    vault = _vault(tmp_path)
    vault.replace({"API_KEY": "sk-0123456789"}, revision=3)
    saved = _set(vault, totp_secret=TOTP, label="work")
    assert saved["origin"] == "https://github.com"
    assert saved["has_totp"] is True
    assert "password" not in saved and "totp_secret" not in saved

    raw = (tmp_path / "secrets.enc").read_bytes()
    assert PASSWORD.encode() not in raw and TOTP.encode() not in raw and b"octo" not in raw

    again = _vault(tmp_path)
    again.load()
    assert again.login_entries() == vault.login_entries()
    full = again.login_lookup("https://github.com")[0]
    assert full["password"] == PASSWORD and full["totp_secret"] == TOTP
    assert again.env() == {"API_KEY": "sk-0123456789"}

    # A foreign key opens nothing.
    foreign = _vault(tmp_path, key=bytes(32))
    foreign.load()
    assert foreign.login_entries() == []


def test_logins_never_reach_env_but_the_scrubber_masks_them(tmp_path):
    vault = _vault(tmp_path)
    saved = _set(vault, totp_secret=TOTP)
    assert vault.env() == {}
    masked = vault.scrubber().scrub_text(f"page says {PASSWORD} and {TOTP}")
    assert PASSWORD not in masked and TOTP not in masked
    assert f"[REDACTED:login:https://github.com#{saved['id']}:password]" in masked


def test_a_secrets_frame_does_not_drop_the_logins(tmp_path):
    vault = _vault(tmp_path)
    _set(vault)
    vault.replace({"A": "12345678"}, revision=2)
    assert len(vault.login_entries()) == 1


def test_upsert_by_origin_and_username(tmp_path):
    vault = _vault(tmp_path)
    first = _set(vault, totp_secret=TOTP, label="work")
    second = _set(vault, password="new-password-1")
    assert second["id"] == first["id"]
    assert second["label"] == "work" and second["has_totp"] is True  # kept
    assert vault.login_lookup("https://github.com")[0]["password"] == "new-password-1"
    third = _set(vault, totp_secret=None)
    assert third["has_totp"] is False
    other = _set(vault, username="someone-else")
    assert other["id"] != first["id"]
    assert len(vault.login_entries()) == 2


def test_bad_logins_are_refused(tmp_path):
    vault = _vault(tmp_path)
    for kw in (
        {"origin": "http://github.com"},
        {"origin": "github.com"},
        {"username": ""},
        {"password": ""},
        {"totp_secret": "not a key!"},
    ):
        try:
            _set(vault, **kw)
        except LoginVaultError:
            continue
        raise AssertionError(f"accepted {kw}")
    assert _set(vault, origin="http://localhost:8080")["origin"] == "http://localhost:8080"


def test_delete_and_last_used(tmp_path):
    vault = _vault(tmp_path)
    saved = _set(vault)
    assert saved["last_used_at"] is None
    vault.login_used(saved["id"])
    assert vault.login_entries()[0]["last_used_at"] is not None
    assert vault.login_delete(saved["id"]) is True
    assert vault.login_delete(saved["id"]) is False
    assert vault.login_entries() == []


def test_audit_lines_hold_no_value(tmp_path):
    vault = _vault(tmp_path)
    vault.login_audit(
        {
            "ts": 1.0,
            "session_key": "s1",
            "origin": "https://github.com",
            "entry_id": "e1",
            "fields": ["password"],
            "tool": "browser_type",
            "outcome": "filled",
            "password": PASSWORD,  # an unknown key is never written
        }
    )
    path = tmp_path / LOGIN_AUDIT_FILENAME
    line = json.loads(path.read_text().strip())
    assert line == {
        "ts": 1.0,
        "session_key": "s1",
        "origin": "https://github.com",
        "entry_id": "e1",
        "fields": ["password"],
        "tool": "browser_type",
        "outcome": "filled",
    }
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"


# -- the frames -------------------------------------------------------------------


def test_frames_set_list_delete_never_return_a_secret(tmp_path):
    vault = _vault(tmp_path)
    reply = handle_login_vault_frame(
        vault,
        "login_vault_set",
        {"type": "login_vault_set", "origin": "https://github.com", "username": "octo",
         "password": PASSWORD, "totp_secret": TOTP, "label": "work"},
    )
    assert reply["type"] == "login_vault"
    assert "error" not in reply
    entry = reply["entries"][0]
    assert set(entry) == {"id", "origin", "username", "label", "has_totp", "created_at", "last_used_at"}
    assert reply["saved"] == entry
    text = json.dumps(reply)
    assert PASSWORD not in text and TOTP not in text

    listed = handle_login_vault_frame(vault, "login_vault_list", {})
    assert listed == {"type": "login_vault", "entries": [entry]}

    gone = handle_login_vault_frame(vault, "login_vault_delete", {"id": entry["id"]})
    assert gone == {"type": "login_vault", "entries": [], "deleted": entry["id"]}
    again = handle_login_vault_frame(vault, "login_vault_delete", {"id": entry["id"]})
    assert again["error"] == "no login with this id"


def test_a_bad_set_frame_answers_with_an_error(tmp_path):
    vault = _vault(tmp_path)
    reply = handle_login_vault_frame(
        vault, "login_vault_set", {"origin": "http://github.com", "username": "a", "password": PASSWORD}
    )
    assert reply["entries"] == [] and "https" in reply["error"]
    assert PASSWORD not in json.dumps(reply)


def test_no_vault_answers_with_an_error():
    reply = handle_login_vault_frame(None, "login_vault_list", {})
    assert reply["entries"] == [] and reply["error"]


def test_every_reply_echoes_the_request_id(tmp_path):
    # The app matches its answer by request_id: a list reply must never be
    # taken for the answer to a save sent at the same time.
    vault = _vault(tmp_path)
    saved = handle_login_vault_frame(
        vault,
        "login_vault_set",
        {"origin": "https://github.com", "username": "octo", "password": PASSWORD, "request_id": "lv-1"},
    )
    assert saved["request_id"] == "lv-1" and saved["saved"]
    listed = handle_login_vault_frame(vault, "login_vault_list", {"request_id": "lv-2"})
    assert listed["request_id"] == "lv-2"
    refused = handle_login_vault_frame(
        vault, "login_vault_delete", {"id": "nope", "request_id": "lv-3"}
    )
    assert refused["request_id"] == "lv-3" and refused["error"]
    assert handle_login_vault_frame(None, "login_vault_list", {"request_id": "lv-4"})["request_id"] == "lv-4"
    # No id (an old app) or a junk id: no echo.
    assert "request_id" not in handle_login_vault_frame(vault, "login_vault_list", {})
    assert "request_id" not in handle_login_vault_frame(
        vault, "login_vault_list", {"request_id": "x" * 500}
    )
    assert "request_id" not in handle_login_vault_frame(vault, "login_vault_list", {"request_id": 7})


# -- through the executor -------------------------------------------------------------


def _boot(tmp_path, vault):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    workspace = tmp_path / "ws"
    workspace.mkdir()
    executor = Executor(
        name="keeper",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: None,
        workspace=str(workspace),
        secrets=vault,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def test_the_sealed_frames_round_trip_through_the_executor(tmp_path):
    vault = _vault(tmp_path)
    executor, controller = _boot(tmp_path, vault)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "login_vault_set", "origin": "https://github.com", "username": "octo",
             "password": PASSWORD}
        )
        set_reply = controller.collect(rid, timeout=10.0)
        rid = controller.send_payload({"type": "login_vault_list"})
        list_reply = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert set_reply[-1]["type"] == "login_vault"
    assert set_reply[-1]["entries"][0]["username"] == "octo"
    assert list_reply[-1]["entries"] == set_reply[-1]["entries"]
    assert PASSWORD not in json.dumps(set_reply + list_reply)
    assert vault.login_lookup("https://github.com")[0]["password"] == PASSWORD


def test_every_session_mcp_manager_gets_the_login_guard(tmp_path):
    vault = _vault(tmp_path)
    executor, _controller = _boot(tmp_path, vault)
    servers = [{"name": "fake", "command": sys.executable, "args": ["-c", "pass"], "auth": "none"}]
    manager = executor._session_mcp_manager("s1", servers)
    try:
        assert isinstance(manager.call_guard, LoginGuard)
    finally:
        manager.close()
