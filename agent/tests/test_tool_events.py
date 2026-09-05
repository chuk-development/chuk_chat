"""The one tool-event shape, live and replayed (docs/WIRE_CONTRACT.md, "Tool
events and timestamps"; beads cowork-b45 / cowork-al2)."""

from __future__ import annotations

from cowork_agent import result_text, tool_event_fields, tool_status


def test_run_command_projects_shell_fields_and_a_plain_command_line():
    fields = tool_event_fields(
        name="run_command",
        arguments={"command": "ls /tmp", "timeout": 5},
        result={"exit_code": 0, "stdout": "a\n", "stderr": "", "timed_out": False},
        call_id="call_1",
        started_at=10.0,
        completed_at=10.25,
    )
    assert fields["name"] == "run_command"
    assert fields["call_id"] == "call_1"
    assert fields["arguments"] == {"command": "ls /tmp", "timeout": 5}
    # Old apps read `command` as the command line — never a JSON blob.
    assert fields["command"] == "ls /tmp"
    assert fields["exit_code"] == 0 and fields["stdout"] == "a\n"
    assert fields["stderr"] == "" and fields["timed_out"] is False
    assert fields["result"] == '{"exit_code":0,"stdout":"a\\n","stderr":"","timed_out":false}'
    assert fields["status"] == "completed"
    assert fields["started_at"] == 10.0 and fields["completed_at"] == 10.25
    assert fields["duration_ms"] == 250


def test_run_python_uses_its_code_as_the_command_line():
    fields = tool_event_fields(
        name="run_python", arguments={"code": "print(1)"}, result={"exit_code": 0}
    )
    assert fields["command"] == "print(1)"


def test_other_tools_carry_no_command_and_no_shell_fields():
    fields = tool_event_fields(
        name="write_file", arguments={"path": "a.txt", "content": "hi"}, result={"ok": True, "path": "a.txt"}
    )
    assert "command" not in fields
    assert "exit_code" not in fields and "stdout" not in fields
    assert fields["result"] == '{"ok":true,"path":"a.txt"}'
    assert fields["status"] == "completed"
    assert "started_at" not in fields and "duration_ms" not in fields


def test_a_string_argument_the_loop_could_not_parse_passes_through():
    fields = tool_event_fields(name="run_command", arguments="not json", result="x")
    assert fields["arguments"] == "not json"
    assert "command" not in fields
    assert fields["result"] == "x"


def test_status_is_error_for_every_failure_shape():
    assert tool_status({"exit_code": 2}) == "error"
    assert tool_status({"exit_code": 0, "timed_out": True}) == "error"
    assert tool_status({"error": "unknown tool: x", "tool": "x"}) == "error"
    assert tool_status({"ok": False, "error": "no such file"}) == "error"
    assert tool_status("fine") == "completed"
    assert tool_status({"ok": True}) == "completed"
    assert tool_status({"exit_code": 0}) == "completed"
    # A dispatch that raised (or a tool skipped by Stop) is an error even
    # when its result is a plain string.
    assert tool_status("not run", raised=True) == "error"


def test_result_text_is_what_the_model_got():
    assert result_text("plain") == "plain"
    assert result_text(None) == ""
    assert result_text({"a": 1}) == '{"a":1}'
