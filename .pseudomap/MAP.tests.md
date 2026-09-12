# pseudomap · chuk_chat · Tests

129 Dateien · 224 Typen/Funktionen · 54 Member · Stand 2026-09-12

Diese Datei ist `.pseudomap/MAP.tests.md` — Stufe 1: was es gibt und wo es liegt.

Vor dem Schreiben neuer Funktionen hier nachsehen, ob die Sache schon existiert. Tut sie es, wird sie wiederverwendet statt neu geschrieben.

- Lange Parameterlisten sind hier gekürzt (`…)`). Volle Signaturen mit Zeilennummern stehen in `.pseudomap/detail/<ordner>.md`, Pfad mit `__` statt `/` — `lib/services` liegt in `.pseudomap/detail/lib__services.md`.
- Suche über alles: `pseudomap find <begriff>`.
- Neu bauen: `pseudomap build` (läuft nach jedem Edit automatisch).

## test

### chat_cache_no_eager_full_read_test.dart  (80 Z.)

- `File _lib(String relative)`
- `Iterable<File> _dartFilesIn(String directory)`
- `void main()`

### fastlane_metadata_test.dart  (162 Z.)

- const: `_metadataRoot` `_titleLimit` `_shortDescriptionLimit` `_fullDescriptionLimit` `_changelogLimit` `_minScreenshotSide` `_maxScreenshotSide` `_pngSignature`
- `List<Directory> _locales()`
- `({int width, int height}) _pngSize(File file)`  — Width and height out of a PNG's IHDR chunk, which always starts at byte 16.
- `void main()`

### local_chat_cache_compression_test.dart  (271 Z.)

- `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - getApplicationSupportPath getApplicationDocumentsPath getTemporaryPath dir
- `String _buildPayload({int messages = 6, int resultChars = 20000})`  — A chat payload of roughly [messages] messages carrying a fat tool
- `void main()`

### token_activity_stats_test.dart  (424 Z.)

- `UsageLogEntry _entry(DateTime? createdAt, {int tokens = 10})`  — Minimal usage entry for the stats math: only [createdAt] and the token
- `DateTime _d(int year, int month, int day)`  — A local-date midnight, so tests never depend on the machine timezone.
- `void main()`

### tray_action_bus_test.dart  (30 Z.)

- `void main()`

### verify_languages.dart  (19 Z.)

- `void main()`

## test/assistant

### assistant_microphone_test.dart  (153 Z.)

- const: `_frame`
- `Uint8List _chunk({required double amplitude, Duration length = _frame})`  — One chunk of PCM16 at the given amplitude (0..1), as a 400 Hz tone so the
- `void _feed( AssistantMicrophone mic, { required double amplitude, required Duration total, })`
- `void main()`

### assistant_overlay_test.dart  (297 Z.)

- const: `_accent` `_bg`
- `Widget _host(Widget child)`
- `void main()`

### assistant_tools_test.dart  (145 Z.)

- `void main()`

## test/chat

### worked_for_stamp_test.dart  (109 Z.)

- `Map<String, String> _assistant({String? startedAt, String? generationMs})`
- `void main()`

## test/helpers

### icon_finder.dart  (25 Z.)

- `Finder findIcon(IconData icon)`  — Finds an icon whichever widget draws it.
- `Finder findWidgetWithIcon(Type type, IconData icon)`  — [find.widgetWithIcon] for the same reason.

## test/mcp

### mcp_apikey_test.dart  (69 Z.)

- `void main()`

### mcp_awareness_test.dart  (169 Z.)

- `McpConnection _connection(String id)`
- `void main()`

### mcp_bundled_icons_test.dart  (121 Z.)

- const: `_pngMagic`
- `void main()`

### mcp_catalogue_test.dart  (306 Z.)

- `void main()`

### mcp_client_test.dart  (208 Z.)

- `http.Response _json(Object body, {Map<String, String> headers = const {}})`
- `void main()`

### mcp_connect_cancel_test.dart  (104 Z.)

- `void main()`

### mcp_endpoints_live_test.dart  (151 Z.)

- const: `_live`
- `class _Probe`  — What a live probe found out about one server.
  - open challenge
- `Future<_Probe> _probe(String url, http.Client client)`
- `void main()`

### mcp_first_party_test.dart  (131 Z.)

- `void main()`

### mcp_legal_links_live_test.dart  (102 Z.)

- const: `_live` `_userAgent`
- `Future<int> _statusOf(String url)`
- `void main()`

### mcp_oauth_test.dart  (341 Z.)

- const: `_issuer`
- `http.Response _json(Object body)`
- `MockClient _server({bool withRegistration = true})`
- `void main()`

### mcp_sync_service_test.dart  (410 Z.)

- `McpSyncBlob _remoteBlob(String id, {String? accessToken, McpAuth auth = McpAuth.oauth})`
- `void main()`

## test/models

### chat_message_test.dart  (305 Z.)

- `void main()`

### chat_model_test.dart  (234 Z.)

- `void main()`

### chat_stream_event_test.dart  (163 Z.)

- `void main()`

### content_block_test.dart  (198 Z.)

- `void main()`

### stored_chat_test.dart  (314 Z.)

- `void main()`

### workspace_model_test.dart  (497 Z.)

- `void main()`

## test/pages

### skills_settings_page_test.dart  (205 Z.)

- const: `_userSkill`
- `Widget _host(Widget child)`
- `void main()`

### theme_page_test.dart  (158 Z.)

- `class _State`
  - themeMode accent iconFg bg contrast uiFont chatFont dynamicColor
- `AppShellConfig _config(_State s)`
- `Widget _host(AppShellConfig config)`
- `void main()`

## test/platform_specific

### sidebar_blocks_test.dart  (467 Z.)

- `DateTime _localMidnight()`  — Midnight at the start of the current local day — the anchor every seeded
- `void _seedChats()`  — Seeds the store the sidebars read from. Returns nothing — the sidebars
- `StoredChat _seedChat({ required String id, required DateTime at, required String title, bool starred = false, })`
- `Widget _host(Widget child)`
- `void _tallWindow(WidgetTester tester)`  — Gives the test a window tall enough that a whole sidebar — account card,
- `Future<void> _settleStartupWork(WidgetTester tester)`  — The background update check starts a 5 s timeout timer. Tearing the tree
- `void main()`

## test/platform_specific/chat

### chat_scroll_mixin_test.dart  (194 Z.)

- `void main()`  — Auto-scroll during streaming.
- `Matcher moveTo(double target)`  — `pixels` lands on the extent within a sub-pixel of it.
- `class _Harness extends StatefulWidget`
  - initialRows
- `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - streamOneMoreRow jumpToEnd rows

### chat_ui_helpers_test.dart  (438 Z.)

- `void main()`

### regen_variant_seed_test.dart  (187 Z.)

- `class _Host extends StatefulWidget`
- `class _HostState extends State<_Host> with RegenVariantSeedMixin<_Host>`
  - variantActiveChatId activeChat
- `Future<_HostState> _pump(WidgetTester tester)`
- `List<Map<String, dynamic>> _seed()`
- `void main()`

## test/services

### app_theme_contrast_uifont_test.dart  (94 Z.)

- `void main()`

### app_theme_service_dynamic_color_test.dart  (155 Z.)

- `ColorScheme _schemeWithPrimary(Color primary, Brightness brightness)`
- `void main()`

### artifact_diff_engine_test.dart  (102 Z.)

- `void main()`

### artifact_repair_version_chain_test.dart  (33 Z.)

- `void main()`

### artifact_rollback_test.dart  (560 Z.)

- `void main()`

### artifact_storage_pending_flushers_test.dart  (112 Z.)

- `void main()`

### bash_sandbox_folder_test.dart  (105 Z.)

- `void main()`

### chat_history_builder_test.dart  (273 Z.)

- `void main()`  — The outgoing payload is `{message: <current turn>, history: [...]}` and the

### chat_mode_config_test.dart  (413 Z.)

- `void main()`

### chat_runtime_test.dart  (182 Z.)

- `void main()`

### encryption_service_test.dart  (702 Z.)

- `void main()`  — Tests for the core AES-GCM encryption logic used by EncryptionService.
- `int? _extractKeyVersion(String encrypted)`  — Mirror of EncryptionService.extractKeyVersion for testing

### file_conversion_page_images_test.dart  (103 Z.)

- `void main()`  — A scanned PDF has no text layer, so the API returns its pages as image

### image_compression_service_test.dart  (228 Z.)

- `void main()`

### message_composition_service_test.dart  (69 Z.)

- `void main()`

### network_status_service_test.dart  (124 Z.)

- `void main()`

### oauth_loopback_server_test.dart  (118 Z.)

- const: `_theme`
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

### sandbox_infra_breaker_test.dart  (123 Z.)

- `void main()`

### streaming_manager_test.dart  (585 Z.)

- `void main()`
- `class _TestStreamContext`  — Helper class to hold test stream state
  - controller getContent getReasoning getTps isCompleted getError

### tool_call_handler_deferred_action_test.dart  (281 Z.)

- `void main()`

### tool_call_handler_fact_check_test.dart  (193 Z.)

- `void main()`

### tool_call_handler_safety_limit_test.dart  (150 Z.)

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

- const: `_skillToolDef` `_tools` `_testSkill`
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

## test/services/skills

### builtin_skills_freshness_test.dart  (49 Z.)

- `void main()`  — The gate that makes build-time codegen safe.

### builtin_skills_validity_test.dart  (132 Z.)

- const: `_kMaxBodyTokens`
- `void main()`

### skill_frontmatter_parser_test.dart  (367 Z.)

- const: `_minimal`
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

## test/support

### kv_cache_test_env.dart  (54 Z.)

- `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - getApplicationSupportPath getApplicationDocumentsPath getTemporaryPath dir
- `void initSqfliteFfi()`  — Initialise the sqflite FFI backend once. Safe to call repeatedly.
- `Future<Directory> useTempKvCache()`  — Point LocalChatCacheService's SQLite DB at a fresh temp dir and drop any
- `Future<void> disposeTempKvCache(Directory tempDir)`  — Drop the cached DB handle and remove [tempDir]. Call from tearDown.

## test/theme

### theme_presets_test.dart  (194 Z.)

- const: `_preset`
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

### weather_tools_test.dart  (157 Z.)

- `void main()`

## test/utils

### accent_button_foreground_test.dart  (69 Z.)

- `double contrast(Color a, Color b)`
- `void main()`

### api_rate_limiter_test.dart  (263 Z.)

- `void main()`

### artifact_tag_parser_test.dart  (208 Z.)

- `void main()`

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

### input_validator_test.dart  (314 Z.)

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

## test/widgets

### agent_activity_timeline_test.dart  (679 Z.)

- const: `_t0`
- `ToolCall _call( String name, { Map<String, dynamic> arguments = const {}, ToolCallStatus status = ToolCallStatus.complet …)`
- `Future<void> _pumpTimeline( WidgetTester tester, { required List<ToolCall> calls, bool isRunning = false, DateTime? now …)`
- `void main()`

### anchored_menu_test.dart  (181 Z.)

- const: `_screen`
- `Future<void> _pumpAnchor( WidgetTester tester, { required double keyboardInset, required Alignment anchorAt, int itemCou …)`
- `void main()`

### app_notification_test.dart  (87 Z.)

- `void main()`

### chat_mode_selector_test.dart  (400 Z.)

- const: `_fireworksLevels`
- `Future<void> _pump( WidgetTester tester, { ChatMode mode = ChatMode.thinking, ValueChanged<ChatMode>? onModeChanged, Val …)`
- `void main()`

### chuk_table_test.dart  (71 Z.)

- `void main()`

### composer_recording_row_test.dart  (96 Z.)

- `void main()`

### diff_widget_test.dart  (62 Z.)

- `void main()`

### excalidraw_svg_export_test.dart  (62 Z.)

- const: `_sampleScene`
- `void main()`

### floating_app_bar_test.dart  (66 Z.)

- `void main()`

### html_artifact_view_test.dart  (113 Z.)

- const: `_sampleHtml`
- `void main()`

### map_block_dedupe_test.dart  (72 Z.)

- `void main()`

### markdown_message_test.dart  (60 Z.)

- `void main()`

### measure_size_test.dart  (57 Z.)

- `void main()`

### message_bubble_consecutive_tool_groups_test.dart  (96 Z.)

- `void main()`

### message_bubble_dangling_lt_test.dart  (44 Z.)

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

### message_bubble_variant_pager_test.dart  (89 Z.)

- `void main()`

### selection_copy_area_test.dart  (284 Z.)

- `void main()`

### settings_kit_test.dart  (106 Z.)

- `Widget _host(Widget child)`
- `void main()`

### web_search_sources_test.dart  (40 Z.)

- `void main()`
