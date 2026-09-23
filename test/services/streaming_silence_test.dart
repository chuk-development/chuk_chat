// A slow answer is not an error — in an Agents build.
//
// `StreamingManager` used to arm a flat 60-second idle timer: no event of any
// kind for a minute and it tore the stream down with "No response received —
// the server may be overloaded. Please try again." Nothing was wrong. On this
// user's own host, turns carrying 170k–290k prompt tokens run 405 s, 490 s,
// 631 s, 818 s and 1851 s end to end, and a provider sends nothing at all until
// the prefill is done — so the app was killing working runs and telling the
// user a story it had no evidence for.
//
// These tests pin the two halves of the fix: silence ends nothing, and a real
// failure still ends the stream at once.
//
// The clock is driven, never waited on: `tester.pump(duration)` advances the
// binding's fake clock, so "thirty minutes of silence" costs no wall time.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/streaming_manager_io.dart';

/// One run under test: the input the host would write to, and everything the
/// manager handed back.
class _Rig {
  _Rig(this.chatId);

  final String chatId;
  final StreamController<ChatStreamEvent> input =
      StreamController<ChatStreamEvent>();
  final StreamingManager manager = StreamingManager();
  final List<String> updates = <String>[];
  final List<String> completions = <String>[];
  final List<String> errors = <String>[];
  final List<String?> errorCodes = <String?>[];

  Future<void> start() => manager.startStream(
    chatId: chatId,
    messageIndex: 0,
    stream: input.stream,
    onUpdate: (String content, String reasoning) => updates.add(content),
    onComplete: (String content, String reasoning, double? tps) =>
        completions.add(content),
    onError: (String message, {String? code}) {
      errors.add(message);
      errorCodes.add(code);
    },
  );

  /// Winds the run down inside the test's fake time.
  ///
  /// Nothing here is awaited directly: a future that completes on a microtask
  /// of the fake zone only resumes when that zone is pumped, so awaiting one
  /// straight from the test body deadlocks. `pump` is what drives it.
  Future<void> dispose(WidgetTester tester) async {
    unawaited(manager.cancelStream(chatId));
    if (!input.isClosed) unawaited(input.close());
    await tester.pump();
  }
}

void main() {
  // This is the Agents behaviour. Tests run with FEATURE_AGENTS off, where the
  // upstream 60-second idle timeout applies (streaming_idle_timeout_test.dart),
  // so the silence watch is switched on through the manager's test seam.
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);

  testWidgets('silence ends nothing, however long it lasts', (tester) async {
    final rig = _Rig('silent-prefill');
    await rig.start();

    // Thirty minutes with not one frame: longer than the slowest turn measured
    // on the host, and thirty times the old timeout.
    await tester.pump(const Duration(minutes: 30));

    expect(rig.errors, isEmpty, reason: 'silence is not evidence of failure');
    expect(rig.completions, isEmpty, reason: 'nothing has been answered yet');
    expect(rig.manager.isStreaming(rig.chatId), isTrue);

    // And the answer still lands when the host finally has one.
    rig.input.add(const ContentEvent('at last'));
    rig.input.add(const DoneEvent());
    await tester.pump();

    expect(rig.errors, isEmpty);
    expect(rig.completions, <String>['at last']);
    await rig.dispose(tester);
  });

  testWidgets('a heartbeat keeps a silent run alive and shows nothing', (
    tester,
  ) async {
    final rig = _Rig('heartbeat-only');
    await rig.start();

    // Ten minutes of a host saying "still working" every ten seconds.
    for (var seq = 1; seq <= 60; seq++) {
      rig.input.add(HeartbeatEvent(seq: seq, elapsedSeconds: seq * 10.0));
      await tester.pump(const Duration(seconds: 10));
    }

    expect(rig.errors, isEmpty);
    expect(rig.completions, isEmpty);
    // Proof of life, not content: nothing was buffered and nothing was drawn.
    expect(rig.updates, isEmpty);
    expect(rig.manager.getBufferedContent(rig.chatId), isNull);
    // The one thing it does change is honest and already in the model: the
    // host answered, so the header stops saying "Connecting".
    expect(rig.manager.phaseOf(rig.chatId), StreamPhase.processing);
    await rig.dispose(tester);
  });

  testWidgets('a heartbeat never pulls the phase backwards', (tester) async {
    final rig = _Rig('heartbeat-midstream');
    await rig.start();

    rig.input.add(const ContentEvent('writing now'));
    await tester.pump();
    expect(rig.manager.phaseOf(rig.chatId), StreamPhase.writing);

    rig.input.add(const HeartbeatEvent(seq: 1));
    await tester.pump(const Duration(minutes: 5));

    expect(rig.manager.phaseOf(rig.chatId), StreamPhase.writing);
    expect(rig.errors, isEmpty);
    expect(rig.completions, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('partial content survives a long silence and completes', (
    tester,
  ) async {
    final rig = _Rig('partial-content');
    await rig.start();

    rig.input.add(const ContentEvent('half an answer'));
    await tester.pump(const Duration(minutes: 20));

    expect(rig.errors, isEmpty);
    expect(rig.completions, isEmpty, reason: 'the run has not ended yet');
    expect(rig.manager.getBufferedContent(rig.chatId), 'half an answer');

    // The stream closing without a done is what completes it, and it completes
    // with every character that had arrived.
    unawaited(rig.input.close());
    await tester.pump();

    expect(rig.completions, <String>['half an answer']);
    expect(rig.errors, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('a dropped socket still errors at once', (tester) async {
    final rig = _Rig('socket-drop');
    await rig.start();

    rig.input.addError(Exception('socket closed'));
    await tester.pump();

    expect(rig.errors, hasLength(1));
    expect(rig.errorCodes, <String?>[StreamErrorCodes.streamFailure]);
    expect(rig.manager.isStreaming(rig.chatId), isFalse);
    await rig.dispose(tester);
  });

  testWidgets('an error frame from the host still errors at once', (
    tester,
  ) async {
    final rig = _Rig('error-frame');
    await rig.start();

    rig.input.add(
      const ErrorEvent(
        'the model rejected the request',
        code: StreamErrorCodes.upstreamStatus,
      ),
    );
    await tester.pump();

    expect(rig.errors, <String>['the model rejected the request']);
    expect(rig.errorCodes, <String?>[StreamErrorCodes.upstreamStatus]);
    expect(rig.manager.isStreaming(rig.chatId), isFalse);
    await rig.dispose(tester);
  });

  testWidgets('no local failure ever claims the server is overloaded', (
    tester,
  ) async {
    final rig = _Rig('no-guessing');
    await rig.start();
    await tester.pump(const Duration(minutes: 45));
    expect(
      rig.errors.where((e) => e.toLowerCase().contains('overloaded')),
      isEmpty,
    );
    await rig.dispose(tester);
  });
}
