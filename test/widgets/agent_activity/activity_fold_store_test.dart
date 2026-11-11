// The "Worked for …" block: folded by default, folded again when the turn
// ends, and the reader's choice survives the lazy list throwing the row away
// (a scroll, a minimap jump) and building it again.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/settings/tool_detail_service.dart';
import 'package:chuk_chat/widgets/agent_activity/activity_fold_store.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 12, 10);

List<ToolCall> _calls(String id, {bool running = false}) => <ToolCall>[
  // One step: a group of several would fold its own steps once settled.
  ToolCall(
    id: '$id-a',
    name: 'web_search',
    arguments: const <String, dynamic>{'query': 'second'},
    status: running ? ToolCallStatus.running : ToolCallStatus.completed,
    startedAt: _t0,
    completedAt: running ? null : _t0.add(const Duration(seconds: 13)),
  ),
];

Widget _timeline(String key, {bool running = false}) => AgentActivityTimeline(
  key: ValueKey<String>('timeline-$key'),
  foldKey: key,
  toolCalls: _calls(key, running: running),
  isRunning: running,
  clock: () => _t0.add(const Duration(minutes: 1)),
  toolDetailMode: ToolDetailMode.standard,
);

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

bool _open(WidgetTester tester, String key) {
  final Finder steps = find.descendant(
    of: find.byKey(ValueKey<String>('timeline-$key')),
    matching: find.textContaining('second', findRichText: true),
  );
  return steps.evaluate().isNotEmpty;
}

Future<void> _tapHeader(WidgetTester tester, String key) async {
  await tester.tap(
    find
        .descendant(
          of: find.byKey(ValueKey<String>('timeline-$key')),
          matching: find.byType(InkWell),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(ActivityFoldStore.instance.clear);

  testWidgets('a finished turn is folded by default', (tester) async {
    await tester.pumpWidget(_app(_timeline('m1:tools')));
    expect(find.text('Worked for 13s'), findsOneWidget);
    expect(_open(tester, 'm1:tools'), isFalse);
  });

  testWidgets('open while it runs, folded the moment it finishes, even when '
      'the reader opened it', (tester) async {
    await tester.pumpWidget(_app(_timeline('m2:tools', running: true)));
    await tester.pump();
    expect(_open(tester, 'm2:tools'), isTrue);

    // Reader folds and opens it again while it runs.
    await _tapHeader(tester, 'm2:tools');
    expect(_open(tester, 'm2:tools'), isFalse);
    await _tapHeader(tester, 'm2:tools');
    expect(_open(tester, 'm2:tools'), isTrue);

    await tester.pumpWidget(_app(_timeline('m2:tools')));
    await tester.pumpAndSettle();
    expect(_open(tester, 'm2:tools'), isFalse);
  });

  testWidgets('the choice survives the row being thrown away', (tester) async {
    await tester.pumpWidget(_app(_timeline('m3:tools')));
    await _tapHeader(tester, 'm3:tools');
    expect(_open(tester, 'm3:tools'), isTrue);

    // The row leaves the tree (scrolled out of the cache) and comes back.
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpWidget(_app(_timeline('m3:tools')));
    expect(_open(tester, 'm3:tools'), isTrue);

    // Folded by hand stays folded across the same trip.
    await _tapHeader(tester, 'm3:tools');
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpWidget(_app(_timeline('m3:tools')));
    expect(_open(tester, 'm3:tools'), isFalse);
  });

  testWidgets('a choice made while running ends with the turn, also when the '
      'row was gone when it ended', (tester) async {
    await tester.pumpWidget(_app(_timeline('m4:tools', running: true)));
    await tester.pump();
    await _tapHeader(tester, 'm4:tools'); // folded by hand
    await _tapHeader(tester, 'm4:tools'); // opened by hand
    expect(_open(tester, 'm4:tools'), isTrue);

    await tester.pumpWidget(_app(const SizedBox()));
    // The turn finished while the row was off screen.
    await tester.pumpWidget(_app(_timeline('m4:tools')));
    expect(_open(tester, 'm4:tools'), isFalse);
  });

  testWidgets('in a lazy list, a jump away and back keeps a folded block '
      'folded and an opened one open', (tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        ListView.builder(
          controller: controller,
          itemCount: 200,
          itemBuilder: (BuildContext context, int i) => SizedBox(
            height: 220,
            child: Align(
              alignment: Alignment.topLeft,
              child: _timeline('row$i:tools'),
            ),
          ),
        ),
      ),
    );
    await _tapHeader(tester, 'row0:tools');
    expect(_open(tester, 'row0:tools'), isTrue);
    expect(_open(tester, 'row1:tools'), isFalse);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-row0:tools')),
      findsNothing,
    );

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_open(tester, 'row0:tools'), isTrue);
    expect(_open(tester, 'row1:tools'), isFalse);

    await _tapHeader(tester, 'row0:tools');
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_open(tester, 'row0:tools'), isFalse);
  });
}
