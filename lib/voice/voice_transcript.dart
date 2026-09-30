// lib/voice/voice_transcript.dart
//
// The live transcript of one call, built from LiveKit transcription text
// streams (`lk.transcription`). Pure Dart, so the partial-to-final logic is
// testable without a room.
//
// Stream semantics (livekit-agents 1.x, room_io `_ParticipantTranscriptionOutput`):
// - Agent speech is ONE text stream per segment. Its chunks are deltas that
//   append. The final flag arrives in the stream trailer, so it is known
//   only when the stream closes.
// - User speech (STT) sends the FULL text again on each update, each update
//   in its own short stream with `lk.transcription_final` = "false"; the last
//   one carries "true" in its header. Same segment id throughout.
// So: same segment + same stream id -> append; same segment + new stream id
// -> replace; final -> mark the turn final.

import 'package:chuk_chat/voice/voice_call_models.dart';

/// Attribute keys livekit-agents puts on a transcription text stream.
abstract final class VoiceTranscriptionAttributes {
  static const String topic = 'lk.transcription';
  static const String segmentId = 'lk.segment_id';
  static const String isFinal = 'lk.transcription_final';

  /// `'true'` / `'1'` -> true, anything else -> false.
  static bool parseFinal(Map<String, String> attributes) {
    final String? raw = attributes[isFinal]?.toLowerCase();
    return raw == 'true' || raw == '1';
  }
}

class VoiceTranscript {
  final List<VoiceTurn> _turns = <VoiceTurn>[];
  final Map<String, _Segment> _segments = <String, _Segment>{};

  /// Turns in the order their segments started. Partials are replaced in
  /// place when their final text arrives.
  List<VoiceTurn> get turns => List<VoiceTurn>.unmodifiable(_turns);

  bool get isEmpty => _turns.isEmpty;

  /// True once at least one turn with text is final.
  bool get hasFinalTurn =>
      _turns.any((VoiceTurn t) => t.isFinal && t.text.trim().isNotEmpty);

  /// Applies one chunk of a transcription stream. Returns true when the
  /// visible transcript changed.
  bool applyChunk({
    required String role,
    required String segmentId,
    required String streamId,
    required String text,
    bool isFinal = false,
    DateTime? at,
  }) {
    if (text.isEmpty && !isFinal) return false;
    final String key = _key(role, segmentId);
    final _Segment? segment = _segments[key];
    if (segment == null) {
      _segments[key] = _Segment(index: _turns.length, streamId: streamId);
      _turns.add(
        VoiceTurn(
          role: role,
          text: text,
          at: at ?? DateTime.now(),
          isFinal: isFinal,
        ),
      );
      return true;
    }
    final VoiceTurn current = _turns[segment.index];
    final String nextText;
    if (segment.streamId == streamId) {
      nextText = current.text + text;
    } else {
      segment.streamId = streamId;
      // A user segment resends the whole text on each update. An empty
      // final header (the text came earlier) must not wipe it.
      nextText = text.isEmpty ? current.text : text;
    }
    final VoiceTurn next = current.copyWith(
      text: nextText,
      isFinal: current.isFinal || isFinal,
    );
    if (next == current) return false;
    _turns[segment.index] = next;
    return true;
  }

  /// Marks a segment final (its stream closed with the final flag in the
  /// trailer). Returns true when the visible transcript changed.
  bool finalizeSegment({required String role, required String segmentId}) {
    final _Segment? segment = _segments[_key(role, segmentId)];
    if (segment == null) return false;
    final VoiceTurn current = _turns[segment.index];
    if (current.isFinal) return false;
    _turns[segment.index] = current.copyWith(isFinal: true);
    return true;
  }

  /// The turns worth keeping in a record: every turn with text, in order.
  List<VoiceTurn> recordTurns() => <VoiceTurn>[
    for (final VoiceTurn turn in _turns)
      if (turn.text.trim().isNotEmpty) turn.copyWith(text: turn.text.trim()),
  ];

  void clear() {
    _turns.clear();
    _segments.clear();
  }

  static String _key(String role, String segmentId) => '$role\u0000$segmentId';
}

class _Segment {
  _Segment({required this.index, required this.streamId});

  final int index;
  String streamId;
}
