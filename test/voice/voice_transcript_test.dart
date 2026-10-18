import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_transcript.dart';

void main() {
  test('a delayed snapshot inserts before its interrupting user turn', () {
    final transcript = VoiceTranscript();
    final speechAt = DateTime.utc(2026, 10, 18);
    transcript.applyChunk(
      role: 'user',
      segmentId: 'u1',
      streamId: 'u1',
      text: 'Stop',
      isFinal: true,
      at: speechAt.add(const Duration(seconds: 2)),
    );
    transcript.applyChunk(
      role: 'assistant',
      segmentId: 'SG_2',
      streamId: 's2',
      text: 'Okay',
      at: speechAt.add(const Duration(seconds: 3)),
    );
    transcript.applySpeechSnapshot(
      turnId: 'item_1',
      spokenText: 'Hello',
      generatedText: 'Hello there',
      interrupted: true,
      at: speechAt,
      finishedAt: speechAt.add(const Duration(seconds: 1)),
    );
    expect(transcript.turns.map((turn) => turn.text), [
      'Hello',
      'Stop',
      'Okay',
    ]);
    transcript.applyChunk(
      role: 'assistant',
      segmentId: 'SG_2',
      streamId: 's2',
      text: '!',
    );
    expect(transcript.turns.last.text, 'Okay!');
    transcript.applySpeechSnapshot(
      turnId: 'item_2',
      spokenText: 'Okay!',
      generatedText: 'Okay!',
      interrupted: false,
      at: speechAt.add(const Duration(seconds: 3)),
    );
    expect(transcript.turns, hasLength(3));
  });

  test(
    'speech snapshot replaces temporary speech and blocks late trailers',
    () {
      final transcript = VoiceTranscript();
      final now = DateTime.utc(2026, 10, 18);
      transcript.applyChunk(
        role: 'assistant',
        segmentId: 'SG_1',
        streamId: 'stream',
        text: 'Hello there',
        at: now,
      );
      expect(
        transcript.applySpeechSnapshot(
          turnId: 'item_1',
          spokenText: 'Hello',
          generatedText: 'Hello there friend',
          interrupted: true,
          at: now,
        ),
        isTrue,
      );
      expect(transcript.turns, hasLength(1));
      expect(transcript.turns.single.text, 'Hello');
      expect(transcript.turns.single.intendedText, 'Hello there friend');
      expect(transcript.turns.single.interrupted, isTrue);
      expect(
        transcript.applyChunk(
          role: 'assistant',
          segmentId: 'SG_1',
          streamId: 'stream',
          text: ' friend',
          isFinal: true,
        ),
        isFalse,
      );
      expect(
        transcript.finalizeSegment(role: 'assistant', segmentId: 'SG_1'),
        isFalse,
      );
      expect(
        transcript.applySpeechSnapshot(
          turnId: 'item_1',
          spokenText: 'Hello',
          generatedText: 'Hello there friend',
          interrupted: true,
          at: now,
        ),
        isFalse,
      );
      expect(transcript.turns, hasLength(1));
    },
  );
  test('snapshot before speech and a later reply keep separate stable IDs', () {
    final transcript = VoiceTranscript();
    final now = DateTime.utc(2026, 10, 18);
    transcript.applySpeechSnapshot(
      turnId: 'item_1',
      spokenText: '',
      generatedText: 'Unspoken',
      interrupted: true,
      at: now,
    );
    transcript.applyChunk(
      role: 'user',
      segmentId: 'user_1',
      streamId: 'userstream',
      text: 'Stop',
      isFinal: true,
    );
    transcript.applyChunk(
      role: 'assistant',
      segmentId: 'SG_2',
      streamId: 'stream2',
      text: 'Okay',
    );
    transcript.applySpeechSnapshot(
      turnId: 'item_2',
      spokenText: 'Okay',
      generatedText: 'Okay',
      interrupted: false,
      at: now,
    );
    expect(transcript.turns, hasLength(3));
    expect(transcript.turns.last.segmentId, 'item_2');
    expect(transcript.recordTurns(), hasLength(3));
  });

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
