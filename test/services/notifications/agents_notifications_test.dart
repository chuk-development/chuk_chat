import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/run_notifications.dart';

import 'local_notifications_test.dart' show FakeBackend;

void main() {
  late FakeBackend backend;
  late List<Map<String, String?>> consumed;

  setUp(() async {
    AgentsNotifications.instance.reset();
    LocalNotifications.instance.reset();
    backend = FakeBackend();
    consumed = <Map<String, String?>>[];
    RunNotifications.instance.configure(
      userId: () => 'user-1',
      writer: ({
        required String userId,
        String? sessionKey,
        String? runId,
        required String consumedAt,
      }) async {
        consumed.add(<String, String?>{
          'user': userId,
          'session': sessionKey,
          'run': runId,
        });
      },
    );
    await AgentsNotifications.instance.initialize(
      localBackend: backend,
      startPush: false,
    );
    AgentsNotifications.instance.threadLabel = (String key) => 'Coworker $key';
  });

  tearDown(() {
    RunNotifications.instance.configure();
    AgentsNotifications.instance.reset();
    LocalNotifications.instance.reset();
  });

  test('attached + foreground: a live done shows nothing', () async {
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.resumed;
    await AgentsNotifications.instance.onLiveDone('t1');
    expect(backend.shown, isEmpty);
  });

  test('attached + background: a live done toasts once, generic text',
      () async {
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.paused;
    await AgentsNotifications.instance.onLiveDone('t1', runId: 'run-1');
    expect(backend.shown, hasLength(1));
    expect(backend.shown.single['title'], 'Coworker t1');
    expect(backend.shown.single['body'], 'Your answer is ready.');
    expect(backend.shown.single['tag'], 't1');
  });

  test('hidden and inactive count as background', () async {
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.hidden;
    await AgentsNotifications.instance.onLiveDone('t1');
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.inactive;
    await AgentsNotifications.instance.onLiveDone('t2');
    expect(backend.shown.map((m) => m['tag']), <String>['t1', 't2']);
  });

  test('a replayed while_away answer consumes the row and clears the toast',
      () async {
    await AgentsNotifications.instance.onAnswerReplayed('t3');
    expect(consumed, <Map<String, String?>>[
      <String, String?>{'user': 'user-1', 'session': 't3', 'run': null},
    ]);
    expect(backend.cancelled, <(int, String)>[
      (LocalNotifications.idFor('t3'), 't3'),
    ]);

    // Idempotent per launch: a second replay does not PATCH again.
    await AgentsNotifications.instance.onAnswerReplayed('t3');
    expect(consumed, hasLength(1));
  });

  test('a second run for the same coworker is consumed too; the same run only '
      'once (F7)', () async {
    await AgentsNotifications.instance.onAnswerReplayed('t7', runId: 'run-a');
    await AgentsNotifications.instance.onAnswerReplayed('t7', runId: 'run-a');
    await AgentsNotifications.instance.onAnswerReplayed('t7', runId: 'run-b');
    expect(consumed.where((m) => m['session'] == 't7'), hasLength(2));
  });

  test('opening from a notification consumes by run and by session', () async {
    await AgentsNotifications.instance.onOpenedFromNotification(
      't4',
      runId: 'run-4',
    );
    expect(consumed.map((m) => m['run']), contains('run-4'));
    expect(consumed.map((m) => m['session']), contains('t4'));
    expect(backend.cancelled.single.$2, 't4');
  });

  test('no user: consume is a no-op, never throws', () async {
    RunNotifications.instance.configure(userId: () => null);
    await AgentsNotifications.instance.onAnswerReplayed('t5');
    expect(consumed, isEmpty);
  });
}
