"""Streaming reasoning scrubber (§7.3).

Models on the ``/v2/ws`` path emit their thinking inline in the assistant
content as ``<think>`` / ``<reasoning>`` blocks. Those blocks must never reach a
consumer: not the UI, not the tool parser, and above all not the stored history,
where they would be re-sent on every later round and pay for themselves again
and again.

:class:`ThinkScrubber` is a **streaming state machine**, not a regex over a
finished string. It is fed deltas as they arrive and returns only the text that
is provably safe to emit. Two properties matter and both are tested:

- **Chunk-boundary safety.** A tag may be cut in half by the transport
  (``"<thi"`` + ``"nk>"``). The scrubber holds back any suffix that could still
  grow into a tag and emits it later once it is proven not to be one.
- **``<tool_call>`` integrity.** The tool-call wire format (:mod:`cowork_agent.model`)
  travels in the same stream. The scrubber removes think/reasoning tags only, so
  a ``<tool_call>`` block passes through byte-identical — even when split across
  deltas.

:func:`scrub_history` implements the send-side half of the rule: **only the
newest turn's reasoning is replayed**; every older assistant turn is sent with
its reasoning stripped.
"""

from __future__ import annotations

import re

# The two think-block families, opening and closing. Case-insensitive: models
# emit `<Think>` and `<THINK>` too.
_OPEN_RE = re.compile(r"<(think|reasoning)>", re.IGNORECASE)
_CLOSE_RE = re.compile(r"</(think|reasoning)>", re.IGNORECASE)

# Every literal the state machine can be halfway through when a delta ends.
_TAGS = ("<think>", "</think>", "<reasoning>", "</reasoning>")
_MAX_TAG_LEN = max(len(t) for t in _TAGS)


def _holdback_len(buf: str) -> int:
    """Length of the trailing slice of ``buf`` that could still grow into a tag.

    A delta ending in ``"<thi"`` must not be emitted: the next delta may complete
    ``<think>``. Only *proper* prefixes count — a complete tag is handled by the
    matcher, not held back. ``<tool_call>`` is unaffected: no suffix of it is a
    proper prefix of any think tag.
    """
    limit = min(len(buf), _MAX_TAG_LEN - 1)
    for k in range(limit, 0, -1):
        candidate = buf[-k:].lower()
        for tag in _TAGS:
            if len(candidate) < len(tag) and tag.startswith(candidate):
                return k
    return 0


class ThinkScrubber:
    """Feed deltas in, get emittable text out.

    ``feed`` returns the visible text discovered so far (possibly ``""`` while a
    partial tag is buffered); ``finish`` flushes whatever is left. Reasoning text
    is captured in :attr:`reasoning` for callers that want to show the newest
    turn's thinking, but it is never part of the returned visible text.

    Nesting is counted, so ``<think>a<think>b</think>c</think>`` strips whole.
    An unterminated ``<think>`` swallows the rest of the stream — the safe
    failure direction: a half-open think block must not leak.
    """

    def __init__(self) -> None:
        self._buf = ""
        self._depth = 0
        self._reasoning: list[str] = []

    @property
    def reasoning(self) -> str:
        return "".join(self._reasoning)

    @property
    def inside(self) -> bool:
        """True while the machine sits inside an unterminated think block."""
        return self._depth > 0

    def feed(self, chunk: str) -> str:
        if not chunk:
            return ""
        self._buf += chunk
        out: list[str] = []
        while True:
            if self._depth == 0:
                open_m = _OPEN_RE.search(self._buf)
                stray_m = _CLOSE_RE.search(self._buf)
                if open_m is None and stray_m is None:
                    keep = _holdback_len(self._buf)
                    cut = len(self._buf) - keep
                    if cut:
                        out.append(self._buf[:cut])
                        self._buf = self._buf[cut:]
                    break
                if open_m is not None and (stray_m is None or open_m.start() < stray_m.start()):
                    out.append(self._buf[: open_m.start()])
                    self._buf = self._buf[open_m.end() :]
                    self._depth = 1
                    continue
                # A stray closing tag with nothing open: protocol noise from a
                # model that opened its think block before the stream began.
                assert stray_m is not None
                out.append(self._buf[: stray_m.start()])
                self._buf = self._buf[stray_m.end() :]
                continue

            open_m = _OPEN_RE.search(self._buf)
            close_m = _CLOSE_RE.search(self._buf)
            if open_m is None and close_m is None:
                keep = _holdback_len(self._buf)
                cut = len(self._buf) - keep
                if cut:
                    self._reasoning.append(self._buf[:cut])
                    self._buf = self._buf[cut:]
                break
            if close_m is None or (open_m is not None and open_m.start() < close_m.start()):
                assert open_m is not None
                self._reasoning.append(self._buf[: open_m.start()])
                self._buf = self._buf[open_m.end() :]
                self._depth += 1
                continue
            self._reasoning.append(self._buf[: close_m.start()])
            self._buf = self._buf[close_m.end() :]
            self._depth -= 1
        return "".join(out)

    def finish(self) -> str:
        """Flush the tail. A leftover partial tag outside a think block was never
        a tag, so it is emitted; anything still inside a block is reasoning and
        is dropped."""
        rest = self._buf
        self._buf = ""
        if self._depth > 0:
            self._reasoning.append(rest)
            return ""
        return rest


def scrub_text(text: str | None) -> tuple[str, str]:
    """One-shot convenience over :class:`ThinkScrubber`: ``(visible, reasoning)``."""
    if not text:
        return "", ""
    scrubber = ThinkScrubber()
    visible = scrubber.feed(text) + scrubber.finish()
    return visible, scrubber.reasoning


def scrub_history(messages: list[dict], *, keep_newest: bool = True) -> list[dict]:
    """Strip reasoning from every assistant turn except (optionally) the newest.

    The newest turn's thinking is what the model needs to continue coherently;
    every older turn's is dead weight that is re-billed on every round.
    """
    newest_assistant = -1
    if keep_newest:
        for i in range(len(messages) - 1, -1, -1):
            if messages[i].get("role") == "assistant":
                newest_assistant = i
                break

    out: list[dict] = []
    for i, message in enumerate(messages):
        if i == newest_assistant or message.get("role") != "assistant":
            out.append(message)
            continue
        content = message.get("content")
        if not isinstance(content, str) or not content:
            out.append(message)
            continue
        visible, reasoning = scrub_text(content)
        if not reasoning:
            out.append(message)
            continue
        clone = dict(message)
        clone["content"] = visible
        out.append(clone)
    return out
