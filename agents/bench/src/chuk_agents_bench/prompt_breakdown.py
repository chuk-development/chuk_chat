"""Where the base prompt of a session goes, and how much of it the provider
prefix cache can reuse between two turns (bead chuk_chat-0qlc).

``agents-bench prompt-breakdown --session KEY`` builds the real runtime
(``build_runtime``) on a scratch database, seeds it with the session's rows
from the snapshot copy, and runs ``--turns`` short tasks against a recording
model client. No model is called and no credit is spent. The client keeps
the first request of every task: the message list and the ``tools`` array,
the same bytes the OpenAI adapter puts on the wire.

The report has three parts:

- the system prompt by ``# `` section,
- every declared tool definition (largest first),
- the history (every message after the system prompt).

The prefix part serializes each request in the order a chat template renders
it: the ``tools`` array first, then the messages. Fireworks (and every
provider with automatic prefix caching) reuses only an identical prefix, so
the common prefix of two consecutive requests is the upper bound of what the
second request can read from the cache. The report says where the two
requests first differ (in the tools, or in which message).

The seeded rows all get the current time, so the idle rule of the context
ladder never fires, and no stored summary is copied. That is the "user keeps
talking" case, which is the case the prefix cache is for.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .snapshot import copy_file, default_scratch_dir

#: The session key the scratch runs use. The seeded rows are copied under it.
SCRATCH_KEY = "local:bench-breakdown:1:1"


def estimate(text: str) -> int:
    """The runtime's own estimate (4 characters per token)."""
    from chuk_agents_runtime.context import estimate_tokens

    return estimate_tokens(text)


class RecordingClient:
    """A ``ModelClient`` that answers every request with a fixed text and
    keeps what it was sent. ``set_tools`` is the legacy adapter's seam for
    the ``tools`` array; it is only called when the array changes, so the
    current array is copied into every recorded request."""

    def __init__(self, answer: str = "ok") -> None:
        self.answer = answer
        self.tools: list[dict] = []
        self.requests: list[dict[str, Any]] = []
        #: Scripted replies, used first (a tool-calling turn, for example).
        self.script: list[Any] = []

    def set_tools(self, tools: list[dict] | None) -> None:
        self.tools = list(tools or [])

    def complete(self, messages: list[dict]) -> Any:
        from chuk_agents_runtime.model import ModelResponse

        self.requests.append(
            {
                "messages": json.loads(json.dumps(messages, default=str)),
                "tools": json.loads(json.dumps(self.tools, default=str)),
            }
        )
        if self.script:
            return self.script.pop(0)
        return ModelResponse(text=self.answer)


class StubAux:
    """The aux model (summaries, memory extraction) without a model: a short
    fixed text, so the context ladder takes tier 2/3 the way a live turn does."""

    def complete(self, messages: list[dict]) -> Any:
        from chuk_agents_runtime.model import ModelResponse

        return ModelResponse(text="Goal: (bench stub summary)\nState: unchanged.")


# --------------------------------------------------------------------------
# serialization in template order
# --------------------------------------------------------------------------


def tool_text(tool: dict) -> str:
    """One tool definition as the template prints it (compact JSON)."""
    return json.dumps(tool, ensure_ascii=False, separators=(",", ":"))


def message_text(message: dict) -> str:
    """One message as a template prints it: role, content, tool calls."""
    content = message.get("content")
    if content is None:
        content = ""
    elif not isinstance(content, str):
        content = json.dumps(content, ensure_ascii=False, separators=(",", ":"), default=str)
    out = f"<|{message.get('role')}|>\n{content or ''}"
    if message.get("name"):
        out += f"\n<name>{message['name']}</name>"
    for call in message.get("tool_calls") or []:
        out += "\n<tool_call>" + json.dumps(
            call, ensure_ascii=False, separators=(",", ":"), default=str
        )
    return out + "\n"


def segments(request: dict) -> list[tuple[str, str]]:
    """``(label, text)`` of a request in template order: tools, then messages."""
    out: list[tuple[str, str]] = []
    tools = request.get("tools") or []
    if tools:
        out.append(("tools", "<tools>\n" + "\n".join(tool_text(t) for t in tools) + "\n</tools>\n"))
    for index, message in enumerate(request.get("messages") or []):
        out.append((f"message {index} ({message.get('role')})", message_text(message)))
    return out


@dataclass
class PrefixResult:
    """The common prefix of two requests."""

    prefix_tokens: int
    first_tokens: int
    second_tokens: int
    #: Where the two requests first differ (a segment label), or ``None``.
    diverges_at: str | None
    #: A short view of both sides at the first different character.
    first_side: str = ""
    second_side: str = ""

    @property
    def share(self) -> float:
        return self.prefix_tokens / self.second_tokens if self.second_tokens else 0.0


def common_prefix(first: dict, second: dict) -> PrefixResult:
    a = segments(first)
    b = segments(second)
    text_a = "".join(t for _, t in a)
    text_b = "".join(t for _, t in b)
    limit = min(len(text_a), len(text_b))
    n = 0
    while n < limit and text_a[n] == text_b[n]:
        n += 1
    diverges: str | None = None
    if n < len(text_a) or n < len(text_b):
        offset = 0
        for label, text in b:
            if offset + len(text) > n:
                diverges = label
                break
            offset += len(text)
        else:
            diverges = "end of the second request"
    return PrefixResult(
        prefix_tokens=estimate(text_a[:n]),
        first_tokens=estimate(text_a),
        second_tokens=estimate(text_b),
        diverges_at=diverges,
        first_side=text_a[max(0, n - 40) : n + 80],
        second_side=text_b[max(0, n - 40) : n + 80],
    )


# --------------------------------------------------------------------------
# the breakdown
# --------------------------------------------------------------------------


_SECTION = re.compile(r"^# (.+)$", re.MULTILINE)


def system_sections(text: str) -> list[tuple[str, int]]:
    """``(heading, tokens)`` per top-level ``# `` section, in order."""
    marks = [(m.start(), m.group(1).strip()) for m in _SECTION.finditer(text)]
    out: list[tuple[str, int]] = []
    if not marks or marks[0][0] > 0:
        out.append(("(intro)", estimate(text[: marks[0][0] if marks else len(text)])))
    for i, (start, title) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        out.append((title, estimate(text[start:end])))
    return out


@dataclass
class Breakdown:
    session_key: str
    seeded_rows: int
    turns: int
    system_tokens: int = 0
    system_sections: list[tuple[str, int]] = field(default_factory=list)
    tools_tokens: int = 0
    tools: list[tuple[str, int]] = field(default_factory=list)
    history_tokens: int = 0
    history_messages: int = 0
    request_tokens: int = 0
    prefixes: list[PrefixResult] = field(default_factory=list)

    @property
    def base_tokens(self) -> int:
        """System prompt + tool definitions: what every request pays."""
        return self.system_tokens + self.tools_tokens

    def as_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["base_tokens"] = self.base_tokens
        for item, src in zip(data["prefixes"], self.prefixes):
            item["share"] = round(src.share, 4)
        return data


def analyse(tasks: list[list[dict]], *, session_key: str, seeded_rows: int) -> Breakdown:
    """The breakdown of the first request, and the prefix that each task's
    first request shares with the request right before it (the last model
    call of the task before): the prefix the provider cache can still hold.

    ``tasks`` holds the recorded requests of each task, in order."""
    tasks = [task for task in tasks if task]
    if not tasks:
        raise ValueError("no request was recorded")
    first = tasks[0][0]
    out = Breakdown(session_key=session_key, seeded_rows=seeded_rows, turns=len(tasks))
    messages = first.get("messages") or []
    system = "".join(
        m.get("content") or "" for m in messages if m.get("role") == "system"
        and isinstance(m.get("content"), str)
    )
    out.system_tokens = estimate(system)
    out.system_sections = system_sections(system)
    tools = first.get("tools") or []
    out.tools = sorted(
        ((str(t.get("function", {}).get("name")), estimate(tool_text(t))) for t in tools),
        key=lambda item: (-item[1], item[0]),
    )
    out.tools_tokens = sum(tokens for _, tokens in out.tools)
    history = [m for m in messages if m.get("role") != "system"]
    out.history_messages = len(history)
    out.history_tokens = sum(estimate(message_text(m)) for m in history)
    out.request_tokens = estimate("".join(t for _, t in segments(first)))
    out.prefixes = [common_prefix(a[-1], b[0]) for a, b in zip(tasks, tasks[1:])]
    return out


class _NoSession:
    """Stands in for the account session. The recording client never sends a
    request, so nothing ever asks it for a token."""

    #: ``web_search`` is offered only while the session has a token.
    access_token = "offline"

    def token(self) -> str:  # pragma: no cover - never called offline
        raise RuntimeError("prompt-breakdown makes no network call")


def search_tools_definition() -> dict | None:
    """The ``search_tools`` definition Pydantic AI's ToolSearch adds while
    deferred tools exist. The OpenAI chat route sends it last in ``tools``; the
    legacy adapter the recording client sits behind drops it (it counts as a
    native tool there), so the breakdown adds it back. ``None`` when this
    Pydantic AI version keeps it elsewhere."""
    try:
        from pydantic_ai.toolsets import _tool_search as ts

        schema, _ = ts._build_search_args_schema(ts._DEFAULT_PARAMETER_DESCRIPTION)
        description = ts._DEFAULT_TOOL_DESCRIPTION
        name = ts._SEARCH_TOOLS_NAME
    except (ImportError, AttributeError):
        return None
    return {
        "type": "function",
        "function": {"name": name, "description": description, "parameters": schema},
    }


def with_search_tool(request: dict, deferred: bool) -> dict:
    tools = list(request.get("tools") or [])
    names = {t.get("function", {}).get("name") for t in tools}
    extra = search_tools_definition() if deferred else None
    if extra is not None and extra["function"]["name"] not in names:
        tools.append(extra)
    return {**request, "tools": tools}


def run(
    db_copy: str | Path,
    session_key: str,
    *,
    turns: int = 2,
    prompt: str = "hi",
    skills_root: str | Path | None = None,
    work_dir: str | Path | None = None,
    tool_turns: bool = False,
    summarizer: bool = True,
) -> Breakdown:
    """Seed a scratch database with the session and record ``turns`` tasks.

    ``tool_turns``: every task first calls ``list_dir`` and then answers, so
    the next task's request carries tool traffic of the one before.
    ``summarizer``: a stub aux model, so the ladder can reach tier 2/3."""
    from chuk_agents_runtime import LocalEnvironment, build_runtime

    from .live import seed_from

    work = Path(work_dir) if work_dir else default_scratch_dir() / "breakdown"
    work.mkdir(parents=True, exist_ok=True)
    db = work / "breakdown.db"
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(db) + suffix)
        if candidate.exists():
            candidate.unlink()
    workspace = work / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    skills = None
    if skills_root is not None:
        # A copy: the runtime may write into its skills dir.
        skills = work / "skills"
        if skills.exists():
            import shutil

            shutil.rmtree(skills)
        copy_tree(Path(skills_root), skills)

    from chuk_agents_runtime.runtime import SubagentConfig

    client = RecordingClient()
    loop = build_runtime(
        client,
        db_path=str(db),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        # The iteration budget is shared by every run of one loop.
        max_iterations=50,
        # The core tools the host declares: web_search (needs an account
        # session; never called here), send_file_to_user (a file sink),
        # the subagent pair and the memory tools (a scratch memory dir).
        session=_NoSession(),
        file_sink=lambda sent: None,
        subagents=SubagentConfig(model_factory=RecordingClient),
        memory_root=str(work / "memory"),
        enable_mcp=False,
        enable_browser=False,
        enable_terminal=False,
        version_workspace=False,
        skills_root=str(skills) if skills is not None else None,
        aux_model=StubAux() if summarizer else None,
    )
    session_id = loop.store.route(SCRATCH_KEY)
    seeded = seed_from(db_copy, session_key, loop.store, session_id)
    deferred = bool(loop.registry.deferred_names())
    recorded: list[list[dict]] = []
    for _ in range(max(2, turns)):
        before = len(client.requests)
        if tool_turns:
            from chuk_agents_runtime.model import tool_call_response

            client.script.append(tool_call_response(("list_dir", {"path": "."})))
        loop.run(SCRATCH_KEY, prompt)
        recorded.append([with_search_tool(r, deferred) for r in client.requests[before:]])
    return analyse(recorded, session_key=session_key, seeded_rows=seeded)


def copy_tree(source: Path, target: Path) -> None:
    import shutil

    shutil.copytree(source, target, symlinks=False, dirs_exist_ok=True)


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------


def render_text(result: Breakdown, *, top: int = 15) -> str:
    lines = [
        f"session {result.session_key}  seeded rows {result.seeded_rows}  turns {result.turns}",
        "",
        f"first request      {result.request_tokens:>7} tok (estimate, 4 chars/token)",
        f"  tools            {result.tools_tokens:>7} tok  ({len(result.tools)} tools)",
        f"  system prompt    {result.system_tokens:>7} tok",
        f"  base (sum)       {result.base_tokens:>7} tok",
        f"  history          {result.history_tokens:>7} tok  ({result.history_messages} messages)",
        "",
        "system prompt sections:",
    ]
    for title, tokens in result.system_sections:
        lines.append(f"  {tokens:>6}  {title}")
    lines += ["", f"tool definitions (top {top} of {len(result.tools)}):"]
    for name, tokens in result.tools[:top]:
        lines.append(f"  {tokens:>6}  {name}")
    rest = result.tools[top:]
    if rest:
        lines.append(f"  {sum(t for _, t in rest):>6}  ({len(rest)} more)")
    lines += [
        "",
        "identical prefix: first request of a task vs the last request before it",
        "(tools first, then messages, as the chat template renders them):",
    ]
    for index, prefix in enumerate(result.prefixes, start=1):
        lines.append(
            f"  turn {index} -> {index + 1}: {prefix.prefix_tokens} of "
            f"{prefix.second_tokens} tok ({prefix.share:.1%}); "
            f"first difference: {prefix.diverges_at or 'none'}"
        )
        if prefix.diverges_at:
            lines.append(f"      turn {index}:     {prefix.first_side!r}")
            lines.append(f"      turn {index + 1}: {prefix.second_side!r}")
    return "\n".join(lines)


def render_json(result: Breakdown) -> str:
    return json.dumps(result.as_dict(), indent=2, default=str)
