// The approval cards of the agent's own commands (docs/WIRE_CONTRACT.md,
// "Sandbox escalation" and "Auto review"): one command with more
// permissions, the reviewer's verdict, and the `local_actions` card in mode
// `ask`. At phone width (360 px, 1.3 text) and desktop width.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/agents_action_approval_card.dart';

import '../support/test_app.dart';

AgentsRelayApprovalRequest _req({
  String kind = 'sandbox_escalation',
  String actionClass = 'sandbox_escalation',
  List<String> options = const <String>['once', 'deny'],
  String? summary = 'Run one command with internet access: npm needs it',
  Map<String, dynamic>? details,
  String? decision,
  String? decisionReason,
  bool replay = false,
}) => AgentsRelayApprovalRequest(
  approvalId: 'ap-1',
  action: 'action_approval',
  path: '',
  name: '',
  fileCount: 0,
  totalBytes: 0,
  baseUrl: '',
  public: false,
  sessionKey: 'thread-1',
  takeoverKind: kind,
  actionClass: actionClass,
  options: options,
  summary: summary,
  tool: 'run_command',
  details: details,
  decision: decision,
  decisionReason: decisionReason,
  replay: replay,
);

Map<String, dynamic> _escDetails({String command = 'npm install'}) =>
    <String, dynamic>{
      'kind': 'sandbox_escalation',
      'permissions': <String>['network', 'workspace_write', 'sudo'],
      'justification': 'The install needs the registry.',
      'command': command,
    };

Map<String, dynamic> _reviewDetails({Map<String, dynamic>? review}) =>
    <String, dynamic>{
      'kind': 'auto_review',
      'local_tool': 'run_command',
      'command': 'rm -rf build',
      'review':
          review ??
          <String, dynamic>{
            'valid': true,
            'risk': 'medium',
            'decision': 'deny',
            'reason': 'Deletes a directory.',
          },
    };

Future<void> _pump(
  WidgetTester tester,
  AgentsRelayApprovalRequest request, {
  Size size = const Size(1280, 1000),
  double textScale = 1,
  ValueChanged<String>? onSelect,
  String? decision,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: AgentsActionApprovalCard(
                  request: request,
                  agentName: 'Ada',
                  decision: decision,
                  dense: size.width > 600,
                  onSelect: onSelect ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  const List<(String, Size, double)> sizes = <(String, Size, double)>[
    ('360 px at 1.3 text', Size(360, 1400), 1.3),
    ('desktop', Size(1280, 1000), 1),
  ];

  for (final (String name, Size size, double scale) in sizes) {
    group(name, () {
      testWidgets('sandbox escalation: title, permissions in words, quote, '
          'command, Allow once / Deny', (tester) async {
        final List<String> picked = <String>[];
        await _pump(
          tester,
          _req(
            details: _escDetails(),
            // A host that lists more must still not get an "always".
            options: const <String>['once', 'always_this_agent', 'deny'],
          ),
          size: size,
          textScale: scale,
          onSelect: picked.add,
        );
        expect(
          find.text('Run one command with more permissions'),
          findsOneWidget,
        );
        expect(find.text('Internet'), findsOneWidget);
        expect(find.text('Write to the workspace'), findsOneWidget);
        expect(find.text('Admin rights (sudo)'), findsOneWidget);
        expect(find.text('The install needs the registry.'), findsOneWidget);
        expect(find.text('npm install'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('agents-approval-option-once')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>('agents-approval-option-always_this_agent'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-approval-option-once')),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-approval-option-deny')),
        );
        expect(picked, <String>['once', 'deny']);
      });

      testWidgets('a long command is cut after 6 lines and expands', (
        tester,
      ) async {
        final String command = List<String>.generate(
          10,
          (int i) => 'echo line$i',
        ).join('\n');
        await _pump(
          tester,
          _req(details: _escDetails(command: command)),
          size: size,
          textScale: scale,
        );
        final Finder code = find.descendant(
          of: find.byKey(const ValueKey<String>('agents-esc-command')),
          matching: find.byKey(const ValueKey<String>('agents-code-text')),
        );
        expect(tester.widget<Text>(code).data, contains('line5'));
        expect(tester.widget<Text>(code).data, isNot(contains('line6')));
        await tester.tap(find.text('Show all'));
        await tester.pump();
        expect(tester.widget<Text>(code).data, contains('line9'));
        expect(find.text('Show less'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('auto review: the reviewer line and only Allow once / Deny', (
        tester,
      ) async {
        await _pump(
          tester,
          _req(
            kind: 'auto_review',
            actionClass: 'local_actions',
            summary: null,
            details: _reviewDetails(),
            options: const <String>['once', 'always_this_agent', 'deny'],
          ),
          size: size,
          textScale: scale,
        );
        expect(find.text('Run this command?'), findsOneWidget);
        expect(
          find.text('Reviewer: medium risk — Deletes a directory.'),
          findsOneWidget,
        );
        expect(find.text('rm -rf build'), findsOneWidget);
        expect(
          find.byKey(
            const ValueKey<String>('agents-approval-option-always_this_agent'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('agents-approval-option-deny')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('auto review with an unusable answer', (tester) async {
        await _pump(
          tester,
          _req(
            kind: 'auto_review',
            actionClass: 'local_actions',
            details: _reviewDetails(
              review: <String, dynamic>{'valid': false, 'reason': 'prose'},
            ),
          ),
          size: size,
          textScale: scale,
        );
        expect(find.text('The reviewer could not decide'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('local_actions in mode ask: path, preview, buttons from '
          'options', (tester) async {
        await _pump(
          tester,
          _req(
            kind: '',
            actionClass: 'local_actions',
            summary: null,
            details: <String, dynamic>{
              'local_tool': 'write_file',
              'path': 'notes/todo.md',
              'preview': '- buy milk',
            },
            options: const <String>['once', 'always_this_agent', 'deny'],
          ),
          size: size,
          textScale: scale,
        );
        expect(find.text('Write this file?'), findsOneWidget);
        expect(find.textContaining('notes/todo.md'), findsOneWidget);
        expect(find.text('- buy milk'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('agents-review-line')),
          findsNothing,
        );
        expect(
          find.byKey(
            const ValueKey<String>('agents-approval-option-always_this_agent'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('a decided escalation replays as information', (tester) async {
    await _pump(
      tester,
      _req(details: _escDetails(), decision: 'approved', replay: true),
    );
    expect(find.text('Allowed once'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-approval-option-once')),
      findsNothing,
    );
    await _pump(
      tester,
      _req(details: _escDetails(), decision: 'denied', replay: true),
    );
    expect(find.text('Denied'), findsOneWidget);
  });

  testWidgets('the answer the user gave says Allowed once', (tester) async {
    await _pump(tester, _req(details: _escDetails()), decision: 'once');
    expect(find.text('Allowed once'), findsOneWidget);
  });

  testWidgets('German', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AgentsActionApprovalCard(
            request: _req(details: _escDetails()),
            agentName: 'Ada',
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('Einen Befehl mit mehr Rechten ausführen'),
      findsOneWidget,
    );
    expect(find.text('Admin-Rechte (sudo)'), findsOneWidget);
  });
}
