"""Live proof, no UI: the executor streams the model's THINKING as `reasoning`
frames before the answer, one `tool` frame per native tool call with
arguments/status/clocks, and a `done` stamped with the run's clock and rows
(docs/WIRE_CONTRACT.md: `reasoning`, "Tool events and timestamps"). Beads
cowork-0ia, cowork-b45, cowork-al2. Not a test — a probe against the real
backend (api.chuk.chat); it costs cents.

    cd executor && uv run python tests/live_reasoning_probe.py

Env (all optional): AGENTS_LIVE_MODEL, AGENTS_LIVE_PROVIDER,
AGENTS_LIVE_REASONING (default "medium"). The account session comes from the
running app's own storage (see agent/tests/test_live_model._session).

Token rotation guard (same as live_native_probe): the app's refresh token is
single-use, so this probe NEVER refreshes — it only runs when the access token
has more than 15 minutes left, and gives up otherwise.
"""

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # wiring
sys.path.insert(0, str(HERE.parent.parent / "agent" / "tests"))  # live helpers

from live_native_probe import (  # noqa: E402
    MIN_TOKEN_HEADROOM,
    _forbid_refresh,
    _token_headroom,
)
from test_live_model import _session, _setting  # noqa: E402

from chuk_agents_runtime import BackendModelClient, fetch_models_info, resolve_model  # noqa: E402
from chuk_agents_sandbox import LocalEnvironment  # noqa: E402

from chuk_agents_executor import ControllerSession, Executor, loopback_pair  # noqa: E402

from wiring import paired_channel  # noqa: E402

PROMPT = (
    "Think it through first. Then create a file named probe.txt containing the "
    "single word hello: call the run_command tool with the command "
    "\"echo hello > probe.txt\". After the tool result, reply with exactly one "
    "word: done."
)


def _short(text: str, n: int = 160) -> str:
    text = text.replace("\n", "\\n")
    return text if len(text) <= n else text[:n] + "…"


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
    wanted = _setting("AGENTS_LIVE_MODEL") or "z-ai/glm-5.3-flash"
    if wanted not in {m.get("id") for m in models}:
        print(f"model {wanted!r} is not in /v1/models_info — falling back to the default")
        wanted = None
    resolved = resolve_model(
        models,
        preferred_model_id=wanted,
        preferred_provider=_setting("AGENTS_LIVE_PROVIDER"),
    )
    effort = _setting("AGENTS_LIVE_REASONING") or "medium"
    print(f"model    : {resolved.model_id}")
    print(f"provider : {resolved.provider_slug}")
    print(f"reasoning: {effort}")

    def model_factory() -> BackendModelClient:
        return BackendModelClient(
            session,
            model_id=resolved.model_id,
            provider_slug=resolved.provider_slug,
            max_tokens=1024,
            reasoning_effort=effort,
        )

    with tempfile.TemporaryDirectory(prefix="agents-reasoning-probe-") as tmp:
        workspace = Path(tmp) / "ws"
        workspace.mkdir()
        channel = paired_channel()
        controller_ep, executor_ep = loopback_pair()
        executor = Executor(
            name="reasoning-probe",
            endpoint=executor_ep,
            opener=channel.executor.opener,
            sealer=channel.executor.sealer,
            environment=LocalEnvironment(workdir=str(workspace)),
            db_path=str(Path(tmp) / "state.db"),
            model_factory=model_factory,
            max_iterations=6,
        )
        controller = ControllerSession(
            endpoint=controller_ep,
            sealer=channel.controller.sealer,
            opener=channel.controller.opener,
        )
        started = time.monotonic()
        executor.start()
        try:
            rid = controller.send_task(PROMPT, session_key="probe")
            events = controller.collect(rid, timeout=180.0)
        finally:
            executor.stop()
        elapsed = time.monotonic() - started
        file_ok = (workspace / "probe.txt").exists()

    kinds = [e["type"] for e in events]
    print(f"\n--- {len(events)} frames in {elapsed:.1f}s ---")
    print("sequence:", " ".join(kinds))

    reasoning = [e for e in events if e["type"] == "reasoning"]
    deltas = [e for e in events if e["type"] == "delta"]
    tools = [e for e in events if e["type"] == "tool"]
    done = events[-1] if events else {}

    first_reasoning = kinds.index("reasoning") if "reasoning" in kinds else None
    first_delta = kinds.index("delta") if "delta" in kinds else None
    print(f"reasoning frames: {len(reasoning)}  chars: {sum(len(e['text']) for e in reasoning)}")
    if reasoning:
        print("  first :", repr(_short(reasoning[0]["text"])))
        print("  joined:", repr(_short("".join(e["text"] for e in reasoning), 400)))
    print(f"delta frames    : {len(deltas)}  text: {_short(''.join(e['text'] for e in deltas))!r}")
    for t in tools:
        print(
            "tool frame      :",
            json.dumps(
                {k: t.get(k) for k in ("name", "arguments", "command", "status", "exit_code",
                                       "started_at", "completed_at", "duration_ms", "replay")},
                default=str,
            ),
        )
    print(
        "done            :",
        json.dumps({k: done.get(k) for k in ("type", "reason", "started_at", "finished_at",
                                             "first_mid", "last_mid", "run_id", "iterations")}),
    )
    print(f"probe.txt written: {file_ok}")

    checks = {
        "a reasoning frame arrived": bool(reasoning),
        "reasoning came before the first delta": (
            first_reasoning is not None and (first_delta is None or first_reasoning < first_delta)
        ),
        # The thinking is its own channel: the joined reasoning is not what the
        # answer text says (a chunk may coincide with a word of the answer).
        "reasoning is not folded into the delta text": bool(reasoning)
        and "".join(e["text"] for e in reasoning).strip()
        != "".join(d["text"] for d in deltas).strip(),
        # One frame per native call. The model may end with a `finish` call as
        # well; the first call is the shell command we asked for.
        "one tool frame per native call, run_command first": bool(tools)
        and tools[0]["name"] == "run_command"
        and all(t["name"] in ("run_command", "finish") for t in tools),
        "tool frame has arguments/status/clocks": bool(tools) and all(
            isinstance(t.get("arguments"), dict)
            and t.get("status") in ("completed", "error")
            and t.get("started_at") is not None
            and t.get("completed_at") is not None
            and t["started_at"] <= t["completed_at"]
            for t in tools
        ),
        "tool command is the plain command line": bool(tools) and tools[0].get("command") == tools[0]["arguments"].get("command"),
        "done is stamped (started_at/finished_at/first_mid/last_mid)": done.get("type") == "done"
        and all(done.get(k) is not None for k in ("started_at", "finished_at", "first_mid", "last_mid"))
        and done["started_at"] <= done["finished_at"]
        and done["first_mid"] < done["last_mid"],
        "the command really ran": file_ok,
    }
    print("\n--- checks ---")
    for label, ok in checks.items():
        print(("PASS " if ok else "FAIL ") + label)
    verdict = all(checks.values())
    print("\nVERDICT:", "REASONING + TOOL FRAMES + DONE STAMPS LIVE" if verdict else "see FAIL lines")
    return 0 if verdict else 2


if __name__ == "__main__":
    raise SystemExit(main())
