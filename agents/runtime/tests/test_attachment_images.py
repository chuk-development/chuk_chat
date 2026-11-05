"""Pictures of the current task go to a vision model as image parts
(docs/WIRE_CONTRACT.md, "Attachments to Agents")."""

from __future__ import annotations

from types import SimpleNamespace

from pydantic_ai.messages import BinaryContent, UserPromptPart

from chuk_agents_runtime.attachment_images import make_image_loader, model_supports_vision
from chuk_agents_runtime.backend import model_supports_vision_in_catalog
from chuk_agents_runtime.pai.convert import rows_to_messages

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32


def _workspace(tmp_path):
    inbox = tmp_path / ".agents" / "inbox" / "u1"
    inbox.mkdir(parents=True)
    (inbox / "p.png").write_bytes(PNG)
    (tmp_path / "secret.png").write_bytes(PNG)
    return tmp_path


def _user_parts(messages):
    return [p for m in messages for p in getattr(m, "parts", []) if isinstance(p, UserPromptPart)]


def test_only_the_current_task_gets_image_parts(tmp_path):
    loader = make_image_loader(str(_workspace(tmp_path)))
    att = [{"kind": "image", "mime": "image/png", "path": ".agents/inbox/u1/p.png"}]
    rows = [
        {"role": "user", "content": "old", "attachments": att},
        {"role": "assistant", "content": "ok"},
        {"role": "user", "content": "look", "attachments": att},
    ]
    parts = _user_parts(rows_to_messages(rows, image_loader=loader))
    assert parts[0].content == "old"
    assert parts[1].content[0] == "look"
    assert isinstance(parts[1].content[1], BinaryContent)
    assert parts[1].content[1].media_type == "image/png"
    # No loader (a model without vision): text only.
    assert _user_parts(rows_to_messages(rows))[1].content == "look"


def test_the_loader_reads_only_the_inbox(tmp_path):
    loader = make_image_loader(str(_workspace(tmp_path)))
    assert loader({"mime": "image/png", "path": ".agents/inbox/u1/p.png"})[1] == "image/png"
    assert loader({"mime": "image/png", "path": ".agents/inbox/../../secret.png"}) is None
    assert loader({"mime": "image/png", "path": "secret.png"}) is None
    assert loader({"mime": "text/plain", "path": ".agents/inbox/u1/p.png"}) is None


def test_vision_flag():
    assert model_supports_vision(SimpleNamespace(inner=SimpleNamespace(supports_vision=True)))
    assert not model_supports_vision(SimpleNamespace())
    models = [{"id": "a", "supports_vision": True}, {"id": "b", "input_modalities": ["text"]}]
    assert model_supports_vision_in_catalog(models, "a") is True
    assert model_supports_vision_in_catalog(models, "b") is False
    assert model_supports_vision_in_catalog(models, "c") is None
