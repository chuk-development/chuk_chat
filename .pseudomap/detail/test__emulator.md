# test/emulator · Signaturen

## test/emulator/emulator_chat_ws_test.dart  (252 Z.)
- L14 `class _WireClient`  — A minimal /v2/ws client that collects frames per req_id.
  - L15 `_WireClient(this.channel)`
  - L22 `final IOWebSocketChannel channel`
  - L23 `final _frames = StreamController<Map<String, dynamic>>.broadcast()`
  - L24 `final _closed = Completer<void>()`
  - L25 `late final Stream<Map<String, dynamic>> frames = _frames.stream`
  - L27 `Future<void> get closed`
  - L29 `static Future<_WireClient> connect(ChukEmulator emu)`
  - L41 `void send(Map<String, Object?> frame)`
  - L44 `Future<List<Map<String, dynamic>>> chat( String reqId, Map<String, Object?> payload, )`  — Sends a chat request and returns every frame up to `done`.
- L57 `Map<String, Object?> _payload(String message)`
- L65 `String _joined(List<Map<String, dynamic>> frames, String kind)`
- L70 `void main()`

## test/emulator/emulator_client_test.dart  (121 Z.)
- L12 `void main()`

## test/emulator/emulator_http_test.dart  (189 Z.)
- L10 `void main()`
