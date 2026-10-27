# test/services/agents · Signaturen

## test/services/agents/agent_mail_alias_test.dart  (201 Z.)
- L15 `void main()`  — Plus aliases of the agent address (docs/AGENT_MAIL.md §1, §8): the tag

## test/services/agents/agent_mail_crypto_test.dart  (142 Z.)
- L11 `void main()`  — The seal format `chuk-agent-mail-v1` against the test vector of

## test/services/agents/agent_mail_key_handover_test.dart  (218 Z.)
- L19 `void main()`  — The mail key goes to the host over the end-to-end channel

## test/services/agents/agent_mail_service_test.dart  (720 Z.)
- L16 `void main()`  — The agent mail client against the v2 contract (docs/AGENT_MAIL.md §3,

## test/services/agents/agent_profile_store_test.dart  (89 Z.)
- L5 `void main()`

## test/services/agents/agent_read_marks_persist_test.dart  (42 Z.)
- L7 `void main()`

## test/services/agents/agent_roster_store_test.dart  (249 Z.)
- L14 `void main()`

## test/services/agents/agent_templates_test.dart  (166 Z.)
- L12 `void main()`

## test/services/agents/agents_cloud_relay_test.dart  (806 Z.)
- L25 `class _FakeRelayServer implements RelaySocket`  — A stand-in for `api.chuk.chat/v2/relay/ws`.
  - L26 `_FakeRelayServer({this.authOk = true, this.claimReply})`
  - L28 `final bool authOk`
  - L31 `bool answerPing = true`  — False plays a socket whose far end is gone: a `ping` gets no `pong`.
  - L35 `final Map<String, dynamic>? claimReply`  — What the relay answers a `cowork_pair_claim` with. Null means the real
  - L38 `final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[]`  — Every frame the app sent, decoded.
  - L41 `final StreamController<Map<String, dynamic>> _toHost = StreamController<Map<String, dynamic>>.broadcast()`  — Local-relay envelopes the app addressed to the host, unwrapped.
  - L43 `Stream<Map<String, dynamic>> get toHost`
  - L45 `final StreamController<dynamic> _toApp = StreamController<dynamic>.broadcast()`
  - L47 `bool closed = false`
  - L49 `static const String hostDeviceId = 'host-device-uuid'`
  - L52 `Stream<dynamic> get incoming`
  - L55 `void send(String data)`
  - L99 `void fromHost(Map<String, dynamic> envelope)`  — The host answers. An executor sends no target_device_id, and its payload
  - L107 `void _deliver(Map<String, dynamic> frame)`
  - L112 `Future<void> close()`
- L122 `class _HostSide`  — The §15 initiator, exactly as the host runs it, speaking the LOCAL relay
  - L123 `_HostSide({ required this.server, required this.channelId, required this.digits, required this.signingKeyPair, required this.deviceId, this.answerResume = true, })`
  - L134 `final bool answerResume`  — False plays a host that goes away right after the ceremony: it never
  - L136 `final _FakeRelayServer server`
  - L137 `final String channelId`
  - L138 `final String digits`
  - L139 `final SimpleKeyPair signingKeyPair`
  - L140 `final String deviceId`
  - L142 `late final AgentsPairing _initiator`
  - L143 `AgentsFrameSealer? _sealer`
  - L144 `AgentsFrameOpener? _opener`
  - L145 `String? connection`
  - L146 `List<int>? sessionTranscript`
  - L147 `Uint8List? sessionKey`
  - L148 `SimplePublicKey? controllerKey`
  - L150 `Future<Uint8List> mac(List<int> key, String label)`
  - L159 `final List<Map<String, dynamic>> opened = <Map<String, dynamic>>[]`  — Payloads the host opened out of the app's sealed frames.
  - L160 `final Completer<void> paired = Completer<void>()`
  - L162 `Future<void> start()`
  - L173 `void _send(String step, Map<String, dynamic> data)`
  - L177 `Future<void> _onEnvelope(Map<String, dynamic> env)`
  - L268 `void _establishCodec()`
  - L282 `Future<void> emit(Map<String, dynamic> payload)`
- L292 `class _Session implements AccountSessionSource`
  - L293 `_Session(this._session)`
  - L294 `final AccountSession? _session`
  - L297 `AccountSession? current()`
  - L300 `Future<AccountSession?> refresh()`
- L303 `void main()`

## test/services/agents/agents_crypto_vectors_test.dart  (185 Z.)
- L23 `void main()`  — Cross-language byte-compatibility proof for the Agents frame crypto.
- L163 `class _FixedByteRandom implements Random`  — A [Random] that hands out a fixed byte sequence through [nextInt], so the
  - L164 `_FixedByteRandom(this._bytes)`
  - L166 `final List<int> _bytes`
  - L167 `int _index = 0`
  - L170 `int nextInt(int max)`
  - L180 `bool nextBool()`
  - L183 `double nextDouble()`

## test/services/agents/agents_frame_fragments_test.dart  (120 Z.)
- L13 `List<Map<String, dynamic>> split( Map<String, dynamic> payload, { int chunk = 256 * 1024, String id = 'abc123', })`  — The host's split (`fragment_plaintexts` in chuk_agents_executor.protocol).
- L38 `void main()`

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

## test/services/agents/agents_install_claim_wait_test.dart  (552 Z.)
- L24 `class _ClaimSocket implements RelaySocket`  — One relay socket. It signs the app in, then answers each claim with the
  - L25 `_ClaimSocket(this.script, {this.authOk = true, this.commitOnBind = false})`
  - L27 `final List<String> script`
  - L28 `final bool authOk`
  - L32 `final bool commitOnBind`  — Sends the host's commit right behind the claim answer, as the real host
  - L34 `static const Map<String, dynamic> commit = <String, dynamic>{ 'type': 'pairing', 'step': 'commit', }`
  - L40 `List<Map<String, dynamic>> get relayed`  — The local-relay envelopes the app sent to the host, unwrapped.
  - L45 `int claims = 0`
  - L46 `final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[]`
  - L47 `bool closed = false`
  - L49 `static const String hostDeviceId = 'host-device-9'`
  - L51 `final StreamController<dynamic> _toApp = StreamController<dynamic>.broadcast()`
  - L55 `Stream<dynamic> get incoming`
  - L58 `void send(String data)`
  - L110 `void _deliver(Map<String, dynamic> frame)`
  - L118 `Future<void> close()`
- L124 `class _Session implements AccountSessionSource`
  - L125 `const _Session([this._session = _signedIn])`
  - L127 `static const AccountSession _signedIn = AccountSession( accessToken: 'jwt', refreshToken: 'r', userId: 'user-1', )`
  - L133 `final AccountSession? _session`
  - L136 `AccountSession? current()`
  - L139 `Future<AccountSession?> refresh()`
- L142 `void main()`

## test/services/agents/agents_install_flow_test.dart  (252 Z.)
- L14 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L15 `final Map<String, String> map = <String, String>{}`
  - L18 `Future<String?> read(String key)`
  - L21 `Future<void> write(String key, String value)`
  - L24 `Future<void> delete(String key)`
- L27 `class _Session implements AccountSessionSource`
  - L28 `const _Session([this.userId = 'user-1'])`
  - L30 `final String? userId`
  - L33 `AccountSession? current()`
  - L38 `Future<AccountSession?> refresh()`
- L42 `class _Wait`  — One pending wait: the test decides when and how it ends.
  - L43 `_Wait(this.invite, this.deadline, this.cancel)`
  - L45 `final AgentsPairingInvite invite`
  - L46 `final DateTime deadline`
  - L47 `final AgentsClaimCancel cancel`
  - L48 `final Completer<String?> result = Completer<String?>()`
- L51 `void main()`

## test/services/agents/agents_install_ticket_test.dart  (225 Z.)
- L13 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L14 `final Map<String, String> map = <String, String>{}`
  - L17 `Future<String?> read(String key)`
  - L20 `Future<void> write(String key, String value)`
  - L23 `Future<void> delete(String key)`
- L26 `void main()`

## test/services/agents/agents_invite_pairing_test.dart  (236 Z.)
- L19 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L20 `final Map<String, String> map = <String, String>{}`
  - L23 `Future<String?> read(String key)`
  - L26 `Future<void> write(String key, String value)`
  - L29 `Future<void> delete(String key)`
- L33 `class _RecordingMirror extends SupabasePairingSync`  — The encrypted mirror, recording what it was asked to store.
  - L34 `final List<AgentsStoredPairing> saved = <AgentsStoredPairing>[]`
  - L37 `Future<void> saveEncryptedPairing(AgentsStoredPairing pairing)`
  - L42 `Future<void> clearEncryptedPairing()`
- L45 `class _Session implements AccountSessionSource`
  - L46 `const _Session([this._session])`
  - L48 `final AccountSession? _session`
  - L51 `AccountSession? current()`
  - L54 `Future<AccountSession?> refresh()`
- L57 `void main()`

## test/services/agents/agents_pairing_key_replace_test.dart  (173 Z.)
- L16 `void main()`

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

## test/services/agents/agents_relay_client_test.dart  (2336 Z.)
- L27 `class FakeMcpStore extends McpStore`  — A stand-in [McpStore] whose forward payloads are canned, so a task-frame
  - L28 `FakeMcpStore(this._payloads)`
  - L30 `final List<Map<String, dynamic>> _payloads`
  - L33 `Future<List<Map<String, dynamic>>> forwardPayloads()`
- L38 `class FakeHereNowStore extends HereNowStore`  — A stand-in [HereNowStore] whose forward payload is canned, so a task-frame
  - L39 `FakeHereNowStore(this._payload)`
  - L41 `final Map<String, dynamic>? _payload`
  - L44 `Future<Map<String, dynamic>?> forwardPayload()`
- L49 `class FakeRelaySocket implements RelaySocket`  — A fake duplex socket. `send()` from the client is captured on [outbound];
  - L50 `final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast()`
  - L52 `final StreamController<String> _outbound = StreamController<String>.broadcast()`
  - L53 `bool closed = false`
  - L56 `Stream<dynamic> get incoming`
  - L59 `Stream<String> get outbound`  — Envelopes the client sent (join, pairing steps, frames).
  - L62 `void send(String data)`
  - L68 `void deliver(String data)`  — Push an envelope down to the client.
  - L73 `Future<void> close()`
- L83 `class FakeExecutorHost`  — The in-Dart executor: it plays the pairing INITIATOR and, once paired, seals
  - L84 `FakeExecutorHost({ required this.socket, required this.deviceId, required this.channelId, required this.digits, required this.signingKeyPair, required this.nowMs, })`
  - L93 `final FakeRelaySocket socket`
  - L94 `final String deviceId`
  - L95 `final String channelId`
  - L96 `final String digits`
  - L97 `final SimpleKeyPair signingKeyPair`
  - L98 `final int Function() nowMs`
  - L100 `final AgentsApprovedDevices approved = AgentsApprovedDevices.empty()`
  - L101 `late final AgentsPairing _initiator`
  - L103 `AgentsFrameSealer? _sealer`
  - L104 `AgentsFrameOpener? _opener`
  - L107 `final List<Map<String, dynamic>> received = <Map<String, dynamic>>[]`  — Payloads the host opened from the client (account_authentication, task…).
  - L109 `final Completer<void> paired = Completer<void>()`
  - L111 `static String frameToWire(AgentsFrame f)`
  - L113 `static AgentsFrame frameFromWire(String w)`
  - L116 `Future<void> start()`
  - L128 `void _sendPairing(String step, Map<String, dynamic> data)`
  - L134 `Future<void> _onClientEnvelope(String raw)`
  - L147 `Future<void> _onPairing(Map<String, dynamic> env)`
  - L164 `void _establishCodec()`
  - L179 `Future<void> _onFrame(Map<String, dynamic> env)`
  - L186 `Future<void> emit(Map<String, dynamic> payload)`  — Seal a payload and push it to the client (delta / tool / done / error).
- L196 `class _SessionSource implements AccountSessionSource`  — A session source the test scripts: what `current()` returns and what a
  - L197 `_SessionSource({required AccountSession current, AccountSession? refreshed}) : _current = current, _refreshed = refreshed`
  - L201 `AccountSession _current`
  - L202 `final AccountSession? _refreshed`
  - L203 `int refreshCalls = 0`
  - L206 `AccountSession? current()`
  - L209 `Future<AccountSession?> refresh()`
- L217 `void main()`

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

## test/services/agents/agents_replay_loader_test.dart  (864 Z.)
- L20 `void main()`
- L859 `Future<void> _drain()`  — Lets the loader's internal handler chain settle.

## test/services/agents/agents_replay_paging_test.dart  (154 Z.)
- L18 `void main()`  — Replay paging in the loader (docs/WIRE_CONTRACT.md "Replay paging", Bead

## test/services/agents/agents_replay_repeat_test.dart  (371 Z.)
- L12 `Map<String, String> user(String text)`  — Bead cowork-4rpt: the same message, twice.
- L18 `Map<String, String> ai(String text)`
- L24 `List<String> texts(List<Map<String, String>> rows)`
- L27 `void main()`
- L271 `void _pagingTests()`
- L288 `void _repairTests()`

## test/services/agents/agents_run_cost_test.dart  (281 Z.)
- L11 `_block = <String, dynamic>{ 'currency': 'EUR', 'eur': 0.002345, 'input_tokens': 5000, 'output_tokens': 150, 'cached_toke`
- L40 `AgentsRelayApprovalRequest _action({ String? decision, String? scope, List<String> options = const <String>[ 'once', 'always_this_agent', 'always_this_site', 'deny', ], })`
- L68 `void main()`

## test/services/agents/agents_run_ledger_test.dart  (371 Z.)
- L11 `void main()`

## test/services/agents/agents_shell_status_test.dart  (84 Z.)
- L6 `void main()`

## test/services/agents/agents_skill_proposal_relay_test.dart  (261 Z.)
- L13 `void main()`  — Skill proposals over the real sealed channel (docs/WIRE_CONTRACT.md,

## test/services/agents/agents_stopped_run_test.dart  (297 Z.)
- L23 `void main()`  — A run that ends with nothing must END — visibly (bead cowork-gnr8).
- L286 `List<Map<String, dynamic>> _rowsFor(String session)`
- L292 `Future<void> _drain()`

## test/services/agents/agents_task_delivery_test.dart  (358 Z.)
- L26 `void main()`  — A message sent at 04:49 was gone. The app drew a sent bubble and a typing
- L353 `Future<void> _drain()`  — Lets the adapter's internal handler chain settle.

## test/services/agents/agents_task_outbox_test.dart  (301 Z.)
- L12 `void main()`  — Bead cowork-i7sd: "ob die Nachrichten im Backend ankommen, ist irgendwie

## test/services/agents/agents_tool_phase_l10n_test.dart  (71 Z.)
- L13 `void main()`  — The running tool and the automation states speak the reader's language

## test/services/agents/agents_turn_phase_test.dart  (155 Z.)
- L11 `void main()`  — The live phase of an Agents turn (research item 4): every phase is read

## test/services/agents/browser_presence_test.dart  (425 Z.)
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

## test/services/agents/roster_pins_test.dart  (182 Z.)
- L10 `AgentsAgent _agent(String id, {DateTime? lastActivity})`
- L17 `void main()`

## test/services/agents/schedule_spec_test.dart  (431 Z.)
- L7 `void main()`  — 2026-02-03 is a Tuesday. Every date in this file is built from local

## test/services/agents/tool_card_parity_test.dart  (334 Z.)
- L34 `Map<String, dynamic> _visible(Map<String, dynamic> call)`  — The fields of a card the reader can see: everything the renderer reads
- L44 `_t0 = DateTime.fromMillisecondsSinceEpoch(1_757_040_000_000)`  — The host's clock, as a current host sends it: unix seconds.
- L45 `DateTime _at(int seconds)`
- L48 `_liveRun = <AgentsRelayInbound>[ const AgentsRelayDelta('Let me look.'), AgentsRelayTool( 'run_command', arguments: 'ls `  — One run: a command that worked, one that failed, a child agent.
- L95 `_replayedRun = <AgentsRelayInbound>[ const AgentsRelayUser('do the thing', mid: 1), const AgentsRelayDelta('Let me look.`  — The same run as the host replays it: every frame marked, in row order,
- L147 `void main()`
- L329 `Future<void> _drain()`

## test/services/agents/tool_events_contract_test.dart  (178 Z.)
- L11 `void main()`
