"""End-to-end probe of one group room (§16.1), outside the app.

The host's own room code (RoomService + RoomAgentPool: one real Executor per
member), the account's real model route through api.chuk.chat, local
sandboxes under _scratch. The account session is used WITHOUT a refresh
token, so nothing can rotate the owner's login. Prints only the emitted room
frames (type, member, a short text).

  agents/host/.venv/bin/python scripts/agents_room_probe.py "<message>" \
      [--live] [--room-id ID] [--name NAME] [--responder everyone|mentions|auto|lead]
      [--lead AGENT_ID] [--bulletin TEXT] AGENT_ID AGENT_ID [...]

--live writes the room and its transcript into the host's own rooms.db and
room-transcript.db (back them up first), so the app lists the group and
replays it. Without it everything stays in memory.
"""
import argparse, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents/host/src"))

from chuk_agents_executor.backend import make_backend_model_select
from chuk_agents_host.account_store import AccountStore
from chuk_agents_host.room_agents import RoomAgentPool
from chuk_agents_host.room_service import RoomService, dispatch_room_frame
from chuk_agents_manager import RoomBinding, RoomStore, RoomTranscriptStore
from chuk_agents_runtime.backend import SupabaseSession, fetch_models_info
from chuk_agents_sandbox import LocalEnvironment

ROOT = Path.home() / ".local/share/chuk-agents"
HERE = Path(__file__).resolve().parents[1] / "_scratch" / "agents_room_probe"
CHEAP = "deepseek/deepseek-v4.1-flash-1017"


def account() -> SupabaseSession:
    t = AccountStore(ROOT / "account.json").token() or {}
    assert t.get("expires_at", 0) > time.time() + 120, "account token too old"
    return SupabaseSession(
        access_token=t["access_token"], refresh_token="",  # never refresh
        supabase_url=t["supabase_url"], anon_key=t["anon_key"],
        expires_at=float(t["expires_at"]),
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("message")
    ap.add_argument("agents", nargs="+")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--room-id", default="room:probe")
    ap.add_argument("--name", default="Probe")
    ap.add_argument("--responder", default=None)
    ap.add_argument("--lead", default=None)
    ap.add_argument("--bulletin", default=None)
    args = ap.parse_args()

    session = account()
    select = make_backend_model_select(session, fetch_models_info(session))
    # Every member on the cheap model, whatever the task names.
    cheap = lambda *_a: select(CHEAP, None, None)  # noqa: E731
    HERE.mkdir(parents=True, exist_ok=True)

    def env(agent_id: str) -> LocalEnvironment:
        ws = HERE / "ws" / agent_id.replace(":", "_")
        ws.mkdir(parents=True, exist_ok=True)
        return LocalEnvironment(workdir=str(ws))

    binding = RoomBinding()
    names = {}
    try:
        import sqlite3
        con = sqlite3.connect(f"file:{ROOT / 'roster.db'}?mode=ro", uri=True)
        names = dict(con.execute("select agent_id, name from coworker_names"))
    except Exception:  # noqa: BLE001
        pass
    pool = RoomAgentPool(
        binding=binding,
        model_wiring=lambda _id: (lambda: select(CHEAP, None, None), cheap),
        environment_factory=env,
        db_dir=HERE / "room-agents",
        system_prompt="You are a helpful agent in a group chat. Keep answers short.",
        agent_name_for=lambda agent_id: names.get(agent_id, agent_id),
    )

    def ask(system: str, user: str) -> str:
        t = time.time()
        text = select(CHEAP, None, "none").complete(
            [{"role": "system", "content": system}, {"role": "user", "content": user}]
        ).text or ""
        print(f"AUTO-PICK {time.time() - t:.2f}s {text[:120]!r}", flush=True)
        return text
    rooms = RoomStore(str(ROOT / "rooms.db") if args.live else ":memory:")
    transcript = RoomTranscriptStore(
        str(ROOT / "room-transcript.db") if args.live else ":memory:"
    )

    def emit(payload: dict) -> None:
        kind = payload.get("type")
        if kind == "room_turn":
            extra = ""
            if payload.get("routed_by"):
                extra = f" [{payload['routed_by']}]"
            if payload.get("kind") == "handoff":
                extra += f" HANDOFF -> @{payload.get('to_handle')}"
            print(f"TURN r{payload['round']} @{payload['handle']}{extra}: "
                  f"{(payload.get('text') or '')[:300]!r}", flush=True)
        elif kind == "room_working":
            print(f"WORKING @{payload['handle']}", flush=True)
        else:
            print("FRAME", {k: v for k, v in payload.items() if k != "turns"}, flush=True)

    service = RoomService(
        room_store=rooms, binding=binding, emit=emit, transcript=transcript,
        members_ready=pool.ensure_room, ask_model=lambda: ask,
        arm_handoff=pool.arm_handoff, name_for=lambda a: names.get(a, a),
        auto_timeout=2.5,
    )
    create = {
        "type": "room_create", "room_id": args.room_id, "name": args.name,
        "members": [
            {"agent_id": a, "handle": (names.get(a) or a).split(":")[-1].lower().replace(" ", "-")}
            for a in args.agents
        ],
    }
    if args.responder:
        create["responder"] = args.responder
    if args.lead:
        create["lead_agent_id"] = args.lead
    if args.bulletin:
        create["bulletin"] = args.bulletin
    print("CREATE", create, flush=True)
    t0 = time.time()
    try:
        dispatch_room_frame(service, create)
        dispatch_room_frame(service, {"type": "room_task", "room_id": args.room_id,
                                      "message": args.message})
        wait = getattr(service, "wait_idle", None)
        if wait is not None:
            wait(timeout=600)
    finally:
        pool.shutdown()
    print(f"ELAPSED {time.time() - t0:.1f}s", flush=True)


main()
