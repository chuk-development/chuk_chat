"""Text shaping for Telegram: split to the message limit, Markdown to HTML.

The coworker answers in Markdown. Telegram's own Markdown modes reject a
message over one unescaped character, so the channel sends Telegram's HTML
mode instead: everything is escaped first, then the few constructs Telegram
draws (bold, italic, strike, inline code, code blocks, links) are put back as
tags. If Telegram still refuses a chunk, the sender sends it again as plain
text. Nothing is lost either way.

A message is at most 4096 characters. The raw text is cut well below that, at
paragraph, line or word borders, so the HTML of one chunk also fits. A code
block that a cut runs through is closed at the end of one chunk and opened
again at the start of the next.
"""

from __future__ import annotations

import html
import re

#: Telegram's hard limit for one message text.
TELEGRAM_MAX_CHARS = 4096
#: Where the raw text is cut, so that the HTML of a chunk still fits.
CHUNK_CHARS = 3500

_FENCE_RE = re.compile(r"^\s*```")


def _hard_split(line: str, limit: int) -> list[str]:
    """Cut one over-long line at spaces, else at ``limit``."""
    out: list[str] = []
    while len(line) > limit:
        cut = line.rfind(" ", 0, limit)
        if cut <= limit // 2:
            cut = limit
        out.append(line[:cut])
        line = line[cut:].lstrip(" ")
    out.append(line)
    return out


def split_text(text: str, limit: int = CHUNK_CHARS) -> list[str]:
    """Split ``text`` into chunks of at most ``limit`` characters.

    Paragraphs and lines stay whole where they fit. A fenced code block that
    spans a cut is closed and reopened, so every chunk renders on its own."""
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= limit:
        return [text]
    lines: list[str] = []
    for line in text.split("\n"):
        lines.extend(_hard_split(line, max(16, limit - 8)))
    chunks: list[str] = []
    current: list[str] = []
    size = 0
    fence: str | None = None  # the opening line of the fence we are inside
    for line in lines:
        closing = 4 if fence is not None else 0  # "\n```"
        if current and size + len(line) + 1 + closing > limit:
            body = "\n".join(current)
            if fence is not None:
                body += "\n```"
            chunks.append(body.strip("\n"))
            current = [fence] if fence is not None else []
            size = len(fence) + 1 if fence is not None else 0
        current.append(line)
        size += len(line) + 1
        if _FENCE_RE.match(line):
            fence = None if fence is not None else line.strip()
    if current:
        body = "\n".join(current).strip("\n")
        if body and body != fence:
            chunks.append(body)
    return [c for c in chunks if c.strip()]


_CODE_BLOCK_RE = re.compile(r"```([\w+#.-]*)[ \t]*\n?(.*?)```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
_LINK_RE = re.compile(r"\[([^\]\n]+)\]\((https?://[^\s)]+)\)")
_BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__", re.DOTALL)
_ITALIC_RE = re.compile(r"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])|(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])")
_STRIKE_RE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
_HEADING_RE = re.compile(r"^#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$", re.MULTILINE)


def markdown_to_html(text: str) -> str:
    """Telegram HTML for one chunk of Markdown. Everything else is escaped."""
    slots: list[str] = []

    def keep(fragment: str) -> str:
        slots.append(fragment)
        return f"\x00{len(slots) - 1}\x00"

    def block(match: re.Match) -> str:
        lang, body = match.group(1), match.group(2).rstrip("\n")
        attr = f' class="language-{html.escape(lang, quote=True)}"' if lang else ""
        return keep(f"<pre><code{attr}>{html.escape(body, quote=False)}</code></pre>")

    out = _CODE_BLOCK_RE.sub(block, text)
    out = _INLINE_CODE_RE.sub(lambda m: keep(f"<code>{html.escape(m.group(1), quote=False)}</code>"), out)
    out = _LINK_RE.sub(
        lambda m: keep(
            f'<a href="{html.escape(m.group(2), quote=True)}">'
            f"{html.escape(m.group(1), quote=False)}</a>"
        ),
        out,
    )
    out = html.escape(out, quote=False)
    out = _HEADING_RE.sub(lambda m: f"<b>{m.group(1)}</b>", out)
    out = _BOLD_RE.sub(lambda m: f"<b>{m.group(1) or m.group(2)}</b>", out)
    out = _STRIKE_RE.sub(lambda m: f"<s>{m.group(1)}</s>", out)
    out = _ITALIC_RE.sub(lambda m: f"<i>{m.group(1) or m.group(2)}</i>", out)
    return re.sub(r"\x00(\d+)\x00", lambda m: slots[int(m.group(1))], out)


__all__ = ["CHUNK_CHARS", "TELEGRAM_MAX_CHARS", "markdown_to_html", "split_text"]
