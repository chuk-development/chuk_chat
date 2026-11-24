"""Run modes that stick to a chat (CHAT-183, Grok Bot item 5,
docs/agents/GOAL_JUDGE_RUN_MODES.md).

A run mode is a small JSON data file. Built-in modes live in
``data/modes/`` of this package (``review``, ``research``, ``plan``,
``quick``, ``careful``); an agent can add its own or override a built-in one
with ``<workspace>/modes/<name>.json``. A mode can set:

- ``prompt``: an extra block, appended once per task as a context row
  (``source: mode``). The system prompt does not change (prefix cache);
- ``deny_groups`` / ``deny_tools``: tool groups or tools the mode refuses;
- ``allow_groups`` / ``allow_tools``: when given, ONLY these (plus the core
  tools in :data:`CORE_TOOLS`) may run;
- ``model`` / ``reasoning_effort``: the model the run uses;
- ``approvals``: ``"strict"`` makes every per-action class that would run
  without a card ask first. A mode can never make approvals weaker;
- ``plan``: ``true`` turns on plan mode (:mod:`.plan_mode`) while the mode
  is on.

The tool list the model sees does not change with the mode (prefix cache,
the same rule as plan mode). A refused tool stays listed and answers with an
error that names the mode.

The mode is per session and durable (``session_features``, kind
``run_mode``). It is set by the ``mode`` field of a ``task`` frame or a
``/mode <name>`` prefix, and it holds for every later task of the chat until
the user changes it (``mode: ""`` or ``/mode off`` clears it).
"""

from __future__ import annotations

import dataclasses
import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .registry import ToolRegistry
from .sources import SOURCE_MODE

FEATURE_KIND = "run_mode"
MODES_DIRNAME = "modes"
BUILTIN_DIR = Path(__file__).resolve().parent / "data" / "modes"

MODE_PREFIX = "/mode"
OFF_WORDS = frozenset({"", "off", "none", "default", "normal"})

MAX_PROMPT_CHARS = 4_000
MAX_MODE_FILE_BYTES = 32_000
_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

APPROVALS_DEFAULT = "default"
APPROVALS_STRICT = "strict"

#: Tools a mode never refuses: the loop's own controls, the agent's planning
#: and question tools, and the bridge a deferred tool is called through (the
#: bridge dispatches the real tool, which is checked on its own).
CORE_TOOLS = frozenset(
    {
        "finish",
        "skill",
        "search_tools",
        "tool_search",
        "tool_describe",
        "tool_call",
        "todo_write",
        "ask_user",
        "set_goal",
        "update_goal",
        "get_goal",
        "exit_plan_mode",
        "propose_skill",
    }
)

#: The tool groups a mode file can name. An entry that ends in ``*`` is a
#: name prefix.
TOOL_GROUPS: dict[str, tuple[str, ...]] = {
    "files_read": (
        "read_file", "list_dir", "stat_file", "read_document", "search_chats",
        "workspace_history", "grep_files",
    ),
    "files_write": (
        "write_file", "edit_file", "apply_patch", "workspace_undo", "document",
    ),
    "shell": ("run_command", "python", "shell_*", "job_*", "run_ffmpeg", "run_ffprobe"),
    "web": ("web_search", "web_fetch", "watch_url"),
    "browser": ("browser_*", "request_takeover"),
    "mail": ("mail_*", "watch_mail"),
    "mail_send": ("mail_send", "mail_reply", "mail_delete"),
    "messaging": (
        "send_message", "call_user", "call_status", "ask_agent",
        "send_file_to_agent", "share_file", "send_file_to_user",
    ),
    "automations": (
        "schedule_task", "list_automations", "cancel_automation",
        "pause_automation", "resume_automation",
    ),
    "publish": ("herenow_publish",),
    "subagents": ("delegate_task", "subagent_control"),
    "memory_write": ("memory_add",),
    "mcp": ("mcp__*",),
    "dashboard": ("dashboard",),
}


class RunModeError(ValueError):
    """A mode file or a switch that is refused."""


@dataclass(frozen=True)
class RunMode:
    name: str
    title: str = ""
    description: str = ""
    prompt: str = ""
    allow_groups: tuple[str, ...] = ()
    deny_groups: tuple[str, ...] = ()
    allow_tools: tuple[str, ...] = ()
    deny_tools: tuple[str, ...] = ()
    model: str | None = None
    reasoning_effort: str | None = None
    approvals: str = APPROVALS_DEFAULT
    plan: bool = False
    builtin: bool = True

    # -- the tool rule ------------------------------------------------------

    def _patterns(self, groups: Iterable[str], tools: Iterable[str]) -> list[str]:
        out: list[str] = []
        for group in groups:
            out.extend(TOOL_GROUPS.get(group, ()))
        out.extend(tools)
        return out

    @property
    def restricts_tools(self) -> bool:
        return bool(self.allow_groups or self.allow_tools or self.deny_groups or self.deny_tools)

    def allows(self, tool: str) -> bool:
        if tool in CORE_TOOLS:
            return True
        if _matches(tool, self._patterns(self.deny_groups, self.deny_tools)):
            return False
        if self.allow_groups or self.allow_tools:
            return _matches(tool, self._patterns(self.allow_groups, self.allow_tools))
        return True

    def view(self) -> dict:
        """The wire shape (the ``run_mode`` frame's ``mode`` field)."""
        out: dict[str, Any] = {
            "name": self.name,
            "title": self.title or self.name.capitalize(),
            "description": self.description,
            "builtin": self.builtin,
        }
        if self.model:
            out["model"] = self.model
        if self.reasoning_effort:
            out["reasoning_effort"] = self.reasoning_effort
        if self.approvals != APPROVALS_DEFAULT:
            out["approvals"] = self.approvals
        if self.plan:
            out["plan"] = True
        return out


def _matches(tool: str, patterns: Iterable[str]) -> bool:
    for pattern in patterns:
        if pattern.endswith("*"):
            if tool.startswith(pattern[:-1]):
                return True
        elif tool == pattern:
            return True
    return False


# -- loading -------------------------------------------------------------------


def _str_list(value: Any, key: str) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RunModeError(f"{key} must be a list of strings")
    return tuple(v.strip() for v in value if v.strip())


def parse_mode(data: Any, *, name: str | None = None, builtin: bool = False) -> RunMode:
    """One mode from its JSON object. Raises :class:`RunModeError`."""
    if not isinstance(data, dict):
        raise RunModeError("a mode file must hold one JSON object")
    raw_name = str(data.get("name") or name or "").strip().lower()
    if not _NAME.match(raw_name):
        raise RunModeError(f"bad mode name {raw_name!r}")
    if raw_name in OFF_WORDS:
        raise RunModeError(f"{raw_name!r} is reserved")
    for key in ("allow_groups", "deny_groups"):
        for group in _str_list(data.get(key), key):
            if group not in TOOL_GROUPS:
                raise RunModeError(f"unknown tool group {group!r} in {key}")
    approvals = str(data.get("approvals") or APPROVALS_DEFAULT).strip().lower()
    if approvals not in (APPROVALS_DEFAULT, APPROVALS_STRICT):
        raise RunModeError("approvals must be 'default' or 'strict'")
    prompt = data.get("prompt") or ""
    if not isinstance(prompt, str):
        raise RunModeError("prompt must be text")
    model = data.get("model")
    effort = data.get("reasoning_effort")
    return RunMode(
        name=raw_name,
        title=str(data.get("title") or "").strip()[:60],
        description=str(data.get("description") or "").strip()[:300],
        prompt=prompt.strip()[:MAX_PROMPT_CHARS],
        allow_groups=_str_list(data.get("allow_groups"), "allow_groups"),
        deny_groups=_str_list(data.get("deny_groups"), "deny_groups"),
        allow_tools=_str_list(data.get("allow_tools"), "allow_tools"),
        deny_tools=_str_list(data.get("deny_tools"), "deny_tools"),
        model=str(model).strip() if isinstance(model, str) and model.strip() else None,
        reasoning_effort=(
            str(effort).strip() if isinstance(effort, str) and effort.strip() else None
        ),
        approvals=approvals,
        plan=data.get("plan") is True,
        builtin=builtin,
    )


def _load_dir(directory: Path, *, builtin: bool) -> tuple[dict[str, RunMode], list[str]]:
    modes: dict[str, RunMode] = {}
    errors: list[str] = []
    try:
        files = sorted(directory.glob("*.json")) if directory.is_dir() else []
    except OSError:
        return modes, errors
    for path in files:
        try:
            if path.is_symlink() or path.stat().st_size > MAX_MODE_FILE_BYTES:
                errors.append(f"{path.name}: skipped (link or too large)")
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
            mode = parse_mode(data, name=path.stem, builtin=builtin)
        except (OSError, ValueError) as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        modes[mode.name] = mode
    return modes, errors


def load_modes(
    workspace: str | Path | None = None, *, builtin_dir: str | Path | None = None
) -> tuple[dict[str, RunMode], list[str]]:
    """Built-in modes, then the agent's own (``<workspace>/modes``), which
    win on the same name. Returns the modes and the load errors."""
    modes, errors = _load_dir(Path(builtin_dir) if builtin_dir else BUILTIN_DIR, builtin=True)
    if workspace:
        own, own_errors = _load_dir(Path(workspace) / MODES_DIRNAME, builtin=False)
        modes.update(own)
        errors.extend(own_errors)
    return modes, errors


def list_modes(workspace: str | Path | None = None) -> list[dict]:
    modes, _ = load_modes(workspace)
    return [modes[name].view() for name in sorted(modes)]


# -- the switch ------------------------------------------------------------------


def parse_mode_prefix(prompt: Any) -> tuple[str | None, Any]:
    """``/mode <name> <message>`` switches the mode, ``/mode off <message>``
    clears it. Returns the switch (``None``: no prefix, ``""``: clear) and the
    prompt without the prefix."""
    if not isinstance(prompt, str):
        return None, prompt
    match = re.match(r"^\s*/mode(?:\s+|$)", prompt)
    if match is None:
        return None, prompt
    rest = prompt[match.end():]
    word = re.match(r"^(\S+)(?:\s+|$)", rest)
    if word is None:
        return None, prompt
    name = word.group(1).strip().lower()
    message = rest[word.end():].strip()
    if name in OFF_WORDS:
        return "", message or "The run mode is off."
    return name, message or f"The run mode is now {name}."


def normalize_switch(value: Any) -> str | None:
    """The ``mode`` field of a task frame: ``None`` (absent, no change),
    ``""`` (clear) or a mode name."""
    if value is None:
        return None
    if not isinstance(value, str):
        return None
    name = value.strip().lower()
    return "" if name in OFF_WORDS else name


class RunModeState:
    """The durable run mode of one session."""

    def __init__(self, store: Any, session_key: str) -> None:
        self.store = store
        self.session_key = session_key

    def name(self) -> str | None:
        doc = self.store.load_feature(self.session_key, FEATURE_KIND)
        name = doc.get("name") if isinstance(doc, dict) else None
        return name if isinstance(name, str) and name else None

    def set(self, name: str | None) -> bool:
        """Store the mode (``None`` / ``""`` clears). True when it changed."""
        new = name or None
        if self.name() == new:
            return False
        self.store.save_feature(
            self.session_key,
            FEATURE_KIND,
            {"name": new, "updated_at": time.time()} if new else None,
        )
        return True


@dataclass
class ModeResolution:
    """What applying a run's switch gave: the mode now on (or ``None``),
    whether it changed, and an error to show (an unknown name)."""

    mode: RunMode | None
    changed: bool = False
    error: str | None = None
    available: list[str] = field(default_factory=list)


def resolve_run_mode(
    store: Any,
    session_key: str,
    switch: str | None,
    *,
    workspace: str | Path | None = None,
    plan_active: bool | None = None,
) -> ModeResolution:
    """Apply a task's switch and return the mode this run uses.

    An unknown name changes nothing and returns an error. A stored ``plan``
    mode whose plan mode was ended (the user approved the plan) counts as off
    and is cleared."""
    modes, _errors = load_modes(workspace)
    state = RunModeState(store, session_key)
    names = sorted(modes)
    changed = False
    error = None
    if switch is not None:
        if switch and switch not in modes:
            error = f"unknown run mode {switch!r}; known: {', '.join(names) or 'none'}"
        else:
            changed = state.set(switch or None)
    current = state.name()
    mode = modes.get(current) if current else None
    if current and mode is None:
        # The file is gone: the chat falls back to no mode.
        state.set(None)
        changed = True
    elif mode is not None and mode.plan and plan_active is False and not changed:
        # Plan approved (exit_plan_mode turned plan mode off): the mode ends.
        state.set(None)
        mode, changed = None, True
    return ModeResolution(mode=mode, changed=changed, error=error, available=names)


# -- what a mode does to a run -------------------------------------------------------


def mode_context_rows(mode: RunMode | None) -> list[dict]:
    """The once-per-task row with the mode's prompt block."""
    if mode is None or not mode.prompt:
        return []
    return [
        {
            "role_tag": "context",
            "role": "user",
            "source": SOURCE_MODE,
            "content": f"<run_mode name={json.dumps(mode.name)}>\n{mode.prompt}\n</run_mode>",
        }
    ]


def refused_result(tool: str, mode: RunMode) -> dict:
    return {
        "ok": False,
        "error": (
            f"{tool} is not allowed in {mode.name} mode. Do the task without it, or tell "
            "the user that the mode must change first."
        ),
        "mode": mode.name,
    }


def apply_mode_to_registry(registry: ToolRegistry, mode: RunMode | None) -> list[str]:
    """Wrap the handler of every tool the mode refuses. The schemas and the
    list stay the same bytes (prefix cache). Returns the refused names."""
    if mode is None or not mode.restricts_tools:
        return []
    refused: list[str] = []
    for name in registry.names():
        if mode.allows(name):
            continue
        spec = registry.spec(name)

        def _refuse(*_args: Any, _tool: str = name, **_kwargs: Any) -> dict:
            return refused_result(_tool, mode)

        registry._tools[name] = dataclasses.replace(spec, handler=_refuse, is_async=False)
        refused.append(name)
    return refused


def strict_policy(policy: Any) -> Any:
    """``allow`` becomes ``ask`` for every action class; ``deny`` stays.
    Allowed sites are dropped, so a site cannot skip the card either."""
    from .action_policy import ACTION_CLASSES, MODE_ALLOW, MODE_ASK, ActionPolicy

    modes = {}
    for action_class in ACTION_CLASSES:
        current = policy.mode(action_class)
        modes[action_class] = MODE_ASK if current == MODE_ALLOW else current
    return ActionPolicy(modes=modes, sites={})


def apply_mode_to_approvals(approvals: Any, mode: RunMode | None) -> Any:
    """The run's approval binding under the mode. Only ``strict`` changes
    it, and only when someone can answer a card (``ask`` is set)."""
    if approvals is None or mode is None or mode.approvals != APPROVALS_STRICT:
        return approvals
    if getattr(approvals, "ask", None) is None:
        return approvals
    inner = approvals.policy

    def policy() -> Any:
        return strict_policy(inner())

    try:
        return dataclasses.replace(approvals, policy=policy)
    except TypeError:
        return approvals


def run_mode_payload(
    session_key: str, mode: RunMode | None, *, error: str | None = None
) -> dict[str, Any]:
    """Executor -> app: the run mode of a session (on a change, and in the
    ``run_state``). ``mode`` is ``None`` when no mode is on."""
    payload: dict[str, Any] = {
        "type": "run_mode",
        "session_key": session_key,
        "mode": mode.view() if mode is not None else None,
    }
    if error:
        payload["error"] = error
    return payload


__all__ = [
    "BUILTIN_DIR",
    "CORE_TOOLS",
    "FEATURE_KIND",
    "ModeResolution",
    "RunMode",
    "RunModeError",
    "RunModeState",
    "SOURCE_MODE",
    "TOOL_GROUPS",
    "apply_mode_to_approvals",
    "apply_mode_to_registry",
    "list_modes",
    "load_modes",
    "mode_context_rows",
    "normalize_switch",
    "parse_mode",
    "parse_mode_prefix",
    "resolve_run_mode",
    "run_mode_payload",
    "strict_policy",
]
