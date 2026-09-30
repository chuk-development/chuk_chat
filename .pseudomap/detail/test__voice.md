# test/voice · Signaturen

## test/voice/voice_call_controller_test.dart  (231 Z.)
- L10 `class _FakeDelegate implements VoiceTaskDelegate`
  - L11 `int _next = 0`
  - L12 `final StreamController<VoiceTaskResult> controller = StreamController<VoiceTaskResult>.broadcast()`
  - L16 `Future<String> startTask(String task)`
  - L19 `Stream<VoiceTaskResult> get results`
- L22 `Map<String, dynamic> _json(String s)`
- L24 `void main()`

## test/voice/voice_call_models_test.dart  (147 Z.)
- L7 `void main()`

## test/voice/voice_call_service_token_test.dart  (112 Z.)
- L8 `void main()`

## test/voice/voice_call_store_test.dart  (80 Z.)
- L11 `VoiceCallRecord _record(String chatId, DateTime start, {String text = 'Hi'})`
- L25 `void main()`

## test/voice/voice_location_test.dart  (116 Z.)
- L7 `Map<String, dynamic> _json(String s)`
- L9 `void main()`

## test/voice/voice_protocol_test.dart  (398 Z.)
- L9 `class _FakeDelegate implements VoiceTaskDelegate`
  - L10 `_FakeDelegate({this.onStart})`
  - L12 `final Future<String> Function(String task)? onStart`
  - L13 `final List<String> started = <String>[]`
  - L14 `final StreamController<VoiceTaskResult> _results = StreamController<VoiceTaskResult>.broadcast()`
  - L18 `Future<String> startTask(String task)`
  - L25 `Stream<VoiceTaskResult> get results`
- L28 `Map<String, dynamic> _json(String s)`
- L30 `void main()`

## test/voice/voice_tasks_test.dart  (113 Z.)
- L8 `class _Delegate implements VoiceTaskDelegate`
  - L10 `Future<String> startTask(String task)`
  - L13 `Stream<VoiceTaskResult> get results`
- L16 `void main()`

## test/voice/voice_transcript_test.dart  (254 Z.)
- L6 `void main()`

## test/voice/voice_widgets_test.dart  (348 Z.)
- L6 `_t0 = DateTime(2026, 9, 29, 14, 5)`
- L9 `Widget _host(Widget child, {double width = 360, double textScale = 1.0})`  — A 360 px column that scrolls, like the chat the widgets live in.
- L29 `List<VoiceTurn> _turns()`
- L47 `List<VoiceCard> _cards()`
- L100 `void main()`
