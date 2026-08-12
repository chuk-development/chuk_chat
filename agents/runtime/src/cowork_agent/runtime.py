"""End-to-end wiring: model + registry + environment + state -> a runnable loop.

``build_runtime`` assembles the core into one :class:`AgentLoop`. With a mock
model it runs fully offline; swap in ``OpenAICompatModelClient`` and the real
sandbox ``Environment`` for production.
"""

from __future__ import annotations

from .environment import Environment, LocalEnvironment
from .loop import AgentLoop, IterationBudget, KillSwitch
from .model import ModelClient
from .prompt import build_system_prompt
from .registry import ToolRegistry
from .state import StateStore
from .tools import register_builtin_tools
from .web_search import DEFAULT_BASE_URL, TokenSession


def build_runtime(
    model: ModelClient,
    *,
    db_path: str,
    environment: Environment | None = None,
    max_iterations: int = 50,
    budget: int | None = None,
    estop_path: str | None = None,
    system_prompt: str | None = None,
    workspace: str | None = None,
    include_tool_docs: bool = True,
    session: TokenSession | None = None,
    base_url: str = DEFAULT_BASE_URL,
) -> AgentLoop:
    """Assemble the loop. ``system_prompt`` is the operator *persona*: the
    behaviour contract, the ``<tool_call>`` wire format and the live tool list
    are prepended from :mod:`cowork_agent.prompt`, so a tool can never be
    registered without being documented to the model. Pass
    ``include_tool_docs=False`` to use ``system_prompt`` verbatim (tests).

    ``session`` is the account session. Pass it and ``web_search`` joins the
    tool set (it bills the account through our backend); leave it out and only
    the local tools — including ``web_fetch`` — are registered."""
    env = environment or LocalEnvironment()
    registry = ToolRegistry()
    register_builtin_tools(registry, env, session=session, base_url=base_url)

    prompt = (
        build_system_prompt(registry, persona=system_prompt, workspace=workspace)
        if include_tool_docs
        else system_prompt
    )

    store = StateStore(db_path)
    return AgentLoop(
        model,
        registry,
        store,
        max_iterations=max_iterations,
        budget=IterationBudget(budget if budget is not None else max_iterations),
        kill_switch=KillSwitch(estop_path),
        system_prompt=prompt,
    )
