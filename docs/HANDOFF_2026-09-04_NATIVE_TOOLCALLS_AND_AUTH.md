# Handoff — native tool calls, live view fixes, and the open auth design

**Date:** 2026-09-04 · **Branch:** `cowork` · **Repo:** `/home/user/git/cowork`
**Status:** the browser/VNC + native-tool-call workstream is DONE and verified; ONE real
design task remains — the client↔server auth/refresh-token flow (bead `cowork-c91`).
Nothing is committed (user has not asked to commit).

This document is written so a fresh agent with a small context can continue fast. Read
§1 (state) and §6 (what to do next) first; §3–§4 are the detail.

---

## 1. What is running right now (live, local)

- **Host:** `cowork-host run --sandbox docker` with `COWORK_SANDBOX_IMAGE=cowork-browser:latest`,
  detached, relay on `ws://127.0.0.1:8787`, log at `/tmp/cowork-host.log`. It runs the
  **native tool-call** agent code. The executor runs IN this host process.
- **Flutter app:** Linux desktop debug build via `flutter-hot`, connected to the host,
  with all the app fixes below (crash, overflow, reconnect watchdog, chat-UI restyle).
- **Sandbox image:** `cowork-browser:latest` — carries the fixed `vnc-up.sh`.

**Check state:**
```bash
ss -ltnp | grep 8787                 # host listening?
pgrep -af build/linux/x64/debug/bundle/cowork   # app alive?
tail -20 /tmp/cowork-host.log        # host log
cd app && flutter-hot logs           # app log (rolling buffer, NO timestamps — beware)
```

**Restart host** (kills the pid on 8787, relaunches; the app auto-reconnects via the
watchdog in ~5–10s and re-provisions a fresh token):
```bash
cd /home/user/git/cowork/host
kill $(ss -ltnp | grep 8787 | grep -oP 'pid=\K[0-9]+' | head -1); sleep 2
COWORK_SANDBOX_IMAGE=cowork-browser:latest COWORK_SANDBOX_KIND=docker \
  setsid nohup /home/user/git/cowork/host/.venv/bin/cowork-host run --sandbox docker \
  >> /tmp/cowork-host.log 2>&1 < /dev/null &
```

**Restart/reload the app** (I started it, so hot-reload/restart is fair game):
```bash
cd /home/user/git/cowork/app
FLUTTER_HOT_EXTRA="" flutter-hot restart   # full re-run; reconnects fresh
FLUTTER_HOT_EXTRA="" flutter-hot reload    # picks up Dart edits
FLUTTER_HOT_EXTRA="" flutter-hot await 8   # wait for the result
```

**Memory:** the machine is RAM-constrained (often ~2–3 GB free; a Blender process and
the Flutter frontend-server eat a lot). Prefix python/pytest with `MEMGUARD_ALLOW_MB=6144`.
Do NOT run heavy flutter builds when free RAM < ~2.5 GB — memguard kills the largest
`CLAUDECODE` process over 6 GB and, under 2 GB free, the largest own process.

---

## 2. Bead tracker (this project uses `bd`)

- **Epic `cowork-05v`** — CLOSED. All children delivered + verified (native tool calls,
  browser-view crash+overflow, chat UI restyle, VNC E2E, streaming, security, here.now,
  lifecycle, skills, MCP sweep, reconnect watchdog).
- Earlier closed: `cowork-9o6` (VNC flock deadlock), `cowork-yu9` (VNC `-u` arg bug).
- **OPEN `cowork-c91`** (P1) — the auth/refresh-token design. **This is the next task.**
- **OPEN `cowork-73z`** (P2) — 3 `settings_page_test` failures from ANOTHER session's
  settings rework. NOT ours; do not touch (unrelated uncommitted work).

Run `bd ready` / `bd show cowork-c91` for details.

---

## 3. What this session did (all verified)

### 3.1 Native OpenAI tool calls — DONE, LIVE-VERIFIED (bead cowork-05v.12)
chuk_chat migrated to native structured tool calls; `api.chuk.chat` supports them. cowork
was still parsing `<tool_call>` out of assistant CONTENT. Migrated:
- `agent/src/cowork_agent/registry.py` → `ToolRegistry.openai_tools()`: OpenAI function
  JSON (`{type:function,function:{name,description,parameters}}`); deferred + unavailable
  tools filtered; empty schema → `{"type":"object","properties":{}}`.
- `agent/src/cowork_agent/backend.py`: `BackendModelClient.set_tools()` + `payload["tools"]`;
  native history pass-through — assistant `tool_calls` with **arguments as a JSON string**,
  `role:"tool"` with `tool_call_id`, empty `message` after a tool pass — replacing the old
  `<tool_call>`/`<tool_result>` text flattening (`_assistant_turn`, `_wire_tool_call`);
  `_chat_once` now parses the `tool_calls` frame (`_native_calls_from_frame`) with native
  priority and keeps `extract_tool_calls` as the fallback for non-native models.
- `set_tools` forwarded through `StreamingModelClient` (executor.py) and
  `_ChildStreamingModel` (runtime.py); wired in `build_runtime` AFTER deferral.
- Tests: 3 native backend tests + 2 registry tests + full agent/executor suites green.
- **Live probe** `agent/tests/live_native_probe.py`: deepseek-v4-flash returned
  `native:True`, `tool_calls=[run_command{command:'ls -la'}]`, 0 text. Re-run it to confirm
  the backend still does native (it uses the app's stored session).

#### Follow-up: the `<tool_call>` text protocol is now GONE (mirrors chuk_chat c3011b3)
Native tool calling is the ONE protocol in the Python runtime. The text fallback was
removed entirely — a turn is a tool-call turn only if the server sent a `tool_calls`
frame; assistant content is prose and is never scanned.
- `model.py`: deleted `_TOOL_CALL_BLOCK`, `_repair_and_load`, `extract_tool_calls`,
  `response_from_content`. New test helper `tool_call_response(*(name, args), text=None,
  housekeeping=False)` builds a native turn (ids `call_0`, `call_1`, …). `MockModelClient`
  treats a scripted `str` as a **bare-text final answer** and never parses it; a
  `ModelResponse` passes through.
- `backend.py`: `_chat_once` fallback branch removed; `extract_tool_calls` import gone.
- `prompt.py`: `TOOL_PROTOCOL` deleted and `build_system_prompt` no longer injects
  `render_tool_docs` — the native `tools[]` array carries the schemas, so a prompt copy
  would be paid for twice and could drift. `render_tool_block` / `render_tool_docs` stay
  (used by `tool_describe` and as the readable view of the offered surface in tests).
- `tool_search.py`: the deferral threshold is now measured on the **native schema JSON**
  (`ToolRegistry.openai_tool(name)`, compact `json.dumps`), not on prompt text. New
  `ToolRegistry.openai_tool(name)` is the single per-tool renderer both the wire and the
  measurement use.
- `context.py` summary preamble → "do not call any tool"; `memory.py` / `skills.py` tag
  scrubs KEPT as defense in depth (comments reworded).
- `__init__.py`: `extract_tool_calls`, `response_from_content`, `TOOL_PROTOCOL` unexported;
  `tool_call_response` exported.
- executor: nothing to remove — `StreamingModelClient` never scrubbed `<tool_call>`.
- Tests: every scripted `<tool_call>` string converted to `tool_call_response(...)`. The
  only remaining literals in the tree are the two injection-scrub tests, where the tag is
  the hostile *input* being neutralized. **agent 678 passed / 3 skipped, executor 74
  passed.**

### 3.2 App fixes
- `app/lib/widgets/browser_view_page.dart` — the live browser view crashed the whole app
  with an **unhandled `SocketException: Broken pipe`** on the loopback bridge. Fixed:
  guarded every `socket.add` (`_safeAdd`/`_teardownBridge`), `done.catchError` on both
  sockets, `.catchError` on `sendBrowserData`/`server.close`. Also fixed a 30px AppBar
  RenderFlex overflow (single-line ellipsis status banner, height 28).
- `app/lib/services/websocket_connector_io.dart` — added WebSocket `pingInterval` (20s) so
  a dead host is detected (was a silent half-open socket).
- `app/lib/widgets/cowork_thread_view.dart` — (a) a **reconnect watchdog** (`Timer.periodic`
  8s) that forces `_scheduleAutoReconnect` whenever the controller is down (closed/error/
  null) with a stored pairing and nothing in flight — the event-driven path alone was
  flaky after a host restart; (b) the chat-UI restyle (see below).
- **Chat UI restyled to chuk_chat's look** (bead cowork-05v.10): user-bubble tail + accent
  fill + 0.8 width, message grouping, assistant copy button, rounded borderless composer;
  new `app/lib/utils/color_extensions.dart`; color alignment in `agent_run_views.dart`.
  `flutter analyze` clean, `cowork_thread_view_test` 26/26, hot-reloaded live with no errors.
- Verified live: two consecutive host restarts → app auto-reconnected in ~10s each.

### 3.3 VNC live view fixes (from the earlier part of the session)
- `sandbox/docker/vnc-up.sh` — REWRITTEN. The old `exec flock … exec x11vnc -bg` leaked the
  flock fd into the daemonized x11vnc, which held the lock forever → every later
  `cowork-vnc-up` deadlocked → the executor's `subprocess.run(timeout=15)` timed out →
  "could not start the VNC server". Fix: dropped flock entirely (x11vnc self-serialises via
  the RFB port bind), launch x11vnc fully detached (`setsid … </dev/null >>LOG 2>&1`); print
  a `WINDOWS=<n>` line (visible-window count) so a blank display reports "no page open yet".
- `executor/src/cowork_executor/executor.py` `_vnc_start` — was slicing the docker exec
  prefix as `prefix[:-1]`, which dropped the `-u <user>` username → `docker exec -i -u <cid>
  cowork-vnc-up` → malformed. Fixed to use the full `prefix`. Also parses `WINDOWS=` and
  sends a "no page open yet" banner message when 0.
- Image rebuilt with the fix. VNC E2E verified by hand: framebuffer streamed out AND
  'COWORK VNC OK' typed into a browser input via RFB (see `_scratch/vnc_input_test.png`).

### 3.4 Skills
`skills/` has one skill, `youtube-transcript`, correctly implemented + hardened, seeded into
each agent workspace by `host/src/cowork_host/seed_skills.py`. Improved this session:
`LANGS` is now env-driven (`YT_LANGS`), retry guidance rewritten, JS-runtime (deno/node)
note added. `host/tests/test_seed_skills.py` 7 pass.

### 3.5 Verification sweep (all green)
`host` 98 · `executor` 71 · `common/cowork_crypto` 65 · `agent` full · `app` 267.
The ONLY app failures are the 3 pre-existing `settings_page_test` (bead cowork-73z, another
session's WIP). `ruff` clean on all changed Python. MCP sweep: 16 PASS / 14 auth-required /
2 known-broken (Cloudflare Dev Platform 410, figma-linux-next refused). Security: crypto
default-deny + GCM + replay + pairing + reconnect vectors green; host binds localhost only;
blind sealed relay; no published container ports; x11vnc localhost-only. Streaming: 14
incremental deltas live. here.now approval: 13 tests. All documented in
`docs/SESSION_2026-09-04_BROWSER_VNC_STREAMING.md` §8–§9.

---

## 4. Problems hit and how they were fixed (quick index)

| Problem | Cause | Fix | File |
|---|---|---|---|
| VNC "could not start the VNC server" (2nd open) | x11vnc inherited the flock fd → permanent lock | dropped flock, detached x11vnc | `sandbox/docker/vnc-up.sh` |
| VNC malformed exec | `prefix[:-1]` dropped `-u <user>` | use full prefix | `executor/.../executor.py` `_vnc_start` |
| Black VNC screen looked broken | no browser window on the display | `WINDOWS=` probe → "no page open yet" banner | vnc-up.sh + executor + browser_view_page.dart |
| App crash on browser view | unhandled broken-pipe SocketException | guard socket writes + `done.catchError` | `browser_view_page.dart` |
| App never auto-reconnected after host restart | dead socket undetected + flaky event path | WS `pingInterval` + reconnect watchdog | `websocket_connector_io.dart`, `cowork_thread_view.dart` |
| Models fumbled tool calls | `<tool_call>` text protocol | native OpenAI tool calls | `backend.py`, `registry.py`, `runtime.py`, `executor.py` |
| **`loop failed: SupabaseAuthError`** (OPEN) | host + client SHARE a rotating refresh token; app rotates it → host's copy dies | UNRESOLVED — see §5 | `host.py` `_make_model_factory`, `backend.py` |

---

## 5. THE OPEN TASK — auth / refresh-token design (bead cowork-c91)

### The bug
An app-driven task fails with `loop failed: SupabaseAuthError`. Not a code bug — a design
flaw. The host builds a `SupabaseSession` from the token the app provisions
(`host/src/cowork_host/host.py:445-450`) and refreshes it independently via GoTrue
(`agent/src/cowork_agent/backend.py:128`). But the app's OWN Supabase client keeps
refreshing its session, and **Supabase rotates the refresh token on each use**, so the app
invalidates the token it gave the host. When the host's access token expires and it
refreshes with the now-rotated token, GoTrue rejects it → `SupabaseAuthError` → the task
loop fails. Verified: a standalone probe with a separate frozen token still authenticates
fine (native tool-call code is NOT the cause); the live host's provisioned token is stale.

Immediate unblock (already applied, and self-healing now): restart the host, or just let
the app's reconnect watchdog re-provision — a reconnect re-runs `provisionAccount` with the
app's CURRENT fresh session. So the system self-heals on reconnect; it only fails a task
whose token died mid-flight.

### Constraint that shapes the design
**The host must work autonomously in the background** — even when the client (phone) is
asleep/offline. So the host needs its OWN durable credential; it cannot depend on the
client being online to hand it a fresh token.

### Why the two naive options fail
- *Client sends its token each time / re-provisions on refresh* — only works while the
  client is online; dies for background work.
- *Client and host share one refresh token* — the current bug (rotation invalidates it).

### Recommended design (agreed direction with the user — CONFIRM which of the two)
Give the host an **independent** credential, minted once at pairing:

1. **Preferred: a durable, per-device, revocable API key.** The backend issues the host a
   long-lived API token at pairing; the host just sends it (no refresh chain, no rotation
   problem); unpairing = revoke the key. Cleanest for a background server.
2. **Alternative: a second, independent Supabase session for the host.** The backend, via
   the service role, mints a NEW session for the same user and returns `{access, refresh}`
   with its OWN rotation chain, independent of the client's. The host refreshes it alone.

Both need a small **backend** endpoint on `api.chuk.chat` (the ONLY part not in this repo),
e.g. `POST /host-session` (authenticated with the client's session) that returns the
host-scoped credential. Ask the user for its exact shape before wiring the client to it.

### What to build in THIS repo once the credential shape is known
- **Client (Flutter):** after login, at pairing, call the backend endpoint once and
  `provisionAccount(...)` the HOST credential (not the client's own session).
  See `app/lib/widgets/cowork_thread_view.dart:424,624` (`provisionAccount`) and
  `app/lib/services/cowork/cowork_relay_client.dart:930` (`provisionAccount` impl).
- **Host (Python):** already holds + refreshes its own session
  (`host.py:_make_model_factory`, `backend.py`). For an API key: skip refresh, send the key.
  For a second session: unchanged — it just needs its OWN token.

### Gotcha for any mid-session re-provision approach
The host provisions ONCE per session (`party.py` `_provisioned` flag; `_handle_frame` routes
later frames to `task_server.submit`). You canNOT peek a later token frame to re-provision
mid-session: frames are sealed and the replay guard forbids opening a frame twice. So a
mid-session token push needs its own frame type/route, OR use the reconnect path (a brief
reconnect re-provisions cleanly — this is what the watchdog already enables). Prefer the
independent-credential design so mid-session re-provision is rarely needed at all.

---

## 6. Prompt for the next agent

> Continue the cowork project at `/home/user/git/cowork` (branch `cowork`). Read
> `docs/HANDOFF_2026-09-04_NATIVE_TOOLCALLS_AND_AUTH.md` first, then `bd ready`.
> The host + Flutter app are running live (see §1 of that handoff; restart commands there).
> Native OpenAI tool calls are done and live-verified; the chat UI, VNC live view, and the
> reconnect watchdog are done. The machine is RAM-constrained — prefix pytest with
> `MEMGUARD_ALLOW_MB=6144` and avoid heavy flutter builds under ~2.5 GB free.
>
> Your task is bead `cowork-c91`: give the Python host its OWN durable credential so it can
> work in the background without sharing (and invalidating) the client's rotating Supabase
> refresh token. The user will tell you whether the backend issues a per-device API key
> (preferred) or a second independent Supabase session, and the exact shape of the
> `POST /host-session`-style endpoint. Then wire the Flutter client to fetch + provision the
> HOST credential at pairing (not the client's own session), and adjust the host to use it.
> Do NOT touch bead cowork-73z (another session's settings_page test WIP). Test with the
> live app + host; use `agent/tests/live_native_probe.py` as an auth smoke test. Ask the
> user for the backend endpoint contract before wiring the client to it.

---

## 7. Files changed this session (not committed)
Python: `agent/src/cowork_agent/{backend,registry,runtime}.py`,
`executor/src/cowork_executor/executor.py`, `sandbox/docker/vnc-up.sh`.
Dart: `app/lib/widgets/{browser_view_page,cowork_thread_view,agent_run_views}.dart`,
`app/lib/services/websocket_connector_io.dart`, `app/lib/utils/color_extensions.dart` (new).
Skill: `skills/youtube-transcript/SKILL.md`.
Tests added: `agent/tests/test_backend.py` (+3), `agent/tests/test_registry.py` (+2),
`agent/tests/live_native_probe.py`, `agent/tests/live_streaming_probe.py`.
Docs: this file + `docs/SESSION_2026-09-04_BROWSER_VNC_STREAMING.md` §8–§9.
