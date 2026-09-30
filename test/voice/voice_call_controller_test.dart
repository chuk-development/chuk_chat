import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/voice/voice_call.dart';
import 'package:chuk_chat/voice/voice_location.dart';

class _FakeDelegate implements VoiceTaskDelegate {
  int _next = 0;
  final StreamController<VoiceTaskResult> controller =
      StreamController<VoiceTaskResult>.broadcast();

  @override
  Future<String> startTask(String task) async => 'task-${++_next}';

  @override
  Stream<VoiceTaskResult> get results => controller.stream;
}

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the flag is off by default and the call is not offered', () {
    // Tests run without --dart-define: the default build.
    expect(kFeatureVoiceCall, isFalse);
    expect(VoiceCallService.tokenUrl, isEmpty);
    expect(VoiceCallService.isAvailable, isFalse);
  });

  test('instance is one controller app-wide', () {
    expect(
      identical(VoiceCallController.instance, VoiceCallController.instance),
      isTrue,
    );
  });

  test('start without a configured token server fails cleanly', () async {
    final VoiceCallController c = VoiceCallController.forTesting();
    final List<VoiceCallPhase> phases = <VoiceCallPhase>[];
    final StreamSubscription<VoiceCallPhase> sub = c.phaseChanges.listen(
      phases.add,
    );
    final List<VoiceCallRecord> ended = <VoiceCallRecord>[];
    final StreamSubscription<VoiceCallRecord> endSub = c.onCallEnded.listen(
      ended.add,
    );

    await c.start(chatId: 'chat-1', mode: VoiceCallMode.chat);
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceCallPhase.failed);
    expect(c.error, 'Voice calls are not set up in this build');
    expect(c.isActive, isFalse);
    expect(c.chatId, 'chat-1');
    expect(c.mode, VoiceCallMode.chat);
    expect(phases, <VoiceCallPhase>[
      VoiceCallPhase.connecting,
      VoiceCallPhase.ending,
      VoiceCallPhase.failed,
    ]);
    // Nothing was said: no record, no event.
    expect(ended, isEmpty);
    expect(await c.end(), isNull);

    c.dismiss();
    expect(c.phase, VoiceCallPhase.idle);
    expect(c.error, isNull);

    await sub.cancel();
    await endSub.cancel();
    c.dispose();
  });

  test('mute before a room exists is kept as the choice', () async {
    final VoiceCallController c = VoiceCallController.forTesting();
    int notified = 0;
    c.addListener(() => notified++);
    await c.setMicMuted(true);
    expect(c.micMuted, isTrue);
    expect(notified, 1);
    await c.setMicMuted(true);
    expect(notified, 1);
    c.dispose();
  });

  test('speaker switching is a no-op off the phone', () async {
    final VoiceCallController c = VoiceCallController.forTesting();
    expect(c.canSwitchSpeaker, isFalse);
    final bool before = c.speakerOn;
    await c.setSpeakerOn(!before);
    expect(c.speakerOn, before);
    c.dispose();
  });

  group('delegate lifecycle', () {
    const Duration tick = Duration(milliseconds: 1);

    test('detachDelegate: no delegate after, open tasks fail', () async {
      final List<VoiceTaskResult> sent = <VoiceTaskResult>[];
      final VoiceCallController c = VoiceCallController.forTesting(
        sendResult: (VoiceTaskResult r) async {
          sent.add(r);
          return true;
        },
        resultBackoff: const <Duration>[tick, tick, tick],
      );
      final _FakeDelegate delegate = _FakeDelegate();
      c.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        delegate: delegate,
      );

      expect(
        _json(await c.debugHandleDelegateRpc('{"task":"a"}'))['task_id'],
        'task-1',
      );
      await c.debugHandleDelegateRpc('{"task":"b"}');
      expect(c.debugPendingTasks, <String>{'task-1', 'task-2'});

      // task-1 finishes on its own before the chat closes.
      delegate.controller.add(
        const VoiceTaskResult(taskId: 'task-1', status: 'done', result: 'ok'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent.single.taskId, 'task-1');

      // Another chat's delegate does not touch this call.
      c.detachDelegate(_FakeDelegate());
      expect(c.debugPendingTasks, <String>{'task-2'});

      c.detachDelegate(delegate);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent, hasLength(2));
      expect(sent.last.taskId, 'task-2');
      expect(sent.last.status, 'failed');
      expect(sent.last.result, 'the chat was closed');
      expect(c.debugPendingTasks, isEmpty);

      expect(
        _json(await c.debugHandleDelegateRpc('{"task":"c"}')),
        <String, dynamic>{'error': 'no delegate'},
      );

      // A late result from the closed chat is not forwarded.
      delegate.controller.add(
        const VoiceTaskResult(taskId: 'task-2', status: 'done', result: 'x'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent, hasLength(2));
      c.dispose();
    });

    test('a result is retried until the RPC goes through', () async {
      int attempts = 0;
      final VoiceCallController c = VoiceCallController.forTesting(
        sendResult: (_) async => ++attempts == 3,
        resultBackoff: const <Duration>[tick, tick, tick],
      );
      final _FakeDelegate delegate = _FakeDelegate();
      c.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        delegate: delegate,
      );
      await c.debugHandleDelegateRpc('{"task":"a"}');
      delegate.controller.add(
        const VoiceTaskResult(taskId: 'task-1', status: 'done', result: 'ok'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(attempts, 3);
      c.dispose();
    });

    test('retries stop at three and never run once the call ended', () async {
      int attempts = 0;
      final VoiceCallController c = VoiceCallController.forTesting(
        sendResult: (_) async {
          attempts++;
          return false;
        },
        resultBackoff: const <Duration>[tick, tick, tick],
      );
      final _FakeDelegate delegate = _FakeDelegate();
      c.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        delegate: delegate,
      );
      delegate.controller.add(
        const VoiceTaskResult(taskId: 't', status: 'done', result: 'ok'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(attempts, 4, reason: 'one try and three retries');

      c.debugSetState(phase: VoiceCallPhase.ended, chatId: 'c1');
      attempts = 0;
      c.detachDelegate(delegate); // already dropped by the reset: no-op
      expect(attempts, 0);
      c.dispose();
    });
  });

  test('get_location goes through the resolver', () async {
    final VoiceCallController c = VoiceCallController.forTesting(
      location: VoiceLocationResolver(
        checkPermission: () async => VoiceLocationPermission.deniedForever,
        fetch: () async => <String, dynamic>{},
      ),
    );
    expect(_json(await c.debugHandleLocationRpc()), <String, dynamic>{
      'error': 'permission denied',
    });
    c.dispose();
  });

  test('the call hangs up at the length limit', () async {
    expect(VoiceCallController.maxCallDuration, const Duration(minutes: 60));
    final VoiceCallController c = VoiceCallController.forTesting();
    c.debugSetState(phase: VoiceCallPhase.live, chatId: 'c1');
    c.debugArmCallLimit(const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.phase, VoiceCallPhase.ended);
    c.dispose();
  });
}
