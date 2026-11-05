import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/spreadsheet/spreadsheet_parser.dart';
import 'package:chuk_chat/services/spreadsheet/spreadsheet_runner_web.dart'
    as web;

import '../support/xlsx_fixture.dart';

Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('formatFor', () {
    test('maps extensions', () {
      expect(SpreadsheetParser.formatFor('a.XLSX'), SpreadsheetFormat.xlsx);
      expect(SpreadsheetParser.formatFor('a.xls'), SpreadsheetFormat.xls);
      expect(SpreadsheetParser.formatFor('a.csv'), SpreadsheetFormat.csv);
      expect(SpreadsheetParser.formatFor('a.tsv'), SpreadsheetFormat.tsv);
      expect(SpreadsheetParser.formatFor('a.pdf'), isNull);
      expect(SpreadsheetParser.formatFor('noext'), isNull);
    });

    test('column names', () {
      expect(SpreadsheetParser.columnName(0), 'A');
      expect(SpreadsheetParser.columnName(25), 'Z');
      expect(SpreadsheetParser.columnName(26), 'AA');
      expect(SpreadsheetParser.columnName(701), 'ZZ');
    });
  });

  group('csv / tsv', () {
    test('quotes, escaped quotes, newlines in a field, CRLF, BOM', () {
      final doc = SpreadsheetParser.parseSync(
        _text('﻿name,note\r\n"Doe, Jane","said ""hi""\nthen left"\r\nBob,\r\n'),
        SpreadsheetFormat.csv,
      );
      final rows = doc.sheets.single.rows;
      expect(rows, <List<String>>[
        <String>['name', 'note'],
        <String>['Doe, Jane', 'said "hi"\nthen left'],
        <String>['Bob', ''],
      ]);
      expect(doc.truncated, isFalse);
    });

    test('ragged rows are padded', () {
      final rows = SpreadsheetParser.parseSync(
        _text('a\nb,c,d\n'),
        SpreadsheetFormat.csv,
      ).sheets.single.rows;
      expect(rows, <List<String>>[
        <String>['a', '', ''],
        <String>['b', 'c', 'd'],
      ]);
    });

    test('semicolon csv is detected', () {
      final rows = SpreadsheetParser.parseSync(
        _text('a;b\n1,5;2\n'),
        SpreadsheetFormat.csv,
      ).sheets.single.rows;
      expect(rows[1], <String>['1,5', '2']);
    });

    test('tsv', () {
      final rows = SpreadsheetParser.parseSync(
        _text('a\tb\n1\t"x\ty"\n'),
        SpreadsheetFormat.tsv,
      ).sheets.single.rows;
      expect(rows, <List<String>>[
        <String>['a', 'b'],
        <String>['1', 'x\ty'],
      ]);
    });

    test('cell cap truncates rows', () {
      final String csv = List<String>.generate(100, (i) => '$i,$i').join('\n');
      final doc = SpreadsheetParser.parseSync(
        _text(csv),
        SpreadsheetFormat.csv,
        cellLimit: 50,
      );
      expect(doc.truncated, isTrue);
      expect(doc.sheets.single.rows.length, 25);
    });
  });

  group('xlsx', () {
    test('two sheets, shared strings, numbers, booleans', () {
      final doc = SpreadsheetParser.parseSync(
        buildXlsx(<String, List<List<Object>>>{
          'Sales': <List<Object>>[
            <Object>['Item', 'Qty', 'Paid'],
            <Object>['Apple', 3, true],
            <Object>['Pear & Plum', 2.5, false],
          ],
          'Notes': <List<Object>>[
            <Object>['Item', 'Note'],
            <Object>['Apple', 'fresh'],
          ],
        }),
        SpreadsheetFormat.xlsx,
      );
      expect(doc.sheets.map((s) => s.name), <String>['Sales', 'Notes']);
      expect(doc.sheets[0].rows[1], <String>['Apple', '3', 'TRUE']);
      expect(doc.sheets[0].rows[2], <String>['Pear & Plum', '2.5', 'FALSE']);
      expect(doc.sheets[1].rows[1], <String>['Apple', 'fresh']);
      expect(doc.unsupported, isEmpty);
    });

    test('detects conditional formatting, images and charts', () {
      final doc = SpreadsheetParser.parseSync(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>['a'],
            ],
          },
          conditionalFormatting: true,
          image: true,
          chart: true,
        ),
        SpreadsheetFormat.xlsx,
      );
      expect(doc.unsupported, <SpreadsheetFeature>{
        SpreadsheetFeature.conditionalFormatting,
        SpreadsheetFeature.images,
        SpreadsheetFeature.charts,
      });
    });

    test('cell cap spans sheets', () {
      final rows = <List<Object>>[
        for (int i = 0; i < 20; i++) <Object>['r$i', i],
      ];
      final doc = SpreadsheetParser.parseSync(
        buildXlsx(<String, List<List<Object>>>{'A': rows, 'B': rows}),
        SpreadsheetFormat.xlsx,
        cellLimit: 50,
      );
      expect(doc.truncated, isTrue);
      expect(doc.sheets[0].rows.length, 20);
      expect(doc.sheets[1].rows.length, 5);
    });

    // M5: crafted input must stay within the bounds, not build a grid
    // from forged coordinates or inflate a zip bomb into memory.
    test('a forged far cell reference builds no giant grid', () {
      final doc = SpreadsheetParser.parseSync(
        buildRawXlsx(
          '<worksheet><sheetData>'
          '<row r="1"><c r="A1" t="inlineStr"><is><t>head</t></is></c></row>'
          '<row r="2000000000"><c r="XFD2000000000" t="inlineStr">'
          '<is><t>far</t></is></c></row>'
          '<row r="3"><c r="ZZZZZZ3" t="inlineStr"><is><t>wide</t></is></c>'
          '<c r="B3" t="inlineStr"><is><t>near</t><rPh><t>x</t></rPh></is></c>'
          '</row>'
          '</sheetData></worksheet>',
        ),
        SpreadsheetFormat.xlsx,
      );
      final rows = doc.sheets.single.rows;
      expect(doc.truncated, isTrue);
      expect(rows, hasLength(3));
      expect(rows.first.first, 'head');
      expect(rows[2][1], 'near');
    });

    test('a sheet with more text cells than the budget stops reading', () {
      final StringBuffer xml = StringBuffer('<worksheet><sheetData>');
      for (int r = 1; r <= 400; r++) {
        xml.write('<row r="$r"><c r="A$r"><v>$r</v></c></row>');
      }
      xml.write('</sheetData></worksheet>');
      final doc = SpreadsheetParser.parseSync(
        buildRawXlsx(xml.toString()),
        SpreadsheetFormat.xlsx,
        cellLimit: 50,
      );
      expect(doc.truncated, isTrue);
      expect(doc.sheets.single.rows, hasLength(50));
    });

    test('a zip declaring a huge size is refused', () {
      final Uint8List forged = forgeZipSizes(
        buildRawXlsx('<worksheet><sheetData/></worksheet>'),
        0x7FFFFFF0,
      );
      expect(
        () => SpreadsheetParser.parseSync(forged, SpreadsheetFormat.xlsx),
        throwsA(
          isA<SpreadsheetParseException>().having(
            (e) => e.kind,
            'kind',
            SpreadsheetErrorKind.tooLarge,
          ),
        ),
      );
    });

    test('a zip bomb that hides its size stops at the bound', () {
      // 80 MB of one byte inflate from a few hundred KB; the zip claims 1 KB
      // per part, so only the inflate itself can stop it.
      final String filler = 'a' * (80 * 1024 * 1024);
      final Uint8List forged = forgeZipSizes(
        buildRawXlsx('<worksheet><sheetData/>$filler</worksheet>'),
        1024,
      );
      expect(forged.length, lessThan(SpreadsheetParser.maxBytes));
      expect(
        () => SpreadsheetParser.parseSync(forged, SpreadsheetFormat.xlsx),
        throwsA(isA<SpreadsheetParseException>()),
      );
    });

    test('garbage is invalid', () {
      expect(
        () => SpreadsheetParser.parseSync(
          _text('not a zip'),
          SpreadsheetFormat.xlsx,
        ),
        throwsA(
          isA<SpreadsheetParseException>().having(
            (e) => e.kind,
            'kind',
            SpreadsheetErrorKind.invalid,
          ),
        ),
      );
    });
  });

  // L5: the web parses on the UI thread, so it takes less.
  test('the web runner takes smaller files and grids', () async {
    final Uint8List big = _text('a,b\n' * (web.kWebSpreadsheetMaxBytes ~/ 4 + 1));
    await expectLater(
      web.runSpreadsheetParse(
        big,
        SpreadsheetFormat.csv,
        SpreadsheetParser.maxCells,
        SpreadsheetParser.timeout,
      ),
      throwsA(
        isA<SpreadsheetParseException>().having(
          (e) => e.kind,
          'kind',
          SpreadsheetErrorKind.tooLarge,
        ),
      ),
    );
    final String csv = List<String>.generate(
      30000,
      (i) => '$i,$i,$i',
    ).join('\n');
    final doc = await web.runSpreadsheetParse(
      _text(csv),
      SpreadsheetFormat.csv,
      SpreadsheetParser.maxCells,
      SpreadsheetParser.timeout,
    );
    expect(doc.truncated, isTrue);
    expect(
      doc.sheets.single.rows.length * 3,
      lessThanOrEqualTo(web.kWebSpreadsheetMaxCells),
    );
  });

  test('xls is unsupported', () {
    expect(
      () => SpreadsheetParser.parseSync(_text('x'), SpreadsheetFormat.xls),
      throwsA(
        isA<SpreadsheetParseException>().having(
          (e) => e.kind,
          'kind',
          SpreadsheetErrorKind.unsupportedFormat,
        ),
      ),
    );
  });

  test('more than 16 MiB is refused before parsing', () async {
    await expectLater(
      SpreadsheetParser.parse(
        Uint8List(SpreadsheetParser.maxBytes + 1),
        SpreadsheetFormat.csv,
      ),
      throwsA(
        isA<SpreadsheetParseException>().having(
          (e) => e.kind,
          'kind',
          SpreadsheetErrorKind.tooLarge,
        ),
      ),
    );
  });

  test('parse in an isolate returns the document', () async {
    final doc = await SpreadsheetParser.parse(
      _text('a,b\n1,2\n'),
      SpreadsheetFormat.csv,
    );
    expect(doc.sheets.single.rows[1], <String>['1', '2']);
  });

  test('timeout becomes an error', () async {
    final String csv = List<String>.generate(
      20000,
      (i) => '$i,"x$i",y',
    ).join('\n');
    await expectLater(
      SpreadsheetParser.parse(
        _text(csv),
        SpreadsheetFormat.csv,
        limit: Duration.zero,
      ),
      throwsA(
        isA<SpreadsheetParseException>().having(
          (e) => e.kind,
          'kind',
          SpreadsheetErrorKind.timeout,
        ),
      ),
    );
  });

  group('dates', () {
    List<String> firstRow(Uint8List bytes) => SpreadsheetParser.parseSync(
      bytes,
      SpreadsheetFormat.xlsx,
    ).sheets.single.rows.first;

    test('built-in date and time formats', () {
      // Style index -> numFmtId.
      final row = firstRow(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>[
                const XlsxStyled(45000, 0), // 14 date
                const XlsxStyled(45000.5, 1), // 22 date + time
                const XlsxStyled(0.75, 2), // 21 h:mm:ss
                const XlsxStyled(0.5, 3), // 20 h:mm
                const XlsxStyled(1.5, 4), // 46 [h]:mm:ss
                const XlsxStyled(45000, 5), // 0 General
                const XlsxStyled(45000, 6), // 17 mmm-yy
                45000, // no style
              ],
            ],
          },
          cellXfs: <int>[14, 22, 21, 20, 46, 0, 17],
        ),
      );
      expect(row, <String>[
        '2023-03-15',
        '2023-03-15 12:00',
        '18:00:00',
        '12:00',
        '36:00:00',
        '45000',
        '2023-03-15',
        '45000',
      ]);
    });

    test('custom date format counts, a number format does not', () {
      final row = firstRow(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>[
                const XlsxStyled(45000, 0),
                const XlsxStyled(1234.5, 1),
                const XlsxStyled(45000.25, 2),
                const XlsxStyled(7, 3),
              ],
            ],
          },
          cellXfs: <int>[164, 165, 166, 167],
          numFmts: <int, String>{
            164: 'dd/mm/yyyy;@',
            165: '#,##0.00 "days";[Red]-#,##0.00',
            166: 'yyyy-mm-dd hh:mm:ss',
            167: r'0\d',
          },
        ),
      );
      expect(row, <String>['2023-03-15', '1234.5', '2023-03-15 06:00:00', '7']);
    });

    test('cellStyleXfs is not read as the cell styles', () {
      // The fixture puts numFmtId 14 into cellStyleXfs; cellXfs says 0.
      final row = firstRow(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>[const XlsxStyled(45000, 0)],
            ],
          },
          cellXfs: <int>[0],
        ),
      );
      expect(row, <String>['45000']);
    });

    test('1900 leap-year bug: 59, 60, 61', () {
      final row = firstRow(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>[
                const XlsxStyled(1, 0),
                const XlsxStyled(59, 0),
                const XlsxStyled(60, 0),
                const XlsxStyled(61, 0),
              ],
            ],
          },
          cellXfs: <int>[14],
        ),
      );
      expect(row, <String>[
        '1900-01-01',
        '1900-02-28',
        '1900-02-29',
        '1900-03-01',
      ]);
    });

    test('date1904 workbook', () {
      final row = firstRow(
        buildXlsx(
          <String, List<List<Object>>>{
            'S': <List<Object>>[
              <Object>[
                const XlsxStyled(0, 0),
                const XlsxStyled(45000, 0),
                const XlsxStyled(1.5, 1),
              ],
            ],
          },
          cellXfs: <int>[14, 22],
          date1904: true,
        ),
      );
      expect(row, <String>['1904-01-01', '2027-03-16', '1904-01-02 12:00']);
    });

    test('format code tokens', () {
      SpreadsheetDateKind k(String code) =>
          SpreadsheetParser.dateKindOfFormatCode(code);
      expect(k('General'), SpreadsheetDateKind.none);
      expect(k('0.00E+00'), SpreadsheetDateKind.none);
      expect(k('[Red]0.00;[Blue]-0.00'), SpreadsheetDateKind.none);
      expect(k('0.0 "mdy"'), SpreadsheetDateKind.none);
      expect(k(r'\d\m\y 0'), SpreadsheetDateKind.none);
      expect(k('_m0*y'), SpreadsheetDateKind.none);
      expect(k('[\$-409]d-mmm-yy'), SpreadsheetDateKind.date);
      expect(k('mmm yyyy'), SpreadsheetDateKind.date);
      expect(k('h:mm AM/PM'), const SpreadsheetDateKind.time());
      expect(k('mm:ss'), const SpreadsheetDateKind.time(seconds: true));
      expect(k('[h]:mm'), const SpreadsheetDateKind.time(elapsed: true));
      expect(
        k('[mm]:ss'),
        const SpreadsheetDateKind.time(seconds: true, elapsed: true),
      );
      expect(k('d/m/yy h:mm'), const SpreadsheetDateKind.dateTime());
    });

    test('values outside the date range stay numbers', () {
      expect(
        SpreadsheetParser.formatSerialDate(-1, SpreadsheetDateKind.date),
        isNull,
      );
      expect(
        SpreadsheetParser.formatSerialDate(2958465, SpreadsheetDateKind.date),
        '9999-12-31',
      );
      expect(
        SpreadsheetParser.formatSerialDate(2958466, SpreadsheetDateKind.date),
        isNull,
      );
      // 23:59:59.9 rounds into the next day.
      expect(
        SpreadsheetParser.formatSerialDate(
          45000.9999999,
          const SpreadsheetDateKind.dateTime(seconds: true),
        ),
        '2023-03-16 00:00:00',
      );
    });
  });

  group('markdown tables (sent attachment)', () {
    test('one sheet per table, named by its heading', () {
      const String md =
          '## Sales\n\n|  |  |  |\n| --- | --- | --- |\n| a | b |  |\n'
          '| 1 |  | 3 |\n\n## Other\n\n|  |\n| --- |\n| 9 |\n';
      final doc = SpreadsheetParser.fromMarkdownTables(md);
      expect(doc, isNotNull);
      expect(doc?.sheets.map((s) => s.name), <String>['Sales', 'Other']);
      expect(doc?.sheets.first.rows, <List<String>>[
        <String>['a', 'b', ''],
        <String>['1', '', '3'],
      ]);
      expect(doc?.sheets.last.rows, <List<String>>[
        <String>['9'],
      ]);
    });

    test('a header row with text stays; escaped pipes and <br>', () {
      const String md =
          '| region | revenue |\n| :--- | ---: |\n| North | 1\\|20 |\n'
          '| South | a<br>b |\n';
      final doc = SpreadsheetParser.fromMarkdownTables(md);
      expect(doc?.sheets.single.name, 'Sheet 1');
      expect(doc?.sheets.single.rows, <List<String>>[
        <String>['region', 'revenue'],
        <String>['North', '1|20'],
        <String>['South', 'a\nb'],
      ]);
    });

    test('no table gives null', () {
      expect(SpreadsheetParser.fromMarkdownTables('just | text\n'), isNull);
      expect(SpreadsheetParser.fromMarkdownTables(''), isNull);
    });
  });
}
