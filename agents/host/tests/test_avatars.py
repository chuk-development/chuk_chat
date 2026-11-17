"""Agent avatars on the host (docs/agents/NOTIFICATIONS.md): the app's
``agent_avatar_set`` frame is checked and kept as ``avatars/<id>.png``."""

from __future__ import annotations

import base64

from chuk_agents_host.avatars import (
    MAX_AVATAR_BYTES,
    PNG_SIGNATURE,
    AvatarStore,
    safe_agent_id,
)

PNG = PNG_SIGNATURE + b"\x00\x00\x00\rIHDR" + b"\x00" * 32


def _frame(agent_id, data: bytes) -> dict:
    return {
        "type": "agent_avatar_set",
        "agent_id": agent_id,
        "png_b64": base64.b64encode(data).decode(),
    }


def test_a_valid_png_is_stored_under_the_agent_id(tmp_path):
    store = AvatarStore(tmp_path / "avatars")
    answer = store.handle_frame(_frame("local:abc-1", PNG))
    assert answer == {"type": "agent_avatar", "agent_id": "local:abc-1", "ok": True}
    path = tmp_path / "avatars" / "local_abc-1.png"
    assert path.read_bytes() == PNG
    assert store.icon_for("local:abc-1") == str(path.resolve())
    # No temp file is left behind.
    assert [p.name for p in (tmp_path / "avatars").iterdir()] == ["local_abc-1.png"]


def test_a_new_png_replaces_the_old_one(tmp_path):
    store = AvatarStore(tmp_path)
    store.handle_frame(_frame("host:1", PNG))
    store.handle_frame(_frame("host:1", PNG + b"more"))
    assert (tmp_path / "host_1.png").read_bytes() == PNG + b"more"


def test_no_avatar_means_no_icon(tmp_path):
    assert AvatarStore(tmp_path).icon_for("local:none") is None


def test_data_that_is_not_a_png_is_refused(tmp_path):
    store = AvatarStore(tmp_path)
    answer = store.handle_frame(_frame("local:a", b"GIF89a" + b"\x00" * 20))
    assert answer["ok"] is False and "PNG" in answer["error"]
    assert not list(tmp_path.iterdir())


def test_a_png_over_128_kb_is_refused(tmp_path):
    store = AvatarStore(tmp_path)
    big = PNG + b"\x00" * MAX_AVATAR_BYTES
    answer = store.handle_frame(_frame("local:a", big))
    assert answer["ok"] is False and "128 KB" in answer["error"]
    assert store.icon_for("local:a") is None


def test_bad_base64_is_refused(tmp_path):
    answer = AvatarStore(tmp_path).handle_frame(
        {"type": "agent_avatar_set", "agent_id": "local:a", "png_b64": "not base64!"}
    )
    assert answer["ok"] is False


def test_an_id_that_could_leave_the_folder_is_refused(tmp_path):
    store = AvatarStore(tmp_path / "avatars")
    for bad in ("../x", "a/b", "a\\b", "..", ".hidden", "", "a b", None, 7, "x" * 200):
        answer = store.handle_frame(_frame(bad, PNG))
        assert answer["ok"] is False, bad
    assert not (tmp_path / "avatars").exists()
    assert not (tmp_path / "x.png").exists()


def test_safe_ids_map_colon_to_underscore():
    assert safe_agent_id("host:7f3a-b.c_d") == "host_7f3a-b.c_d"
    assert safe_agent_id("a/b") is None
