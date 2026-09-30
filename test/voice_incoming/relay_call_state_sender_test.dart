// The state sender: straight out when the host is attached, queued (in
// order) while it is not, and sent once it is back.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';
import 'package:chuk_chat/voice/incoming/relay_call_state_sender.dart';

class _Transport implements AgentsRelayController, AgentsVoiceCallControl {
  final ValueNotifier<AgentsRelayState> _state =
      ValueNotifier<AgentsRelayState>(
        const AgentsRelayState(phase: AgentsRelayPhase.idle),
      );
  final List<(String, String)> sent = <(String, String)>[];
  bool fail = false;

  @override
  ValueListenable<AgentsRelayState> get state => _state;

  void pair() =>
      _state.value = const AgentsRelayState(phase: AgentsRelayPhase.paired);
  void drop() =>
      _state.value = const AgentsRelayState(phase: AgentsRelayPhase.closed);

  @override
  Future<void> sendVoiceCallState({
    required String callId,
    required String state,
  }) async {
    if (fail) throw StateError('Not paired');
    sent.add((callId, state));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A paired transport that is an [AgentsRelayController] but NOT an
/// [AgentsVoiceCallControl] (an older client, a fake).
class _PlainTransport implements AgentsRelayController {
  final ValueNotifier<AgentsRelayState> _state =
      ValueNotifier<AgentsRelayState>(
        const AgentsRelayState(phase: AgentsRelayPhase.paired),
      );

  @override
  ValueListenable<AgentsRelayState> get state => _state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ValueNotifier<AgentsRelayController?> link;
  late RelayCallStateSender sender;

  setUp(() {
    link = ValueNotifier<AgentsRelayController?>(null);
    sender = RelayCallStateSender(
      controller: link,
      retryAfter: const Duration(hours: 1),
    );
  });

  tearDown(() => sender.dispose());

  test('sends at once over a paired transport', () async {
    final _Transport t = _Transport()..pair();
    link.value = t;
    await sender.send('c1', AgentsVoiceCallFrames.accepted);
    expect(t.sent, <(String, String)>[('c1', 'accepted')]);
    expect(sender.queued, 0);
  });

  test('queues without a transport and sends in order once paired', () async {
    await sender.send('c1', AgentsVoiceCallFrames.accepted);
    await sender.send('c1', AgentsVoiceCallFrames.ended);
    expect(sender.queued, 2);

    final _Transport t = _Transport();
    link.value = t;
    await pumpEventQueue();
    expect(t.sent, isEmpty);

    t.pair();
    await pumpEventQueue();
    expect(t.sent, <(String, String)>[('c1', 'accepted'), ('c1', 'ended')]);
    expect(sender.queued, 0);
  });

  test('a failed send stays queued for the next attach', () async {
    final _Transport t = _Transport()
      ..pair()
      ..fail = true;
    link.value = t;
    await sender.send('c1', AgentsVoiceCallFrames.declined);
    expect(sender.queued, 1);

    t
      ..fail = false
      ..drop()
      ..pair();
    await pumpEventQueue();
    expect(t.sent, <(String, String)>[('c1', 'declined')]);
    expect(sender.queued, 0);
  });

  test(
    'a paired transport without the voice-call control keeps it queued',
    () async {
      final _PlainTransport t = _PlainTransport();
      link.value = t;
      await pumpEventQueue();
      await sender.send('c1', AgentsVoiceCallFrames.accepted);
      await pumpEventQueue();
      expect(t.state.value.isPaired, isTrue);
      expect(sender.queued, 1);

      // A transport that can carry it takes the queue over.
      final _Transport voice = _Transport()..pair();
      link.value = voice;
      await pumpEventQueue();
      expect(voice.sent, <(String, String)>[('c1', 'accepted')]);
      expect(sender.queued, 0);
    },
  );
}
