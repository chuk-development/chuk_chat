// "What did it do" under an answer (docs/WIRE_CONTRACT.md, "What did it do:
// run changes and undo", bead chuk_chat-4qry): the line, the sheet, and the
// undo flows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/services/agents/agents_run_changes.dart';
import 'package:chuk_chat/services/agents/agents_run_changes_service.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/widgets/agents_run_changes_line.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

import '../services/agents/agents_run_changes_test.dart' show runChangesFrame;

Widget _app(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (BuildContext context, Widget? inner) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: inner!,
  ),
  home: Scaffold(body: child),
);

/// A host stand-in: records every frame and answers through the service.
class _Host {
  _Host() {
    service = AgentsRunChangesService(
      send: (Map<String, dynamic> payload) async {
        sent.add(payload);
        final Map<String, dynamic>? answer = switch (payload['type']) {
          'run_changes_get' => changes,
          'run_undo' => undoAnswers.isEmpty ? null : undoAnswers.removeAt(0),
          _ => null,
        };
        if (answer != null) {
          scheduleMicrotask(() => service.handleFrame(answer));
        }
      },
      onUndone: undoneThreads.add,
    );
  }

  late final AgentsRunChangesService service;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<String> undoneThreads = <String>[];
  Map<String, dynamic> changes = runChangesFrame();
  final List<Map<String, dynamic>> undoAnswers = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get undos =>
      sent.where((p) => p['type'] == 'run_undo').toList();
}

Map<String, dynamic> _undoOk({int undone = 3}) => <String, dynamic>{
  'type': 'run_undo_result',
  'run_id': 'run-1',
  'session_key': 'thread-1',
  'ok': true,
  'reverted': <String>['notes/plan.md', 'logo.bin'],
  'conflicts': <Object>[],
  'changes': <String, dynamic>{'files': 3, 'undone': undone},
  'note': 'Files are restored. Sent mail stays sent.',
};

const AgentsRunChangesSummary _three = AgentsRunChangesSummary(
  files: 3,
  additions: 15,
  deletions: 10,
);

Widget _line(_Host host, {AgentsRunChangesSummary changes = _three}) =>
    AgentsRunChangesLine(
      runId: 'run-1',
      changes: changes,
      sessionKey: 'thread-1',
      service: host.service,
    );

/// The app's strings load asynchronously: one more frame after the pump.
Future<void> _pumpApp(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pump();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('agents-run-changes-line')),
  );
  await tester.pumpAndSettle();
}

Finder _undoButton() =>
    find.byKey(const ValueKey<String>('agents-run-changes-undo'));

Widget _item(List<ToolCall> calls) => ChatMessageListItem(
  messages: <Map<String, String>>[
    <String, String>{'sender': 'ai', 'text': 'done', 'messageId': 'a-1'},
  ],
  index: 0,
  data: MessageRenderData(
    sender: 'ai',
    displayText: 'done',
    reasoning: '',
    isReasoningStreaming: false,
    toolCalls: calls,
  ),
  uuid: const Uuid(),
  maxWidth: 500,
  activeChatId: 'thread-1',
  flyInKey: null,
  showToolCalls: true,
  showReasoningTokens: false,
  showModelInfo: false,
  showTps: false,
  isEditing: false,
  actions: const <MessageBubbleAction>[],
  userMessageActions: const <MessageBubbleAction>[],
  onSwitchVariant: (_) {},
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRunLedger.instance.reset();
  });
  tearDown(() => AgentsRunLedger.instance.reset());

  group('the line', () {
    testWidgets('none, some and all undone', (tester) async {
      final host = _Host();
      await _pumpApp(tester, _app(_line(host)));
      expect(find.text('3 files changed · Undo'), findsOneWidget);

      await _pumpApp(
        tester,
        _app(
          _line(
            host,
            changes: const AgentsRunChangesSummary(files: 3, undone: 1),
          ),
        ),
      );
      expect(find.text('3 files changed · 1 undone · Undo'), findsOneWidget);

      await _pumpApp(
        tester,
        _app(
          _line(
            host,
            changes: const AgentsRunChangesSummary(files: 3, undone: 3),
          ),
        ),
      );
      expect(find.text('Changes undone'), findsOneWidget);
      expect(find.textContaining('Undo'), findsNothing);

      await _pumpApp(
        tester,
        _app(_line(host, changes: const AgentsRunChangesSummary(files: 1))),
      );
      expect(find.text('1 file changed · Undo'), findsOneWidget);
    });

    testWidgets('German', (tester) async {
      await _pumpApp(
        tester,
        _app(
          _line(
            _Host(),
            changes: const AgentsRunChangesSummary(files: 3, undone: 1),
          ),
          locale: const Locale('de'),
        ),
      );
      expect(
        find.text('3 Dateien geändert · 1 rückgängig · Rückgängig'),
        findsOneWidget,
      );
    });

    testWidgets('in the chat list it sits under the answer, with no cost '
        'line', (
      tester,
    ) async {
      final original = AgentsRunChangesService.instance;
      AgentsRunChangesService.instance = _Host().service;
      addTearDown(() => AgentsRunChangesService.instance = original);
      final cost = AgentsRunCost.fromJson(<String, dynamic>{
        'eur': 0.41,
        'input_tokens': 5000,
        'output_tokens': 150,
      });
      await _pumpApp(
        tester,
        _app(
          _item(<ToolCall>[
            runMetaCall(cost: cost, runId: 'run-1', changes: _three)!,
          ]),
        ),
      );
      expect(find.text('€0.41 · 5.2k tokens'), findsNothing);
      expect(find.text('3 files changed · Undo'), findsOneWidget);
      final bubble = tester.widget<MessageBubble>(find.byType(MessageBubble));
      expect(bubble.toolCalls, isEmpty);

      // Without a run id there is nothing to ask the host about.
      await _pumpApp(
        tester,
        _app(_item(<ToolCall>[runMetaCall(changes: _three)!])),
      );
      expect(
        find.byKey(const ValueKey<String>('agents-run-changes-line')),
        findsNothing,
      );
    });
  });

  group('the sheet', () {
    testWidgets('one row per file, conflicts, the cap and the timeline', (
      tester,
    ) async {
      final host = _Host();
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);

      expect(host.sent.first, <String, dynamic>{
        'type': 'run_changes_get',
        'run_id': 'run-1',
      });
      expect(find.text('What this run changed'), findsOneWidget);
      expect(find.text('+15 −10'), findsOneWidget);
      for (final path in <String>[
        'notes/plan.md',
        'report.csv',
        'old.txt',
        'logo.bin',
      ]) {
        expect(find.text(path), findsOneWidget);
      }
      expect(find.text('+12 −0'), findsOneWidget);
      expect(find.text('Binary file'), findsOneWidget);
      expect(find.text('+0 −9 · Undone'), findsOneWidget);
      expect(find.text('Changed later by another run'), findsOneWidget);
      expect(find.text('2 more files are not listed'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('agents-run-changes-boundary')),
        findsOneWidget,
      );

      Checkbox box(String path) => tester.widget<Checkbox>(
        find.byKey(ValueKey<String>('agents-run-changes-check-$path')),
      );
      expect(box('notes/plan.md').value, isTrue);
      expect(box('logo.bin').value, isTrue);
      // A conflicting file can be ticked, but is not by default.
      expect(box('report.csv').value, isFalse);
      // An undone file has nothing left to tick.
      expect(
        find.byKey(const ValueKey<String>('agents-run-changes-check-old.txt')),
        findsNothing,
      );
      expect(find.text('Undo 2 files'), findsOneWidget);

      // The timeline starts collapsed.
      expect(find.text('4 steps'), findsOneWidget);
      expect(find.text('write_file: notes/plan.md'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-run-changes-timeline')),
      );
      await tester.pumpAndSettle();
      expect(find.text('write_file: notes/plan.md'), findsOneWidget);
    });

    testWidgets('a run that changed nothing says why and offers no Undo', (
      tester,
    ) async {
      final host = _Host()
        ..changes = <String, dynamic>{
          'type': 'run_changes',
          'run_id': 'run-1',
          'files': <Object>[],
          'commits': <Object>[],
          'undoable': false,
          'reason': 'no_history',
        };
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      expect(
        find.text(
          'This workspace keeps no history, so there is nothing to undo.',
        ),
        findsOneWidget,
      );
      expect(_undoButton(), findsNothing);
    });
  });

  group('undo', () {
    testWidgets('ok: the checked paths go out, the line updates, a snackbar '
        'and the note once', (tester) async {
      final host = _Host()..undoAnswers.add(_undoOk());
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();

      expect(host.undos.single, <String, dynamic>{
        'type': 'run_undo',
        'run_id': 'run-1',
        'paths': <String>['notes/plan.md', 'logo.bin'],
      });
      expect(find.text('What this run changed'), findsNothing);
      expect(find.text('2 files undone'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('agents-run-undo-note')),
        findsOneWidget,
      );
      expect(
        find.text('Files are restored. Sent mail stays sent.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Changes undone'), findsOneWidget);
      expect(host.undoneThreads, <String>['thread-1']);

      // A second undo does not show the note again.
      host
        ..changes = runChangesFrame()
        ..undoAnswers.add(_undoOk());
      await _openSheet(tester);
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('agents-run-undo-note')),
        findsNothing,
      );
    });

    testWidgets('conflicts: a dialog lists them; Undo anyway sends force', (
      tester,
    ) async {
      final host = _Host()
        ..undoAnswers.addAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'run_undo_result',
            'run_id': 'run-1',
            'ok': false,
            'code': 'conflicts',
            'reverted': <Object>[],
            'conflicts': <Map<String, dynamic>>[
              <String, dynamic>{'path': 'report.csv', 'reason': 'uncommitted'},
            ],
          },
          _undoOk(),
        ]);
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('agents-run-changes-check-report.csv'),
        ),
      );
      await tester.pump();
      expect(find.text('Undo 3 files'), findsOneWidget);
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();

      final dialog = find.byKey(
        const ValueKey<String>('agents-run-undo-conflicts'),
      );
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('report.csv')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Edited, not saved yet'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-run-undo-anyway')),
      );
      await tester.pumpAndSettle();

      expect(host.undos, hasLength(2));
      expect(host.undos.first.containsKey('force'), isFalse);
      expect(host.undos.last['force'], isTrue);
      expect(host.undos.last['paths'], <String>[
        'notes/plan.md',
        'report.csv',
        'logo.bin',
      ]);
      expect(find.text('What this run changed'), findsNothing);
      expect(find.text('2 files undone'), findsOneWidget);
    });

    testWidgets('conflicts: Cancel sends nothing more', (tester) async {
      final host = _Host()
        ..undoAnswers.add(<String, dynamic>{
          'type': 'run_undo_result',
          'run_id': 'run-1',
          'ok': false,
          'code': 'conflicts',
          'conflicts': <Map<String, dynamic>>[
            <String, dynamic>{
              'path': 'report.csv',
              'reason': 'changed_later',
              'outside': true,
            },
          ],
        });
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();
      expect(find.text('Changed by you'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.undos, hasLength(1));
      expect(find.text('What this run changed'), findsOneWidget);
    });

    testWidgets('run_active: wait, and the button is off', (tester) async {
      final host = _Host()
        ..undoAnswers.add(<String, dynamic>{
          'type': 'run_undo_result',
          'run_id': 'run-1',
          'ok': false,
          'code': 'run_active',
          'error': 'A run works in this workspace right now.',
        });
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();
      expect(find.text('Wait until the agent is done'), findsOneWidget);
      await tester.tap(_undoButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(host.undos, hasLength(1));
    });

    testWidgets('while the thread runs the button is off; when it ends the '
        'sheet asks again', (tester) async {
      final host = _Host();
      final ledger = AgentsRunLedger.instance..begin('thread-1');
      await _pumpApp(tester, _app(_line(host)));
      await _openSheet(tester);
      expect(find.text('Wait until the agent is done'), findsOneWidget);
      await tester.tap(_undoButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(host.undos, isEmpty);

      ledger.finish('thread-1', reason: 'finished');
      await tester.pumpAndSettle();
      expect(find.text('Wait until the agent is done'), findsNothing);
      expect(
        host.sent.where((p) => p['type'] == 'run_changes_get'),
        hasLength(2),
      );
      host.undoAnswers.add(_undoOk());
      await tester.tap(_undoButton());
      await tester.pumpAndSettle();
      expect(host.undos, hasLength(1));
    });
  });

  testWidgets('360 px at 1.3 text scale: line and sheet fit', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final original = AgentsRunChangesService.instance;
    final host = _Host();
    AgentsRunChangesService.instance = host.service;
    addTearDown(() => AgentsRunChangesService.instance = original);
    final cost = AgentsRunCost.fromJson(<String, dynamic>{
      'eur': 12.41,
      'input_tokens': 1250000,
      'output_tokens': 150,
    });
    await _pumpApp(
      tester,
      _app(
        _item(<ToolCall>[
          runMetaCall(
            cost: cost,
            runId: 'run-1',
            changes: const AgentsRunChangesSummary(files: 312, undone: 120),
          )!,
        ]),
        locale: const Locale('de'),
        textScale: 1.3,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.text('312 Dateien geändert · 120 rückgängig · Rückgängig'),
      findsOneWidget,
    );
    await _openSheet(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-run-changes-timeline')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
