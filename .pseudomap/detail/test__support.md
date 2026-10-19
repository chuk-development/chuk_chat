# test/support · Signaturen

## test/support/agent_mail_fake.dart  (639 Z.)
- L21 `kFakeMailBase = 'https://api.test'`
- L22 `kFakeMailToken = 'jwt-test'`
- L23 `kFakeMailUser = 'user-test'`
- L26 `kFakeMailPrivateKey = List<int>.generate(32, (int i) => i + 1)`  — The raw private key of the fake mailbox's mail key.
- L31 `class FakeChukSecretBox implements AgentMailSecretBox`  — A stand-in for `EncryptionService`: reversible, marked, and lockable. It
  - L32 `static const String prefix = 'chuk-sealed:'`
  - L35 `bool locked = false`  — When true, every call fails the way a locked chuk key does.
  - L36 `int seals = 0`
  - L37 `int opens = 0`
  - L39 `static String sealSync(String plaintext)`
  - L43 `Future<String> seal(String plaintext)`
  - L52 `Future<String> open(String sealed)`
- L68 `Map<String, dynamic> fakeMail({ required String id, String direction = 'inbound', String from = 'ada@example.com', String? fromName = 'Ada Lovelace', List<String> to = const <String>['k7f3q9x2mh@chukagents.com'], String subject = 'Quarterly numbers', String? snippet = 'Here are the numbers you asked for last week.', String trust = 'trusted', String folder = 'inbox', bool read = false, bool bulk = false, bool attachments = false, String? status, String? importance, String? note, String createdAt = '2026-09-30T09:15:00Z', String text = 'Hello,\n\nhere are the numbers.\n\nAda', List<Map<String, dynamic>> files = const <Map<String, dynamic>>[], List<String> cc = const <String>[], String? inReplyTo, String? references, bool? dkimAligned = true, String? dkimDomain = 'example.com', bool broken = false, })`  — A mail as the fixtures keep it: plain text. The server seals it on the
- L128 `MailSummary fakeSummary(Map<String, dynamic> m)`  — The opened summary of a fixture, as the service would hand it out. For a
- L164 `List<Map<String, dynamic>> fakeMailbox()`  — A few mails over every folder, long enough to test a narrow window.
- L257 `class FakeAgentMailServer`
  - L258 `FakeAgentMailServer({ List<Map<String, dynamic>>? mails, List<Map<String, dynamic>>? contacts, this.mailboxStatus = 200, this.mailboxDetail, this.frozen = false, this.sendSuspended = false, bool hasKey = true, FakeChukSecretBox? secretBox, }) : mails = mails ?? fakeMailbox(), secretBox = secretBox ?? FakeChukSecretBox(), contacts = contacts ?? <Map<String, dynamic>>[ <String, dynamic>{ 'id': 'c1', 'address': 'ada@example.com', 'trusted_inbound': true, 'allowed_outbound': true, 'blocked': false, 'created_at': '2026-09-01T10:00:00Z', }, <String, dynamic>{ 'id': 'c2', 'address': '@very-long-company-domain-name.example', 'trusted_inbound': true, 'allowed_outbound': false, 'blocked': false, 'created_at': '2026-09-02T10:00:00Z', }, <String, dynamic>{ 'id': 'c3', 'address': 'spam@junk.example', 'trusted_inbound': false, 'allowed_outbound': false, 'blocked': true, 'created_at': '2026-09-03T10:00:00Z', }, ]`
  - L307 `final List<Map<String, dynamic>> mails`
  - L308 `final List<Map<String, dynamic>> contacts`
  - L311 `final FakeChukSecretBox secretBox`  — The chuk key stand-in the services of this server use.
  - L314 `Map<String, String>? keyRow`  — `{public_key, private_key_sealed}`, or null: no mail key yet.
  - L317 `int mailboxStatus`  — 200, or the error status `GET /mailbox` answers with.
  - L318 `String? mailboxDetail`
  - L319 `bool frozen`
  - L320 `bool sendSuspended`
  - L323 `String? userId = kFakeMailUser`  — The signed-in user the services report.
  - L327 `int? pageSize`  — When set, the list answers this many rows per page and a
  - L330 `Future<void>? holdOlderPages`  — When set, a request for an older page waits for it.
  - L333 `http.Response? sendResponse`  — When set, `POST /drafts/{id}/send` answers with this.
  - L336 `final Map<String, http.Response> failures = <String, http.Response>{}`  — When set, every call to a path containing the key answers with it.
  - L339 `final Map<String, List<int>> blobs = <String, List<int>>{}`  — The plain bytes of an attachment, by id. Unset: `bytes of <id>`.
  - L341 `final List<http.Request> requests = <http.Request>[]`
  - L343 `int _nextContact = 100`
  - L346 `List<String> get calls`  — The requests, as `METHOD path?query`.
  - L352 `List<Map<String, dynamic>> bodiesOf(String method, String path)`
  - L359 `AgentMailService service()`
  - L367 `Map<String, dynamic>? fixture(String id)`
  - L375 `MailSummary summaryOf(String id)`  — The opened summary of mail [id], as a page gets it from the list.
  - L377 `static http.Response _json(Object body, [int status = 200])`
  - L385 `static http.Response errorResponse(int status, String detail)`
  - L389 `Future<List<int>> _publicKey()`  — The public key the server seals to.
  - L401 `Future<String> _seal(Map<String, dynamic> doc, {bool broken = false})`  — A sealed field as the server sends it: the text envelope as a string.
  - L409 `Future<Map<String, dynamic>> _summaryRow(Map<String, dynamic> m)`  — A fixture as the list sends it: plain columns and the sealed parts.
  - L441 `Future<Map<String, dynamic>> _messageRow(Map<String, dynamic> m)`
  - L457 `Future<http.Response> handle(http.Request request)`

## test/support/fake_relay_controller.dart  (279 Z.)
- L12 `class FakeRelayController implements AgentsRelayController`  — A controller the test drives directly: set [set], push [emit] — no socket
  - L13 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L17 `final StreamController<AgentsRelayInbound> _inbound = StreamController<AgentsRelayInbound>.broadcast(sync: true)`
  - L20 `int connectCalls = 0`
  - L23 `final List<(Uri, String)> connects = <(Uri, String)>[]`  — Every `connect` call, as `(hostUrl, pairingCode)`, in order.
  - L27 `AgentsStoredPairing? trustOnConnect`  — The trust [establishedTrust] reports once [connect] has run. Null (the
  - L30 `Object? connectError`  — When set, [connect] throws it — a ceremony that failed.
  - L31 `final List<(String, int, int)> replayPages = <(String, int, int)>[]`
  - L32 `int reconnectCalls = 0`
  - L33 `bool provisioned = false`
  - L38 `bool reconnectFails = false`  — When true, [reconnect] reports a failure instead of pairing — the host
  - L40 `final List<String> tasks = <String>[]`
  - L41 `final List<String> taskSessionKeys = <String>[]`
  - L42 `final List<String?> taskModelIds = <String?>[]`
  - L43 `final List<String?> taskProviderSlugs = <String?>[]`
  - L44 `final List<String?> taskReasoning = <String?>[]`
  - L45 `final List<bool> taskDebugFlags = <bool>[]`
  - L49 `final List<bool> taskRegenerateFlags = <bool>[]`  — The `regenerate` flag of each task, in order. A Retry sets it; every other
  - L52 `final List<bool> taskBudgetOverrides = <bool>[]`  — The `budgetOverride` flag of each task, in order.
  - L55 `final List<String?> taskIds = <String?>[]`  — The `task_id` of every send, in order. Null for a caller that sent none.
  - L57 `int stopCalls = 0`
  - L58 `final List<String> stopSessionKeys = <String>[]`
  - L61 `final List<String> ackedRunIds = <String>[]`  — Run ids acknowledged after a live `done`.
  - L64 `final List<(String, int)> replayRequests = <(String, int)>[]`  — Every `replay` frame, as `(sessionKey, afterId)`.
  - L67 `final List<(String, bool)> approvalDecisions = <(String, bool)>[]`  — Every here.now publish decision, as `(approvalId, approved)`.
  - L70 `final List<String?> approvalScopes = <String?>[]`  — The `scope` of each decision, in order (null when none was sent).
  - L73 `final List<(Map<String, String>, int, String?)> secretsSent = <(Map<String, String>, int, String?)>[]`  — Every `secrets` frame, as `(values, revision, requestId)`.
  - L77 `Object? stopError`  — When set, [requestStop] throws it — the "the stop never left" path.
  - L80 `Object? taskError`  — When set, [sendTask] throws it.
  - L83 `ValueListenable<AgentsRelayState> get state`
  - L86 `Stream<AgentsRelayInbound> get inbound`
  - L89 `Future<void> connect({ required Uri hostUrl, required String pairingCode, })`
  - L105 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
  - L125 `AgentsStoredPairing? get establishedTrust`
  - L129 `Future<void> provisionAccount(AccountSession session)`
  - L137 `Object? provisionError`  — When set, [provisionAccount] throws it — a host that went away right
  - L140 `Future<void> createRoom( String roomId, String name, List<Map<String, String>> members, { bool agentToAgent = true, })`
  - L148 `Future<void> setRoomAgentToAgent(String roomId, bool enabled)`
  - L151 `Future<void> sendRoomTask(String roomId, String message)`
  - L154 `Future<void> requestRoomHistory(String roomId)`
  - L157 `Future<void> deleteRoom(String roomId)`
  - L160 `Future<void> renameRoom(String roomId, String name)`
  - L163 `Future<void> createAgent( String agentId, String name, { Map<String, Object?>? template, })`
  - L170 `Future<void> renameAgent(String agentId, String name)`
  - L173 `Future<void> requestAgentList()`
  - L176 `Future<void> addRoomMember( String roomId, String agentId, String handle, )`
  - L183 `Future<void> removeRoomMember(String roomId, String agentId)`
  - L186 `Future<void> sendTask( String prompt, { String sessionKey = 'default', String? modelId, String? providerSlug, String? reasoningEffort, bool debug = false, bool regenerate = false, String? taskId, bool budgetOverride = false, })`
  - L211 `Future<void> requestStop({String sessionKey = 'default'})`
  - L219 `Future<void> requestReplay({ String sessionKey = 'default', int afterId = 0, int beforeId = 0, int limit = 0, })`
  - L231 `List<String> get replaySessionKeys`  — The session keys the view asked to replay, in order.
  - L235 `Future<void> sendRunAck(String runId)`
  - L240 `Future<void> startBrowserView({String? sessionKey})`
  - L243 `Future<void> stopBrowserView()`
  - L246 `Future<void> sendBrowserData(Uint8List bytes)`
  - L249 `Future<void> sendApprovalDecision({ required String approvalId, required bool approved, String? scope, })`
  - L259 `Future<void> sendSecrets({ required Map<String, String> values, required int revision, String? requestId, })`
  - L268 `Future<void> dispose()`
  - L273 `void set(AgentsRelayState next)`
  - L275 `void emit(AgentsRelayInbound event)`

## test/support/icon_finder.dart  (34 Z.)
- L12 `Finder findIcon(IconData icon)`  — Finds an icon whether it draws as Material or as the app's own set.
- L22 `Color? iconColor(WidgetTester tester, Finder finder)`  — The colour the icon at [finder] is drawn in, whichever widget drew it.
- L32 `Finder findWidgetWithIcon<T extends Widget>(IconData icon)`  — A widget of type [T] that contains [icon], whichever widget drew it.

## test/support/kv_cache_test_env.dart  (59 Z.)
- L19 `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - L21 `_FakePathProvider(this.dir)`
  - L23 `final String dir`
  - L26 `Future<String?> getApplicationSupportPath()`
  - L29 `Future<String?> getApplicationDocumentsPath()`
  - L32 `Future<String?> getTemporaryPath()`
- L36 `void initSqfliteFfi()`  — Initialise the sqflite FFI backend once. Safe to call repeatedly.
- L44 `Future<Directory> useTempKvCache()`  — Point LocalChatCacheService's SQLite DB at a fresh temp dir and drop any
- L53 `Future<void> disposeTempKvCache(Directory tempDir)`  — Drop the cached DB handle and remove [tempDir]. Call from tearDown.

## test/support/mcp_memory_list.dart  (15 Z.)
- L8 `McpListBackend memoryMcpList([Map<String, String>? backing])`

## test/support/shell_config.dart  (90 Z.)
- L15 `AppShellConfig testShellConfig({ void Function(String field, Object? value)? onSet, Brightness themeMode = Brightness.dark, bool showReasoningTokens = false, bool showModelInfo = false, bool showTps = false, String uiLocale = 'en', })`  — An [AppShellConfig] for widget tests.

## test/support/test_app.dart  (29 Z.)
- reicht weiter: 'package:chuk_chat/l10n/app_localizations.dart' show AppLocalizations
- L14 `kTestLocalizationsDelegates = <LocalizationsDelegate<Object>>[ AppLocalizations.delegate, GlobalMaterialLocalizations.de`  — The localisation delegates the app installs in `main.dart`.
- L23 `MaterialApp testApp(Widget home, {Key? key})`  — A `MaterialApp` shaped like the real one: localised, with [home] as its body.
