import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_task_delegates.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// A sender that records what it was asked and lets the test finish each
/// turn by hand, in any order.
class _FakeSender {
  final List<String> sent = <String>[];
  final List<Completer<VoiceTurnOutcome>> turns =
      <Completer<VoiceTurnOutcome>>[];

  Future<VoiceTurnOutcome> call(String text) {
    sent.add(text);
    final Completer<VoiceTurnOutcome> c = Completer<VoiceTurnOutcome>();
    turns.add(c);
    return c.future;
  }
}

void main() {
  for (final (String name, VoiceTurnDelegate Function(VoiceTaskSender) make)
      in <(String, VoiceTurnDelegate Function(VoiceTaskSender))>[
        ('ChatVoiceDelegate', ChatVoiceDelegate.new),
        ('AgentsVoiceDelegate', AgentsVoiceDelegate.new),
      ]) {
    group(name, () {
      test('returns an id at once, before the turn ends', () async {
        final _FakeSender sender = _FakeSender();
        final VoiceTurnDelegate delegate = make(sender.call);
        final String id = await delegate.startTask('add milk');
        expect(id, isNotEmpty);
        expect(sender.sent, <String>['${kVoiceTaskMarker}add milk']);
        expect(sender.turns.single.isCompleted, isFalse);
        expect(delegate.openTasks, 1);
        await delegate.dispose();
      });

      test('maps each result to its own task id, in any order', () async {
        final _FakeSender sender = _FakeSender();
        final VoiceTurnDelegate delegate = make(sender.call);
        final List<VoiceTaskResult> results = <VoiceTaskResult>[];
        final StreamSubscription<VoiceTaskResult> sub = delegate.results
            .listen(results.add);

        final String first = await delegate.startTask('first');
        final String second = await delegate.startTask('second');
        final String third = await delegate.startTask('third');
        expect(<String>{first, second, third}, hasLength(3));

        sender.turns[1].complete(const VoiceTurnOutcome.done('two'));
        sender.turns[2].complete(const VoiceTurnOutcome.failed('boom'));
        sender.turns[0].complete(const VoiceTurnOutcome.done('one'));
        await pumpEventQueue();

        expect(
          <String, String>{for (final r in results) r.taskId: r.result},
          <String, String>{first: 'one', second: 'two', third: 'boom'},
        );
        expect(
          <String, String>{for (final r in results) r.taskId: r.status},
          <String, String>{
            first: VoiceTaskResult.statusDone,
            second: VoiceTaskResult.statusDone,
            third: VoiceTaskResult.statusFailed,
          },
        );
        expect(delegate.openTasks, 0);
        await sub.cancel();
        await delegate.dispose();
      });

      test('an empty task fails without a send', () async {
        final _FakeSender sender = _FakeSender();
        final VoiceTurnDelegate delegate = make(sender.call);
        final Future<VoiceTaskResult> next = delegate.results.first;
        final String id = await delegate.startTask('   ');
        final VoiceTaskResult result = await next;
        expect(result.taskId, id);
        expect(result.status, VoiceTaskResult.statusFailed);
        expect(sender.sent, isEmpty);
        await delegate.dispose();
      });

      test('a throwing sender reports failed', () async {
        final VoiceTurnDelegate delegate = make(
          (String _) => Future<VoiceTurnOutcome>.error(StateError('x')),
        );
        final Future<VoiceTaskResult> next = delegate.results.first;
        final String id = await delegate.startTask('go');
        final VoiceTaskResult result = await next;
        expect(result.taskId, id);
        expect(result.status, VoiceTaskResult.statusFailed);
        await delegate.dispose();
      });

      test('dispose reports open tasks as failed before the stream closes, '
          'and drops their late answers', () async {
        final _FakeSender sender = _FakeSender();
        final VoiceTurnDelegate delegate = make(sender.call);
        final List<Object> events = <Object>[];
        delegate.results.listen(events.add, onDone: () => events.add('done'));
        final String a = await delegate.startTask('a');
        final String b = await delegate.startTask('b');
        await delegate.dispose();
        sender.turns[0].complete(const VoiceTurnOutcome.done('late'));
        await pumpEventQueue();
        expect(events, hasLength(3));
        expect(events.last, 'done');
        final List<VoiceTaskResult> results = events
            .whereType<VoiceTaskResult>()
            .toList();
        expect(results.map((r) => r.taskId), <String>[a, b]);
        expect(
          results.map((r) => r.status),
          everyElement(VoiceTaskResult.statusFailed),
        );
        expect(results.first.result, kVoiceTaskChatClosed);
        expect(delegate.openTasks, 0);
      });

      test('failOpenTasks reaches the listener at once (sync stream)', () async {
        final _FakeSender sender = _FakeSender();
        final VoiceTurnDelegate delegate = make(sender.call);
        final List<VoiceTaskResult> results = <VoiceTaskResult>[];
        final StreamSubscription<VoiceTaskResult> sub = delegate.results
            .listen(results.add);
        await delegate.startTask('a');
        delegate.failOpenTasks('gone');
        // Delivered before any await: a detach right after cannot lose it.
        expect(results.single.result, 'gone');
        await sub.cancel();
        await delegate.close();
      });

      test('startTask after close throws a StateError', () async {
        final VoiceTurnDelegate delegate = make(_FakeSender().call);
        await delegate.dispose();
        expect(delegate.isClosed, isTrue);
        await expectLater(delegate.startTask('x'), throwsStateError);
      });
    });
  }

  test('ids of the two delegates never collide', () async {
    final _FakeSender sender = _FakeSender();
    final String a = await ChatVoiceDelegate(sender.call).startTask('x');
    final String b = await AgentsVoiceDelegate(sender.call).startTask('x');
    expect(a, isNot(b));
    expect(a, startsWith('chat-'));
    expect(b, startsWith('agents-'));
  });
}
