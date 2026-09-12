# Handover — the browser takeover, the phone chat, and the offline cache

Session of 2026-09-10. Everything below is either fixed and verified on the
Pixel 7 Pro, or filed as a bead with the evidence that made it a bead.

## 1. Why the agent had no browser (bead cowork-3i5c, closed)

`LocalHost` decided a sandbox could browse by looking for the word `browser`
inside `COWORK_SANDBOX_IMAGE`, and `--sandbox` defaulted to `local`. With the
variable unset — the normal case — the gate was always false, so the Playwright
MCP server never started. Every `mcp__playwright__browser_*` call came back
`unknown tool` (see `executor-state.db` messages 736, 791, 797), which the app
showed as "Eine Aktion konnte nicht abgeschlossen werden", and the screen target
stayed dead because `BrowserPresence` waits for the host's `vnc_available`.

Now:

* `cowork_sandbox.docker.image_has_browser()` probes the image for
  `/usr/local/bin/cowork-browser-mcp` — the file, not the tag — once per image.
* `default_image()` takes `cowork-browser:latest` when it is built on the
  machine; `COWORK_SANDBOX_IMAGE` still wins.
* `--sandbox auto` (the new default) takes docker whenever the daemon answers.
* The ready banner carries one `Sandbox:` line naming the backend, the image and
  the browser state. The failure it describes used to be completely silent.
* A model that still reaches for a browser tool that is not there gets an error
  naming `browser_task`, not a bare `unknown tool`.

## 2. The browser dies with the run (bead cowork-rtak, OPEN)

Proven in the container: while an MCP session is alive, Chromium really renders
to `:99` —

```
0x200003 "Example Domain - Google Chrome for Testing" 1288x931+10+10
```

When the session ends, `browser-mcp-owner.py` reaps it. Minutes later the
display holds a single 1x1 window and no chrome process, while the coworker's
answer still says "the browser is open, you can take it over". That is what made
the takeover open a black page.

Two mitigations shipped; the real fix is still open.

* The host asks the display before advertising a screen:
  `Executor._browser_window_present()` runs one `xwininfo` per 3 s and
  `_vnc_available()` requires a browser window. A probe that cannot run at all
  fails OPEN, so an older image is no worse off.
* `BrowserPresence` now follows the BROWSER, not the run: a live `done` no
  longer revokes the screen, only the host does (a `browser_view: closed`, a
  header that stops advertising it, or the transport going away). The target
  used to die one second after the coworker offered it.

`cowork-rtak` is the remaining work: the browser has to OUTLIVE the run, which
means a host-held long-lived Playwright MCP session per agent instead of one
tied to a task. `playwright-mcp` has no idle-timeout flag and `--headless` is
opt-in, so the launcher is already correct — the lifetime is the problem.

## 3. Is the backend working at all?

`cowork-host doctor` answers it, and nothing in it is inferred from a name:
docker is asked whether it answers, the image whether it carries the launcher,
and the launcher is started and made to speak MCP. Each failure prints the
command that fixes it; exit code 0 only when every check passed. `--quick`
skips the container probe.

## 4. The phone chat

* **The same turn twice** (bead cowork-4rpt). The app paints an outgoing
  message when it is sent and the answer as it streams; neither row can carry
  the host's `mid`. The host stores the same turn and replays it above the
  cursor, and `_commit` appended it. `CoworkReplayLoader.appendWithoutRepeats`
  now removes the overlap, host copy wins, with two guards: a 60-row window and
  "a delta may never be shorter than the tail it replaces". A one-time cursor
  drop (`kReplayRepeatRepairKey`) rebuilds caches that already hold duplicates.
* **The block under some messages** (bead cowork-2rda). It was the assistant
  bubble itself with every block filtered out by the phone's quiet toggles. The
  bubble is now decided by the rendered body, and a turn that really did work
  says so in one line instead of standing there blank.
* **The dots that would not go** (bead cowork-i7sd). The typing indicator kept
  rendering under a bubble that was already streaming text.
* **Tables**. Below 560 px a wide table stacks into one card per row with every
  field labelled; the third column used to sit off screen with nothing saying it
  existed. Links in cells are underlined and open — that is where the coworker
  puts its sources.
* **Markdown**. Inline code chips, accent underlined links that keep the
  surrounding size and weight, monotonic heading sizes that follow the chat font
  size, list markers in the bubble colour.
* **Documents**. `agent_markdown.dart` was a second, half-built renderer; it now
  keeps only the `<chart>` splitting it exists for and hands prose to
  `MarkdownMessage`. Measured before: 73 boxes painting past the column edge on
  a markdown document, 743 on a table document.
* **Charts**. The renderer was always there (`ChartRenderer` + `fl_chart`, off
  the `<chart>` block regex in `message_bubble.dart`). The agent simply did not
  know: `skills/builtin/chart-authoring/SKILL.md` is seeded now and `prompt.py`
  points at it.
* **Edit** is gone from the message menu, on request.

## 5. Offline cache

`LocalAgentRosterSource` was deliberately not persisted, so on a cold start the
app did not know which thread to open until the socket paired — the thread key
stayed `default`, which has no cached transcript. The roster is now a
SharedPreferences cache of host truth (`agent_roster_store.dart`); a received
`agent_list` overwrites it wholesale and deleted coworkers stay deleted.
`resolveCacheUserId()` is the ONE helper `loadThread`, `hasThread` and the
replay loader's `_cachedRows` share — they must agree, or the replay splices a
delta onto the wrong base and `saveChat` REPLACES.

A prompt typed while the host is unreachable now waits in
`CoworkTaskOutbox` (SQLite `kv_cache`, one row per thread, verbatim prompt) and
goes out on the next pairing, AFTER the replay. It is deliberately not stored as
a chat-cache row: a full replay replaces that cache, which would delete the
queued message at the exact moment the socket returns.

## 6. Machine note

Five agents running `flutter test` at once took this box to 306 MB free; one
dart `frontend_server` reached 21.8 GB. Run the suite serially, with
`MEMGUARD_ALLOW_MB=24576`.

## 7. Every screen, measured

`app/test/layout/every_screen_layout_test.dart` + `layout_harness.dart`: 37
surfaces x 4 windows (360x800, 412x892, 800x1200, 1400x900) x 2 text scales,
150 tests. Four structural checks that name no widget, so a control added
tomorrow is measured tomorrow: nothing throws or overflows, nothing paints past
the horizontal edges, every target is at least 48 dp, no text under 10 px.

Two things about it are worth keeping:

* It takes `FlutterError.onError` itself rather than `tester.takeException()`.
  The latter hands back only the FIRST error, so a screen overflowing in four
  places reports one and hides three.
* It carries a planted fault — a 900 dp row, a 24 dp target, 6 px text — that
  the sweep must catch. A check that cannot fail proves nothing.

It found ten real faults, among them a 39 px overflow in the profile page's
action row (the "Screen" label was cut off), an account avatar rendered as a
40x58 ellipse because the app bar stretched a `CircleBorder` to the toolbar
height, and the version line that opens developer options being a 20 dp target.

Five surfaces are listed in `_cannotMount` WITH the reason rather than quietly
skipped: `model_selector_page` and `recover_chats_page` reach
`SupabaseService.client` in `initState`; `credit_display` opens a realtime
channel whose timers outlive the tree; `fullscreen_map_page` needs a tile
provider.

## 8. Speed

`app/test/perf/cold_start_perf_test.dart`, and `scripts/perf_phone.sh` for the
numbers that need a device (start time, jank percentiles, PSS).

Time from `pumpWidget` to the first frame holding the cached conversation is
**flat at about 50 ms from 50 to 2000 messages** (58.3 / 52.3 / 53.9 ms), and
the rows land on frame one. The transcript's length does not cost the demo
anything. `loadThread` itself is 1.97 ms at 2000 messages.

Beware: the first mount in a process costs ~850 ms of pure JIT. It made 50
messages read as slower than 2000 until the benchmark warmed up — proven by
reversing the size order and watching the ranking flip. A perf number from a
single Flutter mount is noise.

That benchmark caught a real defect in this session's own duplicate fix
(cowork-6i0m): `appendWithoutRepeats` searched the overlap by trying every
candidate length, which is quadratic in the delta and reaches its worst case on
real data — a thread of repeated identical turns with one different row at the
end. 96.96 ms on the UI thread for a 2000-row replay, on the reconnect path.
Step 1 is a KMP prefix function now, over `delta + separator + the last
min(n,m) cached rows`, with one row-by-row confirmation over the matched length
so a hash collision can never decide what overwrites the thread. 0.22 ms.

## 9. The send that was lost in airplane mode

Found by comparing against the original (`/home/user/git/chuk_chat`, NOT
`chuk.chat`, which is the marketing site). There are two disjoint
send-failure paths and only one of them worked:

* host unreachable, internet up -> `websocket_chat_service.dart` ->
  `CoworkTaskOutbox` -> sent on the next pairing. Fine.
* **device actually offline** -> the imported short-circuit in
  `chat_ui_mobile.dart:2613` fires FIRST and returns before the relay is asked.
  It called `OfflineSendCoordinator.enqueue`, a stub returning `''`. The row was
  persisted with `status: 'pending'`, `queueId: ''` — and never sent.

`OfflineSendCoordinator.enqueue` routes to the outbox now and returns a real id.
`OfflineRetryManager.retryNow()` is real too: paired it flushes, unpaired it
asks for a reconnect, which is what the user means by Retry when the host is
asleep. Per-entry backoff, and the flush STOPS at the first not-due entry rather
than skipping it, so the thread keeps its order. The app-level
`WidgetsBindingObserver` that routes to `AppLifecycleService` was missing
entirely — that is also why the imported chat UI's resume callbacks never fired.

Note the design rule that came out of it: CoWork's question is "is my host
reachable", not "is there internet". chuk_chat probes Cloudflare over HTTP; for
CoWork the answer is the relay's phase. The imported `isOnline` short-circuits
are not a feature to repair, they are one to re-hang on host presence.

Two more things the comparison turned up:

* `docs/CHAT_UI_IMPORT.md` claimed the widget layer was byte-identical to
  upstream. 41 files had diverged, eight of them rendering widgets holding about
  two thousand lines of CoWork work. A re-import would have deleted all of it in
  silence. The doc, the manifest and `scripts/import_chat_ui.sh` all say so now.
* The artifact card (`message_bubble/cards.dart:309`) is a dead end: it renders,
  the tap reaches `artifact_storage_service.dart:54` which returns null, and the
  panel was never imported. A control that does nothing is worse than no
  control.
