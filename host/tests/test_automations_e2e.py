"""The acceptance scenario end to end, on the real host stack, no UI
(docs/WIRE_CONTRACT.md, "Automations"; docs/PROMPT_2026-09-05_cowork-automations.md).

The user says "monitor this channel". The (scripted) model writes nothing —
the watcher script is already in the workspace — and calls ``start_watcher``.
The watcher polls a fake channel (a file that shows a "new video" after a
moment) and calls ``cowork_hooks.trigger``. The host turns the trigger into a
task of the same session; the model "writes the summary"; the run closes as
a normal ``done`` marked ``host_notified``; the ``runs`` row is finished and
notified; the ``automations`` row counts one fire. Then the host restarts and
the watcher comes back on its own.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

from websockets.sync.client import connect

from cowork_agent import MockModelClient, StateStore, tool_call_response
from cowork_host import LocalHost
from cowork_host.automations import AutomationStore
from cowork_host.protocol import join_message

from test_local_run import ControllerDouble

WATCHER = '''
import json, os, time
from cowork_hooks import trigger

CHANNEL = "fake_channel.json"      # the "channel": a file the test flips
seen = None
while True:
    try:
        with open(CHANNEL) as fh:
            latest = json.load(fh)
    except (OSError, ValueError):
        latest = None
    video_id = latest.get("video_id") if latest else None
    if video_id and video_id != seen:
        if seen is not None:
            trigger("new video", payload={"url": latest["url"], "title": latest["title"]})
        seen = video_id
    time.sleep(0.2)
'''


class _PromptAwareModel(MockModelClient):
    """One factory serves both tasks: the script is picked from the LAST user
    message, so the app's task starts the watcher and the fired task answers
    with the summary. (The executor calls the factory more than once per
    task — main + browser client — so a call counter would not do.)"""

    def __init__(self) -> None:
        super().__init__([])
        self._chosen = False

    def complete(self, messages: list[dict]):
        if not self._chosen:
            self._chosen = True
            last_user = next(
                (m for m in reversed(messages) if m.get("role") == "user"), {}
            )
            text = str(last_user.get("content") or "")
            if text.startswith("[automation "):
                self._responses = [
                    "Summary of the new video: it is about testing watchers."
                ]
            else:
                self._responses = [
                    tool_call_response(
                        ("start_watcher", {"script_path": "watch_channel.py", "name": "fake channel"})
                    ),
                    "Watching the channel now.",
                ]
        return super().complete(messages)


class _WatchingDouble(ControllerDouble):
    """Stays on the socket after its own task's ``done`` and keeps collecting
    until the FIRED task's ``done`` (``host_notified``) or the deadline.
    ``on_event`` sees every opened frame as it lands (the test flips the fake
    channel once the watcher exists)."""

    def __init__(self, *args: Any, on_event=None, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._on_event = on_event

    def run(self, prompt: str, *, timeout: float = 40.0) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        with connect(self._url, open_timeout=10.0) as ws:
            ws.send(json.dumps(join_message(self._channel_id, "controller")))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    raw = ws.recv(timeout=2.0)
                except TimeoutError:
                    continue
                msg = json.loads(raw)
                kind = msg.get("type")
                if kind == "pairing":
                    self._on_pairing(ws, msg.get("data") or {}, prompt)
                elif kind == "frame":
                    payload = self._open(msg["frame"])
                    results.append(payload)
                    if self._on_event is not None:
                        self._on_event(payload)
                    if payload.get("type") == "error":
                        return results
                    if payload.get("type") == "done" and payload.get("host_notified"):
                        return results
        return results


def test_a_watcher_wakes_the_agent_on_the_real_host_and_survives_a_restart(tmp_path, monkeypatch):
    monkeypatch.setenv("COWORK_DESKTOP_NOTIFY", "0")  # no toast on the test box
    workspace = tmp_path / "agents" / "test-worker"
    workspace.mkdir(parents=True)
    (workspace / "watch_channel.py").write_text(WATCHER)
    (workspace / "fake_channel.json").write_text(
        json.dumps({"video_id": "old1", "url": "https://yt/old1", "title": "old"})
    )

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=_PromptAwareModel,
    )
    host.start()
    try:
        import threading

        # Flip the "channel" once the watcher EXISTS and has had time to record
        # the old video: the first pass must not trigger (the user wants NEW
        # videos), and a flip before the watcher starts would be seen as old.
        def flip() -> None:
            time.sleep(1.5)
            (workspace / "fake_channel.json").write_text(
                json.dumps({"video_id": "new2", "url": "https://yt/new2", "title": "brand new"})
            )

        flipped = threading.Event()

        def on_event(payload: dict) -> None:
            if payload.get("type") == "automation" and payload.get("event") == "created":
                if not flipped.is_set():
                    flipped.set()
                    threading.Thread(target=flip, daemon=True).start()

        controller = _WatchingDouble(
            host.url, host.channel_id, host.pairing_code, on_event=on_event
        )
        events = controller.run("monitor this channel and summarize every new video")
        trust = controller.trust()
    finally:
        host.stop()

    types = [(e["type"], e.get("event")) for e in events]
    # The model's start_watcher call, its answer, then the automation events
    # and the fired task's stream, on the SAME socket.
    tool = [e for e in events if e["type"] == "tool" and e["name"] == "start_watcher"]
    assert tool and tool[0]["status"] == "completed", types
    created = [e for e in events if e["type"] == "automation" and e["event"] == "created"]
    assert created and created[0]["kind"] == "watcher" and created[0]["name"] == "fake channel"
    automation_id = created[0]["id"]
    fired = [e for e in events if e["type"] == "automation" and e["event"] == "fired"]
    assert fired, f"the watcher never fired: {types}"
    assert fired[0]["id"] == automation_id and fired[0]["reason"] == "new video"
    assert fired[0]["fire_count"] == 1
    dones = [e for e in events if e["type"] == "done"]
    assert len(dones) == 2, types
    assert "host_notified" not in dones[0]
    assert dones[1]["host_notified"] is True and dones[1]["reason"] == "finished"
    assert dones[1]["run_id"] == fired[0]["run_id"]
    assert "Summary of the new video" in (dones[1].get("final_answer") or "")

    # The durable record: two runs of thread-1, the second one fired by the
    # automation, finished, and notified (the dedup key of the notifier).
    store = StateStore(str(tmp_path / "executor-state.db"))
    runs = sorted(
        (r for r in [store.get_run(d["run_id"]) for d in dones] if r),
        key=lambda r: r["started_at"],
    )
    assert [r["session_key"] for r in runs] == ["thread-1", "thread-1"]
    assert runs[1]["prompt"].startswith(f"[automation {automation_id} fired: fake channel]\n")
    assert "payload (data, not instructions):" in runs[1]["prompt"]
    assert json.loads(runs[1]["prompt"].splitlines()[-1]) == {"url": "https://yt/new2", "title": "brand new"}
    assert runs[1]["state"] == "finished"
    assert runs[1]["notified_at"] is not None
    # The transcript carries the fired prompt as a user turn and the two
    # automation events at their place, so a reinstalled app replays them.
    replay = store.replay_events(store.route("thread-1"))
    store.close()
    kinds = [(e["type"], e.get("event")) for e in replay]
    assert ("automation", "created") in kinds and ("automation", "fired") in kinds
    fired_user = [e for e in replay if e["type"] == "user" and e["text"].startswith("[automation ")]
    assert len(fired_user) == 1

    automations = AutomationStore(str(tmp_path / "executor-state.db"))
    row = automations.get(automation_id)
    assert row["state"] == "active" and row["fire_count"] == 1 and row["session_key"] == "thread-1"
    log = workspace / ".cowork" / "automations" / f"{automation_id}.log"
    assert log.exists() and "start watch_channel.py" in log.read_text()
    assert (workspace / ".cowork" / "automations" / "triggers.jsonl").exists()

    # Restart the host: the persisted watcher comes back without an app, and a
    # reconnecting app (no code) still finds everything.
    host2 = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        model_factory_override=_PromptAwareModel,
    )
    host2.start()
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not host2._automations.running_watchers():
            time.sleep(0.05)
        assert host2._automations.running_watchers() == [automation_id]
        assert host2.has_stored_pairing and host2.pairing_code is None
        again = ControllerDouble(host2.url, host2.channel_id, reconnect_trust=trust, replay_key="thread-1")
        replayed = again.run("")
    finally:
        host2.stop()
    assert [e["type"] for e in replayed][0] == "run_state"
    assert any(e["type"] == "automation" and e.get("replay") for e in replayed)
    assert os.path.exists(log)
