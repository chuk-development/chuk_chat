"""External coding CLIs as a subagent backend (DeepSeek harness item 57).

A subagent normally runs our own loop (:func:`chuk_agents_runtime.runtime.
make_child_runner`). When the user switched it on for an agent (the
``external_agents`` permission, docs/WIRE_CONTRACT.md "Subagents") and the
CLI is installed where the child runs, ``delegate_task`` may instead hand a
task to the user's own ``claude`` (Claude Code) or ``codex`` (OpenAI Codex)
CLI. This module is that :class:`~chuk_agents_runtime.subagents.ChildRunner`.

How one run works:

1. The child's own sandbox is built from the same ``env_factory`` as a native
   child (one child = one sandbox still holds).
2. ``command -v <cli>`` runs inside it. Missing = a failed child with a
   sentence, never a silent fallback to the native loop.
3. The CLI runs once, non-interactive, in the sandbox's working directory:

   - ``claude -p <prompt> --output-format json --permission-mode acceptEdits``
     prints one JSON object; ``result`` is the answer, ``is_error`` the
     outcome, ``usage`` the tokens.
   - ``codex exec --json --skip-git-repo-check --sandbox workspace-write
     <prompt>`` prints JSON lines (``thread.started``, ``item.completed`` ...,
     ``turn.completed`` / ``turn.failed``); the last ``agent_message`` item is
     the answer, ``turn.completed.usage`` the tokens.

4. The answer is mapped to a :class:`~chuk_agents_runtime.loop.LoopResult`
   (``FINISHED`` with the text, ``MAX_ITERATIONS`` with no answer for a CLI
   error), so the supervisor treats it like any other child: the output
   schema check, the git merge, the "subagent settled" note.

Limits, said plainly: the CLI bills the user's own Claude / OpenAI account,
not ours, and it does not see this conversation (``fork`` is refused for it).
Stop reaches it only when the command returns: :meth:`Environment.run_bash`
cannot cancel a running command, so the run is bounded by
:data:`DEFAULT_ACP_TIMEOUT_S` instead, and the stall monitor settles the record
as ``stalled`` after its grace time.
"""

from __future__ import annotations

import json
import shlex
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from .environment import Environment, LocalEnvironment
from .loop import LoopResult, StopReason
from .subagents import ChildContext, ChildRunner

#: The backends this module knows, in the order the model is offered them.
ACP_BACKENDS: tuple[str, ...] = ("claude", "codex")

#: Wall-clock cap for one CLI run. A coding CLI on a real task takes minutes;
#: half an hour is the point where it is wedged, not working.
DEFAULT_ACP_TIMEOUT_S = 1800

#: The stderr text kept in a failure message.
STDERR_CAP = 400


@dataclass(frozen=True)
class CliSpec:
    """How one CLI is called and how its output is read."""

    name: str
    binary: str
    build: Callable[[str], str]
    parse: Callable[[str], tuple[bool, str | None, int, str | None]]


def _claude_command(prompt: str) -> str:
    # ``acceptEdits``: file edits in the working directory go through, shell
    # commands the CLI would ask about are refused (there is nobody to ask).
    return (
        "claude -p "
        + shlex.quote(prompt)
        + " --output-format json --permission-mode acceptEdits"
    )


def parse_claude(stdout: str) -> tuple[bool, str | None, int, str | None]:
    """``(ok, answer, tokens, error)`` from ``claude -p --output-format json``."""
    data: Any = None
    text = (stdout or "").strip()
    for candidate in (text, text.splitlines()[-1] if text else ""):
        try:
            data = json.loads(candidate)
            break
        except ValueError:
            continue
    if isinstance(data, list):  # stream form: the last ``result`` message
        data = next(
            (m for m in reversed(data) if isinstance(m, dict) and m.get("type") == "result"),
            None,
        )
    if not isinstance(data, dict):
        return False, None, 0, "claude printed no JSON result"
    tokens = _usage_tokens(data.get("usage"))
    answer = data.get("result")
    if data.get("is_error") or not isinstance(answer, str) or not answer.strip():
        why = data.get("subtype") or "error"
        return False, None, tokens, f"claude ended with {why}"
    return True, answer, tokens, None


def _codex_command(prompt: str) -> str:
    return (
        "codex exec --json --skip-git-repo-check --sandbox workspace-write "
        + shlex.quote(prompt)
    )


def parse_codex(stdout: str) -> tuple[bool, str | None, int, str | None]:
    """``(ok, answer, tokens, error)`` from ``codex exec --json`` (JSON lines)."""
    answer: str | None = None
    tokens = 0
    error: str | None = None
    seen = False
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        seen = True
        kind = event.get("type")
        if kind == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message" and isinstance(item.get("text"), str):
                answer = item["text"]
        elif kind == "turn.completed":
            tokens += _usage_tokens(event.get("usage"))
        elif kind == "turn.failed":
            error = str((event.get("error") or {}).get("message") or "turn failed")
        elif kind == "error":
            error = str(event.get("message") or "error")
    if not seen:
        return False, None, 0, "codex printed no JSON events"
    if error is not None or not answer or not answer.strip():
        return False, None, tokens, f"codex: {error or 'no final message'}"
    return True, answer, tokens, None


def _usage_tokens(usage: Any) -> int:
    if not isinstance(usage, dict):
        return 0
    total = 0
    for key in ("input_tokens", "output_tokens"):
        value = usage.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            total += int(value)
    return total


CLI_SPECS: dict[str, CliSpec] = {
    "claude": CliSpec("claude", "claude", _claude_command, parse_claude),
    "codex": CliSpec("codex", "codex", _codex_command, parse_codex),
}


def cli_available(env: Environment, binary: str) -> bool:
    """``command -v`` inside ``env``: the CLI must exist where the child runs,
    not only on the host."""
    try:
        result = env.run_bash(
            f"command -v {shlex.quote(binary)}", timeout=15, internal=True
        )
    except Exception:  # noqa: BLE001 — a probe that fails means "not here"
        return False
    return bool(result.ok and (result.stdout or "").strip())


def detect_backends(env: Environment, names: Sequence[str] = ACP_BACKENDS) -> tuple[str, ...]:
    """The subset of ``names`` installed in ``env``."""
    return tuple(n for n in names if n in CLI_SPECS and cli_available(env, CLI_SPECS[n].binary))


class AcpChildError(RuntimeError):
    """The CLI could not run or ended in an error. The supervisor records the
    message as the child's ``error``."""


def make_acp_runner(
    env_factory: Callable[[str], Environment] | None,
    *,
    timeout_s: int = DEFAULT_ACP_TIMEOUT_S,
) -> ChildRunner:
    """A :class:`ChildRunner` for ``ctx.backend`` in :data:`CLI_SPECS`."""

    def run(ctx: ChildContext) -> LoopResult:
        spec = CLI_SPECS.get(ctx.backend)
        if spec is None:
            raise AcpChildError(f"unknown subagent backend {ctx.backend!r}")
        if ctx.kill_switch.interrupted():
            return LoopResult(
                reason=StopReason.INTERRUPTED,
                final_answer=None,
                iterations=0,
                session_id=0,
            )
        factory = env_factory or (lambda task_id: LocalEnvironment())
        env = factory(ctx.task_id)
        try:
            if not cli_available(env, spec.binary):
                raise AcpChildError(
                    f"the {spec.name} CLI is not installed in this subagent's "
                    "sandbox; use the native backend"
                )
            ctx.emit({"type": "tool", "name": f"{spec.name}_cli", "summary": "started"})
            result = env.run_bash(spec.build(ctx.prompt), timeout=timeout_s)
            if result.timed_out:
                raise AcpChildError(
                    f"the {spec.name} CLI did not finish within {timeout_s}s"
                )
            ok, answer, tokens, error = spec.parse(result.stdout)
            if not ok:
                detail = (result.stderr or "").strip()[-STDERR_CAP:]
                message = error or f"{spec.name} failed (exit {result.exit_code})"
                if detail:
                    message += f": {detail}"
                raise AcpChildError(message)
            ctx.emit({"type": "delta", "text": answer})
            return LoopResult(
                reason=StopReason.FINISHED,
                final_answer=answer,
                iterations=1,
                session_id=0,
                tokens_spent=tokens,
            )
        finally:
            cleanup = getattr(env, "cleanup", None)
            if callable(cleanup):
                try:
                    cleanup()
                except Exception:  # noqa: BLE001 — cleanup must not mask a result
                    pass

    return run
