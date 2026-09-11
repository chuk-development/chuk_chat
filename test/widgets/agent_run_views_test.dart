import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_run_views.dart';

/// A 1x1 transparent PNG — the smallest real image to prove a preview renders.
final Uint8List _pngBytes = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842'
  'iQAAAABJRU5ErkJggg==',
);

class _RecordingSaver implements AgentFileSaver {
  final List<String> saved = <String>[];
  Object? failWith;

  @override
  Future<String> save(CoworkRelayFile file) async {
    final error = failWith;
    if (error != null) throw error;
    saved.add(file.name);
    return '/tmp/${file.name}';
  }
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('AgentToolLine', () {
    testWidgets('collapsed it is one line; tapping opens the full output', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const AgentToolLine(
            call: CoworkRelayTool(
              'run_command',
              arguments: 'ls /tmp',
              result: 'a.txt',
              detail: 'a.txt\nb.txt',
              exitCode: 0,
            ),
          ),
        ),
      );

      // The summary is there, the detail is not.
      expect(find.textContaining('run_command'), findsOneWidget);
      expect(find.textContaining('a.txt\nb.txt'), findsNothing);
      expect(findIcon(Icons.expand_more), findsOneWidget);

      await tester.tap(findIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      expect(find.textContaining('a.txt\nb.txt'), findsOneWidget);
      expect(findIcon(Icons.expand_less), findsOneWidget);

      // And it closes again.
      await tester.tap(findIcon(Icons.expand_less));
      await tester.pumpAndSettle();
      expect(find.textContaining('a.txt\nb.txt'), findsNothing);
    });

    testWidgets('a failed call looks different from a successful one', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              AgentToolLine(
                key: Key('ok'),
                call: CoworkRelayTool(
                  'run_command',
                  arguments: 'true',
                  exitCode: 0,
                ),
              ),
              AgentToolLine(
                key: Key('bad'),
                call: CoworkRelayTool(
                  'run_command',
                  arguments: 'ls /nope',
                  result: 'No such file or directory',
                  exitCode: 2,
                  failed: true,
                ),
              ),
            ],
          ),
        ),
      );

      // Different icon: a check for the good one, an error mark for the bad one.
      expect(findIcon(Icons.check_circle_outline), findsOneWidget);
      expect(findIcon(Icons.error_outline), findsOneWidget);
      expect(find.textContaining('exit 2'), findsOneWidget);

      // And a different colour, taken from the theme's error role.
      final context = tester.element(find.byType(AgentToolLine).first);
      final errorColor = Theme.of(context).colorScheme.error;
      expect(iconColor(tester, findIcon(Icons.error_outline)), errorColor);
      expect(
        iconColor(tester, findIcon(Icons.check_circle_outline)),
        isNot(errorColor),
      );
    });

    testWidgets('a duration is shown only when the host reported one', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const AgentToolLine(
            call: CoworkRelayTool(
              'run_command',
              arguments: 'sleep 2',
              exitCode: 0,
              duration: Duration(seconds: 2),
            ),
          ),
        ),
      );
      expect(find.textContaining('2.0s'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          const AgentToolLine(
            key: Key('no-duration'),
            call: CoworkRelayTool(
              'run_command',
              arguments: 'sleep 2',
              exitCode: 0,
            ),
          ),
        ),
      );
      expect(find.textContaining('2.0s'), findsNothing);
    });
  });

  group('AgentReasoningBlock', () {
    testWidgets('reasoning is folded away and never shown as the answer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const AgentReasoningBlock(text: 'first I check the log')),
      );

      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('first I check the log'), findsNothing);

      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      expect(find.text('first I check the log'), findsOneWidget);
    });
  });

  group('AgentFileCard', () {
    testWidgets('an image file shows a preview', (tester) async {
      await tester.pumpWidget(
        _host(
          AgentFileCard(
            file: CoworkRelayFile(
              name: 'screenshot.png',
              mimeType: 'image/png',
              declaredSize: _pngBytes.length,
              bytes: _pngBytes,
            ),
            saver: _RecordingSaver(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('screenshot.png'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('a non-image file saves through the injected saver', (
      tester,
    ) async {
      final saver = _RecordingSaver();
      await tester.pumpWidget(
        _host(
          AgentFileCard(
            file: CoworkRelayFile(
              name: 'report.csv',
              mimeType: 'text/csv',
              declaredSize: 3,
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
            ),
            saver: saver,
          ),
        ),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('text/csv'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saver.saved, <String>['report.csv']);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.textContaining('/tmp/report.csv'), findsOneWidget);
    });

    testWidgets('a save that fails says so instead of looking done', (
      tester,
    ) async {
      final saver = _RecordingSaver()
        ..failWith = UnsupportedError('no filesystem here');
      await tester.pumpWidget(
        _host(
          AgentFileCard(
            file: CoworkRelayFile(
              name: 'report.csv',
              mimeType: 'text/csv',
              declaredSize: 3,
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
            ),
            saver: saver,
          ),
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no filesystem here'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('a broken body becomes an error card, with no save action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AgentFileCard(
            file: const CoworkRelayFile(
              name: 'shot.png',
              mimeType: 'image/png',
              declaredSize: 12,
              error: 'The file body is not valid base64.',
            ),
            saver: _RecordingSaver(),
          ),
        ),
      );

      expect(find.text('The file body is not valid base64.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Save'), findsNothing);
      // The name is still shown, so the user knows what failed.
      expect(find.text('shot.png'), findsOneWidget);
    });
  });

  group('formatBytes', () {
    test('reads like a file manager', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });

  group('sanitizeAgentFileName', () {
    test('a name from the wire can never escape the target directory', () {
      expect(sanitizeAgentFileName('../../.bashrc'), '.bashrc');
      expect(sanitizeAgentFileName('/etc/passwd'), 'passwd');
      expect(sanitizeAgentFileName(r'dir\evil.sh'), 'evil.sh');
      expect(sanitizeAgentFileName('..'), 'agent-file');
      expect(sanitizeAgentFileName('   '), 'agent-file');
      expect(sanitizeAgentFileName('report.csv'), 'report.csv');
    });
  });
}
