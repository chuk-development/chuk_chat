// Web: no isolates. The parse runs inline after the current frame; the
// time limit still turns a slow parse into an error for the viewer.
import 'dart:async';
import 'dart:typed_data';

import 'spreadsheet_parser.dart';

Future<SpreadsheetDocument> runSpreadsheetParse(
  Uint8List bytes,
  SpreadsheetFormat format,
  int cellLimit,
  Duration limit,
) {
  return Future<SpreadsheetDocument>(
    () => SpreadsheetParser.parseSync(bytes, format, cellLimit: cellLimit),
  ).timeout(
    limit,
    onTimeout: () =>
        throw const SpreadsheetParseException(SpreadsheetErrorKind.timeout),
  );
}
