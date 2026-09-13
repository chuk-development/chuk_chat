"""Diagnostic: does api.chuk.chat return a native `tool_calls` frame when the
request declares `tools`? This is the load-bearing assumption of the native
tool-call migration (spec risk #1). Not a test — a probe.

    cd agent && uv run python tests/live_native_probe.py
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session, _setting  # noqa: E402

from chuk_agents_runtime import (  # noqa: E402
    BackendModelClient,
    LocalEnvironment,
    ToolRegistry,
    fetch_models_info,
    register_builtin_tools,
    resolve_model,
)

#: How much life the access token must have left before the probe will run.
#: The token comes from the RUNNING APP's own session (see
#: ``test_live_model._session``), and Supabase makes a refresh token single-use:
#: refreshing here would rotate the pair and kill the app's copy — and the
#: host's. So the probe never refreshes; it only runs on a token that will
#: comfortably outlive it, and gives up otherwise.
MIN_TOKEN_HEADROOM = 15 * 60


def _token_headroom(access_token: str) -> float | None:
    """Seconds left on a JWT, read from its unverified ``exp`` claim.

    Nothing is verified and nothing is printed — this only decides whether to
    make a request at all. ``None`` means the claim could not be read.
    """
    parts = access_token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return float(claims["exp"]) - time.time()
    except (ValueError, KeyError, TypeError):
        return None


def _forbid_refresh(session) -> None:
    """Make any refresh attempt inside this probe fail loudly instead of
    spending the shared refresh token."""

    def _refuse(*_args, **_kwargs):
        raise SystemExit(
            "probe stopped: the backend asked for a token refresh. Refreshing "
            "here would rotate the app's refresh token and sign the app (and "
            "the host) out. Re-run when the app has refreshed by itself."
        )

    session.refresh = _refuse

PROMPT = (
    "List the files in the current directory. You MUST do this by calling the "
    "run_command tool with the command 'ls -la'. Do not answer in prose."
)


def main() -> int:
    session = _session()

    headroom = _token_headroom(session.access_token)
    if headroom is None:
        print("could not read the token expiry — refusing to run blind")
        return 3
    if headroom < MIN_TOKEN_HEADROOM:
        print(
            f"access token has {headroom / 60:.1f} min left, needs "
            f"{MIN_TOKEN_HEADROOM / 60:.0f}. The app refreshes near expiry — "
            "wait for that and re-run."
        )
        return 3
    print(f"token headroom: {headroom / 60:.1f} min")
    _forbid_refresh(session)

    models = fetch_models_info(session)
    wanted = _setting("AGENTS_LIVE_MODEL")
    # resolve_model falls back to the default model, then to the first one, so a
    # typo would silently probe a DIFFERENT model and report a pass for it.
    if wanted and wanted not in {m.get("id") for m in models}:
        print(f"model {wanted!r} is not in /v1/models_info — nothing to probe")
        return 3
    resolved = resolve_model(
        models,
        preferred_model_id=wanted,
        preferred_provider=_setting("AGENTS_LIVE_PROVIDER"),
    )
    print(f"model    : {resolved.model_id}")
    print(f"provider : {resolved.provider_slug}")
    wanted_provider = _setting("AGENTS_LIVE_PROVIDER")
    if wanted_provider and resolved.provider_slug != wanted_provider:
        print(
            f"provider {wanted_provider!r} is not offered for this model — "
            "nothing to probe"
        )
        return 3

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
