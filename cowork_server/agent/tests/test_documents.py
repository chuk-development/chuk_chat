"""``read_document``: anydoc offline first, vision only where anydoc cannot go.

Real files, not mocks, for the offline path — a real CSV and a real (minimal but
valid) OOXML docx package, both converted by the real library. The vision path is
driven by a fake reader, and the backend implementation of that reader is driven
by an ``httpx.MockTransport``, so nothing here touches the network or spends a
token.
"""

from __future__ import annotations

import io
import zipfile

import httpx
import pytest

from cowork_agent import (
    LocalEnvironment,
    ToolRegistry,
    anydoc_available,
    make_read_document_handler,
    register_read_document,
    render_tool_docs,
)
from cowork_agent.documents import (
    DEFAULT_VISION_MODEL,
    MARKDOWN_CAP,
    BackendVisionReader,
    VisionError,
)

# -- fixtures -----------------------------------------------------------------

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"""

PACKAGE_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

DOCUMENT_XML = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:r><w:t>Quarterly report</w:t></w:r></w:p>
<w:p><w:r><w:t>Revenue went up.</w:t></w:r></w:p>
</w:body></w:document>"""


def minimal_docx() -> bytes:
    """A real, valid docx package — the smallest one anydoc will open."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", CONTENT_TYPES)
        archive.writestr("_rels/.rels", PACKAGE_RELS)
        archive.writestr("word/document.xml", DOCUMENT_XML)
    return buffer.getvalue()


class FakeVision:
    """A :class:`~cowork_agent.documents.VisionReader` that records its call."""

    def __init__(self, answer: str = "# Scanned\n\nthe text", raises=None) -> None:
        self.answer = answer
        self.raises = raises
        self.calls: list[dict] = []

    def read(self, *, filename, data, mime_type, instruction):
        self.calls.append(
            {
                "filename": filename,
                "bytes": len(data),
                "mime_type": mime_type,
                "instruction": instruction,
            }
        )
        if self.raises is not None:
            raise self.raises
        return self.answer


def _handler(tmp_path, **kwargs):
    return make_read_document_handler(LocalEnvironment(), **kwargs)


# -- the offline path ---------------------------------------------------------


def test_csv_becomes_a_markdown_table(tmp_path):
    path = tmp_path / "sales.csv"
    path.write_text("region,amount\nnorth,10\nsouth,20\n", encoding="utf-8")

    result = _handler(tmp_path)(str(path))

    assert result["ok"] is True
    assert result["engine"] == "anydoc"
    assert result["format"] == "csv"
    assert "| region | amount |" in result["markdown"]
    assert "north" in result["markdown"]
    assert result["truncated"] is False


def test_docx_becomes_markdown(tmp_path):
    path = tmp_path / "report.docx"
    path.write_bytes(minimal_docx())

    result = _handler(tmp_path)(str(path))

    assert result["ok"] is True
    assert result["engine"] == "anydoc"
    assert result["format"] == "docx"
    assert "Quarterly report" in result["markdown"]
    assert "Revenue went up." in result["markdown"]


def test_content_wins_over_a_lying_extension(tmp_path):
    """anydoc detects by signature, so a docx named .csv still converts."""
    path = tmp_path / "report.csv"
    path.write_bytes(minimal_docx())

    result = _handler(tmp_path)(str(path))

    assert result["ok"] is True
    assert result["format"] == "docx"


def test_markdown_is_capped(tmp_path):
    rows = "\n".join(f"row{i},{i}" for i in range(40_000))
    path = tmp_path / "huge.csv"
    path.write_text("a,b\n" + rows + "\n", encoding="utf-8")

    result = _handler(tmp_path)(str(path))

    assert result["ok"] is True
    assert result["truncated"] is True
    assert len(result["markdown"]) == MARKDOWN_CAP


def test_plain_text_comes_back_as_itself_not_through_vision(tmp_path):
    """anydoc has no format for .md, but sending text to a vision model would be
    absurd — and expensive."""
    path = tmp_path / "notes.md"
    path.write_text("# Notes\n\nline two\n", encoding="utf-8")
    vision = FakeVision()

    result = _handler(tmp_path, vision=vision)(str(path))

    assert result["ok"] is True
    assert result["engine"] == "text"
    assert result["markdown"] == "# Notes\n\nline two\n"
    assert vision.calls == []


def test_binary_of_an_unknown_format_still_goes_to_vision(tmp_path):
    path = tmp_path / "thing.bin"
    path.write_bytes(b"\x00\x01\x02binary\xff")
    vision = FakeVision(answer="pixels said hello")

    result = _handler(tmp_path, vision=vision)(str(path))

    assert result["engine"] == "vision"
    assert len(vision.calls) == 1


def test_missing_file_is_a_clean_failure(tmp_path):
    result = _handler(tmp_path)(str(tmp_path / "nope.docx"))

    assert result["ok"] is False
    assert "not a readable file" in result["error"]


def test_empty_path(tmp_path):
    assert _handler(tmp_path)("   ")["ok"] is False


# -- the hand-off to vision ---------------------------------------------------


def test_unsupported_content_routes_to_vision(tmp_path):
    # Not a format anydoc knows: it raises UnsupportedError, which is the exact
    # hand-off the plan describes.
    path = tmp_path / "scan.png"
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 256)
    vision = FakeVision()

    result = _handler(tmp_path, vision=vision)(str(path))

    assert result["ok"] is True
    assert result["engine"] == "vision"
    assert result["markdown"] == "# Scanned\n\nthe text"
    assert vision.calls[0]["filename"] == "scan.png"
    assert vision.calls[0]["mime_type"] == "image/png"
    assert vision.calls[0]["bytes"] == 264


def test_vision_instruction_is_passed_through(tmp_path):
    path = tmp_path / "chart.jpg"
    path.write_bytes(b"\xff\xd8\xff" + b"\x00" * 64)
    vision = FakeVision()

    _handler(tmp_path, vision=vision)(str(path), instruction="read the axis labels")

    assert vision.calls[0]["instruction"] == "read the axis labels"


def test_no_vision_configured_says_so(tmp_path):
    path = tmp_path / "scan.png"
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 64)

    result = _handler(tmp_path)(str(path))

    assert result["ok"] is False
    assert "no vision model is configured" in result["error"]


def test_vision_failure_is_bounded_not_raised(tmp_path):
    path = tmp_path / "scan.png"
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 64)
    vision = FakeVision(raises=VisionError("the vision model timed out"))

    result = _handler(tmp_path, vision=vision)(str(path))

    assert result["ok"] is False
    assert result["error"] == "the vision model timed out"


def test_video_is_refused_with_the_real_reason(tmp_path):
    path = tmp_path / "clip.mp4"
    path.write_bytes(b"\x00" * 64)
    vision = FakeVision()

    result = _handler(tmp_path, vision=vision)(str(path))

    assert result["ok"] is False
    assert "video is not readable yet" in result["error"]
    assert "run_ffmpeg" in result["error"]
    # And nothing was sent anywhere.
    assert vision.calls == []


# -- registration and prompt cost ---------------------------------------------


def test_registered_and_documented_when_a_converter_exists(tmp_path):
    registry = ToolRegistry()
    register_read_document(registry, LocalEnvironment())

    assert anydoc_available() is True
    assert registry.available("read_document") is True
    assert "read_document" in render_tool_docs(registry)


def test_unavailable_tool_stays_out_of_the_prompt(tmp_path, monkeypatch):
    """With neither converter nor vision route, the tool must not be advertised
    — a tool the model cannot use is pure prompt cost (§7.9)."""
    import cowork_agent.documents as documents

    monkeypatch.setattr(documents, "anydoc", None)
    registry = ToolRegistry()
    register_read_document(registry, LocalEnvironment())

    assert documents.anydoc_available() is False
    assert registry.available("read_document") is False
    assert "read_document" not in render_tool_docs(registry)
    # Dispatch still refuses cleanly rather than raising.
    assert "unavailable" in registry.dispatch("read_document", {"path": "x"})["error"]


def test_without_anydoc_a_vision_route_still_carries_the_tool(tmp_path, monkeypatch):
    import cowork_agent.documents as documents

    monkeypatch.setattr(documents, "anydoc", None)
    vision = FakeVision(answer="from pixels")
    registry = ToolRegistry()
    register_read_document(registry, LocalEnvironment(), vision=vision)

    assert registry.available("read_document") is True

    path = tmp_path / "report.docx"
    path.write_bytes(minimal_docx())
    result = registry.dispatch("read_document", {"path": str(path)})

    assert result["ok"] is True
    assert result["engine"] == "vision"


# -- the backend vision route -------------------------------------------------


class FakeSession:
    def __init__(self, token: str = "tok-1") -> None:
        self.access_token = token
        self.refreshes = 0

    def refresh(self) -> None:
        self.refreshes += 1
        self.access_token = f"tok-{self.refreshes + 1}"


def _sse(*events: str) -> str:
    return "".join(f"data: {e}\n\n" for e in events) + "data: [DONE]\n\n"


def _mock_client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_backend_vision_posts_a_multipart_image(tmp_path):
    seen: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(
            200,
            text=_sse('{"content": "line one\\n"}', '{"content": "line two"}'),
        )

    reader = BackendVisionReader(
        FakeSession(),
        base_url="https://api.example.test",
        http_client=_mock_client(handle),
    )

    text = reader.read(
        filename="scan.png",
        data=b"\x89PNG\r\n\x1a\npixels",
        mime_type="image/png",
        instruction="transcribe",
    )

    assert text == "line one\nline two"
    request = seen[0]
    assert request.url.path == "/v1/ai/chat"
    assert request.headers["Authorization"] == "Bearer tok-1"
    body = request.content
    # The verified contract: a multipart form with `message`, `model_id` and an
    # `images` file part.
    assert b'name="message"' in body
    assert b'name="model_id"' in body
    assert DEFAULT_VISION_MODEL.encode() in body
    assert b'name="images"' in body
    assert b'filename="scan.png"' in body
    assert b"pixels" in body


def test_backend_vision_refreshes_once_on_401(tmp_path):
    codes = [401, 200]

    def handle(request: httpx.Request) -> httpx.Response:
        code = codes.pop(0)
        if code != 200:
            return httpx.Response(code, json={"detail": "expired"})
        return httpx.Response(200, text=_sse('{"content": "ok"}'))

    session = FakeSession()
    reader = BackendVisionReader(
        session,
        base_url="https://api.example.test",
        http_client=_mock_client(handle),
    )

    assert reader.read(
        filename="a.png", data=b"x", mime_type="image/png", instruction="go"
    ) == "ok"
    assert session.refreshes == 1


def test_backend_vision_surfaces_a_stream_error(tmp_path):
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text=_sse('{"error": "model unavailable"}'))

    reader = BackendVisionReader(
        FakeSession(),
        base_url="https://api.example.test",
        http_client=_mock_client(handle),
    )

    with pytest.raises(VisionError) as excinfo:
        reader.read(
            filename="a.png", data=b"x", mime_type="image/png", instruction="go"
        )
    assert "model unavailable" in str(excinfo.value)


def test_backend_vision_refuses_a_non_image_part(tmp_path):
    """The endpoint drops a non-image part silently, which would look like a
    successful answer about nothing. Fail before sending instead."""
    called = []

    def handle(request: httpx.Request) -> httpx.Response:
        called.append(request)
        return httpx.Response(200, text=_sse('{"content": "ok"}'))

    reader = BackendVisionReader(
        FakeSession(),
        base_url="https://api.example.test",
        http_client=_mock_client(handle),
    )

    with pytest.raises(VisionError) as excinfo:
        reader.read(
            filename="clip.mp4",
            data=b"x",
            mime_type="video/mp4",
            instruction="go",
        )

    assert "images only" in str(excinfo.value)
    assert called == []


def test_backend_vision_reasoning_is_never_folded_into_content(tmp_path):
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            text=_sse(
                '{"reasoning": "hmm let me look"}',
                '{"content": "the answer"}',
                '{"usage": {"total_tokens": 12}}',
            ),
        )

    reader = BackendVisionReader(
        FakeSession(),
        base_url="https://api.example.test",
        http_client=_mock_client(handle),
    )

    assert (
        reader.read(
            filename="a.png", data=b"x", mime_type="image/png", instruction="go"
        )
        == "the answer"
    )
