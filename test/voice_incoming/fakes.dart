// Fakes of the incoming-call service's seams (lib/voice/incoming/
// incoming_call_ports.dart). Pure Dart: no plugin, no platform channel.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';

import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// A frame as the host sends it.
Map<String, dynamic> incomingFrame({
  String callId = '3f2a9c1d0b7e4a55',
  String threadId = 'local:crypto-desk:1:74112',
  String agentName = 'Crypto Desk',
  String reason = 'Your pizza is ready to come out of the oven.',
  String urgency = 'normal',
  required DateTime expiresAt,
  num? ringSeconds,
}) => <String, dynamic>{
  'type': 'voice_call_incoming',
  'call_id': callId,
  'thread_id': threadId,
  'agent_id': 'local:crypto-desk:1:74112',
  'agent_name': agentName,
  'reason': reason,
  'urgency': urgency,
  'expires_at': expiresAt.millisecondsSinceEpoch / 1000,
  'ring_seconds': ?ringSeconds,
};

Map<String, dynamic> stateFrame(String callId, String state) =>
    <String, dynamic>{
      'type': 'voice_call_state',
      'call_id': callId,
      'state': state,
    };

class FakeCallkit implements CallkitPort {
  final StreamController<CallkitSignal> controller =
      StreamController<CallkitSignal>.broadcast(sync: true);
  final List<CallKitParams> shown = <CallKitParams>[];
  final List<CallKitParams> missed = <CallKitParams>[];
  final List<CallKitParams> started = <CallKitParams>[];
  final List<String> connected = <String>[];
  final List<String> ended = <String>[];

  /// Whether [end] answers with the plugin's own event. On by default, as on
  /// the device.
  bool echoOnEnd = true;

  @override
  Stream<CallkitSignal> get signals => controller.stream;

  /// Calls the plugin counts as accepted: answered, or started by the user.
  final Set<String> _accepted = <String>{};

  void emit(CallkitSignalKind kind, String id) {
    if (kind == CallkitSignalKind.accept) _accepted.add(id);
    controller.add(CallkitSignal(kind, id));
  }

  @override
  Future<void> showIncoming(CallKitParams params) async => shown.add(params);

  @override
  Future<void> showMissed(CallKitParams params) async => missed.add(params);

  @override
  Future<void> startOutgoing(CallKitParams params) async {
    started.add(params);
    _accepted.add(params.id);
  }

  @override
  Future<void> setConnected(String id) async => connected.add(id);

  /// Like the plugin: ending an accepted (or started) call answers with an
  /// `ended` event, ending a ringing one with a `decline` event.
  @override
  Future<void> end(String id) async {
    ended.add(id);
    if (!echoOnEnd) return;
    // The plugin answers through a broadcast receiver: later, not inside
    // this call.
    if (_accepted.remove(id)) {
      scheduleMicrotask(
        () => controller.add(CallkitSignal(CallkitSignalKind.ended, id)),
      );
    } else if (shown.any((CallKitParams p) => p.id == id)) {
      scheduleMicrotask(
        () => controller.add(CallkitSignal(CallkitSignalKind.decline, id)),
      );
    }
  }
}

/// The microphone permission, as the test sets it. [pending] holds the
/// answer of [request] until the test completes it.
class FakeMic implements MicPermission {
  FakeMic({this.granted = true, this.grantOnRequest = true});

  bool granted;
  bool grantOnRequest;
  int requests = 0;
  Completer<bool>? pending;

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<bool> request() async {
    requests++;
    final Completer<bool>? hold = pending;
    final bool answer = hold == null ? grantOnRequest : await hold.future;
    granted = answer;
    return answer;
  }
}

class FakeSender implements CallStateSender {
  final List<(String, String)> sent = <(String, String)>[];

  @override
  Future<void> send(String callId, String state) async =>
      sent.add((callId, state));
}

class FakeUi implements OngoingCallUi {
  final StreamController<OngoingCallAction> controller =
      StreamController<OngoingCallAction>.broadcast(sync: true);
  final List<OngoingCallSnapshot> shown = <OngoingCallSnapshot>[];
  final List<String> cancelled = <String>[];
  int unlocks = 0;
  final List<String> notices = <String>[];

  @override
  Stream<OngoingCallAction> get actions => controller.stream;

  @override
  Future<void> show(OngoingCallSnapshot snapshot) async => shown.add(snapshot);

  @override
  Future<void> cancel(String callKey) async => cancelled.add(callKey);

  @override
  Future<void> requestUnlock() async => unlocks++;

  @override
  Future<void> notice(String text) async => notices.add(text);
}

/// The app-wide call, driven by the test.
class FakeCall extends ChangeNotifier implements VoiceCallView {
  @override
  VoiceCallPhase phase = VoiceCallPhase.idle;
  @override
  String? callId;
  @override
  String? chatId;
  @override
  VoiceCallMode? mode;
  @override
  String? agentName;
  @override
  bool agentPresent = false;
  @override
  bool micMuted = false;
  @override
  bool speakerOn = true;
  @override
  bool canSwitchSpeaker = true;
  @override
  DateTime? startedAt;

  int endCalls = 0;

  @override
  bool get isActive =>
      phase == VoiceCallPhase.connecting ||
      phase == VoiceCallPhase.live ||
      phase == VoiceCallPhase.ending;

  /// What `VoiceCallController.start` does to the state.
  void begin({
    required String chatId,
    required VoiceCallMode mode,
    String? callId,
    String? agentName,
  }) {
    this.chatId = chatId;
    this.mode = mode;
    this.callId = callId;
    this.agentName = agentName;
    agentPresent = false;
    micMuted = false;
    startedAt = DateTime.now();
    phase = VoiceCallPhase.connecting;
    notifyListeners();
  }

  void goLive({bool agent = true}) {
    phase = VoiceCallPhase.live;
    agentPresent = agent;
    notifyListeners();
  }

  void finish([VoiceCallPhase to = VoiceCallPhase.ended]) {
    phase = to;
    agentPresent = false;
    notifyListeners();
  }

  @override
  Future<void> end() async {
    endCalls++;
    if (isActive) finish();
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    micMuted = muted;
    notifyListeners();
  }

  @override
  Future<void> setSpeakerOn(bool on) async {
    speakerOn = on;
    notifyListeners();
  }
}

/// A starter that records the calls it was asked to start and, like the real
/// one, starts the voice session on [call].
class FakeStarter {
  FakeStarter(this.call);

  final FakeCall call;
  final List<IncomingCall> started = <IncomingCall>[];

  Future<void> start(IncomingCall incoming) async {
    started.add(incoming);
    call.begin(
      chatId: incoming.threadId,
      mode: VoiceCallMode.agents,
      callId: incoming.callId,
      agentName: incoming.agentName,
    );
  }
}
