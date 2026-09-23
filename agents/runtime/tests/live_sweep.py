"""Diagnostic sweep: which models actually call a tool when offered one?

One turn per model, same prompt, same system prompt, the same native ``tools``
array. Prints per model which calls came back on the ``tool_calls`` frame. This
is what decides the default model.

    cd agent && uv run --with pytest python tests/live_sweep.py [model ...]
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session  # noqa: E402

from chuk_agents_runtime import (  # noqa: E402
    BackendModelClient,
    LocalEnvironment,
    ToolRegistry,
    build_system_prompt,
    fetch_models_info,
    register_builtin_tools,
    resolve_model,
)
PROMPT = (
    "Write a small Python test script named test_demo.py in the workspace. "
    "It must print 'agents ok'. Then run it and report the output."
)

DEFAULT_CANDIDATES = [
    "qwen/qwen3.6-35b-a3b",
    "qwen/qwen3.5-35b-a3b",
    "qwen/qwen3-32b",
    "moonshotai/kimi-k2.6",
    "z-ai/glm-5.1",
    "deepseek/deepseek-v4-flash",
    "minimax/minimax-m2.7",
    "openai/gpt-oss-120b",
    "meta-llama/llama-3.3-70b-instruct",
    "mistralai/mistral-small-2603",
]


def main(argv: list[str]) -> int:
    session = _session()
    models = fetch_models_info(session)
    candidates = argv or DEFAULT_CANDIDATES

    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    system_prompt = build_system_prompt(registry, workspace="/tmp/ws")
    # The schemas travel natively, so every candidate is asked the same way the
    # runtime asks: one `tools` array, no in-band format.
    tools = registry.openai_tools()
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": PROMPT},
    ]

    print(f"{'model':<38} {'calls':<22} content  reasoning  cost")
    print("-" * 92)
    for model_id in candidates:
        try:
            resolved = resolve_model(models, preferred_model_id=model_id)
        except Exception as exc:  # model not offered by the account
            print(f"{model_id:<38} unavailable: {type(exc).__name__}")
            continue
        if resolved.model_id != model_id:
            print(f"{model_id:<38} not in account")
            continue
        client = BackendModelClient(
            session,
            model_id=resolved.model_id,
            provider_slug=resolved.provider_slug,
            max_tokens=900,
        )
        client.set_tools(tools)
        try:
            response = client.complete(messages)
        except Exception as exc:
            print(f"{model_id:<38} ERROR {type(exc).__name__}: {str(exc)[:40]}")
            continue
        finally:
            client.close()

        raw = response.raw.get("content", "") or ""
        names = ",".join(c.name for c in response.tool_calls) or "-"
        usage = response.raw.get("usage") or {}
        cost = usage.get("cost", 0.0)
        print(
            f"{model_id:<38} {names:<22} {len(raw):>7}  {len(response.raw.get('reasoning', '') or ''):>9}"
            f"  ${cost:.5f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
