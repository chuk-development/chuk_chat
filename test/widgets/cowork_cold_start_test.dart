// Cold start (bead cowork-91pn): close the app, open it again, and the thread
// you were in is on screen from disk — no spinner, no waiting for the relay.
//
// Every test here mounts the thread view with a controller that NEVER pairs,
// so nothing on screen can have come from the host. The rows are the ones the
// last run wrote to the local cache.
//
// The "disk" is [_FakeDisk], plugged into `CoworkChatStore`'s own cache seams,
// NOT real SQLite. A `testWidgets` body runs in a fake-async zone: a real
// sqflite read hands its answer back through the real event loop and the fake
// zone never drains it, so the test would sit there forever. The seam exercises
// the same code path — `resolveCacheUserId` → `localCacheReader` → the store —
// with none of that hazard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/chat_storage_state.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_replay_loader.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/multiplex_session.dart';
import 'package:cowork/services/settings/verbose_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

import '../support/fake_relay_controller.dart';

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(CoworkRelayFile file) async => '/dev/null/${file.name}';
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => null;

  @override
  Future<AccountSession?> refresh() async => null;
}

/// The local cache, as a map. It outlives [CoworkChatStore.reset] on purpose:
/// resetting the store is the app closing, and the disk is what survives that.
class _FakeDisk {
  final Map<String, Map<String, dynamic>> rows =
      <String, Map<String, dynamic>>{};
  final Map<String, String> kv = <String, String>{};

  /// Points the store at this map. Called again after every reset, because
  /// `reset` clears the seams the way process death clears the process.
  void install() {
    CoworkChatStore.localCacheWriter =
        (String userId, Map<String, dynamic> row) async {
          rows['$userId ${row['id']}'] = row;
        };
    CoworkChatStore.localCacheReader = (String userId, String id) async =>
        rows['$userId $id'];
    // No encryption key: the cloud half of every write is skipped, which is
    // exactly the offline case this file is about.
    CoworkChatStore.keyLoader = () async => false;
    CoworkChatStore.outboxRead = (String key) async => kv[key];
    CoworkChatStore.outboxWrite = (String key, String value) async =>
        kv[key] = value;
    CoworkChatStore.outboxDelete = (String key) async => kv.remove(key);
  }
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDisk disk;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    CoworkReplayLoader.instance.reset();
    await ChatStorageService.reset();
    await CoworkChatStore.reset();
    await MultiplexSession.shutdown();
    disk = _FakeDisk();
  });

  tearDown(() async {
    await MultiplexSession.shutdown();
    await CoworkChatStore.reset();
    await ChatStorageService.reset();
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    CoworkReplayLoader.instance.reset();
    await VerboseService.instance.setEnabled(false);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Writes a transcript the way a finished run does, then forgets everything
  /// this process knew about it — the app was closed. The disk survives.
  ///
  /// Through [WidgetTester.runAsync], because a `testWidgets` body runs in a
  /// fake-async zone: `SharedPreferences` and the store's own write chains hand
  /// their answers back through the real event loop, which that zone never
  /// drains, and the test would sit there forever. This is the app BEFORE the
  /// test, not the app under test, so the real zone is the honest place for it.
  Future<void> writeThenClose(WidgetTester tester, String sessionKey) async {
    await tester.runAsync(() async {
      disk.install();
      CoworkChatStore.userIdProvider = () => 'cold-user';
      await CoworkChatStore.replaceThread(sessionKey, <Map<String, dynamic>>[
        {'sender': 'user', 'text': 'where were we'},
        {'sender': 'ai', 'text': 'right here, from disk'},
      ]);
      await CoworkChatStore.pending(sessionKey);
      // What `CoworkChatStorageBootstrap._signedIn` writes on a session.
      await CoworkChatStore.rememberUser('cold-user');
      // Process death: the store forgets its memory, its seams and the live
      // session. Only the preferences key and the disk map are left.
      await CoworkChatStore.reset();
      await ChatStorageService.reset();
      disk.install();
      await _drainNotifyDebounce();
    });
  }

  Future<FakeRelayController> pumpThread(
    WidgetTester tester,
    String threadKey,
  ) async {
    _silenceUnrelatedPlugins(tester);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FakeRelayController();
    await tester.pumpWidget(
      _app(
        CoworkThreadView(
          controllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          threadKey: threadKey,
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await _settle(tester);
    return controller;
  }

  testWidgets('a cold start paints the cached rows with no controller ever '
      'pairing', (tester) async {
    await writeThenClose(tester, 'host:peer-1');

    final controller = await pumpThread(tester, 'host:peer-1');

    // Nothing came from the host: the transport never left idle and no replay
    // was ever asked for.
    expect(controller.state.value.phase, CoworkRelayPhase.idle);
    expect(controller.replayRequests, isEmpty);

    expect(find.text('where were we'), findsOneWidget);
    expect(find.text('right here, from disk'), findsOneWidget);
    await _releaseIdleTimers(tester);
  }, timeout: _guard);

  testWidgets('the cache is readable with currentUser == null and chatsById '
      'is not cleared', (tester) async {
    await writeThenClose(tester, 'host:peer-1');

    // The cold start proper: no Supabase session anywhere.
    expect(CoworkChatStore.userIdProvider, isNull);
    await tester.runAsync(() async {
      expect(await CoworkChatStore.resolveCacheUserId(), 'cold-user');
      // And the same id answers the replay loader's cheap "do I hold this?"
      // question, which is the check that decides between a delta and a full
      // replay. A disagreement there is how history gets spliced onto the
      // wrong base and lost for good.
      expect(await CoworkChatStore.hasThread('host:peer-1'), isTrue);
    });

    await pumpThread(tester, 'host:peer-1');

    final chat = ChatStorageState.chatsById['host:peer-1'];
    expect(chat, isNotNull, reason: 'the sidebar read must not clear the map');
    expect(chat!.isFullyLoaded, isTrue);
    expect(chat.messages, hasLength(2));
    await _releaseIdleTimers(tester);
  }, timeout: _guard);

  testWidgets('a thread whose rows land after the mount is remounted on them', (
    tester,
  ) async {
    // Mount on a thread the disk does NOT hold, so the warm read finds nothing
    // for it: the mount-on-a-miss the remount exists for.
    await pumpThread(tester, 'late-thread');
    expect(find.text('landed late'), findsNothing);

    // The read lands now, exactly as a slow disk would deliver it.
    await tester.runAsync(() async {
      disk.install();
      CoworkChatStore.userIdProvider = () => 'cold-user';
      await CoworkChatStore.replaceThread('late-thread', <Map<String, dynamic>>[
        {'sender': 'ai', 'text': 'landed late'},
      ]);
      await CoworkChatStore.pending('late-thread');
      await _drainNotifyDebounce();
    });
    await _settle(tester);

    expect(find.text('landed late'), findsOneWidget);
    await _releaseIdleTimers(tester);
  }, timeout: _guard);

  testWidgets('a run in flight is never remounted out from under the answer', (
    tester,
  ) async {
    await pumpThread(tester, 'busy-thread');
    expect(
      find.byKey(const ValueKey<String>('cowork-chat-busy-thread-0-0')),
      findsOneWidget,
    );

    CoworkRunLedger.instance.begin('busy-thread');
    await tester.runAsync(() async {
      disk.install();
      CoworkChatStore.userIdProvider = () => 'cold-user';
      await CoworkChatStore.replaceThread('busy-thread', <Map<String, dynamic>>[
        {'sender': 'ai', 'text': 'a replayed copy'},
      ]);
      await CoworkChatStore.pending('busy-thread');
      await _drainNotifyDebounce();
    });
    await _settle(tester);

    // Same key: the screen was not remounted while the run streams into it.
    expect(
      find.byKey(const ValueKey<String>('cowork-chat-busy-thread-0-0')),
      findsOneWidget,
    );
    await _releaseIdleTimers(tester);
  }, timeout: _guard);

  testWidgets('an empty thread key mounts no conversation at all', (
    tester,
  ) async {
    final controller = await pumpThread(tester, '');
    expect(controller.replayRequests, isEmpty);
    // No chat screen and, above all, no cache row and no replay cursor for a
    // key nobody ever writes.
    expect(ChatStorageState.chatsById, isEmpty);
    await _releaseIdleTimers(tester);
  }, timeout: _guard);
}

/// `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
/// timer. The writes here run through [WidgetTester.runAsync], so that timer is
/// a REAL one: give it its moment in the real zone, or the event the thread
/// view is waiting for never leaves the store.
Future<void> _drainNotifyDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

/// The imported chat screen opens a multiplex session on mount and arms a
/// one-minute idle-close timer when it is disposed — including the dispose the
/// harness itself does after the body, which would then fail the test for a
/// pending timer that is not its business. Shutting the session down first
/// clears the claim, so that last dispose arms nothing.
Future<void> _releaseIdleTimers(WidgetTester tester) async {
  await MultiplexSession.shutdown();
  await tester.pump();
}

/// The imported screen constructs an [AudioRecorder] on mount, which calls the
/// microphone plugin straight away. There is no plugin under `flutter test`, so
/// the call is rejected, and because the recorder does not await its own
/// creation the rejection surfaces as an uncaught error against whichever test
/// happened to mount the screen. Answer that one channel with a harmless null.
///
/// Only that one: path_provider is left alone on purpose. Its own failure is
/// caught by the caller, and a mock that answers null makes it throw
/// `MissingPlatformDirectoryException` instead, which is not.
void _silenceUnrelatedPlugins(WidgetTester tester) {
  const MethodChannel record = MethodChannel('com.llfbandit.record/messages');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    record,
    (MethodCall call) async => null,
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      record,
      null,
    );
  });
}

/// [WidgetTester.pumpAndSettle] never returns here: the thread view arms an
/// 8-second `Timer.periodic` watchdog, so the tree is never "settled" and the
/// call sits until its own ten-minute timeout. Bounded pumps instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

/// A wall-clock guard on every test in this file. Nothing here should take
/// more than a moment; a regression that made one wait on the real event loop
/// from inside the fake-async zone once stalled the whole suite, and a failure
/// is always better than silence.
const Timeout _guard = Timeout(Duration(seconds: 60));
