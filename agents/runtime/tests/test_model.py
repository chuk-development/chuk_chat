from cowork_agent.model import (
    MockModelClient,
    ModelResponse,
    parse_openai_response,
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
