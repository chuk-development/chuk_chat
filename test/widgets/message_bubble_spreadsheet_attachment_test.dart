import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/spreadsheet/spreadsheet_viewer.dart';

import '../support/test_app.dart';

/// A spreadsheet attachment in a sent message opens the read-only table
/// viewer, built from the server's Markdown of the file. Other attachments
/// keep the document viewer.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const String sheetMarkdown =
      '## Sales\n\n|  |  |\n| --- | --- |\n| Item | Qty |\n| Apple | 3 |\n\n'
      '## Notes\n\n|  |\n| --- |\n| fresh |\n';

  Future<void> pumpBubble(
    WidgetTester tester,
    List<DocumentAttachment> attachments,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: MessageBubble(
            message: 'see attached',
            isUser: true,
            maxWidth: 600,
            attachments: attachments,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('tapping a sent .xlsx opens the spreadsheet viewer', (
    tester,
  ) async {
    await pumpBubble(tester, const <DocumentAttachment>[
      DocumentAttachment(fileName: 'book.xlsx', markdownContent: sheetMarkdown),
    ]);
    await tester.tap(find.byKey(const ValueKey('attachment-chip-book.xlsx')));
    await tester.pumpAndSettle();

    expect(find.byType(SpreadsheetViewer), findsOneWidget);
    expect(find.byType(DocumentViewer), findsNothing);
    expect(find.text('Sales'), findsWidgets);
    expect(find.text('Notes'), findsWidgets);
    expect(find.text('Apple'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pdf keeps the document viewer', (tester) async {
    await pumpBubble(tester, const <DocumentAttachment>[
      DocumentAttachment(fileName: 'a.pdf', markdownContent: '| a |\n| - |\n'),
    ]);
    await tester.tap(find.byKey(const ValueKey('attachment-chip-a.pdf')));
    await tester.pumpAndSettle();

    expect(find.byType(SpreadsheetViewer), findsNothing);
    expect(find.byType(DocumentViewer), findsOneWidget);
  });

  testWidgets('a spreadsheet whose Markdown has no table falls back', (
    tester,
  ) async {
    await pumpBubble(tester, const <DocumentAttachment>[
      DocumentAttachment(fileName: 'x.csv', markdownContent: 'no table here'),
    ]);
    await tester.tap(find.byKey(const ValueKey('attachment-chip-x.csv')));
    await tester.pumpAndSettle();

    expect(find.byType(SpreadsheetViewer), findsNothing);
    expect(find.byType(DocumentViewer), findsOneWidget);
  });

  test('which sent attachments count as spreadsheets', () {
    for (final String name in <String>[
      'a.xlsx',
      'a.XLSM',
      'a.xls',
      'a.xlsb',
      'a.csv',
      'a.tsv',
      'a.ods',
    ]) {
      expect(
        SpreadsheetViewer.isSentSpreadsheetName(name),
        isTrue,
        reason: name,
      );
    }
    for (final String name in <String>['a.pdf', 'a.docx', 'xlsx', 'a.odt']) {
      expect(
        SpreadsheetViewer.isSentSpreadsheetName(name),
        isFalse,
        reason: name,
      );
    }
    expect(SpreadsheetViewer.sentDocument('a.pdf', '| a |\n| - |\n'), isNull);
    expect(
      SpreadsheetViewer.sentDocument('a.ods', '| a |\n| - |\n| 1 |\n'),
      isNotNull,
    );
  });
}
