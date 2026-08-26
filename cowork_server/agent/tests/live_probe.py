"""Diagnostic: one real model turn, raw content dumped.

Not a test — a probe. It answers the only question that matters when the model
refuses to call a tool: *what did it actually emit?* A model trained on another
tool-call format (Harmony channels, DeepSeek tokens, XML attributes) produces
text that our ``<tool_call>`` parser silently drops, and the loop then treats a
tool-only turn as a final answer.

    cd agent && uv run python tests/live_probe.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session, _setting  # noqa: E402

from cowork_agent import (  # noqa: E402
    BackendModelClient,
    LocalEnvironment,
    ToolRegistry,
    build_system_prompt,
    fetch_models_info,
    register_builtin_tools,
    resolve_model,
)
from cowork_agent.model import extract_tool_calls  # noqa: E402

PROMPT = (
    "Write a small Python test script named test_demo.py in the workspace. "
    "It must print 'cowork ok'. Then run it and report the output."
)


def main() -> int:
    session = _session()
    models = fetch_models_info(session)
    resolved = resolve_model(models, preferred_model_id=_setting("COWORK_LIVE_MODEL"))
    print(f"model    : {resolved.model_id}")
    print(f"provider : {resolved.provider_slug}")
    print(f"available: {len(models)} models")

    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    system_prompt = build_system_prompt(registry, workspace="/tmp/ws")
    print(f"system prompt: {len(system_prompt)} chars")

    client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=1024,
    )
    response = client.complete(
        [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": PROMPT},
        ]
    )
    client.close()

    raw = response.raw.get("content", "")
    reasoning = response.raw.get("reasoning", "")
    print("\n--- raw content ---")
    print(raw if raw else "(empty)")
    print("\n--- reasoning ---")
    print(reasoning[:2000] if reasoning else "(none)")
    print("\n--- parsed ---")
    _, calls = extract_tool_calls(raw)
    print(f"tool calls parsed: {[c.name for c in calls]}")
    print(f"usage: {response.raw.get('usage')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
