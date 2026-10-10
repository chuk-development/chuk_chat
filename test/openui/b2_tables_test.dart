// Widget tests for the B2 tables: Table (plucked data, number columns,
// component cells, pages, bad data) and EditableTable (inline edits
// write the form state, Save sends the values, select and streaming).
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/components/tables_charts/editable_table.dart';
import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

Future<RecordingOpenUiHandler> _pump(
  WidgetTester tester,
  String source, {
  double width = 360,
  Brightness brightness = Brightness.dark,
  bool isStreaming = false,
}) async {
  final h = RecordingOpenUiHandler();
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(source: source, isStreaming: isStreaming, actionHandler: h),
      brightness: brightness,
      width: width,
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Text _text(WidgetTester tester, String s) =>
    tester.widget<Text>(find.text(s).first);

const String _roster = '''
root = EditableTable("roster", [colName, colAge, colRole, colStart, colSite], [row1, row2])
colName = { type: "text", key: "name", header: "Name" }
colAge = { type: "number", key: "age", header: "Age" }
colRole = { type: "select", key: "role", header: "Role", options: [roleEng, roleDesign] }
roleEng = { value: "eng", label: "Engineering" }
roleDesign = { value: "design", label: "Design" }
colStart = { type: "date-single", key: "start", header: "Start" }
colSite = { type: "url", key: "site", header: "Site" }
row1 = { id: "1", values: ["Alex Kim", 31, "eng", "2024-01-15", "https://example.com/alex"] }
row2 = { id: "2", values: ["Jamie Lee", 28, "design", "2024-03-02", "https://example.com/jamie"] }
''';

void main() {
  group('Table', () {
    testWidgets('renders plucked columns; numbers right-aligned, tabular', (
      tester,
    ) async {
      await _pump(tester, '''
root = Table([Col("Language", rows.name), Col("Users (M)", rows.users, "number"), Col("Year", rows.year)])
rows = [{name: "Python", users: 15.7, year: 1991}, {name: "JavaScript", users: 14.2, year: 1995}, {name: "Java", users: 1234.5, year: 1995}]
''');
      expect(tester.takeException(), isNull);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Python'), findsOneWidget);
      expect(find.text('1234.5'), findsOneWidget);
      final users = _text(tester, '15.7');
      expect(users.textAlign, TextAlign.right);
      expect(
        users.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      // A column of only numbers is a number column without the hint.
      expect(_text(tester, '1991').textAlign, TextAlign.right);
      // The header of a number column is right-aligned too.
      expect(_text(tester, 'Users (M)').textAlign, TextAlign.right);
    });

    testWidgets('renders the canonical fixture form', (tester) async {
      await _pump(
        tester,
        '''
root = Table([Col("Language", langs), Col("Users (M)", users), Col("Year", years)])
langs = ["Python", "JavaScript", "Java"]
users = [15.7, 14.2, 12.1]
years = [1991, 1995, 1995]
''',
        brightness: Brightness.light,
        width: 900,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('JavaScript'), findsOneWidget);
    });

    testWidgets('component cells from @Each render as widgets', (tester) async {
      await _pump(tester, '''
root = Table([Col("Name", rows.name), Col("Status", @Each(rows, "r", TextContent(r.status)))])
rows = [{name: "A", status: "Shipped"}, {name: "B", status: "Pending"}]
''');
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Shipped'), findsOneWidget);
      expect(find.textContaining('Pending'), findsOneWidget);
    });

    testWidgets('long tables page by 10', (tester) async {
      final values = List<String>.generate(15, (i) => '"Row ${i + 1}"');
      await _pump(
        tester,
        'root = Table([Col("Item", [${values.join(', ')}])])',
      );
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 11'), findsNothing);
      expect(find.text('1–10 of 15'), findsOneWidget);
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('Row 11'), findsOneWidget);
      expect(find.text('11–15 of 15'), findsOneWidget);
    });

    testWidgets('many columns scroll sideways at phone width', (tester) async {
      final cols = List<String>.generate(
        9,
        (i) => 'Col("Column number $i", ["value $i a long cell", "x"])',
      );
      await _pump(tester, 'root = Table([${cols.join(', ')}])');
      expect(tester.takeException(), isNull);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
        findsOneWidget,
      );
    });

    testWidgets('URL cells open through the host', (tester) async {
      final h = await _pump(
        tester,
        'root = Table([Col("Site", ["https://www.example.com/a"])])',
      );
      expect(find.text('example.com'), findsOneWidget);
      await tester.tap(find.text('example.com'));
      expect(h.urls, <String>['https://www.example.com/a']);
    });

    const bad = <String>[
      'root = Table([])',
      'root = Table(null)',
      'root = Table("nope")',
      'root = Table([Col("A", null), Col("B", [1, 2, 3])])',
      'root = Table([Col("A", ["x"]), Col("B", [1, 2, 3, 4, 5])])',
      'root = Table([Col("A", "single"), Col(null, [true, false])])',
      'root = Table([Col("A", [{k: 1}, [1, 2], null, 3.5])])',
      'root = Table([Col("A", [1, 2], "bogus")])',
    ];
    for (final source in bad) {
      testWidgets('bad data: $source', (tester) async {
        await _pump(tester, source);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a partial (streaming) table renders what is valid', (
      tester,
    ) async {
      const full =
          'root = Table([Col("Name", ["Ada", "Bob", "Cy"]), '
          'Col("Score", [1, 2, 3], "number")])';
      for (var cut = 8; cut <= full.length; cut += 6) {
        await _pump(tester, full.substring(0, cut), isStreaming: true);
        expect(tester.takeException(), isNull, reason: full.substring(0, cut));
      }
    });
  });

  group('EditableTable', () {
    testWidgets('renders every column type', (tester) async {
      await _pump(tester, _roster);
      expect(tester.takeException(), isNull);
      expect(find.text('Alex Kim'), findsOneWidget);
      expect(find.text('Engineering'), findsOneWidget);
      expect(find.text('Design'), findsOneWidget);
      expect(find.text('Jan 15, 2024'), findsOneWidget);
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('renders at desktop width in light mode', (tester) async {
      await _pump(tester, _roster, width: 900, brightness: Brightness.light);
      expect(tester.takeException(), isNull);
      expect(find.text('Jamie Lee'), findsOneWidget);
    });

    testWidgets('a text edit writes the form state and Save sends it', (
      tester,
    ) async {
      final h = await _pump(tester, _roster);
      await tester.tap(find.text('Alex Kim'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Alex Smith');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Alex Smith'), findsOneWidget);
      expect(find.text('1 change'), findsOneWidget);

      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(h.messages, hasLength(1));
      final sent = h.messages.single;
      expect(sent.text, kEditableTableSaveMessage);
      final rows = sent.formValues!['roster']! as List<Object?>;
      final first = rows.first! as Map<String, Object?>;
      expect(first['id'], '1');
      expect((first['values']! as List<Object?>).first, 'Alex Smith');
      // The save is the new baseline: no changes left.
      expect(find.text('1 change'), findsNothing);
    });

    testWidgets('a number edit stores a number; junk keeps the old value', (
      tester,
    ) async {
      final h = await _pump(tester, _roster);
      await tester.tap(find.text('31'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '42');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('42'), findsOneWidget);

      await tester.tap(find.text('28'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('28'), findsOneWidget);

      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final rows = h.messages.single.formValues!['roster']! as List<Object?>;
      final values =
          (rows.first! as Map<String, Object?>)['values']! as List<Object?>;
      expect(values[1], 42);
    });

    testWidgets('a select edit picks from the menu', (tester) async {
      final h = await _pump(tester, _roster);
      await tester.tap(find.text('Engineering'));
      await tester.pumpAndSettle();
      // The menu lists both options; the second "Design" is the menu row.
      await tester.tap(find.text('Design').last);
      await tester.pumpAndSettle();
      expect(find.text('Engineering'), findsNothing);
      expect(find.text('1 change'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final rows = h.messages.single.formValues!['roster']! as List<Object?>;
      final values =
          (rows.first! as Map<String, Object?>)['values']! as List<Object?>;
      expect(values[2], 'design');
    });

    testWidgets('Reset brings the original values back', (tester) async {
      await _pump(tester, _roster);
      await tester.tap(find.text('Jamie Lee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Someone');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Someone'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('Jamie Lee'), findsOneWidget);
      expect(find.text('1 change'), findsNothing);
    });

    testWidgets('cells do not take edits while the statement streams', (
      tester,
    ) async {
      await _pump(
        tester,
        'root = EditableTable("t", [{ type: "text", key: "a", header: "A" }], '
        '[{ id: "1", values: ["one"] }, { id: "2", values: ["tw',
        isStreaming: true,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });

    const bad = <String>[
      'root = EditableTable()',
      'root = EditableTable("t")',
      'root = EditableTable("t", [], [])',
      'root = EditableTable("t", null, [{ id: "1", values: ["a", 2] }])',
      'root = EditableTable("t", "nope", 5)',
      'root = EditableTable("t", [{ type: "weird" }], [{ values: [null, {x: 1}] }, 7])',
      'root = EditableTable("t", [{ type: "select", key: "s" }], [{ id: "1", values: ["zz"] }])',
      'root = EditableTable("t", [{ type: "date-single", key: "d", width: 5 }], [{ id: "1", values: ["not a date"] }])',
    ];
    for (final source in bad) {
      testWidgets('bad data: $source', (tester) async {
        await _pump(tester, source);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
