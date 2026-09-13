import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';

import '../../support/fake_relay_controller.dart';

/// Replay paging in the loader (docs/WIRE_CONTRACT.md "Replay paging", Bead
/// cowork-axx): the newest page is committed the moment its `done` lands, the
/// loader then asks for the older page below it, prepends it, and stops when
/// the host says there is no more. A cursor never moves down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = 'thread-1';
  final loader = AgentsReplayLoader.instance;
  late FakeRelayController controller;

  setUp(() async {
    // The one-time repeat repair (bead cowork-4rpt) is a migration, not
    // the steady state these tests describe: mark it done.
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
    });
    loader.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await ChatStorageService.reset();
    controller = FakeRelayController();
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = session;
    loader.attach();
  });

  tearDown(() async {
    loader.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await ChatStorageService.reset();
  });

  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<String> texts() {
    final chat = ChatStorageService.getChatById(session);
    if (chat == null || !chat.isFullyLoaded) return const <String>[];
    return chat.messages.map((m) => '${m.toJson()['text'] ?? ''}').toList();
  }

  void turn(String q, int qMid, String a, int aMid) {
    controller.emit(AgentsRelayUser(q, replay: true, mid: qMid));
    controller.emit(AgentsRelayDelta(a, replay: true, mid: aMid));
  }

  AgentsRelayDone pageEnd({required bool hasMore, required int oldestMid, int? beforeId}) =>
      AgentsRelayDone(
        reason: 'replay',
        finalAnswer: null,
        iterations: 0,
        replay: true,
        hasMore: hasMore,
        oldestMid: oldestMid,
        pageBeforeId: beforeId,
      );

  test('the newest page paints first, older pages are fetched and prepended',
      () async {
    // The thread view asks a full replay; the host answers with the newest page.
    loader.expect(session);
    turn('q4', 40, 'a4', 41);
    turn('q5', 50, 'a5', 51);
    controller.emit(pageEnd(hasMore: true, oldestMid: 40));
    await drain();

    // Painted at once, from the first page alone.
    expect(texts(), ['q4', 'a4', 'q5', 'a5']);
    expect(loader.cursorFor(session), 51);
    // ...and the loader asked for the page below it, with the page size.
    expect(controller.replayPages, [(session, 40, kReplayPageSize)]);

    // The older page arrives and goes in front.
    turn('q2', 20, 'a2', 21);
    turn('q3', 30, 'a3', 31);
    controller.emit(pageEnd(hasMore: true, oldestMid: 20, beforeId: 40));
    await drain();
    expect(texts(), ['q2', 'a2', 'q3', 'a3', 'q4', 'a4', 'q5', 'a5']);
    // The cursor stays at the newest row: an older page never moves it down.
    expect(loader.cursorFor(session), 51);
    expect(controller.replayPages.last, (session, 20, kReplayPageSize));

    // The last page: no more below it, so nothing else is asked for.
    turn('q0', 1, 'a0', 2);
    turn('q1', 10, 'a1', 11);
    controller.emit(pageEnd(hasMore: false, oldestMid: 1, beforeId: 20));
    await drain();
    expect(texts(), [
      'q0', 'a0', 'q1', 'a1', 'q2', 'a2', 'q3', 'a3', 'q4', 'a4', 'q5', 'a5',
    ]);
    expect(controller.replayPages, hasLength(2));
  });

  test('a page that does not move the floor is not asked for twice', () async {
    loader.expect(session);
    turn('q4', 40, 'a4', 41);
    controller.emit(pageEnd(hasMore: true, oldestMid: 40));
    await drain();
    expect(controller.replayPages, hasLength(1));

    // The host answers the older page but (misbehaving) repeats the same
    // oldest_mid: the loader must not loop on it.
    turn('q3', 30, 'a3', 31);
    controller.emit(pageEnd(hasMore: true, oldestMid: 40, beforeId: 40));
    await drain();
    expect(controller.replayPages, hasLength(1));
    expect(texts(), ['q3', 'a3', 'q4', 'a4']);
  });

  test('an unpaged replay (old host) is committed exactly as before', () async {
    loader.expect(session);
    turn('q0', 1, 'a0', 2);
    controller.emit(const AgentsRelayDone(
      reason: 'replay', finalAnswer: null, iterations: 0, replay: true));
    await drain();
    expect(texts(), ['q0', 'a0']);
    expect(controller.replayPages, isEmpty);
    expect(loader.cursorFor(session), 2);
  });

  test('no older page is asked for while the transport is down', () async {
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.idle));
    loader.expect(session);
    turn('q4', 40, 'a4', 41);
    controller.emit(pageEnd(hasMore: true, oldestMid: 40));
    await drain();
    expect(texts(), ['q4', 'a4']);
    expect(controller.replayPages, isEmpty);
    if (kDebugMode) debugPrint('paging: transport down, no follow-up asked');
  });
}
