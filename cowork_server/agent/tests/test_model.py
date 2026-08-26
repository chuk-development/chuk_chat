from cowork_agent.model import (
    MockModelClient,
    ModelResponse,
    extract_tool_calls,
    parse_openai_response,
    response_from_content,
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


# -- <tool_call>-in-content protocol (shared by mock and real backend) --------


def test_extract_bare_text_has_no_calls():
    clean, calls = extract_tool_calls("just an answer")
    assert clean == "just an answer"
    assert calls == []


def test_extract_single_tool_call_strips_block():
    content = (
        'here goes <tool_call>{"name":"run_command",'
        '"arguments":{"command":"ls"}}</tool_call>'
    )
    clean, calls = extract_tool_calls(content)
    assert clean == "here goes"
    assert len(calls) == 1
    assert calls[0].name == "run_command"
    assert calls[0].arguments == {"command": "ls"}
    assert calls[0].id == "call_0"


def test_extract_multiple_tool_calls():
    content = (
        '<tool_call>{"name":"a","arguments":{}}</tool_call>'
        '<tool_call>{"name":"b","arguments":{"x":1}}</tool_call>'
    )
    clean, calls = extract_tool_calls(content)
    assert clean == ""
    assert [c.name for c in calls] == ["a", "b"]
    assert calls[1].arguments == {"x": 1}


def test_extract_repairs_missing_brace_and_trailing_comma():
    # Missing closing brace.
    _, calls = extract_tool_calls('<tool_call>{"name":"t","arguments":{"q":"y"}</tool_call>')
    assert calls and calls[0].arguments == {"q": "y"}
    # Trailing comma.
    _, calls2 = extract_tool_calls('<tool_call>{"name":"t","arguments":{"q":"y"},}</tool_call>')
    assert calls2 and calls2[0].name == "t"


def test_extract_skips_nameless_or_unparseable():
    _, calls = extract_tool_calls('<tool_call>{"arguments":{}}</tool_call>')
    assert calls == []
    _, calls2 = extract_tool_calls("<tool_call>not json at all</tool_call>")
    assert calls2 == []


def test_response_from_content_is_structural():
    # A tool-only turn -> no visible text, has tool calls (loop continues).
    resp = response_from_content('<tool_call>{"name":"x","arguments":{}}</tool_call>')
    assert resp.text is None
    assert resp.has_tool_calls
    # A bare-text turn -> final answer, no calls (loop stops).
    resp2 = response_from_content("the answer")
    assert resp2.text == "the answer"
    assert not resp2.has_tool_calls
