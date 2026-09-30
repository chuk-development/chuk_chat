/// The two sealed control frames of "the agent calls the user"
/// (docs/WIRE_CONTRACT.md, "The agent calls the user"; spec §6.3):
///
///  * host → app `voice_call_incoming` — a call rings. It is re-sent on every
///    controller (re)attach while the call still rings, so a receiver dedupes
///    it by `call_id`.
///  * host ↔ app `voice_call_state` — the app reports `accepted`, `declined`
///    or `ended`; the host echoes every accepted change (and `missed` when a
///    ring expires) to every attached controller.
///
/// Neither is a run event: no `session_key`, not persisted, not replayed. The
/// relay client routes them here by `type` ([AgentsVoiceCallFrames.deliver])
/// and never onto its inbound stream, so no exhaustive switch over
/// `AgentsRelayInbound` has to learn about them. The voice layer
/// (`lib/voice/incoming/`) listens to [AgentsVoiceCallFrames.frames] only in a
/// build with `FEATURE_VOICE_CALL`; without a listener a frame is dropped.
///
/// Privacy: `reason` is content. It is never logged here; a log line may carry
/// the frame type and the `call_id`, nothing else.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The app → host half: a transport that can send a `voice_call_state`.
///
/// Its own interface, like `AgentsAgentStatusControl`: the voice layer checks
/// `controller is AgentsVoiceCallControl`, so a fake controller in a test (or
/// an older transport) does not have to implement it.
abstract interface class AgentsVoiceCallControl {
  /// Seals and sends `{"type": "voice_call_state", "call_id", "state"}`.
  /// [state] is one of [AgentsVoiceCallFrames.appStates]. Throws when the
  /// transport is not paired right now.
  Future<void> sendVoiceCallState({
    required String callId,
    required String state,
  });
}

/// The process-wide router of the voice-call control frames.
class AgentsVoiceCallFrames {
  AgentsVoiceCallFrames._();

  /// The one instance the relay client delivers to.
  static final AgentsVoiceCallFrames instance = AgentsVoiceCallFrames._();

  /// Host → app: a call rings.
  static const String incomingType = 'voice_call_incoming';

  /// Both directions: a call changed state.
  static const String stateType = 'voice_call_state';

  static const String accepted = 'accepted';
  static const String declined = 'declined';
  static const String ended = 'ended';

  /// Host only: nobody answered before `expires_at`.
  static const String missed = 'missed';

  /// The states the app may report. `missed` and `ringing` are the host's.
  static const Set<String> appStates = <String>{accepted, declined, ended};

  /// The app → host frame for [state] of [callId].
  static Map<String, dynamic> stateFrame({
    required String callId,
    required String state,
  }) {
    if (!appStates.contains(state)) {
      throw ArgumentError.value(state, 'state', 'not an app state');
    }
    return <String, dynamic>{
      'type': stateType,
      'call_id': callId,
      'state': state,
    };
  }

  /// Whether a frame of [type] belongs here.
  static bool handles(Object? type) =>
      type == incomingType || type == stateType;

  final StreamController<Map<String, dynamic>> _frames =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Every voice-call frame the host sent, in arrival order, decoded and
  /// unmodifiable. A broadcast stream: a frame with no listener is dropped.
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  /// Called by the relay client for an opened frame whose `type` [handles].
  void deliver(Map<String, dynamic> payload) {
    final Object? type = payload['type'];
    if (!handles(type)) return;
    if (kDebugMode) {
      final Object? id = payload['call_id'];
      debugPrint('[voice-call] frame $type call_id=${id is String ? id : '?'}');
    }
    _frames.add(Map<String, dynamic>.unmodifiable(payload));
  }
}
