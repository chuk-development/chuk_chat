"""Shared fakes for the Pydantic AI loop tests: an OpenAI-compatible SSE
endpoint on an ``httpx2.MockTransport`` (no network) and a token session."""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

import httpx2


@dataclass
class FakeSession:
    """Duck-typed ``SupabaseSession``: a token that can expire and refresh."""

    access_token: str = "jwt-1"
    expired: bool = False
    refreshes: list[tuple[str, str | None]] = field(default_factory=list)

    def is_expired(self) -> bool:
        return self.expired

    def refresh(self, *, reason: str = "token_expired", seen_token: str | None = None) -> None:
        self.refreshes.append((reason, seen_token))
        if seen_token is not None and seen_token != self.access_token:
            return
        number = int(self.access_token.rsplit("-", 1)[-1]) + 1
        self.access_token = f"jwt-{number}"
        self.expired = False


def chunk(delta: dict, *, finish: str | None = None, usage: dict | None = None) -> dict:
    body: dict[str, Any] = {
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "created": 1_700_000_000,
        "model": "deepseek/deepseek-v4-flash",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    if usage is not None:
        body["usage"] = usage
    return body


def sse(chunks: Iterable[dict]) -> bytes:
    lines = [f"data: {json.dumps(c)}\n\n" for c in chunks]
    lines.append("data: [DONE]\n\n")
    return "".join(lines).encode()


def text_turn(
    text_parts: list[str],
    *,
    reasoning_parts: list[str] = (),  # type: ignore[assignment]
    usage: dict | None = None,
) -> bytes:
    chunks = [chunk({"role": "assistant", "content": ""})]
    chunks += [chunk({"reasoning_content": r}) for r in reasoning_parts]
    chunks += [chunk({"content": t}) for t in text_parts]
    chunks.append(
        chunk({}, finish="stop", usage=usage or {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15})
    )
    return sse(chunks)


def tool_turn(
    calls: list[tuple[str, str, dict]],
    *,
    reasoning_parts: list[str] = (),  # type: ignore[assignment]
    usage: dict | None = None,
) -> bytes:
    """``calls`` = ``[(call_id, name, args)]``; the arguments arrive in two
    fragments, the way providers stream them."""
    chunks = [chunk({"role": "assistant", "content": None})]
    chunks += [chunk({"reasoning_content": r}) for r in reasoning_parts]
    for index, (call_id, name, args) in enumerate(calls):
        text = json.dumps(args)
        half = len(text) // 2
        chunks.append(
            chunk(
                {
                    "tool_calls": [
                        {
                            "index": index,
                            "id": call_id,
                            "type": "function",
                            "function": {"name": name, "arguments": text[:half]},
                        }
                    ]
                }
            )
        )
        chunks.append(
            chunk({"tool_calls": [{"index": index, "function": {"arguments": text[half:]}}]})
        )
    chunks.append(
        chunk({}, finish="tool_calls", usage=usage or {"prompt_tokens": 20, "completion_tokens": 8, "total_tokens": 28})
    )
    return sse(chunks)


@dataclass
class FakeChatEndpoint:
    """``POST /v1/chat/completions`` answering from a script of SSE bodies.

    Records every request (headers + JSON body). An entry may be an ``int``
    status code (e.g. 401) to answer that request with an error instead.
    """

    script: list[bytes | int]
    requests: list[dict] = field(default_factory=list)
    on_request: Callable[[dict], None] | None = None

    def handler(self, request: httpx2.Request) -> httpx2.Response:
        body = json.loads(request.content or b"{}")
        record = {
            "path": request.url.path,
            "authorization": request.headers.get("authorization"),
            "body": body,
        }
        self.requests.append(record)
        if self.on_request is not None:
            self.on_request(record)
        if not self.script:
            return httpx2.Response(200, content=text_turn(["(script exhausted)"]), headers={"content-type": "text/event-stream"})
        item = self.script.pop(0)
        if isinstance(item, int):
            return httpx2.Response(item, json={"error": {"message": "unauthorized", "type": "auth"}})
        return httpx2.Response(200, content=item, headers={"content-type": "text/event-stream"})

    def client(self) -> httpx2.AsyncClient:
        return httpx2.AsyncClient(transport=httpx2.MockTransport(self.handler))


class CancellableEnv:
    """The sandbox's local environment in miniature: each command runs in its
    own process group and ``cancel()`` kills that group — what the executor's
    Stop listener calls (``chuk_agents_sandbox.local.LocalEnvironment.cancel``)."""

    def __init__(self, cwd: str | None = None) -> None:
        import threading

        self._cwd = cwd
        self._proc = None
        self._lock = threading.Lock()

    def run_bash(self, cmd, *, timeout=120, internal=False, env=None):
        import os
        import signal
        import subprocess
        import time

        from chuk_agents_runtime.environment import ProcessResult

        del internal
        start = time.monotonic()
        proc = subprocess.Popen(
            ["bash", "-c", cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=self._cwd,
            start_new_session=True,
            env={**os.environ, **env} if env else None,
        )
        with self._lock:
            self._proc = proc
        try:
            out, err = proc.communicate(timeout=timeout)
            return ProcessResult(proc.returncode, out, err, time.monotonic() - start)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
            return ProcessResult(124, out, err, time.monotonic() - start, timed_out=True)
        finally:
            with self._lock:
                if self._proc is proc:
                    self._proc = None

    def cancel(self) -> None:
        import os
        import signal

        with self._lock:
            proc = self._proc
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
