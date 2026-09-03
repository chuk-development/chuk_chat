# Session handoff — Browser-in-the-loop, live VNC view, streaming fix, WebRTC transport foundation

**Date:** 2026-09-04 · **Branch:** `cowork` · **Status: NOT finished** — feature built,
tested, and running live locally; two workstreams remain open (see §7). Nothing is
committed yet.

Scope note: the working tree also contains **unrelated** uncommitted work from other
sessions (the here.now connector — `agent/.../herenow.py`, `app/.../herenow/`,
`docs/HERENOW_CONNECTOR.md`, `docs/context-compaction-design.md`, and related test
files). This document covers **only** the work done in this session and does not claim
those.

---

## 1. What this session set out to do

Make the CoWork agent able to drive a real browser as part of its tool loop, let the
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
- `host/src/cowork_host/seed_skills.py` + wiring in `host.py` (`_load_or_create_agent`):
  copies the repo's `skills/` into each agent workspace on provisioning, non-destructive
  (an agent's own skill of the same name is never overwritten). `COWORK_SEED_SKILLS`
  overrides the source dir.
- Tests: `host/tests/test_seed_skills.py` (7). **Confirmed live**: the running agent
  `ivory-lynx` was auto-seeded the skill (`seeded skills for ivory-lynx: youtube-transcript`).

### 2.2 Browser in the tool loop (Playwright MCP, headed on Xvfb) — DONE, tested, image built
- `sandbox/docker/Dockerfile.browser`: added Node 22 (NodeSource), Xvfb, x11vnc, socat,
  xdotool, and `@playwright/mcp@0.0.80` (installed globally). `sandbox/docker/Dockerfile`
  base image gained `ffmpeg` + `yt-dlp`.
- `sandbox/docker/browser-mcp.sh` (`/usr/local/bin/cowork-browser-mcp`): brings up Xvfb
  on `:99`, then execs the **headed** Playwright MCP against the single installed
  Chromium (`--executable-path`), with a persistent `--user-data-dir` in the workspace so
  a login survives. Fails loudly if Xvfb never comes up.
- Executor injection: `_browser_mcp_entry()` builds a `{command: docker, args: [exec -i
  <container> cowork-browser-mcp]}` MCP entry (the runtime is host-side, so the server
  runs INSIDE the container over `docker exec` stdio → its Chromium renders to the
  container's Xvfb, which is the display the user watches). Merged with the UI-forwarded
  connectors in `_run_task`. Gated by a `browser_mcp` flag threaded TaskServer → Executor,
  set in `LocalHost` when `COWORK_SANDBOX_IMAGE` names the browser image.
- Image built: `cowork-browser:latest` (1.37 GB). Smoke-verified in a container: Node
  22.23, Chrome-for-Testing 151, Xvfb/x11vnc/socat/xdotool present, `cowork-browser-mcp
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
  `CoworkRelayBrowserData` / `CoworkRelayBrowserView` inbound events; `startBrowserView` /
  `stopBrowserView` / `sendBrowserData` outbound; `app/lib/widgets/browser_view_page.dart`
  (an in-app loopback `ServerSocket` that `RemoteFrameBufferWidget` dials, bridged both
  ways to `browser_data` frames — a transparent tunnel, the app parses no RFB, **no
  webview**); an app-bar "Agent's browser" button in `messenger_shell.dart`.
  `flutter analyze` clean; `flutter test` **259 passed, 3 skipped**.
- **Live VNC bug found and fixed:** x11vnc crashed in the container with an MIT-SHM
  `X_ShmAttach BadAccess` (the classic x11vnc-on-Xvfb-in-container failure). Fixed with
  `-noshm` in `sandbox/docker/vnc-up.sh` (which also gained an atomic `flock` around the
  check-then-start). Confirmed live (x11vnc bound 5900), and `cowork-browser:latest` was
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
`docs/COWORK_AGENT_PLATFORM_PLAN.md` updated: §1.1 product thesis; §9/§9.1 (media/whisper
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
  accelerator, the E2E `cowork_frame` seal stays on top of DTLS. No WireGuard/Tailscale
  stack. Libraries: Python `aiortc==1.15.0`, Flutter `flutter_webrtc 1.6.1` (Linux
  DataChannels confirmed OK). aiortc does not trickle → 2-message signaling (offer/answer
  SDP).
- Built + tested: `host/src/cowork_host/webrtc_transport.py` — `WebRTCEndpoint`, a sync
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
- **Host:** `cowork-host run --sandbox docker` with `COWORK_SANDBOX_IMAGE=cowork-browser:latest`,
  detached (`setsid nohup`), relay on `ws://127.0.0.1:8787`, log at `/tmp/cowork-host.log`.
  App reconnected **codelessly** (the "pair once, forever" path works), model token
  provisioned, ready to serve.
- **Flutter app:** Linux desktop build running via `flutter-hot` (`flutter-hot status` =
  running). Auto-reconnected to the host.
- **Image:** `cowork-browser:latest` present, rebuilt with the `-noshm` fix.
- **Pairing:** stored in `~/.cowork/paired.json` (app-side pairing in the app's secure
  storage). First task creates a fresh container from the browser image.

Restart from scratch: stop the host (kill the pid on 8787), `docker rm -f` any
`cowork-*` containers, then relaunch the host command above; start the app with
`FLUTTER_HOT_EXTRA="" flutter-hot start linux` from `app/`.

---

## 5. Test status (all green)
- Executor: **68 passed** · Host: **98 passed** (incl. WebRTC 5, seed 7) · Agent
  backend/model green · Flutter: **259 passed, 3 skipped**. `ruff` clean on changed
  Python. `flutter analyze` clean (1 pre-existing info in an untouched file). Note: `mypy`
  is **not** a project gate (no `[tool.mypy]` config).

---

## 6. Files changed/added this session (mine only)
Changed: `.gitignore`, `agent/src/cowork_agent/backend.py`, `executor/src/cowork_executor/{__init__,executor,protocol}.py`,
`host/src/cowork_host/{host,serve}.py`, `host/pyproject.toml` (+`uv.lock`),
`sandbox/docker/{Dockerfile,Dockerfile.browser}`, `docs/COWORK_AGENT_PLATFORM_PLAN.md`,
`app/lib/pages/messenger_shell.dart`, `app/lib/services/cowork/cowork_relay_client.dart`,
`app/lib/widgets/cowork_thread_view.dart`, `app/pubspec.yaml`, the three app test files.
New: `skills/youtube-transcript/SKILL.md`, `host/src/cowork_host/{seed_skills,webrtc_transport}.py`,
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

**8.1 The real bug: an x11vnc fd-leak deadlock in `cowork-vnc-up`.** The old script did
`exec flock /tmp/cowork-vnc.lock "$0"` and later `exec x11vnc … -bg`. `x11vnc -bg`
daemonizes and keeps every inherited fd open, including the flock fd, so the running
x11vnc holds the lock forever. Proven live: after one x11vnc was up, `x11vnc` held
`fd 3 -> /tmp/cowork-vnc.lock` with an active lock, and every following `cowork-vnc-up`
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

Fix: `cowork-vnc-up` now prints a machine-readable `WINDOWS=<n>` line (count of visible
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

**8.4 State after this session.** `cowork-browser:latest` was rebuilt with the fixed
`vnc-up.sh` baked in (verified: the fix is in the image). The host was restarted so the
`_vnc_start` change is live too (pid changed; new relay on `ws://127.0.0.1:8787`). The old
task container was torn down by that restart — a fresh one spawns from the fixed image on
the next task, so it carries the fix with no hot-patch needed. Note: restarting the host
dropped the app's socket and the app did not auto-reconnect within a few minutes, so after
a host restart the app needs one manual reconnect. Lesson: the §8.1 fix lives in the
container script and needs no host restart; only the §8.2 banner message does — do not
restart a live host just for that.

Files touched: `sandbox/docker/vnc-up.sh`, `executor/src/cowork_executor/executor.py`
(`_vnc_start`), `app/lib/widgets/browser_view_page.dart`. Tracked as bead `cowork-9o6`.

**8.5 Second bug, the one the app actually hit: a dropped `-u <user>` arg (bead
`cowork-yu9`).** After the deadlock fix the app still showed "could not start the VNC
server". Cause: `_vnc_start` built the command as `prefix[:-1] + [cid, "cowork-vnc-up"]`.
`prefix` is `[binary, "exec", "-i", "-u", user]` whenever the sandbox resolves a user —
which the docker backend always does (`_resolve_user` sets `uid:gid` or `DEFAULT_USER`).
`prefix[:-1]` was meant to drop the harmless `-i`, but it dropped the **username**
instead, so the command became `docker exec -i -u <cid> cowork-vnc-up` → "docker exec
requires at least 2 arguments" → nonzero exit → the "could not start the VNC server"
banner. The socat bridge already used the full `prefix`, so only the vnc-up call was
broken. Fix: use the full `prefix` (`-i` is a no-op on a captured `subprocess.run`).
Verified: the correct `docker exec -i -u cowork <cid> cowork-vnc-up` returns `WINDOWS=2
rc=0` for both `cowork` and `uid:gid` users; executor browser tests 12 passed. This needs
the host restarted to load (executor runs in the host process).

**8.6 Known rough edge (not fixed here): the app does not auto-reconnect after a host
restart.** Twice, restarting the host left the app on a dead socket and its
`_scheduleAutoReconnect` timer did not re-dial within minutes; the user had to reconnect
by hand. Worth chasing separately (the socket-close path may not be reaching the thread
view's reconnect scheduler). Practical rule until then: after any host restart, expect one
manual reconnect in the app.
