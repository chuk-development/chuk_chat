"""run_ack delivery confirmation (Bead cowork-sq3).

A run that ends with an app attached is not announced: the user is watching.
But the host only ever learned that the app SHOWED the answer from the app's
``run_ack``, and nothing bounded that wait — a backgrounded app or a lost frame
left the answer unannounced forever. Now the host arms a timer at ``done``; no
``run_ack`` inside it and the run is treated as finished while away (the same
desktop toast + cloud push a detached run gets, deduped by ``notified_at``).
"""

from __future__ import annotations

import threading
import time

import chuk_agents_host.host as host_module
from chuk_agents_host.host import LocalHost


class _Notifier:
    def __init__(self) -> None:
        self.summaries: list[dict] = []
        self.fired = threading.Event()

    def notify_run_finished(self, summary: dict) -> bool:
        self.summaries.append(summary)
        self.fired.set()
        return True

    def _mark_notified_once(self, run_id: str) -> bool:  # pragma: no cover - attached+automation path
        return True


def _host(tmp_path, monkeypatch, *, attached: bool = True, timeout: float = 0.15) -> tuple[LocalHost, _Notifier]:
    monkeypatch.setattr(host_module, "RUN_ACK_TIMEOUT_SECONDS", timeout)
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )
    notifier = _Notifier()
    host._notifier = notifier  # type: ignore[assignment]
    host._controller_attached = lambda: attached  # type: ignore[method-assign]
    return host, notifier


def _summary(run_id: str = "run-1", **extra) -> dict:
    return {"run_id": run_id, "session_key": "thread-1", "reason": "finished", "origin": "app", **extra}


def test_no_ack_within_the_window_announces_the_run_as_while_away(tmp_path, monkeypatch):
    host, notifier = _host(tmp_path, monkeypatch)
    host._on_run_finished(_summary())
    # Nothing yet: the user is supposedly watching.
    assert notifier.summaries == []
    assert notifier.fired.wait(2.0), "the timer never fired"
    assert [s["run_id"] for s in notifier.summaries] == ["run-1"]
    # The timer is gone; a stray late ack is a no-op.
    host._on_run_ack({"run_id": "run-1"})
    assert host._ack_pending == {}


def test_a_run_ack_inside_the_window_disarms_the_timer(tmp_path, monkeypatch):
    host, notifier = _host(tmp_path, monkeypatch)
    host._on_run_finished(_summary())
    assert "run-1" in host._ack_pending
    host._on_run_ack({"run_id": "run-1"})
    assert host._ack_pending == {}
    assert not notifier.fired.wait(0.4)
    assert notifier.summaries == []


def test_a_detached_run_is_announced_at_once_with_no_timer(tmp_path, monkeypatch):
    host, notifier = _host(tmp_path, monkeypatch, attached=False)
    host._on_run_finished(_summary())
    assert [s["run_id"] for s in notifier.summaries] == ["run-1"]
    assert host._ack_pending == {}


def test_one_timer_per_run_and_stop_cancels_them(tmp_path, monkeypatch):
    host, notifier = _host(tmp_path, monkeypatch, timeout=5.0)
    host._on_run_finished(_summary("run-a"))
    host._on_run_finished(_summary("run-a"))  # a retry's done restarts the clock
    host._on_run_finished(_summary("run-b"))
    assert set(host._ack_pending) == {"run-a", "run-b"}
    host._cancel_ack_timers()
    assert host._ack_pending == {}
    time.sleep(0.05)
    assert notifier.summaries == []


def test_malformed_payloads_are_ignored(tmp_path, monkeypatch):
    host, notifier = _host(tmp_path, monkeypatch, timeout=5.0)
    host._on_run_finished({"origin": "app"})  # no run_id: nothing to arm
    host._on_run_ack({})
    host._on_run_ack("not a dict")  # type: ignore[arg-type]
    assert host._ack_pending == {}
    assert notifier.summaries == []
    host._cancel_ack_timers()
