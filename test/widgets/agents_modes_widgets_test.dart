import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/widgets/agents_action_approval_card.dart';
import 'package:chuk_chat/widgets/agents_context_chip.dart';
import 'package:chuk_chat/widgets/agents_goal_strip.dart';
import 'package:chuk_chat/widgets/agents_mode_bar.dart';
import 'package:chuk_chat/widgets/agents_plan_review_card.dart';
import 'package:chuk_chat/widgets/agents_question_card.dart';
import 'package:chuk_chat/widgets/agents_todo_card.dart';
import 'package:chuk_chat/widgets/agents_wait_label.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  ),
);

AgentsGoal _goal({String phase = 'active', String activation = 'armed'}) =>
    AgentsGoal.fromJson(<String, dynamic>{
      'id': 'g',
      'revision': 1,
      'objective': 'Make the test suite green across every package',
      'phase': phase,
      'activation': activation,
      'rounds_started': 3,
      'max_rounds': 50,
      if (phase == 'blocked')
        'blocked_reason': <String, dynamic>{
          'code': 'model-reported',
          'message': 'Needs the API key',
        },
    })!;

AgentsQuestionRequest _question({String status = 'open'}) =>
    AgentsQuestionRequest.fromPayload(<String, dynamic>{
      'question_id': 'call_0',
      'session_key': 't1',
      'status': status,
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'db',
          'question': 'Which database?',
          'options': <Map<String, dynamic>>[
            <String, dynamic>{'label': 'SQLite (Recommended)'},
            <String, dynamic>{'label': 'Postgres'},
          ],
        },
        <String, dynamic>{
          'id': 'os',
          'question': 'Which targets?',
          'multi_select': true,
          'options': <Map<String, dynamic>>[
            <String, dynamic>{'label': 'Linux'},
            <String, dynamic>{'label': 'Mac'},
          ],
        },
      ],
    })!;

void main() {
  testWidgets('goal strip: phase, rounds, pause and clear', (tester) async {
    final List<String> actions = <String>[];
    await tester.pumpWidget(
      _host(AgentsGoalStrip(goal: _goal(), onControl: actions.add)),
    );
    expect(find.textContaining('Round 3 of 50'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-goal-resume')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('agents-goal-pause')));
    await tester.tap(find.byKey(const ValueKey<String>('agents-goal-clear')));
    expect(actions, <String>['pause', 'clear']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blocked goal says why and offers Resume', (tester) async {
    final List<String> actions = <String>[];
    await tester.pumpWidget(
      _host(
        AgentsGoalStrip(
          goal: _goal(phase: 'blocked'),
          onControl: actions.add,
        ),
      ),
    );
    expect(find.text('Needs the API key'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('agents-goal-resume')));
    expect(actions, <String>['resume']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('todo card: collapsed shows the item in progress', (
    tester,
  ) async {
    final List<AgentsTodo> todos = AgentsTodo.listFrom(<Map<String, dynamic>>[
      <String, dynamic>{'content': 'Plan', 'status': 'completed'},
      <String, dynamic>{'content': 'Run the tests', 'status': 'in_progress'},
      <String, dynamic>{'content': 'Write docs', 'status': 'pending'},
    ]);
    await tester.pumpWidget(_host(AgentsTodoCard(todos: todos)));
    expect(find.text('Run the tests'), findsOneWidget);
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('Write docs'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('agents-todo-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Write docs'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('agents-todo-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('agents-todo-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Write docs'), findsNothing);
  });

  testWidgets(
    'question card: recommended preselected, multi select, sends answers',
    (tester) async {
      final List<bool> visible = <bool>[];
      List<AgentsQuestionAnswer>? got;
      await tester.pumpWidget(
        _host(
          AgentsQuestionCard(
            request: _question(),
            onVisible: visible.add,
            onSubmit: (List<AgentsQuestionAnswer> a) async {
              got = a;
              return true;
            },
          ),
        ),
      );
      expect(visible, <bool>[true]);
      expect(find.text('SQLite'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('agents-question-recommended')),
        findsOneWidget,
      );
      expect(find.text('1 of 2'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('agents-question-next')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-question-next')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Which targets?'), findsOneWidget);
      await tester.tap(find.text('Linux'));
      await tester.tap(find.text('Mac'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('agents-question-custom-os')),
        'BSD too',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('agents-question-next')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-question-next')),
      );
      await tester.pump();
      expect(got!.first.selected, <String>['SQLite (Recommended)']);
      expect(got!.last.selected, <String>['Linux', 'Mac']);
      expect(got!.last.custom, 'BSD too');
      await tester.pumpWidget(_host(const SizedBox()));
      expect(visible, <bool>[true, false]);
    },
  );

  testWidgets('question card: Skip sends an empty answer; failure shows', (
    tester,
  ) async {
    List<AgentsQuestionAnswer>? got;
    await tester.pumpWidget(
      _host(
        AgentsQuestionCard(
          request: _question(status: 'pending'),
          onSubmit: (List<AgentsQuestionAnswer> a) async {
            got = a;
            return false;
          },
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('agents-question-pending')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('agents-question-skip')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-question-skip')),
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('agents-question-skip')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-question-skip')),
    );
    await tester.pump();
    expect(got!.every((AgentsQuestionAnswer a) => a.isSkip), isTrue);
    expect(
      find.byKey(const ValueKey<String>('agents-question-failed')),
      findsOneWidget,
    );
  });

  testWidgets('answered bubble shows the picks', (tester) async {
    final AgentsQuestionRequest answered = _question().copyWith(
      status: 'answered',
      answers: const <AgentsQuestionAnswer>[
        AgentsQuestionAnswer(
          id: 'db',
          selected: <String>['SQLite (Recommended)'],
        ),
      ],
    );
    await tester.pumpWidget(
      _host(AgentsQuestionAnsweredBubble(request: answered)),
    );
    expect(find.text('SQLite'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
  });

  AgentsRelayApprovalRequest planRequest({String? decision}) =>
      AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
        'approval_id': 'p1',
        'action': 'plan_review',
        'kind': 'plan_review',
        'action_class': 'plan_review',
        'options': <String>['approve', 'keep_planning'],
        'summary': 'Refactor the parser',
        'plan': '# Refactor the parser\n\n1. Split the lexer.\n2. Add tests.',
        'decision': ?decision,
      })!;

  testWidgets('plan review: Approve once, then the buttons go', (tester) async {
    final List<(bool, String?)> calls = <(bool, String?)>[];
    await tester.pumpWidget(
      _host(
        AgentsPlanReviewCard(
          request: planRequest(),
          onDecide: (bool a, String? f) => calls.add((a, f)),
        ),
      ),
    );
    expect(planRequest().isPlanReview, isTrue);
    expect(find.textContaining('Split the lexer'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-plan-review-approve')),
    );
    expect(calls.single, (true, null));
    await tester.pumpWidget(
      _host(
        AgentsPlanReviewCard(
          request: planRequest(),
          decision: true,
          onDecide: (bool a, String? f) => calls.add((a, f)),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('agents-plan-review-approve')),
      findsNothing,
    );
    expect(find.text('Plan approved'), findsOneWidget);
  });

  testWidgets('plan review: Keep planning sends the feedback', (tester) async {
    final List<(bool, String?)> calls = <(bool, String?)>[];
    await tester.pumpWidget(
      _host(
        AgentsPlanReviewCard(
          request: planRequest(),
          onDecide: (bool a, String? f) => calls.add((a, f)),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-plan-review-keep')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agents-plan-review-feedback')),
      'Keep the old API',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-plan-review-send')),
    );
    expect(calls.single, (false, 'Keep the old API'));
  });

  AgentsRelayApprovalRequest shellRequest() =>
      AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
        'approval_id': 'a1',
        'action': 'action_approval',
        'tool': 'run_command',
        'options': <String>['once', 'always_this_prefix', 'deny'],
        'summary': 'Run a command',
        'details': <String, dynamic>{'command': 'git push origin master'},
      })!;

  testWidgets('approval card offers Always allow <prefix>', (tester) async {
    final List<String> picked = <String>[];
    await tester.pumpWidget(
      _host(
        AgentsActionApprovalCard(
          request: shellRequest(),
          agentName: 'Ada',
          onSelect: picked.add,
        ),
        width: 420,
      ),
    );
    expect(find.text('Always allow git push'), findsOneWidget);
    expect(find.text('git push origin master'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('agents-approval-option-always_this_prefix'),
      ),
    );
    expect(picked, <String>['always_this_prefix']);
  });

  testWidgets('approval card: Enter allows once, Esc denies, not in a field', (
    tester,
  ) async {
    final List<String> picked = <String>[];
    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            const TextField(key: ValueKey<String>('other-field')),
            AgentsActionApprovalCard(
              request: shellRequest(),
              agentName: 'Ada',
              keyboardShortcuts: true,
              onSelect: picked.add,
            ),
          ],
        ),
        width: 420,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('agents-approval-keys-hint')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked, <String>['once']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(picked, <String>['once', 'deny']);
    // Typing in a field: Enter belongs to the field.
    await tester.tap(find.byKey(const ValueKey<String>('other-field')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked, <String>['once', 'deny']);
  });

  testWidgets('approval card: a decided card ignores the keys', (tester) async {
    final List<String> picked = <String>[];
    await tester.pumpWidget(
      _host(
        AgentsActionApprovalCard(
          request: shellRequest(),
          agentName: 'Ada',
          decision: 'once',
          keyboardShortcuts: true,
          onSelect: picked.add,
        ),
        width: 420,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked, isEmpty);
  });

  testWidgets('context chip: a label, the text on tap', (tester) async {
    await tester.pumpWidget(
      _host(
        const AgentsContextChip(
          source: 'goal',
          text: '<goal_round>\nObjective: "Ship"\nRound: 2/50\n</goal_round>',
        ),
      ),
    );
    expect(find.text('Goal round'), findsOneWidget);
    expect(find.text('Objective: "Ship"'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-context-chip-goal')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('agents-context-chip-text')),
      findsOneWidget,
    );
  });

  testWidgets('wait pill words', (tester) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: <Widget>[
            AgentsWaitPill(kind: AgentsWaitKind.approval),
            AgentsWaitPill(kind: AgentsWaitKind.answer),
            AgentsWaitPill(kind: AgentsWaitKind.planReview),
            AgentsWaitPill(kind: AgentsWaitKind.needsYou),
          ],
        ),
      ),
    );
    for (final String word in <String>[
      'Approval',
      'Answer',
      'Plan review',
      'Needs you',
    ]) {
      expect(find.text(word), findsOneWidget);
    }
  });

  testWidgets('mode bar: plan toggle, todo, goal and sandbox banner', (
    tester,
  ) async {
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
    final AgentsThreadModes modes = AgentsThreadModes(
      send: (Map<String, dynamic> f) async => sent.add(f),
    );
    await tester.pumpWidget(
      _host(AgentsModeBar(threadKey: 't1', modes: modes)),
    );
    expect(find.text('Plan mode'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-goal-strip')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-plan-mode-chip')),
    );
    await tester.pump();
    expect(modes.planToggleOf('t1'), isTrue);
    modes
      ..ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 't1',
        'goal': <String, dynamic>{
          'id': 'g',
          'objective': 'Ship',
          'phase': 'active',
          'activation': 'armed',
        },
      })
      ..ingest(<String, dynamic>{
        'type': 'todo',
        'session_key': 't1',
        'todos': <Map<String, dynamic>>[
          <String, dynamic>{'content': 'A', 'status': 'in_progress'},
        ],
      })
      ..ingest(<String, dynamic>{
        'type': 'agent_permissions',
        'sandbox': <String, dynamic>{'kind': 'local', 'fallback': true},
      });
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('agents-goal-strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agents-todo-card')),
      findsOneWidget,
    );
    expect(
      find.text('Running without sandbox: Docker unavailable'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('agents-goal-pause')));
    await tester.pump();
    expect(sent.single['type'], 'goal_control');
    expect(sent.single['action'], 'pause');
    expect(tester.takeException(), isNull);
  });
}
