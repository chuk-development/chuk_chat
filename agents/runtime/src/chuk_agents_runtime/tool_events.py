"""One shape for a tool event, live and replayed (docs/WIRE_CONTRACT.md,
"Tool events and timestamps", beads cowork-b45 / cowork-al2).

A ``tool`` frame describes ONE native tool call the model made, after its
result is known. The loop emits it live from its dispatch; ``StateStore.
replay_events`` rebuilds it from the stored assistant call and its ``tool``
result row. Both go through :func:`tool_event_fields`, so the app draws the
same card for a live run and for its replay: same name, same arguments, same
status, same times.
"""

from __future__ import annotations

import json
from typing import Any

# Tools whose one argument IS a command line the user reads as such. Old apps
# only know ``command``; they keep getting it for these.
_COMMAND_ARG = {"run_command": "command", "run_python": "code", "python": "code"}

# Result keys projected to the top level when the result is a dict that has
# them (the shell tools). An old app reads them exactly as before.
_PROJECTED = ("exit_code", "stdout", "stderr", "timed_out")


def result_text(result: Any) -> str:
    """The tool result as one text — the same text the model got. A string
    passes through; a dict is compact JSON; ``None`` is empty."""
    if isinstance(result, str):
        return result
    if result is None:
        return ""
    try:
        return json.dumps(result, separators=(",", ":"))
    except (TypeError, ValueError):
        return str(result)


def tool_status(result: Any, *, raised: bool = False) -> str:
    """``error`` when the dispatch raised, the shell exit code is non-zero, the
    command timed out, or the result envelope says so (``error`` key, or
    ``ok: false``). Else ``completed``."""
    if raised:
        return "error"
    if isinstance(result, dict):
        if result.get("timed_out"):
            return "error"
        code = result.get("exit_code")
        if isinstance(code, int) and not isinstance(code, bool) and code != 0:
            return "error"
        if "error" in result:
            return "error"
        if result.get("ok") is False:
            return "error"
    return "completed"


def tool_event_fields(
    *,
    name: str,
    arguments: Any,
    result: Any,
    call_id: str | None = None,
    started_at: float | None = None,
    completed_at: float | None = None,
    raised: bool = False,
) -> dict[str, Any]:
    """The fields of one ``tool`` event, minus ``type`` / ``replay`` / ``mid``
    (the transport adds those).

    ``arguments`` is the native argument object; a string the loop could not
    parse is passed as it is. ``command`` is only set for the shell tools, and
    is never a JSON blob. ``result`` is the result as text. ``exit_code`` /
    ``stdout`` / ``stderr`` / ``timed_out`` are projected only when the result
    dict carries them. ``duration_ms`` is derived from the two clocks when
    both are known.
    """
    fields: dict[str, Any] = {
        "name": name,
        "arguments": arguments if arguments is not None else {},
    }
    if call_id:
        fields["call_id"] = call_id
    command_key = _COMMAND_ARG.get(name)
    if command_key and isinstance(arguments, dict):
        command = arguments.get(command_key)
        if isinstance(command, str):
            fields["command"] = command
    fields["result"] = result_text(result)
    if isinstance(result, dict):
        for key in _PROJECTED:
            if key in result:
                fields[key] = result[key]
    fields["status"] = tool_status(result, raised=raised)
    if started_at is not None:
        fields["started_at"] = float(started_at)
    if completed_at is not None:
        fields["completed_at"] = float(completed_at)
    if started_at is not None and completed_at is not None:
        fields["duration_ms"] = max(0, int(round((completed_at - started_at) * 1000)))
    return fields
