"""LIVE test against the real account — proves the model actually calls tools.

Everything else in this suite is offline and proves the *wiring*. This one
proves the thing that broke in the field: asked for a script, the model printed
it in a code fence and wrote nothing to disk, because the system prompt never
told it that tools exist. Only a real model can prove that is fixed.

It is env-gated, so it is skipped by default and never spends credits in a
normal ``pytest`` run. Provide EITHER a token pair (preferred — no password
ever touches this process) or email + password for the one-time GoTrue login:

    # token (read from a logged-in client)
    export COWORK_LIVE_ACCESS_TOKEN=... COWORK_LIVE_REFRESH_TOKEN=...
    # or credentials
    export COWORK_LIVE_EMAIL=... COWORK_LIVE_PASSWORD=...
    # plus the project (or put them in the repo .env)
    export SUPABASE_URL=... SUPABASE_ANON_KEY=...

    uv run pytest tests/test_live_model.py -v -s

Cost: two or three small turns on the default open-weight model.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from cowork_agent import (
    BackendModelClient,
    LocalEnvironment,
    SupabaseSession,
    build_runtime,
    fetch_models_info,
    login,
    resolve_model,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def _from_env_file(name: str) -> str | None:
    """Read a key out of ``.env.live`` / ``.env`` / ``app/.env`` (``KEY=value``
    lines), so a live run needs no exports: the credentials live in one
    gitignored file and never appear on a command line or in shell history."""
    for candidate in (
        REPO_ROOT / ".env.live",
        REPO_ROOT / ".env",
        REPO_ROOT / "app" / ".env",
    ):
        if not candidate.exists():
            continue
        for line in candidate.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name:
                return value.strip().strip('"').strip("'")
    return None


def _setting(name: str) -> str | None:
    return os.environ.get(name) or _from_env_file(name)


# The desktop app's SharedPreferences file. supabase_flutter persists the signed
# in session there under `flutter.sb-<project-ref>-auth-token`.
APP_PREFS = Path.home() / ".local/share/dev.chuk.cowork/shared_preferences.json"


def _tokens_from_app_storage() -> tuple[str, str] | None:
    """Read the access + refresh token out of the running app's own session.

    This is the same session the app hands the host when it provisions the
    executor. No password is ever entered here, and nothing is copied out of the
    file — the tokens go straight into the client and are never printed.
    """
    if not APP_PREFS.exists():
        return None
    try:
        prefs = json.loads(APP_PREFS.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None
    for key, value in prefs.items():
        if not key.endswith("-auth-token") or not isinstance(value, str):
            continue
        try:
            session = json.loads(value)
        except ValueError:
            continue
        access = session.get("access_token")
        refresh = session.get("refresh_token")
        if isinstance(access, str) and isinstance(refresh, str) and access and refresh:
            return access, refresh
    return None


def _session() -> SupabaseSession:
    supabase_url = _setting("SUPABASE_URL")
    anon_key = _setting("SUPABASE_ANON_KEY")
    if not supabase_url or not anon_key:
        pytest.skip("no SUPABASE_URL / SUPABASE_ANON_KEY")

    # Preferred: reuse the session the user already signed in with in the app.
    from_app = _tokens_from_app_storage()
    if from_app is not None:
        access, refresh = from_app
        return SupabaseSession(
            access_token=access,
            refresh_token=refresh,
            supabase_url=supabase_url,
            anon_key=anon_key,
        )

    access = _setting("COWORK_LIVE_ACCESS_TOKEN")
    refresh = _setting("COWORK_LIVE_REFRESH_TOKEN")
    if access and refresh:
        return SupabaseSession(
            access_token=access,
            refresh_token=refresh,
            supabase_url=supabase_url,
            anon_key=anon_key,
        )

    email = _setting("COWORK_LIVE_EMAIL")
    password = _setting("COWORK_LIVE_PASSWORD")
    if email and password:
        # One-time bootstrap: the password is traded for a token here and never
        # stored, logged, or sent anywhere but Supabase GoTrue.
        return login(email, password, supabase_url=supabase_url, anon_key=anon_key)

    pytest.skip(
        "put COWORK_LIVE_ACCESS_TOKEN+COWORK_LIVE_REFRESH_TOKEN or "
        "COWORK_LIVE_EMAIL+COWORK_LIVE_PASSWORD in .env.live to run the live test"
    )


@pytest.mark.live
def test_the_real_model_writes_a_file_instead_of_printing_it(tmp_path, monkeypatch):
    session = _session()
    model_id = _setting("COWORK_LIVE_MODEL")
    resolved = resolve_model(fetch_models_info(session), preferred_model_id=model_id)
    print(f"\n[live] model={resolved.model_id} provider={resolved.provider_slug}")

    monkeypatch.chdir(tmp_path)
    client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=1024,
    )
    loop = build_runtime(
        client,
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        max_iterations=6,
        workspace=str(tmp_path),
    )

    result = loop.run(
        "live-1",
        "Write a small Python test script named test_demo.py in the workspace. "
        "It must print 'cowork ok'. Then run it and report the output.",
    )
    print(f"[live] stop={result.reason.value} iterations={result.iterations}")
    print(f"[live] answer:\n{result.final_answer}")
    print(f"[live] files: {sorted(p.name for p in tmp_path.iterdir())}")
    client.close()

    written = list(tmp_path.glob("*.py"))
    assert written, (
        "the model produced no file — it printed the script instead of calling "
        f"write_file. Answer was:\n{result.final_answer}"
    )
    assert "cowork ok" in written[0].read_text()
