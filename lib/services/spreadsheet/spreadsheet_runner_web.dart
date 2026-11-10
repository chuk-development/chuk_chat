// Web: no isolates. The parse runs inline after the current frame, on the
// UI thread, so the web takes smaller files and grids than native (a big
// sheet would freeze the tab before the time limit could fire); the time
// limit still turns a slow parse into an error for the viewer.
import 'dart:async';
import 'dart:typed_data';

import 'spreadsheet_parser.dart';

/// The largest file the web parses (native: [SpreadsheetParser.maxBytes]).
const int kWebSpreadsheetMaxBytes = 4 * 1024 * 1024;

/// The most cells the web builds (native: [SpreadsheetParser.maxCells]).
const int kWebSpreadsheetMaxCells = 50000;

Future<SpreadsheetDocument> runSpreadsheetParse(
  Uint8List bytes,
  SpreadsheetFormat format,
  int cellLimit,
  Duration limit,
) {
  if (bytes.length > kWebSpreadsheetMaxBytes) {
    return Future<SpreadsheetDocument>.error(
      const SpreadsheetParseException(SpreadsheetErrorKind.tooLarge),
    );
  }
  final int cells = cellLimit < kWebSpreadsheetMaxCells
      ? cellLimit
      : kWebSpreadsheetMaxCells;
  return Future<SpreadsheetDocument>(
    () => SpreadsheetParser.parseSync(bytes, format, cellLimit: cells),
  ).timeout(
    limit,
    onTimeout: () =>
        throw const SpreadsheetParseException(SpreadsheetErrorKind.timeout),
  );
}
