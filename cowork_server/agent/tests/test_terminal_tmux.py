"""The interactive terminal against a real tmux server.

The fake in ``test_terminal.py`` proves the logic. This proves the claim that
matters for §7.8: a real interactive program keeps its state **between tool
calls**, which is exactly what the one-shot ``run_command`` tool cannot do.

Skipped when tmux is not installed. It is never installed by the test.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time

import pytest

from cowork_agent import LocalEnvironment, ToolRegistry
from cowork_agent.terminal import TerminalManager, register_terminal_tools

pytestmark = pytest.mark.skipif(
    shutil.which("tmux") is None, reason="tmux is not installed"
)

TASK_ID = f"it{os.getpid()}"


def _tmux_sessions() -> str:
    proc = subprocess.run(
        ["tmux", "list-sessions", "-F", "#{session_name}"],
        capture_output=True,
        text=True,
    )
    return proc.stdout


@pytest.fixture()
def registry(tmp_path):
    manager = TerminalManager(
        LocalEnvironment(), task_id=TASK_ID, rows=20, cols=90
    )
    reg = ToolRegistry()
    register_terminal_tools(reg, manager)
    try:
        yield reg
    finally:
        manager.close_all()


def _wait_for(registry, pattern, name="main", timeout_s=15.0):
    """Wait for text on screen and prove it arrived.

    The returned screen is a diff and may legitimately be "no change" — a
    ``terminal_send_keys`` before it already reported the new screen. The
    outcome is the assertion that counts.
    """
    result = registry.dispatch(
        "terminal_wait", {"name": name, "pattern": pattern, "timeout_s": timeout_s}
    )
    assert result["ok"] is True, result
    assert result["outcome"] == "matched", result
    return result


def _screen(registry, name="main"):
    result = registry.dispatch("terminal_read", {"name": name, "full": True})
    assert result["ok"] is True, result
    return result["screen"]


def test_tmux_is_reported_as_available(registry):
    assert registry.available("terminal_open") is True


def test_a_repl_keeps_its_state_across_separate_tool_calls(registry, tmp_path):
    opened = registry.dispatch(
        "terminal_open", {"cwd": str(tmp_path), "command": "python3 -i -q"}
    )
    assert opened["ok"] is True, opened
    _wait_for(registry, r">>>")

    # Tool call 1: bind a variable.
    typed = registry.dispatch(
        "terminal_send_keys", {"text": "chuk = 41", "enter": True}
    )
    assert typed["ok"] is True, typed

    # Tool call 2 — a separate dispatch, i.e. a separate agent round. The
    # interpreter must still be alive and must still remember `chuk`.
    registry.dispatch("terminal_send_keys", {"text": "print(chuk + 1)", "enter": True})
    _wait_for(registry, r"^42$")

    screen = _screen(registry)
    assert "42" in screen
    assert "NameError" not in screen


def test_the_word_enter_is_typed_not_pressed(registry, tmp_path):
    """The trap, for real: literal text that happens to name a key."""
    registry.dispatch("terminal_open", {"cwd": str(tmp_path), "command": "python3 -i -q"})
    _wait_for(registry, r">>>")

    registry.dispatch(
        "terminal_send_keys", {"text": 'word = "Enter Escape C-c"', "read": False}
    )
    # Nothing was submitted yet: the line sits on screen, unexecuted.
    assert 'word = "Enter Escape C-c"' in _screen(registry)

    registry.dispatch("terminal_send_keys", {"keys": ["Enter"]})
    registry.dispatch("terminal_send_keys", {"text": "print(len(word))", "enter": True})
    # 16 characters, not a submitted form and not an interrupt.
    _wait_for(registry, r"^16$")
    assert "SyntaxError" not in _screen(registry)


def test_a_trailing_semicolon_survives(registry, tmp_path):
    """tmux drops a trailing ``;`` from a ``send-keys -l`` argument; the hex
    fallback is what keeps the typed line intact."""
    registry.dispatch("terminal_open", {"cwd": str(tmp_path), "command": "python3 -i -q"})
    _wait_for(registry, r">>>")

    registry.dispatch("terminal_send_keys", {"text": "line = 'a;';", "read": False})
    assert "line = 'a;';" in _screen(registry)


def test_an_interactive_prompt_can_be_answered(registry, tmp_path):
    script = tmp_path / "ask.sh"
    script.write_text('read -p "Your name: " name\necho "hello $name"\n')
    registry.dispatch(
        "terminal_open", {"cwd": str(tmp_path), "command": "bash ask.sh"}
    )
    _wait_for(registry, r"Your name:")

    registry.dispatch("terminal_send_keys", {"text": "chuk", "enter": True})
    _wait_for(registry, r"hello chuk")
    assert "hello chuk" in _screen(registry)


def test_an_idle_screen_reads_as_no_change(registry, tmp_path):
    registry.dispatch("terminal_open", {"cwd": str(tmp_path), "command": "python3 -i -q"})
    _wait_for(registry, r">>>")
    registry.dispatch("terminal_read", {"full": True})

    time.sleep(0.3)
    idle = registry.dispatch("terminal_read", {})
    assert idle["changed"] is False
    assert idle["screen"] == "no change"


def test_a_menu_redraw_costs_only_the_changed_rows(registry, tmp_path):
    """The token lever: a full-screen repaint where two rows actually moved."""
    menu = tmp_path / "menu.sh"
    menu.write_text(
        "sel=1\n"
        "draw() { clear; echo 'Pick one'; for i in 1 2 3 4 5; do\n"
        "  if [ $i = $sel ]; then echo \"> item $i\"; else echo \"  item $i\"; fi\n"
        "done; }\n"
        "draw\n"
        "while read -rsn1 key; do sel=$((sel+1)); [ $sel -gt 5 ] && sel=1; draw; done\n"
    )
    registry.dispatch("terminal_open", {"cwd": str(tmp_path), "command": "bash menu.sh"})
    _wait_for(registry, r"> item 1")
    registry.dispatch("terminal_read", {"full": True})

    # One byte per keypress, because the toy menu reads one byte at a time.
    moved = registry.dispatch("terminal_send_keys", {"keys": ["Enter"]})
    assert moved["ok"] is True, moved
    assert moved["mode"] == "diff"
    assert moved["changed_lines"] == 2
    assert moved["screen"] == "2|   item 1\n3| > item 2"


def test_close_kills_the_real_session(registry, tmp_path):
    registry.dispatch("terminal_open", {"cwd": str(tmp_path)})
    assert f"cw-{TASK_ID}-main" in _tmux_sessions()

    registry.dispatch("terminal_close", {})
    assert f"cw-{TASK_ID}-main" not in _tmux_sessions()


def test_a_fresh_open_replaces_the_previous_terminal(registry, tmp_path):
    registry.dispatch("terminal_open", {"cwd": str(tmp_path), "command": "python3 -i -q"})
    _wait_for(registry, r">>>")
    registry.dispatch("terminal_send_keys", {"text": "marker = 1", "enter": True})

    registry.dispatch("terminal_open", {"cwd": str(tmp_path)})
    registry.dispatch("terminal_send_keys", {"text": "echo state-$?-clean", "enter": True})
    _wait_for(registry, r"state-0-clean")
    assert "marker" not in _screen(registry)
