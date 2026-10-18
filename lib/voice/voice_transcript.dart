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
  final Map<String, int> _speechTurns = {};
  final Set<String> _settledSegments = {};

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
    if (_settledSegments.contains(key)) return false;
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

  /// Authoritative worker snapshot after synchronized playout or interruption.
  /// Live assistant transcription is temporary; speech output is serialized,
  /// so the oldest temporary assistant segment is the corresponding one.
  /// The worker's stable ID owns every subsequent correction and retry.
  bool applySpeechSnapshot({
    required String turnId,
    required String spokenText,
    required String generatedText,
    required bool interrupted,
    required DateTime at,
    bool? generationComplete,
    DateTime? finishedAt,
  }) {
    var index = _speechTurns[turnId];
    index ??= _turns.indexWhere(
      (turn) =>
          !turn.isUser &&
          turn.segmentId == null &&
          (finishedAt == null || !turn.at.isAfter(finishedAt)),
    );
    final next = VoiceTurn(
      role: VoiceTurn.roleAssistant,
      text: spokenText,
      intendedText: generatedText,
      interrupted: interrupted,
      generationComplete: generationComplete,
      segmentId: turnId,
      at: index >= 0 ? _turns[index].at : at,
      isFinal: true,
    );
    if (index < 0) {
      index = _turns.indexWhere((turn) => turn.at.isAfter(at));
      if (index < 0) index = _turns.length;
      for (final segment in _segments.values) {
        if (segment.index >= index) segment.index++;
      }
      for (final id in _speechTurns.keys.toList()) {
        if (_speechTurns[id]! >= index) {
          _speechTurns[id] = _speechTurns[id]! + 1;
        }
      }
      _turns.insert(index, next);
    } else {
      if (_turns[index] == next) return false;
      _turns[index] = next;
      for (final entry in _segments.entries) {
        if (entry.value.index == index) _settledSegments.add(entry.key);
      }
    }
    _speechTurns[turnId] = index;
    return true;
  }

  /// Marks a segment final (its stream closed with the final flag in the
  /// trailer). Returns true when the visible transcript changed.
  bool finalizeSegment({required String role, required String segmentId}) {
    final key = _key(role, segmentId);
    if (_settledSegments.contains(key)) return false;
    final _Segment? segment = _segments[key];
    if (segment == null) return false;
    final VoiceTurn current = _turns[segment.index];
    if (current.isFinal) return false;
    _turns[segment.index] = current.copyWith(isFinal: true);
    return true;
  }

  /// The turns worth keeping in a record: every turn with text, in order.
  List<VoiceTurn> recordTurns() => <VoiceTurn>[
    for (final VoiceTurn turn in _turns)
      if (turn.text.trim().isNotEmpty ||
          (turn.intendedText?.trim().isNotEmpty ?? false))
        turn.copyWith(text: turn.text.trim()),
  ];

  void clear() {
    _turns.clear();
    _segments.clear();
    _speechTurns.clear();
    _settledSegments.clear();
  }

  static String _key(String role, String segmentId) => '$role\u0000$segmentId';
}

class _Segment {
  _Segment({required this.index, required this.streamId});

  int index;
  String streamId;
}
