// Parser for the output of `flutter run --machine`.
//
// Each protocol line is a JSON array with one object, for example
//   [{"event":"app.debugPort","params":{"appId":"…","wsUri":"ws://…/ws"}}]
// Other lines (build output) are plain text.

import 'dart:convert';

/// One event of the flutter daemon protocol.
class MachineEvent {
  MachineEvent(this.event, this.params);

  final String event;
  final Map<String, Object?> params;

  String? get appId => params['appId'] as String?;
}

/// Returns the event in [line], or null when the line is plain text or a
/// command response.
MachineEvent? parseMachineLine(String line) {
  final String t = line.trim();
  if (!t.startsWith('[{') || !t.endsWith('}]')) return null;
  try {
    final Object? decoded = jsonDecode(t);
    if (decoded is! List || decoded.isEmpty) return null;
    final Object? first = decoded.first;
    if (first is! Map) return null;
    final Object? event = first['event'];
    if (event is! String) return null;
    final Object? params = first['params'];
    return MachineEvent(
      event,
      params is Map
          ? params.cast<String, Object?>()
          : const <String, Object?>{},
    );
  } on FormatException {
    return null;
  }
}

/// Encodes a daemon command for the stdin of `flutter run --machine`.
String machineCommand(int id, String method, Map<String, Object?> params) =>
    jsonEncode(<Object>[
      <String, Object?>{'id': id, 'method': method, 'params': params},
    ]);
