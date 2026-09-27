# test/widgets · Signaturen

## test/widgets/agent_activity_timeline_test.dart  (679 Z.)
- L15 `_t0 = DateTime.utc(2026, 8, 13, 10, 0, 0)`
- L17 `ToolCall _call( String name, { Map<String, dynamic> arguments = const {}, ToolCallStatus status = ToolCallStatus.completed, int startSecond = 0, int? endSecond, String? roundThinking, })`
- L37 `Future<void> _pumpTimeline( WidgetTester tester, { required List<ToolCall> calls, bool isRunning = false, DateTime? now, bool? initiallyExpanded, void Function(ToolCall)? onStepTap, void Function(AgentActivitySource)? onSourceTap, StreamPhase? phase, DateTime? startedAt, Duration? finalDuration, })`
- L68 `void main()`

## test/widgets/agent_chart_blocks_test.dart  (118 Z.)
- L7 `_electionChart = ''' Stand 22:25 Uhr. <chart> {"title":"Zweitstimmen","rows":[{"label":"AfD","value":44.8,"color":"#80cd`
- L21 `void main()`

## test/widgets/agent_control_panel_test.dart  (241 Z.)
- L9 `AgentsAgent _agent({bool onHost = true})`
- L19 `Future<void> _pump( WidgetTester tester, AgentControlSource source, { AgentsAgent? agent, })`
- L34 `_fullSnapshot = AgentControlSnapshot( model: ControlAvailable<AgentModelChoice>( AgentModelChoice( id: 'anthropic/claude`
- L65 `void main()`
- L222 `class _ThrowingControlSource implements AgentControlSource`  — Wraps a source and refuses the skill toggle, to prove the failure surfaces.
  - L223 `_ThrowingControlSource(this._inner)`
  - L224 `final AgentControlSource _inner`
  - L227 `ValueListenable<AgentControlSnapshot> snapshotFor(String sessionKey)`
  - L231 `Future<void> refresh(String sessionKey)`
  - L234 `Future<void> setSkillEnabled(String skillName, {required bool enabled})`
  - L239 `void dispose()`

## test/widgets/agent_face_test.dart  (91 Z.)
- L10 `void main()`

## test/widgets/agent_markdown_test.dart  (56 Z.)
- L6 `Widget _host(Widget child, {Brightness brightness = Brightness.light})`
- L13 `void main()`

## test/widgets/agent_roster_view_test.dart  (863 Z.)
- L22 `void main()`

## test/widgets/agent_run_views_test.dart  (288 Z.)
- L14 `_pngBytes = base64.decode( 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842' 'iQAAAABJRU5Er`  — A 1x1 transparent PNG — the smallest real image to prove a preview renders.
- L19 `class _RecordingSaver implements AgentFileSaver`
  - L20 `final List<String> saved = <String>[]`
  - L21 `Object? failWith`
  - L24 `Future<String> save(AgentsRelayFile file)`
- L32 `Widget _host(Widget child)`
- L36 `void main()`

## test/widgets/agents_cold_start_test.dart  (398 Z.)
- L39 `class _NoopSaver implements AgentFileSaver`
  - L41 `Future<String> save(AgentsRelayFile file)`
- L44 `class _FakeSessionSource implements AccountSessionSource`
  - L45 `const _FakeSessionSource()`
  - L48 `AccountSession? current()`
  - L51 `Future<AccountSession?> refresh()`
- L56 `class _FakeDisk`  — The local cache, as a map. It outlives [AgentsChatStore.reset] on purpose:
  - L57 `final Map<String, Map<String, dynamic>> rows = <String, Map<String, dynamic>>{}`
  - L59 `final Map<String, String> kv = <String, String>{}`
  - L63 `void install()`  — Points the store at this map. Called again after every reset, because
- L80 `Widget _app(Widget child)`
- L91 `void main()`
- L348 `Future<void> _drainNotifyDebounce()`  — `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
- L356 `Future<void> _releaseIdleTimers(WidgetTester tester)`  — The imported chat screen opens a multiplex session on mount and arms a
- L370 `void _silenceUnrelatedPlugins(WidgetTester tester)`  — The imported screen constructs an [AudioRecorder] on mount, which calls the
- L387 `Future<void> _settle(WidgetTester tester)`  — [WidgetTester.pumpAndSettle] never returns here: the thread view arms an
- L397 `_guard = Timeout(Duration(seconds: 60))`  — A wall-clock guard on every test in this file. Nothing here should take

## test/widgets/agents_desktop_controls_test.dart  (176 Z.)
- L12 `Widget _app(Widget child)`
- L16 `void main()`

## test/widgets/agents_desktop_shell_test.dart  (513 Z.)
- L31 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L32 `final Map<String, String> map = <String, String>{}`
  - L34 `Future<String?> read(String key)`
  - L36 `Future<void> write(String key, String value)`
  - L38 `Future<void> delete(String key)`
- L42 `class _FailingRefreshSource extends FakeAgentControlSource`  — A host that answers the panel's first look and then fails a refresh.
  - L43 `bool failNext = false`
  - L46 `Future<void> refresh(String sessionKey)`
- L52 `class _Session implements AccountSessionSource`
  - L53 `const _Session()`
  - L55 `AccountSession? current()`
  - L61 `Future<AccountSession?> refresh()`
- L64 `void main()`

## test/widgets/agents_shell_states_test.dart  (327 Z.)
- L37 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L38 `final Map<String, String> map = <String, String>{}`
  - L41 `Future<String?> read(String key)`
  - L44 `Future<void> write(String key, String value)`
  - L47 `Future<void> delete(String key)`
- L51 `class _Mirror extends SupabasePairingSync`  — The encrypted mirror, answering one scripted outcome.
  - L52 `_Mirror(this.outcome)`
  - L54 `final AgentsCloudPairingOutcome outcome`
  - L57 `Future<AgentsCloudPairingRead> readEncryptedPairing()`
  - L61 `Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing)`
  - L65 `Future<void> saveEncryptedPairing(AgentsStoredPairing pairing)`
  - L68 `Future<void> clearEncryptedPairing()`
- L71 `class _Session implements AccountSessionSource`
  - L72 `const _Session({this.signedIn = true})`
  - L74 `final bool signedIn`
  - L77 `AccountSession? current()`
  - L86 `Future<AccountSession?> refresh()`
- L90 `class _HangingController extends FakeRelayController`  — A reconnect that never finishes: the link stays "connecting".
  - L92 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
- L99 `class _EmptyHostRoster extends LocalAgentRosterSource`  — A host that lists no agents: pairing does not bring a host coworker.
  - L101 `AgentsAgent ensureHostAgent(String peerDeviceId)`
- L109 `kDesktop = Size(1340, 818)`
- L110 `kPhone = Size(412, 915)`
- L112 `void main()`

## test/widgets/agents_thread_header_test.dart  (258 Z.)
- L12 `Widget _wrap(Widget child, {double width = 900})`  — The header only ever gets the width its parent has, so every test states
- L21 `AgentsThreadAction _action(String tooltip, List<String> log)`
- L28 `void main()`

## test/widgets/agents_thread_view_notifications_test.dart  (201 Z.)
- L35 `class _FakeSessionSource implements AccountSessionSource`
  - L36 `const _FakeSessionSource()`
  - L39 `AccountSession? current()`
  - L46 `Future<AccountSession?> refresh()`
- L49 `class _NoopSaver implements AgentFileSaver`
  - L51 `Future<String> save(AgentsRelayFile file)`
- L54 `Widget _app(Widget child)`
- L65 `void main()`

## test/widgets/agents_thread_view_secrets_test.dart  (240 Z.)
- L28 `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the stores round-trip with no platform channel.
  - L29 `final Map<String, String> map = <String, String>{}`
  - L32 `Future<String?> read(String key)`
  - L35 `Future<void> write(String key, String value)`
  - L38 `Future<void> delete(String key)`
- L41 `class _NoopSaver implements AgentFileSaver`
  - L43 `Future<String> save(AgentsRelayFile file)`
- L46 `class _FakeSessionSource implements AccountSessionSource`
  - L47 `const _FakeSessionSource()`
  - L50 `AccountSession? current()`
  - L57 `Future<AccountSession?> refresh()`
- L60 `Widget _app(Widget child)`
- L77 `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — The `secret_request` card (docs/WIRE_CONTRACT.md, "Secrets"): one field
- L82 `String _j(Map<String, String> m)`
- L84 `void main()`

## test/widgets/agents_thread_view_stopped_run_test.dart  (174 Z.)
- L20 `class _NoopSaver implements AgentFileSaver`
  - L22 `Future<String> save(AgentsRelayFile file)`
- L25 `class _FakeSessionSource implements AccountSessionSource`
  - L26 `const _FakeSessionSource()`
  - L29 `AccountSession? current()`
  - L36 `Future<AccountSession?> refresh()`
- L39 `Widget _app(Widget child)`
- L53 `void main()`  — The visible run must end when the host says the run ended, whatever else the

## test/widgets/agents_thread_view_test.dart  (1478 Z.)
- L41 `class _MemoryStore implements AgentsSecureKeyValueStore`  — In-memory secure backend so the store round-trips with no platform channel.
  - L42 `final Map<String, String> map = <String, String>{}`
  - L45 `Future<String?> read(String key)`
  - L48 `Future<void> write(String key, String value)`
  - L51 `Future<void> delete(String key)`
- L55 `class _NoopSaver implements AgentFileSaver`  — A saver that never touches a filesystem.
  - L57 `Future<String> save(AgentsRelayFile file)`
- L60 `class _FakeSessionSource implements AccountSessionSource`
  - L61 `const _FakeSessionSource()`
  - L64 `AccountSession? current()`
  - L71 `Future<AccountSession?> refresh()`
- L76 `Widget _app(Widget child)`  — The app shell the imported chat screen expects around it: localisations and
- L87 `void main()`
- L1474 `Future<void> _flushIdleTimers(WidgetTester tester)`  — The imported chat screen schedules a 60 s idle-close timer for its

## test/widgets/anchored_menu_test.dart  (181 Z.)
- L9 `_screen = Size(400, 800)`
- L11 `Future<void> _pumpAnchor( WidgetTester tester, { required double keyboardInset, required Alignment anchorAt, int itemCount = 3, bool preferAbove = false, })`
- L63 `void main()`

## test/widgets/answer_blocks_test.dart  (284 Z.)
- L10 `_text = Color(0xFF111111)`
- L11 `_bubble = Color(0xFFFFFFFF)`
- L13 `Future<void> _pump( WidgetTester tester, String markdown, { double width = 360, double textScale = 1, })`
- L48 `String _allText(WidgetTester tester)`  — Every RichText's plain text, joined. Finds text inside nested messages.
- L53 `void main()`

## test/widgets/app_lifecycle_observer_test.dart  (43 Z.)
- L9 `void main()`  — `AppLifecycleService.handleLifecycleState` was called by NOBODY in

## test/widgets/app_notification_test.dart  (87 Z.)
- L8 `void main()`

## test/widgets/auth_gate_test.dart  (297 Z.)
- L13 `String _jwt({required int exp})`
- L20 `Session _session({String refresh = 'r1'})`
- L33 `void main()`

## test/widgets/automation_card_test.dart  (120 Z.)
- L9 `AgentsAutomation _automation({ String state = 'active', String kind = 'schedule', int fireCount = 3, String? error, })`
- L29 `Widget _wrap(Widget child)`
- L31 `void main()`

## test/widgets/browser_view_page_test.dart  (203 Z.)
- L13 `class _CountingRelay extends FakeRelayController`  — Counts the view start/stop the page sends the executor.
  - L14 `int starts = 0`
  - L15 `int stops = 0`
  - L18 `Future<void> startBrowserView({String? sessionKey})`
  - L23 `String? lastSessionKey`
  - L26 `Future<void> stopBrowserView()`
- L29 `void main()`

## test/widgets/chart_widget_test.dart  (394 Z.)
- L6 `Future<void> _pumpChart(WidgetTester tester, Map<String, dynamic> data)`
- L17 `void main()`

## test/widgets/chat_document_inline_test.dart  (430 Z.)
- L19 `Widget wrap(Widget child)`
- L25 `SandboxArtifactBlock blockFor(Map<String, dynamic> document)`
- L36 `Map<String, dynamic> tableDocument({int rows = 3})`
- L50 `Map<String, dynamic> legacyChartDocument()`  — A chart document as the tool wrote it before the renderer landed: rows of
- L62 `Map<String, dynamic> specChartDocument()`  — A chart document as the tool writes one now: the spec itself, under `chart`.
- L93 `void main()`

## test/widgets/chat_document_reading_test.dart  (415 Z.)
- L26 `_briefText = ''' # Wahlradar Ein eigener Beobachter für die **Landtagswahl Sachsen-Anhalt 2026** — läuft. - **Quelle:** `  — A saved document has to read like a document on the phone it is read on.
- L47 `Map<String, dynamic> _markdownDocument()`
- L55 `Map<String, dynamic> _tableDocument()`
- L78 `Map<String, dynamic> _chartDocument()`
- L98 `void _phone(WidgetTester tester)`  — Puts the tester on a Pixel 7 Pro at [scale], for the lifetime of one test.
- L104 `Widget _host(Widget child, {double scale = 1.0})`
- L114 `Future<void> _open( WidgetTester tester, Map<String, dynamic> document, { double scale = 1.0, })`  — Opens the document the way a reader does — through the dialog, so the test
- L141 `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- L152 `List<String> _pastRightEdge(WidgetTester tester, Finder root)`  — Every box inside [root] that paints past its right edge.
- L196 `void main()`

## test/widgets/chat_document_view_test.dart  (212 Z.)
- L9 `void main()`

## test/widgets/chat_documents_panel_test.dart  (460 Z.)
- L12 `class _Relay implements AgentsRelayController, AgentsDocumentsControl`
  - L14 `final ValueNotifier<AgentsRelayState> state = ValueNotifier( const AgentsRelayState(phase: AgentsRelayPhase.paired), )`
  - L17 `final events = StreamController<AgentsRelayInbound>.broadcast(sync: true)`
  - L19 `Stream<AgentsRelayInbound> get inbound`
  - L20 `final requests = <String?>[]`
  - L21 `int agentListRequests = 0`
  - L23 `Future<void> requestDocuments(String sessionKey, {String? id})`
  - L26 `Future<void> requestAgentList()`
  - L28 `dynamic noSuchMethod(Invocation invocation)`
  - L29 `void send(Map<String, dynamic> payload)`
- L36 `stamp = DateTime(2026, 1, 5, 14, 3)`  — A fixed, deliberately-not-today stamp: the freshness line then renders its
- L38 `Map<String, dynamic> doc( String id, int version, { bool full = true, bool dated = false, })`
- L57 `Map<String, dynamic> file(String path, {int? size})`
- L66 `void main()`

## test/widgets/chat_maintenance_gate_test.dart  (164 Z.)
- L18 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L30 `void main()`

## test/widgets/chat_mode_selector_test.dart  (474 Z.)
- L22 `_fireworksLevels = <String>['none', 'low', 'high']`
- L24 `Future<void> _pump( WidgetTester tester, { ChatMode mode = ChatMode.thinking, ValueChanged<ChatMode>? onModeChanged, ValueChanged<String>? onModelSelected, String reasoningEffort = 'none', List<String> reasoningLevels = _fireworksLevels, ValueChanged<String>? onReasoningEffortChanged, VoidCallback? onOpenModelScreen, String? selectedModelId, String? modelLabel, List<ChatModelChoice> pickedModels = const <ChatModelChoice>[], })`
- L59 `void main()`

## test/widgets/chuk_table_golden_test.dart  (323 Z.)
- L28 `_shots = 'goldens/chuk_table'`  — Where the shots land: committed next to this file (relative to
- L32 `Map<String, dynamic> songs({int rows = 2})`  — The songs table, as the `chat_document` tool stores one: the reel it came
- L104 `Map<String, dynamic> labelledSongs()`  — A table the coworker labelled itself: the cell carries `[label](url)`, so
- L115 `ParsedTable prices()`  — A price comparison — numbers on the right, a highlighted cell, prose in the
- L134 `ParsedTable wideGrid()`  — Seven columns at phone width: the case that has to pan.
- L161 `Future<void> _shoot( WidgetTester tester, Widget child, String name, { Brightness brightness = Brightness.dark, double width = 360, double height = 620, double textScale = 1.0, })`
- L204 `void _nothing()`
- L205 `void _open(String href)`
- L208 `Widget inline(Map<String, dynamic> document)`  — The block as the thread draws it, in the bubble it sits in.
- L216 `Widget reader(Map<String, dynamic> document)`  — The reader, as the phone screen shows it minus its floating bar.
- L222 `Widget bare(ParsedTable table, {double fontSize = 13.5})`  — A bare table, the way markdown prose puts one in a bubble.
- L241 `void main()`

## test/widgets/chuk_table_mobile_test.dart  (503 Z.)
- L22 `ParsedTable _prices()`  — Bead cowork-8vqt, then the redesign that followed it.
- L37 `ParsedTable _wide()`  — Seven columns: more than a phone can honestly hold.
- L54 `Widget _wrap(Widget child, double width)`
- L62 `ChukTable _table(ParsedTable table, {ValueChanged<String>? onTapLink})`
- L71 `double _leftOf(WidgetTester tester, String text)`  — The left edge of the first Text painting [text].
- L74 `void main()`
- L220 `void _linkTests()`
- L367 `void _copyControlTests()`

## test/widgets/chuk_table_test.dart  (71 Z.)
- L5 `void main()`

## test/widgets/composer_recording_row_test.dart  (96 Z.)
- L15 `void main()`

## test/widgets/diff_widget_test.dart  (62 Z.)
- L6 `void main()`

## test/widgets/excalidraw_svg_export_test.dart  (62 Z.)
- L5 `_sampleScene = ''' { "type": "excalidraw", "version": 2, "source": "https://excalidraw.com", "elements": [ {"type":"rect`
- L29 `void main()`

## test/widgets/expressive_settings_test.dart  (189 Z.)
- L9 `double _tileScale(WidgetTester tester)`  — The scale [MorphTap] currently applies to the tile.
- L20 `Widget _host({required Widget child, bool reducedMotion = false})`
- L29 `void main()`

## test/widgets/flag_off_parity_test.dart  (122 Z.)
- L21 `Widget _wrap(Widget child)`
- L34 `_sent = DateTime(2026, 9, 22, 14, 5)`
- L36 `Widget _turn()`
- L61 `Iterable<BoxDecoration> _decorations(WidgetTester tester)`  — Every decorated box the bubbles draw, by fill colour.
- L71 `void main()`

## test/widgets/floating_app_bar_test.dart  (66 Z.)
- L7 `void main()`

## test/widgets/html_artifact_view_test.dart  (113 Z.)
- L7 `_sampleHtml = ''' <!doctype html> <html><head><meta charset="utf-8"><title>Demo</title></head> <body><h1>Hello</h1><p>Pa`
- L13 `void main()`

## test/widgets/map_block_dedupe_test.dart  (72 Z.)
- L5 `void main()`

## test/widgets/markdown_message_test.dart  (581 Z.)
- L19 `kAccent = Color(0xFF1565C0)`
- L20 `kText = Color(0xFF111111)`
- L21 `kBubble = Color(0xFFFFFFFF)`
- L23 `ThemeData _theme()`
- L31 `Future<void> _pumpMarkdown( WidgetTester tester, String markdown, { double width = 360, double? fontSize, Color textColor = kText, })`
- L63 `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- L70 `List<TextSpan> _leafSpans(WidgetTester tester)`  — Every leaf `TextSpan` in the widget tree, with its resolved style.
- L89 `TextSpan _span(WidgetTester tester, String text)`  — The leaf span whose text is exactly [text].
- L97 `void main()`

## test/widgets/measure_size_test.dart  (57 Z.)
- L5 `void main()`

## test/widgets/message_bubble_consecutive_tool_groups_test.dart  (96 Z.)
- L9 `void main()`

## test/widgets/message_bubble_dangling_lt_test.dart  (44 Z.)
- L7 `void main()`

## test/widgets/message_bubble_grouping_test.dart  (284 Z.)
- L23 `big = Radius.circular(kBubbleRadiusBig)`
- L24 `small = Radius.circular(kBubbleRadiusSmall)`
- L26 `Widget wrap(Widget child)`
- L41 `Widget threeMessageRun({required bool isUser})`  — A run of three messages from the same sender, followed by one message that
- L62 `Rect paintedBubble(WidgetTester tester, int index)`  — The painted rectangle of the bubble at [index] — the decorated box, not the
- L75 `BorderRadius radiusOf(WidgetTester tester, int index)`
- L85 `void main()`

## test/widgets/message_bubble_image_block_test.dart  (35 Z.)
- L5 `void main()`

## test/widgets/message_bubble_live_timer_gap_test.dart  (85 Z.)
- L7 `void main()`

## test/widgets/message_bubble_merge_junk_separated_test.dart  (94 Z.)
- L8 `void main()`

## test/widgets/message_bubble_no_tool_status_test.dart  (62 Z.)
- L6 `void main()`

## test/widgets/message_bubble_pending_image_test.dart  (129 Z.)
- L7 `void main()`

## test/widgets/message_bubble_post_tool_reasoning_test.dart  (97 Z.)
- L7 `void main()`

## test/widgets/message_bubble_sources_test.dart  (88 Z.)
- L7 `void main()`

## test/widgets/message_bubble_test.dart  (273 Z.)
- L19 `_wakeText = '[automation a2f1d3d1 fired: Wahlradar LT Sachsen-Anhalt 2026]\n' 'check the seat projection and tell me wha`  — The exact text the host submits when an automation fires, header +
- L25 `Widget _wrap(Widget child)`
- L36 `void main()`

## test/widgets/message_bubble_variant_pager_test.dart  (89 Z.)
- L7 `void main()`

## test/widgets/messenger_context_menu_test.dart  (71 Z.)
- L6 `void main()`

## test/widgets/messenger_message_bubble_test.dart  (836 Z.)
- L20 `Widget wrap(Widget child)`
- L31 `void main()`

## test/widgets/messenger_shell_test.dart  (1981 Z.)
- L51 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L52 `final Map<String, String> map = <String, String>{}`
  - L55 `Future<String?> read(String key)`
  - L58 `Future<void> write(String key, String value)`
  - L61 `Future<void> delete(String key)`
- L66 `class _FakeRelayController implements AgentsRelayController`  — A controller the test drives: it can report itself paired, and it records
  - L67 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L71 `final StreamController<AgentsRelayInbound> _inbound = StreamController<AgentsRelayInbound>.broadcast()`
  - L74 `final List<String> sessionKeys = <String>[]`
  - L77 `ValueListenable<AgentsRelayState> get state`
  - L80 `Stream<AgentsRelayInbound> get inbound`
  - L83 `Future<void> connect({ required Uri hostUrl, required String pairingCode, })`
  - L89 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
  - L97 `AgentsStoredPairing? get establishedTrust`
  - L100 `Future<void> provisionAccount(AccountSession session)`
  - L103 `Future<void> sendTask( String prompt, { String sessionKey = 'default', String? modelId, String? providerSlug, String? reasoningEffort, bool debug = false, bool regenerate = false, String? taskId, })`
  - L114 `final List<(String, String)> roomTasks = <(String, String)>[]`
  - L115 `final List<String> createdRooms = <String>[]`
  - L116 `final List<bool> createdRoomPolicies = <bool>[]`
  - L117 `final List<(String, bool)> agentToAgentSets = <(String, bool)>[]`
  - L120 `Future<void> createRoom( String roomId, String name, List<Map<String, String>> members, { bool agentToAgent = true, })`
  - L131 `Future<void> setRoomAgentToAgent(String roomId, bool enabled)`
  - L135 `Future<void> sendRoomTask(String roomId, String message)`
  - L138 `final List<String> historyRequests = <String>[]`
  - L139 `final List<String> deletedRooms = <String>[]`
  - L142 `Future<void> requestRoomHistory(String roomId)`
  - L146 `Future<void> deleteRoom(String roomId)`
  - L148 `final List<(String, String)> renamedRooms = <(String, String)>[]`
  - L151 `Future<void> renameRoom(String roomId, String name)`
  - L154 `final List<(String, String)> createdAgents = <(String, String)>[]`
  - L155 `final List<(String, String)> renamedAgents = <(String, String)>[]`
  - L158 `Future<void> createAgent(String agentId, String name)`
  - L162 `Future<void> renameAgent(String agentId, String name)`
  - L165 `int agentListRequests = 0`
  - L168 `Future<void> requestAgentList()`
  - L170 `final List<(String, String)> removedMembers = <(String, String)>[]`
  - L173 `Future<void> addRoomMember( String roomId, String agentId, String handle, )`
  - L180 `Future<void> removeRoomMember(String roomId, String agentId)`
  - L184 `Future<void> requestStop({String sessionKey = 'default'})`
  - L187 `Future<void> requestReplay({ String sessionKey = 'default', int afterId = 0, int beforeId = 0, int limit = 0, })`
  - L195 `Future<void> sendRunAck(String runId)`
  - L198 `Future<void> startBrowserView({String? sessionKey})`
  - L201 `Future<void> stopBrowserView()`
  - L204 `Future<void> sendBrowserData(Uint8List bytes)`
  - L207 `Future<void> sendApprovalDecision({ required String approvalId, required bool approved, })`
  - L213 `Future<void> sendSecrets({ required Map<String, String> values, required int revision, String? requestId, })`
  - L220 `Future<void> dispose()`
  - L225 `void pair()`
  - L230 `void emit(AgentsRelayInbound event)`
- L233 `class _FakeSessionSource implements AccountSessionSource`
  - L234 `const _FakeSessionSource()`
  - L237 `AccountSession? current()`
  - L244 `Future<AccountSession?> refresh()`
- L253 `Future<void> settle(WidgetTester tester)`  — Pump a few frames without waiting for the tree to go quiet.
- L259 `void main()`
- L1962 `class _CountingReadMarks extends AgentReadMarks`
  - L1963 `int flushes = 0`
  - L1966 `Future<void> flush()`
- L1972 `class _CountingRoster extends LocalAgentRosterSource`
  - L1973 `int flushes = 0`
  - L1976 `void flushPendingPersist()`

## test/widgets/messenger_typing_indicator_test.dart  (48 Z.)
- L5 `void main()`

## test/widgets/model_logo_test.dart  (113 Z.)
- L12 `void main()`

## test/widgets/room_create_sheet_test.dart  (251 Z.)
- L8 `AgentsAgent _agent(String id, String name, {String? role})`
- L15 `void main()`

## test/widgets/room_faces_test.dart  (369 Z.)
- L21 `AgentsRoomMember _m(String id, String handle)`
- L24 `AgentsRoomDraft _draft(String name, int members)`
- L31 `AgentsAgent _agent(String id, String name)`
- L37 `Future<void> _pumpFaces(WidgetTester tester, int members, double size)`
- L49 `void main()`

## test/widgets/room_list_view_test.dart  (210 Z.)
- L14 `AgentsRoomMember _m(String id, String handle)`
- L17 `AgentsRoomDraft _draft(String name, int members)`
- L22 `void main()`

## test/widgets/room_members_sheet_test.dart  (234 Z.)
- L10 `AgentsRoomMember _m(String id, String h)`
- L13 `AgentsAgent _agent(String id, String name)`
- L16 `AgentsRoom _room(List<AgentsRoomMember> members, {bool agentToAgent = true})`
- L24 `void main()`

## test/widgets/room_mention_picker_test.dart  (347 Z.)
- L14 `MentionToken? tokenAt(String marked)`  — The caret sits where the `|` is; the `|` is removed before the call.
- L20 `AgentsAgent agent(String id, String name, {String? role})`
- L23 `void main()`

## test/widgets/room_thread_page_test.dart  (728 Z.)
- L19 `void main()`
- L715 `class _FakeController implements AgentsRelayController`  — A minimal AgentsRelayController for the rebind test: only [inbound] is real;
  - L716 `final StreamController<AgentsRelayInbound> _c = StreamController<AgentsRelayInbound>.broadcast(sync: true)`
  - L720 `Stream<AgentsRelayInbound> get inbound`
  - L722 `void emit(AgentsRelayInbound e)`
  - L723 `Future<void> close()`
  - L726 `dynamic noSuchMethod(Invocation invocation)`

## test/widgets/room_thread_view_test.dart  (373 Z.)
- L11 `void main()`

## test/widgets/selection_copy_area_test.dart  (284 Z.)
- L9 `void main()`

## test/widgets/settings_kit_test.dart  (106 Z.)
- L7 `Widget _host(Widget child)`
- L11 `void main()`

## test/widgets/settings_list_view_test.dart  (87 Z.)
- L8 `Widget _host({required List<Widget> children, bool reducedMotion = false})`
- L17 `List<double> _opacities(WidgetTester tester)`
- L29 `void main()`

## test/widgets/stamped_text_test.dart  (255 Z.)
- L14 `kFontSize = 10`  — The test font draws every glyph as a square of the font size, so a line of
- L15 `kStyle = TextStyle(fontSize: kFontSize, height: 1)`
- L18 `kStamp = SizedBox(width: 40, height: 8)`  — A stand-in stamp with a width the test can do arithmetic with.
- L21 `kReserved = 8 + 40`  — Reserved footprint: the default gap plus the stamp.
- L23 `Widget host(Widget child, {double width = 300})`
- L31 `Widget wrapApp(Widget child)`
- L42 `void main()`

## test/widgets/turn_status_test.dart  (238 Z.)
- L16 `void main()`

## test/widgets/web_search_sources_test.dart  (40 Z.)
- L4 `void main()`
