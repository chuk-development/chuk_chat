"""``read_document`` — any file to Markdown (§9).

**anydoc first, fully offline.** ``firecrawl-anydoc`` (MIT, one wheel, no API
key, no LibreOffice, no pandoc) converts doc/docx, ppt/pptx, xls/xlsx, odt/ods/
odp, rtf, epub, csv and **text-layer** PDF. It runs in *this* process, not in the
sandbox, so nothing has to be preinstalled in the container image and the agent
never spends a shell round trip on parsing. The file's bytes travel out of the
sandbox with :func:`chuk_agents_runtime.sandbox_io.fetch_bytes`.

**Vision second, and only where anydoc genuinely cannot help.** anydoc has no
OCR and no image support; a scan or a photo raises
:class:`anydoc.UnsupportedError`. That is the exact hand-off the plan describes:
try ``anydoc``, on ``UnsupportedError`` route to a vision model. This module
takes that branch through a :class:`VisionReader`, which is a one-method seam so
it can be faked in tests.

What is actually *verified* about the backend (read from
``api_server/routers/ai/openai_compat.py``, not assumed; checked again after
the live test of 2026-10-09, when the old multipart ``/v1/ai/chat`` route
answered 404):

- ``POST /v1/chat/completions`` takes OpenAI messages. A user ``content``
  part ``{"type": "image_url", "image_url": {"url": "data:image/...;base64,..."}}``
  carries the picture; ``stream: false`` answers with one JSON body whose
  ``choices[0].message.content`` is the text. Errors arrive as
  ``{"error": {"message": ...}}``.
- The model must be marked ``supports_vision`` in the catalogue
  (``qwen/qwen3.6-35b-a3b`` is).
- A big picture is shrunk to :data:`VISION_MAX_SIDE` pixels first: the
  answer does not get better, the bill gets smaller.

So :class:`BackendVisionReader` is a real, working image path.
**Video is not**: there is no endpoint today that accepts a video part, even
though the model the plan picks (``qwen/qwen3.6-35b-a3b``) reads video. Rather
than invent a route, this module refuses video with a named reason and leaves
:class:`VisionReader` as the documented seam that a future video route plugs
into without touching the tool.

The Markdown result is bounded (:data:`MARKDOWN_CAP`) — it goes straight into
the prompt (§7.9).
"""

from __future__ import annotations

import base64
import mimetypes
from pathlib import PurePosixPath
from typing import Protocol

import httpx

from .environment import Environment
from .registry import ToolRegistry
from .sandbox_io import TransferError, fetch_bytes
from .web_search import DEFAULT_BASE_URL, TokenSession

try:  # pragma: no cover - import guard, exercised by the availability test
    import anydoc

    ANYDOC_IMPORT_ERROR: str | None = None
except Exception as exc:  # pragma: no cover - only on a broken install
    anydoc = None  # type: ignore[assignment]
    ANYDOC_IMPORT_ERROR = f"{type(exc).__name__}: {exc}"

# A document can be big; the Markdown it becomes is what costs tokens, and that
# is capped separately. 20 MiB matches the backend's own document ceiling.
DOCUMENT_MAX_BYTES = 20 * 1024 * 1024

# The result travels into the prompt on every following turn, so it is bounded
# exactly like `read_file` (§7.9).
MARKDOWN_CAP = 60_000

CHAT_PATH = "/v1/chat/completions"
#: A picture check is a short answer; a transcription of a scan is longer.
VISION_MAX_TOKENS = 4096
# Open-weight default from §9: cheap MoE, ~3B active, reads images and video.
DEFAULT_VISION_MODEL = "qwen/qwen3.6-35b-a3b"
VISION_TIMEOUT = 180.0
# The backend refuses a larger image part (api_server MAX_IMAGE_SIZE).
VISION_MAX_IMAGE_BYTES = 20 * 1024 * 1024

DEFAULT_VISION_INSTRUCTION = (
    "Transcribe this file to Markdown. Keep the reading order, the headings and "
    "the tables. Transcribe the text exactly; do not summarize and do not add "
    "anything that is not in the file."
)

READ_DOCUMENT_SCHEMA = {
    "type": "object",
    "description": (
        "Read a document and get its content back as Markdown. Handles Word, "
        "PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV and text-layer PDF "
        "offline. A scan or a picture is read by a vision model instead, when "
        "one is configured: pass `instruction` to ask about a picture (which "
        "product, which colour, is it a logo). Use this for anything that is "
        "not plain text; for plain text `read_file` is cheaper."
    ),
    "properties": {
        "path": {
            "type": "string",
            "description": "File path, relative to the workspace or absolute.",
        },
        "instruction": {
            "type": "string",
            "description": (
                "Only used for the vision path (scans and images): what to look "
                "for, or a question about the picture. Leave it out for a plain "
                "transcription."
            ),
        },
    },
    "required": ["path"],
}


class VisionReader(Protocol):
    """The seam to a model that can look at pixels.

    One method on purpose: everything else about the route (which model, which
    transport, how it is billed) belongs to the implementation, and a test
    replaces the whole thing with four lines.
    """

    def read(
        self, *, filename: str, data: bytes, mime_type: str, instruction: str
    ) -> str:
        """Return the file's content as text, or raise for a failure."""
        ...


class VisionError(RuntimeError):
    """The vision route was reachable but could not read the file."""


# -- format detection ---------------------------------------------------------

# What the vision path handles. anydoc raises UnsupportedError on all of them.
IMAGE_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".bmp",
    ".tif",
    ".tiff",
    ".heic",
    ".heif",
}

# What nothing here handles yet. Named explicitly so the failure says *why*.
VIDEO_SUFFIXES = {
    ".mp4",
    ".mov",
    ".m4v",
    ".mkv",
    ".webm",
    ".avi",
    ".mpg",
    ".mpeg",
    ".wmv",
}


def anydoc_available() -> bool:
    """True when the offline converter is importable in this process."""
    return anydoc is not None


def _detect_format(data: bytes, suffix: str) -> str | None:
    """anydoc's own detection: content signature first, extension as the
    fallback for the signature-less formats (CSV)."""
    if anydoc is None:  # pragma: no cover - guarded by the caller
        return None
    try:
        detected = anydoc.format_from_bytes(data)
    except Exception:
        detected = None
    if detected:
        return detected
    if not suffix:
        return None
    try:
        return anydoc.format_from_extension(suffix)
    except Exception:
        return None


def _guess_mime(name: str, default: str = "application/octet-stream") -> str:
    guessed, _ = mimetypes.guess_type(name)
    return guessed or default


def _as_text(data: bytes) -> str | None:
    """The content as text, or ``None`` if these are not text bytes.

    Strict UTF-8 and no NUL: a file that decodes cleanly under both is text by
    any useful definition, and a binary blob almost never passes."""
    if b"\x00" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _clip(markdown: str) -> tuple[str, bool]:
    if len(markdown) <= MARKDOWN_CAP:
        return markdown, False
    return markdown[:MARKDOWN_CAP], True


# -- the backend vision route -------------------------------------------------

#: A picture is sent at most this big on its longer side. A product photo of
#: 4400 px costs many image tokens and tells a vision model nothing more.
VISION_MAX_SIDE = 1600


def _shrink(data: bytes, mime_type: str) -> tuple[bytes, str]:
    """A big picture as a JPEG of at most :data:`VISION_MAX_SIDE` pixels on
    its longer side; anything Pillow cannot read is sent as it is."""
    try:
        from io import BytesIO

        from PIL import Image
    except ImportError:  # pragma: no cover - Pillow ships with the runtime
        return data, mime_type
    try:
        image = Image.open(BytesIO(data))
        image.load()
    except Exception:  # noqa: BLE001 - not readable here: send it unchanged
        return data, mime_type
    if max(image.size) <= VISION_MAX_SIDE and mime_type in ("image/jpeg", "image/png"):
        return data, mime_type
    image.thumbnail((VISION_MAX_SIDE, VISION_MAX_SIDE))
    out = BytesIO()
    image.convert("RGB").save(out, "JPEG", quality=88)
    return out.getvalue(), "image/jpeg"


def _completion_text(response: httpx.Response) -> tuple[str, str | None]:
    """The answer of a ``/v1/chat/completions`` reply, or its error.
    Reasoning (``reasoning_content``) is never folded into the answer."""
    try:
        body = response.json()
    except ValueError:
        return "", "the vision route did not answer with JSON"
    if not isinstance(body, dict):
        return "", "the vision route answered with an unknown shape"
    error = body.get("error")
    if error:
        message = error.get("message") if isinstance(error, dict) else error
        return "", str(message)[:300]
    choices = body.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return "", "the vision model returned no choice"
    message = choices[0].get("message") or {}
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, list):
        content = "".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    return (content if isinstance(content, str) else ""), None


class BackendVisionReader:
    """Read an image through the account's own backend (§8, §10).

    No provider key ever reaches the sandbox: the account access token pays,
    exactly as ``web_search`` does, and a 401/403 is retried once after a
    refresh. The model id defaults to the open-weight MoE the plan pins; it is
    a constructor argument because model ids churn.

    The route is the backend's OpenAI-compatible ``POST /v1/chat/completions``
    with the picture as an ``image_url`` data URI. The older multipart
    ``/v1/ai/chat`` is gone; it answered 404 in the live test of 2026-10-09,
    so every picture check failed and the agent guessed colours by hand.
    """

    def __init__(
        self,
        session: TokenSession,
        *,
        base_url: str = DEFAULT_BASE_URL,
        model_id: str = DEFAULT_VISION_MODEL,
        http_client: httpx.Client | None = None,
        timeout: float = VISION_TIMEOUT,
    ) -> None:
        self._session = session
        self._url = f"{base_url.rstrip('/')}{CHAT_PATH}"
        self._model_id = model_id
        self._client = http_client
        self._timeout = timeout

    def _post(self, payload: dict) -> httpx.Response:
        client = self._client or httpx.Client(timeout=self._timeout)
        try:
            return client.post(
                self._url,
                json=payload,
                headers={"Authorization": f"Bearer {self._session.access_token}"},
            )
        finally:
            if self._client is None:
                client.close()

    def read(
        self, *, filename: str, data: bytes, mime_type: str, instruction: str
    ) -> str:
        if not mime_type.startswith("image/"):
            # Only a picture is a valid image part; anything else would get an
            # answer about nothing. Fail loudly instead.
            raise VisionError(
                f"the backend vision route takes images only, not {mime_type}"
            )
        if len(data) > VISION_MAX_IMAGE_BYTES:
            raise VisionError(
                f"image is {len(data)} bytes, over the backend's "
                f"{VISION_MAX_IMAGE_BYTES} byte limit"
            )
        data, mime_type = _shrink(data, mime_type)
        payload = {
            "model": self._model_id,
            "stream": False,
            "max_tokens": VISION_MAX_TOKENS,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": instruction},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:{mime_type};base64,"
                                + base64.b64encode(data).decode("ascii")
                            },
                        },
                    ],
                }
            ],
        }
        try:
            response = self._post(payload)
            if response.status_code in (401, 403):
                self._session.refresh()
                response = self._post(payload)
        except httpx.TimeoutException:
            raise VisionError("the vision model timed out") from None
        except Exception as exc:
            raise VisionError(f"vision request failed: {type(exc).__name__}") from None

        text, error = _completion_text(response)
        if response.status_code != 200:
            raise VisionError(error or f"vision route returned HTTP {response.status_code}")
        if error:
            raise VisionError(error)
        if not text.strip():
            raise VisionError("the vision model returned nothing")
        return text


# -- the tool -----------------------------------------------------------------


def make_read_document_handler(
    env: Environment,
    *,
    vision: VisionReader | None = None,
    max_bytes: int = DOCUMENT_MAX_BYTES,
):
    """Build the ``read_document`` handler.

    ``vision`` is optional. Without it the tool still converts every format
    anydoc knows; a scan or an image then comes back as a plain, named failure
    rather than a silent empty result.
    """

    def read_document(path: str, instruction: str | None = None) -> dict:
        text_path = (path if isinstance(path, str) else str(path or "")).strip()
        if not text_path:
            return {"ok": False, "error": "path is empty"}

        name = PurePosixPath(text_path).name or text_path
        suffix = PurePosixPath(name).suffix.lower()

        if suffix in VIDEO_SUFFIXES:
            return {
                "ok": False,
                "path": text_path,
                "error": (
                    "video is not readable yet: the offline converter cannot open "
                    "it and the backend has no video route. Pull single frames "
                    "with `run_ffmpeg` and read those instead."
                ),
            }

        try:
            fetched = fetch_bytes(env, text_path, max_bytes=max_bytes)
        except TransferError as exc:
            return {"ok": False, "path": text_path, "error": str(exc)}

        fmt = _detect_format(fetched.data, suffix) if anydoc is not None else None
        wants_vision = suffix in IMAGE_SUFFIXES or fmt is None

        if anydoc is not None and not wants_vision:
            try:
                markdown = anydoc.to_markdown_bytes(fetched.data, format=fmt)
            except anydoc.EncryptedError:
                return {
                    "ok": False,
                    "path": text_path,
                    "error": "the document is encrypted and needs a password",
                }
            except anydoc.UnsupportedError:
                wants_vision = True
            except Exception as exc:
                return {
                    "ok": False,
                    "path": text_path,
                    "error": f"could not convert {name}: {type(exc).__name__}",
                }
            else:
                content, truncated = _clip(markdown)
                return {
                    "ok": True,
                    "path": text_path,
                    "engine": "anydoc",
                    "format": fmt,
                    "bytes": fetched.size,
                    "markdown": content,
                    "truncated": truncated,
                }

        # Plain text that anydoc has no format for (.txt, .md, .log, source
        # code). Sending it to a vision model would be absurd; it is already the
        # answer.
        if suffix not in IMAGE_SUFFIXES:
            decoded = _as_text(fetched.data)
            if decoded is not None:
                content, truncated = _clip(decoded)
                return {
                    "ok": True,
                    "path": text_path,
                    "engine": "text",
                    "bytes": fetched.size,
                    "markdown": content,
                    "truncated": truncated,
                }

        # Vision path: anydoc said no, or this is an image to begin with.
        if vision is None:
            reason = (
                "no offline converter is installed"
                if anydoc is None
                else f"the offline converter cannot read {name}"
            )
            return {
                "ok": False,
                "path": text_path,
                "error": f"{reason}, and no vision model is configured",
            }

        prompt = (instruction or "").strip() or DEFAULT_VISION_INSTRUCTION
        try:
            markdown = vision.read(
                filename=name,
                data=fetched.data,
                mime_type=_guess_mime(name),
                instruction=prompt,
            )
        except VisionError as exc:
            return {"ok": False, "path": text_path, "error": str(exc)}
        except Exception as exc:
            return {
                "ok": False,
                "path": text_path,
                "error": f"vision path failed: {type(exc).__name__}",
            }

        content, truncated = _clip(markdown if isinstance(markdown, str) else "")
        return {
            "ok": True,
            "path": text_path,
            "engine": "vision",
            "bytes": fetched.size,
            "markdown": content,
            "truncated": truncated,
        }

    return read_document


def register_read_document(
    registry: ToolRegistry,
    env: Environment,
    *,
    vision: VisionReader | None = None,
    max_bytes: int = DOCUMENT_MAX_BYTES,
) -> None:
    """Register ``read_document``.

    ``check_fn`` gates the tool on there being *some* way to read a document at
    all — the offline converter or a vision route. With neither, the tool is
    registered but unavailable, so
    :func:`chuk_agents_runtime.prompt.render_tool_docs` leaves it out of the prompt and
    the model is never told about a tool that cannot run (§7.9).
    """
    registry.register(
        "read_document",
        READ_DOCUMENT_SCHEMA,
        make_read_document_handler(env, vision=vision, max_bytes=max_bytes),
        check_fn=lambda: anydoc_available() or vision is not None,
    )


def build_backend_vision(
    session: TokenSession | None,
    *,
    base_url: str = DEFAULT_BASE_URL,
    model_id: str = DEFAULT_VISION_MODEL,
    http_client: httpx.Client | None = None,
) -> BackendVisionReader | None:
    """The default vision route, or ``None`` when there is no account session to
    bill it to."""
    if session is None:
        return None
    return BackendVisionReader(
        session, base_url=base_url, model_id=model_id, http_client=http_client
    )


__all__: list[str] = [
    "ANYDOC_IMPORT_ERROR",
    "DEFAULT_VISION_INSTRUCTION",
    "DEFAULT_VISION_MODEL",
    "DOCUMENT_MAX_BYTES",
    "MARKDOWN_CAP",
    "BackendVisionReader",
    "VisionError",
    "VisionReader",
    "anydoc_available",
    "build_backend_vision",
    "make_read_document_handler",
    "register_read_document",
]
