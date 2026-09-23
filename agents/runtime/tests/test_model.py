from chuk_agents_runtime.model import (
    MockModelClient,
    ModelResponse,
    parse_openai_response,
    tool_call_response,
)


def test_parse_bare_text():
    data = {"choices": [{"message": {"role": "assistant", "content": "hi there"}}]}
    resp = parse_openai_response(data)
    assert resp.text == "hi there"
    assert not resp.has_tool_calls


def test_parse_tool_calls_with_json_string_args():
    data = {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "id": "call_9",
                            "type": "function",
                            "function": {
                                "name": "run_command",
                                "arguments": '{"command": "echo hi", "timeout": 5}',
                            },
                        }
                    ],
                }
            }
        ]
    }
    resp = parse_openai_response(data)
    assert resp.has_tool_calls
    call = resp.tool_calls[0]
    assert call.id == "call_9"
    assert call.name == "run_command"
    assert call.arguments == {"command": "echo hi", "timeout": 5}


def test_parse_tool_calls_with_dict_args():
    """Some providers hand back the argument object already decoded."""
    data = {
        "choices": [
            {
                "message": {
                    "tool_calls": [
                        {
                            "id": "call_a",
                            "function": {"name": "write_file", "arguments": {"path": "a"}},
                        }
                    ]
                }
            }
        ]
    }
    resp = parse_openai_response(data)
    assert resp.tool_calls[0].arguments == {"path": "a"}


def test_parse_several_tool_calls_keeps_order_and_ids():
    data = {
        "choices": [
            {
                "message": {
                    "content": "on it",
                    "tool_calls": [
                        {"id": "c1", "function": {"name": "a", "arguments": "{}"}},
                        {"id": "c2", "function": {"name": "b", "arguments": '{"x":1}'}},
                    ],
                }
            }
        ]
    }
    resp = parse_openai_response(data)
    assert resp.text == "on it"
    assert [c.name for c in resp.tool_calls] == ["a", "b"]
    assert [c.id for c in resp.tool_calls] == ["c1", "c2"]
    assert resp.tool_calls[1].arguments == {"x": 1}


def test_parse_tolerates_bad_json_args():
    data = {
        "choices": [
            {
                "message": {
                    "tool_calls": [
                        {"function": {"name": "t", "arguments": "not json"}}
                    ]
                }
            }
        ]
    }
    resp = parse_openai_response(data)
    assert resp.tool_calls[0].arguments == {}
    assert resp.tool_calls[0].id == "call_0"


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
