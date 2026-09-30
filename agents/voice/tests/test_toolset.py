"""The per-call toolset (needs the livekit import, but no room)."""

from __future__ import annotations

import tools


def _names(ts: list) -> set[str]:
    names = set()
    for t in ts:
        info = getattr(t, "info", None)
        names.add(info.name if info is not None else getattr(t, "id", type(t).__name__))
    return names


def test_device_status_is_gone() -> None:
    for delegate in (False, True):
        for mode in ("chat", "agents"):
            names = _names(tools.build_tools(mode=mode, delegate_available=delegate))
            assert "get_device_status" not in names
            assert "get_device_location" in names
            assert "end_call" in names


def test_set_reminder_only_without_a_delegate() -> None:
    assert "set_reminder" in _names(tools.build_tools(mode="chat", delegate_available=False))
    for mode in ("chat", "agents"):
        names = _names(tools.build_tools(mode=mode, delegate_available=True))
        assert "set_reminder" not in names
        assert "delegate_task" in names


def test_research_is_left_out_only_in_agents_mode_with_a_delegate() -> None:
    assert "research_in_background" in _names(tools.build_tools(mode="chat", delegate_available=True))
    assert "research_in_background" not in _names(tools.build_tools(mode="agents", delegate_available=True))


class _FakeUi:
    def __init__(self, answer: object) -> None:
        self.answer = answer

    async def call_client(self, method: str, payload: dict | None = None, **_: object) -> object:
        assert method == "get_location"
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


class _FakeCtx:
    def __init__(self, answer: object) -> None:
        self.userdata = type("D", (), {"ui": _FakeUi(answer)})()


def _location(answer: object) -> str:
    import asyncio

    return asyncio.run(tools.get_device_location(_FakeCtx(answer)))


def test_location_denied_or_unreachable_is_graceful() -> None:
    for answer in (
        RuntimeError("Method not supported at destination"),
        {"error": "permission denied"},
        {"latitude": None, "longitude": 10.1},
        "garbage",
    ):
        text = _location(answer)
        assert text.startswith("Location not available right now")
        assert "can't see their location right now" in text


def test_location_with_a_place_name() -> None:
    text = _location({"latitude": 54.3233, "longitude": 10.1228, "accuracy": 12.4, "place": "Kiel"})
    assert "Kiel" in text
    assert "54.3233, 10.1228" in text
    assert "accuracy about 12 m" in text


def test_client_place_is_validated() -> None:
    assert tools._clean_place("  Kiel  ") == "Kiel"
    assert tools._clean_place("") is None
    assert tools._clean_place("   ") is None
    assert tools._clean_place(42) is None
    assert tools._clean_place("x" * 101) is None
    assert tools._clean_place("x" * 100) == "x" * 100


def test_reverse_geocode_ignores_a_non_dict_answer(monkeypatch) -> None:
    import asyncio

    async def fake_get_json(*_a, **_k):
        return ["not", "a", "dict"]

    monkeypatch.setattr(tools, "_get_json", fake_get_json)
    assert asyncio.run(tools._reverse_geocode(54.3, 10.1)) is None

    async def fake_bad_address(*_a, **_k):
        return {"address": "Kiel", "name": "  Kiel  "}

    monkeypatch.setattr(tools, "_get_json", fake_bad_address)
    assert asyncio.run(tools._reverse_geocode(54.3, 10.1)) == "Kiel"
