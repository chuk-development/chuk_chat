"""File tools read relative paths from the workspace root (live test
2026-10-09): the sandbox shell keeps its working directory, so after
``cd tmp/images`` a relative ``tmp/images/a.jpg`` missed the file and the
vision check failed."""

from __future__ import annotations

from chuk_agents_runtime import LocalEnvironment, ToolRegistry, register_builtin_tools
from chuk_agents_runtime.sandbox_io import fetch_bytes, workspace_path


class _Rooted(LocalEnvironment):
    """A local environment whose shell sits in a sub directory, like the
    sandbox after the agent ran ``cd``."""

    def __init__(self, root: str, cwd: str) -> None:
        self.root = root
        self._shell_cwd = cwd

    def run_bash(self, cmd, **kwargs):
        return super().run_bash(f"cd {self._shell_cwd} && {cmd}", **kwargs)


def test_workspace_path_joins_only_relative_paths():
    env = _Rooted("/workspace", "/workspace/tmp")
    assert workspace_path(env, "tmp/a.jpg") == "/workspace/tmp/a.jpg"
    assert workspace_path(env, "/etc/x") == "/etc/x"
    assert workspace_path(env, "~/x") == "~/x"
    assert workspace_path(LocalEnvironment(), "a.txt") == "a.txt"


def test_file_tools_find_a_file_after_the_shell_moved(tmp_path):
    (tmp_path / "tmp" / "images").mkdir(parents=True)
    (tmp_path / "tmp" / "images" / "a.txt").write_text("hello")
    env = _Rooted(str(tmp_path), str(tmp_path / "tmp" / "images"))
    assert fetch_bytes(env, "tmp/images/a.txt").data == b"hello"

    registry = ToolRegistry()
    register_builtin_tools(registry, env)
    assert registry.dispatch("read_file", {"path": "tmp/images/a.txt"})["content"] == "hello"
    written = registry.dispatch("write_file", {"path": "notes/b.md", "content": "x"})
    assert written["ok"] is True
    assert (tmp_path / "notes" / "b.md").read_text() == "x"
