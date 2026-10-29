"""Pages: an agent writes its own page, the app lists and reads it (docs/PAGES.md).

A page is a ``chat_document`` of kind ``markdown`` or ``html``. These tests walk
the whole path over the encrypted channel: the model writes an HTML page, the
app gets it as a ``file`` event with the document attached, and the existing
``documents_list`` / ``document_read`` frames answer with the same page. The
pages belong to the agent: another session key (another agent) sees none.
"""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel

AGENT = "local:crypto-desk:1:74112"
HTML = "<!doctype html><html><body><h1>BTC</h1><p>v1</p></body></html>"


def _build(tmp_path, workdir, model_factory):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workdir)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(workdir),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _documents(controller, payload: dict) -> dict:
    request_id = controller.send_payload(payload)
    events = controller.collect(request_id, timeout=15.0)
    frames = [e for e in events if e.get("type") == "documents"]
    assert frames, [e.get("type") for e in events]
    return frames[-1]


def test_agent_page_round_trip(tmp_path):
    workdir = tmp_path / "ws"
    workdir.mkdir()

    def factory():
        return MockModelClient([
            tool_call_response(("chat_document", {
                "action": "write", "id": "btc", "title": "BTC dashboard",
                "kind": "html", "text": HTML,
            })),
            tool_call_response(("chat_document", {
                "action": "write", "id": "btc", "title": "",
                "text": HTML.replace("v1", "v2"), "expected_version": 1,
            })),
            "page is up",
        ])

    executor, controller = _build(tmp_path, workdir, factory)
    executor.start()
    try:
        events = controller.collect(
            controller.send_task("make me a page", session_key=AGENT), timeout=30.0
        )
        listed = _documents(controller, {"type": "documents_list", "session_key": AGENT})
        read = _documents(
            controller, {"type": "document_read", "session_key": AGENT, "id": "btc"}
        )
        other = _documents(
            controller, {"type": "documents_list", "session_key": "local:other:2:9"}
        )
    finally:
        executor.stop()

    assert events[-1]["type"] == "done", [e.get("type") for e in events]
    files = [e for e in events if e.get("type") == "file"]
    # One delivery per version, each with the whole page attached.
    assert [f["document"]["version"] for f in files] == [1, 2]
    assert files[-1]["name"].endswith(".html")
    assert files[-1]["document"]["kind"] == "html"

    pages = [d for d in listed["documents"] if d["id"] == "btc"]
    assert pages and pages[0]["kind"] == "html" and pages[0]["version"] == 2
    assert read["selected"]["text"] == HTML.replace("v1", "v2")
    assert read["selected"]["title"] == "BTC dashboard"
    assert [d for d in other["documents"] if d.get("kind") != "file"] == []
