// What a turn stores in `modelContext` is bounded, and the bounded form
// rebuilds the same history bytes as the full form (prompt cache).

import 'dart:convert';

import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapshotState = PromptState(
  identity: true,
  soul: 'Be brief.',
  user: 'Name: Ada',
  memory: 'Likes tea.',
  mcpConnected: ['Linear'],
  skills: [SkillCatalogEntry('weather-cards', 'Weather cards.')],
);

List<Map<String, dynamic>> _rounds(
  int count,
  int resultChars, {
  String? skill,
}) {
  return [
    for (var i = 0; i < count; i++) ...[
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'c$i',
            'type': 'function',
            'function': {'name': 'web_search', 'arguments': '{"q":"$i"}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'c$i', 'content': 'r$i' * resultChars},
    ],
    if (skill != null)
      {'role': 'user', 'content': skillContentMessage(skill, 'step 1\nstep 2')},
  ];
}

Map<String, String> _user(String text, String sentAt, TurnPromptContext? c) => {
  'sender': 'user',
  'text': text,
  'sentAt': sentAt,
  if (c != null) 'modelContext': c.encode(),
};

Map<String, String> _ai(String text) => {'sender': 'ai', 'text': text};

/// The same messages with each user message's context as storage keeps it.
List<Map<String, String>> _stored(List<Map<String, String>> messages) => [
  for (final m in messages)
    if (m['sender'] == 'user' && m['modelContext'] != null)
      {...m, 'modelContext': PromptContextLedger.storedContextOf(m) ?? ''}
    else
      m,
];

Future<String> _build(
  List<Map<String, String>> messages, {
  bool includeToolResults = true,
}) async {
  final history = await ChatHistoryBuilder.build(
    messages: messages,
    pendingUserText: 'next',
    includeToolResults: includeToolResults,
  );
  final ctx = HistoryPromptContext.of(history);
  return jsonEncode({
    'history': history,
    'effective': ctx?.effective?.toJson(),
    'snapshot': ctx?.snapshot?.toJson(),
  });
}

void main() {
  setUp(PromptContextLedger.clearForTesting);

  group('transcript over the replay budget', () {
    test('is stored as its size and skill names, same history', () async {
      final big = TurnPromptContext(
        snapshot: _snapshotState.withExtras(toolHistory: true),
        skills: const [SkillContent('weather-cards', 'step 1\nstep 2')],
        transcript: _rounds(45, 5000, skill: 'weather-cards'),
      );
      expect(big.transcriptSize, greaterThan(kTranscriptBudgetChars));
      final small = TurnPromptContext(transcript: _rounds(2, 100));
      final messages = [
        _user('one', '2026-11-04T10:00:00.000', big),
        _ai('answer one'),
        _user('two', '2026-11-04T10:05:00.000', small),
        _ai('answer two'),
        _user('next', '2026-11-04T10:10:00.000', null),
      ];
      final stored = _stored(messages);

      final raw = stored.first['modelContext']!;
      expect(raw.length, lessThan(2000));
      final decoded = TurnPromptContext.decode(raw)!;
      expect(decoded.transcript, isNull);
      expect(decoded.transcriptChars, big.transcriptSize);
      expect(decoded.transcriptSkillNames, ['weather-cards']);
      // The skill body stays: with tool rounds off it is replayed from it.
      expect(decoded.skills.single.body, 'step 1\nstep 2');

      final full = await _build(messages);
      expect(await _build(stored), full);
      expect(full, contains(skillDroppedMarker('weather-cards')));
      expect(full, contains('r1' * 10));

      // Stored again (a later save): unchanged.
      expect(_stored(stored).first['modelContext'], raw);
    });

    test('with tool rounds off, the same history too', () async {
      final big = TurnPromptContext(
        snapshot: _snapshotState.withExtras(toolHistory: false),
        skills: const [SkillContent('weather-cards', 'step 1\nstep 2')],
        transcript: _rounds(45, 5000, skill: 'weather-cards'),
      );
      final messages = [
        _user('one', '2026-11-04T10:00:00.000', big),
        _ai('answer one'),
        _user('next', '2026-11-04T10:10:00.000', null),
      ];
      final full = await _build(messages, includeToolResults: false);
      expect(await _build(_stored(messages), includeToolResults: false), full);
      expect(full, contains('<skill_content name=\\"weather-cards\\">'));
    });
  });

  group('skill bodies', () {
    test('a body the transcript carries is stored once', () async {
      final ctx = TurnPromptContext(
        snapshot: _snapshotState.withExtras(toolHistory: true),
        skills: const [
          SkillContent('weather-cards', '  step 1\nstep 2  '),
          SkillContent('not-in-rounds', 'other body'),
        ],
        transcript: _rounds(1, 50, skill: 'weather-cards'),
      );
      final messages = [
        _user('one', '2026-11-04T10:00:00.000', ctx),
        _ai('answer'),
        _user('next', '2026-11-04T10:10:00.000', null),
      ];
      final stored = _stored(messages);
      final raw = stored.first['modelContext']!;
      final skills = (jsonDecode(raw) as Map)['skills'] as List;
      expect(skills.first, {'name': 'weather-cards'});
      expect(skills.last, {'name': 'not-in-rounds', 'body': 'other body'});
      expect(r'step 1\nstep 2'.allMatches(raw).length, 1);

      final decoded = TurnPromptContext.decode(raw)!;
      expect(decoded.skills.first.body, 'step 1\nstep 2');

      for (final on in [true, false]) {
        final snapshot = _snapshotState.withExtras(toolHistory: on);
        final m = [
          for (final x in messages)
            if (x['modelContext'] != null)
              {
                ...x,
                'modelContext': (TurnPromptContext.decode(
                  x['modelContext'],
                )!..snapshot = snapshot).encode(),
              }
            else
              x,
        ];
        expect(await _build(_stored(m)), await _build(m));
      }
    });

    test('an old payload (bodies, whole state) still loads', () {
      const raw =
          '{"v":1,"state":{"identity":true,"memory":"m"},'
          '"notes":["[memory updated] x"],'
          '"skills":[{"name":"a","body":"b"}],'
          '"transcript":[{"role":"tool","tool_call_id":"c","content":"r"}]}';
      final ctx = TurnPromptContext.decode(raw)!;
      expect(ctx.state!.memory, 'm');
      expect(ctx.skills.single.body, 'b');
      expect(ctx.transcript, hasLength(1));
      expect(ctx.hasTranscript, isTrue);
    });
  });

  group('state after a note', () {
    test('a diff round-trips, empty values included', () {
      const after = PromptState(
        identity: true,
        soul: 'Be brief.',
        user: 'Name: Ada',
        mcpConnected: [],
        mcpUnconnected: ['github'],
        skills: [SkillCatalogEntry('new', 'New.')],
      );
      final diff = after.diffFrom(_snapshotState)!;
      expect(diff.keys, containsAll(['memory', 'mcp', 'mcpAvailable']));
      expect(diff.containsKey('soul'), isFalse);
      expect(
        jsonEncode(_snapshotState.applyDiff(diff).toJson()),
        jsonEncode(after.toJson()),
      );
      expect(
        jsonEncode(_snapshotState.applyDiff(const {}).toJson()),
        jsonEncode(_snapshotState.toJson()),
      );
    });

    test('an unrecorded catalog cannot be a diff', () {
      const after = PromptState(identity: true);
      expect(after.diffFrom(_snapshotState), isNull);
    });

    test('the history reaches the same state from a diff', () async {
      const after = PromptState(
        identity: true,
        soul: 'Be brief.',
        user: 'Name: Ada',
        memory: 'Likes coffee now.',
        mcpConnected: ['Linear'],
        skills: [SkillCatalogEntry('weather-cards', 'Weather cards.')],
      );
      final first = TurnPromptContext(
        snapshot: _snapshotState.withExtras(toolHistory: true),
      );
      List<Map<String, String>> chat(TurnPromptContext second) => [
        _user('one', '2026-11-04T10:00:00.000', first),
        _ai('answer one'),
        _user('two', '2026-11-04T10:05:00.000', second),
        _ai('answer two'),
        _user('next', '2026-11-04T10:10:00.000', null),
      ];
      final whole = TurnPromptContext(
        notes: ['[memory updated] x'],
        state: after,
      );
      final diff = TurnPromptContext(
        notes: ['[memory updated] x'],
        stateDiff: after.diffFrom(_snapshotState),
      );
      expect(diff.stateDiff, {'memory': 'Likes coffee now.'});
      expect(await _build(chat(diff)), await _build(chat(whole)));
      expect(await _build(_stored(chat(diff))), await _build(chat(whole)));
    });
  });
}
