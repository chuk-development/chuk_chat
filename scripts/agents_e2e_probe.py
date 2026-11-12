"""End-to-end probe of one Agents run, outside the app (CHAT-88).

A real Executor (the host's code), the account's real model route through
api.chuk.chat, a loopback controller. Its own state dir and workdir. The
account session is used WITHOUT a refresh token, so nothing can rotate the
owner's login. Prints only frame types, tool names, statuses and the answer.

  agents/host/.venv/bin/python scripts/agents_e2e_probe.py "<prompt>" [--fastmail]
"""
import base64, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "agents/executor/tests"))
from wiring import paired_channel  # noqa: E402

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.backend import make_backend_model_select
from chuk_agents_executor.protocol import task_payload
from chuk_agents_runtime.backend import SupabaseSession, fetch_models_info
from chuk_agents_sandbox import LocalEnvironment

ROOT = Path.home() / ".local/share/chuk-agents"
HERE = Path(__file__).resolve().parents[1] / "_scratch" / "agents_e2e_probe"
HERE.mkdir(parents=True, exist_ok=True)

def account():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "agents/host/src"))
    from chuk_agents_host.account_store import AccountStore
    t = AccountStore(ROOT / "account.json").token() or {}
    assert t.get("expires_at", 0) > time.time() + 120, "account token too old"
    return SupabaseSession(
        access_token=t["access_token"], refresh_token="",  # never refresh
        supabase_url=t["supabase_url"], anon_key=t["anon_key"],
        expires_at=float(t["expires_at"]),
    )

def fastmail_entry():
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from chuk_agents_host.secrets_key import mcp_grants_at_rest_key
    from chuk_agents_host import host as _h
    ident = _h.load_or_create_identity(ROOT / "host_device.key")
    rec = json.loads((ROOT / "mcp-grants.json").read_text())
    plain = AESGCM(mcp_grants_at_rest_key(ident)).decrypt(
        base64.b64decode(rec["nonce"]), base64.b64decode(rec["ciphertext"]),
        b"chuk-agents/mcp-grants-at-rest/v1")
    for r in json.loads(plain).values():
        if r.get("name") == "Fastmail":
            return {"id": "fastmail", "name": "Fastmail", "url": r["url"],
                    "oauth": {k: r[k] for k in ("refresh_token", "token_endpoint", "client_id", "resource", "scope") if r.get(k)}}
    return None

def main():
    prompt = sys.argv[1]
    session = account()
    models = fetch_models_info(session)
    select = make_backend_model_select(session, models)
    channel = paired_channel()
    c_ep, e_ep = loopback_pair()
    (HERE / "ws").mkdir(exist_ok=True)
    ex = Executor(name="probe", endpoint=e_ep, opener=channel.executor.opener,
                  sealer=channel.executor.sealer,
                  environment=LocalEnvironment(workdir=str(HERE / "ws")),
                  db_path=str(HERE / "state.db"),
                  model_factory=lambda: select("deepseek/deepseek-v4.1-flash-1017", None, None),
                  model_select=select)
    ctl = ControllerSession(endpoint=c_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    ex.start()
    try:
        payload = task_payload(prompt, "local:Mail:probe:1",
                               model="deepseek/deepseek-v4.1-flash-1017", provider="ionstream/flex")
        if "--fastmail" in sys.argv:
            entry = fastmail_entry()
            payload["mcp_servers"] = [entry] if entry else []
        rid = ctl.send_payload(payload)
        events = ctl.collect(rid, timeout=300.0)
        for ev in events:
            t = ev.get("type")
            if t == "tool":
                res = str(ev.get("result") or "")
                print("TOOL", ev.get("name"), ev.get("status"), "auth_required" if "auth_required" in res else "")
            elif t == "message":
                print("MESSAGE", ev.get("text"))
            elif t in ("done", "run_error", "error"):
                print("TERMINAL", t, ev.get("reason"), "|", (ev.get("final_answer") or ev.get("message") or "")[:400])
    finally:
        ex.stop()

main()
