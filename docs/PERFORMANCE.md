# Performance

Measured 2026-11-01. Bead `chuk_chat-l4t6`.

The numbers in this file come from two sources. Do not mix them.

- **Phone baseline:** Pixel 7 Pro, profile build, synthetic data, before all
  fixes. It is the reference for what the owner feels. There is no phone
  "after" run: the owner stopped the use of the phone during this work.
- **AVD:** `cowork_x64`, profile build, same scenario, before and after. Use it
  only to compare two AVD runs. Its CPU is the host, so its build times are
  5 to 15 times lower than on the phone.

## How to run it

```bash
scripts/emulator.sh start                  # one headless AVD
scripts/perf_bench.sh --label mine         # all paths, table at the end
scripts/perf_bench.sh --label mine --crawl # every screen, every button
scripts/perf_bench.sh --label a --crawl-agents   # the Agents half
scripts/perf_bench.sh --label mine --census      # frame phases + CPU samples
scripts/perf_bench_table.py _scratch/perf/mine.jsonl
scripts/emulator.sh stop
```

`perf_bench.sh` runs on an emulator only and refuses a physical phone. The
serial comes from `--serial`, then `$ANDROID_SERIAL`, then the running emulator.

What the benchmark is:

- It runs the **real app** (`app.main()`) from `test_driver/perf_bench_main.dart`,
  as its own package `dev.chuk.chat.perf`, next to `dev.chuk.chat`. It never
  touches that package.
- It has a fake offline session and a real SQLite cache with 122 synthetic
  chats (one with 300 messages: tables, code, lists, `:::` blocks, tool calls).
  They live only in that package. The script uninstalls it at the end, so the
  chats go with it. `--keep` keeps it.
- `bench_guard.dart` sends all `dart:io` network traffic to a dead local proxy
  and stops links from opening a browser. The script prints the traffic of the
  package; it must say `none`. **The first runs on 2026-11-01 had no guard**
  and reached the production API over mobile data (about 470 KB in, 76 KB out,
  a fake token, no account data).
- The AVD has no accessibility service, so the bench holds the semantics tree
  open to match the phone. `--no-semantics` turns that off.

Column names in the tables: `b` build, `r` raster, `j16` frames over 16.67 ms
from vsync to raster end, `first` tap to first frame end, `settled` tap to last
frame end, `stall` longest gap of an 8 ms timer on the UI isolate.

## Traps

- **Raster on the AVD means nothing.** It is mostly `SwapBuffers` and changes
  from run to run with the same code (keyboard `j16`: 70, 117, 102). Compare
  build times only.
- **Whole-AVD stalls of 1 to 2.5 s** came up in the runs with heavy host load
  (28 GB of host swap in use, a full test suite next to it). They hit a
  different button in each run, so they say nothing about that button. A hop
  counts only when it repeats. See the ranking below.
- **A count of two routes after rapid taps is not a double push.** The second
  tap can land on the page that has just opened. Look at `to`.
- `settled` is near 670 ms on most hops: that is the ink ripple, not work.
- **AVD memory:** the qemu process grew to 18 GB RSS with `hw.ramSize=4096`.
  14.9 GB of that was the host `[heap]`, 2.3 GB the guest RAM. Idle, frames and
  screenshots do not grow it (measured flat). Disk writes in the guest do (an
  APK install: +1.6 GB and one 2-4 GB `tcmalloc large alloc`), and tcmalloc did
  not give the blocks back. `scripts/emulator.sh` now sets
  `TCMALLOC_AGGRESSIVE_DECOMMIT=t`: after the same installs 4.6 GB instead of
  10.9 GB, peak 8.9 GB for a few seconds. `perf_bench.sh` logs the RSS to
  `_scratch/perf/<label>.rss` and stops after 30 s over 8 GB.
- `adb emu kill` can leave `*.lock` files in the AVD folder, and the next start
  then fails with "A snapshot operation is pending". With no qemu running, they
  are safe to delete. A snapshot saved by a windowed start hung the headless
  one on `offline`, so `emulator.sh` now uses `-no-snapshot`.
- Never `flutter run/drive` next to the owner's app: on an install failure the
  tool uninstalls the old package.

## Phone baseline (reference, before all fixes)

Pixel 7 Pro, 60 Hz. Accessibility services on: Sprecho, Bitwarden. Times in ms.

| Path | frames | wall | b50 | b90 | b99 | b max | r50 | r90 | r99 | r max | j16 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| keyboard open, empty chat (8x) | 164 | 661 | 3.3 | 15.0 | 20.8 | 22.9 | 7.5 | 10.5 | 21.6 | 24.6 | 46 |
| keyboard close, empty chat (8x) | 113 | 488 | 5.3 | 17.7 | 26.4 | 26.4 | 8.4 | 15.7 | 38.6 | 44.2 | 89 |
| typing, empty chat (40 keys) | 31 | 55 | 24.3 | 28.3 | 36.1 | 36.1 | 14.7 | 16.1 | 18.2 | 18.2 | 31 |
| open long chat | 16 | 2167 | 4.3 | 73.8 | 721 | 721 | 11.9 | 99.1 | 150 | 150 | 12 |
| keyboard open, long chat (8x) | 150 | 683 | 2.7 | 20.4 | 30.9 | 33.6 | 8.5 | 16.4 | 34.3 | 43.3 | 58 |
| keyboard close, long chat (8x) | 100 | 520 | 6.9 | 23.4 | 28.8 | 29.2 | 8.2 | 11.1 | 17.5 | 20.9 | 79 |
| typing, long chat (40 keys) | 32 | 57 | 24.3 | 29.0 | 42.8 | 42.8 | 15.7 | 17.5 | 21.2 | 21.2 | 31 |
| scroll up, long chat | 181 | 3413 | 1.2 | 2.7 | 16.9 | 17.3 | 5.2 | 8.3 | 19.5 | 21.5 | 11 |
| sidebar open (5x) | 45 | 491 | 1.6 | 3.2 | 14.9 | 14.9 | 8.9 | 27.6 | 35.2 | 35.2 | 20 |
| send, long chat | 1 | 327 | 7.9 | | | | 7.4 | | | | 0 |
| stream answer, long chat | 107 | 48254 | 4.3 | 6.7 | 18.3 | 33.9 | 11.0 | 12.7 | 26.6 | 27.3 | 87 |
| cold start | | 1557 `am TotalTime`, 1746 to the shell | | | | | | | | | |

The "chat switch" row of that run (12 s) was a bench error: the gesture did not
open the sidebar and the run waited for its 10 s limit. It is not an app number.

Frame anatomy on the phone, per frame, from the timeline:

| Phase | keyboard, long chat | one keystroke frame |
|---|---:|---:|
| BUILD | 3.1 | 5.0 |
| LAYOUT | 0.6 | 2.5 |
| PAINT | 1.7 | 6.2 |
| SEMANTICS | 1.7 | 4.3 |
| COMPOSITING | 0.3 | 2.0 |
| raster flush (`flushAndSubmit`) | 6.2 | 6.6 |

Each keystroke made two frames. **The phone's 24 ms per keystroke does not show
on the AVD** (1.3 ms, also with semantics on and off), so its cause is not
proven. The phone's big finding stays: with any accessibility service on,
Flutter keeps the semantics tree alive and pays for it every frame. Native apps
do not, and that fits "it is the app, not the phone". Impeller is off in the
manifest since 2026-01-24 ("better compatibility"), so the phone rasters with
Skia and compiles shaders at run time (`driver_compile_shader` in the sidebar
frames). Flutter marks that opt-out as deprecated.

## AVD before and after

Renderer: `Android Emulator OpenGL ES Translator (NVIDIA GeForce RTX 3060)`,
GLES 3.1 on host GPU 610.57, `-gpu host`, KVM usable, 4 vCPU, 60 Hz, 1440x3120,
`qemu-system-x86_64-headless -no-window`. Semantics held on. Build times in ms.

| Path | before b max | after b max | before wall | after wall |
|---|---:|---:|---:|---:|
| **open long chat** | **423.5** | **20.2 / 23.9** | 1552 | 969 / 1485 |
| chat switch short and long (sidebar callback) | not measurable | 20.1 | | 119 |
| jump button from the top of the list | | 6.7 | | 235 |
| keyboard open, long chat | 8.9 | 11.6 | 598 | 615 |
| keyboard close, long chat | 11.5 | 11.3 | 378 | 376 |
| typing, long chat | 5.8 | 3.5 | 18.3 | 18.2 |
| scroll up slow, 200 frames | 3.1 | 6.8 | 3345 | 3342 |
| scroll up fast, 200 frames | 4.3 | 4.3 | 3349 | 3349 |
| fling up (5x) | 5.2 | 4.5 | 1931 | 1929 |
| fling down (5x) | 5.5 | 4.1 | 1931 | 1936 |
| sidebar open (5x) | 0.6 | 0.6 | 465 | 466 |
| send, long chat | 5.7 | 5.3 | 22 | 33 |
| stream 12 KB answer | 4.3 | 9.8 | 7074 | 7059 |
| stream 12 KB, reader dragging | 14.4 | 10.7 | 7365 | 8672 |
| `jumpTo` top (no UI path, like a scrollbar) | 353 | 366 | | |

Scroll, fling, typing and the stream did not move: those paths were fine on the
AVD before and stay so. Cold start: 1050 before, 1258 to 1346 after, with the
host under load in all "after" runs. No start-up code changed, and the AVD
cannot tell this apart from load. It needs a check on a quiet host.

`jumpTo` to the far end stays slow, because a `SliverList` walks every row on
the way. No control in the app does this today. A draggable scrollbar would.

## Crawl: every screen, every button

`--crawl` taps every reachable target of every screen, then five times in rapid
fire, then tap and back at once, and goes on through each new route. Final run:
320 actions on 29 screens, Agents half 29 more on 6 screens. No error widget,
no red screen. Skipped on purpose: `Logout`.

Screens reached: chat (empty, short, long), sidebar, media manager, settings,
theme, customization, model selector, system prompt, connectors and connector
detail, assistant settings, developer options, about, licenses, account,
pricing, usage, install and pairing, attach and mode menus, rename dialog,
dropdowns, agents inbox and thread, chat documents, agent settings.

Worst hops. A row counts only if it was slow in at least two of three "after"
runs; the value is the median of the three. Times in ms on the AVD, tap-to-frame.

| Rank | Hop | worst frame | runs | settled | before | Why |
|---:|---|---:|---|---:|---:|---|
| 1 | long chat: Retry on the last answer | 308 | 305, 308, 311 | 1574 | 13 | Before, Retry died offline and did nothing, so 13 ms is no base. Now the whole send runs. Not repeated by a direct `resendMessageAt` (17 ms build): cause open. `saveLocal` hashes all messages on the UI isolate |
| 2 | assistant settings: switches | 242 | 172, 242, 429 | 695 | 253 | Each switch asks Android for a permission or role. Lag on return from a system screen |
| 3 | attach menu: Files | 188 | 162, 188, 231 | 325 | 256 | The system file picker opens over the app |
| 4 | assistant settings: Standort | 143 | 142, 143, 331 | 662 | 189 | As rank 2 |
| 5 | settings: Pricing Plans | 119 | 119, 1063, 23 | 2535 | 17 | Not repeatable. Page never settled in 2.5 s offline: spinner |
| 6 | install page: Copy command | 114 | 114, 118, 109 | 684 | 102 | Clipboard call on the platform thread, system popup |
| 7 | install page: Pair with a code | 101 | 70, 102, 101 | 1136 | 85 | First build of the page |
| 8 | composer: new chat | 83 | 83, 89, 78 | 689 | 85 | Screen reset |

Before the fix, rank 0 was **opening a long chat from any button: 416 ms frame,
512 ms stall**. It no longer shows up.

Five pages did not settle within 2.5 s with no network: account, pricing, usage,
model selector, one assistant toggle. They wait on network calls with no
timeout of their own, behind a spinner. The exact length is not measured: the
crawl stops watching at 2.5 s.

## Root causes and fixes

1. **Opening a chat was O(n) in its length.** Only the Agents thread used the
   anchored transcript. The plain chat, the owner's main path, used
   `ListView.builder` and walked to the bottom row by row. All mobile chats now
   use the anchored list (`chat_ui_mobile.dart`). 423 to about 22 ms on the AVD;
   on the phone that frame was 721 ms.
2. **Retry raced itself.** `submitEditedMessage` waits for the artifact rollback,
   so a second tap passed the streaming guard, cut the list, and the first run
   came back with a stale index: `RangeError`, or two sends. It now runs one at
   a time.
3. **Offline errors nobody caught.** `ArtifactStorageService.loadArtifactsForChat`
   (every chat open) and the rollback caught `PostgrestException` only, and
   `http.ClientException` went up as an uncaught error. The rollback error also
   killed Retry. Same for `DeveloperOptionsService._saveRemote`. All handled.
4. **Quadratic teardown.** All implicit animations listen to one `TickerMode`
   notifier and `removeListener` scans it: 49 of 87 frame samples in that open
   frame's teardown. Message rows and sidebar cards now have their own.
5. **The keyboard rebuilt the screen. Only partly fixed.** While the keyboard
   moves, the whole chat half rebuilds, the off-screen sidebar included. Changes:
   `paddingOf` to `viewPaddingOf` in the chrome (`padding.bottom` falls to 0 with
   the keyboard), and the shell reads `MediaQuery.sizeOf` instead of a
   `LayoutBuilder`. `_rebuildWithConstraints` CPU samples for three keyboard
   cycles: 54 to 19 (empty chat), 57 to 34 (long chat). Build time per frame did
   not change in a way the AVD can show (table above), and `SidebarMobile` still
   builds. **The keyboard lag on the phone is not shown to be fixed.**
6. **Composer repaint.** The text field has its own `RepaintBoundary`, so a
   keystroke or a caret blink does not repaint the icons around it.

Not a fix, but tempting: a tap throttle for settings rows. It was removed again.
The "double push" it was for did not exist.

## Open

See the beads filed with `chuk_chat-l4t6`.

- `lib/widgets/markdown_message.dart:358`: `didChangeDependencies` calls
  `_rebuildCache()`, 15 of 117 frame samples in "open long chat". That file had
  another owner during this work, so it stays unchanged.
- All numbers on this page after the fixes need one run on the phone. Keyboard
  and typing above all: the AVD did not show the phone's cost.
- A decision on Impeller, tested on the phone.
