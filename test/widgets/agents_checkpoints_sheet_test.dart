import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_checkpoints.dart';
import 'package:chuk_chat/services/agents/agents_derived_threads.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/agents_checkpoints_sheet.dart';

/// Plays the host on its own reply bus.
class _Host {
  _Host(this.answer);

  final Map<String, dynamic>? Function(Map<String, dynamic> frame) answer;
  final AgentsReplyFrames bus = AgentsReplyFrames();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  Future<void> send(Map<String, dynamic> frame) async {
    sent.add(frame);
    final Map<String, dynamic>? reply = answer(frame);
    if (reply != null) bus.add(reply);
  }

  AgentsCheckpoints get service => AgentsCheckpoints(send: send, replies: bus);
}

Map<String, dynamic> _list(Map<String, dynamic> f) => <String, dynamic>{
  'type': 'checkpoints',
  'session_key': f['session_key'],
  'ok': true,
  'items': <Object?>[
    <String, dynamic>{
      'id': 'cp-new',
      'created_at': 1762300500.0,
      'user_mid': 812,
      'prompt': 'Rename every photo in the trip folder by its date',
    },
    <String, dynamic>{
      'id': 'cp-old',
      'created_at': 1762300000.0,
      'user_mid': 800,
      'prompt': 'Write the report',
    },
  ],
};

Map<String, dynamic> _rewound(
  Map<String, dynamic> f, {
  bool conflict = false,
}) => conflict && f['mode'] == 'safe'
    ? <String, dynamic>{
        'type': 'checkpoint_rewound',
        'session_key': f['session_key'],
        'checkpoint_id': f['checkpoint_id'],
        'mode': 'safe',
        'ok': false,
        'error': 'files changed outside the agent since this checkpoint',
        'conflicts': <String>['notes.md', 'plan/todo.txt'],
        'restorable': 3,
      }
    : <String, dynamic>{
        'type': 'checkpoint_rewound',
        'session_key': f['session_key'],
        'checkpoint_id': f['checkpoint_id'],
        'mode': f['mode'],
        'ok': true,
        'restored': <String>['a.py', 'b.py'],
        'merged': f['mode'] == 'merge' ? <String>['notes.md'] : <String>[],
        'kept': f['mode'] == 'keep_user_edits'
            ? <String>['notes.md']
            : <String>[],
        'refused': <String>['linked/c.py'],
      };

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Widget _panel(AgentsCheckpoints service) => _app(
  Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      AgentsCheckpointsPanel(
        sessionKey: 't1',
        agentName: 'Atlas',
        service: service,
      ),
    ],
  ),
);

const Map<String, Size> _sizes = <String, Size>{
  'phone 360': Size(360, 800),
  'desktop 1280': Size(1280, 800),
};

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The busy spinner of a rewind runs while a dialog is open, so
/// pumpAndSettle would never return: pump the frames out by hand.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  tearDown(() {
    AgentsRunLedger.instance.reset();
    AgentsDerivedThreads.instance.reset();
  });

  for (final MapEntry<String, Size> size in _sizes.entries) {
    group(size.key, () {
      testWidgets('lists checkpoints newest first', (
        WidgetTester tester,
      ) async {
        _setSize(tester, size.value);
        final _Host host = _Host(_list);
        await tester.pumpWidget(_panel(host.service));
        await tester.pumpAndSettle();
        expect(host.sent.single['type'], 'checkpoints_list');
        final Offset newer = tester.getTopLeft(
          find.byKey(const ValueKey<String>('agents-checkpoint-cp-new')),
        );
        final Offset older = tester.getTopLeft(
          find.byKey(const ValueKey<String>('agents-checkpoint-cp-old')),
        );
        expect(newer.dy, lessThan(older.dy));
        expect(find.text('Rewind files to here'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });

      testWidgets('conflict: overwrite needs a confirm, then shows the '
          'result', (WidgetTester tester) async {
        _setSize(tester, size.value);
        final _Host host = _Host(
          (Map<String, dynamic> f) => f['type'] == 'checkpoints_list'
              ? _list(f)
              : _rewound(f, conflict: true),
        );
        await tester.pumpWidget(_panel(host.service));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-checkpoint-rewind-cp-new')),
        );
        await _settle(tester);
        expect(host.sent.last['mode'], 'safe');
        expect(
          find.byKey(const ValueKey<String>('agents-rewind-conflicts')),
          findsOneWidget,
        );
        expect(find.text('notes.md'), findsOneWidget);
        expect(find.text('Keep my edits'), findsOneWidget);
        expect(find.text('Merge'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(
          find.byKey(const ValueKey<String>('agents-rewind-force')),
        );
        await _settle(tester);
        expect(
          find.byKey(const ValueKey<String>('agents-rewind-force-confirm')),
          findsOneWidget,
        );
        // Nothing went out before the confirm.
        expect(host.sent.last['mode'], 'safe');
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-rewind-force-yes')),
        );
        await _settle(tester);
        expect(host.sent.last['mode'], 'force');
        expect(
          find.byKey(const ValueKey<String>('agents-rewind-summary')),
          findsOneWidget,
        );
        expect(find.text('Restored: a.py, b.py'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('agents-rewind-refused')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('agents-rewind-outside')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('conflict: keep my edits goes out as keep_user_edits', (
        WidgetTester tester,
      ) async {
        _setSize(tester, size.value);
        final _Host host = _Host(
          (Map<String, dynamic> f) => f['type'] == 'checkpoints_list'
              ? _list(f)
              : _rewound(f, conflict: true),
        );
        await tester.pumpWidget(_panel(host.service));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-checkpoint-rewind-cp-old')),
        );
        await _settle(tester);
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-rewind-keep')),
        );
        await _settle(tester);
        expect(host.sent.last['mode'], 'keep_user_edits');
        expect(host.sent.last['checkpoint_id'], 'cp-old');
        expect(find.text('Kept: notes.md'), findsOneWidget);
      });

      testWidgets('busy from the host says to wait for the agent', (
        WidgetTester tester,
      ) async {
        _setSize(tester, size.value);
        final _Host host = _Host(
          (Map<String, dynamic> f) => f['type'] == 'checkpoints_list'
              ? _list(f)
              : <String, dynamic>{
                  'type': 'checkpoint_rewound',
                  'session_key': 't1',
                  'checkpoint_id': f['checkpoint_id'],
                  'ok': false,
                  'error': 'busy: a task of this agent is running',
                },
        );
        await tester.pumpWidget(_panel(host.service));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-checkpoint-rewind-cp-new')),
        );
        await _settle(tester);
        expect(find.text('Wait until Atlas is done.'), findsOneWidget);
      });

      testWidgets('a running agent disables the rewind', (
        WidgetTester tester,
      ) async {
        _setSize(tester, size.value);
        AgentsRunLedger.instance.adoptRunning('t1');
        final _Host host = _Host(_list);
        await tester.pumpWidget(_panel(host.service));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('agents-checkpoints-running')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('agents-checkpoint-rewind-cp-new')),
          warnIfMissed: false,
        );
        await _settle(tester);
        expect(host.sent.length, 1);
      });
    });
  }

  testWidgets('fork from here opens the new thread and resolves a '
      'workspace conflict', (WidgetTester tester) async {
    final _Host host = _Host(
      (Map<String, dynamic> f) => switch (f['type']) {
        'thread_fork' => <String, dynamic>{
          'type': 'thread_forked',
          'session_key': 't1',
          'ok': true,
          'new_session_key': 't1:fork:abcd1234',
          'mid': f['mid'],
          'copied': 5,
          'checkpoint_id': 'cp9',
          'workspace': <String, dynamic>{
            'ok': false,
            'error': 'files changed outside the agent since this checkpoint',
            'conflicts': <String>['x.md'],
          },
        },
        _ => _rewound(f),
      },
    );
    final List<String> opened = <String>[];
    final sub = AgentsCheckpoints.openRequests.listen(opened.add);
    addTearDown(sub.cancel);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => forkAgentsThreadFrom(
                context,
                sessionKey: 't1',
                mid: 815,
                messageText: 'Make a plan',
                service: host.service,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await _settle(tester);
    expect(host.sent.first, <String, dynamic>{
      'type': 'thread_fork',
      'session_key': 't1',
      'mid': 815,
    });
    expect(
      find.byKey(const ValueKey<String>('agents-rewind-conflicts')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('agents-rewind-merge')));
    await _settle(tester);
    expect(host.sent.last['type'], 'checkpoint_rewind');
    expect(host.sent.last['checkpoint_id'], 'cp9');
    expect(host.sent.last['session_key'], 't1:fork:abcd1234');
    expect(host.sent.last['mode'], 'merge');
    expect(opened, <String>['t1:fork:abcd1234']);
    final AgentsDerivedThread? thread = AgentsDerivedThreads.instance.byKey(
      't1:fork:abcd1234',
    );
    expect(thread?.ownerKey, 't1');
    expect(thread?.title, 'Fork: Make a plan');
  });

  testWidgets('the fork action is only offered for an Agents row with a '
      'mid', (WidgetTester tester) async {
    ChatOrigin.agentsEnabled = true;
    addTearDown(ChatOrigin.reset);
    late BuildContext ctx;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      agentsForkAction(ctx, 'local:atlas:1:x', <String, String>{
        kAgentsHostMidKey: '815',
        'text': 'hi',
      })?.label,
      'Fork from here',
    );
    expect(
      agentsForkAction(ctx, 'local:atlas:1:x', <String, String>{'text': 'hi'}),
      isNull,
    );
    // A chuk_chat chat (a uuid) never gets it.
    expect(
      agentsForkAction(
        ctx,
        '123e4567-e89b-12d3-a456-426614174000',
        <String, String>{kAgentsHostMidKey: '815'},
      ),
      isNull,
    );
    ChatOrigin.agentsEnabled = false;
    expect(
      agentsForkAction(ctx, 'local:atlas:1:x', <String, String>{
        kAgentsHostMidKey: '815',
      }),
      isNull,
    );
  });
}
