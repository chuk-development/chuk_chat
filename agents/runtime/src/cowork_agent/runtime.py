"""End-to-end wiring: model + registry + environment + state -> a runnable loop.

``build_runtime`` assembles the core into one :class:`AgentLoop`. With a mock
model it runs fully offline; swap in ``OpenAICompatModelClient`` and the real
sandbox ``Environment`` for production.
"""

from __future__ import annotations

from .environment import Environment, LocalEnvironment
from .loop import AgentLoop, IterationBudget, KillSwitch
from .model import ModelClient
from .registry import ToolRegistry
from .state import StateStore
from .tools import register_run_command


def build_runtime(
    model: ModelClient,
    *,
    db_path: str,
    environment: Environment | None = None,
    max_iterations: int = 50,
    budget: int | None = None,
    estop_path: str | None = None,
    system_prompt: str | None = None,
) -> AgentLoop:
    env = environment or LocalEnvironment()
    registry = ToolRegistry()
    register_run_command(registry, env)

    store = StateStore(db_path)
    return AgentLoop(
        model,
        registry,
        store,
        max_iterations=max_iterations,
        budget=IterationBudget(budget if budget is not None else max_iterations),
        kill_switch=KillSwitch(estop_path),
        system_prompt=system_prompt,
    )
