"""The app account must reach the API search tool in the real agent loop."""

from types import SimpleNamespace

import httpx
import pytest

from cowork_agent import MockModelClient, tool_call_response
from cowork_sandbox import LocalEnvironment
from cowork_executor import ControllerSession, Executor, loopback_pair
from wiring import paired_channel


@pytest.mark.parametrize("signed_in", [True, False])
def test_executor_offers_api_search_only_with_account(tmp_path, monkeypatch, signed_in):
    seen = []

    def post(_client, url, **kwargs):
        seen.append((url, kwargs))
        return httpx.Response(200, json={"web": {"results": [
            {"title": "Local market", "url": "https://example.com/market",
             "description": "Store information"}
        ]}})

    monkeypatch.setattr(httpx.Client, "post", post)
    models = []

    class RecordingModel(MockModelClient):
        def set_tools(self, tools):
            self.tools = tools or []

    def factory():
        model = RecordingModel([
            tool_call_response(("web_search", {"query": "Edeka Selent Bismarck"})),
            "done",
        ])
        models.append(model)
        return model

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    session = SimpleNamespace(access_token="test-account") if signed_in else None
    executor = Executor(
        name="search", endpoint=executor_ep,
        opener=channel.executor.opener, sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "state.db"), model_factory=factory,
        account_session_provider=lambda: session,
    )
    controller = ControllerSession(
        endpoint=controller_ep, opener=channel.controller.opener,
        sealer=channel.controller.sealer,
    )
    executor.start()
    try:
        rid = controller.send_task("Find the local water price", session_key="search")
        events = controller.collect(rid, timeout=20)
    finally:
        executor.stop()
    used_model = next(m for m in models if m.calls)
    names = {t["function"]["name"] for t in used_model.tools}
    assert ("web_search" in names) is signed_in
    if signed_in:
        assert len(seen) == 1
        assert seen[0][1]["headers"]["Authorization"] == "Bearer test-account"
        assert seen[0][1]["json"]["query"] == "Edeka Selent Bismarck"
        event = next(e for e in events if e.get("name") == "web_search")
        assert event["status"] == "completed"
    else:
        assert not seen
