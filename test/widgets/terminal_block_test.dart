import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/utils/ansi_sgr.dart';
import 'package:chuk_chat/widgets/terminal_block.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
    ),
  ),
);

void main() {
  group('ANSI', () {
    test('keeps SGR colours, strips every other escape', () {
      const String raw =
          '\x1b]0;title\x07\x1b[2J\x1b[1;31merror\x1b[0m done\x1b[K';
      expect(stripNonSgr(raw), '\x1b[1;31merror\x1b[0m done');
      final lines = parseAnsi(raw);
      expect(lines, hasLength(1));
      expect(lines.single.map((s) => s.text), ['error', ' done']);
      expect(lines.single.first.bold, isTrue);
      expect(lines.single.first.foreground, const AnsiColor.named(1));
      expect(lines.single.last.plain, isTrue);
    });

    test('256 and truecolor become RGB', () {
      final spans = parseAnsi('\x1b[38;2;10;20;30mx\x1b[48;5;196my').single;
      expect(spans.first.foreground, const AnsiColor.rgb(Color(0xFF0A141E)));
      expect(spans.last.background?.rgb, isNotNull);
    });

    test('a carriage return keeps what the terminal would show', () {
      expect(stripNonSgr('10%\r50%\r100%\nnext'), '100%\nnext');
    });
  });

  group('shellResultOf', () {
    test('reads the JSON form and its exit code', () {
      final call = ToolCall(
        name: 'bash',
        arguments: const {'command': 'false'},
        result: '{"success":false,"exit_code":2,"error":"boom","output":"out"}',
        status: ToolCallStatus.completed,
      );
      final r = shellResultOf(call)!;
      expect(r.command, 'false');
      expect(r.exitCode, 2);
      expect(r.output, 'out\nboom');
    });

    test('reads the exit code the host put on the arguments', () {
      final call = ToolCall(
        name: 'run_command',
        arguments: {'command': 'ls', 'exit_code': 0},
        result: 'a\nb',
        status: ToolCallStatus.completed,
      );
      expect(shellResultOf(call)!.exitCode, 0);
    });

    test('reads stdout/stderr markers and [exit code: N]', () {
      final call = ToolCall(
        name: 'bash',
        result: '--- stdout ---\nhello\n--- stderr ---\nwarn\n[exit code: 1]',
        status: ToolCallStatus.completed,
      );
      final r = shellResultOf(call)!;
      expect(r.exitCode, 1);
      expect(r.output, startsWith('hello\nwarn'));
    });
  });

  group('TerminalBlock', () {
    testWidgets('over 16 lines keeps head 8 + tail 8 and folds the rest', (
      tester,
    ) async {
      final output = List.generate(40, (i) => 'line $i').join('\n');
      await _pump(tester, TerminalBlock(output: output, command: 'seq 40'));

      expect(find.text('line 0', findRichText: true), findsOneWidget);
      expect(find.text('line 7', findRichText: true), findsOneWidget);
      expect(find.text('line 8', findRichText: true), findsNothing);
      expect(find.text('line 32', findRichText: true), findsOneWidget);
      expect(find.text('line 39', findRichText: true), findsOneWidget);
      expect(find.text('24 lines hidden'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('terminal-expand')));
      await tester.pump();
      expect(find.text('line 20', findRichText: true), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('lines never wrap; the block scrolls sideways', (tester) async {
      await _pump(tester, TerminalBlock(output: 'x' * 400));
      final Iterable<Text> lines = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.textSpan?.toPlainText().contains('x' * 400) ?? false);
      expect(lines, hasLength(1));
      expect(lines.single.softWrap, isFalse);
      final scroll = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey<String>('terminal-hscroll')),
      );
      expect(scroll.scrollDirection, Axis.horizontal);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the exit capsule shows only for a non-zero code', (
      tester,
    ) async {
      await _pump(tester, const TerminalBlock(output: 'ok', exitCode: 0));
      expect(
        find.byKey(const ValueKey<String>('terminal-exit-code')),
        findsNothing,
      );

      await _pump(tester, const TerminalBlock(output: 'bad', exitCode: 127));
      expect(
        find.byKey(const ValueKey<String>('terminal-exit-code')),
        findsOneWidget,
      );
      expect(find.text('exit 127'), findsOneWidget);
    });

    testWidgets('a short output has no fold row', (tester) async {
      await _pump(tester, const TerminalBlock(output: 'a\nb\nc'));
      expect(
        find.byKey(const ValueKey<String>('terminal-expand')),
        findsNothing,
      );
    });
  });
}
