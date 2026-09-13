// Shared scaffolding for the perf tests in this directory.
//
// Nothing here asserts. It only holds the pieces every perf test needs: the
// fake local cache the store reads through, a median, and a table printer, so
// a run leaves numbers a person can read instead of a pass/fail dot.
//
// The "disk" is a map plugged into `AgentsChatStore`'s own cache seams, NOT
// real SQLite. A `testWidgets` body runs in a fake-async zone: a real sqflite
// read hands its answer back through the real event loop, which that zone
// never drains, so the test would sit there forever. The seam runs the same
// code — `resolveCacheUserId` -> `localCacheReader` -> payload parse -> the
// store — with none of that hazard. See `test/widgets/agents_cold_start_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';

/// A file saver that writes nowhere. No perf test hands a file to it.
class NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

/// No Supabase session anywhere — the cold start proper.
class FakeSessionSource implements AccountSessionSource {
  const FakeSessionSource();

  @override
  AccountSession? current() => null;

  @override
  Future<AccountSession?> refresh() async => null;
}

/// The local cache, as a map. It outlives [AgentsChatStore.reset] on purpose:
/// resetting the store is the app closing, and the disk is what survives that.
class FakeDisk {
  final Map<String, Map<String, dynamic>> rows =
      <String, Map<String, dynamic>>{};
  final Map<String, String> kv = <String, String>{};

  /// How many bytes of payload the disk holds for one thread. The parse cost
  /// of a cold start is a function of this, not of the row count alone.
  int payloadBytesOf(String userId, String sessionKey) {
    final payload = rows['$userId $sessionKey']?['payload'];
    return payload is String ? payload.length : 0;
  }

  /// Points the store at this map. Called again after every reset, because
  /// `reset` clears the seams the way process death clears the process.
  void install() {
    AgentsChatStore.localCacheWriter =
        (String userId, Map<String, dynamic> row) async {
          rows['$userId ${row['id']}'] = row;
        };
    AgentsChatStore.localCacheReader = (String userId, String id) async =>
        rows['$userId $id'];
    // No encryption key: the cloud half of every write is skipped, which is
    // exactly the offline case these tests are about.
    AgentsChatStore.keyLoader = () async => false;
    AgentsChatStore.outboxRead = (String key) async => kv[key];
    AgentsChatStore.outboxWrite = (String key, String value) async =>
        kv[key] = value;
    AgentsChatStore.outboxDelete = (String key) async => kv.remove(key);
  }
}

Widget perfApp(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

/// The imported chat screen constructs an [AudioRecorder] on mount, which
/// calls the microphone plugin straight away. There is no plugin under
/// `flutter test`, so the call is rejected, and because the recorder does not
/// await its own creation the rejection surfaces as an uncaught error against
/// whichever test mounted the screen. Answer that one channel with a null.
///
/// Only that one: path_provider is left alone on purpose. Its own failure is
/// caught by the caller, and a mock that answers null makes it throw
/// `MissingPlatformDirectoryException` instead, which is not.
void silenceUnrelatedPlugins(WidgetTester tester) {
  const MethodChannel record = MethodChannel('com.llfbandit.record/messages');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    record,
    (MethodCall call) async => null,
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(record, null);
  });
}

/// The imported chat screen opens a multiplex session on mount and arms a
/// one-minute idle-close timer when it is disposed — including the dispose the
/// harness does after the body, which would then fail the test for a pending
/// timer that is not its business. Shutting the session down first clears the
/// claim, so that last dispose arms nothing.
Future<void> releaseIdleTimers(WidgetTester tester) async {
  await MultiplexSession.shutdown();
  await tester.pump();
}

/// `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
/// timer. Seeding runs through [WidgetTester.runAsync], so that timer is a REAL
/// one: give it its moment, or the event the thread view waits for never
/// leaves the store.
Future<void> drainNotifyDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

// ---------------------------------------------------------------------------
// Statistics and reporting
// ---------------------------------------------------------------------------

/// The median of [samples]. An even count takes the mean of the middle pair.
/// A median, not a mean: one scheduling hiccup on a busy machine must not move
/// the reported number.
double median(List<double> samples) {
  assert(samples.isNotEmpty, 'a median needs at least one sample');
  final sorted = List<double>.of(samples)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

double _minOf(List<double> s) => (List<double>.of(s)..sort()).first;
double _maxOf(List<double> s) => (List<double>.of(s)..sort()).last;

/// One measured quantity: a label, its samples in milliseconds, and an
/// optional note (a row count, a byte count, a comparison count).
class PerfRow {
  PerfRow(this.label, this.samplesMs, {this.note = ''});

  final String label;
  final List<double> samplesMs;
  final String note;

  double get medianMs => median(samplesMs);
  double get minMs => _minOf(samplesMs);
  double get maxMs => _maxOf(samplesMs);
}

/// Collects [PerfRow]s and prints them as one fixed-width table.
class PerfTable {
  PerfTable(this.title);

  final String title;
  final List<PerfRow> rows = <PerfRow>[];

  void add(String label, List<double> samplesMs, {String note = ''}) =>
      rows.add(PerfRow(label, samplesMs, note: note));

  void report() {
    if (rows.isEmpty) return;
    final labelWidth = rows
        .map((PerfRow r) => r.label.length)
        .reduce((int a, int b) => a > b ? a : b)
        .clamp(10, 46);
    String pad(String s, int w) =>
        s.length >= w ? s.substring(0, w) : s.padRight(w);
    String num6(double v) => v.toStringAsFixed(2).padLeft(9);

    final line = '-' * (labelWidth + 9 * 3 + 6 + 4);
    debugPrint('');
    debugPrint('=== $title ===');
    debugPrint(
      '${pad("measurement", labelWidth)}  '
      '${"median/ms".padLeft(9)} ${"min/ms".padLeft(9)} ${"max/ms".padLeft(9)}'
      '  n  note',
    );
    debugPrint(line);
    for (final row in rows) {
      debugPrint(
        '${pad(row.label, labelWidth)}  '
        '${num6(row.medianMs)} ${num6(row.minMs)} ${num6(row.maxMs)}'
        '  ${row.samplesMs.length}  ${row.note}',
      );
    }
    debugPrint(line);
  }
}

/// Wall-clock milliseconds of [body], at microsecond resolution.
double timedMs(void Function() body) {
  final watch = Stopwatch()..start();
  body();
  watch.stop();
  return watch.elapsedMicroseconds / 1000.0;
}
