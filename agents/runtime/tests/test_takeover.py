"""Browser takeover (docs/WIRE_CONTRACT.md, "Browser takeover") and the loop's
phase observer (``heartbeat.phase``), runtime side.

The tool: ``request_takeover`` waits while the user does a login, a 2FA code
or a CAPTCHA in the live browser view. It is offered only while the agent's
own sandbox browser is the target, it is deferred behind ``search_tools``,
and an unsearched call still runs. The helpers: reading the current tab's URL
from a Playwright MCP answer, and deciding from the URL alone that the
sign-in page is gone.
"""

from __future__ import annotations

from chuk_agents_runtime import (
    PHASE_MODEL,
    PHASE_PREPARING,
    PHASE_TOOL,
    TAKEOVER_TOOL,
    RecordingTakeoverBackend,
    TakeoverWatch,
    build_runtime,
    current_tab_url,
    looks_like_auth_page,
    register_takeover_tool,
)
from chuk_agents_runtime.loop import AgentLoop
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.prompt import BASE_INSTRUCTIONS, upgrade_research_instructions
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.takeover import (
    REQUEST_TAKEOVER_SCHEMA,
    TAKEOVER_KINDS,
    clean_site,
    make_request_takeover_handler,
)

# -- the tool ------------------------------------------------------------------


def test_no_backend_registers_nothing():
    registry = ToolRegistry()
    register_takeover_tool(registry, None)
    assert not registry.has(TAKEOVER_TOOL)


def test_the_tool_is_deferrable_and_gated_on_the_sandbox_browser():
    registry = ToolRegistry()
    backend = RecordingTakeoverBackend()
    register_takeover_tool(registry, backend)
    spec = registry.spec(TAKEOVER_TOOL)
    assert spec.deferrable is True
    assert registry.available(TAKEOVER_TOOL)
    backend.is_available = False
    assert not registry.available(TAKEOVER_TOOL)


def test_the_schema_names_the_four_kinds():
    kind = REQUEST_TAKEOVER_SCHEMA["properties"]["kind"]
    assert kind["enum"] == ["login", "two_factor", "captcha", "other"]
    assert REQUEST_TAKEOVER_SCHEMA["required"] == ["kind"]
    assert set(REQUEST_TAKEOVER_SCHEMA["properties"]) == {"kind", "site", "reason"}


def test_done_returns_the_status_and_a_hint_never_content():
    backend = RecordingTakeoverBackend("done")
    handler = make_request_takeover_handler(backend)
    result = handler(kind="two_factor", site="github.com", reason="GitHub asks for the code")
    assert result["status"] == "done"
    assert "browser_snapshot" in result["note"]
    assert set(result) == {"status", "note"}
    assert backend.requests == [
        {"kind": "two_factor", "site": "github.com", "reason": "GitHub asks for the code"}
    ]


def test_every_status_passes_through():
    for status in ("done", "skipped", "timeout", "stopped"):
        result = make_request_takeover_handler(RecordingTakeoverBackend(status))(kind="login")
        assert result["status"] == status


def test_a_bad_kind_is_refused_before_anything_is_asked():
    backend = RecordingTakeoverBackend()
    result = make_request_takeover_handler(backend)(kind="password")
    assert result["ok"] is False and "kind" in result["error"]
    assert backend.requests == []
    assert set(TAKEOVER_KINDS) == {"login", "two_factor", "captcha", "other"}


def test_unavailable_explains_instead_of_asking():
    backend = RecordingTakeoverBackend(available=False)
    result = make_request_takeover_handler(backend)(kind="login")
    assert result["ok"] is False and "not available" in result["error"]
    assert backend.requests == []


def test_a_broken_backend_answer_is_an_error():
    class _Broken(RecordingTakeoverBackend):
        def request(self, kind, site, reason):
            return {"error": "no app"}

    result = make_request_takeover_handler(_Broken())(kind="captcha")
    assert result == {"ok": False, "error": "no app"}


def test_a_raising_backend_is_a_generic_error():
    class _Raising(RecordingTakeoverBackend):
        def request(self, kind, site, reason):
            raise RuntimeError("socket closed: secret detail")

    result = make_request_takeover_handler(_Raising())(kind="login", site="example.com")
    assert result == {"ok": False, "error": "the takeover could not be started"}


def test_site_is_a_host_name_and_the_reason_one_short_line():
    assert clean_site("https://accounts.google.com/v3/signin?x=1") == "accounts.google.com"
    assert clean_site("GitHub.com") == "github.com"
    assert clean_site("") == ""
    backend = RecordingTakeoverBackend()
    make_request_takeover_handler(backend)(kind="login", reason="line one\nline two " + "x" * 400)
    reason = backend.requests[0]["reason"]
    assert "\n" not in reason and len(reason) <= 200 and reason.endswith("…")


# -- the page watch -------------------------------------------------------------


def test_the_current_tab_is_read_from_a_tabs_list():
    text = (
        "### Open tabs\n"
        "- 0: [Inbox](https://mail.example.com/)\n"
        "- 1: (current) [Sign in - Google Accounts](https://accounts.google.com/v3/signin?hl=en)\n"
    )
    assert current_tab_url(text) == "https://accounts.google.com/v3/signin?hl=en"


def test_the_page_url_line_is_the_fallback():
    assert current_tab_url("### Page state\n- Page URL: https://github.com/login\n") == (
        "https://github.com/login"
    )
    assert current_tab_url("- 0: [Only](https://example.com/a)") == "https://example.com/a"
    assert current_tab_url("") is None
    assert current_tab_url(None) is None
    assert current_tab_url("No open tabs. Use the browser_navigate tool.") is None


def test_sign_in_and_check_pages_are_told_apart_from_the_rest():
    for url in (
        "https://accounts.google.com/v3/signin/identifier",
        "https://github.com/login",
        "https://github.com/sessions/two-factor/app",
        "https://www.google.com/sorry/index?continue=x",
        "https://id.atlassian.com/login",
        "https://example.com/oauth2/authorize?client_id=1",
        "https://shop.example.com/account/verify",
    ):
        assert looks_like_auth_page(url), url
    for url in (
        "https://github.com/",
        "https://myaccount.google.com/",
        "https://mail.google.com/mail/u/0/#inbox",
        "https://shop.example.com/orders/42",
    ):
        assert not looks_like_auth_page(url), url


def test_the_watch_waits_for_a_stable_page_that_is_not_a_sign_in():
    watch = TakeoverWatch("https://github.com/login")
    assert not watch.observe(None)
    assert not watch.observe("https://github.com/login")
    # Login -> 2FA: still a sign-in page, the wait stays open.
    assert not watch.observe("https://github.com/sessions/two-factor/app")
    # The repository page, read once: could be a step in a redirect chain.
    assert not watch.observe("https://github.com/acme/repo")
    # Read twice in a row: the user is through.
    assert watch.observe("https://github.com/acme/repo")


def test_a_redirect_chain_resets_the_count():
    watch = TakeoverWatch("https://www.google.com/sorry/index")
    assert not watch.observe("https://www.google.com/search?q=a")
    assert not watch.observe("https://www.google.com/search?q=b")
    assert watch.observe("https://www.google.com/search?q=b")


def test_a_watch_without_a_start_takes_the_first_url_as_the_start():
    watch = TakeoverWatch(None)
    assert not watch.observe("https://example.com/")
    assert not watch.observe("https://example.com/")
    assert not watch.observe("https://example.com/home")
    assert watch.observe("https://example.com/home")


# -- in a built runtime ---------------------------------------------------------


def test_build_runtime_defers_the_tool_and_runs_an_unsearched_call(tmp_path):
    backend = RecordingTakeoverBackend("done")
    model = MockModelClient(
        [
            tool_call_response((TAKEOVER_TOOL, {"kind": "login", "site": "github.com"})),
            "signed in, continuing",
        ]
    )
    loop = build_runtime(
        model, db_path=str(tmp_path / "state.db"), context_ladder=False, takeover=backend
    )
    assert loop.registry.has(TAKEOVER_TOOL)
    assert loop.registry.is_deferred(TAKEOVER_TOOL)
    result = loop.run("s1", "check my GitHub notifications")
    assert result.final_answer == "signed in, continuing"
    assert backend.requests == [{"kind": "login", "site": "github.com", "reason": ""}]
    store = StateStore(str(tmp_path / "state.db"))
    try:
        rows = [m.content for m in store.get_conversation(result.session_id)]
    finally:
        store.close()
    tool_rows = [r for r in rows if r.get("role") == "tool"]
    assert tool_rows and tool_rows[0]["name"] == TAKEOVER_TOOL
    assert tool_rows[0]["content"]["status"] == "done"


def test_without_a_backend_the_runtime_has_no_takeover(tmp_path):
    loop = build_runtime(
        MockModelClient(["hi"]), db_path=str(tmp_path / "state.db"), context_ladder=False
    )
    assert not loop.registry.has(TAKEOVER_TOOL)


# -- the prompt -----------------------------------------------------------------


def test_the_research_rules_name_the_takeover():
    research = BASE_INSTRUCTIONS.split("# Online research\n", 1)[1].split("# Your workspace\n", 1)[0]
    assert "`request_takeover`" in research
    assert "2FA" in research and "CAPTCHA" in research
    assert "browser_snapshot" in research


def test_an_old_session_gets_the_takeover_rule_once():
    start = BASE_INSTRUCTIONS.index("- If the browser stops at a login")
    end = BASE_INSTRUCTIONS.index("- If search or browser tools are unavailable")
    old = BASE_INSTRUCTIONS[:start] + BASE_INSTRUCTIONS[end:]
    assert "request_takeover" not in old
    upgraded = upgrade_research_instructions(old)
    assert upgraded == BASE_INSTRUCTIONS
    # Same text every round: the prefix cache holds.
    assert upgrade_research_instructions(upgraded) == upgraded


# -- the phase observer (heartbeat.phase) ---------------------------------------


def _echo_registry() -> ToolRegistry:
    registry = ToolRegistry()
    registry.register(
        "echo",
        {"type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"echo": v},
    )
    return registry


def test_the_loop_reports_preparing_model_and_tool(tmp_path):
    seen: list[tuple[str, str | None]] = []
    model = MockModelClient([tool_call_response(("echo", {"v": "hi"})), "finished"])
    loop = AgentLoop(
        model,
        _echo_registry(),
        StateStore(str(tmp_path / "s.db")),
        phase_observer=lambda phase, tool: seen.append((phase, tool)),
    )
    result = loop.run("k", "go")
    assert result.final_answer == "finished"
    assert seen == [
        (PHASE_PREPARING, None),
        (PHASE_MODEL, None),
        (PHASE_TOOL, "echo"),
        (PHASE_PREPARING, None),
        (PHASE_MODEL, None),
    ]


def test_a_raising_phase_observer_never_ends_the_run(tmp_path):
    def boom(phase, tool):
        raise RuntimeError("status sink down")

    model = MockModelClient([tool_call_response(("echo", {"v": "hi"})), "finished"])
    loop = AgentLoop(
        model, _echo_registry(), StateStore(str(tmp_path / "s.db")), phase_observer=boom
    )
    assert loop.run("k", "go").final_answer == "finished"


def test_build_runtime_passes_the_phase_observer(tmp_path):
    seen: list[tuple[str, str | None]] = []
    loop = build_runtime(
        MockModelClient(["hi"]),
        db_path=str(tmp_path / "state.db"),
        context_ladder=False,
        phase_observer=lambda phase, tool: seen.append((phase, tool)),
    )
    loop.run("s1", "hello")
    assert seen == [(PHASE_PREPARING, None), (PHASE_MODEL, None)]
