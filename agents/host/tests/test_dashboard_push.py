"""The host owns the one Home dashboard (docs/DASHBOARD.md) and pushes
``dashboard_state`` to the attached app after every stored change."""

from __future__ import annotations

from test_reprovision import _host


def test_a_stored_change_is_pushed_to_the_attached_app(tmp_path):
    host, party = _host(tmp_path, attached=True)
    host._dashboard.apply("add", {"widget": {"type": "note", "title": "Hi"}}, by="t")
    states = [f for f in party.frames if f.get("type") == "dashboard_state"]
    assert len(states) == 1
    assert states[0]["dashboard"]["version"] == 1
    assert states[0]["dashboard"]["widgets"][0]["id"] == "hi"


def test_nobody_attached_drops_the_push_and_keeps_the_store(tmp_path):
    host, party = _host(tmp_path, attached=False)
    host._dashboard.apply("add", {"widget": {"type": "note", "title": "Hi"}}, by="t")
    assert [f for f in party.frames if f.get("type") == "dashboard_state"] == []
    assert host._dashboard.get()["version"] == 1
