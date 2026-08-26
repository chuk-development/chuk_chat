from cowork_agent.registry import ERROR_CAP, ToolRegistry


def _int_schema():
    return {
        "type": "object",
        "properties": {
            "a": {"type": "integer"},
            "b": {"type": "number"},
            "flag": {"type": "boolean"},
            "name": {"type": "string"},
        },
    }


def test_dispatch_calls_handler():
    reg = ToolRegistry()
    reg.register("echo", {"type": "object", "properties": {}}, lambda **k: {"ok": True})
    assert reg.dispatch("echo", {}) == {"ok": True}


def test_arg_coercion_string_to_int_number_bool():
    seen = {}

    def handler(a, b, flag, name):
        seen.update(a=a, b=b, flag=flag, name=name)
        return "done"

    reg = ToolRegistry()
    reg.register("t", _int_schema(), handler)
    reg.dispatch("t", {"a": "42", "b": "3.5", "flag": "true", "name": "x"})

    assert seen["a"] == 42 and isinstance(seen["a"], int)
    assert seen["b"] == 3.5 and isinstance(seen["b"], float)
    assert seen["flag"] is True
    assert seen["name"] == "x"


def test_coercion_leaves_unparsable_untouched():
    got = {}
    reg = ToolRegistry()
    reg.register("t", _int_schema(), lambda a: got.setdefault("a", a) or "ok")
    reg.dispatch("t", {"a": "not-a-number"})
    assert got["a"] == "not-a-number"


def test_unknown_tool_returns_error_envelope():
    reg = ToolRegistry()
    out = reg.dispatch("nope", {})
    assert out["tool"] == "nope"
    assert "unknown tool" in out["error"]


def test_handler_exception_is_bounded_and_sanitized():
    def boom(**_):
        raise RuntimeError("x" * 5000 + "\x00\x07bad")

    reg = ToolRegistry()
    reg.register("boom", {"type": "object", "properties": {}}, boom)
    out = reg.dispatch("boom", {})
    assert out["tool"] == "boom"
    # bounded
    assert len(out["error"]) <= ERROR_CAP + len("…[truncated]")
    # sanitized — no raw control chars
    assert "\x00" not in out["error"] and "\x07" not in out["error"]


def test_async_handler_is_bridged():
    async def ahandler(x):
        return {"doubled": x * 2}

    reg = ToolRegistry()
    reg.register(
        "a",
        {"type": "object", "properties": {"x": {"type": "integer"}}},
        ahandler,
        is_async=True,
    )
    assert reg.dispatch("a", {"x": "21"}) == {"doubled": 42}


def test_check_fn_gates_availability():
    reg = ToolRegistry()
    reg.register(
        "gated",
        {"type": "object", "properties": {}},
        lambda **k: "ran",
        check_fn=lambda: False,
    )
    out = reg.dispatch("gated", {})
    assert "unavailable" in out["error"]


def test_check_fn_that_raises_is_unavailable():
    def probe():
        raise OSError("docker down")

    reg = ToolRegistry()
    reg.register("g", {"type": "object", "properties": {}}, lambda **k: "x", check_fn=probe)
    assert reg.available("g") is False


def test_double_register_rejected():
    reg = ToolRegistry()
    reg.register("dup", {}, lambda **k: 1)
    try:
        reg.register("dup", {}, lambda **k: 2)
    except ValueError:
        return
    raise AssertionError("expected ValueError on duplicate register")
