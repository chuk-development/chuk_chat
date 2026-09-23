// Speed tests for the demo the app is sold on (bead cowork-l6no): close the
// app, open it, and the conversation you were in is already on screen.
//
// Everything measured here is measured with a controller that NEVER pairs, so
// nothing on screen can have come from the host. The rows are the ones the last
// run left in the local cache. What is timed is therefore the honest cold-start
// cost: read the row, parse the payload, build the models, lay out and paint
// the first frame that shows the conversation.
//
// The numbers are wall clock on the machine that runs the test, so they are a
// shape, not a phone-accurate figure — the curve over 50/500/2000 rows is the
// point, because a regression in the parse or the paint shows up as a slope.
// Every figure is a median of at least five runs and is printed as a table by
// `debugPrint`. The assertions are deliberately generous ceilings: a perf test
// that fails on a busy machine is noise, but a tenfold regression must still be
// caught.
//
// The store's SQLite is replaced by a map through `AgentsChatStore`'s own cache
// seams — see `perf_support.dart` for why a real sqflite read would hang here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../support/fake_relay_controller.dart';
import 'perf_support.dart';

/// A wall-clock guard on every test in this file. A regression that made one
/// wait on the real event loop from inside the fake-async zone once stalled a
/// whole suite; a failure is always better than silence.
const Timeout _guard = Timeout(Duration(minutes: 5));

/// Runs per measured quantity. Five is the floor the bead asks for; the mount
/// measurements pay for every extra run, so they stay at five.
const int _mountRuns = 5;

/// The micro-benchmarks are cheap, so they can afford more samples.
const int _microRuns = 9;

/// Every seeded row carries this marker, so one finder recognises the
/// conversation whichever slice of a long thread the list happens to build.
const String _marker = 'rowmark';

/// Ceilings. Generous on purpose — see the file comment. They are here to
/// catch a tenfold regression, not to police a busy machine.
const double _mountCeilingMs = 6000;
const double _microCeilingMs = 400;

void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDisk disk;

  Future<void> resetWorld() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
    await MultiplexSession.shutdown();
  }

  setUp(() async {
    await resetWorld();
    disk = FakeDisk();
  });

  tearDown(() async {
    await MultiplexSession.shutdown();
    await resetWorld();
  });

  /// `count` alternating rows, the shape a real transcript has: a short user
  /// turn, a long assistant turn. Realistic length matters — the cold-start
  /// cost is a function of payload bytes, not of the row count alone.
  List<Map<String, dynamic>> transcript(int count) => <Map<String, dynamic>>[
    for (int i = 0; i < count; i++)
      if (i.isEven)
        <String, dynamic>{'sender': 'user', 'text': '$_marker $i ask'}
      else
        <String, dynamic>{
          'sender': 'ai',
          'text':
              '$_marker $i answer. '
              '${"the assistant explains a step of the plan. " * 6}',
        },
  ];

  /// Writes a transcript the way a finished run does, then forgets everything
  /// this process knew about it — the app was closed. The disk survives.
  ///
  /// Through [WidgetTester.runAsync], because this is the app BEFORE the test,
  /// not the app under test: the store's write chains and `SharedPreferences`
  /// hand their answers back through the real event loop, which the fake-async
  /// zone of a `testWidgets` body never drains.
  Future<void> writeThenClose(
    WidgetTester tester,
    String sessionKey,
    int rows,
  ) async {
    await tester.runAsync(() async {
      await resetWorld();
      disk.install();
      AgentsChatStore.userIdProvider = () => 'perf-user';
      await AgentsChatStore.replaceThread(sessionKey, transcript(rows));
      await AgentsChatStore.pending(sessionKey);
      // What `AgentsChatStorageBootstrap._signedIn` writes on a session.
      await AgentsChatStore.rememberUser('perf-user');
      // Process death: the store forgets its memory, its seams and the live
      // session. Only the preferences key and the disk map are left.
      await AgentsChatStore.reset();
      await ChatStorageService.reset();
      disk.install();
      await drainNotifyDebounce();
    });
  }

  /// Mounts the thread view and reports three things about the mount:
  ///
  ///  * `mountMs` — `pumpWidget` alone: the first frame, still empty.
  ///  * `rowsMs` — from the same start to the first frame that actually holds
  ///    the cached rows. That is the number the demo lives on.
  ///  * `frames` — how many pumps after the mount that took. It separates
  ///    "the work is expensive" from "the rows waited for a timer", which the
  ///    milliseconds alone cannot tell apart.
  ///
  /// The pumps are inside the stopwatch: the mount and every frame after it
  /// are work the launch has to pay for. The loop stops at the first frame
  /// where the finder hits, so nothing is charged for pumps the paint did not
  /// need.
  Future<({double mountMs, double rowsMs, int frames})> timeMountToRows(
    WidgetTester tester,
    String threadKey, {
    required bool expectRows,
  }) async {
    silenceUnrelatedPlugins(tester);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FakeRelayController();
    final finder = find.textContaining(_marker);

    final watch = Stopwatch()..start();
    await tester.pumpWidget(
      perfApp(
        AgentsThreadView(
          controllerBuilder: () async => controller,
          sessionSource: const FakeSessionSource(),
          threadKey: threadKey,
          fileSaver: NoopSaver(),
        ),
      ),
    );
    final double mountMs = watch.elapsedMicroseconds / 1000;
    double? hit;
    int frames = 0;
    // A bounded pump loop, never `pumpAndSettle`: the thread view arms an
    // eight-second `Timer.periodic` watchdog, so the tree is never "settled"
    // and `pumpAndSettle` would sit until its own ten-minute timeout.
    for (int i = 0; i < 24 && hit == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      frames = i + 1;
      if (finder.evaluate().isNotEmpty) hit = watch.elapsedMicroseconds / 1000;
    }
    watch.stop();

    // Off the clock from here. The measurement stops at the first frame that
    // shows the rows, which is EARLIER than the mount is finished: the
    // imported chat screen arms a zero-duration timer from its `initState`
    // post-frame callback, and an unmount with that still pending fails the
    // test for a timer that is not the measurement's business. Give the tree
    // its remaining frames before taking it down.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    // The guarantee under the number: this really was a cold start.
    expect(
      controller.state.value.phase,
      AgentsRelayPhase.idle,
      reason: 'the transport must never leave idle in a cold-start measurement',
    );
    expect(
      controller.replayRequests,
      isEmpty,
      reason: 'nothing on screen may have been asked of the host',
    );
    if (expectRows) {
      expect(hit, isNotNull, reason: 'the cached rows never reached a frame');
    }
    final double rowsMs = hit ?? watch.elapsedMicroseconds / 1000;

    await releaseIdleTimers(tester);
    // Unmount before the next run, so the next mount is a mount and not a
    // rebuild of a tree that is already warm.
    await tester.pumpWidget(perfApp(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 350));
    return (mountMs: mountMs, rowsMs: rowsMs, frames: frames);
  }

  testWidgets('cold start to the first frame holding the cached rows, over '
      '50 / 500 / 2000 messages', (tester) async {
    final table = PerfTable(
      'cold start: pumpWidget -> first frame with the cached conversation',
    );
    final medians = <int, double>{};

    // Unrecorded mounts first, at the LARGEST size, and more than one. The
    // very first mount in a process pays for JIT compilation of the whole chat
    // screen (850 ms against 60 ms for the next), and the warming keeps going
    // for several more mounts. Without this, whichever size ran first carried
    // the remaining warm-up and read as the slowest — measured: 103 ms for 50
    // messages ahead of 60 ms for 2000, and the ranking flipped when the order
    // was reversed. Warm at 2000 so every path the big case takes is compiled
    // before the first sample is kept.
    for (int i = 0; i < 3; i++) {
      await writeThenClose(tester, 'host:warmup-$i', 2000);
      await timeMountToRows(tester, 'host:warmup-$i', expectRows: true);
    }

    for (final int rows in <int>[50, 500, 2000]) {
      final toRows = <double>[];
      final mounts = <double>[];
      var bytes = 0;
      var frames = 0;
      for (int run = 0; run < _mountRuns; run++) {
        final key = 'host:cold-$rows-$run';
        await writeThenClose(tester, key, rows);
        bytes = disk.payloadBytesOf('perf-user', key);
        final result = await timeMountToRows(tester, key, expectRows: true);
        toRows.add(result.rowsMs);
        mounts.add(result.mountMs);
        frames = result.frames;
      }
      table.add(
        'cold start, $rows msgs -> rows on screen',
        toRows,
        note:
            '${(bytes / 1024).toStringAsFixed(1)} KiB payload, '
            '$frames frames after the mount',
      );
      table.add(
        'cold start, $rows msgs -> pumpWidget only',
        mounts,
        note: 'the first, still empty frame',
      );
      medians[rows] = median(toRows);
    }
    table.report();

    for (final MapEntry<int, double> entry in medians.entries) {
      expect(
        entry.value,
        lessThan(_mountCeilingMs),
        reason:
            'cold start with ${entry.key} cached messages took '
            '${entry.value.toStringAsFixed(1)} ms — a tenfold regression',
      );
    }
    // The slope is the real assertion: forty times the rows must not cost
    // anything like forty times the time, because the list is lazy and only
    // the parse grows. A build that starts laying out every row would blow
    // straight through this.
    final double slope = medians[2000]! / medians[50]!;
    debugPrint(
      'cold-start slope 2000 rows / 50 rows = ${slope.toStringAsFixed(2)}x',
    );
    expect(
      slope,
      lessThan(20),
      reason:
          'cold start scaled ${slope.toStringAsFixed(1)}x from 50 to 2000 '
          'rows — the paint is no longer lazy, or the parse went quadratic',
    );
  }, timeout: _guard);

  testWidgets('the disk read, payload parse and model build alone, with no '
      'widget in the way', (tester) async {
    // The mount measurement above is nearly flat over 50..2000 messages, which
    // only says the fixed cost of building the chat screen dominates it. This
    // one strips the screen away and times `loadThread` on its own: the row
    // read, `deserializePayloadIsolate` on the payload, and `ChatMessage`
    // for every row. It is the part that actually grows with the transcript,
    // and it runs on the UI thread on the cold-start path by design.
    //
    // In `runAsync`, so the store's own futures complete on the real event
    // loop instead of waiting for a fake-async zone that never drains them.
    final table = PerfTable(
      'AgentsChatStore.loadThread alone: read + parse + model build',
    );
    final medians = <int, double>{};

    for (int i = 0; i < 2; i++) {
      await writeThenClose(tester, 'parse:warmup-$i', 2000);
      await tester.runAsync(
        () async => AgentsChatStore.loadThread('parse:warmup-$i'),
      );
    }

    for (final int rows in <int>[50, 500, 2000]) {
      final samples = <double>[];
      var bytes = 0;
      for (int run = 0; run < _microRuns; run++) {
        final key = 'parse:$rows-$run';
        await writeThenClose(tester, key, rows);
        bytes = disk.payloadBytesOf('perf-user', key);
        await tester.runAsync(() async {
          final watch = Stopwatch()..start();
          final chat = await AgentsChatStore.loadThread(key);
          watch.stop();
          expect(
            chat?.messages,
            hasLength(rows),
            reason: 'the parse must return the whole transcript',
          );
          samples.add(watch.elapsedMicroseconds / 1000);
        });
      }
      table.add(
        'loadThread, $rows messages',
        samples,
        note:
            '${(bytes / 1024).toStringAsFixed(1)} KiB, '
            '${(median(samples) * 1000 / rows).toStringAsFixed(1)} us/message',
      );
      medians[rows] = median(samples);
    }
    table.report();

    for (final MapEntry<int, double> entry in medians.entries) {
      expect(
        entry.value,
        lessThan(_mountCeilingMs),
        reason:
            'loadThread with ${entry.key} messages took '
            '${entry.value.toStringAsFixed(1)} ms on the UI thread',
      );
    }
    // Linear is the contract: the parse walks the rows once. Forty times the
    // rows may cost forty times the time, but not four hundred — a quadratic
    // in the decode would blow through this long before a user noticed.
    final double slope = medians[2000]! / medians[50]!;
    debugPrint(
      'loadThread slope 2000 rows / 50 rows = ${slope.toStringAsFixed(2)}x '
      '(linear would be 40x)',
    );
    expect(
      slope,
      lessThan(160),
      reason:
          'the parse scaled ${slope.toStringAsFixed(1)}x for 40x the rows — '
          'that is no longer linear',
    );
  }, timeout: _guard);

  testWidgets('opening a thread that is already cached versus one that is not', (
    tester,
  ) async {
    final table = PerfTable('opening a thread: cached versus not');
    const int rows = 500;

    // Unrecorded, for the same reason as in the tests above: a process warms
    // up over several mounts, and that must not be charged to the first block.
    for (int i = 0; i < 3; i++) {
      await writeThenClose(tester, 'host:warmup-$i', rows);
      await timeMountToRows(tester, 'host:warmup-$i', expectRows: true);
    }

    // 1. Cold from disk: the row is there, but this process has never read it.
    final fromDisk = <double>[];
    for (int run = 0; run < _mountRuns; run++) {
      final key = 'host:disk-$run';
      await writeThenClose(tester, key, rows);
      fromDisk.add((await timeMountToRows(tester, key, expectRows: true)).rowsMs);
    }
    table.add(
      'open, $rows rows, cold from disk',
      fromDisk,
      note: 'row read + payload parse + first paint',
    );

    // 2. Warm: the same thread mounted again in a process that already holds
    //    it in memory. `loadThread` returns on its first line here.
    const String warmKey = 'host:warm';
    await writeThenClose(tester, warmKey, rows);
    await timeMountToRows(tester, warmKey, expectRows: true); // prime memory
    final warm = <double>[];
    for (int run = 0; run < _mountRuns; run++) {
      warm.add(
        (await timeMountToRows(tester, warmKey, expectRows: true)).rowsMs,
      );
    }
    table.add(
      'open, $rows rows, warm in memory',
      warm,
      note: 'no disk read, no parse',
    );

    // 3. A thread nothing has ever written: the mount-on-a-miss. This is the
    //    screen a first-ever launch shows, and it must not be slower than a
    //    hit — a miss that costs more than a hit means the read is retried.
    final miss = <double>[];
    for (int run = 0; run < _mountRuns; run++) {
      await tester.runAsync(() async {
        await resetWorld();
        disk.install();
      });
      miss.add(
        (await timeMountToRows(
          tester,
          'host:never-$run',
          expectRows: false,
        )).rowsMs,
      );
    }
    table.add(
      'open, thread not cached at all',
      miss,
      note: 'cache miss, empty screen',
    );
    table.report();

    final double diskMs = median(fromDisk);
    final double warmMs = median(warm);
    final double missMs = median(miss);
    debugPrint(
      'cached-vs-not: disk ${diskMs.toStringAsFixed(1)} ms, '
      'warm ${warmMs.toStringAsFixed(1)} ms, '
      'miss ${missMs.toStringAsFixed(1)} ms',
    );

    for (final double value in <double>[diskMs, warmMs, missMs]) {
      expect(value, lessThan(_mountCeilingMs));
    }
    // A cache miss paints nothing, so it can never be the expensive case.
    expect(
      missMs,
      lessThan(diskMs * 6 + 100),
      reason:
          'a cache MISS cost ${missMs.toStringAsFixed(1)} ms against '
          '${diskMs.toStringAsFixed(1)} ms for a hit — the empty path is '
          'doing work it has no rows to do it on',
    );
  }, timeout: _guard);

  test('AgentsReplayLoader.appendWithoutRepeats over a long cache', () {
    // The join the app runs every time the host answers with a delta. Step one
    // walks every possible overlap length k from min(n, m) down to 1 and
    // compares up to k rows for each, so its cost is driven by the DELTA, not
    // by the cache: O(min(n, m)^2) row comparisons in the adversarial shape.
    // Step two is bounded by `repeatWindow` (60) and cannot grow. The point of
    // this benchmark is to find where that square starts to hurt.
    List<Map<String, String>> rows(int count, {String salt = ''}) =>
        <Map<String, String>>[
          for (int i = 0; i < count; i++)
            <String, String>{
              'sender': i.isEven ? 'user' : 'ai',
              'text': 'turn $i$salt ${"a word " * 8}',
            },
        ];

    final table = PerfTable(
      'AgentsReplayLoader.appendWithoutRepeats (cache = 2000 rows)',
    );
    const int cacheSize = 2000;
    final List<Map<String, String>> cache = rows(cacheSize);

    void bench(
      String label,
      List<Map<String, String>> existing,
      List<Map<String, String>> delta,
      String note,
    ) {
      final samples = <double>[];
      // One warm-up outside the samples: the first call pays for JIT.
      AgentsReplayLoader.appendWithoutRepeats(existing, delta);
      for (int run = 0; run < _microRuns; run++) {
        late List<Map<String, String>> out;
        samples.add(
          timedMs(() {
            out = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
          }),
        );
        expect(out, isNotEmpty);
      }
      table.add(label, samples, note: note);
    }

    // (a) The clean case the code is written for: the last 20 cached rows are
    //     the head of the delta. Step one finds the overlap and returns.
    for (final int deltaSize in <int>[50, 500, 2000]) {
      final overlap = cache.sublist(cacheSize - 20);
      final delta = <Map<String, String>>[
        ...overlap,
        ...rows(deltaSize - 20, salt: '-new'),
      ];
      bench(
        'clean 20-row overlap, delta $deltaSize',
        cache,
        delta,
        'the shape a normal delta has',
      );
    }

    // (b) The adversarial shape, and the reason this benchmark exists. Every
    //     cached row but the LAST one is the same repeated turn, and the delta
    //     is that same turn again — a thread of "ok", "ok", "ok" with one
    //     different row at the end, which is reachable.
    //
    //     This shape used to be the worst case of a row-by-row search: every
    //     candidate overlap matched on all but its last row, so each one was
    //     paid for in full, k(k+1)/2 comparisons. It measured 97 ms on the UI
    //     thread at a 2000-row delta on a desktop, on the reconnect path (bead
    //     cowork-6i0m). Step one is a KMP prefix function now and answers in
    //     one pass, so this shape is no longer special — the numbers below are
    //     what proves it, and they are why this benchmark stays.
    for (final int deltaSize in <int>[50, 500, 2000]) {
      final existing = <Map<String, String>>[
        for (int i = 0; i < cacheSize - 1; i++)
          <String, String>{'sender': 'ai', 'text': 'ok'},
        <String, String>{'sender': 'ai', 'text': 'the last one differs'},
      ];
      final delta = <Map<String, String>>[
        for (int i = 0; i < deltaSize; i++)
          <String, String>{'sender': 'ai', 'text': 'ok'},
      ];
      // What the old loop paid here, kept as the yardstick: it tried every
      // candidate length and each one matched on all but its last row.
      final int wasComparisons = deltaSize * (deltaSize + 1) ~/ 2;
      bench(
        'adversarial repeats, delta $deltaSize',
        existing,
        delta,
        'linear now; the row-by-row loop paid $wasComparisons comparisons',
      );
    }

    // (c) No overlap at all: step one's prefix function finds nothing, then
    //     step two scans the bounded 60-row window. The cheap path.
    for (final int deltaSize in <int>[50, 2000]) {
      bench(
        'no overlap, delta $deltaSize',
        cache,
        rows(deltaSize, salt: '-unrelated'),
        'step 1 fails fast, step 2 scans 60 rows',
      );
    }
    table.report();

    for (final PerfRow row in table.rows) {
      expect(
        row.medianMs,
        lessThan(_microCeilingMs),
        reason:
            '${row.label} took ${row.medianMs.toStringAsFixed(2)} ms — '
            'appendWithoutRepeats is on the paint path of every delta',
      );
    }
  }, timeout: _guard);
}
