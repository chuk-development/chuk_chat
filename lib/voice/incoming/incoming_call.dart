// lib/voice/incoming/incoming_call.dart
//
// The plain data of "the agent calls the user" (docs/WIRE_CONTRACT.md, "The
// agent calls the user"; spec §6.3): a ringing call as the host sent it, and
// the host's state echo. Parsing only: no Flutter, no plugin, no clock.
//
// Privacy: [IncomingCall.reason] is content. It goes to the voice worker (the
// agent speaks it) and nowhere else: not into a log line, not into a
// notification, not into the ring screen (that one is backed by a
// notification too, see incoming_call_mapping.dart).

import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';

/// How urgent the agent says the call is.
enum IncomingCallUrgency { normal, high }

/// One `voice_call_incoming` frame.
class IncomingCall {
  const IncomingCall({
    required this.callId,
    required this.threadId,
    required this.agentId,
    required this.agentName,
    required this.reason,
    required this.urgency,
    required this.expiresAt,
  });

  /// The name the host uses when the user gave the coworker none.
  static const String defaultAgentName = 'Your coworker';

  /// The host cuts `reason` at this many characters; a longer one is cut here
  /// too, so a broken host cannot hand the worker a novel.
  static const int maxReasonChars = 1000;

  /// A `call_id` longer than this is not one the host minted (16 hex).
  static const int maxCallIdChars = 64;

  /// Parses a decoded frame received at [now]. Null when it is not a usable
  /// `voice_call_incoming`: another type, no `call_id`, no `thread_id`, or
  /// neither `ring_seconds` nor `expires_at`. Unknown keys are ignored (the
  /// contract says so).
  ///
  /// The ring ends at `now + ring_seconds` (the seconds the ring had left
  /// when the host sent it), so a phone clock that disagrees with the host's
  /// does not matter. A host that does not send `ring_seconds` yet falls back
  /// to `expires_at`, which is on the host clock.
  static IncomingCall? fromFrame(
    Map<String, dynamic> frame, {
    required DateTime now,
  }) {
    if (frame['type'] != AgentsVoiceCallFrames.incomingType) return null;
    final String? callId = _id(frame['call_id']);
    final String? threadId = _id(frame['thread_id']);
    if (callId == null || threadId == null) return null;
    final DateTime? expiresAt = _expiry(frame, now);
    if (expiresAt == null) return null;
    final Object? name = frame['agent_name'];
    final String agentName = name is String && name.trim().isNotEmpty
        ? name.trim()
        : defaultAgentName;
    final Object? rawReason = frame['reason'];
    String reason = rawReason is String ? rawReason.trim() : '';
    if (reason.length > maxReasonChars) {
      reason = '${reason.substring(0, maxReasonChars - 1)}…';
    }
    final Object? agentId = frame['agent_id'];
    return IncomingCall(
      callId: callId,
      threadId: threadId,
      agentId: agentId is String ? agentId : '',
      agentName: agentName,
      reason: reason,
      urgency: frame['urgency'] == 'high'
          ? IncomingCallUrgency.high
          : IncomingCallUrgency.normal,
      expiresAt: expiresAt,
    );
  }

  static DateTime? _expiry(Map<String, dynamic> frame, DateTime now) {
    final Object? ring = frame['ring_seconds'];
    if (ring is num && ring.isFinite && ring >= 0) {
      return now.toUtc().add(Duration(milliseconds: (ring * 1000).round()));
    }
    final Object? expires = frame['expires_at'];
    if (expires is num && expires.isFinite) {
      return DateTime.fromMillisecondsSinceEpoch(
        (expires * 1000).round(),
        isUtc: true,
      );
    }
    return null;
  }

  static String? _id(Object? value) {
    if (value is! String) return null;
    final String id = value.trim();
    if (id.isEmpty || id.length > maxCallIdChars) return null;
    return id;
  }

  final String callId;

  /// The thread's `session_key`: the Agents thread to open on accept.
  final String threadId;
  final String agentId;

  /// The name the user gave the coworker. Shown on the ring screen.
  final String agentName;

  /// Why the agent calls. Content: the worker gets it, the UI does not.
  final String reason;
  final IncomingCallUrgency urgency;

  /// When the ring ends, on THIS device's clock (from `ring_seconds`), or on
  /// the host clock for a host that sends only `expires_at`.
  final DateTime expiresAt;

  bool get isUrgent => urgency == IncomingCallUrgency.high;

  /// How long the ring may still last at [now]. Zero or less: expired.
  Duration remainingAt(DateTime now) => expiresAt.difference(now.toUtc());

  @override
  String toString() => 'IncomingCall($callId, urgency=${urgency.name})';
}

/// One `voice_call_state` frame from the host (the echo).
class HostCallState {
  const HostCallState({required this.callId, required this.state});

  /// Null unless the frame is a `voice_call_state` with a `call_id` and one of
  /// the four states the host sends.
  static HostCallState? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != AgentsVoiceCallFrames.stateType) return null;
    final Object? id = frame['call_id'];
    final Object? state = frame['state'];
    if (id is! String || id.isEmpty || state is! String) return null;
    if (!_hostStates.contains(state)) return null;
    return HostCallState(callId: id, state: state);
  }

  static const Set<String> _hostStates = <String>{
    AgentsVoiceCallFrames.accepted,
    AgentsVoiceCallFrames.declined,
    AgentsVoiceCallFrames.missed,
    AgentsVoiceCallFrames.ended,
  };

  final String callId;

  /// `accepted`, `declined`, `missed` or `ended`.
  final String state;
}
