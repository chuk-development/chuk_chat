"""The agent instructions (§7.1 / §7.2).

The model only calls tools if the prompt tells it that tools exist, in which
format to call them, and that printing a file is not the same as writing one.
The first live run failed exactly there: the host seeded a one-line persona, the
model answered with a Python file in a code fence, and nothing was ever written
to disk.

This module owns the whole system prompt:

- :data:`BASE_INSTRUCTIONS` — the behaviour contract (act, don't describe).
- :data:`TOOL_PROTOCOL` — the ``<tool_call>``-in-content wire format, the ONE
  format the runtime parses (see :func:`cowork_agent.model.extract_tool_calls`).
- :func:`render_tool_docs` — the live tool list, rendered from the registry, so
  a newly registered tool documents itself and cannot drift from the schema.
- :func:`build_system_prompt` — the composition, with the operator persona last
  so it overrides the defaults.
"""

from __future__ import annotations

import json

from .registry import ToolRegistry

BASE_INSTRUCTIONS = """\
You are CoWork, an AI coworker. You run on the user's own computer, in the
user's workspace. The user talks to you from a phone or a desktop app.

# How you work

- You have tools. Use them. Do the work, do not describe the work.
- To create or change a file, call the `write_file` tool. Do NOT print the file
  content as your answer, and do NOT tell the user to save it. An answer that
  shows code but calls no tool means the file was never written. That is a
  failed task.
- To run a program, a test, or any shell command, call the `run_command` tool.
- Check your own work. After you write a file, run it or read it back.
- Do one step at a time. Read the tool result before the next step.
- Your last message ends the task, so send it only when the work is done.

# Style

- Answer in the language of the user.
- Be short. Report what you did, what the result was, and where the files are.
- Write the final answer in Markdown. The app renders Markdown. Put code in a
  fenced block with the language, for example ```python.
- Never invent the output of a command. Report only what a tool returned.

# Safety

- The workspace is the user's real machine. Change only what the task needs.
- Never print secrets, tokens, passwords, or key material.
- Before a destructive command (delete, overwrite, `git reset`), say in one
  sentence what you are about to do, then do it.
"""

TOOL_PROTOCOL = """\
# Tool-call format

To call a tool, write one block in your reply:

<tool_call>{"name": "<tool name>", "arguments": {"<key>": "<value>"}}</tool_call>

Rules:

- The body is strict JSON: double quotes, no comments, no trailing comma.
- Several blocks in one reply run in order, top to bottom.
- Never put a tool call inside a code fence, and never show one as an example.
  Every block you write is executed.
- A reply with no tool-call block ends the task. Do not end while work is left.
- Each result comes back as `<tool_result name="...">...</tool_result>`.

Example. The user asks for a Python script that prints the date:

<tool_call>{"name": "write_file", "arguments": {"path": "show_date.py", "content": "import datetime\\nprint(datetime.date.today())\\n"}}</tool_call>

Then, in the next turn, run it:

<tool_call>{"name": "run_command", "arguments": {"command": "python3 show_date.py"}}</tool_call>
"""


def _render_arguments(schema: dict) -> list[str]:
    """One readable line per argument, from the tool's JSON schema."""
    props = (schema or {}).get("properties") or {}
    required = set((schema or {}).get("required") or [])
    lines: list[str] = []
    for name, prop in props.items():
        prop = prop if isinstance(prop, dict) else {}
        kind = prop.get("type", "string")
        flag = "required" if name in required else "optional"
        description = prop.get("description", "")
        default = prop.get("default")
        if default is not None:
            description = f"{description} Default: {json.dumps(default)}.".strip()
        lines.append(f"  - `{name}` ({kind}, {flag}) {description}".rstrip())
    return lines


def render_tool_block(name: str, schema: dict | None) -> str:
    """One tool's prompt block: heading, description, argument lines.

    Public because three callers must agree on it to the character:
    :func:`render_tool_docs` writes it into the prompt, ``tool_describe``
    (§7.2) hands the same text back for a deferred tool, and the tool-search
    threshold is measured on it. A second renderer would make the measured
    saving a fiction.
    """
    schema = schema or {}
    blocks = [f"\n## {name}\n"]
    summary = schema.get("description")
    if summary:
        blocks.append(f"{summary}\n")
    arguments = _render_arguments(schema)
    if arguments:
        blocks.append("Arguments:")
        blocks.extend(arguments)
    else:
        blocks.append("Arguments: none.")
    return "\n".join(blocks)


def render_tool_docs(registry: ToolRegistry) -> str:
    """Render the registry as prompt text. Unavailable tools (a failing
    ``check_fn``) are left out — the model must not call what cannot run — and
    so are deferred tools (§7.2), which the model reaches through
    ``tool_search`` / ``tool_call`` instead."""
    blocks: list[str] = ["# Tools you can call"]
    for name in registry.names():
        if not registry.available(name) or registry.is_deferred(name):
            continue
        blocks.append(render_tool_block(name, registry.spec(name).schema))
    return "\n".join(blocks)


def build_system_prompt(
    registry: ToolRegistry,
    *,
    persona: str | None = None,
    workspace: str | None = None,
    skills: str | None = None,
    memory: str | None = None,
) -> str:
    """Compose the full system prompt: behaviour + wire format + live tools +
    the skill catalogue + the memory snapshot + the operator persona (last, so
    it wins on any conflict).

    ``skills`` carries names and descriptions only (§11); ``memory`` is the
    frozen snapshot (§12) — both are read once, when a session is seeded, and
    never rewritten mid-session, so the prefix cache survives the whole run.
    Both are sanitized by their own module before they arrive here.
    """
    parts = [BASE_INSTRUCTIONS, TOOL_PROTOCOL, render_tool_docs(registry)]
    if skills and skills.strip():
        parts.append(skills.strip())
    if memory and memory.strip():
        parts.append(memory.strip())
    if workspace:
        parts.append(
            "# Workspace\n\n"
            f"Your working directory is `{workspace}`. Use relative paths inside it."
        )
    if persona and persona.strip():
        parts.append(f"# Operator instructions\n\n{persona.strip()}")
    return "\n\n".join(part.strip() for part in parts if part.strip()) + "\n"
