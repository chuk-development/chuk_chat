import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';
import 'package:chuk_chat/utils/openui_fence.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

const String _program = 'root = Card([t])\nt = TextContent("Hi")';

void main() {
  group('splitOpenUiFences', () {
    test('text without a fence is one markdown part', () {
      final parts = splitOpenUiFences('Just **text**.');
      expect(parts, hasLength(1));
      expect(parts.single.isProgram, isFalse);
      expect(parts.single.text, 'Just **text**.');
    });

    test('a closed fence splits text, program, text', () {
      const text = 'Before\n\n```openui-lang\n$_program\n```\n\nAfter';
      final parts = splitOpenUiFences(text);
      expect(parts.map((p) => p.isProgram), [false, true, false]);
      expect(parts[0].text.trim(), 'Before');
      expect(parts[1].text, _program);
      expect(parts[1].isClosed, isTrue);
      expect(parts[1].ordinal, 0);
      expect(parts[2].text.trim(), 'After');
    });

    test('```openui is accepted too, and the ordinals count up', () {
      const text =
          '```openui\n$_program\n```\nmid\n```openui-lang\n$_program\n```';
      final programs = splitOpenUiFences(text).where((p) => p.isProgram);
      expect(programs.map((p) => p.ordinal), [0, 1]);
    });

    test('an unclosed fence runs to the end and is open', () {
      const text = 'Here:\n```openui-lang\nroot = Card([t])\nt = TextCon';
      final parts = splitOpenUiFences(text, streaming: true);
      expect(parts, hasLength(2));
      expect(parts[1].isProgram, isTrue);
      expect(parts[1].isClosed, isFalse);
      expect(parts[1].text, 'root = Card([t])\nt = TextCon');
    });

    test('a fence inside another code block is code', () {
      const text = '````md\n```openui-lang\n$_program\n```\n````';
      final parts = splitOpenUiFences(text);
      expect(parts.any((p) => p.isProgram), isFalse);
      expect(parts.single.text, text);
    });

    test('a normal code block stays markdown', () {
      const text = '```dart\nvoid main() {}\n```\n\nok';
      expect(splitOpenUiFences(text).single.text, text);
    });

    test('while streaming, a half opener line is hidden', () {
      for (final tail in ['```', '```open', '```openui-l']) {
        final parts = splitOpenUiFences('Text\n$tail', streaming: true);
        expect(parts.single.text, 'Text', reason: tail);
      }
      // Not a possible OpenUI opener: kept.
      expect(
        splitOpenUiFences('Text\n```dart', streaming: true).single.text,
        'Text\n```dart',
      );
      // Not streaming: kept.
      expect(splitOpenUiFences('Text\n```').single.text, 'Text\n```');
    });

    test('CRLF line ends work', () {
      const text = 'A\r\n```openui-lang\r\nroot = Card([])\r\n```\r\nB';
      final parts = splitOpenUiFences(text);
      expect(parts.where((p) => p.isProgram), hasLength(1));
      expect(parts.where((p) => p.isProgram).single.isClosed, isTrue);
    });
  });

  group('stripOpenUiPrograms', () {
    test('drops programs and keeps the prose', () {
      const text = 'Before\n```openui-lang\n$_program\n```\nAfter';
      expect(stripOpenUiPrograms(text), 'Before\n\nAfter');
    });

    test('text without a program is unchanged', () {
      const text = 'A\n```js\nx\n```';
      expect(stripOpenUiPrograms(text), text);
    });

    test('an answer that is only a program gives whenEmpty', () {
      const text = '```openui-lang\n$_program\n```';
      expect(stripOpenUiPrograms(text, whenEmpty: 'view'), 'view');
      expect(hasOpenUiProgram(text), isTrue);
      expect(hasOpenUiProgram('no ui'), isFalse);
    });
  });

  test('the display strip keeps a program intact', () {
    final text = File('test/openui/fixtures/chat_ex3.oui').readAsStringSync();
    final answer = 'Plan:\n\n```openui-lang\n$text\n```\n\nDone.';
    expect(stripToolCallBlocksForDisplay(answer).trim(), answer.trim());
  });

  group('voice text', () {
    test('the call context drops the program', () {
      final context = buildVoiceCallContext(<Map<String, String>>[
        {'sender': 'ai', 'text': 'Hi\n```openui-lang\n$_program\n```'},
      ]);
      expect(context, 'Assistant: Hi');
    });

    test('a task result drops the program', () {
      expect(voiceResultText('Done.\n```openui-lang\n$_program\n```'), 'Done.');
      expect(
        voiceResultText('```openui-lang\n$_program\n```'),
        kVoiceOpenUiOnlyText,
      );
    });
  });
}
