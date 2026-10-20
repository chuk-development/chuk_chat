# test/voice_integration · Signaturen

## test/voice_integration/chat_voice_binding_agent_call_test.dart  (138 Z.)
- L14 `_thread = 'local:crypto-desk:1:74112'`
- L16 `ChatVoiceBinding _binding(VoiceCallController controller, String chatId)`
- L29 `void main()`

## test/voice_integration/chat_voice_binding_on_demand_test.dart  (165 Z.)
- L11 `class _Screen`  — A fake chat screen: a new chat (no id) until [ensureChatId] gives it one.
  - L12 `String? chatId`
  - L13 `final List<Map<String, String>> messages = <Map<String, String>>[]`
  - L14 `final List<String> discarded = <String>[]`
  - L15 `int creates = 0`
  - L18 `Completer<void>? gate`  — When set, a creation waits for it (a slow first save).
  - L20 `Future<String?> ensureChatId()`
  - L28 `Future<void> discardChat(String id)`
- L36 `ChatVoiceBinding _binding( VoiceCallController controller, _Screen screen, { bool onDemand = true, })`  — No LiveKit: the test build has no token server, so a started call fails
- L55 `Future<void> _hangUp(VoiceCallController controller)`  — Hangs up the failed call (its panel goes away) and lets the binding
- L60 `void main()`

## test/voice_integration/chat_voice_binding_test.dart  (282 Z.)
- L13 `ChatVoiceBinding _binding({ required VoiceCallController controller, required String? Function() chatId, bool agents = false, List<String>? sent, bool Function()? busy, String? Function()? agentName, void Function(List<VoiceTurn>)? onVoiceTurns, })`  — A binding over a fake screen. No LiveKit: the test build has no token
- L38 `void main()`

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
