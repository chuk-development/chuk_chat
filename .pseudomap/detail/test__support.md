# test/support · Signaturen

## test/support/fake_relay_controller.dart  (245 Z.)
- L12 `class FakeRelayController implements AgentsRelayController`  — A controller the test drives directly: set [set], push [emit] — no socket
  - L13 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L17 `final StreamController<AgentsRelayInbound> _inbound = StreamController<AgentsRelayInbound>.broadcast(sync: true)`
  - L20 `int connectCalls = 0`
  - L21 `final List<(String, int, int)> replayPages = <(String, int, int)>[]`
  - L22 `int reconnectCalls = 0`
  - L23 `bool provisioned = false`
  - L28 `bool reconnectFails = false`  — When true, [reconnect] reports a failure instead of pairing — the host
  - L30 `final List<String> tasks = <String>[]`
  - L31 `final List<String> taskSessionKeys = <String>[]`
  - L32 `final List<String?> taskModelIds = <String?>[]`
  - L33 `final List<String?> taskProviderSlugs = <String?>[]`
  - L34 `final List<String?> taskReasoning = <String?>[]`
  - L35 `final List<bool> taskDebugFlags = <bool>[]`
  - L39 `final List<bool> taskRegenerateFlags = <bool>[]`  — The `regenerate` flag of each task, in order. A Retry sets it; every other
  - L42 `final List<String?> taskIds = <String?>[]`  — The `task_id` of every send, in order. Null for a caller that sent none.
  - L44 `int stopCalls = 0`
  - L45 `final List<String> stopSessionKeys = <String>[]`
  - L48 `final List<String> ackedRunIds = <String>[]`  — Run ids acknowledged after a live `done`.
  - L51 `final List<(String, int)> replayRequests = <(String, int)>[]`  — Every `replay` frame, as `(sessionKey, afterId)`.
  - L54 `final List<(String, bool)> approvalDecisions = <(String, bool)>[]`  — Every here.now publish decision, as `(approvalId, approved)`.
  - L57 `final List<(Map<String, String>, int, String?)> secretsSent = <(Map<String, String>, int, String?)>[]`  — Every `secrets` frame, as `(values, revision, requestId)`.
  - L61 `Object? stopError`  — When set, [requestStop] throws it — the "the stop never left" path.
  - L64 `Object? taskError`  — When set, [sendTask] throws it.
  - L67 `ValueListenable<AgentsRelayState> get state`
  - L70 `Stream<AgentsRelayInbound> get inbound`
  - L73 `Future<void> connect({ required Uri hostUrl, required String pairingCode, })`
  - L86 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
  - L106 `AgentsStoredPairing? get establishedTrust`
  - L109 `Future<void> provisionAccount(AccountSession session)`
  - L114 `Future<void> createRoom( String roomId, String name, List<Map<String, String>> members, { bool agentToAgent = true, })`
  - L122 `Future<void> setRoomAgentToAgent(String roomId, bool enabled)`
  - L125 `Future<void> sendRoomTask(String roomId, String message)`
  - L128 `Future<void> requestRoomHistory(String roomId)`
  - L131 `Future<void> deleteRoom(String roomId)`
  - L134 `Future<void> renameRoom(String roomId, String name)`
  - L137 `Future<void> createAgent(String agentId, String name)`
  - L140 `Future<void> renameAgent(String agentId, String name)`
  - L143 `Future<void> requestAgentList()`
  - L146 `Future<void> addRoomMember( String roomId, String agentId, String handle, )`
  - L153 `Future<void> removeRoomMember(String roomId, String agentId)`
  - L156 `Future<void> sendTask( String prompt, { String sessionKey = 'default', String? modelId, String? providerSlug, String? reasoningEffort, bool debug = false, bool regenerate = false, String? taskId, })`
  - L179 `Future<void> requestStop({String sessionKey = 'default'})`
  - L187 `Future<void> requestReplay({ String sessionKey = 'default', int afterId = 0, int beforeId = 0, int limit = 0, })`
  - L199 `List<String> get replaySessionKeys`  — The session keys the view asked to replay, in order.
  - L203 `Future<void> sendRunAck(String runId)`
  - L208 `Future<void> startBrowserView({String? sessionKey})`
  - L211 `Future<void> stopBrowserView()`
  - L214 `Future<void> sendBrowserData(Uint8List bytes)`
  - L217 `Future<void> sendApprovalDecision({ required String approvalId, required bool approved, })`
  - L225 `Future<void> sendSecrets({ required Map<String, String> values, required int revision, String? requestId, })`
  - L234 `Future<void> dispose()`
  - L239 `void set(AgentsRelayState next)`
  - L241 `void emit(AgentsRelayInbound event)`

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
