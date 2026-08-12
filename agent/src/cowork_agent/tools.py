"""Built-in tools.

Currently the ``run_command`` tool, which runs a shell command via an injected
:class:`~cowork_agent.environment.Environment`. It depends only on the protocol;
the real sandbox is wired at integration time.
"""

from __future__ import annotations

from .environment import Environment
from .registry import ToolRegistry

RUN_COMMAND_SCHEMA = {
    "type": "object",
    "properties": {
        "command": {"type": "string", "description": "Shell command to run."},
        "timeout": {
            "type": "integer",
            "description": "Seconds before the command is killed.",
        },
    },
    "required": ["command"],
}


def make_run_command_handler(env: Environment):
    def run_command(command: str, timeout: int = 120) -> dict:
        result = env.run_bash(command, timeout=timeout)
        return {
            "exit_code": result.exit_code,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "timed_out": result.timed_out,
            "duration_s": round(result.duration_s, 4),
        }

    return run_command


def register_run_command(registry: ToolRegistry, env: Environment) -> None:
    registry.register(
        "run_command",
        RUN_COMMAND_SCHEMA,
        make_run_command_handler(env),
    )
