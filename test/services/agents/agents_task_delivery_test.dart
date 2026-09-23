import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';

import '../../support/fake_relay_controller.dart';

/// A message sent at 04:49 was gone. The app drew a sent bubble and a typing
/// indicator that never resolved; the host had no run row and no log line. The
/// frame had reached a host that was not provisioned for the current controller
/// session, and that host dropped it with no run, no error and no word of any
/// kind — which looks exactly like a frame that never left the phone.
///
/// These are the app's half of the fix. A task now names itself with a
/// `task_id`, the host answers every one with a `task_ack`, and anything the
/// app has no ack for is re-sent with the SAME id, which the host dedupes. "No
/// ack" therefore means one thing only: it never arrived.
void main() {
  const String sessionKey = 'thread-1';
  late FakeRelayController controller;
  late Map<String, String> disk;
  late Map<String, List<Map<String, dynamic>>> transcript;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = sessionKey;

    disk = <String, String>{};
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.read = (String key) async => disk[key];
    AgentsTaskOutbox.write = (String key, String value) async =>
        disk[key] = value;
    AgentsTaskOutbox.delete = (String key) async => disk.remove(key);

    transcript = <String, List<Map<String, dynamic>>>{
      sessionKey: <Map<String, dynamic>>[
        <String, dynamic>{'sender': 'user', 'text': 'do the thing'},
      ],
    };
    AgentsQueuedMarks.readRows = (String key) => transcript[key];
    AgentsQueuedMarks.writeRows =
        (String key, List<Map<String, dynamic>> rows) async =>
            transcript[key] = rows;
  });

  tearDown(() async {
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsQueuedMarks.readRows = null;
    AgentsQueuedMarks.writeRows = null;
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await VerboseService.instance.setEnabled(false);
  });

  /// Starts one user message and returns the events the adapter yields for it.
  /// The subscription is left open so the test can feed acks into it.
  ({List<ChatStreamEvent> seen, Future<void> Function() cancel}) send() {
    final List<ChatStreamEvent> seen = <ChatStreamEvent>[];
    final sub = AgentsChatTransport.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
      reasoningEffort: 'low',
    ).listen(seen.add);
    return (seen: seen, cancel: () async => sub.cancel());
  }

  /// What the app has no `task_ack` for, in this thread.
  Future<List<PendingTask>> unacknowledged() =>
      AgentsPendingTasks.pendingFor(sessionKey);

  /// Stands in for the reconnect: sends everything still unacknowledged again,
  /// exactly as the thread view does on the transition into `paired`.
  Future<int> reconnectAndResend() =>
      AgentsPendingTasks.resend(sessionKey, (PendingTask task) async {
        await controller.sendTask(
          task.prompt,
          sessionKey: sessionKey,
          modelId: task.modelId,
          providerSlug: task.providerSlug,
          reasoningEffort: task.reasoningEffort,
          taskId: task.taskId,
        );
      });

  test('a task sent across a host restart arrives exactly once', () async {
    final out = send();
    await _drain();

    // One frame went out, it names itself, and the app knows it is unanswered.
    expect(controller.tasks, <String>['do the thing']);
    final String taskId = controller.taskIds.single!;
    expect(taskId, isNotEmpty);
    expect((await unacknowledged()).single.taskId, taskId);

    // The socket dies before any ack. Nothing comes back at all — which is
    // precisely the state the app could not see before.
    expect(out.seen, isEmpty);

    // The reconnect re-sends it, once, with the SAME id.
    expect(await reconnectAndResend(), 1);
    expect(controller.tasks, <String>['do the thing', 'do the thing']);
    expect(controller.taskIds, <String?>[taskId, taskId]);

    // The host had it all along and says so. A duplicate must paint NOTHING:
    // the answer is coming from the first attempt, and a second bubble here
    // would be this fix creating the duplicate it exists to prevent.
    controller.emit(
      AgentsRelayTaskAck(
        taskId: taskId,
        status: 'duplicate',
        sessionKey: sessionKey,
        runId: 'run-1',
      ),
    );
    await _drain();
    expect(out.seen, isEmpty);
    expect(await unacknowledged(), isEmpty);

    await out.cancel();
  });

  test(
    'every distinct send mints its own id, so no send is dedupe-swallowed',
    () async {
      // The host dedupes strictly: a second frame with an id it has already
      // taken is answered `duplicate` and is NOT run. A tool-loop pass, a
      // regenerate and a continue each come through as a real send that must
      // run, so sharing one id across them would leave the second one silently
      // undone — the very failure this mechanism exists to remove.
      final first = send();
      await _drain();
      final String firstId = controller.taskIds.single!;
      controller.emit(
        AgentsRelayTaskAck(
          taskId: firstId,
          status: 'accepted',
          sessionKey: sessionKey,
        ),
      );
      await _drain();
      await first.cancel();

      final second = send();
      await _drain();
      expect(controller.taskIds, hasLength(2));
      expect(controller.taskIds.last, isNot(firstId));
      await second.cancel();
    },
  );

  test(
    'an accepted ack before the reconnect means no re-send at all',
    () async {
      final out = send();
      await _drain();
      final String taskId = controller.taskIds.single!;

      controller.emit(
        AgentsRelayTaskAck(
          taskId: taskId,
          status: 'accepted',
          sessionKey: sessionKey,
          runId: 'run-1',
        ),
      );
      await _drain();

      // The host holds it, so there is nothing left to re-send.
      expect(await unacknowledged(), isEmpty);
      expect(await reconnectAndResend(), 0);
      expect(controller.tasks, <String>['do the thing']);
      expect(
        AgentsRunLedger.instance.runFor(sessionKey)?.taskAcknowledged,
        true,
      );

      await out.cancel();
    },
  );

  test('a task with no ack and no run surfaces as a failed send', () async {
    final AgentsRunLedger ledger = AgentsRunLedger.instance;
    final DateTime t0 = DateTime(2026, 9, 13, 4, 49);
    final List<String> resends = <String>[];
    ledger.onTaskUnacknowledged = resends.add;
    addTearDown(() => ledger.onTaskUnacknowledged = null);

    ledger.begin(sessionKey);
    ledger.taskSent(sessionKey, 'task-1', at: t0);

    // Nothing arrives: no ack, no heartbeat, no run. Well inside the window
    // the app waits — a slow round trip is not a lost frame.
    ledger.sweep(now: t0.add(const Duration(seconds: 3)));
    expect(resends, isEmpty);
    expect(ledger.isRunning(sessionKey), isTrue);

    // Past the window it is sent again rather than waited on, twice, and then
    // the thread says what happened instead of spinning for ever.
    ledger.sweep(now: t0.add(const Duration(seconds: 9)));
    ledger.sweep(now: t0.add(const Duration(seconds: 18)));
    expect(resends, <String>[sessionKey, sessionKey]);
    expect(ledger.isRunning(sessionKey), isTrue);

    ledger.sweep(now: t0.add(const Duration(seconds: 27)));
    final AgentsRun run = ledger.runFor(sessionKey)!;
    expect(run.running, isFalse);
    expect(run.outcome, AgentsRunOutcome.notDelivered);
    expect(run.endedWithoutAnswer, isTrue);
    expect(agentsRunEndNotice(run.outcome!), contains('did not reach'));
  });

  test('a heartbeat proves the task arrived, so it is never re-sent', () async {
    final AgentsRunLedger ledger = AgentsRunLedger.instance;
    final DateTime t0 = DateTime(2026, 9, 13, 4, 49);
    final List<String> resends = <String>[];
    ledger.onTaskUnacknowledged = resends.add;
    addTearDown(() => ledger.onTaskUnacknowledged = null);

    ledger.begin(sessionKey);
    ledger.taskSent(sessionKey, 'task-1', at: t0);
    // An old host sends heartbeats and no `task_ack`. That is proof enough:
    // the rule is the positively-detectable state, not a timer on the spinner.
    ledger.heartbeat(sessionKey);

    ledger.sweep(now: t0.add(const Duration(seconds: 30)));
    expect(resends, isEmpty);
    expect(ledger.isRunning(sessionKey), isTrue);
  });

  test(
    'a rejected ack clears the spinner and is retried after re-provisioning',
    () async {
      final out = send();
      await _drain();
      final String taskId = controller.taskIds.single!;

      controller.emit(
        AgentsRelayTaskAck(
          taskId: taskId,
          status: 'rejected',
          sessionKey: sessionKey,
          reason: 'not_provisioned',
        ),
      );
      await _drain();

      // The spinner goes: the run is over and the stream closed.
      expect(AgentsRunLedger.instance.isRunning(sessionKey), isFalse);
      expect(
        AgentsRunLedger.instance.runFor(sessionKey)?.outcome,
        AgentsRunOutcome.notDelivered,
      );
      final ErrorEvent error = out.seen.whereType<ErrorEvent>().single;
      expect(error.code, StreamErrorCodes.connectionLost);
      expect(error.message, contains('not signed in'));
      expect(out.seen.last, isA<DoneEvent>());

      // A frame the host refused is never blindly re-sent: re-sending it would
      // be refused for the same reason, for ever.
      expect(await unacknowledged(), isEmpty);
      expect(await reconnectAndResend(), 0);

      // It waits in the outbox instead, and the bubble offers Retry.
      final List<OutboxTask> queued = await AgentsTaskOutbox.pendingFor(
        sessionKey,
      );
      expect(queued.single.prompt, 'do the thing');
      expect(transcript[sessionKey]!.single['status'], 'failed');

      // The next pairing provisions the account and then flushes: the prompt
      // goes out without the user pressing anything.
      final int flushed = await AgentsTaskOutbox.flush(sessionKey, (
        OutboxTask task,
      ) async {
        await controller.sendTask(task.prompt, sessionKey: sessionKey);
      });
      expect(flushed, 1);
      expect(controller.tasks, <String>['do the thing', 'do the thing']);

      await out.cancel();
    },
  );
}

/// Lets the adapter's internal handler chain settle.
Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
