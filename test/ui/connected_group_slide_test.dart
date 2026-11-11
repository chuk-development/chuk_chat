/// The app's one segmented switch has ONE filled capsule, and it slides from
/// the old segment to the new one instead of jumping or fading per segment.
/// With reduced motion it lands at once.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/ui/expressive/connected_group.dart';

class _Host extends StatefulWidget {
  const _Host({required this.labels, this.picked});

  final List<String> labels;
  final List<int>? picked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return ConnectedGroup(
      labels: widget.labels,
      selected: _selected,
      margin: EdgeInsets.zero,
      onSelected: (int i) {
        widget.picked?.add(i);
        setState(() => _selected = i);
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  List<String> labels = const <String>['All', 'Active', 'Inactive'],
  List<int>? picked,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = const Size(360, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 200),
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: _Host(labels: labels, picked: picked),
          ),
        ),
      ),
    ),
  );
}

Rect _pill(WidgetTester tester) =>
    tester.getRect(find.byKey(ConnectedGroup.pillKey));

Rect _segment(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(Expanded)).first,
);

bool _isSelected(WidgetTester tester, String label) => tester
    .widget<Semantics>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Semantics &&
            w.properties.identifier == 'connected-group-${label.toLowerCase()}',
      ),
    )
    .properties
    .selected!;

void main() {
  testWidgets('there is exactly one capsule, under the selected segment', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(ConnectedGroup.pillKey), findsOneWidget);
    expect(
      _pill(tester).center.dx,
      closeTo(_segment(tester, 'All').center.dx, 0.5),
    );
    expect(_isSelected(tester, 'All'), isTrue);
    expect(_isSelected(tester, 'Inactive'), isFalse);
  });

  testWidgets('a tap calls onSelected with the index', (tester) async {
    final List<int> picked = <int>[];
    await _pump(tester, picked: picked);
    await tester.tap(find.text('Inactive'));
    await tester.pumpAndSettle();
    expect(picked, <int>[2]);
    expect(_isSelected(tester, 'Inactive'), isTrue);
  });

  testWidgets('the capsule slides to the new segment', (tester) async {
    await _pump(tester);
    final Rect start = _pill(tester);

    await tester.tap(find.text('Inactive'));
    await tester.pump();
    // One frame in: the selection is committed but the capsule is still
    // on its way, not already at the end and not gone.
    await tester.pump(const Duration(milliseconds: 60));
    final Rect mid = _pill(tester);
    final Rect target = _segment(tester, 'Inactive');
    expect(mid.left, greaterThan(start.left));
    expect(mid.center.dx, lessThan(target.center.dx - 1));
    expect(
      mid.width,
      closeTo(start.width, 0.01),
      reason: 'it slides, not grows',
    );

    await tester.pumpAndSettle();
    final Rect end = _pill(tester);
    expect(end.center.dx, closeTo(target.center.dx, 0.5));
    expect(end.width, closeTo(target.width, 0.5));
    expect(end.top, closeTo(start.top, 0.01));
  });

  testWidgets('with reduced motion the capsule lands at once', (tester) async {
    await _pump(tester, disableAnimations: true);
    await tester.tap(find.text('Active'));
    await tester.pump();
    expect(
      _pill(tester).center.dx,
      closeTo(_segment(tester, 'Active').center.dx, 0.5),
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the label colour follows the capsule', (tester) async {
    await _pump(tester, labels: const <String>['Chats', 'Agents']);
    Color colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    final Color lit = colorOf('Chats');
    final Color dim = colorOf('Agents');
    expect(lit, isNot(dim));

    await tester.tap(find.text('Agents'));
    await tester.pumpAndSettle();
    expect(colorOf('Agents'), lit);
    expect(colorOf('Chats'), dim);
  });
}
