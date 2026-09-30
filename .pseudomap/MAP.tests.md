# pseudomap · chuk_chat · Tests

357 Dateien · 974 Typen/Funktionen · 955 Member · Stand 2026-09-30

Diese Datei ist `.pseudomap/MAP.md` — Stufe 1: was es gibt und wo es liegt.

Vor dem Schreiben neuer Funktionen hier nachsehen, ob die Sache schon existiert. Tut sie es, wird sie wiederverwendet statt neu geschrieben.

- Lange Parameterlisten sind hier gekürzt (`…)`). Volle Signaturen mit Zeilennummern stehen in `.pseudomap/detail/<ordner>.md`, Pfad mit `__` statt `/` — `lib/services` liegt in `.pseudomap/detail/lib__services.md`.
- Suche über alles: `pseudomap find <begriff>`.
- Neu bauen: `pseudomap build` (läuft nach jedem Edit automatisch).

## test
### chat_cache_no_eager_full_read_test.dart  (80 Z.)
- `File _lib(String relative)`
- `Iterable<File> _dartFilesIn(String directory)`
- `void main()`

### fastlane_metadata_test.dart  (170 Z.)
- const: _metadataRoot _titleLimit _shortDescriptionLimit _fullDescriptionLimit _changelogLimit _minScreenshotSide _maxScreenshotSide _pngSignature
- `List<Directory> _locales()`
- `({int width, int height}) _pngSize(File file)`  — Width and height out of a PNG's IHDR chunk, which always starts at byte 16.
- `void main()`

### flutter_test_config.dart  (15 Z.)
- `Future<void> testExecutable(FutureOr<void> Function() testMain)`  — Runs before every test file.

### interop_smoke_test.dart  (191 Z.)
- const: _session
- `class _PlainSocket implements RelaySocket`  — A plain web_socket_channel-backed [RelaySocket] — bypasses the cert-pinned
  - send close incoming
- `Future<RelaySocket> _plainConnector(Uri url)`
- `Future<List<AgentsRelayTool>> _runTask( AgentsRelayClient client, String prompt, )`  — Drives one run to completion and returns the tool events it saw.
- `void main()`

### local_chat_cache_compression_test.dart  (271 Z.)
- `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - getApplicationSupportPath getApplicationDocumentsPath getTemporaryPath dir
- `String _buildPayload({int messages = 6, int resultChars = 20000})`  — A chat payload of roughly [messages] messages carrying a fat tool
- `void main()`

### stream_error_notice_test.dart  (74 Z.)
- `void main()`

### supabase_session_refresh_test.dart  (58 Z.)
- `Session _sessionExpiringIn(Duration remaining)`
- `void main()`

### token_activity_stats_test.dart  (424 Z.)
- `UsageLogEntry _entry(DateTime? createdAt, {int tokens = 10})`  — Minimal usage entry for the stats math: only [createdAt] and the token
- `DateTime _d(int year, int month, int day)`  — A local-date midnight, so tests never depend on the machine timezone.
- `void main()`

### tray_action_bus_test.dart  (30 Z.)
- `void main()`

### verify_languages.dart  (19 Z.)
- `void main()`

### widget_test.dart  (318 Z.)
- `class _FailingAuthService extends AuthService`  — Auth service that always fails, so the login test can exercise the error
  - signInWithPassword
- `class _FakeSessionSource implements AccountSessionSource`  — Session source returning fixed tokens, so tests never touch Supabase.
  - current refresh
- `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the shell's store never touches a platform
  - read write delete map
- `class _IdleRelayController implements AgentsRelayController`  — Minimal relay controller so the shell can be pumped without a socket.
  - connect reconnect provisionAccount setRoomAgentToAgent sendRoomTask requestRoomHistory deleteRoom renameRoom createAgent renameAgent requestAgentList addRoomMember removeRoomMember sendRunAck startBrowserView stopBrowserView sendBrowserData sendApprovalDecision sendSecrets state inbound establishedTrust sessionKey agentToAgent
- `void main()`

## test/agents_permissions
### agent_permissions_section_test.dart  (329 Z.)
- `Widget _page(AgentsPermissionsService service, {String agentId = 'a'})`
- `Switch _switch(WidgetTester tester, String key)`
- `Future<(FakeHost, AgentsPermissionsService)> _open( WidgetTester tester, { bool connected = true, bool supported = true …)`
- `void main()`

### agents_error_routing_test.dart  (100 Z.)
- `Future<void> _drain()`
- `void main()`

### agents_permissions_service_test.dart  (219 Z.)
- `void main()`

### permissions_fakes.dart  (51 Z.)
- `class FakeHost`  — A stand-in for the host connection: what it sends, whether a host is
  - send service attach detach nameCapability connection capabilities sent fail
- `Map<String, dynamic> permissionsReply( String agentId, AgentPermissions? p, { String? error, Map<String, bool>? enforced …)`

## test/assistant
### assistant_microphone_test.dart  (153 Z.)
- const: _frame
- `Uint8List _chunk({required double amplitude, Duration length = _frame})`  — One chunk of PCM16 at the given amplitude (0..1), as a 400 Hz tone so the
- `void _feed( AssistantMicrophone mic, { required double amplitude, required Duration total, })`
- `void main()`

### assistant_overlay_test.dart  (297 Z.)
- const: _accent _bg
- `Widget _host(Widget child)`
- `void main()`

### assistant_tools_test.dart  (143 Z.)
- `void main()`

## test/chat
### worked_for_stamp_test.dart  (109 Z.)
- `Map<String, String> _assistant({String? startedAt, String? generationMs})`
- `void main()`

## test/helpers
### icon_finder.dart  (25 Z.)
- `Finder findIcon(IconData icon)`  — Finds an icon whichever widget draws it.
- `Finder findWidgetWithIcon(Type type, IconData icon)`  — [find.widgetWithIcon] for the same reason.

## test/layout
### chat_documents_phone_layout_test.dart  (194 Z.)
- const: _stamp _catalog
- `class _Relay implements AgentsRelayController, AgentsDocumentsControl`
  - requestDocuments requestAgentList send inbound state events
- `Map<String, dynamic> _file(String path, {int size = 4096})`
- `Map<String, dynamic> _table(String title)`
- `void main()`

### every_screen_layout_test.dart  (842 Z.)
- const: _cannotMount _chukSizes
- `class _Bag`  — Anything a screen made that has to be thrown away afterwards.
  - Function
- `FakeAgentControlSource _keepControl(_Bag bag, FakeAgentControlSource source)`
- `typedef ScreenBuilder = Widget Function(_Bag bag)`
- `class _Screen`
  - name after
- `AgentsAgent _agent({ String id = 'amber', String name = 'Amber Fitzgerald-Okonkwo', String? role = 'Research and long-fo …)`
- `List<AgentsAgent> _roster()`
- `AgentsRoomMember _member(String id, String handle)`
- `AgentsRoom _fullRoom()`  — A room at the cap, which is the case the member sheet has to survive.
- `Widget _hosted(Widget child)`  — Wraps a panel that has no scaffold of its own.
- `Widget _sheetHost(WidgetBuilder builder)`  — Presents [builder] the way `agents_shell_state` presents it: a scroll
- `Future<void> _openSheet(WidgetTester tester)`
- `List<_Screen> _screens()`
- `void main()`
- `class _InstallMemory implements AgentsSecureKeyValueStore`  — Secure storage for the install page, in memory.
  - read write delete
- `class _InstallSession implements AccountSessionSource`
  - current refresh

### layout_harness.dart  (431 Z.)
- const: kLayoutSizes kTextScales _kEdgeTolerance kMinFontSize
- `class LayoutSize`  — One window the app has to fit into.
  - name size
- `Future<void> pumpAt( WidgetTester tester, Widget child, { required Size size, required double textScale, Duration settle …)`  — Pumps [child] into a window of [size] with text scaled by [textScale].
- `Future<void> unpump(WidgetTester tester)`  — Unmounts the screen and drains what it started, INSIDE the test body.
- `Future<List<FlutterErrorDetails>> collectErrors( Future<void> Function() body, )`  — Collects every framework error raised while [body] runs.
- `String describeErrors(List<FlutterErrorDetails> errors)`
- `bool isOverflow(FlutterErrorDetails d)`
- `class Bleed`  — A box whose painted rect leaves the window sideways.
  - what rect
- `bool _scrollsHorizontally(Element element)`  — True when [element] scrolls sideways, so its content is MEANT to be wider
- `bool _paintsNothing(Element element)`  — True when nothing under [element] paints at all.
- `bool _paintsElsewhere(Element element)`  — True for a node whose OWN box is measured in its parent's coordinates
- `bool _mayOverhang(Element element)`  — True for a box that is told to let its child be bigger than itself. What
- `bool _clipsChildren(Element element)`  — True when [element] cuts its children off at its own edge, so nothing
- `List<Bleed> findHorizontalBleed(WidgetTester tester, Size screen)`  — Walks the tree under the root and returns every box that paints past the
- `bool isTarget(Widget w)`  — True for a widget that takes a tap and is therefore a touch target.
- `bool _ownsItsPadding(Widget w)`  — True for the widgets that build their own ink well INSIDE a 48 dp tap
- `class SmallTarget`  — A control that is too small to hit.
  - what size
- `List<SmallTarget> findSmallTargets(WidgetTester tester)`
- `class TinyText`
  - text fontSize
- `List<TinyText> findTinyText(WidgetTester tester)`  — Every run of text painted smaller than [kMinFontSize].

## test/manual
### chat_payload_v3_real_data_test.dart  (146 Z.)
- const: _dbPath
- `String _stats(List<int> sizes)`
- `Future<String> _sealV1(String text, List<int> key)`
- `List<String> _inMemory(DecodedChatPayload p)`
- `void main()`

### table_preview.dart  (207 Z.)
- `Map<String, dynamic> songs({int rows = 2, bool labelled = false})`  — The Songs document the coworker wrote: the reel it came from, the song,
- `Map<String, dynamic> prices()`  — A price comparison: a number column, a highlighted cell, and prose in the
- `void main()`
- `class TablePreviewApp extends StatefulWidget`
- `class _TablePreviewAppState extends State<TablePreviewApp>`

## test/mcp
### mcp_apikey_test.dart  (69 Z.)
- `void main()`

### mcp_awareness_test.dart  (169 Z.)
- `McpConnection _connection(String id)`
- `void main()`

### mcp_bundled_icons_test.dart  (121 Z.)
- const: _pngMagic
- `void main()`

### mcp_catalogue_test.dart  (305 Z.)
- `void main()`

### mcp_client_test.dart  (208 Z.)
- `http.Response _json(Object body, {Map<String, String> headers = const {}})`
- `void main()`

### mcp_connect_cancel_test.dart  (122 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure storage, so the connect path's "is there already a
  - read write delete map
- `void main()`

### mcp_endpoints_live_test.dart  (151 Z.)
- const: _live
- `class _Probe`  — What a live probe found out about one server.
  - open challenge
- `Future<_Probe> _probe(String url, http.Client client)`
- `void main()`

### mcp_first_party_test.dart  (131 Z.)
- `void main()`

### mcp_legal_links_live_test.dart  (102 Z.)
- const: _live _userAgent
- `Future<int> _statusOf(String url)`
- `void main()`

### mcp_oauth_test.dart  (341 Z.)
- const: _issuer
- `http.Response _json(Object body)`
- `MockClient _server({bool withRegistration = true})`
- `void main()`

## test/models
### agents_room_test.dart  (94 Z.)
- `AgentsRoomMember _m(String id, String handle)`
- `void main()`

### chat_message_test.dart  (305 Z.)
- `void main()`

### chat_message_timestamp_test.dart  (30 Z.)
- `void main()`

### chat_model_test.dart  (234 Z.)
- `void main()`

### chat_reply_test.dart  (28 Z.)
- `void main()`

### chat_stream_event_test.dart  (171 Z.)
- `void main()`

### content_block_test.dart  (222 Z.)
- `void main()`

### stored_chat_test.dart  (314 Z.)
- `void main()`

### workspace_model_test.dart  (535 Z.)
- `void main()`

## test/pages
### agent_profile_edit_page_test.dart  (115 Z.)
- `void main()`

### agent_profile_page_test.dart  (50 Z.)
- `void main()`

### agents_install_page_test.dart  (281 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _Session implements AccountSessionSource`
  - current refresh
- `void main()`

### agents_pairing_page_test.dart  (229 Z.)
- `class _FakeCamera`  — A stand-in camera. It renders a marker instead of a preview and exposes the
  - onCode onUnavailable builds
- `void main()`

### automations_page_test.dart  (230 Z.)
- `AgentsAutomation _automation( String id, { String session = 'thread-1', String state = 'active', })`
- `void main()`

### desktop_settings_modal_test.dart  (180 Z.)
- `void main()`  — The desktop settings modal lists the same destinations as the phone's

### mcp_connectors_page_test.dart  (273 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure backend so secrets round-trip with no platform channel.
  - read write delete map
- `void main()`

### mobile_agents_settings_page_test.dart  (267 Z.)
- `void main()`

### model_selector_design_test.dart  (114 Z.)
- `void main()`

### newest_message_time_test.dart  (17 Z.)
- `void main()`

### secrets_settings_page_test.dart  (166 Z.)
- `class _Memory implements AgentsSecureKeyValueStore`
  - read write delete map
- `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — Settings > API Keys: names are listed with a "set" badge, values are never
- `String _j(Map<String, String> m)`
- `void main()`

### settings_page_test.dart  (213 Z.)
- `void main()`  — One settings page for both builds. With Agents on it is upstream

### skills_settings_page_test.dart  (357 Z.)
- const: _userSkill
- `Widget _host(Widget child)`
- `AgentsSkill _skill(String name, {String source = 'workspace', bool enabled = true})`
- `void main()`

### theme_page_test.dart  (166 Z.)
- `class _State`
  - themeMode accent iconFg bg contrast uiFont chatFont dynamicColor
- `AppShellConfig _config(_State s)`
- `Widget _host(AppShellConfig config)`
- `void main()`

## test/perf
### agent_switch_data_perf_test.dart  (146 Z.)
- const: _catalogueReadsPerSwitch _messagesPerThread _switches _dataCeilingMs
- `List<Map<String, dynamic>> _catalogue()`
- `List<Map<String, String>> _thread()`
- `void main()`

### agent_switch_perf_test.dart  (324 Z.)
- const: _guard _messagesPerThread _switches _switchCeilingMs
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _SignedIn implements AccountSessionSource`  — A signed-in account, so the shell takes its normal paired path.
  - current refresh
- `String _marker(int agent)`  — Marker words, one per agent, so the finder knows which thread is shown.
- `String _answer(int agent, int i)`
- `String _toolCalls(int i)`
- `List<Map<String, dynamic>> _transcript(int agent)`
- `void main()`

### cold_start_perf_test.dart  (584 Z.)
- const: _guard _mountRuns _microRuns _marker _mountCeilingMs _microCeilingMs
- `void main()`

### perf_support.dart  (203 Z.)
- `class NoopSaver implements AgentFileSaver`  — A file saver that writes nowhere. No perf test hands a file to it.
  - save
- `class FakeSessionSource implements AccountSessionSource`  — No Supabase session anywhere — the cold start proper.
  - current refresh
- `class FakeDisk`  — The local cache, as a map. It outlives [AgentsChatStore.reset] on purpose:
  - payloadBytesOf install rows kv
- `Widget perfApp(Widget child)`
- `void silenceUnrelatedPlugins(WidgetTester tester)`  — The imported chat screen constructs an [AudioRecorder] on mount, which
- `Future<void> releaseIdleTimers(WidgetTester tester)`  — The imported chat screen opens a multiplex session on mount and arms a
- `Future<void> drainNotifyDebounce()`  — `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
- `double median(List<double> samples)`  — The median of [samples]. An even count takes the mean of the middle pair.
- `double _minOf(List<double> s)`
- `double _maxOf(List<double> s)`
- `class PerfRow`  — One measured quantity: a label, its samples in milliseconds, and an
  - medianMs minMs maxMs label samplesMs note
- `class PerfTable`  — Collects [PerfRow]s and prints them as one fixed-width table.
  - report title rows note
- `double timedMs(void Function() body)`  — Wall-clock milliseconds of [body], at microsecond resolution.

## test/platform_specific
### sidebar_blocks_test.dart  (528 Z.)
- `DateTime _localMidnight()`  — Midnight at the start of the current local day — the anchor every seeded
- `void _seedChats()`  — Seeds the store the sidebars read from. Returns nothing — the sidebars
- `StoredChat _seedChat({ required String id, required DateTime at, required String title, bool starred = false, })`
- `Widget _host(Widget child)`
- `void _tallWindow(WidgetTester tester)`  — Gives the test a window tall enough that a whole sidebar — account card,
- `Future<void> _settleStartupWork(WidgetTester tester)`  — The background update check starts a 5 s timeout timer. Tearing the tree
- `void main()`

## test/platform_specific/chat
### agents_thread_composer_test.dart  (197 Z.)
- `Finder findId(String id)`  — The composer's targets carry a semantics identifier, not a label.
- `class _NoopSaver implements AgentFileSaver`
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Widget _app(Widget child)`
- `void main()`

### anchored_transcript_test.dart  (340 Z.)
- `void main()`  — The bottom-anchored transcript (Agents).
- `Matcher moveTo(double target)`
- `class _Harness extends StatefulWidget`
  - initialRows anchored rowHeight textLength bottomInset
- `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - _row open setStreaming truncateAndAppend _item anchoredTranscript transcriptRows transcriptStreaming rows streaming built

### chat_scroll_mixin_test.dart  (242 Z.)
- `void main()`  — Auto-scroll during streaming.
- `Matcher moveTo(double target)`  — `pixels` lands on the extent within a sub-pixel of it.
- `class _Harness extends StatefulWidget`
  - initialRows
- `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - streamOneMoreRow growWithoutPinning finishStream jumpToEnd rows

### chat_ui_helpers_test.dart  (701 Z.)
- `void main()`

### composer_send_target_test.dart  (129 Z.)
- `Finder findId(String id)`  — The composer's targets carry a semantics identifier, not a label.
- `class _NoopSaver implements AgentFileSaver`
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Widget _app(Widget child)`
- `void main()`

### message_render_cache_shared_test.dart  (91 Z.)
- `List<Map<String, String>> _messages()`
- `void main()`

### mode_provider_resolution_test.dart  (146 Z.)
- const: _model _modeProvider
- `class _Host extends StatefulWidget`
- `class _HostState extends State<_Host> with ModelProviderResolutionMixin<_Host>`
  - selectedModelId selectedProviderSlug chatMode
- `void main()`

### queued_messages_restore_test.dart  (18 Z.)
- `void main()`

### regen_variant_seed_test.dart  (187 Z.)
- `class _Host extends StatefulWidget`
- `class _HostState extends State<_Host> with RegenVariantSeedMixin<_Host>`
  - variantActiveChatId activeChat
- `Future<_HostState> _pump(WidgetTester tester)`
- `List<Map<String, dynamic>> _seed()`
- `void main()`

## test/platform_specific/chat/widgets
### chat_message_list_item_test.dart  (145 Z.)
- `void main()`

## test/platform_specific/mobile
### mobile_agent_list_test.dart  (368 Z.)
- `void main()`

### mobile_agent_sheet_test.dart  (82 Z.)
- `void main()`

### mobile_chat_chrome_test.dart  (528 Z.)
- `void main()`

### mobile_chat_screen_test.dart  (129 Z.)
- `void main()`

### mobile_preview_test.dart  (295 Z.)
- const: _out
- `void main()`
- `class _PlaceholderChat extends StatelessWidget`  — Stands in for the verbatim chuk_chat phone screen in the preview: a
  - topInset

### mobile_support.dart  (111 Z.)
- const: kPhoneSize kPhonePadding
- `Finder findId(String id)`  — Finds the `Semantics(identifier: id)` widget the mobile layer wraps each
- `Future<void> pumpPhone( WidgetTester tester, Widget child, { ThemeData? theme, })`  — Pumps [child] into a phone-shaped, localised app.
- `AgentsAgent agent({ required String id, required String name, String? role, String? brief, bool running = false, DateTim …)`
- `LocalAgentRosterSource rosterWith(List<AgentsAgent> agents)`
- `Future<void> loadRealFonts()`  — Loads Roboto and the Material icon font from the Flutter SDK so a golden

### touch_target_walk_test.dart  (140 Z.)
- `bool _isTarget(Widget w)`  — True for a widget that takes a tap and is therefore a touch target.
- `void expectAllTargetsAreBigEnough(WidgetTester tester, Finder root)`  — Measures every target under [root] and fails on the first one that is
- `void main()`

## test/services
### account_session_test.dart  (226 Z.)
- `String _jwt({required int exp, String sub = 'user-1'})`  — A JWT whose only claim that matters is `exp` (gotrue reads it unverified).
- `Session _session({required int exp, String refresh = 'r1'})`
- `void main()`

### api_config_base_test.dart  (26 Z.)
- `void main()`  — The model catalogue (`/v1/models_info`) is fetched from this base URL by

### app_mode_service_test.dart  (117 Z.)
- `void main()`

### app_theme_contrast_uifont_test.dart  (94 Z.)
- `void main()`

### app_theme_service_dynamic_color_test.dart  (165 Z.)
- `ColorScheme _schemeWithPrimary(Color primary, Brightness brightness)`
- `void main()`

### artifact_diff_engine_test.dart  (102 Z.)
- `void main()`

### artifact_encrypted_meta_test.dart  (823 Z.)
- const: _prefix _rowUuid
- `Future<String> _fakeSeal(String plaintext)`
- `Future<String> _fakeOpen(String envelope)`
- `Map<String, dynamic> _row({ required String id, required Object? title, Object? language, Object? encryptedMeta, String …)`
- `ArtifactRowRef _ref({ required String rowId, required String handle, required String updatedAt, String? title, String? s …)`
- `Future<String> _seal(String rowId, Map<String, Object?> fields)`  — Seals [fields] the way the service does, bound to `artifacts` row
- `Future<ArtifactDocument> _resolve(Map<String, dynamic> row)`
- `Future<bool> _needsReseal(Map<String, dynamic> row)`
- `Future<Map<String, dynamic>> _open(Object? envelope, String rowId)`  — Opens an envelope as the service does for `artifacts` row [rowId];
- `void main()`

### artifact_repair_version_chain_test.dart  (33 Z.)
- `void main()`

### artifact_rollback_test.dart  (560 Z.)
- `void main()`

### artifact_storage_pending_flushers_test.dart  (112 Z.)
- `void main()`

### auth_trace_test.dart  (43 Z.)
- `void main()`

### bash_sandbox_folder_test.dart  (105 Z.)
- `void main()`

### chat_history_builder_test.dart  (273 Z.)
- `void main()`  — The outgoing payload is `{message: <current turn>, history: [...]}` and the

### chat_mode_config_test.dart  (413 Z.)
- `void main()`

### chat_model_provider_resolution_test.dart  (70 Z.)
- `class _Harness extends StatefulWidget`
  - chat
- `class _HarnessState extends State<_Harness> with ModelProviderResolutionMixin`
  - selectedModelId modelSelectionChatId selectedProviderSlug
- `void main()`

### chat_model_selection_service_test.dart  (91 Z.)
- `void main()`

### chat_payload_codec_test.dart  (244 Z.)
- `Map<String, dynamic> _toolTurn({String result = 'RESULT ', int repeat = 400})`  — A tool turn the way the app stores it in v2: the same tool calls (with
- `Map<String, dynamic> _v2Payload(List<Map<String, dynamic>> messages)`
- `List<String> _inMemory(String payloadJson)`
- `void main()`

### chat_payload_envelope_test.dart  (283 Z.)
- const: _oldPayloadVersion _oldCacheCodec
- `Future<String> _oldDecryptString(String encrypted, List<int> keyBytes)`
- `Future<List<String?>> _oldDecryptBatch( List<String> encryptedList, List<int> keyBytes, )`
- `String _oldDecodeCachePayload(Object? stored)`
- `List<int> _key()`
- `Future<String> _sealV1(String text, List<int> keyBytes)`  — A v1 envelope as every app writes it for titles and old chats.
- `String _chatJson({int rounds = 30})`
- `void main()`

### chat_payload_migration_test.dart  (870 Z.)
- const: userId _unreadableJson
- `String _id(int i)`
- `String _updatedAt(int i)`
- `String _v2Json(int i)`
- `Future<String> _sealV1(String text, List<int> key)`
- `class _FakeCloud implements ChatMigrationCloud`  — An in-memory `encrypted_chats` with the prod trigger's rule: a written
  - listPlainEnvelopeChats readRow writeRow convert fingerprint ensureKey currentKeyVersion key rows writes offline keyAvailable listGate changeBeforeWrite failRead
- `void main()`

### chat_reaction_service_test.dart  (76 Z.)
- `void main()`

### chat_runtime_test.dart  (182 Z.)
- `void main()`

### chat_storage_local_first_test.dart  (297 Z.)
- const: chatId userId
- `List<Map<String, String>> turn(String answer)`
- `void main()`

### chat_storage_pending_save_test.dart  (110 Z.)
- `void main()`

### chat_storage_title_sync_test.dart  (56 Z.)
- `void main()`

### encryption_service_test.dart  (702 Z.)
- `void main()`  — Tests for the core AES-GCM encryption logic used by EncryptionService.
- `int? _extractKeyVersion(String encrypted)`  — Mirror of EncryptionService.extractKeyVersion for testing

### file_conversion_page_images_test.dart  (103 Z.)
- `void main()`  — A scanned PDF has no text layer, so the API returns its pages as image

### flag_off_auth_parity_test.dart  (55 Z.)
- `void main()`

### image_compression_service_test.dart  (228 Z.)
- `void main()`

### legacy_prefs_blob_migration_test.dart  (277 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _FakeKv`  — An in-memory kv_cache that counts writes and can be told to fail them.
  - backend map failWrites writes
- `String _connectionsJson(List<String> names)`
- `void main()`

### mcp_reachability_test.dart  (24 Z.)
- `void main()`

### mcp_tools_frame_test.dart  (148 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - read write delete map
- `void main()`

### media_index_test.dart  (111 Z.)
- `void main()`

### message_composition_service_test.dart  (69 Z.)
- `void main()`

### model_cache_memo_test.dart  (51 Z.)
- `void main()`

### multiplex_auth_refresh_test.dart  (569 Z.)
- `class _FakeMultiplexServer`  — Minimal stand-in for the `/v2/ws` endpoint.
  - _send start _accept _onFrame push acceptPendingRefresh stop baseUrl refreshTokens handshakeToken onAuthRefresh
- `Future<void> _settle([int ms = 120])`  — Let queued microtasks and socket I/O settle.
- `void main()`

### network_status_service_test.dart  (124 Z.)
- `void main()`

### oauth_loopback_server_test.dart  (118 Z.)
- const: _theme
- `OAuthLoopbackServer _server(int port)`  — Ports in the dynamic range, one per test, so a lingering socket from one
- `typedef _Response = ({int status, String body})`  — Status code and body of one callback request.
- `Future<_Response> _get(Uri uri)`
- `void main()`

### offline_queue_service_test.dart  (140 Z.)
- `void main()`

### offline_retry_manager_test.dart  (145 Z.)
- `void main()`

### onboarding_tour_controller_test.dart  (44 Z.)
- `void main()`

### per_model_system_prompt_merge_test.dart  (175 Z.)
- `void main()`

### prefs_to_kv_migration_test.dart  (58 Z.)
- `void main()`

### reasoning_supported_efforts_test.dart  (198 Z.)
- `Future<void> _seedCatalog(List<Map<String, dynamic>> models)`  — Seed the on-disk catalog cache with [models] and hydrate the capability
- `void main()`

### round_content_block_service_test.dart  (519 Z.)
- `void main()`

### session_manager_sign_out_event_test.dart  (51 Z.)
- `void main()`

### session_recovery_test.dart  (464 Z.)
- `String _jwt({required int exp, String sub = 'user-1'})`
- `Session _session({required int exp, required String refresh})`
- `class _FakeLink implements RecoveryLink`  — A host on the other end of the recovery link, scripted per test.
  - Function provision source adopter attachFails disposed provisioned onProvision
- `void main()`

### session_refresh_scheduler_test.dart  (137 Z.)
- `class _Source implements AccountSessionSource`
  - adopt current refresh refreshCalls gate
- `void main()`

### streaming_final_content_test.dart  (55 Z.)
- `void main()`

### streaming_idle_timeout_test.dart  (139 Z.)
- const: _chukChatId
- `void main()`

### streaming_manager_test.dart  (585 Z.)
- `void main()`
- `class _TestStreamContext`  — Helper class to hold test stream state
  - controller getContent getReasoning getTps isCompleted getError

### streaming_silence_test.dart  (206 Z.)
- `class _Rig`  — One run under test: the input the host would write to, and everything the
  - start chatId input manager updates completions errors errorCodes
- `void main()`

### theme_settings_sync_fields_test.dart  (122 Z.)
- `void main()`

### thread_preview_store_test.dart  (97 Z.)
- `void main()`

### tool_call_handler_deferred_action_test.dart  (281 Z.)
- `void main()`

### tool_call_handler_fact_check_test.dart  (193 Z.)
- `void main()`

### tool_call_handler_repeated_lookup_test.dart  (393 Z.)
- `void main()`

### tool_call_handler_safety_limit_test.dart  (145 Z.)
- `void main()`

### tool_call_handler_stub_test.dart  (204 Z.)
- `void main()`

### tool_call_reasoning_lift_test.dart  (65 Z.)
- `void main()`

### tool_enforcer_test.dart  (137 Z.)
- `Map<String, dynamic> _def(String name)`
- `Map<String, dynamic> _call(String name, [Map<String, dynamic>? args])`
- `void main()`

### tool_failure_detection_test.dart  (129 Z.)
- `void main()`  — A tool result's failure flag drives the icon the user sees AND whether the

### tool_image_result_service_test.dart  (178 Z.)
- `void main()`

### tool_prompt_builder_test.dart  (439 Z.)
- const: _skillToolDef _tools _testSkill
- `void main()`

### tool_result_cache_registry_test.dart  (124 Z.)
- `void main()`

### tool_turn_signals_test.dart  (47 Z.)
- `void main()`

### tour_key_registry_test.dart  (62 Z.)
- `void main()`

### user_scoped_cache_invalidation_test.dart  (301 Z.)
- `void main()`  — Guards the cross-user leak fix: the static caches in these services are

### user_scoped_cache_race_test.dart  (309 Z.)
- `void main()`  — The sign-out-mid-flight race: an operation starts as user A, A signs out and

### websocket_chat_service_test.dart  (730 Z.)
- `List<AgentsRelayInbound> _everyVariant()`  — Every inbound variant the relay can produce, so the "never a ToolCallsEvent"
- `void main()`
- `Future<void> _drain()`  — Lets the adapter's internal handler chain settle.

### workspace_encrypted_meta_test.dart  (1172 Z.)
- const: _prefix _projectStamp _fileStamp
- `Future<String> _fakeSeal(String plaintext)`  — Reversible and opaque: base64 hides the plaintext, like a real envelope.
- `Future<String> _fakeOpen(String envelope)`  — Opens only envelopes of [_fakeSeal]; anything else acts like a wrong key.
- `String _foreignEnvelope(Map<String, Object?> fields)`  — An envelope sealed with another key (cannot be opened).
- `Future<String> _envelope( Map<String, Object?> fields, { String table = 'projects', String row = 'proj-1', })`  — Envelope bound to project row 'proj-1' (the default [_projectRow]).
- `Future<String> _fileEnvelope(Map<String, Object?> fields)`  — Envelope bound to file row 'file-1' (the default [_fileRow]).
- `Map<String, dynamic> _projectRow({ String id = 'proj-1', Object? name = kEncryptedPlaceholder, Object? description, Obje …)`
- `Map<String, dynamic> _fileRow({ String id = 'file-1', Object? fileName = kEncryptedPlaceholder, Object? markdown, String …)`
- `Future<SealedRowRead> _readProject(Map<String, dynamic> raw)`
- `Future<SealedRowRead> _readFile(Map<String, dynamic> raw)`
- `bool _matchesOrFilter(String filter, Map<String, dynamic> row)`  — Evaluates a PostgREST `or` filter of the sweep against one row with SQL
- `void main()`

## test/services/agents
### agent_profile_store_test.dart  (58 Z.)
- `void main()`

### agent_read_marks_persist_test.dart  (42 Z.)
- `void main()`

### agent_roster_store_test.dart  (249 Z.)
- `void main()`

### agents_cloud_relay_test.dart  (754 Z.)
- `class _FakeRelayServer implements RelaySocket`  — A stand-in for `api.chuk.chat/v2/relay/ws`.
  - send fromHost _deliver close toHost incoming authOk claimReply sent closed hostDeviceId
- `class _HostSide`  — The §15 initiator, exactly as the host runs it, speaking the LOCAL relay
  - mac start _send _onEnvelope _establishCodec emit answerResume server channelId digits signingKeyPair deviceId connection sessionTranscript sessionKey controllerKey opened paired
- `class _Session implements AccountSessionSource`
  - current refresh
- `void main()`

### agents_crypto_vectors_test.dart  (185 Z.)
- `void main()`  — Cross-language byte-compatibility proof for the Agents frame crypto.
- `class _FixedByteRandom implements Random`  — A [Random] that hands out a fixed byte sequence through [nextInt], so the
  - nextInt nextBool nextDouble

### agents_heal_channel_test.dart  (400 Z.)
- `class _Session implements AccountSessionSource`
  - current refresh
- `class _Relay implements RelaySocket`  — The relay as a reconnect sees it: `auth_ok`, then the presence snapshot it
  - send deliver _deliver close incoming online claimCode silentClaims hostId sent closed
- `class _RecordingTransport implements ExecutorTransport`
  - sendAuthentication payloads
- `void main()`
- `Future<SimpleKeyPair> _keyPair()`
- `Future<AgentsStoredPairing> _pairing(Uint8List key, Uri hostUrl)`

### agents_install_claim_wait_test.dart  (552 Z.)
- `class _ClaimSocket implements RelaySocket`  — One relay socket. It signs the app in, then answers each claim with the
  - send _deliver close relayed incoming script authOk commitOnBind commit claims sent closed hostDeviceId
- `class _Session implements AccountSessionSource`
  - current refresh
- `void main()`

### agents_install_flow_test.dart  (252 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _Session implements AccountSessionSource`
  - current refresh userId
- `class _Wait`  — One pending wait: the test decides when and how it ends.
  - invite deadline cancel result
- `void main()`

### agents_install_ticket_test.dart  (225 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `void main()`

### agents_invite_pairing_test.dart  (236 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _RecordingMirror extends SupabasePairingSync`  — The encrypted mirror, recording what it was asked to store.
  - saveEncryptedPairing clearEncryptedPairing saved
- `class _Session implements AccountSessionSource`
  - current refresh
- `void main()`

### agents_pairing_key_replace_test.dart  (173 Z.)
- `void main()`

### agents_pairing_restore_test.dart  (425 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _FakeMirror extends SupabasePairingSync`  — The encrypted mirror, scripted. [record] is what a read returns once
  - publishEncryptedPairing readEncryptedPairing saveEncryptedPairing clearEncryptedPairing record available reads publishes writable missing
- `class _Session implements AccountSessionSource`
  - current refresh session
- `void main()`
- `class _ThrowingStore implements AgentsSecureKeyValueStore`
  - read write delete

### agents_pairing_store_test.dart  (194 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the store round-trips with no platform channel.
  - read write delete map
- `void main()`

### agents_pairing_test.dart  (502 Z.)
- `void main()`  — Pairing tests: the cross-language vector (byte-for-byte against the Python

### agents_pairing_uri_test.dart  (137 Z.)
- `void main()`  — The one string the user ever handles. It comes off a QR code, out of a

### agents_queued_marks_test.dart  (126 Z.)
- `void main()`  — The imported bubble offers **Retry** only for a row whose status is

### agents_reconnect_test.dart  (374 Z.)
- `void main()`  — Reconnect handshake tests: the cross-language vector (byte-for-byte against

### agents_relay_client_test.dart  (2140 Z.)
- `class FakeMcpStore extends McpStore`  — A stand-in [McpStore] whose forward payloads are canned, so a task-frame
  - forwardPayloads
- `class FakeHereNowStore extends HereNowStore`  — A stand-in [HereNowStore] whose forward payload is canned, so a task-frame
  - forwardPayload
- `class FakeRelaySocket implements RelaySocket`  — A fake duplex socket. `send()` from the client is captured on [outbound];
  - send deliver close incoming outbound closed
- `class FakeExecutorHost`  — The in-Dart executor: it plays the pairing INITIATOR and, once paired, seals
  - frameToWire frameFromWire start _sendPairing _onClientEnvelope _onPairing _establishCodec _onFrame emit socket deviceId channelId digits signingKeyPair nowMs approved received paired
- `class _SessionSource implements AccountSessionSource`  — A session source the test scripts: what `current()` returns and what a
  - current refresh refreshCalls
- `void main()`

### agents_relay_done_reason_test.dart  (26 Z.)
- `void main()`  — `done.reason` semantics the thread view relies on (docs/WIRE_CONTRACT.md,

### agents_relay_reconnect_test.dart  (280 Z.)
- `class FakeRelaySocket implements RelaySocket`  — A fake duplex socket (client send captured on [outbound]; host writes via
  - send deliver close incoming outbound
- `class FakeReconnectHost`  — A fake host that plays the reconnect INITIATOR: on join it sends a signed
  - start _sendPairing _onEnvelope _establishCodec emit socket hostDeviceId hostKeyPair appDeviceId appPublicKey channelId channelKey received authenticated
- `void main()`

### agents_relay_secrets_test.dart  (136 Z.)
- `void main()`  — The secrets frames over the real sealed channel (docs/WIRE_CONTRACT.md,

### agents_replay_loader_test.dart  (736 Z.)
- `void main()`
- `Future<void> _drain()`  — Lets the loader's internal handler chain settle.

### agents_replay_paging_test.dart  (153 Z.)
- `void main()`  — Replay paging in the loader (docs/WIRE_CONTRACT.md "Replay paging", Bead

### agents_replay_repeat_test.dart  (181 Z.)
- `Map<String, String> user(String text)`  — Bead cowork-4rpt: the same message, twice.
- `Map<String, String> ai(String text)`
- `List<String> texts(List<Map<String, String>> rows)`
- `void main()`
- `void _pagingTests()`
- `void _repairTests()`

### agents_run_ledger_test.dart  (371 Z.)
- `void main()`

### agents_shell_status_test.dart  (84 Z.)
- `void main()`

### agents_stopped_run_test.dart  (296 Z.)
- `void main()`  — A run that ends with nothing must END — visibly (bead cowork-gnr8).
- `List<Map<String, dynamic>> _rowsFor(String session)`
- `Future<void> _drain()`

### agents_task_delivery_test.dart  (310 Z.)
- `void main()`  — A message sent at 04:49 was gone. The app drew a sent bubble and a typing
- `Future<void> _drain()`  — Lets the adapter's internal handler chain settle.

### agents_task_outbox_test.dart  (230 Z.)
- `void main()`  — Bead cowork-i7sd: "ob die Nachrichten im Backend ankommen, ist irgendwie

### browser_presence_test.dart  (345 Z.)
- `void main()`

### chat_core_routing_test.dart  (308 Z.)
- const: chukChatId threadKey
- `StoredChat _chat(String id, String text)`
- `void main()`
- `Future<void> _drain()`

### chat_debug_export_size_test.dart  (102 Z.)
- `void main()`  — The debug copy has to be the size chuk_chat's is. A thread that carries a

### chat_document_persistence_test.dart  (203 Z.)
- `Future<String> _encryptWithKey(String plaintext, SecretKey key)`  — Builds the production ciphertext envelope around [plaintext] with an
- `void main()`

### offline_retry_manager_test.dart  (150 Z.)
- `void main()`  — The Retry button in the imported bubble calls

### room_source_test.dart  (221 Z.)
- `AgentsRoomMember _m(String id, String handle)`
- `AgentsRoomDraft _draft( String name, { List<AgentsRoomMember>? members, bool agentToAgent = true, })`
- `void main()`

### schedule_spec_test.dart  (431 Z.)
- `void main()`  — 2026-02-03 is a Tuesday. Every date in this file is built from local

### tool_card_parity_test.dart  (317 Z.)
- const: _t0 _liveRun _replayedRun
- `Map<String, dynamic> _visible(Map<String, dynamic> call)`  — The fields of a card the reader can see: everything the renderer reads
- `DateTime _at(int seconds)`
- `void main()`
- `Future<void> _drain()`

### tool_events_contract_test.dart  (178 Z.)
- `void main()`

## test/services/automations
### agents_automation_test.dart  (223 Z.)
- `Map<String, dynamic> eventPayload({ String event = 'created', String id = 'ab12cd34', String state = 'active', String ki …)`  — The wire shapes of docs/WIRE_CONTRACT.md, "Automations", as the host
- `void main()`

### automations_source_test.dart  (167 Z.)
- `class FakeAutomationController extends FakeRelayController implements AgentsAutomationControl`  — The shared test double, plus the two automation frames the source sends.
  - sendAutomationControl requestAutomationList controls listRequests sendError
- `AgentsAutomation automation(String id, {String session = 'thread-1', String state = 'active', double created = 1.0})`
- `void main()`

## test/services/herenow
### herenow_store_test.dart  (56 Z.)
- `void main()`

## test/services/mcp
### chuk_mcp_mirror_test.dart  (390 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`  — Keychain stand-in.
  - read write delete map
- `class _OwnMirror implements McpConnectorSync`  — Agents's own mirror, in memory.
  - save load clear blob
- `class _ChukTable implements ChukMcpMirror`  — chuk_chat's `service_credentials` rows, in memory, by catalogue id.
  - load save delete rows saved deleted saveError
- `Map<String, dynamic> _connectionJson( String id, { String auth = 'oauth', String? url, })`
- `Map<String, dynamic> _secretsJson({ String access = 'at-chuk', String? refresh = 'rt-chuk', Duration ttl = const Duratio …)`  — chuk's `_McpSecrets.toJson` as it lands in the blob.
- `ChukMcpRow _row(String id, {Map<String, dynamic>? secrets, String auth = 'oauth'})`
- `void main()`

### mcp_adoption_test.dart  (234 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`  — Keychain stand-in.
  - read write delete map
- `class _OwnMirror implements McpConnectorSync`  — Agents's own mirror, in memory. Always readable, always empty here — these
  - save load clear
- `class _ChukTable implements ChukMcpMirror`  — chuk_chat's `service_credentials` rows, in memory, counting every read.
  - load save delete rows loads
- `Map<String, dynamic> _connectionJson(String id)`
- `Map<String, dynamic> _secretsJson()`
- `ChukMcpRow _row(String id)`
- `void main()`

### mcp_oauth_test.dart  (321 Z.)
- `http.Response _json(Map<String, dynamic> body)`
- `MockClient _compliantServer({ List<String> scopes = const <String>['read', 'write'], void Function(Map<String, String> b …)`  — A server that publishes protected-resource metadata pointing at its own
- `void main()`

### mcp_service_test.dart  (728 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _FakeSync implements McpConnectorSync`  — An in-memory stand-in for the encrypted Supabase mirror.
  - save load clear blob
- `http.Response _json(Map<String, dynamic> body)`
- `MockClient _challengingServer({String scope = 'read'})`  — The server's answer to an unauthenticated request: a 401 that names both
- `MockClient _authServer({bool refuseRegistration = false})`  — A compliant authorization server for `https://srv.example/mcp`.
- `Future<bool> _signIn(Uri authorizationUrl)`  — Stands in for the browser: takes the authorization URL, hands the loopback
- `void main()`

### mcp_store_test.dart  (564 Z.)
- `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure backend so secrets round-trip with no platform channel.
  - read write delete map
- `McpSecrets _record({ String accessToken = 'at-1', String? refreshToken = 'rt-1', DateTime? expiresAt, String tokenEndpoi …)`  — A full record, as `_authorize` writes one after a real sign-in.
- `void main()`

## test/services/notifications
### agents_notifications_test.dart  (110 Z.)
- `void main()`

### local_notifications_test.dart  (167 Z.)
- `class FakeBackend implements LocalNotificationsBackend`  — Records every call; the platform plugin never runs in a test.
  - Function show cancel launchPayload requestPermission initOk launch permission tap shown cancelled
- `void main()`

### push_service_test.dart  (221 Z.)
- `class FakeTransport implements PushTransport`  — Firebase, faked: the tests drive tokens and taps by hand.
  - initialize token initialMessage requestPermission onTokenRefresh onMessageOpenedApp available currentToken initial permissionRequests refresh opened
- `class FakeStore implements DeviceTokenStore`
  - upsert delete upserts deletes
- `void main()`
- `class _ThrowingStore implements DeviceTokenStore`
  - upsert delete

## test/services/secrets
### secrets_service_test.dart  (149 Z.)
- `class _Memory implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _Mirror implements SecretsMirror`  — A mirror that records what it was asked to do and can pre-seed a pull.
  - save delete load seed saved deleted
- `List<(Map<String, String>, int, String?)> _sink(SecretsService Function() _)`  — Every frame handed to the "host": `(values, revision, requestId)`.
- `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — Records with a Map inside compare by identity; flatten to compare by value.
- `String _j(Map<String, String> m)`
- `void main()`

### secrets_store_test.dart  (104 Z.)
- `class _Memory implements AgentsSecureKeyValueStore`  — In-memory secure backend so the set round-trips with no platform channel.
  - read write delete map
- `void main()`

## test/services/settings
### mobile_chat_preferences_test.dart  (93 Z.)
- `void main()`

## test/services/skills
### builtin_skills_freshness_test.dart  (49 Z.)
- `void main()`  — The gate that makes build-time codegen safe.

### builtin_skills_validity_test.dart  (132 Z.)
- const: _kMaxBodyTokens
- `void main()`

### skill_frontmatter_parser_test.dart  (367 Z.)
- const: _minimal
- `String _md(String frontmatter, {String body = '# Body\n\nDo the thing.'})`  — Builds a SKILL.md with [frontmatter] verbatim between the --- fences.
- `void main()`

### skill_registry_user_layer_test.dart  (199 Z.)
- `Skill _userSkill(String name, {String? id})`
- `void main()`

### skill_tool_execution_test.dart  (165 Z.)
- `ToolExecutor _executorWith(List<String> toolNames)`  — Registers just the tools a skill test needs, straight from the catalogue,
- `void main()`

### skills_catalog_reconcile_test.dart  (225 Z.)
- `CatalogSkill _cat(String name, String hash)`
- `void main()`

### skills_local_store_test.dart  (156 Z.)
- `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - getApplicationSupportPath getApplicationDocumentsPath getTemporaryPath dir
- `Map<String, dynamic> _skillRow( String id, String userId, { required String source, String? catalogName, String? baselin …)`
- `void main()`

### skills_source_test.dart  (208 Z.)
- `class FakeSkillsController extends FakeRelayController implements AgentsSkillsControl`  — The shared test double, plus the two skill frames the source sends.
  - sendSkillControl requestSkillsList controls listRequests sendError
- `class FakeMirror implements SkillSettingsMirror`  — A mirror the test can read back and seed.
  - load save stored saves
- `AgentsSkill skill(String name, {String source = 'workspace', bool enabled = true})`
- `void main()`

## test/services/storage
### agents_chat_cache_migration_test.dart  (169 Z.)
- `void main()`

### agents_chat_storage_bootstrap_test.dart  (129 Z.)
- `void main()`
- `void _flushTests()`

### agents_chat_store_test.dart  (555 Z.)
- `List<Map<String, dynamic>> rows(List<List<String>> turns)`
- `void main()`
- `void _outboxTests()`

### agents_cloud_table_test.dart  (569 Z.)
- const: _user _chukChatId
- `String _payload(List<List<String>> turns, {String? customName})`
- `Map<String, dynamic> _cloudRow( String id, String payloadJson, { String updatedAt = '2026-09-20T10:00:00.000Z', String? …)`  — A `cowork_chats` row as the server returns it. The "ciphertext" is the
- `class _Cloud`
  - install rows selects deletes updates maxRows
- `void main()`

### agents_offline_sqlite_test.dart  (97 Z.)
- `void main()`

### chat_origin_routing_test.dart  (325 Z.)
- const: chukChatId agentsThreadKey
- `List<Map<String, dynamic>> turn(String text)`
- `OfflineSendPayload payload(String chatId)`
- `void removeAsTheSyncDoes(String chatId)`  — Upstream's local removal drops the chat first and then reaches for the
- `void main()`

## test/support
### fake_relay_controller.dart  (265 Z.)
- `class FakeRelayController implements AgentsRelayController`  — A controller the test drives directly: set [set], push [emit] — no socket
  - connect reconnect provisionAccount setRoomAgentToAgent sendRoomTask requestRoomHistory deleteRoom renameRoom createAgent renameAgent requestAgentList addRoomMember removeRoomMember sendRunAck startBrowserView stopBrowserView sendBrowserData sendApprovalDecision sendSecrets set emit state inbound establishedTrust replaySessionKeys connectCalls connects trustOnConnect connectError replayPages reconnectCalls provisioned reconnectFails tasks taskSessionKeys taskModelIds taskProviderSlugs taskReasoning taskDebugFlags taskRegenerateFlags +12

### icon_finder.dart  (34 Z.)
- `Finder findIcon(IconData icon)`  — Finds an icon whether it draws as Material or as the app's own set.
- `Color? iconColor(WidgetTester tester, Finder finder)`  — The colour the icon at [finder] is drawn in, whichever widget drew it.
- `Finder findWidgetWithIcon<T extends Widget>(IconData icon)`  — A widget of type [T] that contains [icon], whichever widget drew it.

### kv_cache_test_env.dart  (59 Z.)
- `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - getApplicationSupportPath getApplicationDocumentsPath getTemporaryPath dir
- `void initSqfliteFfi()`  — Initialise the sqflite FFI backend once. Safe to call repeatedly.
- `Future<Directory> useTempKvCache()`  — Point LocalChatCacheService's SQLite DB at a fresh temp dir and drop any
- `Future<void> disposeTempKvCache(Directory tempDir)`  — Drop the cached DB handle and remove [tempDir]. Call from tearDown.

### mcp_memory_list.dart  (15 Z.)
- `McpListBackend memoryMcpList([Map<String, String>? backing])`

### shell_config.dart  (90 Z.)
- `AppShellConfig testShellConfig({ void Function(String field, Object? value)? onSet, Brightness themeMode = Brightness.da …)`  — An [AppShellConfig] for widget tests.

### test_app.dart  (29 Z.)
- reicht weiter: 'package:chuk_chat/l10n/app_localizations.dart' show AppLocalizations
- const: kTestLocalizationsDelegates
- `MaterialApp testApp(Widget home, {Key? key})`  — A `MaterialApp` shaped like the real one: localised, with [home] as its body.

## test/theme
### theme_presets_test.dart  (194 Z.)
- const: _preset
- `class _Recorder`  — Captures every setter call so a test can assert what a preset applied.
  - themeMode accent iconFg bg contrast uiFont dynamicCalls
- `AppShellConfig _config( _Recorder r, { Brightness currentThemeMode = Brightness.dark, Color currentAccent = kDefaultAcce …)`
- `void main()`

## test/tool_handlers
### map_tools_test.dart  (147 Z.)
- `void main()`

### places_map_card_test.dart  (145 Z.)
- `Map<String, dynamic> _decodeTag(String tag)`
- `void main()`

### weather_tools_test.dart  (316 Z.)
- `void main()`

## test/ui
### agent_status_test.dart  (72 Z.)
- `AgentsAgent agentWith({bool running = false})`
- `void main()`

### pill_controls_test.dart  (323 Z.)
- const: _destinations
- `Future<void> _pumpPhone(WidgetTester tester, Widget child)`
- `Future<void> _pumpInsideAScrollView( WidgetTester tester, Widget pill, )`  — The pill and the list under it, the arrangement the tap used to be lost in.
- `void main()`

## test/utils
### accent_button_foreground_test.dart  (46 Z.)
- `void main()`

### answer_blocks_parser_test.dart  (241 Z.)
- `AnswerBlockSegment _onlyBlock(List<AnswerSegment> segs)`
- `void main()`

### api_rate_limiter_test.dart  (263 Z.)
- `void main()`

### artifact_tag_parser_test.dart  (208 Z.)
- `void main()`

### build_app_theme_agents_test.dart  (50 Z.)
- `void main()`  — The theme has one side. The Agents build uses chuk_chat's theme as is: the

### build_app_theme_contrast_test.dart  (161 Z.)
- `void main()`

### clipboard_text_sanitizer_test.dart  (48 Z.)
- `void main()`

### debug_chat_formatter_test.dart  (122 Z.)
- `void main()`

### exponential_backoff_test.dart  (271 Z.)
- `void main()`

### file_upload_validator_test.dart  (148 Z.)
- `void main()`

### incomplete_markdown_links_test.dart  (27 Z.)
- `void main()`

### input_validator_test.dart  (314 Z.)
- `void main()`

### lenient_json_test.dart  (48 Z.)
- `void main()`

### lru_byte_cache_test.dart  (168 Z.)
- `Uint8List _bytes(int size)`  — Helper: create a Uint8List of [size] bytes.
- `void main()`

### phone_linkify_test.dart  (99 Z.)
- `void main()`

### secure_token_handler_test.dart  (163 Z.)
- `void main()`

### service_error_handler_test.dart  (440 Z.)
- `void main()`

### token_estimator_test.dart  (202 Z.)
- `void main()`

### tool_detail_format_test.dart  (86 Z.)
- `void main()`

### tool_history_formatter_test.dart  (214 Z.)
- `void main()`

### tool_parser_foreign_protocol_test.dart  (220 Z.)
- `void main()`  — Deny-by-default guard: a tool-call dialect this app does not parse must

### tool_parser_test.dart  (222 Z.)
- `void main()`

### upload_rate_limiter_test.dart  (135 Z.)
- `void main()`

## test/vnc
### live_auth_probe.dart  (54 Z.)
- `Future<String> attempt(int port, String? password)`
- `Future<void> main(List<String> args)`

### size_tracking_test.dart  (26 Z.)
- `void main()`

### socket_read_test.dart  (70 Z.)
- `Future<(RawSocket, Socket)> _pair()`
- `void main()`

### tight_decoder_test.dart  (350 Z.)
- const: _encTight _subJpeg
- `Uint8List _encodeTinyJpeg()`  — A 4x4 baseline JPEG, small enough for a 1-byte compact length.
- `class _Vector`
  - x0 y0 w h rects name meta raw
- `_Vector _load(String name)`
- `Future<(Uint8List, List<bool>)> _decodeAll(_Vector v)`  — Decode every rect of a vector in order (one decoder = one connection's
- `double _rectMeanError(_Vector v, Uint8List decoded, Map<String, dynamic> r)`  — Mean absolute error over R,G,B of one rect vs the raw capture.
- `void _expectRectExact(_Vector v, Uint8List decoded, Map<String, dynamic> r)`
- `void main()`

### trackpad_overlay_test.dart  (320 Z.)
- `class _SpyController extends RemoteFrameBufferController`  — Records the pointer/click/key calls the overlay makes, standing in for
  - key isReady frameBufferSize lastLeftClick events buttons button
- `Future<void> _pump(WidgetTester tester, _SpyController c)`
- `Future<void> _pinch(WidgetTester tester, double factor)`  — Pinches the two fingers apart (or together) by [factor] about the centre of
- `void main()`

### view_fit_test.dart  (184 Z.)
- `void main()`  — The mapping the whole browser view rests on: a touch has to reach the remote

### vnc_local_server_test.dart  (308 Z.)
- `void main()`  — The loopback server behind the noVNC viewer.

## test/voice
### voice_call_controller_test.dart  (231 Z.)
- `class _FakeDelegate implements VoiceTaskDelegate`
  - startTask results controller
- `Map<String, dynamic> _json(String s)`
- `void main()`

### voice_call_models_test.dart  (147 Z.)
- `void main()`

### voice_call_service_token_test.dart  (112 Z.)
- `void main()`

### voice_call_store_test.dart  (80 Z.)
- `VoiceCallRecord _record(String chatId, DateTime start, {String text = 'Hi'})`
- `void main()`

### voice_location_test.dart  (116 Z.)
- `Map<String, dynamic> _json(String s)`
- `void main()`

### voice_protocol_test.dart  (398 Z.)
- `class _FakeDelegate implements VoiceTaskDelegate`
  - startTask results onStart started
- `Map<String, dynamic> _json(String s)`
- `void main()`

### voice_tasks_test.dart  (113 Z.)
- `class _Delegate implements VoiceTaskDelegate`
  - startTask results
- `void main()`

### voice_transcript_test.dart  (254 Z.)
- `void main()`

### voice_widgets_test.dart  (348 Z.)
- const: _t0
- `Widget _host(Widget child, {double width = 360, double textScale = 1.0})`  — A 360 px column that scrolls, like the chat the widgets live in.
- `List<VoiceTurn> _turns()`
- `List<VoiceCard> _cards()`
- `void main()`

## test/voice_incoming
### fakes.dart  (253 Z.)
- `Map<String, dynamic> incomingFrame({ String callId = '3f2a9c1d0b7e4a55', String threadId = 'local:crypto-desk:1:74112' …)`  — A frame as the host sends it.
- `Map<String, dynamic> stateFrame(String callId, String state)`
- `class FakeCallkit implements CallkitPort`
  - emit showIncoming showMissed startOutgoing setConnected end signals controller shown missed started connected ended echoOnEnd
- `class FakeMic implements MicPermission`  — The microphone permission, as the test sets it. [pending] holds the
  - isGranted request granted grantOnRequest requests pending
- `class FakeSender implements CallStateSender`
  - send sent
- `class FakeUi implements OngoingCallUi`
  - show cancel requestUnlock notice actions controller shown cancelled unlocks notices
- `class FakeCall extends ChangeNotifier implements VoiceCallView`  — The app-wide call, driven by the test.
  - begin end setMicMuted setSpeakerOn isActive phase callId chatId mode agentName agentPresent micMuted speakerOn canSwitchSpeaker startedAt endCalls agent to
- `class FakeStarter`  — A starter that records the calls it was asked to start and, like the real
  - start call started

### incoming_call_mapping_test.dart  (214 Z.)
- `void main()`

### incoming_call_parsing_test.dart  (269 Z.)
- `void main()`

### incoming_call_service_test.dart  (522 Z.)
- `void main()`

### incoming_call_starter_test.dart  (115 Z.)
- const: _thread _reason
- `ChatVoiceBinding _binding(VoiceCallController controller)`
- `void main()`

### relay_call_state_sender_test.dart  (130 Z.)
- `class _Transport implements AgentsRelayController, AgentsVoiceCallControl`
  - pair drop sendVoiceCallState state sent fail
- `class _PlainTransport implements AgentsRelayController`  — A paired transport that is an [AgentsRelayController] but NOT an
  - state
- `void main()`

### voice_call_permissions_section_test.dart  (60 Z.)
- `void main()`

## test/voice_integration
### chat_voice_binding_agent_call_test.dart  (138 Z.)
- const: _thread
- `ChatVoiceBinding _binding(VoiceCallController controller, String chatId)`
- `void main()`

### chat_voice_binding_test.dart  (193 Z.)
- `ChatVoiceBinding _binding({ required VoiceCallController controller, required String? Function() chatId, bool agents = f …)`  — A binding over a fake screen. No LiveKit: the test build has no token
- `void main()`

### voice_call_context_test.dart  (130 Z.)
- `Map<String, String> _user(String text)`
- `Map<String, String> _ai(String text)`
- `void main()`

### voice_record_placement_test.dart  (156 Z.)
- `DateTime _t(int minute)`
- `VoiceCallRecord _record(int minute)`
- `void main()`

### voice_task_delegates_test.dart  (158 Z.)
- `class _FakeSender`  — A sender that records what it was asked and lets the test finish each
  - call sent turns
- `void main()`

### voice_turn_queue_test.dart  (251 Z.)
- `class _FakeChat`  — Stands in for a chat screen: each send appends a user row and an
  - send chatId busy refuse sent rows offline maxWait
- `void main()`

## test/widgets
### agent_activity_timeline_test.dart  (679 Z.)
- const: _t0
- `ToolCall _call( String name, { Map<String, dynamic> arguments = const {}, ToolCallStatus status = ToolCallStatus.complet …)`
- `Future<void> _pumpTimeline( WidgetTester tester, { required List<ToolCall> calls, bool isRunning = false, DateTime? now …)`
- `void main()`

### agent_chart_blocks_test.dart  (118 Z.)
- const: _electionChart
- `void main()`

### agent_control_panel_test.dart  (241 Z.)
- const: _fullSnapshot
- `AgentsAgent _agent({bool onHost = true})`
- `Future<void> _pump( WidgetTester tester, AgentControlSource source, { AgentsAgent? agent, })`
- `void main()`
- `class _ThrowingControlSource implements AgentControlSource`  — Wraps a source and refuses the skill toggle, to prove the failure surfaces.
  - snapshotFor refresh setSkillEnabled

### agent_face_test.dart  (91 Z.)
- `void main()`

### agent_markdown_test.dart  (56 Z.)
- `Widget _host(Widget child, {Brightness brightness = Brightness.light})`
- `void main()`

### agent_roster_view_test.dart  (927 Z.)
- `void main()`

### agent_run_views_test.dart  (288 Z.)
- const: _pngBytes
- `class _RecordingSaver implements AgentFileSaver`
  - save saved failWith
- `Widget _host(Widget child)`
- `void main()`

### agents_cold_start_test.dart  (398 Z.)
- const: _guard
- `class _NoopSaver implements AgentFileSaver`
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `class _FakeDisk`  — The local cache, as a map. It outlives [AgentsChatStore.reset] on purpose:
  - install rows kv
- `Widget _app(Widget child)`
- `void main()`
- `Future<void> _drainNotifyDebounce()`  — `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
- `Future<void> _releaseIdleTimers(WidgetTester tester)`  — The imported chat screen opens a multiplex session on mount and arms a
- `void _silenceUnrelatedPlugins(WidgetTester tester)`  — The imported screen constructs an [AudioRecorder] on mount, which calls the
- `Future<void> _settle(WidgetTester tester)`  — [WidgetTester.pumpAndSettle] never returns here: the thread view arms an

### agents_desktop_shell_test.dart  (502 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _FailingRefreshSource extends FakeAgentControlSource`  — A host that answers the panel's first look and then fails a refresh.
  - refresh failNext
- `class _Session implements AccountSessionSource`
  - current refresh
- `void main()`

### agents_shell_states_test.dart  (327 Z.)
- const: kDesktop kPhone
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _Mirror extends SupabasePairingSync`  — The encrypted mirror, answering one scripted outcome.
  - readEncryptedPairing publishEncryptedPairing saveEncryptedPairing clearEncryptedPairing outcome
- `class _Session implements AccountSessionSource`
  - current refresh signedIn
- `class _HangingController extends FakeRelayController`  — A reconnect that never finishes: the link stays "connecting".
  - reconnect
- `class _EmptyHostRoster extends LocalAgentRosterSource`  — A host that lists no agents: pairing does not bring a host coworker.
  - ensureHostAgent
- `void main()`

### agents_thread_header_test.dart  (250 Z.)
- `Widget _wrap(Widget child, {double width = 900})`  — The row only ever gets the width its parent has, so every test states
- `AgentsThreadAction _action(String tooltip, List<String> log)`
- `void main()`

### agents_thread_view_notifications_test.dart  (201 Z.)
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `class _NoopSaver implements AgentFileSaver`
  - save
- `Widget _app(Widget child)`
- `void main()`

### agents_thread_view_secrets_test.dart  (240 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the stores round-trip with no platform channel.
  - read write delete map
- `class _NoopSaver implements AgentFileSaver`
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Widget _app(Widget child)`
- `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — The `secret_request` card (docs/WIRE_CONTRACT.md, "Secrets"): one field
- `String _j(Map<String, String> m)`
- `void main()`

### agents_thread_view_stopped_run_test.dart  (174 Z.)
- `class _NoopSaver implements AgentFileSaver`
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Widget _app(Widget child)`
- `void main()`  — The visible run must end when the host says the run ended, whatever else the

### agents_thread_view_test.dart  (1456 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the store round-trips with no platform channel.
  - read write delete map
- `class _NoopSaver implements AgentFileSaver`  — A saver that never touches a filesystem.
  - save
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Widget _app(Widget child)`  — The app shell the imported chat screen expects around it: localisations and
- `void main()`
- `Future<void> _flushIdleTimers(WidgetTester tester)`  — The imported chat screen schedules a 60 s idle-close timer for its

### anchored_menu_test.dart  (181 Z.)
- const: _screen
- `Future<void> _pumpAnchor( WidgetTester tester, { required double keyboardInset, required Alignment anchorAt, int itemCou …)`
- `void main()`

### answer_blocks_test.dart  (284 Z.)
- const: _text _bubble
- `Future<void> _pump( WidgetTester tester, String markdown, { double width = 360, double textScale = 1, })`
- `String _allText(WidgetTester tester)`  — Every RichText's plain text, joined. Finds text inside nested messages.
- `void main()`

### app_lifecycle_observer_test.dart  (43 Z.)
- `void main()`  — `AppLifecycleService.handleLifecycleState` was called by NOBODY in

### app_mode_switch_test.dart  (943 Z.)
- const: kPhone kSwitchOnPhone kWidePhone kPhoneInsets
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _EmptyMirror extends SupabasePairingSync`  — The encrypted mirror, with nothing in it.
  - readEncryptedPairing publishEncryptedPairing saveEncryptedPairing clearEncryptedPairing
- `class _SlowMirror extends _EmptyMirror`  — A mirror whose read answers only when the test says so.
  - readEncryptedPairing
- `class _Session implements AccountSessionSource`
  - current refresh
- `class _FakeChatHalf extends StatefulWidget`  — Stands in for chuk_chat's root wrapper: a top bar shaped like chuk's (a
  - phone modeSwitch onAddComputer
- `class _FakeChatHalfState extends State<_FakeChatHalf>`
  - taps draft
- `void main()`

### app_notification_test.dart  (87 Z.)
- `void main()`

### auth_gate_test.dart  (297 Z.)
- `String _jwt({required int exp})`
- `Session _session({String refresh = 'r1'})`
- `void main()`

### automation_card_test.dart  (120 Z.)
- `AgentsAutomation _automation({ String state = 'active', String kind = 'schedule', int fireCount = 3, String? error, })`
- `Widget _wrap(Widget child)`
- `void main()`

### browser_view_page_test.dart  (203 Z.)
- `class _CountingRelay extends FakeRelayController`  — Counts the view start/stop the page sends the executor.
  - startBrowserView stopBrowserView starts stops lastSessionKey
- `void main()`

### chart_widget_test.dart  (394 Z.)
- `Future<void> _pumpChart(WidgetTester tester, Map<String, dynamic> data)`
- `void main()`

### chat_document_inline_test.dart  (430 Z.)
- `Widget wrap(Widget child)`
- `SandboxArtifactBlock blockFor(Map<String, dynamic> document)`
- `Map<String, dynamic> tableDocument({int rows = 3})`
- `Map<String, dynamic> legacyChartDocument()`  — A chart document as the tool wrote it before the renderer landed: rows of
- `Map<String, dynamic> specChartDocument()`  — A chart document as the tool writes one now: the spec itself, under `chart`.
- `void main()`

### chat_document_reading_test.dart  (417 Z.)
- const: _briefText
- `Map<String, dynamic> _markdownDocument()`
- `Map<String, dynamic> _tableDocument()`
- `Map<String, dynamic> _chartDocument()`
- `void _phone(WidgetTester tester)`  — Puts the tester on a Pixel 7 Pro at [scale], for the lifetime of one test.
- `Widget _host(Widget child, {double scale = 1.0})`
- `Future<void> _open( WidgetTester tester, Map<String, dynamic> document, { double scale = 1.0, })`  — Opens the document the way a reader does — through the dialog, so the test
- `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- `List<String> _pastRightEdge(WidgetTester tester, Finder root)`  — Every box inside [root] that paints past its right edge.
- `void main()`

### chat_document_view_test.dart  (212 Z.)
- `void main()`

### chat_documents_panel_test.dart  (460 Z.)
- const: stamp
- `class _Relay implements AgentsRelayController, AgentsDocumentsControl`
  - requestDocuments requestAgentList send inbound state events requests agentListRequests
- `Map<String, dynamic> doc( String id, int version, { bool full = true, bool dated = false, })`
- `Map<String, dynamic> file(String path, {int? size})`
- `void main()`

### chat_maintenance_gate_test.dart  (164 Z.)
- `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- `void main()`

### chat_mode_selector_test.dart  (474 Z.)
- const: _fireworksLevels
- `Future<void> _pump( WidgetTester tester, { ChatMode mode = ChatMode.thinking, ValueChanged<ChatMode>? onModeChanged, Val …)`
- `void main()`

### chuk_table_golden_test.dart  (323 Z.)
- const: _shots
- `Map<String, dynamic> songs({int rows = 2})`  — The songs table, as the `chat_document` tool stores one: the reel it came
- `Map<String, dynamic> labelledSongs()`  — A table the coworker labelled itself: the cell carries `[label](url)`, so
- `ParsedTable prices()`  — A price comparison — numbers on the right, a highlighted cell, prose in the
- `ParsedTable wideGrid()`  — Seven columns at phone width: the case that has to pan.
- `Future<void> _shoot( WidgetTester tester, Widget child, String name, { Brightness brightness = Brightness.dark, double w …)`
- `void _nothing()`
- `void _open(String href)`
- `Widget inline(Map<String, dynamic> document)`  — The block as the thread draws it, in the bubble it sits in.
- `Widget reader(Map<String, dynamic> document)`  — The reader, as the phone screen shows it minus its floating bar.
- `Widget bare(ParsedTable table, {double fontSize = 13.5})`  — A bare table, the way markdown prose puts one in a bubble.
- `void main()`

### chuk_table_mobile_test.dart  (503 Z.)
- `ParsedTable _prices()`  — Bead cowork-8vqt, then the redesign that followed it.
- `ParsedTable _wide()`  — Seven columns: more than a phone can honestly hold.
- `Widget _wrap(Widget child, double width)`
- `ChukTable _table(ParsedTable table, {ValueChanged<String>? onTapLink})`
- `double _leftOf(WidgetTester tester, String text)`  — The left edge of the first Text painting [text].
- `void main()`
- `void _linkTests()`
- `void _copyControlTests()`

### chuk_table_test.dart  (71 Z.)
- `void main()`

### composer_recording_row_test.dart  (96 Z.)
- `void main()`

### diff_widget_test.dart  (62 Z.)
- `void main()`

### excalidraw_svg_export_test.dart  (62 Z.)
- const: _sampleScene
- `void main()`

### expressive_settings_test.dart  (89 Z.)
- `Widget _host({required Widget child})`
- `void main()`

### flag_off_parity_test.dart  (119 Z.)
- const: _sent
- `Widget _wrap(Widget child)`
- `Widget _turn({bool messengerMode = false})`
- `Iterable<BoxDecoration> _decorations(WidgetTester tester)`  — Every decorated box the bubbles draw, by fill colour.
- `void main()`

### floating_app_bar_test.dart  (66 Z.)
- `void main()`

### html_artifact_view_test.dart  (113 Z.)
- const: _sampleHtml
- `void main()`

### map_block_dedupe_test.dart  (72 Z.)
- `void main()`

### markdown_message_test.dart  (541 Z.)
- const: kAccent kText kBubble
- `ThemeData _theme()`
- `Future<void> _pumpMarkdown( WidgetTester tester, String markdown, { double width = 360, double? fontSize, Color textColo …)`
- `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- `List<TextSpan> _leafSpans(WidgetTester tester)`  — Every leaf `TextSpan` in the widget tree, with its resolved style.
- `TextSpan _span(WidgetTester tester, String text)`  — The leaf span whose text is exactly [text].
- `void main()`

### measure_size_test.dart  (57 Z.)
- `void main()`

### message_bubble_consecutive_tool_groups_test.dart  (96 Z.)
- `void main()`

### message_bubble_dangling_lt_test.dart  (44 Z.)
- `void main()`

### message_bubble_grouping_test.dart  (265 Z.)
- const: full tail gapInRun gapBetweenRuns decoratedBoxes
- `Widget wrap(Widget child)`
- `Widget threeMessageRun({required bool isUser})`  — A run of three messages from the same sender, followed by one message that
- `Rect paintedBubble(WidgetTester tester, int index)`  — The painted rectangle of the bubble at [index] — the decorated box, not the
- `BorderRadius radiusOf(WidgetTester tester, int index)`
- `void main()`

### message_bubble_image_block_test.dart  (35 Z.)
- `void main()`

### message_bubble_live_timer_gap_test.dart  (85 Z.)
- `void main()`

### message_bubble_merge_junk_separated_test.dart  (94 Z.)
- `void main()`

### message_bubble_no_tool_status_test.dart  (62 Z.)
- `void main()`

### message_bubble_pending_image_test.dart  (129 Z.)
- `void main()`

### message_bubble_post_tool_reasoning_test.dart  (97 Z.)
- `void main()`

### message_bubble_sources_test.dart  (88 Z.)
- `void main()`

### message_bubble_test.dart  (242 Z.)
- const: _wakeText _threadKey _chukChatId
- `Widget _wrap(Widget child)`
- `void main()`

### message_bubble_variant_pager_test.dart  (89 Z.)
- `void main()`

### messenger_context_menu_test.dart  (57 Z.)
- `void main()`

### messenger_message_bubble_test.dart  (848 Z.)
- `Widget wrap(Widget child)`
- `void main()`

### messenger_shell_test.dart  (1963 Z.)
- `class _MemoryStore implements AgentsSecureKeyValueStore`
  - read write delete map
- `class _FakeRelayController implements AgentsRelayController`  — A controller the test drives: it can report itself paired, and it records
  - connect reconnect provisionAccount setRoomAgentToAgent sendRoomTask requestRoomHistory deleteRoom renameRoom createAgent renameAgent requestAgentList addRoomMember removeRoomMember sendRunAck startBrowserView stopBrowserView sendBrowserData sendApprovalDecision sendSecrets pair emit state inbound establishedTrust sessionKeys sessionKey roomTasks createdRooms createdRoomPolicies agentToAgentSets agentToAgent historyRequests deletedRooms renamedRooms createdAgents renamedAgents agentListRequests removedMembers
- `class _FakeSessionSource implements AccountSessionSource`
  - current refresh
- `Future<void> settle(WidgetTester tester)`  — Pump a few frames without waiting for the tree to go quiet.
- `void main()`
- `class _CountingReadMarks extends AgentReadMarks`
  - flush flushes
- `class _CountingRoster extends LocalAgentRosterSource`
  - flushPendingPersist flushes

### messenger_typing_indicator_test.dart  (48 Z.)
- `void main()`

### model_logo_test.dart  (113 Z.)
- `void main()`

### room_create_sheet_test.dart  (251 Z.)
- `AgentsAgent _agent(String id, String name, {String? role})`
- `void main()`

### room_faces_test.dart  (365 Z.)
- `AgentsRoomMember _m(String id, String handle)`
- `AgentsRoomDraft _draft(String name, int members)`
- `AgentsAgent _agent(String id, String name)`
- `Future<void> _pumpFaces(WidgetTester tester, int members, double size)`
- `void main()`

### room_list_view_test.dart  (210 Z.)
- `AgentsRoomMember _m(String id, String handle)`
- `AgentsRoomDraft _draft(String name, int members)`
- `void main()`

### room_members_sheet_test.dart  (234 Z.)
- `AgentsRoomMember _m(String id, String h)`
- `AgentsAgent _agent(String id, String name)`
- `AgentsRoom _room(List<AgentsRoomMember> members, {bool agentToAgent = true})`
- `void main()`

### room_mention_picker_test.dart  (347 Z.)
- `MentionToken? tokenAt(String marked)`  — The caret sits where the `|` is; the `|` is removed before the call.
- `AgentsAgent agent(String id, String name, {String? role})`
- `void main()`

### room_thread_page_test.dart  (728 Z.)
- `void main()`
- `class _FakeController implements AgentsRelayController`  — A minimal AgentsRelayController for the rebind test: only [inbound] is real;
  - emit close inbound

### room_thread_view_test.dart  (373 Z.)
- `void main()`

### selection_copy_area_test.dart  (284 Z.)
- `void main()`

### settings_list_view_test.dart  (51 Z.)
- `Widget _host({required List<Widget> children})`
- `void main()`

### turn_status_test.dart  (238 Z.)
- `void main()`

### web_search_sources_test.dart  (40 Z.)
- `void main()`

## test/widgets/charts
### chart_fixtures.dart  (145 Z.)
- const: kSachsenAnhalt kGainsAndLosses kCryptoWeek kMalformed kGrouped kHighReference kGainsAndLossesWithRule

### chart_spec_test.dart  (228 Z.)
- `void main()`

### chart_test_support.dart  (150 Z.)
- const: kChartGoldenDir
- `Future<void> loadChartFonts()`  — Loads Roboto from the SDK so a golden shows real glyphs instead of the
- `Directory? _findMaterialFonts()`
- `ThemeData chartTheme(Brightness brightness)`  — The app's own scheme shape: a neutral seed, so the chart's colours come
- `Future<Finder> pumpChart( WidgetTester tester, Widget chart, { double width = 366, Brightness brightness = Brightness.da …)`  — Pumps [chart] into a bubble-width column on a themed background and
- `Future<void> shootChart( WidgetTester tester, Object? json, String name, { double width = 366, Brightness brightness = B …)`  — Renders [spec] finished (no entrance) and writes `<name>.png`.

### chuk_chart_golden_test.dart  (147 Z.)
- `void main()`

### chuk_chart_test.dart  (416 Z.)
- `void main()`
- `ChukChartPainter _painterOf(WidgetTester tester)`
- `class _Rebuildable extends StatefulWidget`  — A host that rebuilds its chart without changing the spec.
- `class _RebuildableState extends State<_Rebuildable>`
  - bump

### document_chart_golden_test.dart  (190 Z.)
- `Map<String, dynamic> specDocument()`  — A chart document as the `chat_document` tool writes one now: the spec
- `Map<String, dynamic> legacyDocument()`  — A chart document as the tool wrote one before the renderer landed: rows of
- `Future<void> _shoot( WidgetTester tester, Widget child, String name, { Brightness brightness = Brightness.dark, double h …)`  — Shoots [child] on a 360 dp phone column.
- `Widget _inline(Map<String, dynamic> document)`  — The thread block: the bubble, the title, the meta line and the chart.
- `void _nothing()`
- `Widget _reader(Map<String, dynamic> document)`  — The reader, as the phone screen shows it minus its floating bar.
- `void main()`
