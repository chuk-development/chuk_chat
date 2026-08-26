"""The interactive terminal (§7.8), against a fake tmux.

Everything here is deterministic: no tmux server, no real clock, no real
sleep. The real thing is exercised in ``test_terminal_tmux.py``, which is
skipped when tmux is absent.

What these tests pin down is the part that is easy to get wrong and expensive
when wrong: a literal string must never be read as a key name, a read must
never carry the scrollback or a screen full of padding, an unchanged screen
must cost nothing, and a terminal nobody closed must die on its own.
"""

from __future__ import annotations

import shlex

import pytest

from cowork_agent import ProcessResult, ToolRegistry, render_tool_docs
from cowork_agent.terminal import (
    TerminalManager,
    diff_screens,
    normalize_screen,
    register_terminal_tools,
    tmux_key,
)

DEFAULT_SCREEN = "$ "


class FakeEnv:
    """An ``Environment`` that fakes just enough tmux to be honest about it.

    It parses the command with ``shlex`` (so quoting is checked for real),
    splits chained tmux calls on ``&&``, and keeps a session set plus a queue
    of screens per session.
    """

    def __init__(self, has_tmux: bool = True) -> None:
        self.has_tmux = has_tmux
        self.commands: list[str] = []
        self.argvs: list[list[str]] = []
        self.sessions: set[str] = set()
        self.geometry: dict[str, tuple[int, int]] = {}
        self.start_dirs: dict[str, str] = {}
        self.screens: dict[str, list[str]] = {}
        self.broken: set[str] = set()

    # -- test helpers ------------------------------------------------------

    def set_screen(self, tmux_name: str, screen: str) -> None:
        self.screens[tmux_name] = [screen]

    def send_key_argvs(self) -> list[list[str]]:
        return [a for a in self.argvs if a[:2] == ["tmux", "send-keys"]]

    def sub_argvs(self, sub: str) -> list[list[str]]:
        return [a for a in self.argvs if a[:2] == ["tmux", sub]]

    # -- the Environment seam ---------------------------------------------

    def run_bash(
        self, cmd: str, *, timeout: int = 120, internal: bool = False
    ) -> ProcessResult:
        self.commands.append(cmd)
        tokens = shlex.split(cmd)
        groups: list[list[str]] = [[]]
        for token in tokens:
            if token == "&&":
                groups.append([])
            else:
                groups[-1].append(token)
        out = ""
        for argv in groups:
            if not argv:
                continue
            code, text = self._one(argv)
            if code:
                return ProcessResult(code, out, "fake tmux: error")
            out += text
        return ProcessResult(0, out, "")

    def _one(self, argv: list[str]) -> tuple[int, str]:
        if argv[0] == "command":
            return (0 if self.has_tmux else 1), ""
        if argv[0] != "tmux":
            return 0, ""
        self.argvs.append(argv)
        sub = argv[1]
        raw_target = _flag(argv, "-t") or ""
        if sub in ("send-keys", "capture-pane"):
            # tmux 3.4: a pane target must carry the trailing ':', or the call
            # fails with "can't find pane". The fake insists on it too, so the
            # quirk cannot silently regress.
            target = raw_target[1:-1] if _is_pane_target(raw_target) else None
        else:
            target = raw_target.lstrip("=")
        if sub == "new-session":
            name = _flag(argv, "-s") or ""
            self.sessions.add(name)
            self.geometry[name] = (int(_flag(argv, "-y")), int(_flag(argv, "-x")))
            start = _flag(argv, "-c")
            if start:
                self.start_dirs[name] = start
            return 0, ""
        if sub == "kill-session":
            if target in self.sessions:
                self.sessions.discard(target)
                return 0, ""
            return 1, ""
        if sub == "has-session":
            return (0 if target in self.sessions else 1), ""
        if sub == "send-keys":
            return (0 if target in self.sessions else 1), ""
        if sub == "capture-pane":
            if target not in self.sessions or target in self.broken:
                return 1, ""
            queue = self.screens.get(target) or [DEFAULT_SCREEN]
            screen = queue.pop(0) if len(queue) > 1 else queue[0]
            return 0, screen
        return 0, ""


def _is_pane_target(target: str) -> bool:
    return target.startswith("=") and target.endswith(":") and len(target) > 2


def _flag(argv: list[str], flag: str) -> str | None:
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture()
def setup():
    def _build(has_tmux: bool = True, **kwargs):
        env = FakeEnv(has_tmux=has_tmux)
        clock = FakeClock()
        manager = TerminalManager(
            env, task_id="t1", clock=clock, sleep=clock.sleep, **kwargs
        )
        registry = ToolRegistry()
        register_terminal_tools(registry, manager)
        return env, manager, registry, clock

    return _build


def _tmux_name(manager: TerminalManager, name: str = "main") -> str:
    return f"cw-{manager.task_id}-{name}"


# -- key mapping -----------------------------------------------------------


@pytest.mark.parametrize(
    ("given", "expected"),
    [
        ("enter", "Enter"),
        ("Return", "Enter"),
        ("esc", "Escape"),
        ("backspace", "BSpace"),
        ("shift-tab", "BTab"),
        ("pgdn", "PageDown"),
        ("delete", "DC"),
        ("f5", "F5"),
        ("f12", "F12"),
        ("c-c", "C-c"),
        ("ctrl-d", "C-d"),
        ("^l", "C-l"),
        ("alt-x", "M-x"),
        ("m-C-a", "C-M-a"),
    ],
)
def test_key_names_map_to_tmux_names(given, expected):
    assert tmux_key(given) == expected


@pytest.mark.parametrize("bad", ["retrun", "f13", "control-alt-delete", "", "meta"])
def test_unknown_key_names_are_refused_not_guessed(bad):
    with pytest.raises(Exception) as excinfo:
        tmux_key(bad)
    assert "key" in str(excinfo.value).lower()


# -- the literal-text trap -------------------------------------------------


def test_literal_text_is_never_interpreted_as_a_key_name(setup):
    """The trap: a prompt asking for a word, and the word is "Enter". Sent
    without ``-l`` that is a keypress, and the form submits."""
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    result = registry.dispatch(
        "terminal_send_keys", {"text": "Enter Escape C-c Up", "read": False}
    )
    assert result["ok"] is True

    sends = env.send_key_argvs()
    assert len(sends) == 1
    assert sends[0][-3:] == ["-l", "--", "Enter Escape C-c Up"]
    # Not one bare key press anywhere: the text stayed text.
    assert all("-l" in argv or "-H" in argv for argv in sends)


def test_named_keys_travel_without_the_literal_flag(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    registry.dispatch(
        "terminal_send_keys",
        {"text": "y", "keys": ["down", "c-c"], "enter": True, "read": False},
    )
    sends = env.send_key_argvs()
    assert sends[0][-3:] == ["-l", "--", "y"]
    assert [argv[-1] for argv in sends[1:]] == ["Down", "C-c", "Enter"]
    assert all("-l" not in argv for argv in sends[1:])


def test_a_bad_key_name_sends_nothing_at_all(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    result = registry.dispatch(
        "terminal_send_keys", {"text": "rm -rf /", "keys": ["Retrun"]}
    )
    assert result["ok"] is False
    assert "unknown key name" in result["error"]
    assert env.send_key_argvs() == []


def test_trailing_semicolon_is_sent_by_hex_because_tmux_eats_it(setup):
    """Verified against tmux 3.4: ``send-keys -l 'echo A;'`` arrives as
    ``echo A``. One stripped character silently changes the command."""
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    registry.dispatch("terminal_send_keys", {"text": "echo A;;", "read": False})
    sends = env.send_key_argvs()
    assert sends[0][-3:] == ["-l", "--", "echo A"]
    assert sends[1][-3:] == ["-H", "3b", "3b"]


def test_a_semicolon_inside_the_line_stays_in_the_literal_argument(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    registry.dispatch("terminal_send_keys", {"text": "a;b", "read": False})
    assert env.send_key_argvs()[0][-1] == "a;b"


def test_a_newline_in_text_becomes_an_enter_press(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    registry.dispatch("terminal_send_keys", {"text": "one\ntwo", "read": False})
    sends = env.send_key_argvs()
    assert [argv[-1] for argv in sends] == ["one", "Enter", "two"]


@pytest.mark.parametrize("args", [{}, {"text": ""}, {"keys": []}])
def test_send_keys_needs_something_to_send(setup, args):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    result = registry.dispatch("terminal_send_keys", dict(args))
    assert result["ok"] is False
    assert "nothing to send" in result["error"]


# -- the viewport ----------------------------------------------------------


def test_normalize_screen_bounds_rows_and_cols_and_trims_padding():
    raw = "\n".join(["x" * 200, "keep"] + [""] * 20 + ["over"] * 40)
    lines = normalize_screen(raw, rows=24, cols=80)
    assert len(lines) == 24
    assert lines[0] == "x" * 80
    assert lines[1] == "keep"


def test_normalize_screen_drops_the_trailing_blank_padding():
    lines = normalize_screen("$ \n\n\n\n", rows=24, cols=80)
    assert lines == ["$"]


def test_a_read_never_asks_for_the_scrollback(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    registry.dispatch("terminal_read", {})
    captures = env.sub_argvs("capture-pane")
    assert captures
    for argv in captures:
        assert "-S" not in argv and "-E" not in argv


def test_the_pane_is_created_with_the_bounded_geometry(setup):
    env, manager, registry, _ = setup(rows=10, cols=40)
    registry.dispatch("terminal_open", {"cwd": "/tmp/work"})
    tmux = _tmux_name(manager)
    assert env.geometry[tmux] == (10, 40)
    assert env.start_dirs[tmux] == "/tmp/work"


def test_geometry_is_clamped_to_the_ceiling(setup):
    env, manager, registry, _ = setup(rows=9999, cols=9999)
    assert (manager.rows, manager.cols) == (60, 200)


# -- diff reads ------------------------------------------------------------


def test_diff_screens_reports_the_changed_row_and_its_number():
    old = ["a", "b", "c"]
    new = ["a", "B", "c"]
    assert diff_screens(old, new) == [(2, "B")]


def test_diff_screens_reports_a_line_that_went_blank():
    assert diff_screens(["a", "b"], ["a"]) == [(2, "")]


def test_first_read_is_full_then_later_reads_are_diffs(setup):
    env, manager, registry, _ = setup()
    tmux = _tmux_name(manager)
    menu = "Select:\n> one\n  two\n  three"
    env.set_screen(tmux, menu)

    opened = registry.dispatch("terminal_open", {})
    assert opened["mode"] == "full"
    assert opened["screen"] == menu

    env.set_screen(tmux, "Select:\n  one\n> two\n  three")
    moved = registry.dispatch("terminal_read", {})
    assert moved["mode"] == "diff"
    assert moved["changed"] is True
    assert moved["changed_lines"] == 2
    assert moved["screen"] == "2|   one\n3| > two"


def test_an_unchanged_screen_costs_a_two_word_result(setup):
    env, manager, registry, _ = setup()
    env.set_screen(_tmux_name(manager), "Select:\n> one\n  two")
    registry.dispatch("terminal_open", {})

    idle = registry.dispatch("terminal_read", {})
    assert idle["changed"] is False
    assert idle["screen"] == "no change"


def test_a_full_capture_can_always_be_forced(setup):
    env, manager, registry, _ = setup()
    screen = "Select:\n> one\n  two"
    env.set_screen(_tmux_name(manager), screen)
    registry.dispatch("terminal_open", {})

    full = registry.dispatch("terminal_read", {"full": True})
    assert full["mode"] == "full"
    assert full["screen"] == screen


def test_a_mostly_changed_screen_falls_back_to_the_full_capture(setup):
    """A scrolled shell shifts every row, and a numbered diff of every row is
    bigger than the screen it describes."""
    env, manager, registry, _ = setup()
    tmux = _tmux_name(manager)
    env.set_screen(tmux, "\n".join(f"line {i}" for i in range(10)))
    registry.dispatch("terminal_open", {})

    env.set_screen(tmux, "\n".join(f"line {i}" for i in range(1, 11)))
    scrolled = registry.dispatch("terminal_read", {})
    assert scrolled["mode"] == "full"
    assert scrolled["reason"] == "most of the screen changed"


def test_send_keys_returns_the_diff_so_one_call_is_one_interaction(setup):
    env, manager, registry, _ = setup()
    tmux = _tmux_name(manager)
    env.set_screen(tmux, "Menu\n> one\n  two\n  three\n  four")
    registry.dispatch("terminal_open", {})
    env.set_screen(tmux, "Menu\n  one\n> two\n  three\n  four")

    result = registry.dispatch("terminal_send_keys", {"keys": ["down"]})
    assert result["mode"] == "diff"
    assert result["screen"] == "2|   one\n3| > two"


# -- waiting ---------------------------------------------------------------


def test_wait_returns_as_soon_as_the_pattern_shows_up(setup):
    env, manager, registry, clock = setup()
    tmux = _tmux_name(manager)
    env.set_screen(tmux, "booting")
    registry.dispatch("terminal_open", {})
    env.screens[tmux] = ["booting", "booting", "ready >"]

    result = registry.dispatch("terminal_wait", {"pattern": r"ready >"})
    assert result["outcome"] == "matched"
    assert "ready >" in result["screen"]


def test_wait_gives_up_and_says_so(setup):
    env, manager, registry, clock = setup()
    env.set_screen(_tmux_name(manager), "spinner /")
    registry.dispatch("terminal_open", {})

    result = registry.dispatch(
        "terminal_wait", {"pattern": "never", "timeout_s": 1, "idle_ms": 0}
    )
    assert result["outcome"] == "timeout"


def test_wait_without_a_pattern_returns_when_the_redraw_settles(setup):
    env, manager, registry, clock = setup()
    tmux = _tmux_name(manager)
    env.set_screen(tmux, "drawing 1")
    registry.dispatch("terminal_open", {})
    env.screens[tmux] = ["drawing 2", "drawing 3", "done", "done", "done"]

    result = registry.dispatch("terminal_wait", {"idle_ms": 100})
    assert result["outcome"] == "idle"
    assert "done" in result["screen"]


def test_wait_refuses_a_broken_pattern(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    result = registry.dispatch("terminal_wait", {"pattern": "("})
    assert result["ok"] is False
    assert "invalid pattern" in result["error"]


# -- lifecycle -------------------------------------------------------------


def test_a_new_task_cannot_inherit_a_terminal(setup):
    """Task scoping is in the session name, so two tasks cannot collide even
    if both call their terminal "main"."""
    env_a, manager_a, _, _ = setup()
    manager_b = TerminalManager(FakeEnv(), task_id="t2")
    assert _tmux_name(manager_a) != _tmux_name(manager_b)


def test_open_kills_a_leftover_session_before_starting(setup):
    env, manager, registry, _ = setup()
    tmux = _tmux_name(manager)
    env.sessions.add(tmux)  # a leftover from an earlier run

    registry.dispatch("terminal_open", {})
    kills = env.sub_argvs("kill-session")
    assert kills and kills[0][-1] == f"={tmux}"
    assert env.sub_argvs("new-session")


def test_reuse_continues_the_named_session_instead_of_restarting_it(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.argvs.clear()

    again = registry.dispatch("terminal_open", {"reuse": True})
    assert again["reused"] is True
    assert env.sub_argvs("new-session") == []
    assert env.sub_argvs("kill-session") == []


def test_close_kills_the_session(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    tmux = _tmux_name(manager)

    result = registry.dispatch("terminal_close", {})
    assert result["closed"] is True
    assert tmux not in env.sessions
    assert manager.list_sessions() == []


def test_the_idle_reaper_kills_what_the_agent_abandoned(setup):
    env, manager, registry, clock = setup(idle_timeout_s=60)
    registry.dispatch("terminal_open", {})
    tmux = _tmux_name(manager)
    assert tmux in env.sessions

    clock.now += 61
    # Any tool call reaps first; a read of the abandoned terminal then fails.
    result = registry.dispatch("terminal_read", {})
    assert result["ok"] is False
    assert tmux not in env.sessions
    assert manager.list_sessions() == []


def test_the_reaper_spares_a_terminal_still_in_use(setup):
    env, manager, registry, clock = setup(idle_timeout_s=60)
    registry.dispatch("terminal_open", {})
    clock.now += 50
    registry.dispatch("terminal_read", {})
    clock.now += 50
    assert registry.dispatch("terminal_read", {})["ok"] is True


def test_close_all_is_the_task_teardown(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {"name": "one"})
    registry.dispatch("terminal_open", {"name": "two"})
    assert sorted(manager.close_all()) == ["one", "two"]
    assert env.sessions == set()


def test_too_many_terminals_is_an_error_not_a_fork_bomb(setup):
    env, manager, registry, _ = setup(max_sessions=2)
    registry.dispatch("terminal_open", {"name": "a"})
    registry.dispatch("terminal_open", {"name": "b"})
    result = registry.dispatch("terminal_open", {"name": "c"})
    assert result["ok"] is False
    assert "too many open terminals" in result["error"]


def test_reading_an_unopened_terminal_says_how_to_open_one(setup):
    env, manager, registry, _ = setup()
    result = registry.dispatch("terminal_read", {"name": "ghost"})
    assert result["ok"] is False
    assert "terminal_open" in result["error"]


def test_a_terminal_whose_program_exited_reports_cleanly(setup):
    env, manager, registry, _ = setup()
    registry.dispatch("terminal_open", {})
    env.sessions.clear()  # the program exited, tmux tore the session down

    result = registry.dispatch("terminal_read", {})
    assert result["ok"] is False
    assert "not running" in result["error"]
    assert manager.list_sessions() == []


@pytest.mark.parametrize("bad", ["../etc", "a b", "x" * 33, "sess:1", ""])
def test_terminal_names_are_restricted(setup, bad):
    env, manager, registry, _ = setup()
    result = registry.dispatch("terminal_read", {"name": bad})
    assert result["ok"] is False
    assert "invalid terminal name" in result["error"] or "no terminal" in result["error"]


# -- availability ----------------------------------------------------------


def test_without_tmux_the_tools_are_invisible_and_inert(setup):
    env, manager, registry, _ = setup(has_tmux=False)
    for name in (
        "terminal_open",
        "terminal_send_keys",
        "terminal_read",
        "terminal_wait",
        "terminal_close",
    ):
        assert registry.has(name)
        assert registry.available(name) is False
        result = registry.dispatch(name, {})
        assert result["error"] == f"tool unavailable: {name}"
    assert "terminal_open" not in render_tool_docs(registry)


def test_with_tmux_the_tools_are_documented_once(setup):
    env, manager, registry, _ = setup()
    docs = render_tool_docs(registry)
    assert "## terminal_open" in docs
    assert "## terminal_send_keys" in docs
    assert env.commands.count("command -v tmux >/dev/null 2>&1") == 1


def test_the_tmux_probe_is_cached_across_calls(setup):
    env, manager, registry, _ = setup()
    for _ in range(5):
        registry.available("terminal_read")
    assert env.commands.count("command -v tmux >/dev/null 2>&1") == 1
