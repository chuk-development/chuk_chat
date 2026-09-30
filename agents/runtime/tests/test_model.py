from chuk_agents_runtime.model import (
    MockModelClient,
    ModelResponse,
    tool_call_response,
)


def test_mock_records_calls_and_replays_in_order():
    mock = MockModelClient([ModelResponse(text="a"), ModelResponse(text="b")])
    assert mock.complete([{"role": "user", "content": "1"}]).text == "a"
    assert mock.complete([{"role": "user", "content": "2"}]).text == "b"
    assert len(mock.calls) == 2
    # exhausted -> a graceful bare-text turn, not a crash
    assert mock.complete([]).text == "(mock exhausted)"


# -- native tool calls are the one protocol ----------------------------------


def test_tool_call_response_builds_a_native_turn():
    resp = tool_call_response(("run_command", {"command": "ls"}))
    assert resp.has_tool_calls
    assert resp.text is None
    call = resp.tool_calls[0]
    assert (call.id, call.name, call.arguments) == ("call_0", "run_command", {"command": "ls"})


def test_tool_call_response_numbers_several_calls():
    resp = tool_call_response(("a", {}), ("b", {"x": 1}), text="doing both")
    assert resp.text == "doing both"
    assert [c.id for c in resp.tool_calls] == ["call_0", "call_1"]
    assert [c.name for c in resp.tool_calls] == ["a", "b"]
    assert resp.tool_calls[1].arguments == {"x": 1}


def test_mock_string_turn_is_a_final_answer_not_a_protocol():
    """A scripted string is prose. Even text shaped exactly like a call — a name
    and an argument object — is answer text: there is no in-band call format
    left to parse, so nothing about a string can continue the loop."""
    text = 'call {"name": "run_command", "arguments": {"command": "ls"}} yourself'
    mock = MockModelClient([text])
    resp = mock.complete([])
    assert not resp.has_tool_calls
    assert resp.text == text


def test_mock_passes_a_scripted_tool_turn_through():
    scripted = tool_call_response(("write_file", {"path": "a.py", "content": "x"}))
    mock = MockModelClient([scripted, "done"])
    first = mock.complete([])
    assert first.tool_calls[0].name == "write_file"
    assert mock.complete([]).text == "done"
