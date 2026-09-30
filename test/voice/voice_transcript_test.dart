import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_transcript.dart';

void main() {
  late VoiceTranscript transcript;

  setUp(() => transcript = VoiceTranscript());

  group('agent speech (one stream, deltas, final in the trailer)', () {
    test('chunks of one stream append into one partial turn', () {
      for (final String chunk in <String>['Hallo', ' Welt', '!']) {
        transcript.applyChunk(
          role: VoiceTurn.roleAssistant,
          segmentId: 'SG_1',
          streamId: 'st_1',
          text: chunk,
        );
      }
      expect(transcript.turns, hasLength(1));
      expect(transcript.turns.single.text, 'Hallo Welt!');
      expect(transcript.turns.single.isFinal, isFalse);
      expect(transcript.hasFinalTurn, isFalse);
    });

    test('the trailer final marks the same turn final', () {
      transcript.applyChunk(
        role: VoiceTurn.roleAssistant,
        segmentId: 'SG_1',
        streamId: 'st_1',
        text: 'Fertig.',
      );
      expect(
        transcript.finalizeSegment(
          role: VoiceTurn.roleAssistant,
          segmentId: 'SG_1',
        ),
        isTrue,
      );
      expect(transcript.turns.single.isFinal, isTrue);
      expect(transcript.hasFinalTurn, isTrue);
      // Second finalize is a no-op.
      expect(
        transcript.finalizeSegment(
          role: VoiceTurn.roleAssistant,
          segmentId: 'SG_1',
        ),
        isFalse,
      );
    });

    test('finalizing an unknown segment changes nothing', () {
      expect(
        transcript.finalizeSegment(role: 'assistant', segmentId: 'nope'),
        isFalse,
      );
      expect(transcript.isEmpty, isTrue);
    });
  });

  group('user speech (full text per update, final in the header)', () {
    test('each interim replaces the text, the final replaces it last', () {
      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'a',
        text: 'Wie',
      );
      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'b',
        text: 'Wie wird das',
      );
      expect(transcript.turns.single.text, 'Wie wird das');
      expect(transcript.turns.single.isFinal, isFalse);

      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'c',
        text: 'Wie wird das Wetter?',
        isFinal: true,
      );
      expect(transcript.turns, hasLength(1));
      expect(transcript.turns.single.text, 'Wie wird das Wetter?');
      expect(transcript.turns.single.isFinal, isTrue);
    });

    test('an empty final header keeps the text it already has', () {
      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'a',
        text: 'Ja',
      );
      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'b',
        text: '',
        isFinal: true,
      );
      expect(transcript.turns.single.text, 'Ja');
      expect(transcript.turns.single.isFinal, isTrue);
    });

    test('an empty non-final chunk is ignored', () {
      expect(
        transcript.applyChunk(
          role: VoiceTurn.roleUser,
          segmentId: 'x',
          streamId: 'a',
          text: '',
        ),
        isFalse,
      );
      expect(transcript.isEmpty, isTrue);
    });

    test('a repeat of the same text reports no change', () {
      transcript.applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'SG_u',
        streamId: 'a',
        text: 'Hallo',
        isFinal: true,
      );
      expect(
        transcript.applyChunk(
          role: VoiceTurn.roleUser,
          segmentId: 'SG_u',
          streamId: 'b',
          text: 'Hallo',
          isFinal: true,
        ),
        isFalse,
      );
    });
  });

  test('turns keep the order their segments started in', () {
    final DateTime t = DateTime(2026, 9, 29, 10);
    transcript
      ..applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'u1',
        streamId: 'a',
        text: 'Frage',
        isFinal: true,
        at: t,
      )
      ..applyChunk(
        role: VoiceTurn.roleAssistant,
        segmentId: 'a1',
        streamId: 'b',
        text: 'Ant',
        at: t.add(const Duration(seconds: 1)),
      )
      ..applyChunk(
        role: VoiceTurn.roleUser,
        segmentId: 'u2',
        streamId: 'c',
        text: 'Noch was',
        at: t.add(const Duration(seconds: 2)),
      )
      // A late delta of the agent's first segment lands in its own turn.
      ..applyChunk(
        role: VoiceTurn.roleAssistant,
        segmentId: 'a1',
        streamId: 'b',
        text: 'wort',
      );
    expect(transcript.turns.map((VoiceTurn e) => e.text).toList(), <String>[
      'Frage',
      'Antwort',
      'Noch was',
    ]);
    expect(transcript.turns[1].at, t.add(const Duration(seconds: 1)));
  });

  test('the same segment id from two roles is two turns', () {
    transcript
      ..applyChunk(role: 'user', segmentId: 's', streamId: '1', text: 'A')
      ..applyChunk(role: 'assistant', segmentId: 's', streamId: '2', text: 'B');
    expect(transcript.turns, hasLength(2));
  });

  test('recordTurns drops empty turns and trims the rest', () {
    transcript
      ..applyChunk(
        role: 'user',
        segmentId: 'a',
        streamId: '1',
        text: '  Hallo  ',
        isFinal: true,
      )
      ..applyChunk(
        role: 'assistant',
        segmentId: 'b',
        streamId: '2',
        text: '   ',
      );
    final List<VoiceTurn> kept = transcript.recordTurns();
    expect(kept, hasLength(1));
    expect(kept.single.text, 'Hallo');
  });

  test('clear empties the transcript', () {
    transcript.applyChunk(
      role: 'user',
      segmentId: 'a',
      streamId: '1',
      text: 'x',
    );
    transcript.clear();
    expect(transcript.isEmpty, isTrue);
    // A cleared segment id starts a fresh turn.
    transcript.applyChunk(
      role: 'user',
      segmentId: 'a',
      streamId: '1',
      text: 'y',
    );
    expect(transcript.turns.single.text, 'y');
  });

  test('parseFinal reads the attribute', () {
    expect(
      VoiceTranscriptionAttributes.parseFinal(<String, String>{
        'lk.transcription_final': 'true',
      }),
      isTrue,
    );
    expect(
      VoiceTranscriptionAttributes.parseFinal(<String, String>{
        'lk.transcription_final': '1',
      }),
      isTrue,
    );
    expect(
      VoiceTranscriptionAttributes.parseFinal(<String, String>{
        'lk.transcription_final': 'false',
      }),
      isFalse,
    );
    expect(
      VoiceTranscriptionAttributes.parseFinal(<String, String>{}),
      isFalse,
    );
  });
}
