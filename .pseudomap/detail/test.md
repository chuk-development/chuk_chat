# test · Signaturen

## test/chat_cache_no_eager_full_read_test.dart  (80 Z.)
- L17 `File _lib(String relative)`
- L19 `Iterable<File> _dartFilesIn(String directory)`
- L29 `void main()`

## test/fastlane_metadata_test.dart  (170 Z.)
- L10 `_metadataRoot = 'fastlane/metadata/android'`
- L13 `_titleLimit = 30`  — Play's own limits for a store listing.
- L14 `_shortDescriptionLimit = 80`
- L15 `_fullDescriptionLimit = 4000`
- L16 `_changelogLimit = 500`
- L19 `_minScreenshotSide = 320`  — Play rejects a screenshot with any side below 320 px or above 3840 px.
- L20 `_maxScreenshotSide = 3840`
- L22 `List<Directory> _locales()`
- L30 `_pngSignature = <int>[ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ]`  — The first eight bytes of every PNG.
- L38 `({int width, int height}) _pngSize(File file)`  — Width and height out of a PNG's IHDR chunk, which always starts at byte 16.
- L54 `void main()`

## test/flutter_test_config.dart  (15 Z.)
- L11 `Future<void> testExecutable(FutureOr<void> Function() testMain)`  — Runs before every test file.

## test/interop_smoke_test.dart  (191 Z.)
- L34 `class _PlainSocket implements RelaySocket`  — A plain web_socket_channel-backed [RelaySocket] — bypasses the cert-pinned
  - L35 `_PlainSocket(this._ch)`
  - L36 `final WebSocketChannel _ch`
  - L38 `Stream get incoming`
  - L40 `void send(String data)`
  - L42 `Future<void> close()`
- L45 `Future<RelaySocket> _plainConnector(Uri url)`
- L51 `_session = AccountSession( accessToken: 'mock', refreshToken: 'mock', userId: 'mock', )`
- L58 `Future<List<AgentsRelayTool>> _runTask( AgentsRelayClient client, String prompt, )`  — Drives one run to completion and returns the tool events it saw.
- L83 `void main()`

## test/local_chat_cache_compression_test.dart  (271 Z.)
- L16 `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - L18 `_FakePathProvider(this.dir)`
  - L20 `final String dir`
  - L23 `Future<String?> getApplicationSupportPath()`
  - L26 `Future<String?> getApplicationDocumentsPath()`
  - L29 `Future<String?> getTemporaryPath()`
- L34 `String _buildPayload({int messages = 6, int resultChars = 20000})`  — A chat payload of roughly [messages] messages carrying a fat tool
- L50 `void main()`

## test/stream_error_notice_test.dart  (74 Z.)
- L6 `void main()`

## test/supabase_session_refresh_test.dart  (58 Z.)
- L6 `Session _sessionExpiringIn(Duration remaining)`
- L28 `void main()`

## test/token_activity_stats_test.dart  (424 Z.)
- L8 `UsageLogEntry _entry(DateTime? createdAt, {int tokens = 10})`  — Minimal usage entry for the stats math: only [createdAt] and the token
- L22 `DateTime _d(int year, int month, int day)`  — A local-date midnight, so tests never depend on the machine timezone.
- L24 `void main()`

## test/tray_action_bus_test.dart  (30 Z.)
- L5 `void main()`

## test/verify_languages.dart  (19 Z.)
- L4 `void main()`

## test/widget_test.dart  (318 Z.)
- L27 `class _FailingAuthService extends AuthService`  — Auth service that always fails, so the login test can exercise the error
  - L28 `const _FailingAuthService()`
  - L31 `Future<void> signInWithPassword({ required String email, required String password, })`
- L40 `class _FakeSessionSource implements AccountSessionSource`  — Session source returning fixed tokens, so tests never touch Supabase.
  - L41 `const _FakeSessionSource()`
  - L44 `AccountSession? current()`
  - L51 `Future<AccountSession?> refresh()`
- L60 `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the shell's store never touches a platform
  - L61 `final Map<String, String> map = <String, String>{}`
  - L64 `Future<String?> read(String key)`
  - L67 `Future<void> write(String key, String value)`
  - L70 `Future<void> delete(String key)`
- L74 `class _IdleRelayController implements AgentsRelayController`  — Minimal relay controller so the shell can be pumped without a socket.
  - L75 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L79 `final StreamController<AgentsRelayInbound> _inbound = StreamController<AgentsRelayInbound>.broadcast()`
  - L83 `ValueListenable<AgentsRelayState> get state`
  - L86 `Stream<AgentsRelayInbound> get inbound`
  - L89 `Future<void> connect({ required Uri hostUrl, required String pairingCode, })`
  - L95 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
  - L101 `AgentsStoredPairing? get establishedTrust`
  - L104 `Future<void> provisionAccount(AccountSession session)`
  - L107 `Future<void> sendTask( String prompt, { String sessionKey = 'default', String? modelId, String? providerSlug, String? reasoningEffort, bool debug = false, bool regenerate = false, String? taskId, })`
  - L119 `Future<void> createRoom( String roomId, String name, List<Map<String, String>> members, { bool agentToAgent = true, })`
  - L127 `Future<void> setRoomAgentToAgent(String roomId, bool enabled)`
  - L130 `Future<void> sendRoomTask(String roomId, String message)`
  - L133 `Future<void> requestRoomHistory(String roomId)`
  - L136 `Future<void> deleteRoom(String roomId)`
  - L139 `Future<void> renameRoom(String roomId, String name)`
  - L142 `Future<void> createAgent(String agentId, String name)`
  - L145 `Future<void> renameAgent(String agentId, String name)`
  - L148 `Future<void> requestAgentList()`
  - L151 `Future<void> addRoomMember(String roomId, String agentId, String handle)`
  - L154 `Future<void> removeRoomMember(String roomId, String agentId)`
  - L157 `Future<void> requestStop({String sessionKey = 'default'})`
  - L160 `Future<void> requestReplay({ String sessionKey = 'default', int afterId = 0, int beforeId = 0, int limit = 0, })`
  - L168 `Future<void> sendRunAck(String runId)`
  - L171 `Future<void> startBrowserView({String? sessionKey})`
  - L174 `Future<void> stopBrowserView()`
  - L177 `Future<void> sendBrowserData(Uint8List bytes)`
  - L180 `Future<void> sendApprovalDecision({ required String approvalId, required bool approved, })`
  - L186 `Future<void> sendSecrets({ required Map<String, String> values, required int revision, String? requestId, })`
  - L193 `Future<void> dispose()`
- L199 `void main()`
