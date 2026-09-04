"""Diagnostic: does api.chuk.chat return a native `tool_calls` frame when the
request declares `tools`? This is the load-bearing assumption of the native
tool-call migration (spec risk #1). Not a test — a probe.

    cd agent && uv run python tests/live_native_probe.py
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
    fetch_models_info,
    register_builtin_tools,
    resolve_model,
)

PROMPT = (
    "List the files in the current directory. You MUST do this by calling the "
    "run_command tool with the command 'ls -la'. Do not answer in prose."
)


def main() -> int:
    session = _session()
    models = fetch_models_info(session)
    resolved = resolve_model(models, preferred_model_id=_setting("COWORK_LIVE_MODEL"))
    print(f"model    : {resolved.model_id}")
    print(f"provider : {resolved.provider_slug}")

    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    tools = registry.openai_tools()
    print(f"tools declared: {len(tools)} (e.g. {[t['function']['name'] for t in tools[:5]]})")

    client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=512,
    )
    client.set_tools(tools)
    resp = client.complete([{"role": "user", "content": PROMPT}])
    client.close()

    print("--- result ---")
    print(f"native tool_calls frame used: {resp.raw.get('native')}")
    print(f"tool_calls: {[(c.name, c.arguments) for c in resp.tool_calls]}")
    text = (resp.text or "").strip()
    print(f"text ({len(text)} chars): {text[:200]!r}")
    raw_content = (resp.raw.get('content') or '')
    if not resp.raw.get('native'):
        print(f"raw content (fallback path): {raw_content[:300]!r}")
    ok = resp.raw.get("native") and resp.tool_calls
    print("VERDICT:", "NATIVE TOOL CALLS WORK" if ok else "native NOT observed (see above)")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
