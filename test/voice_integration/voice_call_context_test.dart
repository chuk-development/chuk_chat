import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';

Map<String, String> _user(String text) => <String, String>{
  'sender': 'user',
  'text': text,
};

Map<String, String> _ai(String text) => <String, String>{
  'sender': 'ai',
  'text': text,
};

void main() {
  group('buildVoiceCallContext', () {
    test('turns messages into User/Assistant lines, oldest first', () {
      final String context = buildVoiceCallContext(<Map<String, String>>[
        _user('What is on my list?'),
        _ai('Milk and eggs.'),
        _user('Thanks'),
      ]);
      expect(
        context,
        'User: What is on my list?\nAssistant: Milk and eggs.\nUser: Thanks',
      );
    });

    test('keeps only the last 10 text messages', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        for (int i = 0; i < 15; i++) i.isEven ? _user('u$i') : _ai('a$i'),
      ];
      final List<String> lines = buildVoiceCallContext(rows).split('\n');
      expect(lines, hasLength(10));
      expect(lines.first, 'Assistant: a5');
      expect(lines.last, 'User: u14');
    });

    test('skips empty rows and the Thinking placeholder, keeps the count', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        for (int i = 0; i < 10; i++) _user('m$i'),
        _ai(''),
        _ai('Thinking...'),
        _ai('   '),
      ];
      final List<String> lines = buildVoiceCallContext(rows).split('\n');
      expect(lines, hasLength(10));
      expect(lines.first, 'User: m0');
      expect(lines.last, 'User: m9');
    });

    test('reads text only: attachments, images and tool calls stay out', () {
      final String context = buildVoiceCallContext(<Map<String, String>>[
        <String, String>{
          'sender': 'user',
          'text': 'Look at this',
          'attachments': '[{"fileName":"secret.pdf","markdownContent":"x"}]',
          'images': '["data:image/png;base64,AAAA"]',
        },
        <String, String>{
          'sender': 'ai',
          'text': 'Here is a chart <chart>{"type":"bar"}</chart> done',
          'toolCalls': '[{"name":"web_search"}]',
          'reasoning': 'private thoughts',
        },
      ]);
      expect(context, 'User: Look at this\nAssistant: Here is a chart done');
      expect(context, isNot(contains('secret.pdf')));
      expect(context, isNot(contains('base64')));
      expect(context, isNot(contains('private')));
    });

    test('folds a multi-line message into one line', () {
      expect(
        buildVoiceCallContext(<Map<String, String>>[_ai('one\n\ntwo\tthree')]),
        'Assistant: one two three',
      );
    });

    test('trims to the character budget, dropping the oldest lines', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        for (int i = 0; i < 10; i++) _user('x' * 900),
      ];
      final String context = buildVoiceCallContext(rows);
      expect(context.length, lessThanOrEqualTo(kVoiceContextMaxChars));
      // 4 lines of 906 chars + 3 newlines fit; a fifth does not.
      expect(context.split('\n'), hasLength(4));
    });

    test('cuts one oversized newest line instead of sending nothing', () {
      final String context = buildVoiceCallContext(
        <Map<String, String>>[_user('y' * 5000)],
        maxLineChars: 10000,
      );
      expect(context.length, kVoiceContextMaxChars);
      expect(context, startsWith('User: yyy'));
      expect(context, endsWith('…'));
    });

    test('an empty chat gives an empty context', () {
      expect(buildVoiceCallContext(const <Map<String, String>>[]), '');
    });
  });

  group('voice task text', () {
    test('carries the marker once', () {
      expect(voiceTaskMessageText('  add milk  '), '${kVoiceTaskMarker}add milk');
      expect(
        voiceTaskMessageText('${kVoiceTaskMarker}add milk'),
        '${kVoiceTaskMarker}add milk',
      );
      expect(voiceTaskMessageText('   '), isNull);
    });

    test('recognises the pipeline failure texts', () {
      expect(looksLikeFailedTurn('Error: 500'), isTrue);
      expect(
        looksLikeFailedTurn('Failed to start streaming. Please try again.'),
        isTrue,
      );
      expect(looksLikeFailedTurn(''), isTrue);
      expect(looksLikeFailedTurn('Milk is on the list.'), isFalse);
    });

    test('cuts a long result', () {
      expect(voiceResultText('z' * 9000).length, kVoiceResultMaxChars);
    });
  });
}
