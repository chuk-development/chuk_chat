// Reads a spreadsheet attachment (.xlsx, .csv, .tsv) into plain rows of
// text for the read-only viewer (lib/widgets/spreadsheet/spreadsheet_viewer.dart).
//
// Pure Dart, no Flutter: the parse runs in a separate isolate
// (spreadsheet_runner_io.dart) with hard caps, so a large or hostile file can
// never freeze the UI. Caps: 16 MiB input, 250 000 cells, 15 s.
//
// What the viewer does NOT draw (charts, images, conditional formatting, pivot
// tables, macros) is detected and listed, so the reader knows the preview is
// only the cell values. Formulas show their cached value.
//
// A number cell whose style has a date or time number format (built-in ids
// 14-22 and 45-47, or a custom format code with d/m/y/h/s tokens) is shown
// as a date, a time, or both. The 1900 date system keeps Excel's leap-year
// bug (serial 60 is 1900-02-29); `<workbookPr date1904="1"/>` selects the
// 1904 system.
//
// A sent message keeps only the server's Markdown of the file, not its
// bytes; [SpreadsheetParser.fromMarkdownTables] turns the Markdown tables
// back into sheets for the same viewer.
//
// .xls (the binary BIFF format) is not read: it needs a large parser and the
// app has no dependency for it. It fails with
// [SpreadsheetErrorKind.unsupportedFormat].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'spreadsheet_runner_io.dart'
    if (dart.library.js_interop) 'spreadsheet_runner_web.dart'
    as runner;

enum SpreadsheetFormat { xlsx, xls, csv, tsv }

/// A part of the file the viewer cannot draw.
enum SpreadsheetFeature {
  charts,
  images,
  conditionalFormatting,
  pivotTables,
  macros,
}

enum SpreadsheetErrorKind { tooLarge, unsupportedFormat, timeout, invalid }

class SpreadsheetParseException implements Exception {
  const SpreadsheetParseException(this.kind, [this.detail = '']);

  final SpreadsheetErrorKind kind;
  final String detail;

  @override
  String toString() =>
      'SpreadsheetParseException($kind${detail.isEmpty ? '' : ': $detail'})';
}

class SpreadsheetSheet {
  const SpreadsheetSheet({required this.name, required this.rows});

  final String name;

  /// Dense rows; every row has [columnCount] cells ('' for an empty cell).
  final List<List<String>> rows;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;
}

class SpreadsheetDocument {
  const SpreadsheetDocument({
    required this.sheets,
    this.unsupported = const <SpreadsheetFeature>{},
    this.truncated = false,
  });

  final List<SpreadsheetSheet> sheets;
  final Set<SpreadsheetFeature> unsupported;

  /// True when the cell cap cut rows or columns off.
  final bool truncated;
}

class SpreadsheetParser {
  SpreadsheetParser._();

  static const int maxBytes = 16 * 1024 * 1024;
  static const int maxCells = 250000;
  static const Duration timeout = Duration(seconds: 15);

  /// Upper bound for the unpacked XML of one xlsx, against zip bombs. It
  /// counts the bytes really inflated (the sizes a zip declares can lie),
  /// and the inflate stops as soon as the bound is passed.
  static const int maxUnpackedBytes = 64 * 1024 * 1024;

  /// The largest grid Excel itself allows. A cell reference outside it is
  /// dropped, so a forged `r="XFD2000000000"` cannot make the parser build
  /// two billion rows.
  static const int maxSheetRows = 1048576;
  static const int maxSheetColumns = 16384;

  static SpreadsheetFormat? formatFor(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return switch (fileName.substring(dot + 1).toLowerCase()) {
      'xlsx' || 'xlsm' => SpreadsheetFormat.xlsx,
      'xls' => SpreadsheetFormat.xls,
      'csv' => SpreadsheetFormat.csv,
      'tsv' || 'tab' => SpreadsheetFormat.tsv,
      _ => null,
    };
  }

  static bool isSpreadsheet(String fileName) => formatFor(fileName) != null;

  /// Parses off the UI isolate. Throws [SpreadsheetParseException].
  static Future<SpreadsheetDocument> parse(
    Uint8List bytes,
    SpreadsheetFormat format, {
    int cellLimit = maxCells,
    Duration limit = timeout,
  }) async {
    _checkInput(bytes, format);
    return runner.runSpreadsheetParse(bytes, format, cellLimit, limit);
  }

  static void _checkInput(Uint8List bytes, SpreadsheetFormat format) {
    if (bytes.length > maxBytes) {
      throw const SpreadsheetParseException(SpreadsheetErrorKind.tooLarge);
    }
    if (format == SpreadsheetFormat.xls) {
      throw const SpreadsheetParseException(
        SpreadsheetErrorKind.unsupportedFormat,
      );
    }
  }

  /// The parse itself, on the calling isolate. Throws
  /// [SpreadsheetParseException].
  static SpreadsheetDocument parseSync(
    Uint8List bytes,
    SpreadsheetFormat format, {
    int cellLimit = maxCells,
  }) {
    _checkInput(bytes, format);
    switch (format) {
      case SpreadsheetFormat.csv:
      case SpreadsheetFormat.tsv:
        return _parseDelimited(bytes, format, cellLimit);
      case SpreadsheetFormat.xlsx:
        return _parseXlsx(bytes, cellLimit);
      case SpreadsheetFormat.xls:
        throw const SpreadsheetParseException(
          SpreadsheetErrorKind.unsupportedFormat,
        );
    }
  }

  // ── CSV / TSV ──────────────────────────────────────────────────────────

  static SpreadsheetDocument _parseDelimited(
    Uint8List bytes,
    SpreadsheetFormat format,
    int cellLimit,
  ) {
    String text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    final String delimiter = format == SpreadsheetFormat.tsv
        ? '\t'
        : _sniffCsvDelimiter(text);
    final List<List<String>> rows = parseDelimitedText(text, delimiter);
    final _Densified dense = _densify(rows, cellLimit);
    return SpreadsheetDocument(
      sheets: <SpreadsheetSheet>[
        SpreadsheetSheet(
          name: format == SpreadsheetFormat.tsv ? 'TSV' : 'CSV',
          rows: dense.rows,
        ),
      ],
      truncated: dense.truncated,
    );
  }

  /// A European CSV uses `;`. Picks it when the first line has more `;`
  /// than `,` outside quotes.
  static String _sniffCsvDelimiter(String text) {
    int commas = 0, semis = 0;
    bool quoted = false;
    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      if (ch == '"') quoted = !quoted;
      if (quoted) continue;
      if (ch == '\n' || ch == '\r') break;
      if (ch == ',') commas++;
      if (ch == ';') semis++;
    }
    return semis > commas ? ';' : ',';
  }

  /// RFC 4180 reading: quoted fields, `""` inside quotes, CRLF / LF / CR
  /// line ends, line breaks inside quoted fields.
  static List<List<String>> parseDelimitedText(String text, String delimiter) {
    final List<List<String>> rows = <List<String>>[];
    List<String> row = <String>[];
    final StringBuffer field = StringBuffer();
    bool quoted = false;
    bool fieldStarted = false;
    int i = 0;
    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final String ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          quoted = false;
        } else {
          field.write(ch);
        }
        i++;
        continue;
      }
      if (ch == '"' && field.isEmpty && !fieldStarted) {
        quoted = true;
        fieldStarted = true;
      } else if (ch == delimiter) {
        endField();
      } else if (ch == '\r') {
        endRow();
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
      } else if (ch == '\n') {
        endRow();
      } else {
        field.write(ch);
        fieldStarted = true;
      }
      i++;
    }
    if (field.isNotEmpty || fieldStarted || row.isNotEmpty) endRow();
    return rows;
  }

  // ── Markdown tables (a sent attachment) ───────────────────────────────

  static final RegExp _mdSeparator = RegExp(
    r'^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$',
  );
  static final RegExp _mdHeading = RegExp(r'^#{1,6}\s+(.*?)\s*#*$');

  /// The pipe tables of [markdown] as sheets, one sheet per table, named by
  /// the heading above it (the server writes `## <sheet name>` before each
  /// sheet). A header row with no text is dropped. Null when there is no
  /// table at all.
  static SpreadsheetDocument? fromMarkdownTables(
    String markdown, {
    int cellLimit = maxCells,
  }) {
    final List<String> lines = const LineSplitter().convert(markdown);
    final List<SpreadsheetSheet> sheets = <SpreadsheetSheet>[];
    final Map<String, int> names = <String, int>{};
    String? heading;
    bool truncated = false;
    int budget = cellLimit;
    int i = 0;
    while (i < lines.length) {
      final String line = lines[i].trim();
      final RegExpMatch? h = _mdHeading.firstMatch(line);
      if (h != null) {
        heading = h.group(1);
        i++;
        continue;
      }
      final bool starts =
          line.startsWith('|') &&
          i + 1 < lines.length &&
          _mdSeparator.hasMatch(lines[i + 1].trim());
      if (!starts) {
        i++;
        continue;
      }
      final List<List<String>> rows = <List<String>>[_mdCells(line)];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_mdCells(lines[i].trim()));
        i++;
      }
      if (rows.first.every((c) => c.isEmpty)) rows.removeAt(0);
      String name = (heading == null || heading.isEmpty)
          ? 'Sheet ${sheets.length + 1}'
          : heading;
      final int seen = names[name] = (names[name] ?? 0) + 1;
      if (seen > 1) name = '$name ($seen)';
      if (budget <= 0) {
        truncated = true;
        sheets.add(SpreadsheetSheet(name: name, rows: const <List<String>>[]));
        continue;
      }
      final _Densified dense = _densify(rows, budget);
      truncated = truncated || dense.truncated;
      budget -= dense.cellCount;
      sheets.add(SpreadsheetSheet(name: name, rows: dense.rows));
    }
    if (sheets.isEmpty) return null;
    return SpreadsheetDocument(sheets: sheets, truncated: truncated);
  }

  /// The cells of one table line: `\|` is a literal pipe, `<br>` a line
  /// break.
  static List<String> _mdCells(String line) {
    String body = line;
    if (body.startsWith('|')) body = body.substring(1);
    if (body.endsWith('|') && !body.endsWith(r'\|')) {
      body = body.substring(0, body.length - 1);
    }
    final List<String> cells = <String>[];
    final StringBuffer cell = StringBuffer();
    for (int i = 0; i < body.length; i++) {
      final String ch = body[i];
      if (ch == r'\' && i + 1 < body.length && body[i + 1] == '|') {
        cell.write('|');
        i++;
      } else if (ch == '|') {
        cells.add(cell.toString());
        cell.clear();
      } else {
        cell.write(ch);
      }
    }
    cells.add(cell.toString());
    return <String>[
      for (final String c in cells)
        c.trim().replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
    ];
  }

  // ── XLSX ───────────────────────────────────────────────────────────────

  static SpreadsheetDocument _parseXlsx(Uint8List bytes, int cellLimit) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw SpreadsheetParseException(SpreadsheetErrorKind.invalid, '$e');
    }
    int declared = 0;
    final Set<SpreadsheetFeature> unsupported = <SpreadsheetFeature>{};
    for (final ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      declared += f.size;
      final String name = f.name;
      if (name.startsWith('xl/charts/')) {
        unsupported.add(SpreadsheetFeature.charts);
      }
      if (name.startsWith('xl/media/')) {
        unsupported.add(SpreadsheetFeature.images);
      }
      if (name.startsWith('xl/pivotTables/') ||
          name.startsWith('xl/pivotCache/')) {
        unsupported.add(SpreadsheetFeature.pivotTables);
      }
      if (name == 'xl/vbaProject.bin') {
        unsupported.add(SpreadsheetFeature.macros);
      }
    }
    // The declared sizes are a quick first check only.
    if (declared > maxUnpackedBytes) {
      throw const SpreadsheetParseException(SpreadsheetErrorKind.tooLarge);
    }

    // Every part read counts the bytes it really inflates against one
    // budget; the inflate stops at the bound.
    int inflated = 0;
    String? read(String path) {
      final ArchiveFile? f = archive.find(path);
      if (f == null || !f.isFile) return null;
      final _CappedOutput out = _CappedOutput(maxUnpackedBytes - inflated);
      try {
        f.decompress(out);
      } on _InflateLimitReached {
        throw const SpreadsheetParseException(SpreadsheetErrorKind.tooLarge);
      } on SpreadsheetParseException {
        rethrow;
      } catch (e) {
        // A part that inflates past the size it declares, or broken data.
        throw SpreadsheetParseException(SpreadsheetErrorKind.invalid, '$e');
      } finally {
        f.clear();
      }
      if (out.exceeded) {
        throw const SpreadsheetParseException(SpreadsheetErrorKind.tooLarge);
      }
      inflated += out.length;
      return utf8.decode(out.bytes, allowMalformed: true);
    }

    final String? workbookXml = read('xl/workbook.xml');
    if (workbookXml == null) {
      throw const SpreadsheetParseException(
        SpreadsheetErrorKind.invalid,
        'no xl/workbook.xml',
      );
    }
    try {
      final List<String> shared = _sharedStrings(read('xl/sharedStrings.xml'));
      final Map<String, String> rels = _relationships(
        read('xl/_rels/workbook.xml.rels'),
      );
      final XmlDocument workbook = XmlDocument.parse(workbookXml);
      final bool date1904 = workbook.descendantElements
          .where((e) => e.localName == 'workbookPr')
          .any((e) {
            final String flag = (e.getAttribute('date1904') ?? '')
                .trim()
                .toLowerCase();
            return flag == '1' || flag == 'true';
          });
      final List<SpreadsheetDateKind> styles = cellStyleKinds(
        read('xl/styles.xml'),
      );
      final _CellContext context = _CellContext(shared, styles, date1904);
      final List<SpreadsheetSheet> sheets = <SpreadsheetSheet>[];
      bool truncated = false;
      int budget = cellLimit;
      int index = 0;
      for (final XmlElement sheet in workbook.descendantElements.where(
        (e) => e.localName == 'sheet',
      )) {
        index++;
        final String name = sheet.getAttribute('name') ?? 'Sheet $index';
        final String? rid = sheet.attributes
            .where((a) => a.localName == 'id')
            .map((a) => a.value)
            .firstOrNull;
        String? target = rid == null ? null : rels[rid];
        target ??= 'worksheets/sheet$index.xml';
        final String path = target.startsWith('/')
            ? target.substring(1)
            : 'xl/$target';
        final String? xml = read(path);
        if (xml == null) continue; // a chart sheet or a missing part
        if (xml.contains('conditionalFormatting')) {
          unsupported.add(SpreadsheetFeature.conditionalFormatting);
        }
        if (budget <= 0) {
          truncated = true;
          sheets.add(
            SpreadsheetSheet(name: name, rows: const <List<String>>[]),
          );
          continue;
        }
        final _SparseSheet sparse = _sheetCells(xml, context, budget);
        final _Densified dense = _densifySparse(sparse.cells, budget);
        truncated = truncated || sparse.truncated || dense.truncated;
        budget -= dense.cellCount;
        sheets.add(SpreadsheetSheet(name: name, rows: dense.rows));
      }
      return SpreadsheetDocument(
        sheets: sheets,
        unsupported: unsupported,
        truncated: truncated,
      );
    } on SpreadsheetParseException {
      rethrow;
    } catch (e) {
      throw SpreadsheetParseException(SpreadsheetErrorKind.invalid, '$e');
    }
  }

  /// The shared strings, read as a stream of events (no DOM of a large
  /// table): the visible text of each `<si>`, without phonetic runs.
  static List<String> _sharedStrings(String? xml) {
    if (xml == null) return const <String>[];
    final List<String> out = <String>[];
    StringBuffer? item;
    int rph = 0;
    bool inT = false;
    for (final XmlEvent e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        switch (e.localName) {
          case 'si':
            item = StringBuffer();
            rph = 0;
            inT = false;
            if (e.isSelfClosing) {
              out.add('');
              item = null;
            }
          case 'rPh':
            if (!e.isSelfClosing) rph++;
          case 't':
            inT = item != null && rph == 0 && !e.isSelfClosing;
        }
      } else if (e is XmlEndElementEvent) {
        switch (e.localName) {
          case 'si':
            if (item != null) out.add(item.toString());
            item = null;
          case 'rPh':
            if (rph > 0) rph--;
          case 't':
            inT = false;
        }
      } else if (inT && item != null) {
        if (e is XmlTextEvent) item.write(e.value);
        if (e is XmlCDATAEvent) item.write(e.value);
      }
    }
    return out;
  }

  static Map<String, String> _relationships(String? xml) {
    if (xml == null) return const <String, String>{};
    final XmlDocument doc = XmlDocument.parse(xml);
    return <String, String>{
      for (final XmlElement rel in doc.descendantElements.where(
        (e) => e.localName == 'Relationship',
      ))
        if ((rel.getAttribute('Id'), rel.getAttribute('Target')) case (
          final String id,
          final String target,
        ))
          id: target,
    };
  }

  /// The cells of a worksheet, read as a stream of events: row index ->
  /// column index -> text. Cells outside Excel's grid are dropped, and the
  /// read stops after [budget] cells with text (the grid cannot show more).
  static _SparseSheet _sheetCells(
    String xml,
    _CellContext context,
    int budget,
  ) {
    final Map<int, Map<int, String>> cells = <int, Map<int, String>>{};
    int stored = 0;
    bool truncated = false;
    int nextRow = 0;
    int rowIndex = 0;
    int nextCol = 0;
    // The cell being read.
    int? col;
    String type = 'n';
    String? style;
    StringBuffer? value;
    StringBuffer? inline;
    bool inV = false;
    bool inIs = false;
    bool inT = false;
    int rph = 0;

    void finishCell() {
      final int? c = col;
      col = null;
      if (c == null) return;
      final String text = _cellValue(
        type: type,
        style: style,
        value: value?.toString(),
        inline: inline?.toString(),
        context: context,
      );
      if (text.isEmpty) return;
      if (rowIndex < 0 ||
          rowIndex >= maxSheetRows ||
          c < 0 ||
          c >= maxSheetColumns) {
        truncated = true;
        return;
      }
      (cells[rowIndex] ??= <int, String>{})[c] = text;
      stored++;
    }

    for (final XmlEvent e in parseEvents(xml)) {
      if (stored >= budget && budget > 0) {
        // More text cells than the grid may hold: the rest is cut.
        if (e is XmlStartElementEvent && e.localName == 'c') {
          truncated = true;
          break;
        }
      }
      if (e is XmlStartElementEvent) {
        switch (e.localName) {
          case 'row':
            final int? r = int.tryParse(_attr(e, 'r') ?? '');
            rowIndex = (r ?? (nextRow + 1)) - 1;
            nextRow = rowIndex + 1;
            nextCol = 0;
          case 'c':
            final int c = _columnOf(_attr(e, 'r')) ?? nextCol;
            nextCol = c + 1;
            col = c;
            type = _attr(e, 't') ?? 'n';
            style = _attr(e, 's');
            value = null;
            inline = null;
            rph = 0;
            if (e.isSelfClosing) finishCell();
          case 'v':
            if (col != null && !e.isSelfClosing) {
              value = StringBuffer();
              inV = true;
            }
          case 'is':
            if (col != null && !e.isSelfClosing) {
              inline = StringBuffer();
              inIs = true;
            }
          case 'rPh':
            if (inIs && !e.isSelfClosing) rph++;
          case 't':
            inT = inIs && rph == 0 && !e.isSelfClosing;
        }
      } else if (e is XmlEndElementEvent) {
        switch (e.localName) {
          case 'c':
            finishCell();
          case 'v':
            inV = false;
          case 'is':
            inIs = false;
          case 'rPh':
            if (rph > 0) rph--;
          case 't':
            inT = false;
        }
      } else if (e is XmlTextEvent || e is XmlCDATAEvent) {
        final String text = e is XmlTextEvent
            ? e.value
            : (e as XmlCDATAEvent).value;
        if (inV) value?.write(text);
        if (inT) inline?.write(text);
      }
    }
    return _SparseSheet(cells, truncated);
  }

  static String? _attr(XmlStartElementEvent e, String localName) {
    for (final XmlEventAttribute a in e.attributes) {
      if (a.localName == localName) return a.value;
    }
    return null;
  }

  /// The shown text of one cell from its type, style and raw parts.
  static String _cellValue({
    required String type,
    required String? style,
    required String? value,
    required String? inline,
    required _CellContext context,
  }) {
    switch (type) {
      case 'inlineStr':
        return inline ?? '';
      case 's':
        final List<String> shared = context.shared;
        final int? i = int.tryParse(value?.trim() ?? '');
        return i != null && i >= 0 && i < shared.length ? shared[i] : '';
      case 'b':
        final String raw = value?.trim() ?? '';
        return raw == '1' ? 'TRUE' : (raw == '0' ? 'FALSE' : raw);
      case 'n':
        final String raw = value ?? '';
        final int? s = int.tryParse(style ?? '');
        if (s == null || s < 0 || s >= context.styles.length) return raw;
        final SpreadsheetDateKind kind = context.styles[s];
        if (kind == SpreadsheetDateKind.none) return raw;
        final double? serial = double.tryParse(raw.trim());
        if (serial == null) return raw;
        return formatSerialDate(serial, kind, date1904: context.date1904) ??
            raw;
      default:
        return value ?? '';
    }
  }

  /// The dense grid of [cells] within [cellLimit] cells. Only the rows and
  /// columns that fit are built, whatever the coordinates say.
  static _Densified _densifySparse(
    Map<int, Map<int, String>> cells,
    int cellLimit,
  ) {
    if (cells.isEmpty || cellLimit <= 0) {
      return _Densified(const <List<String>>[], 0, cells.isNotEmpty);
    }
    int maxRow = 0;
    int maxCol = 0;
    cells.forEach((int r, Map<int, String> row) {
      if (r > maxRow) maxRow = r;
      for (final int c in row.keys) {
        if (c > maxCol) maxCol = c;
      }
    });
    bool truncated = false;
    int width = maxCol + 1;
    if (width > cellLimit) {
      width = cellLimit;
      truncated = true;
    }
    int keep = maxRow + 1;
    if (keep * width > cellLimit) {
      keep = cellLimit ~/ width;
      truncated = true;
    }
    final List<List<String>> out = <List<String>>[
      for (int r = 0; r < keep; r++)
        List<String>.generate(
          width,
          (c) => cells[r]?[c] ?? '',
          growable: false,
        ),
    ];
    return _Densified(out, keep * width, truncated);
  }

  // ── Dates ──────────────────────────────────────────────────────────────

  /// What a cell style shows, per `cellXfs` index of `xl/styles.xml`.
  static List<SpreadsheetDateKind> cellStyleKinds(String? stylesXml) {
    if (stylesXml == null) return const <SpreadsheetDateKind>[];
    final XmlDocument doc = XmlDocument.parse(stylesXml);
    final Map<int, String> custom = <int, String>{
      for (final XmlElement f in doc.descendantElements.where(
        (e) => e.localName == 'numFmt',
      ))
        if ((
              int.tryParse(f.getAttribute('numFmtId') ?? ''),
              f.getAttribute('formatCode'),
            )
            case (final int id, final String code))
          id: code,
    };
    final XmlElement? xfs = doc.descendantElements
        .where((e) => e.localName == 'cellXfs')
        .firstOrNull;
    if (xfs == null) return const <SpreadsheetDateKind>[];
    return <SpreadsheetDateKind>[
      for (final XmlElement xf in xfs.childElements.where(
        (e) => e.localName == 'xf',
      ))
        _kindForNumFmt(
          int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0,
          custom,
        ),
    ];
  }

  static SpreadsheetDateKind _kindForNumFmt(int id, Map<int, String> custom) {
    final String? code = custom[id];
    if (code != null) return dateKindOfFormatCode(code);
    return builtInDateKind(id);
  }

  /// The built-in number formats that show a date or a time.
  static SpreadsheetDateKind builtInDateKind(int id) {
    if (id >= 14 && id <= 17) return SpreadsheetDateKind.date;
    // 18 h:mm AM/PM, 19 h:mm:ss AM/PM, 20 h:mm, 21 h:mm:ss.
    if (id == 18 || id == 20) return const SpreadsheetDateKind.time();
    if (id == 19 || id == 21) {
      return const SpreadsheetDateKind.time(seconds: true);
    }
    if (id == 22) return const SpreadsheetDateKind.dateTime(); // m/d/yy h:mm
    // 45 mm:ss, 46 [h]:mm:ss, 47 mmss.0.
    if (id == 45 || id == 47) {
      return const SpreadsheetDateKind.time(seconds: true);
    }
    if (id == 46) {
      return const SpreadsheetDateKind.time(seconds: true, elapsed: true);
    }
    return SpreadsheetDateKind.none;
  }

  /// Reads a custom number format code. Text in quotes, escaped (`\x`),
  /// padded (`_x`) and repeated (`*x`) characters and bracket parts such as
  /// `[Red]` or `[$-409]` do not count; `[h]`, `[m]` and `[s]` are elapsed
  /// time. An `m` right after an hour or right before a second is minutes.
  static SpreadsheetDateKind dateKindOfFormatCode(String code) {
    // Only the first section (positive numbers) decides.
    final List<String> tokens = <String>[];
    final String lowerCode = code.toLowerCase();
    bool elapsed = false;
    int i = 0;
    while (i < code.length) {
      final String ch = code[i];
      if (ch == ';') break;
      if (ch == '"') {
        final int end = code.indexOf('"', i + 1);
        i = end < 0 ? code.length : end + 1;
        continue;
      }
      if (ch == r'\' || ch == '_' || ch == '*') {
        i += 2;
        continue;
      }
      if (ch == '[') {
        final int end = code.indexOf(']', i + 1);
        final String inner =
            (end < 0 ? code.substring(i + 1) : code.substring(i + 1, end))
                .toLowerCase();
        if (RegExp(r'^(h+|m+|s+)$').hasMatch(inner)) {
          elapsed = true;
          tokens.add(inner[0]);
        }
        i = end < 0 ? code.length : end + 1;
        continue;
      }
      if (lowerCode.startsWith('general', i)) {
        i += 7;
        continue;
      }
      if (lowerCode.startsWith('am/pm', i)) {
        tokens.add('a');
        i += 5;
        continue;
      }
      if (lowerCode.startsWith('a/p', i)) {
        tokens.add('a');
        i += 3;
        continue;
      }
      final String lower = lowerCode[i];
      if ('ymdhs'.contains(lower)) {
        // A run of one letter is one token.
        int j = i;
        while (j < code.length && lowerCode[j] == lower) {
          j++;
        }
        tokens.add(lower);
        i = j;
        continue;
      }
      i++;
    }
    bool date = false, time = elapsed, seconds = false;
    for (int t = 0; t < tokens.length; t++) {
      switch (tokens[t]) {
        case 'y' || 'd':
          date = true;
        case 'h' || 'a':
          time = true;
        case 's':
          time = true;
          seconds = true;
        case 'm':
          final bool afterHour = t > 0 && tokens[t - 1] == 'h';
          final bool beforeSecond =
              t + 1 < tokens.length && tokens[t + 1] == 's';
          if (afterHour || beforeSecond) {
            time = true;
          } else {
            date = true;
          }
      }
    }
    if (date && time) return SpreadsheetDateKind.dateTime(seconds: seconds);
    if (date) return SpreadsheetDateKind.date;
    if (time) {
      return SpreadsheetDateKind.time(seconds: seconds, elapsed: elapsed);
    }
    return SpreadsheetDateKind.none;
  }

  /// The serial number [serial] as text for [kind], or null when it is not
  /// a valid date (negative, or past the year 9999).
  ///
  /// 1900 system: 1 is 1900-01-01, 60 is the 1900-02-29 that Excel keeps
  /// from Lotus 1-2-3, so every serial above 60 is one day late. 1904
  /// system: 0 is 1904-01-01.
  static String? formatSerialDate(
    double serial,
    SpreadsheetDateKind kind, {
    bool date1904 = false,
  }) {
    if (kind == SpreadsheetDateKind.none) return null;
    if (serial.isNaN || serial.isInfinite || serial < 0) return null;
    if (serial >= 2958466) return null; // after 9999-12-31
    String two(int v) => v.toString().padLeft(2, '0');

    int day = serial.floor();
    int secs = ((serial - day) * 86400).round();
    if (secs >= 86400) {
      day++;
      secs -= 86400;
    }
    final int h = secs ~/ 3600, m = (secs % 3600) ~/ 60, s = secs % 60;
    String clock(int hours) =>
        '${two(hours)}:${two(m)}${kind.seconds ? ':${two(s)}' : ''}';

    if (kind.isTimeOnly) {
      return clock(kind.elapsed ? day * 24 + h : h);
    }

    final String date;
    if (date1904) {
      final DateTime d = DateTime.utc(1904, 1, 1 + day);
      date = '${d.year}-${two(d.month)}-${two(d.day)}';
    } else if (day == 0) {
      date = '1900-01-00'; // what Excel shows
    } else if (day == 60) {
      date = '1900-02-29'; // the Lotus leap-year bug
    } else {
      final DateTime d = DateTime.utc(1899, 12, day < 60 ? 31 + day : 30 + day);
      date =
          '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
    }
    return kind.hasTime ? '$date ${clock(h)}' : date;
  }

  /// `"BC12"` -> 54 (zero based). Null when there is no letter part.
  static int? _columnOf(String? ref) {
    if (ref == null) return null;
    int col = 0;
    int i = 0;
    while (i < ref.length) {
      final int code = ref.codeUnitAt(i);
      final int upper = code & ~0x20;
      if (upper < 0x41 || upper > 0x5A) break;
      col = col * 26 + (upper - 0x40);
      i++;
    }
    return i == 0 ? null : col - 1;
  }

  /// Column letters for a zero-based index: 0 -> A, 26 -> AA.
  static String columnName(int index) {
    final StringBuffer out = StringBuffer();
    int n = index + 1;
    while (n > 0) {
      final int rem = (n - 1) % 26;
      out.write(String.fromCharCode(0x41 + rem));
      n = (n - 1) ~/ 26;
    }
    return out.toString().split('').reversed.join();
  }

  /// Pads rows to one width and keeps the grid within [cellLimit] cells.
  static _Densified _densify(List<List<String>> rows, int cellLimit) {
    // Trailing empty rows say nothing.
    int end = rows.length;
    while (end > 0 && rows[end - 1].every((c) => c.isEmpty)) {
      end--;
    }
    int width = 0;
    for (int r = 0; r < end; r++) {
      if (rows[r].length > width) width = rows[r].length;
    }
    if (end == 0 || width == 0) {
      return const _Densified(<List<String>>[], 0, false);
    }
    bool truncated = false;
    if (width > cellLimit) {
      width = cellLimit;
      truncated = true;
    }
    int keep = end;
    if (keep * width > cellLimit) {
      keep = cellLimit ~/ width;
      truncated = true;
    }
    final List<List<String>> out = <List<String>>[
      for (int r = 0; r < keep; r++)
        List<String>.generate(
          width,
          (c) => c < rows[r].length ? rows[r][c] : '',
          growable: false,
        ),
    ];
    return _Densified(out, keep * width, truncated);
  }
}

/// How a number cell is shown: as is, or as a date and/or a time.
class SpreadsheetDateKind {
  const SpreadsheetDateKind._(
    this._hasDate,
    this.hasTime, {
    this.seconds = false,
    this.elapsed = false,
  });

  const SpreadsheetDateKind.time({bool seconds = false, bool elapsed = false})
    : this._(false, true, seconds: seconds, elapsed: elapsed);

  const SpreadsheetDateKind.dateTime({bool seconds = false})
    : this._(true, true, seconds: seconds);

  /// Not a date: the raw number.
  static const SpreadsheetDateKind none = SpreadsheetDateKind._(false, false);
  static const SpreadsheetDateKind date = SpreadsheetDateKind._(true, false);

  final bool _hasDate;
  final bool hasTime;

  /// The format shows seconds.
  final bool seconds;

  /// `[h]`: hours past 24 are kept, not rolled into days.
  final bool elapsed;

  bool get isTimeOnly => hasTime && !_hasDate;

  @override
  bool operator ==(Object other) =>
      other is SpreadsheetDateKind &&
      other._hasDate == _hasDate &&
      other.hasTime == hasTime &&
      other.seconds == seconds &&
      other.elapsed == elapsed;

  @override
  int get hashCode => Object.hash(_hasDate, hasTime, seconds, elapsed);

  @override
  String toString() =>
      'SpreadsheetDateKind(date: $_hasDate, time: $hasTime, '
      'seconds: $seconds, elapsed: $elapsed)';
}

class _CellContext {
  const _CellContext(this.shared, this.styles, this.date1904);

  final List<String> shared;
  final List<SpreadsheetDateKind> styles;
  final bool date1904;
}

class _Densified {
  const _Densified(this.rows, this.cellCount, this.truncated);

  final List<List<String>> rows;
  final int cellCount;
  final bool truncated;
}

/// Thrown by [_CappedOutput] when an inflate passes its bound.
class _InflateLimitReached implements Exception {
  const _InflateLimitReached();
}

/// Collects inflated bytes up to [limit] and throws past it, so a zip
/// bomb stops after the bound instead of filling the memory.
class _CappedOutput extends OutputStream {
  _CappedOutput(this.limit) : super(byteOrder: ByteOrder.littleEndian);

  final int limit;
  final OutputMemoryStream _out = OutputMemoryStream();
  bool exceeded = false;

  Uint8List get bytes => _out.getBytes();

  @override
  int get length => _out.length;

  void _room(int count) {
    if (_out.length + count > limit) {
      exceeded = true;
      throw const _InflateLimitReached();
    }
  }

  @override
  void clear() => _out.clear();

  @override
  void flush() => _out.flush();

  @override
  void writeByte(int value) {
    _room(1);
    _out.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _room(length ?? bytes.length);
    _out.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _room(stream.length);
    _out.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _room(count);
    _out.writeBackReference(distance, count);
  }

  @override
  Uint8List subset(int start, [int? end]) => _out.subset(start, end);
}

/// A worksheet's text cells and whether the read stopped early.
class _SparseSheet {
  const _SparseSheet(this.cells, this.truncated);

  final Map<int, Map<int, String>> cells;
  final bool truncated;
}
