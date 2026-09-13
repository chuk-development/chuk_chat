"""LIVE long-context proof — run directly, not via pytest.

    cd agent && uv run python tests/live_long_context.py

Proves the whole memory story on a REAL model over ONE permanent session:

- One session_key, driven for many rounds (the "one permanent session per bot"
  shape). History is never reset between turns.
- The context budget is deliberately shrunk (``context_length`` small) so the
  context ladder's tier-2/3 aux-model ("hero") summary fires after a couple of
  fat tool outputs, exactly as it would after a week on a real budget — without
  paying for a million real tokens.
- A distinctive fact is stated in round 1, then pushed far out of the verbatim
  tail by unrelated work. At the end the model is asked to recall it. If the
  hero-model summary (and/or mem0 memory) preserved it, the model answers
  correctly — that is the thing that must work.

Not pytest-collected (no ``test_`` prefix) and never runs in CI. It spends a few
cents of the very cheap open-weight model.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_live_model import _session  # reuse the app-session / .env loader

from chuk_agents_runtime import (
    BackendModelClient,
    LocalEnvironment,
    build_runtime,
    fetch_models_info,
    resolve_model,
)
from chuk_agents_runtime.context import LadderConfig

CODENAME = "BLUEFALCON"
LAUNCH = "2026-11-15"


def _hero(client: BackendModelClient) -> BackendModelClient:
    """The cheap 'hero' compactor: the SAME model, reasoning off. Prefer the
    real ``cheap_clone`` if the backend build shipped it; fall back to a plain
    reasoning-off clone so this script runs either way."""
    clone = getattr(client, "cheap_clone", None)
    if callable(clone):
        return clone()
    return BackendModelClient(
        client._session,  # type: ignore[attr-defined]
        model_id=client._model,  # type: ignore[attr-defined]
        provider_slug=client._provider_slug,  # type: ignore[attr-defined]
        max_tokens=512,
        reasoning_effort="low",
    )


def main() -> int:
    session = _session()
    resolved = resolve_model(fetch_models_info(session))
    print(f"[live] model={resolved.model_id} provider={resolved.provider_slug}")

    workspace = Path(__file__).resolve().parents[1] / "_live_ctx_ws"
    workspace.mkdir(exist_ok=True)

    main_client = BackendModelClient(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        max_tokens=1024,
    )
    hero = _hero(main_client)

    # Small budget so compaction fires after a couple of fat tool outputs.
    # ``max_tool_result_tokens`` is deliberately LARGE so tier 1 does not simply
    # truncate the fat outputs away — the middle stays big, forcing the tier-2/3
    # aux ("hero") summary to engage, which is the thing this proof is about.
    cfg = LadderConfig(
        context_length=6_000,
        reserved_output=1_024,
        tier1_threshold=0.30,
        tier2_threshold=0.50,
        tail_budget_fraction=0.25,
        max_tool_result_tokens=50_000,
    )

    db_path = str(workspace / "state.db")
    session_key = "agent:proof"  # ONE permanent session, reused every turn

    # One loop for the whole permanent session: one mem0/embedder load, and the
    # ladder's summary state persists across turns (tier-3 iterative update — the
    # hero model updating its running notes, exactly the design). The budget is
    # shared across every turn, so it is sized for all of them at once.
    loop = build_runtime(
        main_client,
        db_path=db_path,
        environment=LocalEnvironment(),
        workspace=str(workspace),
        max_iterations=40,
        context_config=cfg,
        aux_model=hero,  # <- the hero compactor + mem0 extractor
    )
    ladder = loop.context_ladder

    turns = [
        # Round 1: plant the fact.
        f"Remember this for later: the secret project codename is {CODENAME} and "
        f"its launch date is {LAUNCH}. Just reply 'noted', nothing else.",
        # Rounds of unrelated work that generate big tool outputs, pushing the
        # fact out of the verbatim tail and into the compacted summary.
        "Run this shell command and report the last line: python3 -c \"print('\\n'.join(str(i) for i in range(400)))\"",
        "Write a file notes.txt containing the numbers 1 to 200 each on its own line, then read it back and tell me the final number.",
        "Run: python3 -c \"print('lorem ipsum ' * 500)\" and just tell me how many words it printed.",
        "List the files in the workspace and their sizes.",
        # Final: recall across compaction. Answer FROM the compacted context (no
        # tool) — this is the direct proof that the hero summary preserved the
        # fact the verbatim tail no longer holds.
        "What is the secret project codename and its launch date that I told you "
        "at the very start? Answer with both, exactly, in plain text. Do not call "
        "any tool.",
    ]

    max_tier = 0
    saved_any = False
    final = ""
    for i, prompt in enumerate(turns, 1):
        result = loop.run(session_key, prompt)
        stats = ladder.last_stats if ladder else None
        if stats is not None:
            max_tier = max(max_tier, stats.tier)
            saved_any = saved_any or stats.saved > 0
            print(
                f"[live] round {i}: stop={result.reason.value} "
                f"tier={stats.tier} pressure={stats.pressure:.2f} "
                f"before={stats.tokens_before} after={stats.tokens_after}"
            )
        final = result.final_answer or ""
        if i == len(turns):
            print(f"[live] FINAL ANSWER:\n{final}\n")

    main_client.close()
    try:
        hero.close()
    except Exception:  # noqa: BLE001
        pass

    if ladder is not None and ladder.summary:
        print(f"[live] HERO SUMMARY (preserved across compaction):\n{ladder.summary}\n")

    ok_codename = CODENAME.lower() in final.lower()
    ok_launch = LAUNCH in final or "november" in final.lower()
    ok_compacted = max_tier >= 2

    print(f"[live] compaction fired (tier>=2): {ok_compacted} (max tier {max_tier})")
    print(f"[live] recalled codename {CODENAME}: {ok_codename}")
    print(f"[live] recalled launch {LAUNCH}: {ok_launch}")

    passed = ok_codename and ok_launch and ok_compacted
    print("[live] RESULT:", "PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
