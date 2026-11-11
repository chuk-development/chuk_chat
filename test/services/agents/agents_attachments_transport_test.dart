import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_attachments.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/agents/agents_outbox_flusher.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';

import '../../support/fake_relay_controller.dart';

/// The Agents send with files (docs/WIRE_CONTRACT.md, "Attachments to
/// Agents"): every file is uploaded first, the task names them by `blob_id`
/// only once each one is complete, a too-big selection sends nothing, an
/// `unknown attachment` refusal uploads again once, and a queued prompt keeps
/// its files until the flush uploads them.
void main() {
  const String sessionKey = 'thread-files';
  late FakeRelayController controller;
  late Map<String, String> disk;
  late List<Map<String, dynamic>> puts;
  late int completeAcks;
  late List<int> completeAtTask;

  Future<void> drain() async {
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    controller = FakeRelayController();
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
    AgentsRelayLink.instance.bind(controller);

    disk = <String, String>{};
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.read = (String key) async => disk[key];
    AgentsTaskOutbox.write = (String key, String value) async =>
        disk[key] = value;
    AgentsTaskOutbox.delete = (String key) async => disk.remove(key);
    AgentsQueuedMarks.readRows = (String key) => <Map<String, dynamic>>[];
    AgentsQueuedMarks.writeRows = (_, _) async {};

    puts = <Map<String, dynamic>>[];
    completeAcks = 0;
    completeAtTask = <int>[];
    // The local copies: 300 KiB per path, named after it.
    AgentsAttachmentPaths.readerOverride = (String path, int index) async =>
        AgentsOutgoingAttachment(
          name: '$path.bin',
          mime: 'application/octet-stream',
          bytes: Uint8List(300 * 1024),
          localPath: path,
        );
    // The host: acks every chunk; the last one completes the file.
    final Map<String, Set<int>> got = <String, Set<int>>{};
    AgentsAttachmentPaths.senderOverride = (Map<String, dynamic> f) async {
      puts.add(f);
      scheduleMicrotask(() {
        final Set<int> have = got.putIfAbsent(
          f['upload_id'] as String,
          () => <int>{},
        )..add(f['index'] as int);
        final bool complete = have.length == f['count'];
        if (complete) completeAcks++;
        AgentsReplyFrames.instance.add(<String, dynamic>{
          'type': 'attachment_ack',
          'ok': true,
          'upload_id': f['upload_id'],
          'index': f['index'],
          'received': have.length,
          'count': f['count'],
          'complete': complete,
          if (complete) 'blob_id': f['upload_id'],
        });
      });
    };
  });

  tearDown(() async {
    AgentsAttachmentPaths.readerOverride = null;
    AgentsAttachmentPaths.senderOverride = null;
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsQueuedMarks.readRows = null;
    AgentsQueuedMarks.writeRows = null;
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
  });

  List<ChatStreamEvent> send(List<String> paths) {
    final List<ChatStreamEvent> seen = <ChatStreamEvent>[];
    final StreamSubscription<ChatStreamEvent> sub =
        AgentsChatTransport.sendStreamingChat(
          accessToken: 't',
          message: 'what is on these?',
          modelId: 'm',
          providerSlug: 'p',
          images: paths,
          chatId: sessionKey,
          modelSelectionCaptured: true,
        ).listen(seen.add);
    addTearDown(sub.cancel);
    return seen;
  }

  test('the task names the files only after every upload completed', () async {
    controller.taskError = null;
    // Note how many files were complete when the task frame went out.
    final StreamSubscription<void> watch = Stream<void>.periodic(Duration.zero)
        .listen((_) {
          if (controller.tasks.isNotEmpty && completeAtTask.isEmpty) {
            completeAtTask.add(completeAcks);
          }
        });
    addTearDown(watch.cancel);
    send(<String>['offline://img/u/a', 'agents-att://u/b']);
    await drain();

    expect(controller.tasks, <String>['what is on these?']);
    // 300 KiB = 2 chunks per file, 2 files.
    expect(puts, hasLength(4));
    final List<String> blobIds = puts
        .map((f) => f['upload_id'] as String)
        .toSet()
        .toList();
    expect(controller.taskAttachments.single, blobIds);
    expect(completeAcks, 2);
    expect(completeAtTask, isNot(contains(lessThan(2))));
  });

  test('a send with no files carries no attachments', () async {
    send(const <String>[]);
    await drain();
    expect(puts, isEmpty);
    expect(controller.taskAttachments.single, isEmpty);
  });

  test('more than ten files: nothing goes out, the user is told', () async {
    final List<AgentsSendNotice> notices = <AgentsSendNotice>[];
    final StreamSubscription<AgentsSendNotice> sub = AgentsChatTransport.notices
        .listen(notices.add);
    addTearDown(sub.cancel);
    final List<ChatStreamEvent> seen = send(
      List<String>.generate(11, (i) => 'agents-att://u/f$i'),
    );
    await drain();
    expect(puts, isEmpty);
    expect(controller.tasks, isEmpty);
    expect(notices.single.kind, AgentsSendNoticeKind.attachmentsRefused);
    expect(notices.single.failure, AgentsAttachmentFailure.tooMany);
    expect(seen.whereType<ErrorEvent>(), isNotEmpty);
    expect(seen.whereType<DoneEvent>(), isNotEmpty);
    expect(await AgentsTaskOutbox.pendingFor(sessionKey), isEmpty);
  });

  test('a file over 25 MB: nothing goes out', () async {
    AgentsAttachmentPaths.readerOverride = (String path, int index) async =>
        AgentsOutgoingAttachment(
          name: 'movie.mov',
          mime: 'video/quicktime',
          bytes: Uint8List(kAgentsAttachmentMaxBytes + 1),
        );
    final List<ChatStreamEvent> seen = send(<String>['agents-att://u/m']);
    await drain();
    expect(puts, isEmpty);
    expect(controller.tasks, isEmpty);
    expect(seen.whereType<ErrorEvent>().single.message, contains('25 MB'));
  });

  test('unknown attachment: upload again and resend once', () async {
    send(<String>['agents-att://u/a']);
    await drain();
    expect(controller.tasks, hasLength(1));
    final String? firstId = controller.taskIds.single;

    controller.emit(
      const AgentsRelayRunError(
        "attachments: unknown attachment 'x': upload it again",
        sessionKey: sessionKey,
      ),
    );
    await drain();
    expect(controller.tasks, hasLength(2));
    expect(controller.taskIds.last, isNot(firstId));
    expect(puts.map((f) => f['upload_id']).toSet(), hasLength(2));
    expect(controller.taskAttachments.last.single, puts.last['upload_id']);

    // A second refusal ends the turn; no third send.
    controller.emit(
      const AgentsRelayRunError(
        "attachments: unknown attachment 'y': upload it again",
        sessionKey: sessionKey,
      ),
    );
    await drain();
    expect(controller.tasks, hasLength(2));
  });

  test('no host: the prompt is queued with its files, the flush uploads '
      'them first', () async {
    AgentsRelayLink.instance.reset();
    send(<String>['offline://img/u/a']);
    await drain();
    final List<OutboxTask> queued = await AgentsTaskOutbox.pendingFor(
      sessionKey,
    );
    expect(queued.single.attachments, <String>['offline://img/u/a']);
    expect(puts, isEmpty);

    // The outbox row survives a round trip through its stored form.
    final OutboxTask? again = OutboxTask.fromJson(queued.single.toJson());
    expect(again?.attachments, <String>['offline://img/u/a']);

    await AgentsOutboxFlusher.sendQueued(controller, queued.single);
    expect(puts, hasLength(2));
    expect(controller.taskAttachments.single, <String>[
      puts.first['upload_id'] as String,
    ]);
    final List<PendingTask> pending = await AgentsPendingTasks.pendingFor(
      sessionKey,
    );
    expect(pending.single.blobIds, controller.taskAttachments.single);
  });

  test('a flush whose link cannot carry frames is deferred', () async {
    AgentsAttachmentPaths.senderOverride = (_) async =>
        throw StateError('down');
    final OutboxTask task = await AgentsTaskOutbox.enqueue(
      sessionKey: sessionKey,
      prompt: 'p',
      attachments: const <String>['agents-att://u/a'],
    );
    await expectLater(
      AgentsOutboxFlusher.sendQueued(controller, task),
      throwsA(isA<OutboxSendDeferred>()),
    );
    expect(controller.tasks, isEmpty);
  });

  test(
    'a queued prompt whose file is gone fails at once and says why',
    () async {
      // Review of b8e3343c, finding 7: a user-fixable upload error is not
      // retried until the attempts run out.
      AgentsAttachmentPaths.readerOverride = (String path, int index) async =>
          throw AgentsAttachmentException(
            AgentsAttachmentFailure.missing,
            name: path,
          );
      final List<AgentsSendNotice> notices = <AgentsSendNotice>[];
      final sub = AgentsChatTransport.notices.listen(notices.add);
      addTearDown(sub.cancel);
      final OutboxTask task = await AgentsTaskOutbox.enqueue(
        sessionKey: sessionKey,
        prompt: 'p',
        attachments: const <String>['agents-att://u/gone'],
      );
      final OutboxTask behind = await AgentsTaskOutbox.enqueue(
        sessionKey: sessionKey,
        prompt: 'no files',
      );
      final int sent = await AgentsTaskOutbox.flush(
        sessionKey,
        (OutboxTask t) => AgentsOutboxFlusher.sendQueued(controller, t),
      );
      await drain();
      // The prompt behind it still went out.
      expect(sent, 1);
      expect(controller.tasks, <String>['no files']);
      final List<OutboxTask> left = await AgentsTaskOutbox.pendingFor(
        sessionKey,
      );
      final OutboxTask failed = left.singleWhere(
        (OutboxTask t) => t.localId == task.localId,
      );
      expect(failed.failed, isTrue);
      expect(failed.attempts, 1);
      expect(
        left.where((OutboxTask t) => t.localId == behind.localId),
        isEmpty,
      );
      expect(notices.single.kind, AgentsSendNoticeKind.attachmentsRefused);
      expect(notices.single.failure, AgentsAttachmentFailure.missing);
      expect(notices.single.sessionKey, sessionKey);
      expect(puts, isEmpty);
    },
  );
}
