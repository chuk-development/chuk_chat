import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A number cell with a style: [style] is an index into the `cellXfs` list
/// passed to [buildXlsx] as `cellXfs`.
class XlsxStyled {
  const XlsxStyled(this.value, this.style);

  final num value;
  final int style;
}

/// Builds a small .xlsx in memory: [sheets] maps a sheet name to its rows.
/// Strings go into the shared string table; numbers stay numbers.
///
/// [cellXfs] lists the numFmtId of each cell style (written to
/// `xl/styles.xml`), [numFmts] the custom format codes by id, and
/// [date1904] sets `<workbookPr date1904="1"/>`.
Uint8List buildXlsx(
  Map<String, List<List<Object>>> sheets, {
  bool conditionalFormatting = false,
  bool image = false,
  bool chart = false,
  List<int> cellXfs = const <int>[],
  Map<int, String> numFmts = const <int, String>{},
  bool date1904 = false,
}) {
  final List<String> shared = <String>[];
  int sharedIndex(String s) {
    final int i = shared.indexOf(s);
    if (i >= 0) return i;
    shared.add(s);
    return shared.length - 1;
  }

  String colName(int i) {
    String out = '';
    int n = i + 1;
    while (n > 0) {
      out = String.fromCharCode(65 + (n - 1) % 26) + out;
      n = (n - 1) ~/ 26;
    }
    return out;
  }

  final Archive archive = Archive();
  void add(String name, String text) =>
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));

  final StringBuffer sheetEntries = StringBuffer();
  final StringBuffer rels = StringBuffer();
  int n = 0;
  sheets.forEach((String name, List<List<Object>> rows) {
    n++;
    sheetEntries.write('<sheet name="$name" sheetId="$n" r:id="rId$n"/>');
    rels.write(
      '<Relationship Id="rId$n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$n.xml"/>',
    );
    final StringBuffer data = StringBuffer();
    for (int r = 0; r < rows.length; r++) {
      data.write('<row r="${r + 1}">');
      for (int c = 0; c < rows[r].length; c++) {
        final Object v = rows[r][c];
        final String ref = '${colName(c)}${r + 1}';
        if (v is XlsxStyled) {
          data.write('<c r="$ref" s="${v.style}"><v>${v.value}</v></c>');
        } else if (v is num) {
          data.write('<c r="$ref"><v>$v</v></c>');
        } else if (v is bool) {
          data.write('<c r="$ref" t="b"><v>${v ? 1 : 0}</v></c>');
        } else {
          data.write('<c r="$ref" t="s"><v>${sharedIndex('$v')}</v></c>');
        }
      }
      data.write('</row>');
    }
    add(
      'xl/worksheets/sheet$n.xml',
      '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>$data</sheetData>'
          '${conditionalFormatting && n == 1 ? '<conditionalFormatting sqref="A1:A3"><cfRule type="cellIs" priority="1"/></conditionalFormatting>' : ''}'
          '</worksheet>',
    );
  });
  add(
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">${date1904 ? '<workbookPr date1904="1"/>' : ''}<sheets>$sheetEntries</sheets></workbook>',
  );
  if (cellXfs.isNotEmpty || numFmts.isNotEmpty) {
    const HtmlEscape attr = HtmlEscape(HtmlEscapeMode.attribute);
    final String fmts = numFmts.entries
        .map(
          (e) =>
              '<numFmt numFmtId="${e.key}" formatCode="${attr.convert(e.value)}"/>',
        )
        .join();
    final String xfs = cellXfs
        .map((id) => '<xf numFmtId="$id" fontId="0" applyNumberFormat="1"/>')
        .join();
    add(
      'xl/styles.xml',
      '<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<numFmts count="${numFmts.length}">$fmts</numFmts>'
          '<cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>'
          '<cellXfs count="${cellXfs.length}">$xfs</cellXfs></styleSheet>',
    );
  }
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>',
  );
  add(
    'xl/sharedStrings.xml',
    '<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '${shared.map((s) => '<si><t>${const HtmlEscape().convert(s)}</t></si>').join()}</sst>',
  );
  if (image) add('xl/media/image1.png', 'png');
  if (chart) add('xl/charts/chart1.xml', '<chartSpace/>');
  return ZipEncoder().encodeBytes(archive);
}

/// A one-sheet .xlsx whose worksheet is [sheetXml] as given (no shared
/// strings), for crafted input: forged cell references, odd markup.
Uint8List buildRawXlsx(String sheetXml) {
  final Archive archive = Archive();
  void add(String name, String text) =>
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  add(
    'xl/workbook.xml',
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>',
  );
  add('xl/worksheets/sheet1.xml', sheetXml);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// [zip] with the uncompressed size of every entry rewritten to [size], in
/// the local headers and the central directory: a zip that lies about how
/// large its parts are.
Uint8List forgeZipSizes(Uint8List zip, int size) {
  final Uint8List out = Uint8List.fromList(zip);
  final ByteData data = ByteData.sublistView(out);
  for (int i = 0; i + 30 <= out.length; i++) {
    final int sig = data.getUint32(i, Endian.little);
    if (sig == 0x04034b50) {
      data.setUint32(i + 22, size, Endian.little);
    } else if (sig == 0x02014b50 && i + 46 <= out.length) {
      data.setUint32(i + 24, size, Endian.little);
    }
  }
  return out;
}
