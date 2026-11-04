import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_thread_modes.dart';

void main() {
  late AgentsThreadModes modes;
  late List<Map<String, dynamic>> sent;

  setUp(() {
    sent = <Map<String, dynamic>>[];
    modes = AgentsThreadModes(send: (Map<String, dynamic> f) async {
      sent.add(f);
    });
  });

  Map<String, dynamic> goal({
    String phase = 'active',
    String activation = 'armed',
    bool needsUser = false,
  }) => <String, dynamic>{
    'id': 'g_1',
    'revision': 3,
    'objective': 'Ship the release',
    'phase': phase,
    'activation': activation,
    'rounds_started': 4,
    'max_rounds': 50,
    if (phase == 'blocked')
      'blocked_reason': <String, dynamic>{
        'code': 'round-limit',
        'message': 'Limit reached',
      },
    'needs_user': needsUser,
  };

  group('goal', () {
    test('a goal frame sets the goal, null clears it', () {
      modes.ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 't1',
        'goal': goal(),
      });
      final AgentsGoal g = modes.goalOf('t1')!;
      expect(g.objective, 'Ship the release');
      expect(g.roundsStarted, 4);
      expect(g.maxRounds, 50);
      expect(g.canPause, isTrue);
      expect(g.canResume, isFalse);
      modes.ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 't1',
        'goal': null,
      });
      expect(modes.goalOf('t1'), isNull);
    });

    test('a disarmed or blocked goal offers Resume; blocked needs you', () {
      modes.ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 't1',
        'goal': goal(activation: 'disarmed'),
      });
      expect(modes.goalOf('t1')!.canResume, isTrue);
      modes.ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 't1',
        'goal': goal(phase: 'blocked', needsUser: true),
      });
      final AgentsGoal g = modes.goalOf('t1')!;
      expect(g.blockedCode, 'round-limit');
      expect(g.blockedMessage, 'Limit reached');
      expect(modes.waitKindOf('t1'), AgentsWaitKind.needsYou);
    });

    test('goal_control sends the action for the thread', () async {
      expect(await modes.goalControl('t1', 'pause'), isTrue);
      expect(sent.single, <String, dynamic>{
        'type': 'goal_control',
        'session_key': 't1',
        'action': 'pause',
      });
    });

    test('a failed send reports false', () async {
      modes.sender = (_) async => throw StateError('offline');
      expect(await modes.goalControl('t1', 'resume'), isFalse);
    });
  });

  group('plan mode', () {
    test('the toggle is pending until the host confirms', () {
      expect(modes.planToggleOf('t1'), isFalse);
      modes.setPlanWanted('t1', true);
      expect(modes.planToggleOf('t1'), isTrue);
      expect(modes.planModeOf('t1'), isFalse);
      // The next task carries it once.
      expect(modes.takePlanFlag('t1'), isTrue);
      expect(modes.takePlanFlag('t1'), isNull);
      modes.ingest(<String, dynamic>{
        'type': 'plan_mode',
        'session_key': 't1',
        'active': true,
      });
      expect(modes.planModeOf('t1'), isTrue);
      expect(modes.planToggleOf('t1'), isTrue);
    });

    test('toggling back to the host state leaves the key off', () {
      modes.setPlanWanted('t1', true);
      modes.setPlanWanted('t1', false);
      expect(modes.takePlanFlag('t1'), isNull);
    });

    test('run_state is the whole mode state', () {
      modes.ingest(<String, dynamic>{
        'type': 'run_state',
        'session_key': 't1',
        'state': 'running',
        'plan_mode': true,
        'goal': goal(),
        'todos': <Map<String, dynamic>>[
          <String, dynamic>{'content': 'A', 'status': 'in_progress'},
        ],
        'source': 'goal',
      });
      expect(modes.planModeOf('t1'), isTrue);
      expect(modes.goalOf('t1'), isNotNull);
      expect(modes.todosOf('t1'), hasLength(1));
      expect(modes.runSourceOf('t1'), 'goal');
      modes.ingest(<String, dynamic>{
        'type': 'run_state',
        'session_key': 't1',
        'state': 'idle',
      });
      expect(modes.planModeOf('t1'), isFalse);
      expect(modes.goalOf('t1'), isNull);
      expect(modes.todosOf('t1'), isEmpty);
      expect(modes.runSourceOf('t1'), isNull);
    });
  });

  test('todo frames keep the last list, unknown statuses read pending', () {
    modes.ingest(<String, dynamic>{
      'type': 'todo',
      'session_key': 't1',
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'content': 'Run the tests', 'status': 'in_progress'},
        <String, dynamic>{'content': 'Write docs', 'status': 'weird'},
        <String, dynamic>{'content': 'Plan', 'status': 'completed'},
        <String, dynamic>{'content': '  '},
      ],
    });
    final List<AgentsTodo> todos = modes.todosOf('t1');
    expect(todos.map((AgentsTodo t) => t.status), <String>[
      'in_progress',
      'pending',
      'completed',
    ]);
  });

  group('questions', () {
    Map<String, dynamic> request({String status = 'open'}) =>
        <String, dynamic>{
          'type': 'question_request',
          'question_id': 'call_0',
          'session_key': 't1',
          'timeout_seconds': 120,
          'status': status,
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'db',
              'question': 'Which database?',
              'header': 'Storage',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'label': 'SQLite (Recommended)'},
                <String, dynamic>{'label': 'Postgres', 'description': 'Big'},
              ],
            },
            <String, dynamic>{
              'id': 'os',
              'question': 'Targets?',
              'multi_select': true,
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'label': 'Linux'},
                <String, dynamic>{'label': 'Mac'},
              ],
            },
          ],
        };

    test('parses questions; recommended is preselected', () {
      modes.ingest(request());
      final AgentsQuestionRequest q = modes.questionOf('t1')!;
      expect(q.questions, hasLength(2));
      expect(q.questions.first.preselected, <String>['SQLite (Recommended)']);
      expect(q.questions.first.options.first.displayLabel, 'SQLite');
      expect(q.questions.first.options.first.recommended, isTrue);
      expect(q.questions.last.multiSelect, isTrue);
      expect(modes.waitKindOf('t1'), AgentsWaitKind.answer);
    });

    test('pending stays answerable after the run ends; open stops', () {
      modes.ingest(request(status: 'pending'));
      modes.ingest(<String, dynamic>{
        'type': 'done',
        'session_key': 't1',
        'reason': 'finished',
      });
      expect(modes.questionOf('t1')!.isAnswerable, isTrue);
      modes.ingest(request());
      modes.ingest(<String, dynamic>{
        'type': 'done',
        'session_key': 't1',
        'reason': 'finished',
      });
      expect(modes.questionOf('t1')!.isAnswerable, isFalse);
    });

    test('answerQuestion sends the answers and marks it answered', () async {
      modes.ingest(request());
      final AgentsQuestionRequest q = modes.questionOf('t1')!;
      final bool ok = await modes.answerQuestion(q, const <AgentsQuestionAnswer>[
        AgentsQuestionAnswer(id: 'db', selected: <String>['Postgres']),
        AgentsQuestionAnswer(id: 'os'),
      ]);
      expect(ok, isTrue);
      expect(sent.single['type'], 'question_answer');
      expect(sent.single['question_id'], 'call_0');
      expect(sent.single['answers'], <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'db',
          'selected': <String>['Postgres'],
        },
        <String, dynamic>{'id': 'os', 'selected': <String>[]},
      ]);
      expect(modes.questionOf('t1')!.isAnswered, isTrue);
      expect(modes.waitKindOf('t1'), isNull);
      expect(modes.questionOf('t1')!.summary(), 'Postgres\n-');
    });

    test('ask_visible is sent once per change', () async {
      await modes.setAskVisible('call_0', true);
      await modes.setAskVisible('call_0', true);
      await modes.setAskVisible('call_0', false);
      expect(sent.map((Map<String, dynamic> f) => f['visible']), <bool>[
        true,
        false,
      ]);
    });

    test('a late answer prompt reads as the picks', () {
      const String prompt =
          '<answer_to_pending_question callId="call_0">{"callId":"call_0",'
          '"questions":[{"id":"db","question":"Which?","options":'
          '[{"label":"SQLite (Recommended)"}]}],"answers":[{"id":"db",'
          '"selected":["SQLite (Recommended)"],"custom":"WAL on"}]}'
          '</answer_to_pending_question>';
      expect(pendingAnswerSummary(prompt), 'SQLite, WAL on');
      expect(pendingAnswerSummary('hello'), isNull);
    });
  });

  group('approvals', () {
    test('open approvals mark the thread; a plan review wins', () {
      modes.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 't1',
        'approval_id': 'a1',
        'action': 'action_approval',
      });
      expect(modes.waitKindOf('t1'), AgentsWaitKind.approval);
      modes.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 't1',
        'approval_id': 'p1',
        'action': 'plan_review',
      });
      expect(modes.waitKindOf('t1'), AgentsWaitKind.planReview);
      modes.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 't1',
        'approval_id': 'p1',
        'action': 'plan_review',
        'decision': 'denied',
        'decision_reason': 'timeout',
      });
      expect(modes.waitKindOf('t1'), AgentsWaitKind.approval);
      modes.approvalAnswered('t1', 'a1');
      expect(modes.waitKindOf('t1'), isNull);
    });

    test('a live done clears open approvals', () {
      modes.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 't1',
        'approval_id': 'a1',
      });
      modes.ingest(<String, dynamic>{
        'type': 'done',
        'session_key': 't1',
        'reason': 'replay',
      });
      expect(modes.waitKindOf('t1'), AgentsWaitKind.approval);
      modes.ingest(<String, dynamic>{
        'type': 'done',
        'session_key': 't1',
        'reason': 'finished',
      });
      expect(modes.waitKindOf('t1'), isNull);
    });

    test('waitKindOfAny picks the most urgent', () {
      modes.ingest(<String, dynamic>{
        'type': 'goal',
        'session_key': 'a',
        'goal': goal(phase: 'blocked', needsUser: true),
      });
      modes.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 'b',
        'approval_id': 'x',
      });
      expect(
        modes.waitKindOfAny(<String>['a', 'b', 'c']),
        AgentsWaitKind.approval,
      );
    });

    test('sendApprovalDecision carries feedback and remember_prefix', () async {
      await modes.sendApprovalDecision(
        approvalId: 'p1',
        approved: false,
        feedback: '  add tests  ',
      );
      await modes.sendApprovalDecision(
        approvalId: 'a1',
        approved: true,
        scope: 'always_this_prefix',
        rememberPrefix: 'git push',
      );
      expect(sent.first, <String, dynamic>{
        'type': 'approval_decision',
        'approval_id': 'p1',
        'approved': false,
        'feedback': 'add tests',
      });
      expect(sent.last['scope'], 'always_this_prefix');
      expect(sent.last['remember_prefix'], 'git push');
    });
  });

  test('the sandbox block of agent_permissions sets the fallback', () {
    expect(modes.sandboxFallback, isFalse);
    modes.ingest(<String, dynamic>{
      'type': 'agent_permissions',
      'agent_id': 'x',
      'sandbox': <String, dynamic>{
        'kind': 'local',
        'fallback': true,
        'requested': 'auto',
      },
    });
    expect(modes.sandboxFallback, isTrue);
    expect(modes.sandbox!.requested, 'auto');
    modes.ingest(<String, dynamic>{
      'type': 'agent_status',
      'session_key': 'x',
      'sandbox': <String, dynamic>{'kind': 'docker'},
    });
    expect(modes.sandboxFallback, isFalse);
  });
}
