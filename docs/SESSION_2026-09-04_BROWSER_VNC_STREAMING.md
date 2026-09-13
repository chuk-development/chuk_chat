# Session handoff — Browser-in-the-loop, live VNC view, streaming fix, WebRTC transport foundation

**Date:** 2026-09-04 · **Branch:** `agents` · **Status: NOT finished** — feature built,
tested, and running live locally; two workstreams remain open (see §7). Nothing is
committed yet.

Scope note: the working tree also contains **unrelated** uncommitted work from other
sessions (the here.now connector — `agent/.../herenow.py`, `app/.../herenow/`,
`docs/HERENOW_CONNECTOR.md`, `docs/context-compaction-design.md`, and related test
files). This document covers **only** the work done in this session and does not claim
those.

---

## 1. What this session set out to do

Make the Agents agent able to drive a real browser as part of its tool loop, let the
user watch and control that browser live (for logins), fix response streaming, and lay
the foundation for a peer-to-peer transport. Then actually start backend + frontend so
the user can test end to end.

---

## 2. Delivered and tested

### 2.1 `youtube-transcript` skill + skill seeding — DONE, tested, live-verified
- `skills/youtube-transcript/SKILL.md`: pulls a YouTube transcript with `yt-dlp`
  (subtitles only, no video download) and summarizes. Hardened after CodeRabbit:
  YouTube-only URL validation, isolated temp dir (never deletes workspace files),
  `--no-playlist`, deterministic language selection, rolling-caption dedup. Live test:
  3357-word transcript from a real video, `--no-playlist` confirmed.
- `host/src/chuk_agents_host/seed_skills.py` + wiring in `host.py` (`_load_or_create_agent`):
  copies the repo's `skills/` into each agent workspace on provisioning, non-destructive
  (an agent's own skill of the same name is never overwritten). `AGENTS_SEED_SKILLS`
  overrides the source dir.
- Tests: `host/tests/test_seed_skills.py` (7). **Confirmed live**: the running agent
  `ivory-lynx` was auto-seeded the skill (`seeded skills for ivory-lynx: youtube-transcript`).

### 2.2 Browser in the tool loop (Playwright MCP, headed on Xvfb) — DONE, tested, image built
- `sandbox/docker/Dockerfile.browser`: added Node 22 (NodeSource), Xvfb, x11vnc, socat,
  xdotool, and `@playwright/mcp@0.0.80` (installed globally). `sandbox/docker/Dockerfile`
  base image gained `ffmpeg` + `yt-dlp`.
- `sandbox/docker/browser-mcp.sh` (`/usr/local/bin/agents-browser-mcp`): brings up Xvfb
  on `:99`, then execs the **headed** Playwright MCP against the single installed
  Chromium (`--executable-path`), with a persistent `--user-data-dir` in the workspace so
  a login survives. Fails loudly if Xvfb never comes up.
- Executor injection: `_browser_mcp_entry()` builds a `{command: docker, args: [exec -i
  <container> agents-browser-mcp]}` MCP entry (the runtime is host-side, so the server
  runs INSIDE the container over `docker exec` stdio → its Chromium renders to the
  container's Xvfb, which is the display the user watches). Merged with the UI-forwarded
  connectors in `_run_task`. Gated by a `browser_mcp` flag threaded TaskServer → Executor,
  set in `LocalHost` when `AGENTS_SANDBOX_IMAGE` names the browser image.
- Image built: `agents-browser:latest` (1.37 GB). Smoke-verified in a container: Node
  22.23, Chrome-for-Testing 151, Xvfb/x11vnc/socat/xdotool present, `agents-browser-mcp
  --version` → Xvfb up + MCP `Version 0.0.80`, exit 0.

### 2.3 Live browser view / VNC monitoring — DONE (backend + frontend), tested; live VNC bug fixed
- **Backend (executor):** `_VncBridge` (a `docker exec socat STDIO TCP:127.0.0.1:5900`
  byte pipe) + inbound dispatch for `browser_start` / `browser_stop` / `browser_data`
  (input) + `_vnc_start` / `_vnc_feed` / `_vnc_teardown`, torn down on executor stop.
  Payloads `browser_data_payload` / `browser_view_payload` in `protocol.py`. All frames
  ride the existing sealed channel — no RFB parsing on host or executor; the Flutter side
  speaks RFB. Tests: `executor/tests/test_browser_view.py` (12) — incl. a real `cat`-echo
  byte round-trip (which caught a `read()`-blocks-until-n-bytes streaming stall, fixed
  with `read1`).
- **Frontend (Flutter, built by a fork subagent, then fixed up):** `flutter_rfb ^0.6.2`;
  `AgentsRelayBrowserData` / `AgentsRelayBrowserView` inbound events; `startBrowserView` /
  `stopBrowserView` / `sendBrowserData` outbound; `app/lib/widgets/browser_view_page.dart`
  (an in-app loopback `ServerSocket` that `RemoteFrameBufferWidget` dials, bridged both
  ways to `browser_data` frames — a transparent tunnel, the app parses no RFB, **no
  webview**); an app-bar "Agent's browser" button in `messenger_shell.dart`.
  `flutter analyze` clean; `flutter test` **259 passed, 3 skipped**.
- **Live VNC bug found and fixed:** x11vnc crashed in the container with an MIT-SHM
  `X_ShmAttach BadAccess` (the classic x11vnc-on-Xvfb-in-container failure). Fixed with
  `-noshm` in `sandbox/docker/vnc-up.sh` (which also gained an atomic `flock` around the
  check-then-start). Confirmed live (x11vnc bound 5900), and `agents-browser:latest` was
  **rebuilt** so the fix is baked in.

### 2.4 Response streaming — DONE, tested
- **Root cause:** `StreamingModelClient.complete()` awaited the whole answer, then fired
  `on_delta` **once** with the full text — so the UI showed everything at the end, not
  token-by-token.
- **Fix:** `BackendModelClient` (`agent/backend.py`) gained a settable `on_delta`, fired
  per `content` chunk as it arrives off the wire; `StreamingModelClient` (`executor.py`)
  now hands its callback to the inner client when the inner supports it (real streaming),
  and only falls back to the one-shot emit for non-streaming clients (the mock). Executor
  68 + agent backend/model tests green.

### 2.5 Plan documentation
`docs/AGENTS_AGENT_PLATFORM_PLAN.md` updated: §1.1 product thesis; §9/§9.1 (media/whisper
via our API, browser-use-vs-Playwright-MCP decision, login hand-off over VNC, renderer =
x11vnc + `flutter_rfb`); §10 (client-authenticates-then-pass-token as the primary
credential path); §14.1 (WebRTC P2P data plane — server signaling-only, **zero open
ports**, IPv6, own-TURN fallback, E2E seal stays on top); §20 open questions.

### 2.6 CodeRabbit review — run, real findings fixed
1 critical (WebRTC concurrent-send interleaving → an `asyncio.Lock` per framed message),
+ Dockerfile ENV from ARG, + 5 SKILL hardening items, + 2 shell-script robustness fixes,
+ `session.txt` gitignored. Unrelated findings (in `.beads/`, `.agents/`, other files
pulled in by `--include-untracked`) were left alone.

---

## 3. WebRTC P2P transport — FOUNDATION ONLY (not wired in)
- Decision recorded in §14.1: WebRTC DataChannels, our server is a **signaling
  coordinator only**, **no port forwarding ever** (outbound-only ICE/STUN hole punching;
  a TURN relay is an outbound fallback, ideally the user's own coturn), IPv6 as an
  accelerator, the E2E `agents_frame` seal stays on top of DTLS. No WireGuard/Tailscale
  stack. Libraries: Python `aiortc==1.15.0`, Flutter `flutter_webrtc 1.6.1` (Linux
  DataChannels confirmed OK). aiortc does not trickle → 2-message signaling (offer/answer
  SDP).
- Built + tested: `host/src/chuk_agents_host/webrtc_transport.py` — `WebRTCEndpoint`, a sync
  `send`/`recv(timeout)`/`close` facade over a private asyncio loop thread, with
  length-prefix framing + 16 KiB chunking + `bufferedAmount` backpressure + the send-lock
  fix. `host/tests/test_webrtc_transport.py` (5) — a **real in-process P2P DataChannel**
  exchanging bytes both ways, incl. a 1 MB message chunked and reassembled. `aiortc`
  added to `host/pyproject.toml`.
- **NOT done:** the `HostParty` outer-transport seam refactor to use it; turning
  `LocalRelay` into a signaling coordinator; the Dart `WebRtcRelaySocket` + connector
  behind the existing `RelaySocket` seam; TURN credential minting. **The live system
  still uses the WebSocket relay** — which works fine for local testing.

---

## 4. What is running right now (live, local)
- **Host:** `cowork-host run --sandbox docker` with `AGENTS_SANDBOX_IMAGE=agents-browser:latest`,
  detached (`setsid nohup`), relay on `ws://127.0.0.1:8787`, log at `/tmp/cowork-host.log`.
  App reconnected **codelessly** (the "pair once, forever" path works), model token
  provisioned, ready to serve.
- **Flutter app:** Linux desktop build running via `flutter-hot` (`flutter-hot status` =
  running). Auto-reconnected to the host.
- **Image:** `agents-browser:latest` present, rebuilt with the `-noshm` fix.
- **Pairing:** stored in `~/.agents/paired.json` (app-side pairing in the app's secure
  storage). First task creates a fresh container from the browser image.

Restart from scratch: stop the host (kill the pid on 8787), `docker rm -f` any
`agents-*` containers, then relaunch the host command above; start the app with
`FLUTTER_HOT_EXTRA="" flutter-hot start linux` from `app/`.

---

## 5. Test status (all green)
- Executor: **68 passed** · Host: **98 passed** (incl. WebRTC 5, seed 7) · Agent
  backend/model green · Flutter: **259 passed, 3 skipped**. `ruff` clean on changed
  Python. `flutter analyze` clean (1 pre-existing info in an untouched file). Note: `mypy`
  is **not** a project gate (no `[tool.mypy]` config).

---

## 6. Files changed/added this session (mine only)
Changed: `.gitignore`, `agent/src/chuk_agents_runtime/backend.py`, `executor/src/chuk_agents_executor/{__init__,executor,protocol}.py`,
`host/src/chuk_agents_host/{host,serve}.py`, `host/pyproject.toml` (+`uv.lock`),
`sandbox/docker/{Dockerfile,Dockerfile.browser}`, `docs/AGENTS_AGENT_PLATFORM_PLAN.md`,
`app/lib/pages/messenger_shell.dart`, `app/lib/services/agents/agents_relay_client.dart`,
`app/lib/widgets/agents_thread_view.dart`, `app/pubspec.yaml`, the three app test files.
New: `skills/youtube-transcript/SKILL.md`, `host/src/chuk_agents_host/{seed_skills,webrtc_transport}.py`,
`host/tests/{test_seed_skills,test_webrtc_transport}.py`, `executor/tests/test_browser_view.py`,
`sandbox/docker/{browser-mcp.sh,vnc-up.sh}`, `app/lib/widgets/browser_view_page.dart`.

---

## 7. Open / next steps (we are NOT done)
1. **User live-confirmation still pending:** verify in the running app that (a) responses
   now stream token-by-token and (b) after a browser task, the "Agent's browser" button
   shows the live Chromium and accepts clicks/typing. The fixes are in and unit-tested;
   the end-to-end render in the app is the last check.
2. **Visible/structured logging (debuggability)** — requested, NOT done. The executor
   internals (MCP server start/fail, VNC bridge start/errors, streaming) are not logged
   to a visible place; diagnosis this session was by `docker exec` + `/tmp/cowork-host.log`.
   Add executor logging surfaced to the host stdout.
3. **WebRTC transport rewrite** — the big remaining workstream (§3): wire `WebRTCEndpoint`
   into `HostParty` behind a new outer-transport seam, make `LocalRelay` a signaling
   coordinator, build the Dart `WebRtcRelaySocket` + connector, add TURN cred minting,
   verify real P2P. The foundation and the plan are done.
4. **Nothing is committed.** When the user approves, commit the tested work as
   `chukfinley <77645077+chukfinley@users.noreply.github.com>` — but the tree also holds
   unrelated here.now/compaction changes, so stage this session's files deliberately, not
   `git add -A`.
5. Minor: the app's run summary shows `done · N rounds · <tokens>` — not a bug (turn
   accounting); soften/hide for trivial turns only if the user wants it.

---

## 8. Live VNC debug + fix (follow-up session, bead cowork-9o6)

Symptom the user reported: the VNC session was not being transmitted.

What was actually wrong — two things:

**8.1 The real bug: an x11vnc fd-leak deadlock in `agents-vnc-up`.** The old script did
`exec flock /tmp/agents-vnc.lock "$0"` and later `exec x11vnc … -bg`. `x11vnc -bg`
daemonizes and keeps every inherited fd open, including the flock fd, so the running
x11vnc holds the lock forever. Proven live: after one x11vnc was up, `x11vnc` held
`fd 3 -> /tmp/agents-vnc.lock` with an active lock, and every following `agents-vnc-up`
blocked on `flock`. The executor calls it with `subprocess.run(..., timeout=15)`, so from
the second view-open onward the call hangs, hits the 15 s timeout, and the view reports a
failure / streams nothing. `_vnc_teardown` kills only the socat bridge, not x11vnc
(`-forever`), so the leaked lock survives open/close cycles — every reopen deadlocked.

Fix (`sandbox/docker/vnc-up.sh`, fully rewritten): drop flock entirely. x11vnc already
serialises itself — only one process binds the RFB port — so a lost race just makes the
second x11vnc exit and we re-check with a short `pgrep` wait loop. x11vnc is launched
fully detached (`setsid … </dev/null >>LOG 2>&1`, plus `-o LOG`), so it holds neither the
lock nor the `docker exec` stdout pipe. Verified: 4 consecutive opens return `rc=0` in
<1 s each, no hang; a full RFB 3.8 handshake + a 1280×800 framebuffer streams cleanly
through the exact executor bridge (`docker exec -i <c> socat STDIO TCP:127.0.0.1:5900`).

**8.2 The confusing symptom: a blank display looks like "not transmitting".** The pipe was
proven end to end (server + bridge + RFB all work). But the agent's Chromium launches
lazily (first browser tool call) and is torn down at run end, while Xvfb persists. So
opening the view when no page is open streams an all-black framebuffer — captured live: a
1280×800 frame of pure `0x00`. That reads as "nothing is transmitted".

Fix: `agents-vnc-up` now prints a machine-readable `WINDOWS=<n>` line (count of visible
top-level windows via `xdotool search --onlyvisible`). `Executor._vnc_start` parses it and,
when it is `0`, sends `browser_view("started", message="no page open yet — ask the agent
to open a browser")`. `browser_view_page.dart`'s status banner now shows that message
(amber) instead of the usual green "live — you are in control", so a black screen is never
a silent mystery. The bridge stays live either way: the moment the agent opens a page the
window appears in the same stream.

**8.3 Verification.** Executor: 71 passed · `ruff` clean · `flutter analyze` clean on the
changed widget. Proven live before the fixes: a full RFB 3.8 handshake plus a 1280×800
framebuffer streamed through the exact executor bridge (`docker exec -i <c> socat STDIO
TCP:127.0.0.1:5900`) — first an all-`0x00` frame (blank display), then, after launching a
Chromium on `:99`, a clean render of a test page. So server + bridge + RFB were never the
problem; §8.1 (the deadlock) was.

**8.4 State after this session.** `agents-browser:latest` was rebuilt with the fixed
`vnc-up.sh` baked in (verified: the fix is in the image). The host was restarted so the
`_vnc_start` change is live too (pid changed; new relay on `ws://127.0.0.1:8787`). The old
task container was torn down by that restart — a fresh one spawns from the fixed image on
the next task, so it carries the fix with no hot-patch needed. Note: restarting the host
dropped the app's socket and the app did not auto-reconnect within a few minutes, so after
a host restart the app needs one manual reconnect. Lesson: the §8.1 fix lives in the
container script and needs no host restart; only the §8.2 banner message does — do not
restart a live host just for that.

Files touched: `sandbox/docker/vnc-up.sh`, `executor/src/chuk_agents_executor/executor.py`
(`_vnc_start`), `app/lib/widgets/browser_view_page.dart`. Tracked as bead `cowork-9o6`.

**8.5 Second bug, the one the app actually hit: a dropped `-u <user>` arg (bead
`cowork-yu9`).** After the deadlock fix the app still showed "could not start the VNC
server". Cause: `_vnc_start` built the command as `prefix[:-1] + [cid, "agents-vnc-up"]`.
`prefix` is `[binary, "exec", "-i", "-u", user]` whenever the sandbox resolves a user —
which the docker backend always does (`_resolve_user` sets `uid:gid` or `DEFAULT_USER`).
`prefix[:-1]` was meant to drop the harmless `-i`, but it dropped the **username**
instead, so the command became `docker exec -i -u <cid> agents-vnc-up` → "docker exec
requires at least 2 arguments" → nonzero exit → the "could not start the VNC server"
banner. The socat bridge already used the full `prefix`, so only the vnc-up call was
broken. Fix: use the full `prefix` (`-i` is a no-op on a captured `subprocess.run`).
Verified: the correct `docker exec -i -u agents <cid> agents-vnc-up` returns `WINDOWS=2
rc=0` for both `agents` and `uid:gid` users; executor browser tests 12 passed. This needs
the host restarted to load (executor runs in the host process).

**8.6 Known rough edge (not fixed here): the app does not auto-reconnect after a host
restart.** Twice, restarting the host left the app on a dead socket and its
`_scheduleAutoReconnect` timer did not re-dial within minutes; the user had to reconnect
by hand. Worth chasing separately (the socket-close path may not be reaching the thread
view's reconnect scheduler). Practical rule until then: after any host restart, expect one
manual reconnect in the app.

---

## 9. Native OpenAI tool calls + full platform verification (autonomous session)

Driven under a /loop; tracked as bead epic `cowork-05v` (all children closed except
the reconnect edge `cowork-05v.3`).

### 9.1 Native tool-call migration (bead cowork-05v.12) — DONE, LIVE-VERIFIED
chuk_chat migrated fully to native structured tool calls; api.chuk.chat supports them.
agents was still parsing `<tool_call>` from assistant CONTENT. Migrated agents to native:
- `ToolRegistry.openai_tools()` — OpenAI function JSON (`{type:function,function:{name,
  description,parameters}}`); deferred + unavailable tools filtered; empty schema →
  `{"type":"object","properties":{}}`.
- `BackendModelClient`: `set_tools()` + `payload["tools"]`; native history pass-through —
  assistant `tool_calls` with **arguments as a JSON string**, `role:"tool"` with
  `tool_call_id`, empty `message` after a tool pass — replacing the `<tool_call>` /
  `<tool_result>` text flattening; `_chat_once` parses the `tool_calls` frame with native
  priority and keeps `extract_tool_calls` as the fallback for non-native models.
- `set_tools` forwarded through `StreamingModelClient` (executor) + `_ChildStreamingModel`
  (runtime) + wired in `build_runtime` after deferral.
- Tests: 3 native backend + 2 registry tests + full agent/executor suites green, ruff clean.
- **Live-verified** (`agent/tests/live_native_probe.py`): deepseek-v4-flash returned
  `native:True`, `tool_calls=[run_command{command:'ls -la'}]`, 0 text. Server does native.
- Host restarted + app reconnected → native tool calls live in the running system.

### 9.2 App fixes
- Browser-view crash (unhandled broken-pipe SocketException) + AppBar overflow — fixed in
  `browser_view_page.dart` (guarded socket writes + done.catchError; single-line banner).
- `websocket_connector_io.dart`: added WebSocket `pingInterval` (20s) so a dropped host is
  detected and the app auto-reconnects (was: silent half-open socket). Common network-drop
  case fixed; the host-PROCESS-restart reconnect loop is a deeper race (see cowork-05v.3).
- Chat UI restyled to the chuk_chat look (bead cowork-05v.10): user-bubble tail + accent
  fill + 0.8 width, message grouping, assistant copy button, rounded borderless composer,
  new `app/lib/utils/color_extensions.dart`. analyze clean, 26/26 thread tests pass,
  hot-reloaded live with no errors.

### 9.3 Verification (all green)
- Streaming (05v.8): live, 14 incremental deltas, not one-shot.
- VNC E2E (05v.4): stream out (framebuffer decoded) AND input in ('AGENTS VNC OK' typed via
  RFB into a browser field) through the real docker-exec socat bridge.
- Security (05v.7): chuk_agents_crypto 65 tests (default-deny, GCM, replay, pairing, reconnect
  vectors); host localhost-only; blind sealed relay; no published container ports; x11vnc
  localhost-only. here.now approval (05v.9): 13 tests. Lifecycle (05v.11): verified.
- MCP servers: 16 PASS / 14 auth-required / 2 known-broken. Skills: 1 (youtube-transcript),
  hardened + seeded; improved (env LANGS, JS-runtime note).
- Full sweep: host 98, executor 71, crypto 65, agent full, app 267 pass. (3 pre-existing
  `settings_page_test` failures from another session's settings rework — bead cowork-73z,
  not caused by this work.)

### 9.4 Still open
- `cowork-05v.3`: reconnect after a host **process** restart loops at reconnect-confirm
  (unawaited old-controller dispose races the new reconnect on the reused channel). Needs a
  focused reproduction session; the common network-drop case is handled.

### 9.5 Reconnect after host restart — FIXED (bead cowork-05v.3)
Clean experiment (host log = source of truth): after a host **process** restart the app
did NOT re-dial for 70s (0 controller-joins). Root cause: the event-driven reconnect
(`_onStateChanged` on a `closed` transition → `_scheduleAutoReconnect`) was flaky — a
dropped socket that never surfaced as a clean `closed` transition, or a missed rebuild,
left the app idle on a dead link. Fix (`agents_thread_view.dart`): a reconnect
**watchdog** (`Timer.periodic` 8s) that forces `_scheduleAutoReconnect` whenever the
controller is down (closed/error/null) with a stored pairing and nothing in flight,
resetting the backoff for prompt recovery — recovery no longer depends on one fragile
transition. Together with the WS `pingInterval` (drop detection). Verified live: two
consecutive host restarts, app auto-reconnected in ~10s each, no manual action. analyze
clean; thread + shell tests 39 pass (watchdog cancelled in dispose, FakeAsync-safe).

### 9.6 Final verification sweep
host 98 · executor 71 · crypto 65 · agent full · app 267 (the only 3 failures are the
pre-existing `settings_page_test` from another session's settings rework — bead
cowork-73z, not this work). ruff clean on all changed Python. Epic `cowork-05v` closed.
Live system: host running native tool calls, app connected with all fixes + working
auto-reconnect.

---

## 10. VNC view: fit-to-screen + clipboard leak removed (bead cowork-8k6)

The live browser view rendered (a real NYT page showed), but two defects remained,
found by driving the running app and reading its status banner.

### 10.1 The framebuffer did not scale
`RemoteFrameBufferWidget` (flutter_rfb 0.6.2) renders a `RawImage` at the framebuffer's
native pixel size (1280x800) pinned top-left — no scaling — so on a wide window or a
phone it sat in the corner with a large black margin. Fix (`app/lib/widgets/browser_view_page.dart`):
wrap it in `Center > FittedBox(fit: BoxFit.contain)`. FittedBox lays the child out under
unbounded constraints, so `RawImage` keeps its native size and `SizeTrackingWidget` still
measures that size — which is what the gesture detector maps input against; FittedBox only
scales at paint time and Flutter inverts that transform for hit-testing, so taps stay on
the correct pixel at any scale. The connecting placeholder had to become a definite-size
`SizedBox(1280x800)` — a bare `Center` throws under FittedBox's unbounded constraints.

### 10.2 The red error banner and the clipboard leak
The banner read `invalid argument (string): Contains invalid characters.: 'Fertig: docs/...'`.
Root cause (confirmed by subagents): flutter_rfb runs a 1 Hz clipboard monitor that reads
the local OS clipboard and sends it into the sandbox as an RFB ClientCutText; dart_rfb's
`client_cut_text_message.dart` does `latin1.encode(text)`, which throws on any non-latin1
character (em-dash, typographic quote). The uncaught isolate error surfaces through
`onError` into the app's banner, embedding the offending clipboard string — which made it
look like chat text had entered the pixel stream. It had not; the inbound framebuffer path
is separate and was always clean.

Beyond the crash, the clipboard sync is a genuine cross-boundary leak in both directions:
local clipboard -> sandbox (ClientCutText) and sandbox -> local clipboard (ServerCutText ->
`Clipboard.setData`). For a sealed VNC tunnel no clipboard path should exist. Fix: vendor
flutter_rfb into `app/third_party/flutter_rfb` (a `path:` dependency; dart_rfb stays from
pub, no codegen needed) and strip the clipboard feature both directions — remove
`_monitorClipBoard`, no-op the inbound `clipBoardUpdate` branch in the widget, and
drain-and-discard `serverClipBoardStream` in the isolate (it is a non-broadcast controller
that would otherwise buffer forever). The client now emits strictly RFB derived from the
handshake, the render loop, and user pointer/key input.

### 10.3 Loopback socket hardened
The app bridges `browser_data` to `RemoteFrameBufferWidget` over a loopback `ServerSocket`
(127.0.0.1:0). It accepted every connection with no auth (last-writer-wins), so on a
shared host a stray local process could read the agent's screen or inject RFB bytes.
`_onRfbClient` now accepts exactly one client and `destroy()`s any further connection.

### 10.4 Executor inbound size cap
`_vnc_feed` had no size ceiling (the outbound pump has `MAX_BROWSER_CHUNK` = 512 KiB). A
single RFB client message is tiny, so inbound chunks over that ceiling are now dropped
rather than forwarded into x11vnc. Pinned by `test_vnc_feed_forwards_normal_input_but_drops_oversize`.

### 10.5 Not done on purpose (tracked)
- Enforced RFB-only via a client->server message-type allow-list in the executor (drop
  ClientCutText type 6 / ServerCutText type 3). Would make "only VNC bytes" a structural
  guarantee rather than a client-side property, but turns the opaque pipe into a stateful
  RFB parser in the hot path — deferred as a hardening task. The clipboard removal already
  closes the real leak. Bead filed.
- `_vnc_start` register-after-death race (a dead bridge can show as live). Cosmetic. Bead filed.

### 10.6 Verification
Executor: 13 browser-view tests + full suite 72 passed; ruff clean. `flutter analyze`
clean on the app (`third_party/**` excluded — it carries upstream deprecation infos we do
not own). No dedicated widget test exists for `browser_view_page.dart`; the scaling and
socket changes are verified by analyze + live rebuild.

Load note: the app must be fully rebuilt (`flutter run`) to pick up the vendored path
dependency and the widget change — a hot reload is not enough for a pubspec dependency
change. The executor size cap loads on a host restart (the executor runs in the host
process).

### 10.7 Performance: the view was unusably slow — x11vnc was throttling itself
After the fixes above the view rendered and scaled, but takeover felt laggy. A live probe
(`executor/tests/live_vnc_speed_probe.py`, speaks minimal RFB 3.8 through the exact
`docker exec socat` path, mimicking flutter_rfb's bgra8888 + {raw,copyRect}) turned it into
numbers:

  - A full 1280x800 refresh is 4.10 MB **uncompressed** (dart_rfb decodes only raw +
    copyRect, so there is no compressed encoding to negotiate). base64 inflates it to
    5.46 MB on the sealed channel = 84 JSON frames per full screen.
  - With x11vnc's **defaults** that frame transferred at 3.9 MB/s = **0.9 FPS**. The
    docker-exec pipe itself does ~82 MB/s (measured), so x11vnc — not the pipe, not the
    sealed channel, not the debug build — was the throttle.
  - Cause: x11vnc's default `-defer 30 -wait 20` and no threading. Adding
    `-threads -defer 1 -wait 2` (in `sandbox/docker/vnc-up.sh`) lifted a full refresh to
    ~5-17 FPS (measured 60-209 ms/frame across runs), a 5-18x win, with no client change.
    Incremental idle updates were always tiny (~2.4 KiB, so idle was never the problem).

Applied live (hot-copied the patched script into the running container and restarted its
x11vnc → 16.7 FPS on the live port) and baked into `agents-browser:latest` (rebuilt; the
`COPY vnc-up.sh` layer is near the end so the rebuild is seconds). `-noxdamage` is kept on
purpose (correct full-screen polling on Xvfb; dropping it roughly doubles FPS again but
risks missed damage regions).

The remaining ceiling was the 4 MB uncompressed frame — solved in §10.8.

### 10.8 Tight encoding in the Dart client: 4.1 MB -> ~0.2 MB per frame
The owner's requirement: frames in the tens/hundreds of KB, <= 1 MB/s, ~30 FPS — "noVNC
manages it". noVNC manages it because it decodes compressed RFB encodings; our pure-Dart
client asked for `raw` only. Measured on the real screen (NYT page, photos + text, worst
case) with the probe, one full 1280x800 refresh per encoding:

| encoding | full frame | vs raw | server time | sealed-channel frames |
|---|---|---|---|---|
| raw | 4.10 MB | 1x | 128 ms | 84 |
| hextile | 1.53 MB | 2.7x | 4042 ms | 32 |
| zlib | 1.02 MB | 4x | 134 ms | 21 |
| ZRLE | 0.91 MB | 4.5x | 183 ms | 19 |
| **Tight, JPEG q6** | **0.255 MB** | **16x** | **33 ms** | **6** |

zlib/ZRLE only reach 4x because photos do not zlib-compress; Tight uses JPEG for those and
palette/fill for UI. Quality 5/6/8 = 215/255/390 KB; q6 kept (noVNC's default).

**Implementation** (vendored `app/third_party/dart_rfb`, plus the already-vendored
flutter_rfb, both `path:` deps; dart_rfb's dev_dependencies dropped so no codegen runs):
- `lib/src/protocol/tight_decoder.dart` — `TightDecoder`: control byte (reset bits, sub-
  encoding), fill, JPEG (`package:image`, pure Dart — `dart:ui` codecs are not available in
  a spawned isolate), basic with copy/palette(1-bit MSB-first row-padded, 8-bit)/gradient
  filters, the <12-byte inline rule, the "no-zlib" 0xA/0xE sub-encoding, 4 persistent zlib
  streams. Streams use `RawZLibFilter.inflateFilter()` + `processed(flush: true)`
  (Z_SYNC_FLUSH): the chunked `ZLibDecoder` sink was tested and does NOT return output
  synchronously after `add`, which Tight needs per rectangle. Output is bgra8888 `[B,G,R,FF]`.
- `frame_buffer_update_message.dart` — the rectangle loop intercepts encoding 7, decodes it
  and hands it on as a plain `raw` rectangle, so flutter_rfb needs no new variant and no
  freezed regeneration (the freezed toolchain no longer resolves on this SDK). Any other
  unknown encoding now fails loudly instead of silently desynchronising the stream.
- `encoding_type.dart` — `unsupported` round-trips its numeric id (was -1), `fromId`, Tight
  constants. `remote_frame_buffer_client.dart` — one `TightDecoder` per client (reset on
  connect), SetEncodings = [Tight, copyRect, raw, JPEG-quality 6]. No compression-level
  pseudo-encoding on purpose (level 0 would make libvncserver emit no-zlib rects).

**Tests** — `app/test/vnc/tight_decoder_test.dart` (11): three REAL x11vnc vectors captured
with `live_vnc_speed_probe.py --dump` (raw pixels + Tight bytes of the same region, only
accepted when the screen held still): 4 rects pixel-exact (zlib copy over a persistent
stream, palette with explicit filter), 4 JPEG rects with mean error < 8/255; synthetic
fill, inline-<12, 1-bit palette packing, gradient round-trip, stream reset, truncation.

**Live in the app (end-to-end meter in `browser_view_page.dart`, debug builds, bytes
received off the sealed channel):**
- black display (browser closed between tasks): full frame **0.2 KiB** (16 fill rects).
- NYT front page, photos + text: full frame **~193 KB** (was 4.1 MB), then 7.9 KiB/s while
  the page settled, then **0.1 KiB/s idle**.
- interaction (click in the page, cookie banner dismissed, partial scroll): bursts of
  36–97 KiB/s. Input verified through the same Tight session.
- server side: a full frame in 33 ms => 30 FPS possible; at 1 MB/s that is ~4 full
  photo-page repaints per second, and real interaction only repaints dirty rectangles.
Client log confirms the path: the first update arrived as 16 Tight rectangles and was
rendered; incremental updates are 1-3 small rectangles.

Also fixed while at it: flutter_rfb forwarded taps only — no mouse wheel — so a page could
not be scrolled from the app. Wheel/trackpad scroll now maps to RFB buttons 4/5 (6/7
horizontal) at the pointer position.

Note for the probe: `--quality -1` requests Tight without JPEG (gradient/palette only).

### 10.9 "Only VNC bytes" is now enforced, not trusted (P2) + the start race (P3)
- `_RfbClientFramer` (executor, VNC block) frames every client->server byte the app sends:
  ProtocolVersion, security type (+16-byte VNC-auth response), ClientInit, then typed
  messages with fixed / self-describing lengths. Forwarded: SetPixelFormat(0),
  SetEncodings(2), FramebufferUpdateRequest(3), KeyEvent(4), PointerEvent(5).
  ClientCutText(6) — the only message carrying arbitrary host data — is dropped. Anything
  that is not RFB fails closed: the view is torn down with `browser_view("error")` rather
  than piped into x11vnc. Messages split across sealed chunks are reassembled; a partial
  message may not exceed 1 MiB. Server->client stays opaque on purpose (framing it needs
  the full rectangle decoder; the client already discards ServerCutText). Tests: framer
  unit tests + an end-to-end `_vnc_feed` test (clipboard never reaches the bridge, garbage
  kills the view). Executor suite 83 passed.
- `_vnc_start` race: `_VncBridge(autostart=False)` + `start()` — the bridge is registered
  under the lock BEFORE its pump can fire `on_closed`, and `on_closed` only tears down if
  that bridge is still the registered one. Test simulates an instantly-dying socat and
  asserts the registry is cleared and the app gets `stopped`.
- Both loaded with a host restart (coordinated with the other sessions). Note: stopping
  the host removes the task container (executor `stop()` -> sandbox cleanup), so a page the
  agent had open is gone after a restart; the next task builds a fresh container.
- Probe gotcha for future sessions: `pkill -f '<pattern>'` from a shell whose own command
  line contains the pattern kills that shell. Use `pgrep -f '[c]owork-host'` style patterns.

### 10.10 Review pass (Sonnet; the Opus pass is owed once the Opus quota resets) — fixed
Findings and what changed:
1. HIGH — rect size unbounded: w/h are raw uint16s, a corrupt header could allocate
   ~536 MB (Tight) or park the raw reader waiting for GBs. Fix: every rectangle must fit the
   negotiated framebuffer (`frame_buffer_update_message.dart`, fails the update loudly) and
   `TightDecoder` also caps area at 4 Mpx before allocating. Test: absurd sizes rejected
   with nothing consumed.
2. MEDIUM — TOCTOU: a late `on_closed` from a replaced bridge could tear down its
   successor (check outside the lock, teardown inside). Fix: `_vnc_teardown(expected=)`
   does identity check + clear under one lock acquisition; `on_closed` passes its bridge.
   Test: stale teardown is a no-op, matching one closes.
3. MEDIUM — framer assumed RFB >= 3.7 (client security-selection byte); a 3.3 client
   would desync and be torn down. Fix: version parsed from the client string; 3.3 skips
   the selection phase. Test added. (dart_rfb sends 3.8, so this was dormant.)
4. MEDIUM — JPEG amplification: the JPEG's own SOF size is server-controlled. Fix: header
   dimensions checked via `JpegDecoder().startDecode` BEFORE decoding; mismatch throws.
   Test: a 4x4 JPEG claimed as 64x64 is rejected.
5. LOW — the client still forwarded ServerCutText into a stream nobody read. Fix: dropped at
   the source in `handleIncomingMessages` (consumed off the wire, never surfaced).
6. LOW (upstream, not fixed) — `SizeTrackingWidget` measures once; a mid-session
   framebuffer resize would stale the tap/wheel mapping. Inert at the fixed 1280x800.
7. INFO — `x11vnc -nopw -shared` is reachable only via `docker exec`; acceptable.
Executor suite 88 passed, Tight decoder tests 13 passed, analyze clean.

### 10.11 Opus-5 review pass — 18 findings, 13 fixed, 4 filed, 1 stale-comment
Fixed (with tests where it matters):
- (1 HIGH) zlib bomb: `_inflate` now throws the moment the stream overshoots the rect's
  filtered size, instead of buffering the whole expansion first. Test: 200 KiB bomb on a
  12-byte rect.
- (3 HIGH) copyRect SOURCE coordinates were never bounds-checked and the copy ran outside
  any catch on the UI isolate (RangeError = dead view). Now rejected; and the copy is
  per-row `setRange`, not one 4-byte view per pixel.
- (4 MEDIUM, and very likely why the wheel was "unconfirmed") `SizeTrackingWidget` writes
  the size in a post-frame callback that only lands on the next rebuild; on a still screen
  it stays `Size.zero`, the wheel handler silently dropped every event and the first tap
  divided by zero. Under FittedBox the child lays out at the image's own size, so that is
  now the fallback for both wheel and tap mapping.
- (5 MEDIUM) the global `RawKeyboard` listener forwarded keystrokes typed into anything
  pushed over the view page. Now only while the page's route is current.
- (6 MEDIUM) `SetColorMapEntries` body read was a dropped `Task` (never run) — stream
  desync on any type-1 server message. `.run()`ed.
- (10 MEDIUM) `config.pixelFormat` kept the server's native format while the wire carried
  the negotiated bgra8888; raw rect bodies were sized from the wrong bpp (dormant at depth
  24). Config now records the negotiated format.
- (11 LOW) ServerCutText text was logged at INFO; length only now.
- (12 LOW) RFB 3.3 cannot be framed from the client side (server-chosen auth); the framer
  refuses 3.3 outright (fail closed) instead of guessing. Test updated.
- (13 LOW) `_vnc_feed` reads bridge + framer under one lock acquisition.
- (14 LOW) oversize inbound chunk now tears the view down (fail closed) instead of leaving
  a hole the framer would misreport. Test updated.
- (15 LOW) 1-colour palette rejected; 1-bit path only for exactly 2 colours. Test.
- (16 LOW perf) raw blit is per-row `setRange` instead of per-pixel get/set (~1M calls per
  frame on the UI isolate).
- (17 LOW) `vnc-up.sh` waits for the RFB PORT (`/dev/tcp` probe), not the process; stale
  comment about "dart_rfb only decodes raw" removed.
- (18 LOW) the widget's `ReceivePort` is closed in dispose.
Also added tests: zlib output shorter than expected, area-cap boundary (2048x2047 ok,
2048x2048 rejected).
Filed as beads (design-level, not for a hot path change): (2) x11vnc passwordless inside
the container — VNC auth per view is possible (dart_rfb speaks it, framer allows it) but
the agent already controls that Chromium via Playwright, so decide with the owner;
(7) browser_data send ordering in the relay client (seq taken before awaits; only safe
while AES-GCM is pure Dart); (8) busy-spin socket reads without a deadline (upstream
dart_rfb); (9) `_vnc_start` blocks the serve thread up to 15 s.
Review test-coverage notes accepted as-is: the framer handshake fixture is hand-written
(a captured dart_rfb handshake would pin it), and gradient conformance is a round-trip
against our own formula (no real x11vnc gradient vector — x11vnc/libvncserver never emit
gradient; only TightVNC does).

### 10.12 Per-view VNC secret: the sandbox can no longer watch its own screen
Threat (Opus finding 2): x11vnc ran `-nopw -localhost`; `-localhost` keeps the network
out, not the container — the agent's own bash tool or JS in its Chromium could open
127.0.0.1:5900 and read the framebuffer / inject input while the user logs in.
Fix:
- executor `_vnc_start` generates an 8-char secret per view and runs `agents-vnc-up` as
  ROOT (`docker exec -u root -e AGENTS_VNC_PASSWD=…`); the secret rides to the app only
  inside the sealed `started` frame (`browser_view_payload(password=)`), never logged.
- `vnc-up.sh` writes it to `/run/agents-vnc.pass` (root, 0600 — the `agents` user gets
  "Permission denied", verified) and starts x11vnc with `-passwdfile read:FILE`, which is
  re-read on every client connect, so each view rotates the secret with no x11vnc restart
  (verified: second run rewrites the file, still one x11vnc). A passwordless x11vnc from
  an older start is replaced. Without the env var the script behaves as before.
- verified in a throwaway container: a client is offered security type 2 only.
- app: `AgentsRelayBrowserView.password` (additive), `browser_view_page.dart` builds the
  RFB widget only after `started` (the secret is needed at handshake time) and passes it;
  dart_rfb's VNC-auth (bit-reversed DES key, 16-byte response) was checked and the
  executor framer already admits the security-type-2 response (test).
- root x11vnc attaches to the `agents`-owned Xvfb (no xauth on that display); the socat
  bridge keeps running as `agents` — it only proxies bytes and never needs the secret.
- image rebuilt. Executor VNC tests 22, incl. "vnc-up runs as root with the secret in its
  env and `started` carries it".
- `agents-vnc-up` REFUSES to start without `AGENTS_VNC_PASSWD` (exit 4): the script is on
  the agent's PATH, so otherwise the agent could start its own passwordless x11vnc (this
  session did exactly that by accident from a diagnostic). Only the explicit
  `AGENTS_VNC_ALLOW_NOPW=1`, which the executor never sets, permits `-nopw`. As `agents`
  the script cannot write the root-only password file either.
- Live proof with the REAL client (`app/test/vnc/live_auth_probe.dart`, `dart run`,
  against the real x11vnc from the rebuilt image via an in-container relay published on
  127.0.0.1:59000): with the secret → framebuffer update received; wrong secret →
  "password check failed"; no secret → "Server does not support security type none".
- Also: `browser_start` now runs on its own thread (Opus finding 9): `agents-vnc-up` can
  take seconds and no longer stalls `stop` and every other frame. A generation counter
  (`_vnc_generation`, bumped by start/stop/executor stop) makes a stop or newer start win
  over a start still bringing x11vnc up: the late bridge is closed, never registered, no
  `started`. Dispatcher seam `_handle_browser_kind`. Test simulates the hang.

### 10.13 Outbound frame ordering (Opus finding 7)
`AgentsRelayClient._sendFramePayload` takes its `seq` synchronously inside `seal` but sent
after an await, so two in-flight sends could reach the wire out of order and the opener
(strictly increasing seq) would reject the loser — for `browser_data` a hole in the RFB
stream that the executor framer then reports as not-RFB. All sends are now chained
through one future (`_sendChain`, FIFO, a failure does not poison the chain). A
`@visibleForTesting` `debugBeforeSeal` seam lets the tests delay or fail one send:
slow-first-send keeps wire order; failed send, next one still goes out. Relay client
tests 35/35.

### 10.14 The two P3s (Opus findings 8 and 6)
- Socket reads no longer busy-spin (`dart_rfb` `readSync`): bytes already buffered are
  drained with no delay, a 16-round microtask spin covers "a few µs away", then the wait
  sleeps in 1→5 ms steps so timers and the isolate port keep running (on a phone: CPU and
  battery), and 30 s without progress throws `TimeoutException` instead of hanging the
  read loop forever on a server that announced a length and went silent. Tests: a read
  split over two chunks completes while a 10 ms timer keeps firing (a spin would starve
  it); buffered bytes return without sleeping; a stalled read times out.
- `SizeTrackingWidget` re-measures after every build and notifies only on change, so a
  framebuffer resize no longer stales the tap/wheel mapping. Widget test.
All VNC tests: 21 (17 Tight decoder, 3 socket read, 1 size tracking).

Open: the mouse-wheel path is in the running build but its live confirmation is pending —
XTEST/xdotool input stopped reaching the XWayland window of the rebuilt app (an
environment problem, not an app one; the earlier window accepted the same clicks). A
10-second manual check does it: open "Agent browser", scroll the wheel over the page.
