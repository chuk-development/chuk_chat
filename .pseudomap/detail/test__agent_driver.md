# test/agent_driver · Signaturen

## test/agent_driver/agent_extensions_test.dart  (193 Z.)
- L13 `Widget _app({bool dialog = false})`
- L50 `void main()`

## test/agent_driver/fake_app.dart  (79 Z.)
- L8 `onePixelPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA' '60e6kgAAAABJRU5ErkJggg=='`  — A 1x1 transparent PNG.
- L12 `class FakeApp implements AppControl`
  - L13 `final List<Map<String, String>> driverCalls = <Map<String, String>>[]`
  - L14 `final List<String> extensionCalls = <String>[]`
  - L15 `final List<Map<String, String>> extensionArgs = <Map<String, String>>[]`
  - L16 `String? failDriverWith`
  - L17 `bool started = false`
  - L20 `bool get running`
  - L23 `Future<Map<String, Object?>> start({ required bool headless, required bool fresh, String? definesFile, })`
  - L37 `Future<Map<String, Object?>> stop()`
  - L43 `Map<String, Object?> status()`
  - L46 `List<String> logs(int lines)`
  - L50 `Future<Object?> driver(Map<String, String> params)`
  - L58 `Future<Map<String, Object?>> extension( String method, [ Map<String, String> args = const <String, String>{}, ])`
  - L74 `Future<Map<String, Object?>> hotReload({required bool fullRestart})`

## test/agent_driver/isolation_test.dart  (128 Z.)
- L8 `void main()`

## test/agent_driver/machine_events_test.dart  (41 Z.)
- L9 `void main()`

## test/agent_driver/mcp_server_test.dart  (153 Z.)
- L11 `void main()`

## test/agent_driver/tools_test.dart  (207 Z.)
- L13 `void main()`
