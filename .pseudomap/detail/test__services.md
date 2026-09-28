# test/services · Signaturen

## test/services/account_session_test.dart  (226 Z.)
- L9 `String _jwt({required int exp, String sub = 'user-1'})`  — A JWT whose only claim that matters is `exp` (gotrue reads it unverified).
- L16 `Session _session({required int exp, String refresh = 'r1'})`
- L31 `void main()`

## test/services/api_config_base_test.dart  (26 Z.)
- L10 `void main()`  — The model catalogue (`/v1/models_info`) is fetched from this base URL by

## test/services/app_theme_contrast_uifont_test.dart  (94 Z.)
- L12 `void main()`

## test/services/app_theme_service_dynamic_color_test.dart  (165 Z.)
- L10 `ColorScheme _schemeWithPrimary(Color primary, Brightness brightness)`
- L15 `void main()`

## test/services/artifact_diff_engine_test.dart  (102 Z.)
- L6 `void main()`

## test/services/artifact_repair_version_chain_test.dart  (33 Z.)
- L5 `void main()`

## test/services/artifact_rollback_test.dart  (560 Z.)
- L5 `void main()`

## test/services/artifact_storage_pending_flushers_test.dart  (112 Z.)
- L5 `void main()`

## test/services/auth_trace_test.dart  (43 Z.)
- L6 `void main()`

## test/services/bash_sandbox_folder_test.dart  (105 Z.)
- L8 `void main()`

## test/services/chat_history_builder_test.dart  (273 Z.)
- L8 `void main()`  — The outgoing payload is `{message: <current turn>, history: [...]}` and the

## test/services/chat_mode_config_test.dart  (413 Z.)
- L11 `void main()`

## test/services/chat_model_provider_resolution_test.dart  (70 Z.)
- L7 `class _Harness extends StatefulWidget`
  - L8 `const _Harness({super.key, required this.chat})`
  - L9 `final String chat`
  - L11 `State<_Harness> createState()`
- L14 `class _HarnessState extends State<_Harness> with ModelProviderResolutionMixin`
  - L16 `String get selectedModelId`
  - L18 `String? selectedProviderSlug`
  - L20 `String? get modelSelectionChatId`
  - L22 `Widget build(BuildContext context)`
- L25 `void main()`

## test/services/chat_model_selection_service_test.dart  (91 Z.)
- L5 `void main()`

## test/services/chat_payload_codec_test.dart  (244 Z.)
- L17 `Map<String, dynamic> _toolTurn({String result = 'RESULT ', int repeat = 400})`  — A tool turn the way the app stores it in v2: the same tool calls (with
- L94 `Map<String, dynamic> _v2Payload(List<Map<String, dynamic>> messages)`
- L100 `List<String> _inMemory(String payloadJson)`
- L105 `void main()`

## test/services/chat_payload_envelope_test.dart  (283 Z.)
- L24 `_oldPayloadVersion = '1'`
- L26 `Future<String> _oldDecryptString(String encrypted, List<int> keyBytes)`
- L46 `Future<List<String?>> _oldDecryptBatch( List<String> encryptedList, List<int> keyBytes, )`
- L82 `_oldCacheCodec = GZipCodec(level: 4)`
- L84 `String _oldDecodeCachePayload(Object? stored)`
- L94 `List<int> _key()`
- L100 `Future<String> _sealV1(String text, List<int> keyBytes)`  — A v1 envelope as every app writes it for titles and old chats.
- L116 `String _chatJson({int rounds = 30})`
- L140 `void main()`

## test/services/chat_payload_migration_test.dart  (591 Z.)
- L26 `userId = 'user-1'`
- L28 `String _id(int i)`
- L30 `String _updatedAt(int i)`
- L32 `String _v2Json(int i)`
- L53 `Future<String> _sealV1(String text, List<int> key)`
- L71 `class _FakeCloud implements ChatMigrationCloud`  — An in-memory `encrypted_chats` with the prod trigger's rule: a written
  - L72 `_FakeCloud(this.key)`
  - L74 `final List<int> key`
  - L75 `final Map<String, ({String encrypted, String updatedAt})> rows = {}`
  - L76 `final List<String> writes = []`
  - L77 `bool offline = false`
  - L78 `bool keyAvailable = true`
  - L81 `Completer<void>? listGate`  — Holds the cloud list until completed (a slow network).
  - L84 `String? changeBeforeWrite`  — Simulates another device saving a chat between read and write.
  - L87 `Future<List<String>> listPlainEnvelopeChats(String userId)`
  - L97 `Future<({String encrypted, String updatedAt})?> readRow( String userId, String chatId, )`
  - L103 `Future<String?> writeRow( String userId, String chatId, { required String encrypted, required String updatedAt, required String expectedUpdatedAt, })`
  - L128 `Future<ChatEnvelopeV3?> convert(String encrypted)`
  - L135 `Future<String> fingerprint(String encrypted)`
  - L139 `int get currentKeyVersion`
  - L142 `Future<bool> ensureKey()`
- L145 `void main()`

## test/services/chat_reaction_service_test.dart  (76 Z.)
- L5 `void main()`

## test/services/chat_runtime_test.dart  (182 Z.)
- L5 `void main()`

## test/services/chat_storage_local_first_test.dart  (297 Z.)
- L26 `chatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b'`
- L27 `userId = 'user-1'`
- L29 `List<Map<String, String>> turn(String answer)`
- L34 `void main()`

## test/services/chat_storage_pending_save_test.dart  (110 Z.)
- L16 `void main()`

## test/services/chat_storage_title_sync_test.dart  (56 Z.)
- L12 `void main()`

## test/services/encryption_service_test.dart  (702 Z.)
- L15 `void main()`  — Tests for the core AES-GCM encryption logic used by EncryptionService.
- L690 `int? _extractKeyVersion(String encrypted)`  — Mirror of EncryptionService.extractKeyVersion for testing

## test/services/file_conversion_page_images_test.dart  (103 Z.)
- L8 `void main()`  — A scanned PDF has no text layer, so the API returns its pages as image

## test/services/flag_off_auth_parity_test.dart  (55 Z.)
- L17 `void main()`

## test/services/image_compression_service_test.dart  (228 Z.)
- L6 `void main()`

## test/services/legacy_prefs_blob_migration_test.dart  (277 Z.)
- L28 `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - L29 `final Map<String, String> map = <String, String>{}`
  - L32 `Future<String?> read(String key)`
  - L35 `Future<void> write(String key, String value)`
  - L38 `Future<void> delete(String key)`
- L42 `class _FakeKv`  — An in-memory kv_cache that counts writes and can be told to fail them.
  - L43 `final Map<String, String> map = <String, String>{}`
  - L44 `bool failWrites = false`
  - L45 `int writes = 0`
  - L47 `McpListBackend get backend`
- L57 `String _connectionsJson(List<String> names)`
- L78 `void main()`

## test/services/mcp_reachability_test.dart  (24 Z.)
- L5 `void main()`

## test/services/mcp_tools_frame_test.dart  (148 Z.)
- L10 `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - L11 `final Map<String, String> map = <String, String>{}`
  - L14 `Future<String?> read(String key)`
  - L17 `Future<void> write(String key, String value)`
  - L20 `Future<void> delete(String key)`
- L23 `void main()`

## test/services/media_index_test.dart  (111 Z.)
- L6 `void main()`

## test/services/message_composition_service_test.dart  (69 Z.)
- L4 `void main()`

## test/services/model_cache_memo_test.dart  (51 Z.)
- L14 `void main()`

## test/services/multiplex_auth_refresh_test.dart  (569 Z.)
- L33 `class _FakeMultiplexServer`  — Minimal stand-in for the `/v2/ws` endpoint.
  - L34 `_FakeMultiplexServer._(this._server)`
  - L36 `final HttpServer _server`
  - L37 `WebSocket? _socket`
  - L40 `final List<String> refreshTokens = <String>[]`  — Tokens received in `auth_refresh` frames, in arrival order.
  - L43 `String? handshakeToken`  — Token received in the handshake `auth` frame.
  - L46 `void Function(WebSocket socket, String token) onAuthRefresh = (WebSocket socket, String token) { _send(socket, <String, dynamic>{ 'type': 'auth_refreshed', 'expires_at': 4102444800, }); }`  — How to answer an `auth_refresh`. Default: accept it.
  - L58 `static void _send(WebSocket socket, Map<String, dynamic> frame)`  — Write a frame, tolerating a socket the test has already torn down.
  - L66 `static Future<_FakeMultiplexServer> start()`
  - L73 `String get baseUrl`
  - L75 `Future<void> _accept()`
  - L96 `void _onFrame(WebSocket socket, dynamic raw)`
  - L125 `void push(Map<String, dynamic> frame)`  — Push an unsolicited server frame, e.g. `auth_refresh_needed`.
  - L131 `void acceptPendingRefresh()`  — Answer a handover that [onAuthRefresh] deliberately left unanswered.
  - L136 `Future<void> stop()`
- L145 `Future<void> _settle([int ms = 120])`  — Let queued microtasks and socket I/O settle.
- L148 `void main()`

## test/services/network_status_service_test.dart  (124 Z.)
- L4 `void main()`

## test/services/oauth_loopback_server_test.dart  (118 Z.)
- L7 `_theme = OAuthResultPageTheme( successColor: '#28a745', errorColor: '#dc3545', background: '#0d1117', card: '#161b22', b`
- L18 `OAuthLoopbackServer _server(int port)`  — Ports in the dynamic range, one per test, so a lingering socket from one
- L25 `typedef _Response = ({int status, String body})`  — Status code and body of one callback request.
- L27 `Future<_Response> _get(Uri uri)`
- L41 `void main()`

## test/services/offline_queue_service_test.dart  (140 Z.)
- L11 `void main()`

## test/services/offline_retry_manager_test.dart  (145 Z.)
- L14 `void main()`

## test/services/onboarding_tour_controller_test.dart  (44 Z.)
- L17 `void main()`

## test/services/per_model_system_prompt_merge_test.dart  (175 Z.)
- L5 `void main()`

## test/services/prefs_to_kv_migration_test.dart  (58 Z.)
- L21 `void main()`

## test/services/reasoning_supported_efforts_test.dart  (198 Z.)
- L19 `Future<void> _seedCatalog(List<Map<String, dynamic>> models)`  — Seed the on-disk catalog cache with [models] and hydrate the capability
- L25 `void main()`

## test/services/round_content_block_service_test.dart  (519 Z.)
- L8 `void main()`

## test/services/session_recovery_test.dart  (464 Z.)
- L17 `String _jwt({required int exp, String sub = 'user-1'})`
- L24 `Session _session({required int exp, required String refresh})`
- L40 `class _FakeLink implements RecoveryLink`  — A host on the other end of the recovery link, scripted per test.
  - L41 `AccountSessionSource? source`
  - L42 `Future<AccountSession?> Function(String refreshToken)? adopter`
  - L43 `bool attachFails = false`
  - L44 `bool disposed = false`
  - L45 `final List<AccountSession> provisioned = []`
  - L46 `Future<void> Function(_FakeLink link)? onProvision`
  - L49 `Future<void> attach({ required AccountSessionSource sessionSource, required Future<AccountSession?> Function(String refreshToken) adopter, })`
  - L59 `Future<void> provision(AccountSession session)`
  - L65 `Future<void> dispose()`
- L70 `void main()`

## test/services/session_refresh_scheduler_test.dart  (137 Z.)
- L8 `class _Source implements AccountSessionSource`
  - L9 `_Source(this._current)`
  - L11 `AccountSession? _current`
  - L12 `int refreshCalls = 0`
  - L13 `Completer<void>? gate`
  - L15 `void adopt(AccountSession next)`
  - L18 `AccountSession? current()`
  - L21 `Future<AccountSession?> refresh()`
- L37 `void main()`

## test/services/streaming_final_content_test.dart  (55 Z.)
- L7 `void main()`

## test/services/streaming_idle_timeout_test.dart  (112 Z.)
- L16 `void main()`

## test/services/streaming_manager_test.dart  (585 Z.)
- L12 `void main()`
- L568 `class _TestStreamContext`  — Helper class to hold test stream state
  - L569 `final StreamController<ChatStreamEvent> controller`
  - L570 `final String Function() getContent`
  - L571 `final String Function() getReasoning`
  - L572 `final double? Function() getTps`
  - L573 `final bool Function() isCompleted`
  - L574 `final String? Function() getError`
  - L576 `_TestStreamContext({ required this.controller, required this.getContent, required this.getReasoning, required this.getTps, required this.isCompleted, required this.getError, })`

## test/services/streaming_silence_test.dart  (203 Z.)
- L28 `class _Rig`  — One run under test: the input the host would write to, and everything the
  - L29 `_Rig(this.chatId)`
  - L31 `final String chatId`
  - L32 `final StreamController<ChatStreamEvent> input = StreamController<ChatStreamEvent>()`
  - L34 `final StreamingManager manager = StreamingManager()`
  - L35 `final List<String> updates = <String>[]`
  - L36 `final List<String> completions = <String>[]`
  - L37 `final List<String> errors = <String>[]`
  - L38 `final List<String?> errorCodes = <String?>[]`
  - L40 `Future<void> start()`
  - L58 `Future<void> dispose(WidgetTester tester)`  — Winds the run down inside the test's fake time.
- L65 `void main()`

## test/services/theme_settings_sync_fields_test.dart  (122 Z.)
- L12 `void main()`

## test/services/thread_preview_store_test.dart  (97 Z.)
- L6 `void main()`

## test/services/tool_call_handler_deferred_action_test.dart  (281 Z.)
- L6 `void main()`

## test/services/tool_call_handler_fact_check_test.dart  (193 Z.)
- L6 `void main()`

## test/services/tool_call_handler_repeated_lookup_test.dart  (393 Z.)
- L22 `void main()`

## test/services/tool_call_handler_safety_limit_test.dart  (145 Z.)
- L6 `void main()`

## test/services/tool_call_handler_stub_test.dart  (204 Z.)
- L13 `void main()`

## test/services/tool_call_reasoning_lift_test.dart  (65 Z.)
- L5 `void main()`

## test/services/tool_enforcer_test.dart  (137 Z.)
- L5 `Map<String, dynamic> _def(String name)`
- L11 `Map<String, dynamic> _call(String name, [Map<String, dynamic>? args])`
- L16 `void main()`

## test/services/tool_failure_detection_test.dart  (129 Z.)
- L9 `void main()`  — A tool result's failure flag drives the icon the user sees AND whether the

## test/services/tool_image_result_service_test.dart  (178 Z.)
- L8 `void main()`

## test/services/tool_prompt_builder_test.dart  (439 Z.)
- L8 `_skillToolDef = { 'name': 'skill', 'description': 'Load a skill.', 'parameters': <String, dynamic>{'name': 'string'}, }`
- L14 `_tools = [ { 'name': 'find_tools', 'description': 'Discovery', 'parameters': <String, dynamic>{}, }, { 'name': 'web_sear`
- L37 `_testSkill = Skill( name: 'weather-cards', description: 'Renders weather. Use when the user asks about weather.', body: `
- L44 `void main()`

## test/services/tool_result_cache_registry_test.dart  (124 Z.)
- L4 `void main()`

## test/services/tool_turn_signals_test.dart  (47 Z.)
- L4 `void main()`

## test/services/tour_key_registry_test.dart  (62 Z.)
- L7 `void main()`

## test/services/user_scoped_cache_invalidation_test.dart  (301 Z.)
- L16 `void main()`  — Guards the cross-user leak fix: the static caches in these services are

## test/services/user_scoped_cache_race_test.dart  (309 Z.)
- L21 `void main()`  — The sign-out-mid-flight race: an operation starts as user A, A signs out and

## test/services/websocket_chat_service_test.dart  (730 Z.)
- L23 `List<AgentsRelayInbound> _everyVariant()`  — Every inbound variant the relay can produce, so the "never a ToolCallsEvent"
- L78 `void main()`
- L725 `Future<void> _drain()`  — Lets the adapter's internal handler chain settle.
