"""Task 1: the agent runs its ``run_command`` tool through the real sandbox."""

from __future__ import annotations

from cowork_agent import MockModelClient, ModelResponse, StopReason, ToolCall, build_runtime
from cowork_sandbox import LocalEnvironment

from cowork_executor import SandboxEnvironment


def test_shim_adapts_sandbox_result_fields():
    """The sandbox ProcessResult has no ``duration_s``; the shim adds it and keeps
    the shared fields."""
    with LocalEnvironment() as sandbox:
        shim = SandboxEnvironment(sandbox)
        result = shim.run_bash("echo hi", timeout=30)
    assert result.exit_code == 0
    assert result.stdout.strip() == "hi"
    assert result.timed_out is False
    # The field the agent's run_command handler reads, absent on the sandbox type.
    assert hasattr(result, "duration_s")
    assert result.duration_s >= 0.0


def test_agent_loop_runs_through_sandbox(tmp_path):
    """build_runtime + the shim: the agent's tool actually runs in the sandbox and
    the file lands in the sandbox workspace."""
    workdir = tmp_path / "ws"
    workdir.mkdir()
    with LocalEnvironment(workdir=str(workdir)) as sandbox:
        model = MockModelClient(
            [
                ModelResponse(
                    tool_calls=[
                        ToolCall(
                            id="c1",
                            name="run_command",
                            arguments={"command": "echo hello > f.txt", "timeout": "30"},
                        )
                    ]
                ),
                ModelResponse(text="done"),
            ]
        )
        loop = build_runtime(
            model,
            db_path=str(tmp_path / "state.db"),
            environment=SandboxEnvironment(sandbox),
        )
        result = loop.run("s1", "please make a file")

    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "done"
    made = workdir / "f.txt"
    assert made.exists()
    assert made.read_text().strip() == "hello"


def test_on_run_observer_fires():
    seen = []
    with LocalEnvironment() as sandbox:
        shim = SandboxEnvironment(sandbox, on_run=lambda cmd, res: seen.append((cmd, res)))
        shim.run_bash("true")
    assert len(seen) == 1
    assert seen[0][0] == "true"
    assert seen[0][1].exit_code == 0


def test_an_availability_probe_is_not_reported_as_agent_activity():
    """A tool's ``check_fn`` runs a shell command (``command -v tmux``) on the
    same seam the agent uses for real work. Without the ``internal`` flag that
    probe reached the user's thread as a tool call nobody asked for — the chat
    showed "ran run_command: command -v tmux"."""
    seen: list[str] = []
    with LocalEnvironment() as sandbox:
        shim = SandboxEnvironment(sandbox, on_run=lambda cmd, _r: seen.append(cmd))

        shim.run_bash("command -v tmux >/dev/null 2>&1", internal=True)
        assert seen == []

        shim.run_bash("echo hi")
        assert seen == ["echo hi"]
