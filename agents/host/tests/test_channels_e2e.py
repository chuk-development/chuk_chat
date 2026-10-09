"""The Telegram channel on the real host stack (bead chuk_chat-02s5).

The app pairs and provisions the host once (a controller double). Then the
user turns the channel on for the host's coworker, links a Telegram chat with
the code the bot sent, and writes a task from Telegram. The task runs through
the real executor as a normal run of the coworker's one session; the
(scripted) model writes a file and sends it with ``send_file_to_user``; the
answer and the file come back to the fake Telegram. Nothing hits a network.
"""

from __future__ import annotations

import re
import time

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response

from chuk_agents_host import LocalHost
from chuk_agents_host.channels import ChannelSettings, PROMPT_MARKER, TelegramTiming
from chuk_agents_host.coworker_names import host_agent_id
from chuk_agents_host.identity import HOST_DEVICE_ID

from fake_telegram import TOKEN, FakeTelegram
from test_local_run import ControllerDouble

OWNER_CHAT = 5150


class _Model(MockModelClient):
    """The app's task gets a plain answer; a Telegram task writes a CSV, sends
    it and answers. Picked from the last user message (the executor calls the
    factory more than once per task)."""

    def __init__(self) -> None:
        super().__init__([])
        self._chosen = False

    def complete(self, messages: list[dict]):
        if not self._chosen:
            self._chosen = True
            last_user = next(
                (m for m in reversed(messages) if m.get("role") == "user"
                 and not str(m.get("content") or "").startswith("[clock]")),
                {},
            )  # the runtime's [clock] note follows each prompt
            if str(last_user.get("content") or "").startswith(PROMPT_MARKER):
                self._responses = [
                    tool_call_response(("run_command", {"command": "printf 'a,b\\n1,2\\n' > report.csv"})),
                    tool_call_response(("send_file_to_user", {"path": "report.csv"})),
                    "**Report** attached.",
                ]
            else:
                self._responses = ["hello from the app"]
        return super().complete(messages)


def test_a_telegram_message_runs_on_the_real_host_and_the_answer_and_file_come_back(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("AGENTS_DESKTOP_NOTIFY", "0")
    with FakeTelegram() as fake:
        host = LocalHost(
            port=0,
            workspace_dir=str(tmp_path),
            agent_name="test-worker",
            channel_id="testchannel00",
            digits="428913",
            model_factory_override=_Model,
            channel_settings=ChannelSettings(
                telegram_api_base=fake.base_url,
                timing=TelegramTiming(
                    poll_timeout=1, backoff_base=0.05, backoff_max=0.2, send_interval=0.0
                ),
            ),
        )
        host.start()
        try:
            # Before the app ever connected: no task server, so the channel
            # is off and says so through the frame like any other state.
            agent_id = host_agent_id(HOST_DEVICE_ID)
            assert host._on_agent_frame(
                {"type": "agent_channel_get", "agent_id": agent_id}
            )["state"] == "off"

            # The app pairs and provisions the host.
            controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
            events = controller.run("hi")
            assert events and events[-1]["type"] == "done"

            reply = host._on_agent_frame(
                {"type": "agent_channel_set", "agent_id": agent_id, "channel": "telegram",
                 "action": "enable", "token": TOKEN}
            )
            assert reply["enabled"] is True and "error" not in reply, reply
            fake.push_message("/start", chat_id=OWNER_CHAT)
            assert fake.wait_for(lambda: fake.messages(OWNER_CHAT))
            code = re.search(r"\b(\d{6})\b", fake.messages(OWNER_CHAT)[-1]["text"]).group(1)
            reply = host._on_agent_frame(
                {"type": "agent_channel_set", "agent_id": agent_id, "channel": "telegram",
                 "action": "link", "code": code}
            )
            assert reply["linked"] is True, reply

            fake.push_message("make me the report", chat_id=OWNER_CHAT)
            assert fake.wait_for(
                lambda: any(s["method"] == "sendDocument" for s in fake.sent), timeout=30
            ), fake.sent
            answers = [m for m in fake.messages(OWNER_CHAT) if "attached" in m["text"]]
            assert answers and answers[0]["text"] == "<b>Report</b> attached."
            assert answers[0]["parse_mode"] == "HTML"
            doc = next(s for s in fake.sent if s["method"] == "sendDocument")
            assert doc["filename"] == "report.csv" and doc["data"] == b"a,b\n1,2\n"
            assert doc["chat_id"] == OWNER_CHAT
        finally:
            started = time.monotonic()
            host.stop()
            assert time.monotonic() - started < 10

    # The turn is a normal run of the coworker's one session, marked.
    store = StateStore(str(tmp_path / "executor-state.db"))
    try:
        replay = store.replay_events(store.route(agent_id))
    finally:
        store.close()
    users = [e["text"] for e in replay if e["type"] == "user"]
    assert f"{PROMPT_MARKER}\nmake me the report" in users
    assert any(e["type"] == "file" and e.get("name") == "report.csv" for e in replay)


def test_the_host_maps_coworker_ids_and_keeps_telegram_runs_off_the_push_path(tmp_path):
    host = LocalHost(
        port=0, workspace_dir=str(tmp_path / "state"), channel_id="testchannel",
        agent_name="pytest-agent", model_factory_override=lambda: None,
    )
    sent: list[dict] = []
    host._send_host_payload = lambda payload: sent.append(payload) or True
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        own = host_agent_id(HOST_DEVICE_ID)
        # Every name of the host's coworker is the app's thread key.
        assert host._channel_key("default") == own
        assert host._channel_key(host._agent.id) == own
        assert host._channel_key(own) == own
        assert host._channel_key("local:amber:1") == "local:amber:1"
        assert host._channel_key("local:ghost:9") is None
        # Without a started host the frame says so instead of raising.
        reply = host._on_agent_frame({"type": "agent_channel_get", "agent_id": own})
        assert reply["type"] == "agent_channel" and reply["error"] == "channels not running"
        # The host names the capability, so the app knows it may ask.
        host._on_agent_frame({"type": "agent_list"})
        route = next(p for p in sent if p["type"] == "host_route")
        assert "agent_channels" in route["capabilities"]

        # A Telegram run goes to its channel and never to the notifier.
        # A dead loopback port: this test must never dial the real Bot API.
        host._channels = host._build_channels(
            ChannelSettings(telegram_api_base="http://127.0.0.1:9")
        )
        routed: list[dict] = []
        host._channels.on_run_finished = lambda summary: routed.append(summary) or True

        class _Notifier:
            calls = 0

            def notify_run_finished(self, _summary):
                _Notifier.calls += 1

        host._notifier = _Notifier()
        host._on_run_finished({"run_id": "r1", "origin": "telegram", "final_answer": "x"})
        assert routed and _Notifier.calls == 0
        host._on_run_finished({"run_id": "r2", "origin": "automation", "final_answer": "x"})
        assert _Notifier.calls == 1
        # The token never reaches the secret set the sandboxes get.
        host._on_agent_frame({
            "type": "agent_channel_set", "agent_id": own, "action": "enable",
            "token": TOKEN,
        })
        assert TOKEN not in host._secrets_vault.env().values()
        assert TOKEN.encode() not in (tmp_path / "state" / "channels.enc").read_bytes()
    finally:
        if host._channels is not None:
            host._channels.stop()
        host._roster.close()
        host._coworker_names.close()
