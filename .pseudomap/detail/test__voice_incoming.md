# test/voice_incoming · Signaturen

## test/voice_incoming/fakes.dart  (253 Z.)
- L14 `Map<String, dynamic> incomingFrame({ String callId = '3f2a9c1d0b7e4a55', String threadId = 'local:crypto-desk:1:74112', String agentName = 'Crypto Desk', String reason = 'Your pizza is ready to come out of the oven.', String urgency = 'normal', required DateTime expiresAt, num? ringSeconds, })`  — A frame as the host sends it.
- L34 `Map<String, dynamic> stateFrame(String callId, String state)`
- L41 `class FakeCallkit implements CallkitPort`
  - L42 `final StreamController<CallkitSignal> controller = StreamController<CallkitSignal>.broadcast(sync: true)`
  - L44 `final List<CallKitParams> shown = <CallKitParams>[]`
  - L45 `final List<CallKitParams> missed = <CallKitParams>[]`
  - L46 `final List<CallKitParams> started = <CallKitParams>[]`
  - L47 `final List<String> connected = <String>[]`
  - L48 `final List<String> ended = <String>[]`
  - L52 `bool echoOnEnd = true`  — Whether [end] answers with the plugin's own event. On by default, as on
  - L55 `Stream<CallkitSignal> get signals`
  - L58 `final Set<String> _accepted = <String>{}`  — Calls the plugin counts as accepted: answered, or started by the user.
  - L60 `void emit(CallkitSignalKind kind, String id)`
  - L66 `Future<void> showIncoming(CallKitParams params)`
  - L69 `Future<void> showMissed(CallKitParams params)`
  - L72 `Future<void> startOutgoing(CallKitParams params)`
  - L78 `Future<void> setConnected(String id)`
  - L83 `Future<void> end(String id)`  — Like the plugin: ending an accepted (or started) call answers with an
- L102 `class FakeMic implements MicPermission`  — The microphone permission, as the test sets it. [pending] holds the
  - L103 `FakeMic({this.granted = true, this.grantOnRequest = true})`
  - L105 `bool granted`
  - L106 `bool grantOnRequest`
  - L107 `int requests = 0`
  - L108 `Completer<bool>? pending`
  - L111 `Future<bool> isGranted()`
  - L114 `Future<bool> request()`
- L123 `class FakeSender implements CallStateSender`
  - L124 `final List<(String, String)> sent = <(String, String)>[]`
  - L127 `Future<void> send(String callId, String state)`
- L131 `class FakeUi implements OngoingCallUi`
  - L132 `final StreamController<OngoingCallAction> controller = StreamController<OngoingCallAction>.broadcast(sync: true)`
  - L134 `final List<OngoingCallSnapshot> shown = <OngoingCallSnapshot>[]`
  - L135 `final List<String> cancelled = <String>[]`
  - L136 `int unlocks = 0`
  - L137 `final List<String> notices = <String>[]`
  - L140 `Stream<OngoingCallAction> get actions`
  - L143 `Future<void> show(OngoingCallSnapshot snapshot)`
  - L146 `Future<void> cancel(String callKey)`
  - L149 `Future<void> requestUnlock()`
  - L152 `Future<void> notice(String text)`
- L156 `class FakeCall extends ChangeNotifier implements VoiceCallView`  — The app-wide call, driven by the test.
  - L158 `VoiceCallPhase phase = VoiceCallPhase.idle`
  - L160 `String? callId`
  - L162 `String? chatId`
  - L164 `VoiceCallMode? mode`
  - L166 `String? agentName`
  - L168 `bool agentPresent = false`
  - L170 `bool micMuted = false`
  - L172 `bool speakerOn = true`
  - L174 `bool canSwitchSpeaker = true`
  - L176 `DateTime? startedAt`
  - L178 `int endCalls = 0`
  - L181 `bool get isActive`
  - L187 `void begin({ required String chatId, required VoiceCallMode mode, String? callId, String? agentName, })`  — What `VoiceCallController.start` does to the state.
  - L204 `void goLive({bool agent = true})`
  - L210 `void finish([VoiceCallPhase to = VoiceCallPhase.ended])`
  - L217 `Future<void> end()`
  - L223 `Future<void> setMicMuted(bool muted)`
  - L229 `Future<void> setSpeakerOn(bool on)`
- L237 `class FakeStarter`  — A starter that records the calls it was asked to start and, like the real
  - L238 `FakeStarter(this.call)`
  - L240 `final FakeCall call`
  - L241 `final List<IncomingCall> started = <IncomingCall>[]`
  - L243 `Future<void> start(IncomingCall incoming)`

## test/voice_incoming/incoming_call_mapping_test.dart  (214 Z.)
- L18 `void main()`

## test/voice_incoming/incoming_call_parsing_test.dart  (269 Z.)
- L12 `void main()`

## test/voice_incoming/incoming_call_service_test.dart  (522 Z.)
- L18 `void main()`

## test/voice_incoming/incoming_call_starter_test.dart  (115 Z.)
- L22 `_thread = 'local:crypto-desk:1:74112'`
- L23 `_reason = 'Your pizza is ready to come out of the oven.'`
- L25 `ChatVoiceBinding _binding(VoiceCallController controller)`
- L35 `void main()`

## test/voice_incoming/relay_call_state_sender_test.dart  (130 Z.)
- L11 `class _Transport implements AgentsRelayController, AgentsVoiceCallControl`
  - L12 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L16 `final List<(String, String)> sent = <(String, String)>[]`
  - L17 `bool fail = false`
  - L20 `ValueListenable<AgentsRelayState> get state`
  - L22 `void pair()`
  - L24 `void drop()`
  - L28 `Future<void> sendVoiceCallState({ required String callId, required String state, })`
  - L37 `dynamic noSuchMethod(Invocation invocation)`
- L42 `class _PlainTransport implements AgentsRelayController`  — A paired transport that is an [AgentsRelayController] but NOT an
  - L43 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.paired), )`
  - L49 `ValueListenable<AgentsRelayState> get state`
  - L52 `dynamic noSuchMethod(Invocation invocation)`
- L55 `void main()`

## test/voice_incoming/voice_call_permissions_section_test.dart  (60 Z.)
- L10 `void main()`
