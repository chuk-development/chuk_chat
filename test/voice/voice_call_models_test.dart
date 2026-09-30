import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';

void main() {
  final DateTime t0 = DateTime.utc(2026, 9, 29, 12, 0, 0);

  VoiceCallRecord sample() => VoiceCallRecord(
    chatId: 'chat-1',
    mode: VoiceCallMode.agents,
    startedAt: t0,
    endedAt: t0.add(const Duration(minutes: 3, seconds: 5)),
    turns: <VoiceTurn>[
      VoiceTurn(role: 'user', text: 'Was steht an?', at: t0, isFinal: true),
      VoiceTurn(
        role: 'assistant',
        text: 'Drei Dinge. 🍕',
        at: t0.add(const Duration(seconds: 2)),
        isFinal: true,
      ),
      VoiceTurn(
        role: 'assistant',
        text: 'Und dann',
        at: t0.add(const Duration(seconds: 9)),
        isFinal: false,
      ),
    ],
    cards: <VoiceCard>[
      VoiceCard(
        id: 'card-1',
        kind: 'weather',
        title: 'Kiel',
        subtitle: 'Heute',
        source: 'Open-Meteo',
        data: <String, dynamic>{
          'temperature': 14.5,
          'hourly': <Map<String, dynamic>>[
            <String, dynamic>{'time': '2026-09-29T13:00', 'temp': 15},
          ],
        },
        at: t0.add(const Duration(seconds: 3)),
      ),
    ],
  );

  group('VoiceCallRecord JSON', () {
    test('round-trips every field through a JSON string', () {
      final VoiceCallRecord original = sample();
      final String wire = jsonEncode(original.toJson());
      final VoiceCallRecord back = VoiceCallRecord.fromJson(
        jsonDecode(wire) as Map<String, dynamic>,
      );

      expect(back.chatId, 'chat-1');
      expect(back.mode, VoiceCallMode.agents);
      expect(back.startedAt.isAtSameMomentAs(original.startedAt), isTrue);
      expect(back.endedAt.isAtSameMomentAs(original.endedAt), isTrue);
      expect(back.duration, const Duration(minutes: 3, seconds: 5));
      expect(back.turns, hasLength(3));
      for (int i = 0; i < 3; i++) {
        expect(back.turns[i].role, original.turns[i].role);
        expect(back.turns[i].text, original.turns[i].text);
        expect(back.turns[i].isFinal, original.turns[i].isFinal);
        expect(back.turns[i].at.isAtSameMomentAs(original.turns[i].at), isTrue);
      }
      expect(back.finalTurnCount, 2);
      expect(back.cards, hasLength(1));
      final VoiceCard card = back.cards.single;
      expect(card.id, 'card-1');
      expect(card.kind, 'weather');
      expect(card.title, 'Kiel');
      expect(card.subtitle, 'Heute');
      expect(card.source, 'Open-Meteo');
      expect(card.number('temperature'), 14.5);
      expect(card.list('hourly').single['temp'], 15);
      expect(card.at.isAtSameMomentAs(original.cards.single.at), isTrue);
    });

    test('a record written before cards existed reads with no cards', () {
      final Map<String, dynamic> json = sample().toJson()..remove('cards');
      final VoiceCallRecord back = VoiceCallRecord.fromJson(json);
      expect(back.cards, isEmpty);
      expect(back.turns, hasLength(3));
    });

    test('malformed fields fall back instead of throwing', () {
      final VoiceCallRecord back = VoiceCallRecord.fromJson(<String, dynamic>{
        'chat_id': 42,
        'mode': 'nonsense',
        'started_at': 'not a date',
        'turns': <Object?>[
          'junk',
          <String, dynamic>{'role': 'robot', 'text': 7},
        ],
        'cards': 'junk',
      });
      expect(back.chatId, '');
      expect(back.mode, VoiceCallMode.chat);
      expect(back.turns, hasLength(1));
      expect(back.turns.single.role, VoiceTurn.roleAssistant);
      expect(back.turns.single.text, '');
      expect(back.turns.single.isFinal, isTrue);
      expect(back.cards, isEmpty);
    });

    test('lists are read-only', () {
      final VoiceCallRecord record = sample();
      expect(
        () => record.turns.add(record.turns.first),
        throwsUnsupportedError,
      );
      expect(() => record.cards.clear(), throwsUnsupportedError);
    });
  });

  group('VoiceToolActivity', () {
    test('a follow-up without a name keeps the started name', () {
      final VoiceToolActivity started = VoiceToolActivity(
        callId: 'c1',
        name: 'search_web',
        status: 'running',
        at: t0,
      );
      final VoiceToolActivity done = started.mergedWith(
        VoiceToolActivity(callId: 'c1', name: '', status: 'done', at: t0),
      );
      expect(done.name, 'search_web');
      expect(done.isRunning, isFalse);
      expect(started.label, 'Searching the web');
    });

    test('an unknown tool reads as its name without underscores', () {
      expect(
        VoiceToolActivity(
          callId: 'c',
          name: 'fetch_bus_times',
          status: 'running',
          at: t0,
        ).label,
        'fetch bus times',
      );
    });
  });
}
