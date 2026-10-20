# test/voice_incoming · Signaturen

## test/voice_incoming/fakes.dart  (259 Z.)
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
  - L54 `Completer<void>? pendingStart`
  - L55 `Object? startError`
  - L58 `Stream<CallkitSignal> get signals`
  - L61 `final Set<String> _accepted = <String>{}`  — Calls the plugin counts as accepted: answered, or started by the user.
  - L63 `void emit(CallkitSignalKind kind, String id)`
  - L69 `Future<void> showIncoming(CallKitParams params)`
  - L72 `Future<void> showMissed(CallKitParams params)`
  - L75 `Future<void> startOutgoing(CallKitParams params)`
  - L84 `Future<void> setConnected(String id)`
  - L89 `Future<void> end(String id)`  — Like the plugin: ending an accepted (or started) call answers with an
- L108 `class FakeMic implements MicPermission`  — The microphone permission, as the test sets it. [pending] holds the
  - L109 `FakeMic({this.granted = true, this.grantOnRequest = true})`
  - L111 `bool granted`
  - L112 `bool grantOnRequest`
  - L113 `int requests = 0`
  - L114 `Completer<bool>? pending`
  - L117 `Future<bool> isGranted()`
  - L120 `Future<bool> request()`
- L129 `class FakeSender implements CallStateSender`
  - L130 `final List<(String, String)> sent = <(String, String)>[]`
  - L133 `Future<void> send(String callId, String state)`
- L137 `class FakeUi implements OngoingCallUi`
  - L138 `final StreamController<OngoingCallAction> controller = StreamController<OngoingCallAction>.broadcast(sync: true)`
  - L140 `final List<OngoingCallSnapshot> shown = <OngoingCallSnapshot>[]`
  - L141 `final List<String> cancelled = <String>[]`
  - L142 `int unlocks = 0`
  - L143 `final List<String> notices = <String>[]`
  - L146 `Stream<OngoingCallAction> get actions`
  - L149 `Future<void> show(OngoingCallSnapshot snapshot)`
  - L152 `Future<void> cancel(String callKey)`
  - L155 `Future<void> requestUnlock()`
  - L158 `Future<void> notice(String text)`
- L162 `class FakeCall extends ChangeNotifier implements VoiceCallView`  — The app-wide call, driven by the test.
  - L164 `VoiceCallPhase phase = VoiceCallPhase.idle`
  - L166 `String? callId`
  - L168 `String? chatId`
  - L170 `VoiceCallMode? mode`
  - L172 `String? agentName`
  - L174 `bool agentPresent = false`
  - L176 `bool micMuted = false`
  - L178 `bool speakerOn = true`
  - L180 `bool canSwitchSpeaker = true`
  - L182 `DateTime? startedAt`
  - L184 `int endCalls = 0`
  - L187 `bool get isActive`
  - L193 `void begin({ required String chatId, required VoiceCallMode mode, String? callId, String? agentName, })`  — What `VoiceCallController.start` does to the state.
  - L210 `void goLive({bool agent = true})`
  - L216 `void finish([VoiceCallPhase to = VoiceCallPhase.ended])`
  - L223 `Future<void> end()`
  - L229 `Future<void> setMicMuted(bool muted)`
  - L235 `Future<void> setSpeakerOn(bool on)`
- L243 `class FakeStarter`  — A starter that records the calls it was asked to start and, like the real
  - L244 `FakeStarter(this.call)`
  - L246 `final FakeCall call`
  - L247 `final List<IncomingCall> started = <IncomingCall>[]`
  - L249 `Future<void> start(IncomingCall incoming)`

## test/voice_incoming/incoming_call_mapping_test.dart  (214 Z.)
- L18 `void main()`

## test/voice_incoming/incoming_call_parsing_test.dart  (269 Z.)
- L12 `void main()`

## test/voice_incoming/incoming_call_service_test.dart  (646 Z.)
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

## test/voice_incoming/voice_call_permissions_section_test.dart  (56 Z.)
- L10 `void main()`
