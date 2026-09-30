# test/voice_integration · Signaturen

## test/voice_integration/chat_voice_binding_agent_call_test.dart  (138 Z.)
- L14 `_thread = 'local:crypto-desk:1:74112'`
- L16 `ChatVoiceBinding _binding(VoiceCallController controller, String chatId)`
- L29 `void main()`

## test/voice_integration/chat_voice_binding_test.dart  (193 Z.)
- L13 `ChatVoiceBinding _binding({ required VoiceCallController controller, required String? Function() chatId, bool agents = false, List<String>? sent, bool Function()? busy, String? Function()? agentName, })`  — A binding over a fake screen. No LiveKit: the test build has no token
- L36 `void main()`

## test/voice_integration/voice_call_context_test.dart  (130 Z.)
- L5 `Map<String, String> _user(String text)`
- L10 `Map<String, String> _ai(String text)`
- L15 `void main()`

## test/voice_integration/voice_record_placement_test.dart  (156 Z.)
- L7 `DateTime _t(int minute)`
- L9 `VoiceCallRecord _record(int minute)`
- L19 `void main()`

## test/voice_integration/voice_task_delegates_test.dart  (158 Z.)
- L12 `class _FakeSender`  — A sender that records what it was asked and lets the test finish each
  - L13 `final List<String> sent = <String>[]`
  - L14 `final List<Completer<VoiceTurnOutcome>> turns = <Completer<VoiceTurnOutcome>>[]`
  - L17 `Future<VoiceTurnOutcome> call(String text)`
- L25 `void main()`

## test/voice_integration/voice_turn_queue_test.dart  (251 Z.)
- L9 `class _FakeChat`  — Stands in for a chat screen: each send appends a user row and an
  - L10 `String? chatId = 'chat-1'`
  - L11 `bool busy = false`
  - L12 `bool refuse = false`
  - L13 `final List<String> sent = <String>[]`
  - L14 `int rows = 0`
  - L16 `Future<void> send(String text, VoiceTurnStarted onStarted)`
  - L24 `bool offline = false`
  - L26 `VoiceTurnQueue queue({ Duration maxWait = const Duration(seconds: 5), Duration turnTimeout = const Duration(seconds: 5), })`
- L40 `void main()`
