"""Live proof of the Hindsight memory backend (bead chuk_chat-381g).

    cd agents/runtime && uv run python tests/live_memory_hindsight.py [--state-home DIR] [--strace]

What it proves, end to end on this machine:

1. The host-level service starts the real sidecar (``agents/memory``: pg0 +
   Hindsight) once, under a throwaway state home, and the memory gateway
   answers it on loopback.
2. Task 1 states a fact. The turn observer retains it — Hindsight extracts the
   fact with the real memory model (``api.chuk.chat/v1/chat/completions``) and
   embeds it with the real proxy route (``qwen3-embedding-8b`` @ 1024), both
   through the gateway with the live account token.
3. Task 2, a new thread, gets the fact back in its task-start recall, with no
   tool call by the model.
4. A COPY of an old Mem0 Qdrant store is imported once and renamed to
   ``qdrant.migrated-<date>``. The probe never touches a real agent workspace.

The driving model is a scripted mock (its replies are not what is tested). The
memory model and the embedder are real and spend a few credits.

The account session is read, never refreshed: from the running Chuk app's
own session file (``~/.local/share/dev.chuk.chat/shared_preferences.json``),
re-read on every use — the app rotates the tokens, the probe only follows. Or
from ``AGENTS_LIVE_ACCESS_TOKEN`` in ``.env.live`` (then without refresh). No
token is ever printed.

``--strace`` runs the sidecar under ``strace -f`` and lists every outbound
address it connected to (the egress smoke test).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chuk_agents_runtime import AgentLoop, MockModelClient, StateStore, ToolRegistry  # noqa: E402
from chuk_agents_runtime.hindsight_service import (  # noqa: E402
    DEFAULT_SIDECAR_PROJECT,
    configure_memory_service,
    shutdown_memory_service,
    sidecar_command,
)
from chuk_agents_runtime.memory_hindsight import HindsightMemoryStore, drain_retains  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
APP_PREFS = Path.home() / ".local/share/dev.chuk.chat/shared_preferences.json"
FACT_PROMPT = "For this project: the release codename is BLUEFALCON-7. Remember it."
RECALL_PROMPT = "What is the release codename of this project? Answer from memory."
IMPORT_QUERY = "What did the user want to buy from Panther Technology?"


def _jwt_exp(token: str) -> float | None:
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return float(json.loads(base64.urlsafe_b64decode(part)).get("exp"))
    except Exception:  # noqa: BLE001
        return None


class FollowingSession:
    """A session that follows a token source and never spends a refresh token."""

    def __init__(self, read) -> None:
        self._read = read
        self.access_token = read() or ""
        self.refreshes = 0

    def is_expired(self, *, skew: float = 30.0) -> bool:
        exp = _jwt_exp(self.access_token)
        return exp is not None and exp - skew < time.time()

    def refresh(self, *, reason: str = "token_expired", seen_token: str | None = None) -> None:
        self.refreshes += 1
        self.access_token = self._read() or self.access_token


def _app_token() -> str | None:
    try:
        prefs = json.loads(APP_PREFS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for key, value in prefs.items():
        if key.endswith("-auth-token") and isinstance(value, str):
            try:
                return json.loads(value).get("access_token")
            except ValueError:
                continue
    return None


def _env_file_token() -> str | None:
    for candidate in (REPO / ".env.live", REPO / ".env"):
        if candidate.exists():
            for line in candidate.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition("=")
                if key.strip() == "AGENTS_LIVE_ACCESS_TOKEN":
                    return value.strip().strip("\"'")
    return os.environ.get("AGENTS_LIVE_ACCESS_TOKEN")


def _session() -> FollowingSession | None:
    for source in (_env_file_token, _app_token):
        token = source()
        if token and (_jwt_exp(token) or 0) > time.time() + 120:
            return FollowingSession(source)
    return None


class Clonable(MockModelClient):
    """The scripted driver, marked as a real writer so automatic memory is on."""

    def cheap_clone(self):
        return MockModelClient(["{}"])


def _tree_rss_kb(root_pid: int) -> dict:
    """RSS of the sidecar process tree (python + pg0 + postgres backends)."""
    children: dict[int, list[int]] = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as handle:
                ppid = int(handle.read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            continue
        children.setdefault(ppid, []).append(int(entry))
    seen: dict[int, int] = {}
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        try:
            with open(f"/proc/{pid}/status") as handle:
                rss = next((int(line.split()[1]) for line in handle if line.startswith("VmRSS:")), 0)
        except OSError:
            continue
        seen[pid] = rss
        stack.extend(children.get(pid, []))
    return seen


def _proc_name(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[0].decode()[-40:]
    except OSError:
        return "?"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-home", default=str(REPO / "_scratch" / "hindsight-probe"))
    parser.add_argument("--mem0-copy", default=str(REPO / "_scratch" / "mem0-copy" / "qdrant"))
    parser.add_argument("--strace", action="store_true")
    args = parser.parse_args()

    session = _session()
    if session is None:
        print("NO SESSION: sign in to the Chuk app on this machine (its session file is read, "
              "never refreshed), or put a fresh AGENTS_LIVE_ACCESS_TOKEN in .env.live")
        return 2

    state_home = Path(args.state_home)
    if state_home.exists():
        shutil.rmtree(state_home)
    workspace = state_home / "agents" / "probe-agent"
    memory_root = workspace / "memory"
    memory_root.mkdir(parents=True)
    mem0_copy = Path(args.mem0_copy)
    if mem0_copy.is_dir():
        shutil.copytree(mem0_copy, memory_root / "qdrant")
        (memory_root / "qdrant" / ".lock").unlink(missing_ok=True)

    env = dict(os.environ, AGENTS_MEM_BACKEND="hindsight")
    kwargs = {}
    strace_log = state_home / "sidecar.strace"
    if args.strace:
        base = sidecar_command(DEFAULT_SIDECAR_PROJECT)
        kwargs["command"] = [
            "strace", "-f", "-qq", "--seccomp-bpf", "-e", "trace=connect",
            "-o", str(strace_log), *base,
        ]
    service = configure_memory_service(
        state_home=state_home, session_provider=lambda: session, environ=env,
        logger=lambda m: print(m), **kwargs,
    )
    assert service is not None
    t0 = time.monotonic()
    ok = service.wait_ready(300)
    cold = time.monotonic() - t0
    print(f"[service] ready={ok} state={service.state} cold_start={cold:.1f}s "
          f"(sidecar spawn->healthy {service.ready_after}s)")
    if not ok:
        print(f"[service] reason: {service.reason}")
        shutdown_memory_service()
        return 1
    pid = service.status()["pid"]

    store = HindsightMemoryStore(
        memory_root, bank_id="probe-agent", service=service, llm_client=Clonable(["x"])
    )
    state = StateStore(str(state_home / "state.db"))

    def loop(answer: str) -> AgentLoop:
        return AgentLoop(
            Clonable([answer]),
            ToolRegistry(),
            state,
            recall_provider=store.recall_messages,
            turn_observer=lambda record: store.observe_turn(
                record.user_message, record.final_answer,
                tool_names=record.tool_names, wait=True, session_key=record.session_key,
            ),
        )

    t1 = time.monotonic()
    r1 = loop("Noted: the release codename is BLUEFALCON-7.").run("probe-1", FACT_PROMPT)
    retain_s = time.monotonic() - t1
    rows1 = state.get_conversation(r1.session_id)
    print(f"[task1] finished={r1.reason.name} recall rows={sum(m.role == 'memory' for m in rows1)} "
          f"retain(sync)={retain_s:.1f}s")
    listing = store.list(limit=20)
    print(f"[task1] facts in bank: {len(listing.get('results', []))}")

    t2 = time.monotonic()
    r2 = loop("The release codename is BLUEFALCON-7.").run("probe-2", RECALL_PROMPT)
    recall_s = time.monotonic() - t2
    rows2 = state.get_conversation(r2.session_id)
    recall_rows = [m for m in rows2 if m.role == "memory"]
    recalled = "\n".join(m.content.get("content", "") for m in recall_rows)
    print(f"[task2] recall rows={len(recall_rows)} loop={recall_s:.2f}s")
    print(f"[task2] recall carries the fact: {'BLUEFALCON-7' in recalled}")

    timings = []
    for _ in range(3):
        s = time.monotonic()
        store.recall_messages("release codename")
        timings.append(time.monotonic() - s)
    print(f"[recall] warm latency: {', '.join(f'{t * 1000:.0f}ms' for t in timings)}")

    imported = None
    if mem0_copy.is_dir():
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            moved = list(memory_root.glob("qdrant.migrated-*"))
            if moved:
                imported = moved[0]
                break
            time.sleep(3)
        print(f"[import] folder renamed: {imported.name if imported else None}")
        hits = store.search(IMPORT_QUERY, limit=5).get("results", [])
        print(f"[import] recall of an imported fact: {any('panther' in h.lower() for h in hits)} "
              f"({len(hits)} hits)")

    tree = _tree_rss_kb(pid)
    # pg0 daemonizes Postgres, so the postmaster is not in the launcher's tree:
    # add it (and its backends) by its data directory.
    pg_dir = str(service.settings.data_dir / "pg0")
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                argv = Path(f"/proc/{entry}/cmdline").read_bytes().split(b"\0")
            except OSError:
                continue
            if b"-D" in argv and pg_dir.encode() in argv:
                tree.update(_tree_rss_kb(int(entry)))
    total = sum(tree.values())
    pss = 0
    for p in tree:
        try:
            with open(f"/proc/{p}/smaps_rollup") as handle:
                pss += next((int(line.split()[1]) for line in handle if line.startswith("Pss:")), 0)
        except OSError:
            pass
    print(f"[ram] sidecar tree RSS: {total / 1024:.0f} MB, PSS: {pss / 1024:.0f} MB "
          f"over {len(tree)} processes")
    for p, kb in sorted(tree.items(), key=lambda kv: -kv[1])[:6]:
        print(f"        {kb / 1024:7.1f} MB  {_proc_name(p)}")
    print(f"[gateway] {dict(service.status()['gateway'])}  session refreshes={session.refreshes}")

    drain_retains(20)
    shutdown_memory_service()

    if args.strace and strace_log.exists():
        text = strace_log.read_text(errors="replace")
        v4 = re.findall(r'sin_port=htons\((\d+)\), sin_addr=inet_addr\("([^"]+)"\)', text)
        v6 = re.findall(r'sin6_port=htons\((\d+)\).*?inet_pton\(AF_INET6, "([^"]+)"', text)
        unix = sorted(set(re.findall(r'sun_path="([^"]+)"', text)))
        targets = sorted({f"{addr}:{port}" for port, addr in v4 + v6})
        outbound = [t for t in targets if not t.startswith(("127.", "::1", "0.0.0.0"))]
        print(f"[egress] inet connect() targets: {targets}")
        print(f"[egress] non-loopback targets: {outbound or 'none'}")
        print(f"[egress] unix sockets: {unix}")

    checks = {
        "sidecar ready": ok,
        "task 1 stored a fact": bool(listing.get("results")),
        "task 2 recalled the fact": "BLUEFALCON-7" in recalled,
        "exactly one recall row after the prompt": len(recall_rows) == 1
        and [m.role for m in rows2][:2] == ["user", "memory"],
        "no refresh token spent": True,
    }
    if mem0_copy.is_dir():
        checks["mem0 copy imported and renamed"] = imported is not None
    print()
    for name, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
