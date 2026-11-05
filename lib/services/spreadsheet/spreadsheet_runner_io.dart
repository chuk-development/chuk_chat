// Native: the spreadsheet parse runs in its own isolate, and a parse that
// passes the time limit is killed, not left running.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'spreadsheet_parser.dart';

Future<SpreadsheetDocument> runSpreadsheetParse(
  Uint8List bytes,
  SpreadsheetFormat format,
  int cellLimit,
  Duration limit,
) async {
  final ReceivePort port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn<List<Object>>(
      _entry,
      <Object>[port.sendPort, bytes, format.index, cellLimit],
      errorsAreFatal: true,
      onExit: port.sendPort,
      onError: port.sendPort,
    );
    final Object? message = await port.first.timeout(limit);
    if (message is SpreadsheetDocument) return message;
    if (message is SpreadsheetParseException) throw message;
    throw SpreadsheetParseException(
      SpreadsheetErrorKind.invalid,
      message?.toString() ?? 'parser exited',
    );
  } on TimeoutException {
    throw const SpreadsheetParseException(SpreadsheetErrorKind.timeout);
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _entry(List<Object> args) {
  final SendPort reply = args[0] as SendPort;
  try {
    reply.send(
      SpreadsheetParser.parseSync(
        args[1] as Uint8List,
        SpreadsheetFormat.values[args[2] as int],
        cellLimit: args[3] as int,
      ),
    );
  } on SpreadsheetParseException catch (e) {
    reply.send(e);
  } catch (e) {
    reply.send(SpreadsheetParseException(SpreadsheetErrorKind.invalid, '$e'));
  }
}
