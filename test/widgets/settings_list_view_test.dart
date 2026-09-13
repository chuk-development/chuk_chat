import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/ui/expressive/staggered.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

Widget _host({required List<Widget> children, bool reducedMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(body: SettingsListView(children: children)),
    ),
  );
}

List<double> _opacities(WidgetTester tester) {
  return tester
      .widgetList<Opacity>(
        find.descendant(
          of: find.byType(StaggeredItem),
          matching: find.byType(Opacity),
        ),
      )
      .map((Opacity o) => o.opacity)
      .toList();
}

void main() {
  List<Widget> rows(int count) => <Widget>[
    for (var i = 0; i < count; i++)
      SizedBox(height: 40, child: Text('row $i')),
  ];

  testWidgets('renders every child', (WidgetTester tester) async {
    await tester.pumpWidget(_host(children: rows(12)));
    await tester.pumpAndSettle();

    for (var i = 0; i < 12; i++) {
      expect(find.text('row $i'), findsOneWidget);
    }
  });

  testWidgets('staggers the rows in', (WidgetTester tester) async {
    await tester.pumpWidget(_host(children: rows(6)));

    final List<double> first = _opacities(tester);
    expect(first, hasLength(6));
    expect(first.every((double v) => v < 1), isTrue);

    // Part way through: the early rows lead the late ones.
    await tester.pump(const Duration(milliseconds: 260));
    final List<double> middle = _opacities(tester);
    expect(middle.first, greaterThan(middle.last));

    await tester.pumpAndSettle();
    expect(_opacities(tester), everyElement(1.0));
  });

  testWidgets('reduced motion skips the stagger', (WidgetTester tester) async {
    await tester.pumpWidget(_host(children: rows(6), reducedMotion: true));

    // The very first frame already shows every row in place.
    expect(_opacities(tester), everyElement(1.0));
    for (var i = 0; i < 6; i++) {
      expect(find.text('row $i'), findsOneWidget);
    }
  });
}
