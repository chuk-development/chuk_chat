"""LIVE probe for bead cowork-c91 — run directly, not via pytest.

    cd agent && uv run python tests/live_reprovision_probe.py

Shows, against the real backend, that an expired/invalid access token no longer
kills a model call while the app is attached: the client asks the app to
re-provision (here: a stand-in that answers after a moment with the real token),
waits, and retries the SAME request — GoTrue is never touched, so the user's
refresh token is NOT rotated and the running app keeps its session.

It deliberately does not rotate anything: the full live proof (the app rotates
its token mid-task, the host task continues) needs the real app with
tokenRefreshed -> provisionAccount and is run with it.
"""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session  # noqa: E402

from cowork_agent import BackendModelClient, fetch_models_info, resolve_model  # noqa: E402
from cowork_agent import backend as backend_mod  # noqa: E402


def main() -> int:
    real = _session()
    resolved = resolve_model(fetch_models_info(real))
    print(f"[live] model={resolved.model_id} provider={resolved.provider_slug}")

    # The host's view of the session: same pair, but the access token is junk —
    # exactly the state after the app rotated and the host's copy went stale.
    stale = backend_mod.SupabaseSession(
        access_token="stale-" + real.access_token[-8:],
        refresh_token=real.refresh_token,
        supabase_url=real.supabase_url,
        anon_key=real.anon_key,
    )
    stale.may_self_refresh = lambda: False  # a controller (the app) is attached

    def forbidden(*a, **k):
        raise AssertionError("GoTrue must not be called while the app is attached")

    backend_mod._gotrue = forbidden  # the probe proves the refresh token is never spent

    asked: list[str] = []

    def request(reason: str) -> None:
        asked.append(reason)
        print(f"[live] host -> app: reprovision_request ({reason})")

        def app_answers():
            stale.access_token = real.access_token  # the app's account_authentication
            stale.mark_reprovisioned()
            print("[live] app -> host: account_authentication (fresh pair) — waiter woken")

        threading.Timer(0.5, app_answers).start()

    stale.request_reprovision = request

    client = BackendModelClient(
        stale, model_id=resolved.model_id, provider_slug=resolved.provider_slug, max_tokens=32
    )
    t0 = time.monotonic()
    try:
        response = client.complete([{"role": "user", "content": "Reply with exactly: PONG"}])
    finally:
        client.close()
    text = (response.text or "").strip()
    print(f"[live] reply after {time.monotonic() - t0:.1f}s: {text!r}")

    ok = bool(asked) and "PONG" in text.upper()
    print(f"[live] reprovision requested: {bool(asked)}; request retried and succeeded: {'PONG' in text.upper()}")
    print("[live] RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
