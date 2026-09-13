"""Diagnostic: does the backend stream assistant text token-by-token (many
on_delta calls arriving over time), not one-shot at the end? Verifies the
streaming fix end to end against the live api.chuk.chat. Not a test — a probe.

    cd agent && uv run python tests/live_streaming_probe.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session, _setting  # noqa: E402

from chuk_agents_runtime import (  # noqa: E402
    BackendModelClient,
    fetch_models_info,
    resolve_model,
)

PROMPT = "Count slowly from 1 to 15 in words, one number per line. No preamble."


def main() -> int:
    session = _session()
    models = fetch_models_info(session)
    resolved = resolve_model(models, preferred_model_id=_setting("AGENTS_LIVE_MODEL"))
    print(f"model: {resolved.model_id} / {resolved.provider_slug}")

    client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=256,
    )

    start = time.monotonic()
    deltas: list[tuple[float, int]] = []

    def on_delta(chunk: str) -> None:
        deltas.append((time.monotonic() - start, len(chunk)))

    client.on_delta = on_delta
    resp = client.complete([{"role": "user", "content": PROMPT}])
    total = time.monotonic() - start
    client.close()

    n = len(deltas)
    print(f"deltas: {n}   total time: {total:.2f}s")
    if n:
        first = deltas[0][0]
        last = deltas[-1][0]
        print(f"first delta at {first:.2f}s, last at {last:.2f}s, spread {last - first:.2f}s")
        print(f"chars: {sum(d[1] for d in deltas)}   text len: {len(resp.text or '')}")
    # Streaming = many deltas spread over time, not one blob at the very end.
    ok = n >= 3 and (deltas[-1][0] - deltas[0][0]) > 0.05
    print("VERDICT:", "STREAMING WORKS (token-by-token)" if ok else "NOT streaming (one-shot)")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
