import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/spreadsheet/spreadsheet_parser.dart';
import 'package:chuk_chat/widgets/spreadsheet/spreadsheet_viewer.dart';

import '../support/test_app.dart';
import '../support/xlsx_fixture.dart';

Future<SpreadsheetDocument> _syncParse(
  Uint8List b,
  SpreadsheetFormat f,
) async => SpreadsheetParser.parseSync(b, f);

Future<void> _pump(
  WidgetTester tester,
  double width,
  String name,
  Uint8List bytes,
) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      SpreadsheetViewer(fileName: name, bytes: bytes, parser: _syncParse),
    ),
  );
  await tester.pumpAndSettle();
}

Uint8List _workbook() => buildXlsx(
  <String, List<List<Object>>>{
    'Sales': <List<Object>>[
      <Object>['Item', 'Qty'],
      for (int i = 0; i < 200; i++) <Object>['row$i', i],
    ],
    'Notes': <List<Object>>[
      <Object>['Topic', 'Text'],
      <Object>['Apple', 'fresh'],
    ],
  },
  conditionalFormatting: true,
  chart: true,
);

void main() {
  for (final double width in <double>[360, 1280]) {
    group('at $width px', () {
      testWidgets('banner, header pinned on scroll, tabs switch', (
        tester,
      ) async {
        await _pump(tester, width, 'book.xlsx', _workbook());
        expect(tester.takeException(), isNull);

        final Finder banner = find.byKey(const ValueKey('spreadsheet-banner'));
        expect(banner, findsOneWidget);
        expect(
          find.descendant(
            of: banner,
            matching: find.textContaining('charts, conditional formatting'),
          ),
          findsOneWidget,
        );

        final Finder header = find.byKey(const ValueKey('spreadsheet-header'));
        expect(
          find.descendant(of: header, matching: find.text('Item')),
          findsOneWidget,
        );
        final double headerTop = tester.getTopLeft(header).dy;
        expect(find.text('row0'), findsOneWidget);

        await tester.drag(find.text('row3'), const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(find.text('row0'), findsNothing);
        expect(
          find.descendant(of: header, matching: find.text('Item')),
          findsOneWidget,
        );
        expect(tester.getTopLeft(header).dy, headerTop);

        await tester.tap(find.byKey(const ValueKey('spreadsheet-tab-1')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: header, matching: find.text('Topic')),
          findsOneWidget,
        );
        expect(find.text('fresh'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('one sheet: no tabs, no banner', (tester) async {
        await _pump(
          tester,
          width,
          'a.csv',
          Uint8List.fromList(utf8.encode('a,b\n1,2\n')),
        );
        expect(find.byKey(const ValueKey('spreadsheet-tab-0')), findsNothing);
        expect(find.byKey(const ValueKey('spreadsheet-banner')), findsNothing);
        expect(find.text('2'), findsWidgets);
      });

      testWidgets('xls shows the unsupported message', (tester) async {
        await _pump(tester, width, 'old.xls', Uint8List.fromList(<int>[0]));
        expect(find.textContaining('.xls'), findsWidgets);
        expect(find.textContaining('cannot be previewed'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
