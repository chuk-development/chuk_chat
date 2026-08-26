"""``browser_task`` — the browser fallback (§8, §9).

What is pinned here:

* **Nothing leaks into the prompt without a browser.** Without ``browser_use``
  (or without a Chromium / CDP endpoint) the tool's ``check_fn`` is false, it is
  absent from the rendered tool docs, and a call to it comes back as a clean
  ``tool unavailable`` envelope rather than an exception.
* **The model bridge really is our client.** One ``ainvoke`` lands on the
  injected client, the reply is converted (plain text and structured), a client
  failure is raised as :class:`ModelBridgeError` and never swallowed, and image
  parts are dropped *and counted* because the ``/v2/ws`` route carries text only.
* **The URL policy runs before a browser exists.** A forbidden target is refused
  without the runner ever being called.
* **The step cap holds and the cost comes back.** ``max_steps`` is clamped to
  :data:`MAX_MAX_STEPS`, and the usage block is in the result on success, on a
  model failure and on a timeout.
* **Screenshots go to the user, not into the prompt.**

A real browser run is exercised only when ``browser-use`` and a Chromium binary
are genuinely present; otherwise it skips. Nothing here installs a browser.
"""

from __future__ import annotations

import asyncio

import pytest

from cowork_agent import render_tool_docs
from cowork_agent.browser import (
    DEFAULT_MAX_STEPS,
    EXECUTABLE_ENV_VAR,
    MAX_MAX_STEPS,
    BackendChatModel,
    BridgeUsage,
    BrowserRunOutcome,
    BrowserTaskSpec,
    ModelBridgeError,
    browser_use_available,
    domain_scope,
    extract_json_object,
    find_chromium,
    make_browser_task_handler,
    messages_to_dicts,
    outcome_from_history,
    parse_domain_list,
    register_browser_task,
    registrable_domain,
)
from cowork_agent.model import ModelResponse
from cowork_agent.registry import ToolRegistry

# -- doubles ------------------------------------------------------------------


class FakeClient:
    """A ``ModelClient`` that replays scripted replies and records the turns it
    was given. ``(text, usage)`` tuples carry a backend ``usage`` frame; an
    ``Exception`` item is raised instead of answered."""

    def __init__(self, replies: list) -> None:
        self.replies = list(replies)
        self.calls: list[list[dict]] = []

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.calls.append([dict(m) for m in messages])
        if not self.replies:
            return ModelResponse(text="", raw={"content": ""})
        item = self.replies.pop(0)
        if isinstance(item, Exception):
            raise item
        text, usage = item if isinstance(item, tuple) else (item, None)
        raw = {"content": text}
        if usage is not None:
            raw["usage"] = usage
        return ModelResponse(text=text, raw=raw)


class FakeRunner:
    """Records the :class:`BrowserTaskSpec` it was handed and returns a scripted
    outcome — or raises, to test the money-still-reported paths."""

    def __init__(self, outcome: BrowserRunOutcome | Exception | None = None) -> None:
        self.outcome = outcome if outcome is not None else BrowserRunOutcome(done=True)
        self.specs: list[BrowserTaskSpec] = []
        self.llms: list = []

    async def run(self, spec: BrowserTaskSpec, llm) -> BrowserRunOutcome:
        self.specs.append(spec)
        self.llms.append(llm)
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self.outcome


class Part:
    def __init__(self, kind: str, text: str = "", url: str = "") -> None:
        self.type = kind
        self.text = text
        self.image_url = url


class Message:
    def __init__(self, role: str, content) -> None:
        self.role = role
        self.content = content


class Sink:
    def __init__(self, raises: Exception | None = None) -> None:
        self.received: list = []
        self.raises = raises

    def __call__(self, sent) -> None:
        if self.raises is not None:
            raise self.raises
        self.received.append(sent)


try:  # pydantic ships with browser-use, but cowork-agent does not depend on it
    from pydantic import BaseModel as _PydanticBase
except ImportError:  # pragma: no cover - depends on the installed extras
    _PydanticBase = None


if _PydanticBase is not None:

    class FakeSchema(_PydanticBase):
        """Stands in for browser-use's ``AgentOutput``.

        A **real** pydantic model where pydantic is installed, because
        ``ChatInvokeCompletion.completion`` is typed ``BaseModel | str`` and
        validates: a duck-typed double passes the offline suite and then fails
        against the real library, which is exactly the bug this once hid.
        """

        action: str
        index: int | None = None

    def schema_data(parsed) -> dict:
        return parsed.model_dump(exclude_none=True)

else:

    class FakeSchema:  # type: ignore[no-redef]
        """The duck-typed fallback: the two pydantic entry points the bridge uses."""

        def __init__(self, **data) -> None:
            self.data = data

        @classmethod
        def model_validate(cls, data: dict):
            if "action" not in data:
                raise ValueError("action is required")
            return cls(**data)

        @classmethod
        def model_json_schema(cls) -> dict:
            return {"type": "object", "properties": {"action": {"type": "string"}}}

    def schema_data(parsed) -> dict:
        return parsed.data


def public_resolver(host: str, port: int) -> list[str]:
    """A DNS stand-in, so a rejection in a test can only come from a rule and
    never from the network. An address literal answers with itself, exactly as
    ``getaddrinfo`` does; two names are wired to point somewhere internal."""
    import ipaddress

    del port
    try:
        return [str(ipaddress.ip_address(host.strip("[]")))]
    except ValueError:
        pass
    if host in ("localhost", "metadata.google.internal"):
        return ["127.0.0.1"]
    if host == "internal.example.com":
        return ["10.1.2.3"]
    return ["93.184.216.34"]


def handler(runner, *, client=None, sink=None, **kwargs):
    return make_browser_task_handler(
        client or FakeClient(["ok"]),
        runner=runner,
        file_sink=sink,
        resolve=public_resolver,
        **kwargs,
    )


def run(coro):
    return asyncio.run(coro)


# -- availability / prompt ----------------------------------------------------


def test_unavailable_tool_is_absent_from_the_prompt_and_dispatches_cleanly():
    registry = ToolRegistry()
    register_browser_task(
        registry,
        FakeClient([]),
        runner=FakeRunner(),
        available=lambda: False,
    )

    assert registry.has("browser_task")
    assert registry.available("browser_task") is False
    assert "browser_task" not in render_tool_docs(registry)

    result = registry.dispatch("browser_task", {"task": "x", "start_url": "https://a.com"})
    assert result == {"error": "tool unavailable: browser_task", "tool": "browser_task"}


def test_available_tool_is_documented_with_its_arguments():
    registry = ToolRegistry()
    register_browser_task(
        registry, FakeClient([]), runner=FakeRunner(), available=lambda: True
    )

    docs = render_tool_docs(registry)
    assert "browser_task" in docs
    assert "start_url" in docs
    assert "max_steps" in docs


def test_no_model_means_no_tool_at_all():
    registry = ToolRegistry()
    register_browser_task(registry, None, runner=FakeRunner())
    assert registry.has("browser_task") is False


def test_a_probe_that_raises_counts_as_unavailable():
    registry = ToolRegistry()

    def broken() -> bool:
        raise RuntimeError("no browser")

    register_browser_task(registry, FakeClient([]), runner=FakeRunner(), available=broken)
    assert registry.available("browser_task") is False


def test_find_chromium_prefers_the_explicit_executable(tmp_path, monkeypatch):
    binary = tmp_path / "chromium"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    binary.chmod(0o755)
    monkeypatch.setenv(EXECUTABLE_ENV_VAR, str(binary))
    assert find_chromium() == str(binary)


def test_find_chromium_rejects_a_configured_path_that_is_not_executable(tmp_path, monkeypatch):
    missing = tmp_path / "nope"
    monkeypatch.setenv(EXECUTABLE_ENV_VAR, str(missing))
    assert find_chromium() is None


# -- the model bridge ---------------------------------------------------------


def test_a_plain_call_lands_on_our_client_and_comes_back_as_text():
    client = FakeClient([("hello there", {"prompt_tokens": 30, "completion_tokens": 5})])
    bridge = BackendChatModel(client, model="test-model")

    completion = run(bridge.ainvoke([Message("user", "hi")]))

    assert completion.completion == "hello there"
    assert client.calls == [[{"role": "user", "content": "hi"}]]
    assert bridge.usage.invocations == 1
    assert bridge.usage.prompt_tokens == 30
    assert bridge.usage.completion_tokens == 5
    assert bridge.usage.total_tokens == 35


def test_the_bridge_identifies_itself_as_our_backend():
    bridge = BackendChatModel(FakeClient([]), model="deepseek/deepseek-v4-flash")
    assert bridge.provider == "cowork-backend"
    assert bridge.name == "deepseek/deepseek-v4-flash"
    assert bridge.model_name == "deepseek/deepseek-v4-flash"
    # No API key to verify: browser-use must not run its own probe.
    assert bridge._verified_api_keys is True


def test_structured_output_is_validated_out_of_a_fenced_reply():
    client = FakeClient(['```json\n{"action": "click", "index": 3}\n```'])
    bridge = BackendChatModel(client, usage=BridgeUsage())

    completion = run(bridge.ainvoke([Message("user", "go")], FakeSchema))

    assert isinstance(completion.completion, FakeSchema)
    assert schema_data(completion.completion) == {"action": "click", "index": 3}
    # The schema was actually put in front of the model.
    assert "properties" in client.calls[0][-1]["content"]
    assert bridge.usage.structured_retries == 0


def test_a_reply_that_is_not_json_is_repaired_once_and_the_retry_is_counted():
    client = FakeClient(["I will click the button", '{"action": "click"}'])
    bridge = BackendChatModel(client)

    completion = run(bridge.ainvoke([Message("user", "go")], FakeSchema))

    assert schema_data(completion.completion) == {"action": "click"}
    assert bridge.usage.structured_retries == 1
    assert bridge.usage.invocations == 2
    # The repair round tells the model what was wrong with the last one.
    assert "JSON" in client.calls[1][-1]["content"]


def test_structured_output_that_never_validates_raises_and_is_not_faked():
    client = FakeClient(["nope", "still nope"])
    bridge = BackendChatModel(client)

    with pytest.raises(ModelBridgeError):
        run(bridge.ainvoke([Message("user", "go")], FakeSchema))
    assert bridge.usage.invocations == 2


def test_a_reply_that_parses_but_fails_the_schema_raises():
    client = FakeClient(['{"wrong": 1}', '{"wrong": 2}'])
    bridge = BackendChatModel(client)

    with pytest.raises(ModelBridgeError) as excinfo:
        run(bridge.ainvoke([Message("user", "go")], FakeSchema))
    assert "structured output" in str(excinfo.value)


def test_a_client_failure_is_raised_not_swallowed_and_still_counted():
    client = FakeClient([RuntimeError("socket died")])
    bridge = BackendChatModel(client)

    with pytest.raises(ModelBridgeError) as excinfo:
        run(bridge.ainvoke([Message("user", "hi")]))
    assert "socket died" in str(excinfo.value)
    assert bridge.usage.invocations == 1
    assert bridge.usage.unreported_rounds == 1


def test_image_parts_are_dropped_and_counted_never_silently_lost():
    client = FakeClient(["fine"])
    bridge = BackendChatModel(client)
    content = [Part("text", text="look at this"), Part("image_url", url="data:image/png;base64,AA")]

    run(bridge.ainvoke([Message("user", content)]))

    assert client.calls[0] == [{"role": "user", "content": "look at this"}]
    assert bridge.usage.images_dropped == 1


def test_a_round_without_a_usage_frame_is_marked_so_tokens_read_as_a_floor():
    client = FakeClient(["answer"])
    bridge = BackendChatModel(client)

    run(bridge.ainvoke([Message("user", "hi")]))

    assert bridge.usage.total_tokens == 0
    assert bridge.usage.unreported_rounds == 1


def test_message_roles_and_shapes_survive_the_conversion():
    turns, dropped = messages_to_dicts(
        [
            Message("system", "be brief"),
            Message("user", [Part("text", text="a"), Part("text", text="b")]),
            Message("assistant", None),
            Message("tool", "unknown role"),
        ]
    )
    assert dropped == 0
    assert turns[0] == {"role": "system", "content": "be brief"}
    assert turns[1] == {"role": "user", "content": "a\nb"}
    assert turns[2] == {"role": "assistant", "content": ""}
    # An unknown role must not reach the backend as itself.
    assert turns[3]["role"] == "user"


@pytest.mark.parametrize(
    "text, expected",
    [
        ('{"a": 1}', {"a": 1}),
        ('```json\n{"a": 1}\n```', {"a": 1}),
        ('```\n{"a": 1}\n```', {"a": 1}),
        ('Sure! {"a": "}"}  done', {"a": "}"}),
        ('prose {not json} then {"a": 2}', {"a": 2}),
        ("[1, 2]", None),
        ("no braces", None),
        ("", None),
        (None, None),
    ],
)
def test_extract_json_object(text, expected):
    assert extract_json_object(text) == expected


# -- URL policy ---------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1:8080/",
        "http://localhost/admin",
        "http://169.254.169.254/latest/meta-data/",
        "https://internal.example.com/",
        "file:///etc/passwd",
        "ftp://example.com/",
        "https://user:pw@example.com/",
        "https://[::1]/",
        "not a url",
        "",
    ],
)
def test_a_forbidden_target_is_refused_before_a_browser_starts(url):
    runner = FakeRunner()
    result = run(handler(runner)("export the table", url))

    assert result["ok"] is False
    assert "rejected" in result["error"] or "malformed" in result["error"]
    assert runner.specs == [], "the runner must never see a rejected URL"


def test_an_empty_task_is_refused_without_a_browser():
    runner = FakeRunner()
    result = run(handler(runner)("   ", "https://example.com/"))
    assert result["ok"] is False
    assert runner.specs == []


def test_navigation_is_scoped_to_the_start_url_and_the_local_names_are_banned():
    runner = FakeRunner()
    run(
        handler(runner)(
            "log in and export",
            "https://app.example.com/login",
            allow_domains="https://idp.other.com/, *.cdn.example.net",
        )
    )

    spec = runner.specs[0]
    assert "app.example.com" in spec.allowed_domains
    assert "*.example.com" in spec.allowed_domains
    # A URL where a domain was wanted is reduced to its host.
    assert "idp.other.com" in spec.allowed_domains
    assert "*.cdn.example.net" in spec.allowed_domains
    assert "localhost" in spec.prohibited_domains
    assert "metadata.google.internal" in spec.prohibited_domains


def test_domain_scope_keeps_a_two_label_host_from_becoming_a_wildcard_of_a_tld():
    assert domain_scope("https://example.com/x") == ["example.com", "*.example.com"]


@pytest.mark.parametrize(
    "url, forbidden",
    [
        ("https://app.example.co.uk/login", "*.co.uk"),
        ("https://site.example.com.au/x", "*.com.au"),
        ("https://a.b.example.co.jp/x", "*.co.jp"),
    ],
)
def test_a_public_suffix_never_becomes_the_allowed_scope(url, forbidden):
    """`*.co.uk` as an allowed domain is every host in a country. The wildcard
    must stop at the registrable domain."""
    scope = domain_scope(url)
    assert forbidden not in scope
    assert any(item.startswith("*.example.") for item in scope)


def test_a_host_that_is_only_a_registrable_domain_gets_no_extra_wildcard():
    assert domain_scope("https://example.co.uk/") == ["example.co.uk", "*.example.co.uk"]
    assert domain_scope("https://localhost.localdomain/") == [
        "localhost.localdomain",
        "*.localhost.localdomain",
    ]


def test_registrable_domain_cases():
    assert registrable_domain("www.example.com") == "example.com"
    assert registrable_domain("app.example.co.uk") == "example.co.uk"
    # Already the registrable domain: it is returned, and `domain_scope` then
    # adds no second wildcard because it equals the host.
    assert registrable_domain("example.co.uk") == "example.co.uk"
    # A bare public suffix has no registrable domain at all.
    assert registrable_domain("co.uk") == ""
    assert registrable_domain("com") == ""
    assert registrable_domain("") == ""


def test_parse_domain_list_takes_a_string_or_a_list():
    assert parse_domain_list("a.com, b.com;c.com") == ["a.com", "b.com", "c.com"]
    assert parse_domain_list(["A.com", "a.com"]) == ["a.com"]
    assert parse_domain_list(None) == []


# -- the step cap and the cost report ----------------------------------------


def test_the_step_cap_holds_whatever_the_model_asks_for():
    runner = FakeRunner()
    run(handler(runner)("t", "https://example.com/", max_steps=9999))
    assert runner.specs[0].max_steps == MAX_MAX_STEPS

    runner = FakeRunner()
    run(handler(runner)("t", "https://example.com/", max_steps=-3))
    assert runner.specs[0].max_steps == 1

    runner = FakeRunner()
    run(handler(runner)("t", "https://example.com/", max_steps="not a number"))
    assert runner.specs[0].max_steps == DEFAULT_MAX_STEPS


def test_a_lower_ceiling_can_be_configured():
    runner = FakeRunner()
    run(handler(runner, max_steps_ceiling=3)("t", "https://example.com/", max_steps=20))
    assert runner.specs[0].max_steps == 3


def test_the_result_reports_what_the_session_cost():
    client = FakeClient([])
    runner = FakeRunner(
        BrowserRunOutcome(
            done=True, success=True, steps=4, result="12 rows exported", urls=["https://example.com/"]
        )
    )
    outer = handler(runner, client=client)

    result = run(outer("export", "https://example.com/", max_steps=6))

    assert result["ok"] is True
    assert result["steps"] == 4
    assert result["steps_allowed"] == 6
    assert result["result"] == "12 rows exported"
    assert set(result["usage"]) == {
        "model_rounds",
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
        "structured_retries",
        "images_dropped",
        "rounds_without_usage",
    }
    assert "duration_s" in result


def test_the_bridge_handed_to_the_runner_is_the_one_the_result_accounts_for():
    runner = FakeRunner(BrowserRunOutcome(done=True, steps=2))
    outer = handler(runner)

    result = run(outer("t", "https://example.com/"))

    bridge = runner.llms[0]
    assert isinstance(bridge, BackendChatModel)
    assert result["usage"]["model_rounds"] == bridge.usage.invocations


def test_a_run_that_used_every_step_without_finishing_is_marked_capped():
    runner = FakeRunner(BrowserRunOutcome(done=False, steps=5, budget_exhausted=True))
    result = run(handler(runner)("t", "https://example.com/", max_steps=5))
    assert result["capped"] is True


def test_capped_is_not_claimed_from_the_history_length():
    """browser-use's history is longer than the step count (measured: 4 entries
    for a 2-step run), so a history-vs-budget comparison would report a cap that
    never happened. With no word from the runner, the field is absent."""
    runner = FakeRunner(BrowserRunOutcome(done=False, steps=9, budget_exhausted=None))
    result = run(handler(runner)("t", "https://example.com/", max_steps=2))
    assert "capped" not in result
    assert result["steps"] == 9


def test_a_finished_run_is_never_capped_even_when_the_budget_ran_out():
    runner = FakeRunner(BrowserRunOutcome(done=True, steps=3, budget_exhausted=True))
    result = run(handler(runner)("t", "https://example.com/", max_steps=3))
    assert result["capped"] is False


def test_a_model_failure_still_reports_what_was_spent():
    runner = FakeRunner(ModelBridgeError("no valid JSON"))
    result = run(handler(runner)("t", "https://example.com/"))

    assert result["ok"] is False
    assert "ModelBridgeError" in result["error"]
    assert "usage" in result
    assert result["steps_allowed"] == DEFAULT_MAX_STEPS


def test_a_timeout_still_reports_what_was_spent():
    runner = FakeRunner(TimeoutError("deadline"))
    result = run(handler(runner)("t", "https://example.com/"))

    assert result["ok"] is False
    assert "TimeoutError" in result["error"]
    assert "usage" in result


def test_an_unexpected_runner_crash_is_an_envelope_not_an_exception():
    runner = FakeRunner(RuntimeError("chromium died"))
    result = run(handler(runner)("t", "https://example.com/"))

    assert result["ok"] is False
    assert "chromium died" in result["error"]
    assert "usage" in result


def test_a_long_result_is_capped_because_it_lands_in_the_prompt():
    from cowork_agent.browser import BROWSER_RESULT_CAP

    runner = FakeRunner(BrowserRunOutcome(done=True, result="x" * (BROWSER_RESULT_CAP + 500)))
    result = run(handler(runner)("t", "https://example.com/"))

    assert len(result["result"]) == BROWSER_RESULT_CAP
    assert result["truncated"] is True


# -- screenshots --------------------------------------------------------------


def test_screenshots_go_to_the_user_and_never_into_the_result():
    sink = Sink()
    runner = FakeRunner(BrowserRunOutcome(done=True, screenshots=[b"\x89PNG-one", b"\x89PNG-two"]))

    result = run(handler(runner, sink=sink)("t", "https://example.com/", send_screenshots=True))

    assert result["screenshots_sent"] == 2
    assert [sent.mime_type for sent in sink.received] == ["image/png", "image/png"]
    assert sink.received[0].data == b"\x89PNG-one"
    assert "screenshots" not in result
    assert b"PNG" not in repr(result).encode()


def test_screenshots_are_not_collected_when_they_were_not_asked_for():
    sink = Sink()
    runner = FakeRunner(BrowserRunOutcome(done=True))

    run(handler(runner, sink=sink)("t", "https://example.com/", send_screenshots=False))

    assert runner.specs[0].want_screenshots is False
    assert sink.received == []


def test_without_a_sink_screenshots_are_not_even_requested():
    runner = FakeRunner(BrowserRunOutcome(done=True))
    run(handler(runner)("t", "https://example.com/", send_screenshots=True))
    assert runner.specs[0].want_screenshots is False


def test_a_failing_sink_does_not_fail_the_browser_task():
    sink = Sink(raises=RuntimeError("relay full"))
    runner = FakeRunner(BrowserRunOutcome(done=True, screenshots=[b"png"]))

    result = run(handler(runner, sink=sink)("t", "https://example.com/", send_screenshots=True))

    assert result["ok"] is True
    assert "screenshots_sent" not in result


def test_an_oversized_screenshot_is_skipped_not_sent():
    sink = Sink()
    runner = FakeRunner(BrowserRunOutcome(done=True, screenshots=[b"x" * 40]))

    result = run(
        handler(runner, sink=sink, max_file_bytes=10)(
            "t", "https://example.com/", send_screenshots=True
        )
    )

    assert result["ok"] is True
    assert sink.received == []


# -- history mapping ----------------------------------------------------------


class FakeHistory:
    def __init__(self, **values) -> None:
        self._values = values

    def __getattr__(self, name):
        if name not in self._values:
            raise AttributeError(name)
        value = self._values[name]
        return lambda *args: value


def test_history_is_mapped_and_repeated_urls_collapse():
    spec = BrowserTaskSpec(
        task="t", start_url="https://example.com/", max_steps=5, allowed_domains=[]
    )
    history = FakeHistory(
        is_done=True,
        is_successful=True,
        number_of_steps=3,
        final_result="done",
        urls=["https://a/", "https://a/", "https://b/", None],
        errors=["boom", None],
    )

    outcome = outcome_from_history(history, spec)

    assert outcome.done is True
    assert outcome.steps == 3
    assert outcome.result == "done"
    assert outcome.urls == ["https://a/", "https://b/"]
    assert outcome.errors == ["boom"]
    assert outcome.screenshots == []


def test_a_history_missing_an_accessor_degrades_instead_of_losing_the_run():
    spec = BrowserTaskSpec(
        task="t", start_url="https://example.com/", max_steps=5, allowed_domains=[]
    )
    outcome = outcome_from_history(FakeHistory(final_result="partial"), spec)

    assert outcome.result == "partial"
    assert outcome.done is False
    assert outcome.steps == 0


def test_screenshots_are_decoded_from_base64_only_when_wanted():
    import base64

    spec = BrowserTaskSpec(
        task="t",
        start_url="https://example.com/",
        max_steps=5,
        allowed_domains=[],
        want_screenshots=True,
    )
    encoded = base64.b64encode(b"shot").decode("ascii")
    outcome = outcome_from_history(FakeHistory(screenshots=[encoded, None]), spec)
    assert outcome.screenshots == [b"shot"]


# -- registry integration -----------------------------------------------------


def test_the_tool_runs_through_the_registry_with_stringy_model_arguments():
    registry = ToolRegistry()
    runner = FakeRunner(BrowserRunOutcome(done=True, steps=2, result="ok"))
    registry.register(
        "browser_task",
        {
            "type": "object",
            "properties": {
                "task": {"type": "string"},
                "start_url": {"type": "string"},
                "max_steps": {"type": "integer"},
                "send_screenshots": {"type": "boolean"},
            },
        },
        handler(runner),
        is_async=True,
    )

    result = registry.dispatch(
        "browser_task",
        {
            "task": "export",
            "start_url": "https://example.com/",
            "max_steps": "7",
            "send_screenshots": "false",
        },
    )

    assert result["ok"] is True
    assert runner.specs[0].max_steps == 7


def test_the_runtime_registers_the_tool_when_a_browser_model_is_given(tmp_path):
    from cowork_agent import MockModelClient, build_runtime

    loop = build_runtime(
        MockModelClient([]),
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path),
        browser_model=MockModelClient([]),
        browser_runner=FakeRunner(),
        version_workspace=False,
    )
    assert loop.registry.has("browser_task")


def test_the_runtime_leaves_the_tool_out_without_a_browser_model(tmp_path):
    from cowork_agent import MockModelClient, build_runtime

    loop = build_runtime(
        MockModelClient([]),
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path),
        version_workspace=False,
    )
    assert loop.registry.has("browser_task") is False


# -- the real thing (skipped unless it is genuinely installed) ----------------


def _real_browser_ready() -> bool:
    return browser_use_available() and find_chromium() is not None


@pytest.mark.skipif(
    not _real_browser_ready(),
    reason="browser-use and a Chromium binary are not both installed here",
)
def test_the_real_bridge_satisfies_browser_uses_protocol():
    """The one check worth doing against the real library: that our adapter is
    accepted by ``BaseChatModel``, which is ``@runtime_checkable``. No browser is
    started and no model is called."""
    from browser_use.llm.base import BaseChatModel

    assert isinstance(BackendChatModel(FakeClient([])), BaseChatModel)


@pytest.mark.skipif(
    not _real_browser_ready(),
    reason="browser-use and a Chromium binary are not both installed here",
)
@pytest.mark.live
def test_a_real_browser_run_reaches_a_local_page():
    """Marked ``live``: it starts a real Chromium and spends real model rounds, so
    it only runs when the live markers are enabled explicitly."""
    pytest.skip("needs an account session; run tests/live_probe.py instead")
