"""Secrets the model never sees (docs/WIRE_CONTRACT.md, "Secrets").

Unit level: the scrubber, the two tools, the registry chokepoint and the
child-process env for ``run_command`` / ``python``. The executor's tests prove
the same across the sealed stream and the store.
"""

from __future__ import annotations

import base64
from urllib.parse import quote

from cowork_agent import (
    DictSecrets,
    LocalEnvironment,
    Scrubber,
    ToolRegistry,
    build_runtime,
    register_builtin_tools,
    status_map,
    valid_name,
)
from cowork_agent.model import MockModelClient, tool_call_response
from cowork_agent.registry import ToolRegistry as PlainRegistry

VALUE = "sk-live-0123456789abcdef"


def _scrubber(values: dict[str, str]) -> Scrubber:
    return Scrubber(lambda: values)


# -- scrubber ------------------------------------------------------------------


def test_scrubber_masks_raw_base64_and_url_encoded_forms():
    s = _scrubber({"OPENAI_API_KEY": VALUE})
    b64 = base64.b64encode(VALUE.encode()).decode()
    url = quote(VALUE, safe="")
    text = f"raw={VALUE} b64={b64} url={url} stripped={b64.rstrip('=')}"
    out = s.scrub_text(text)
    assert VALUE not in out and b64 not in out and url not in out
    assert out.count("[REDACTED:OPENAI_API_KEY]") == 4


def test_scrubber_leaves_short_values_alone():
    s = _scrubber({"PIN": "1234"})
    assert s.scrub_text("pin 1234 here") == "pin 1234 here"
    assert s.active is False


def test_scrubber_recurses_into_dicts_and_lists_and_keeps_keys():
    s = _scrubber({"K": VALUE})
    obj = {"stdout": VALUE, "nested": [VALUE, {"x": f"a{VALUE}b"}], "n": 3, VALUE: "key"}
    out = s.scrub_obj(obj)
    assert out["stdout"] == "[REDACTED:K]"
    assert out["nested"][0] == "[REDACTED:K]"
    assert out["nested"][1]["x"] == "a[REDACTED:K]b"
    assert out["n"] == 3
    assert VALUE in out  # keys are field names, not values


def test_scrubber_follows_the_live_set():
    values: dict[str, str] = {}
    s = _scrubber(values)
    assert s.scrub_text(VALUE) == VALUE
    values["K"] = VALUE
    assert s.scrub_text(VALUE) == "[REDACTED:K]"


def test_scrubber_longest_value_wins_when_one_contains_another():
    s = _scrubber({"SHORT": VALUE[:12], "LONG": VALUE})
    assert s.scrub_text(VALUE) == "[REDACTED:LONG]"


def test_scrubber_never_raises_on_a_broken_provider():
    def boom():
        raise RuntimeError("vault down")

    s = Scrubber(boom)
    assert s.scrub_text("hello") == "hello"


# -- names + status --------------------------------------------------------------


def test_valid_name_is_an_env_identifier():
    assert valid_name("PEXELS_API_KEY")
    assert valid_name("_x9")
    assert not valid_name("9abc")
    assert not valid_name("with-dash")
    assert not valid_name("")
    assert not valid_name(None)


def test_status_map_only_says_set_or_missing():
    assert status_map(["A", "B"], ["A"]) == {"A": "set", "B": "missing"}


# -- the tools through the registry ------------------------------------------------


def _registry(secrets: DictSecrets | None) -> ToolRegistry:
    registry = PlainRegistry()
    register_builtin_tools(registry, LocalEnvironment(), secrets=secrets)
    return registry


def test_tools_are_registered_only_with_secrets():
    assert not _registry(None).has("request_secrets")
    reg = _registry(DictSecrets({"A": VALUE}))
    assert reg.has("request_secrets") and reg.has("list_secrets")
    assert reg.result_filter is not None


def test_list_secrets_returns_names_and_status_only():
    reg = _registry(DictSecrets({"PEXELS_API_KEY": VALUE, "B": "12345678"}))
    out = reg.dispatch("list_secrets", {})
    assert out == {"secrets": {"B": "set", "PEXELS_API_KEY": "set"}, "count": 2}
    assert VALUE not in str(out)


def test_request_secrets_returns_a_status_map_and_records_the_ask():
    access = DictSecrets({"A": VALUE})
    reg = _registry(access)
    out = reg.dispatch(
        "request_secrets", {"names": ["A", "B", "A"], "purpose": "  fetch   images "}
    )
    assert out == {"A": "set", "B": "missing"}
    assert access.requests == [(["A", "B"], "fetch images")]


def test_request_secrets_rejects_bad_names_and_too_many():
    reg = _registry(DictSecrets())
    assert "error" in reg.dispatch("request_secrets", {"names": ["bad-name"], "purpose": ""})
    assert "error" in reg.dispatch("request_secrets", {"names": [], "purpose": ""})
    many = [f"N{i}" for i in range(40)]
    assert "error" in reg.dispatch("request_secrets", {"names": many, "purpose": ""})
    # A single string is accepted as a one-element list.
    assert reg.dispatch("request_secrets", {"names": "ONE", "purpose": ""}) == {"ONE": "missing"}


# -- the chokepoint: dispatch results are masked ----------------------------------


def test_run_command_sees_the_value_but_the_model_gets_a_mask():
    reg = _registry(DictSecrets({"X": VALUE}))
    out = reg.dispatch("run_command", {"command": "echo $X; printenv X"})
    assert out["exit_code"] == 0
    assert out["stdout"] == "[REDACTED:X]\n[REDACTED:X]\n"
    assert VALUE not in str(out)


def test_python_tool_print_environ_is_masked_including_base64():
    reg = _registry(DictSecrets({"X": VALUE}))
    code = (
        "import os, base64\n"
        "v = os.environ['X']\n"
        "print(v)\n"
        "print(base64.b64encode(v.encode()).decode())\n"
        "print(len(v))\n"
    )
    out = reg.dispatch("python", {"code": code})
    assert out["exit_code"] == 0
    lines = out["stdout"].splitlines()
    assert lines[0] == "[REDACTED:X]"
    assert lines[1] == "[REDACTED:X]"
    assert lines[2] == str(len(VALUE))  # a length is not a value
    assert VALUE not in str(out)


def test_file_tools_do_not_get_the_secret_env():
    reg = _registry(DictSecrets({"X": VALUE}))
    # read_file runs a shell too, but without the secrets: $X is empty there.
    out = reg.dispatch("run_command", {"command": "echo -n \"$X\" > probe.txt; wc -c < probe.txt"})
    assert out["stdout"].strip() == str(len(VALUE))
    # The file holds the value (the model wrote it). Reading it back is masked.
    read = reg.dispatch("read_file", {"path": "probe.txt"})
    assert read["content"] == "[REDACTED:X]"
    # And a plain probe shell (no secrets) does not see the variable.
    listing = reg.dispatch("list_dir", {"path": "."})
    assert VALUE not in str(listing)


def test_error_envelope_is_masked_too():
    reg = PlainRegistry()
    reg.result_filter = _scrubber({"X": VALUE}).scrub_obj

    def boom():
        raise RuntimeError(f"bad key {VALUE}")

    reg.register("boom", {"type": "object", "properties": {}}, boom)
    out = reg.dispatch("boom", {})
    assert out["error"] == "RuntimeError: bad key [REDACTED:X]"


def test_a_raising_filter_never_leaks_the_raw_result():
    reg = PlainRegistry()

    def broken(_result):
        raise ValueError("filter broke")

    reg.result_filter = broken
    reg.register("t", {"type": "object", "properties": {}}, lambda: {"v": VALUE})
    out = reg.dispatch("t", {})
    assert VALUE not in str(out) and "error" in out


# -- through build_runtime: the loop stores masked rows ---------------------------


def test_build_runtime_stores_only_masks(tmp_path):
    access = DictSecrets({"X": VALUE})
    model = MockModelClient(
        [
            tool_call_response(("python", {"code": "import os; print(os.environ['X'])"})),
            "done",
        ]
    )
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "s.db"),
        workspace=str(tmp_path / "ws"),
        secrets=access,
        enable_memory=False,
        version_workspace=False,
    )
    assert loop.registry.has("request_secrets")
    result = loop.run("t", "print the key")
    assert result.final_answer == "done"
    rows = loop.store.get_conversation(result.session_id)
    dump = "\n".join(str(r.content) for r in rows)
    assert VALUE not in dump
    assert "[REDACTED:X]" in dump
