# test/services/agents · Signaturen

## test/services/agents/agent_profile_store_test.dart  (58 Z.)
- L5 `void main()`

## test/services/agents/agent_read_marks_persist_test.dart  (42 Z.)
- L7 `void main()`

## test/services/agents/agent_roster_store_test.dart  (249 Z.)
- L14 `void main()`

## test/services/agents/agents_cloud_relay_test.dart  (615 Z.)
- L25 `class _FakeRelayServer implements RelaySocket`  — A stand-in for `api.chuk.chat/v2/relay/ws`.
  - L26 `_FakeRelayServer({this.authOk = true, this.claimReply})`
  - L28 `final bool authOk`
  - L32 `final Map<String, dynamic>? claimReply`  — What the relay answers a `cowork_pair_claim` with. Null means the real
  - L35 `final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[]`  — Every frame the app sent, decoded.
  - L38 `final StreamController<Map<String, dynamic>> _toHost = StreamController<Map<String, dynamic>>.broadcast()`  — Local-relay envelopes the app addressed to the host, unwrapped.
  - L40 `Stream<Map<String, dynamic>> get toHost`
  - L42 `final StreamController<dynamic> _toApp = StreamController<dynamic>.broadcast()`
  - L44 `bool closed = false`
  - L46 `static const String hostDeviceId = 'host-device-uuid'`
  - L49 `Stream<dynamic> get incoming`
  - L52 `void send(String data)`
  - L94 `void fromHost(Map<String, dynamic> envelope)`  — The host answers. An executor sends no target_device_id, and its payload
  - L102 `void _deliver(Map<String, dynamic> frame)`
  - L107 `Future<void> close()`
- L117 `class _HostSide`  — The §15 initiator, exactly as the host runs it, speaking the LOCAL relay
  - L118 `_HostSide({ required this.server, required this.channelId, required this.digits, required this.signingKeyPair, required this.deviceId, })`
  - L126 `final _FakeRelayServer server`
  - L127 `final String channelId`
  - L128 `final String digits`
  - L129 `final SimpleKeyPair signingKeyPair`
  - L130 `final String deviceId`
  - L132 `late final AgentsPairing _initiator`
  - L133 `AgentsFrameSealer? _sealer`
  - L134 `AgentsFrameOpener? _opener`
  - L135 `String? connection`
  - L136 `List<int>? sessionTranscript`
  - L137 `Uint8List? sessionKey`
  - L138 `SimplePublicKey? controllerKey`
  - L140 `Future<Uint8List> mac(List<int> key, String label)`
  - L149 `final List<Map<String, dynamic>> opened = <Map<String, dynamic>>[]`  — Payloads the host opened out of the app's sealed frames.
  - L150 `final Completer<void> paired = Completer<void>()`
  - L152 `Future<void> start()`
  - L163 `void _send(String step, Map<String, dynamic> data)`
  - L167 `Future<void> _onEnvelope(Map<String, dynamic> env)`
  - L257 `void _establishCodec()`
  - L271 `Future<void> emit(Map<String, dynamic> payload)`
- L281 `class _Session implements AccountSessionSource`
  - L282 `_Session(this._session)`
  - L283 `final AccountSession? _session`
  - L286 `AccountSession? current()`
  - L289 `Future<AccountSession?> refresh()`
- L292 `void main()`

## test/services/agents/agents_crypto_vectors_test.dart  (185 Z.)
- L23 `void main()`  — Cross-language byte-compatibility proof for the Agents frame crypto.
- L163 `class _FixedByteRandom implements Random`  — A [Random] that hands out a fixed byte sequence through [nextInt], so the
  - L164 `_FixedByteRandom(this._bytes)`
  - L166 `final List<int> _bytes`
  - L167 `int _index = 0`
  - L170 `int nextInt(int max)`
  - L180 `bool nextBool()`
  - L183 `double nextDouble()`

## test/services/agents/agents_heal_channel_test.dart  (400 Z.)
- L26 `class _Session implements AccountSessionSource`
  - L27 `_Session(this._current)`
  - L28 `final AccountSession? _current`
  - L30 `AccountSession? current()`
  - L32 `Future<AccountSession?> refresh()`
- L37 `class _Relay implements RelaySocket`  — The relay as a reconnect sees it: `auth_ok`, then the presence snapshot it
  - L38 `_Relay({required this.online, this.claimCode})`
  - L41 `final List<String> online`  — Executor ids the presence snapshot reports online.
  - L44 `final String? claimCode`  — Null: the claim succeeds for [hostId]. Else the refusal code.
  - L47 `bool silentClaims = false`  — True: the relay never answers a claim.
  - L49 `static const String hostId = 'host-relay-uuid'`
  - L51 `final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[]`
  - L52 `final StreamController<dynamic> _toApp = StreamController<dynamic>.broadcast()`
  - L53 `bool closed = false`
  - L56 `Stream<dynamic> get incoming`
  - L59 `void send(String data)`
  - L95 `void deliver(Map<String, dynamic> frame)`
  - L97 `void _deliver(Map<String, dynamic> frame)`
  - L102 `Future<void> close()`
- L108 `class _RecordingTransport implements ExecutorTransport`
  - L109 `final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[]`
  - L111 `Future<void> sendAuthentication( ExecutorHandle target, Map<String, dynamic> payload, )`
- L119 `void main()`
- L388 `Future<SimpleKeyPair> _keyPair()`
- L390 `Future<AgentsStoredPairing> _pairing(Uint8List key, Uri hostUrl)`

## test/services/agents/agents_pairing_restore_test.dart  (425 Z.)
- L12 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L13 `final Map<String, String> map = <String, String>{}`
  - L16 `Future<String?> read(String key)`
  - L19 `Future<void> write(String key, String value)`
  - L22 `Future<void> delete(String key)`
- L28 `class _FakeMirror extends SupabasePairingSync`  — The encrypted mirror, scripted. [record] is what a read returns once
  - L29 `_FakeMirror(this.record)`
  - L31 `final AgentsStoredPairing record`
  - L32 `bool available = false`
  - L33 `int reads = 0`
  - L34 `int publishes = 0`
  - L35 `bool writable = false`
  - L38 `Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing)`
  - L44 `AgentsCloudPairingOutcome missing = AgentsCloudPairingOutcome.keyLocked`  — What a read answers while [available] is false.
  - L47 `Future<AgentsCloudPairingRead> readEncryptedPairing()`
  - L55 `Future<void> saveEncryptedPairing(AgentsStoredPairing pairing)`
  - L58 `Future<void> clearEncryptedPairing()`
- L61 `class _Session implements AccountSessionSource`
  - L62 `AccountSession? session`
  - L65 `AccountSession? current()`
  - L68 `Future<AccountSession?> refresh()`
- L71 `void main()`
- L414 `class _ThrowingStore implements AgentsSecureKeyValueStore`
  - L416 `Future<String?> read(String key)`
  - L419 `Future<void> write(String key, String value)`
  - L423 `Future<void> delete(String key)`

## test/services/agents/agents_pairing_store_test.dart  (194 Z.)
- L10 `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the store round-trips with no platform channel.
  - L11 `final Map<String, String> map = <String, String>{}`
  - L14 `Future<String?> read(String key)`
  - L17 `Future<void> write(String key, String value)`
  - L20 `Future<void> delete(String key)`
- L23 `void main()`

## test/services/agents/agents_pairing_test.dart  (502 Z.)
- L21 `void main()`  — Pairing tests: the cross-language vector (byte-for-byte against the Python

## test/services/agents/agents_pairing_uri_test.dart  (137 Z.)
- L9 `void main()`  — The one string the user ever handles. It comes off a QR code, out of a

## test/services/agents/agents_queued_marks_test.dart  (126 Z.)
- L10 `void main()`  — The imported bubble offers **Retry** only for a row whose status is

## test/services/agents/agents_reconnect_test.dart  (374 Z.)
- L20 `void main()`  — Reconnect handshake tests: the cross-language vector (byte-for-byte against

## test/services/agents/agents_relay_client_test.dart  (2140 Z.)
- L26 `class FakeMcpStore extends McpStore`  — A stand-in [McpStore] whose forward payloads are canned, so a task-frame
  - L27 `FakeMcpStore(this._payloads)`
  - L29 `final List<Map<String, dynamic>> _payloads`
  - L32 `Future<List<Map<String, dynamic>>> forwardPayloads()`
- L37 `class FakeHereNowStore extends HereNowStore`  — A stand-in [HereNowStore] whose forward payload is canned, so a task-frame
  - L38 `FakeHereNowStore(this._payload)`
  - L40 `final Map<String, dynamic>? _payload`
  - L43 `Future<Map<String, dynamic>?> forwardPayload()`
- L48 `class FakeRelaySocket implements RelaySocket`  — A fake duplex socket. `send()` from the client is captured on [outbound];
  - L49 `final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast()`
  - L51 `final StreamController<String> _outbound = StreamController<String>.broadcast()`
  - L52 `bool closed = false`
  - L55 `Stream<dynamic> get incoming`
  - L58 `Stream<String> get outbound`  — Envelopes the client sent (join, pairing steps, frames).
  - L61 `void send(String data)`
  - L67 `void deliver(String data)`  — Push an envelope down to the client.
  - L72 `Future<void> close()`
- L82 `class FakeExecutorHost`  — The in-Dart executor: it plays the pairing INITIATOR and, once paired, seals
  - L83 `FakeExecutorHost({ required this.socket, required this.deviceId, required this.channelId, required this.digits, required this.signingKeyPair, required this.nowMs, })`
  - L92 `final FakeRelaySocket socket`
  - L93 `final String deviceId`
  - L94 `final String channelId`
  - L95 `final String digits`
  - L96 `final SimpleKeyPair signingKeyPair`
  - L97 `final int Function() nowMs`
  - L99 `final AgentsApprovedDevices approved = AgentsApprovedDevices.empty()`
  - L100 `late final AgentsPairing _initiator`
  - L102 `AgentsFrameSealer? _sealer`
  - L103 `AgentsFrameOpener? _opener`
  - L106 `final List<Map<String, dynamic>> received = <Map<String, dynamic>>[]`  — Payloads the host opened from the client (account_authentication, task…).
  - L108 `final Completer<void> paired = Completer<void>()`
  - L110 `static String frameToWire(AgentsFrame f)`
  - L112 `static AgentsFrame frameFromWire(String w)`
  - L115 `Future<void> start()`
  - L127 `void _sendPairing(String step, Map<String, dynamic> data)`
  - L133 `Future<void> _onClientEnvelope(String raw)`
  - L146 `Future<void> _onPairing(Map<String, dynamic> env)`
  - L163 `void _establishCodec()`
  - L178 `Future<void> _onFrame(Map<String, dynamic> env)`
  - L185 `Future<void> emit(Map<String, dynamic> payload)`  — Seal a payload and push it to the client (delta / tool / done / error).
- L195 `class _SessionSource implements AccountSessionSource`  — A session source the test scripts: what `current()` returns and what a
  - L196 `_SessionSource({required AccountSession current, AccountSession? refreshed}) : _current = current, _refreshed = refreshed`
  - L200 `AccountSession _current`
  - L201 `final AccountSession? _refreshed`
  - L202 `int refreshCalls = 0`
  - L205 `AccountSession? current()`
  - L208 `Future<AccountSession?> refresh()`
- L216 `void main()`

## test/services/agents/agents_relay_done_reason_test.dart  (26 Z.)
- L8 `void main()`  — `done.reason` semantics the thread view relies on (docs/WIRE_CONTRACT.md,

## test/services/agents/agents_relay_reconnect_test.dart  (280 Z.)
- L19 `class FakeRelaySocket implements RelaySocket`  — A fake duplex socket (client send captured on [outbound]; host writes via
  - L20 `final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast()`
  - L22 `final StreamController<String> _outbound = StreamController<String>.broadcast()`
  - L25 `Stream<dynamic> get incoming`
  - L27 `Stream<String> get outbound`
  - L30 `void send(String data)`
  - L34 `void deliver(String data)`
  - L39 `Future<void> close()`
- L49 `class FakeReconnectHost`  — A fake host that plays the reconnect INITIATOR: on join it sends a signed
  - L50 `FakeReconnectHost({ required this.socket, required this.hostDeviceId, required this.hostKeyPair, required this.appDeviceId, required this.appPublicKey, required this.channelId, required this.channelKey, })`
  - L60 `final FakeRelaySocket socket`
  - L61 `final String hostDeviceId`
  - L62 `final SimpleKeyPair hostKeyPair`
  - L63 `final String appDeviceId`
  - L64 `final SimplePublicKey appPublicKey`
  - L65 `final String channelId`
  - L66 `final Uint8List channelKey`
  - L68 `late final AgentsReconnect _initiator`
  - L69 `AgentsFrameSealer? _sealer`
  - L70 `AgentsFrameOpener? _opener`
  - L71 `final List<Map<String, dynamic>> received = <Map<String, dynamic>>[]`
  - L72 `final Completer<void> authenticated = Completer<void>()`
  - L74 `Future<void> start()`
  - L85 `void _sendPairing(String step, Map<String, dynamic> data)`
  - L91 `Future<void> _onEnvelope(String raw)`
  - L115 `void _establishCodec()`
  - L131 `Future<void> emit(Map<String, dynamic> payload)`
- L142 `void main()`

## test/services/agents/agents_relay_secrets_test.dart  (136 Z.)
- L14 `void main()`  — The secrets frames over the real sealed channel (docs/WIRE_CONTRACT.md,

## test/services/agents/agents_replay_loader_test.dart  (736 Z.)
- L19 `void main()`
- L731 `Future<void> _drain()`  — Lets the loader's internal handler chain settle.

## test/services/agents/agents_replay_paging_test.dart  (153 Z.)
- L18 `void main()`  — Replay paging in the loader (docs/WIRE_CONTRACT.md "Replay paging", Bead

## test/services/agents/agents_replay_repeat_test.dart  (181 Z.)
- L12 `Map<String, String> user(String text)`  — Bead cowork-4rpt: the same message, twice.
- L18 `Map<String, String> ai(String text)`
- L24 `List<String> texts(List<Map<String, String>> rows)`
- L27 `void main()`
- L140 `void _pagingTests()`
- L157 `void _repairTests()`

## test/services/agents/agents_run_ledger_test.dart  (371 Z.)
- L11 `void main()`

## test/services/agents/agents_shell_status_test.dart  (84 Z.)
- L6 `void main()`

## test/services/agents/agents_stopped_run_test.dart  (296 Z.)
- L23 `void main()`  — A run that ends with nothing must END — visibly (bead cowork-gnr8).
- L285 `List<Map<String, dynamic>> _rowsFor(String session)`
- L291 `Future<void> _drain()`

## test/services/agents/agents_task_delivery_test.dart  (310 Z.)
- L26 `void main()`  — A message sent at 04:49 was gone. The app drew a sent bubble and a typing
- L305 `Future<void> _drain()`  — Lets the adapter's internal handler chain settle.

## test/services/agents/agents_task_outbox_test.dart  (230 Z.)
- L10 `void main()`  — Bead cowork-i7sd: "ob die Nachrichten im Backend ankommen, ist irgendwie

## test/services/agents/browser_presence_test.dart  (345 Z.)
- L6 `void main()`

## test/services/agents/chat_core_routing_test.dart  (308 Z.)
- L35 `chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b'`
- L36 `threadKey = 'amber-otter-2'`
- L38 `StoredChat _chat(String id, String text)`
- L47 `void main()`
- L303 `Future<void> _drain()`

## test/services/agents/chat_debug_export_size_test.dart  (102 Z.)
- L16 `void main()`  — The debug copy has to be the size chuk_chat's is. A thread that carries a

## test/services/agents/chat_document_persistence_test.dart  (203 Z.)
- L24 `Future<String> _encryptWithKey(String plaintext, SecretKey key)`  — Builds the production ciphertext envelope around [plaintext] with an
- L42 `void main()`

## test/services/agents/offline_retry_manager_test.dart  (150 Z.)
- L9 `void main()`  — The Retry button in the imported bubble calls

## test/services/agents/room_source_test.dart  (221 Z.)
- L8 `AgentsRoomMember _m(String id, String handle)`
- L11 `AgentsRoomDraft _draft( String name, { List<AgentsRoomMember>? members, bool agentToAgent = true, })`
- L22 `void main()`

## test/services/agents/schedule_spec_test.dart  (431 Z.)
- L7 `void main()`  — 2026-02-03 is a Tuesday. Every date in this file is built from local

## test/services/agents/tool_card_parity_test.dart  (317 Z.)
- L33 `Map<String, dynamic> _visible(Map<String, dynamic> call)`  — The fields of a card the reader can see: everything the renderer reads
- L43 `_t0 = DateTime.fromMillisecondsSinceEpoch(1_757_040_000_000)`  — The host's clock, as a current host sends it: unix seconds.
- L44 `DateTime _at(int seconds)`
- L47 `_liveRun = <AgentsRelayInbound>[ const AgentsRelayDelta('Let me look.'), AgentsRelayTool( 'run_command', arguments: 'ls `  — One run: a command that worked, one that failed, a child agent.
- L92 `_replayedRun = <AgentsRelayInbound>[ const AgentsRelayUser('do the thing', mid: 1), const AgentsRelayDelta('Let me look.`  — The same run as the host replays it: every frame marked, in row order,
- L144 `void main()`
- L312 `Future<void> _drain()`

## test/services/agents/tool_events_contract_test.dart  (178 Z.)
- L11 `void main()`
