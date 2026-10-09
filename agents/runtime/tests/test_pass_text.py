"""The answer text of all model turns of a run (beads chuk_chat-6ze4, chuk_chat-qcdt).

A run with tool calls has several model turns (passes). Each turn can write
text: a research report before a ``schedule_task`` call, then one closing line.
The final answer keeps the text of all turns, in order, and the live stream
puts a paragraph break between two turns, so a heading line of one turn does
not take in the first paragraph of the next.
"""

from __future__ import annotations

import json
from pathlib import Path

import httpx2

from chuk_agents_runtime.loop import AgentLoop, StopReason
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.pai.events import PASS_BREAK, PassJoiner
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.tools import register_finish

from pai_fakes import FakeChatEndpoint, FakeSession, chunk, sse, text_turn, tool_turn

REPORT = "## Ergebnisse\n\n- GitHub: nichts Neues\n- arXiv: zwei Papers"
HEADING = "📅 Tägliche Routine wird eingerichtet"
CLOSING = "Die Routine läuft jetzt täglich."


def _store(tmp_path: Path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _echo_registry() -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "echo",
        {"type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"echo": v},
    )
    return reg


def _text_and_tool_turn(text_parts: list[str], call_id: str, args: dict) -> bytes:
    """One streamed turn that writes text and then calls ``echo``."""
    chunks = [chunk({"role": "assistant", "content": ""})]
    chunks += [chunk({"content": t}) for t in text_parts]
    chunks.append(
        chunk(
            {
                "tool_calls": [
                    {
                        "index": 0,
                        "id": call_id,
                        "type": "function",
                        "function": {"name": "echo", "arguments": json.dumps(args)},
                    }
                ]
            }
        )
    )
    chunks.append(
        chunk({}, finish="tool_calls", usage={"prompt_tokens": 20, "completion_tokens": 8, "total_tokens": 28})
    )
    return sse(chunks)


def _http_loop(tmp_path: Path, script: list[bytes], deltas: list[str]) -> AgentLoop:
    endpoint = FakeChatEndpoint(script)
    model, settings = chuk_chat_model(
        FakeSession(),
        ChukModelSpec(model_id="m"),
        base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    return AgentLoop(
        model, _echo_registry(), _store(tmp_path), model_settings=settings, on_delta=deltas.append
    )


def test_the_final_answer_keeps_the_text_of_every_turn(tmp_path):
    deltas: list[str] = []
    loop = _http_loop(
        tmp_path,
        [
            # The report, written in the same turn as a tool call.
            _text_and_tool_turn(["## Ergebnisse\n\n", "- GitHub: nichts Neues\n", "- arXiv: zwei Papers\n"], "c1", {"v": "a"}),
            # A tool-only turn writes no text.
            tool_turn([("c2", "echo", {"v": "b"})]),
            # A heading with no newline at its end, then a tool call.
            _text_and_tool_turn([HEADING], "c3", {"v": "c"}),
            # The last turn: one closing line.
            text_turn([CLOSING]),
        ],
        deltas,
    )
    result = loop.run("s", "check it")

    assert result.reason is StopReason.FINISHED
    assert result.final_answer == PASS_BREAK.join([REPORT, HEADING, CLOSING])
    # The stream says the same: the text of a new turn starts a new paragraph,
    # it never runs into the last line of the turn before.
    streamed = "".join(deltas)
    assert HEADING + CLOSING not in streamed
    assert HEADING + PASS_BREAK + CLOSING in streamed
    assert streamed.strip().split() == result.final_answer.split()


def test_one_text_turn_streams_and_answers_as_before(tmp_path):
    deltas: list[str] = []
    loop = _http_loop(tmp_path, [text_turn(["  hello ", "there \n"])], deltas)
    result = loop.run("s", "q")
    assert result.final_answer == "hello there"
    # No break in front of the first text of a run.
    assert deltas == ["hello ", "there \n"]


def test_a_finish_call_keeps_the_text_of_the_earlier_turns(tmp_path):
    reg = _echo_registry()
    register_finish(reg)
    model = MockModelClient(
        [
            tool_call_response(("echo", {"v": "a"}), text=REPORT),
            tool_call_response(("finish", {"summary": CLOSING})),
        ]
    )
    result = AgentLoop(model, reg, _store(tmp_path)).run("f", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == REPORT + PASS_BREAK + CLOSING


def test_a_finish_call_with_no_summary_does_not_repeat_its_own_text(tmp_path):
    reg = _echo_registry()
    register_finish(reg)
    model = MockModelClient(
        [
            tool_call_response(("echo", {"v": "a"}), text=REPORT),
            tool_call_response(("finish", {"summary": ""}), text=CLOSING),
        ]
    )
    result = AgentLoop(model, reg, _store(tmp_path)).run("f", "go")
    assert result.final_answer == REPORT + PASS_BREAK + CLOSING


def test_the_report_written_in_the_finish_turn_is_the_answer_not_the_summary(tmp_path):
    """Live run b90c02a2: the model wrote the full report as the text of the
    turn that called ``finish`` with a one-paragraph summary. The report is the
    answer; the summary is not added."""
    reg = _echo_registry()
    register_finish(reg)
    summary = "23+2 relevante neue arXiv-Papers, jeweils mit Link."
    model = MockModelClient(
        [
            tool_call_response(("echo", {"v": "a"}), text="Ich suche jetzt."),
            tool_call_response(("finish", {"summary": summary}), text=REPORT),
        ]
    )
    result = AgentLoop(model, reg, _store(tmp_path)).run("f", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "Ich suche jetzt." + PASS_BREAK + REPORT
    assert summary not in result.final_answer


def test_the_streamed_report_in_the_finish_turn_is_the_answer(tmp_path):
    """The same shape on the streamed route: the final answer is what streamed,
    never less."""
    reg = _echo_registry()
    register_finish(reg)
    summary = "Kurz: zwei Papers."
    chunks = [chunk({"role": "assistant", "content": ""})]
    chunks += [chunk({"content": t}) for t in ["## Ergebnisse\n\n", "- GitHub: nichts Neues\n", "- arXiv: zwei Papers"]]
    chunks.append(
        chunk(
            {
                "tool_calls": [
                    {
                        "index": 0,
                        "id": "f1",
                        "type": "function",
                        "function": {"name": "finish", "arguments": json.dumps({"summary": summary})},
                    }
                ]
            }
        )
    )
    chunks.append(chunk({}, finish="tool_calls", usage={"prompt_tokens": 9, "completion_tokens": 9, "total_tokens": 18}))
    endpoint = FakeChatEndpoint([sse(chunks)])
    model, settings = chuk_chat_model(
        FakeSession(),
        ChukModelSpec(model_id="m"),
        base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    deltas: list[str] = []
    result = AgentLoop(model, reg, _store(tmp_path), model_settings=settings, on_delta=deltas.append).run("f", "go")
    assert result.final_answer == REPORT
    assert "".join(deltas).strip() == result.final_answer


def test_the_legacy_route_keeps_the_text_of_every_turn(tmp_path):
    model = MockModelClient([tool_call_response(("echo", {"v": "a"}), text=REPORT), CLOSING])
    result = AgentLoop(model, _echo_registry(), _store(tmp_path)).run("m", "go")
    assert result.final_answer == REPORT + PASS_BREAK + CLOSING


def test_the_joiner_breaks_only_between_turns_that_wrote_text():
    out: list[str] = []
    joiner = PassJoiner(out.append)
    joiner.new_pass()
    joiner("# Title")
    joiner(" line")
    joiner.new_pass()  # a tool-only turn: nothing
    joiner.new_pass()
    joiner("\n")  # leading whitespace of a turn is not forwarded
    joiner("Next")
    joiner(" part")
    assert "".join(out) == "# Title line" + PASS_BREAK + "Next part"


def test_the_joiner_with_no_sink_does_nothing():
    joiner = PassJoiner(None)
    joiner.new_pass()
    joiner("text")  # no error
