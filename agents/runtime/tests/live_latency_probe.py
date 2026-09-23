"""Measure real API latency without executing generated tools or changing chats.

Run from agent/: .venv/bin/python tests/live_latency_probe.py
Uses the app's existing token, never refreshes it, and prints only timings,
counts and API usage/provider metadata (no prompts, tokens or tool arguments).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import time
from pathlib import Path

from websockets.sync.client import connect

from chuk_agents_runtime import BackendModelClient, DEFAULT_BASE_URL
from chuk_agents_runtime.connection_pool import BackendConnectionPool
from chuk_agents_runtime.skills import load_skills
from chuk_agents_runtime.prompt import upgrade_research_instructions
from live_native_probe import _forbid_refresh, _token_headroom
from test_live_model import _session


class Trace:
    def __init__(self):
        self.events = []
        self.start = time.perf_counter()

    def mark(self, kind, **data):
        self.events.append({"event": kind, "seconds": round(time.perf_counter() - self.start, 6), **data})

    def connect(self, *args, **kwargs):
        self.mark("connect_start")
        ws = connect(*args, **kwargs)
        self.mark("connected")
        return TracedSocket(ws, self)


class TracedSocket:
    def __init__(self, ws, trace):
        self.ws, self.trace = ws, trace

    def send(self, raw):
        obj = json.loads(raw)
        self.trace.mark("send_" + str(obj.get("type")), bytes=len(raw.encode()))
        self.ws.send(raw)

    def recv(self, **kwargs):
        raw = self.ws.recv(**kwargs)
        obj = json.loads(raw)
        kind = obj.get("kind", obj.get("type", "unknown"))
        data = obj.get("data")
        details = {"keys": sorted(obj)}
        if kind in ("usage", "tps", "meta"):
            details["data"] = data
            # Protocol variants may put diagnostic fields outside data.
            details["diagnostics"] = {k: v for k, v in obj.items() if k in ("usage", "tps", "meta")}
        elif isinstance(data, str):
            details["chars"] = len(data)
        self.trace.mark(str(kind), **details)
        return raw

    def close(self):
        self.ws.close()


TOOLS = [{"type": "function", "function": {
    "name": "run_command", "description": "Run a shell command.",
    "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]},
}}]


def saved_context():
    db = Path.home() / ".agents/executor-state.db"
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as conn:
        sid = conn.execute("select session_id from session_routes where session_key=?", ("host:cowork-host",)).fetchone()
        if sid is None:
            raise RuntimeError("Expected existing host conversation")
        rows = [json.loads(r[0]) for r in conn.execute("select content from messages where session_id=? order by id", sid)]
    rows = [r for r in rows if r.get("role") in ("system", "user", "assistant", "tool")]
    # Reproduce the decision after the latest script-location lookup. No tools
    # are executed by this probe; only model responses are measured.
    cutoff = next((i + 1 for i in range(len(rows) - 1, -1, -1)
                   if rows[i].get("role") == "tool" and "identify_song.py" in str(rows[i].get("content"))
                   and "/workspace/skills/song-id/scripts/identify_song.py" in str(rows[i].get("content"))), None)
    if cutoff is None:
        raise RuntimeError("No script-location result in existing chat")
    library = load_skills(Path.home() / ".agents/agents/ivory-lynx/skills")
    return [{**r, "content": library.upgrade_catalog(upgrade_research_instructions(r["content"]))}
            if r.get("role") == "system" else r for r in rows[:cutoff]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default=DEFAULT_BASE_URL)
    args = parser.parse_args()
    session = _session()
    _forbid_refresh(session)
    headroom = _token_headroom(session.access_token)
    if headroom is None or headroom < 180:
        raise SystemExit("Wait for the app to refresh: fewer than 3 minutes token headroom")
    short = [{"role": "user", "content": "Call run_command with command true. Do not add prose."}]
    long = saved_context()
    trace = Trace()
    pool = BackendConnectionPool()
    try:
        for label, messages in [("short_cold", short), ("short_warm", short),
                                ("saved_context_warm_1", long), ("saved_context_warm_2", long)]:
            trace.events.clear()
            trace.start = time.perf_counter()
            client = BackendModelClient(
                session, model_id="z-ai/glm-5.3-flash", provider_slug="fireworks/serverless",
                reasoning_effort="none", max_tokens=256, temperature=0, connect=trace.connect,
                base_url=args.base_url, connection_pool=pool,
            )
            client.set_tools(TOOLS)
            try:
                result = client.complete(messages)
            finally:
                client.close()
            trace.mark("complete_return")
            print(json.dumps({"case": label, "message_count": len(messages),
                              "context_chars": len(json.dumps(messages)), "events": trace.events,
                              "usage": result.raw.get("usage"), "timing": result.raw.get("timing"), "tool_calls": len(result.tool_calls)}, ensure_ascii=False), flush=True)
    finally:
        pool.close()


if __name__ == "__main__":
    main()
