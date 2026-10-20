# test/widgets · Signaturen

## test/widgets/agent_activity_timeline_test.dart  (679 Z.)
- L15 `_t0 = DateTime.utc(2026, 8, 13, 10, 0, 0)`
- L17 `ToolCall _call( String name, { Map<String, dynamic> arguments = const {}, ToolCallStatus status = ToolCallStatus.completed, int startSecond = 0, int? endSecond, String? roundThinking, })`
- L37 `Future<void> _pumpTimeline( WidgetTester tester, { required List<ToolCall> calls, bool isRunning = false, DateTime? now, bool? initiallyExpanded, void Function(ToolCall)? onStepTap, void Function(AgentActivitySource)? onSourceTap, StreamPhase? phase, DateTime? startedAt, Duration? finalDuration, })`
- L68 `void main()`

## test/widgets/agent_chart_blocks_test.dart  (118 Z.)
- L7 `_electionChart = ''' Stand 22:25 Uhr. <chart> {"title":"Zweitstimmen","rows":[{"label":"AfD","value":44.8,"color":"#80cd`
- L21 `void main()`

## test/widgets/agent_control_panel_cost_test.dart  (387 Z.)
- L12 `AgentsAgent _agent()`
- L21 `AgentControlSnapshot _withCost(Map<String, dynamic>? cost)`
- L33 `void main()`

## test/widgets/agent_control_panel_test.dart  (455 Z.)
- L11 `AgentsAgent _agent({bool onHost = true})`
- L21 `Future<void> _pump( WidgetTester tester, AgentControlSource source, { AgentsAgent? agent, })`
- L36 `_fullSnapshot = AgentControlSnapshot( model: ControlAvailable<AgentModelChoice>( AgentModelChoice( id: 'anthropic/claude`
- L67 `void main()`

## test/widgets/agent_details_overview_test.dart  (211 Z.)
- L15 `AgentsAutomation _routine( String id, { String session = 'amber-main', String state = 'active', String kind = 'schedule', Map<String, dynamic> spec = const <String, dynamic>{'cron': '13 8 * * *'}, String? name, })`
- L32 `void main()`

## test/widgets/agent_face_test.dart  (91 Z.)
- L10 `void main()`

## test/widgets/agent_markdown_test.dart  (56 Z.)
- L6 `Widget _host(Widget child, {Brightness brightness = Brightness.light})`
- L13 `void main()`

## test/widgets/agent_roster_view_test.dart  (1022 Z.)
- L26 `void main()`

## test/widgets/agent_run_views_test.dart  (288 Z.)
- L14 `_pngBytes = base64.decode( 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842' 'iQAAAABJRU5Er`  — A 1x1 transparent PNG — the smallest real image to prove a preview renders.
- L19 `class _RecordingSaver implements AgentFileSaver`
  - L20 `final List<String> saved = <String>[]`
  - L21 `Object? failWith`
  - L24 `Future<String> save(AgentsRelayFile file)`
- L32 `Widget _host(Widget child)`
- L36 `void main()`

## test/widgets/agent_template_picker_test.dart  (253 Z.)
- L11 `class _Harness`  — Opens the picker from a button and keeps what it returned.
  - L12 `AgentCreateRequest? result`
  - L13 `bool closed = false`
  - L15 `Widget app({String locale = 'en', double textScale = 1})`
- L49 `void _size(WidgetTester tester, Size size)`
- L55 `Future<_Harness> _open( WidgetTester tester, { Size size = const Size(360, 800), String locale = 'en', double textScale = 1, })`
- L70 `Finder _key(String key)`
- L72 `void main()`

## test/widgets/agents_action_approval_card_test.dart  (486 Z.)
- L24 `class _NoopSaver implements AgentFileSaver`
  - L26 `Future<String> save(AgentsRelayFile file)`
- L29 `class _FakeSessionSource implements AccountSessionSource`
  - L30 `const _FakeSessionSource()`
  - L33 `AccountSession? current()`
  - L40 `Future<AccountSession?> refresh()`
- L43 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L55 `_allOptions = <String>[ 'once', 'always_this_agent', 'always_this_site', 'deny', ]`
- L62 `AgentsRelayApprovalRequest _request({ String id = 'ap-1', String actionClass = 'browser_act', List<String> options = _allOptions, String? summary = 'Click "Buy now" on shop.example', String? site = 'shop.example', Map<String, dynamic>? details = const <String, dynamic>{ 'browser_tool': 'browser_click', 'element': 'Buy now', }, })`
- L89 `void main()`

## test/widgets/agents_approval_row_test.dart  (369 Z.)
- L22 `void main()`  — bead chuk_chat-aupy: an answered approval stays in the thread as one

## test/widgets/agents_cold_start_test.dart  (399 Z.)
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
- L349 `Future<void> _drainNotifyDebounce()`  — `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
- L357 `Future<void> _releaseIdleTimers(WidgetTester tester)`  — The imported chat screen opens a multiplex session on mount and arms a
- L371 `void _silenceUnrelatedPlugins(WidgetTester tester)`  — The imported screen constructs an [AudioRecorder] on mount, which calls the
- L388 `Future<void> _settle(WidgetTester tester)`  — [WidgetTester.pumpAndSettle] never returns here: the thread view arms an
- L398 `_guard = Timeout(Duration(seconds: 60))`  — A wall-clock guard on every test in this file. Nothing here should take

## test/widgets/agents_desktop_shell_test.dart  (665 Z.)
- L34 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L35 `final Map<String, String> map = <String, String>{}`
  - L37 `Future<String?> read(String key)`
  - L39 `Future<void> write(String key, String value)`
  - L41 `Future<void> delete(String key)`
- L45 `class _FailingRefreshSource extends FakeAgentControlSource`  — A host that answers the panel's first look and then fails a refresh.
  - L46 `bool failNext = false`
  - L49 `Future<void> refresh(String sessionKey)`
- L55 `class _Session implements AccountSessionSource`
  - L56 `const _Session()`
  - L58 `AccountSession? current()`
  - L64 `Future<AccountSession?> refresh()`
- L69 `class _FailingCreateController extends FakeRelayController`  — A host link whose `agent_create` send fails.
  - L71 `Future<void> createAgent( String agentId, String name, { Map<String, Object?>? template, })`
- L81 `void main()`

## test/widgets/agents_live_dots_test.dart  (207 Z.)
- L21 `void main()`  — bead chuk_chat-hfru: while an Agents turn runs, the thread shows the

## test/widgets/agents_live_status_test.dart  (256 Z.)
- L16 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L31 `void main()`  — The status line above a running Agents answer (research item 4): it says

## test/widgets/agents_run_cost_meta_test.dart  (335 Z.)
- L19 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L31 `AgentsRunCost _cost({double? eur = 0.002345})`
- L57 `Widget _item(List<ToolCall> calls, {String text = 'the answer'})`
- L84 `void main()`

## test/widgets/agents_shell_states_test.dart  (333 Z.)
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
- L99 `class _EmptyHostRoster extends LocalAgentRosterSource`  — A host that lists no agents: pairing does not bring a host agent.
  - L101 `AgentsAgent ensureHostAgent( String peerDeviceId, { String? label, Set<String> replaceableLabels = const <String>{}, })`
- L113 `kDesktop = Size(1340, 818)`
- L114 `kPhone = Size(412, 915)`
- L116 `void main()`

## test/widgets/agents_skill_proposal_card_test.dart  (571 Z.)
- L23 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L35 `_draft = AgentsRelaySkillProposal( proposalId: 'sp_1', name: 'invoice-export', description: 'Export the month of invoice`
- L44 `SkillProposalEntry _entry({ SkillProposalState state = SkillProposalState.pending, String? savedName, })`
- L55 `class _Decisions`  — Records every answer and replies with [reply].
  - L56 `_Decisions([this.reply])`
  - L58 `AgentsSkillProposalResult Function()? reply`
  - L59 `final List<Map<String, Object?>> sent = <Map<String, Object?>>[]`
  - L61 `Future<AgentsSkillProposalResult> decide({ required bool accept, String? name, String? description, String? body, })`
- L81 `Finder _key(String k)`
- L84 `Future<void> _tap(WidgetTester tester, Finder finder)`  — The card can be taller than the test window: scroll the target in first.
- L91 `Future<void> _pump(WidgetTester tester, Widget widget)`  — The localizations load on the first frame; settle before looking.
- L96 `void main()`
- L531 `class _NoopSaver implements AgentFileSaver`
  - L533 `Future<String> save(AgentsRelayFile file)`
- L536 `class _FakeSessionSource implements AccountSessionSource`
  - L537 `const _FakeSessionSource()`
  - L540 `AccountSession? current()`
  - L547 `Future<AccountSession?> refresh()`
- L551 `class _SkillFakeController extends FakeRelayController implements AgentsSkillProposalControl`  — The fake transport, plus the decision a real relay client sends.
  - L553 `final List<(String, bool)> decisions = <(String, bool)>[]`
  - L556 `Future<AgentsSkillProposalResult> sendSkillProposalDecision({ required String proposalId, required bool accept, String? name, String? description, String? body, })`

## test/widgets/agents_takeover_card_test.dart  (619 Z.)
- L24 `class _NoopSaver implements AgentFileSaver`
  - L26 `Future<String> save(AgentsRelayFile file)`
- L29 `class _FakeSessionSource implements AccountSessionSource`
  - L30 `const _FakeSessionSource()`
  - L33 `AccountSession? current()`
  - L40 `Future<AccountSession?> refresh()`
- L43 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L55 `AgentsRelayApprovalRequest _takeover({ String id = 'tk-1', String? kind = 'login', String? site = 'accounts.google.com', String? reason, String? decision, bool replay = false, String? sessionKey = 'thread-1', String? url, })`
- L86 `void main()`  — The takeover card (research item 6): a login, 2FA code or CAPTCHA in the

## test/widgets/agents_thread_header_test.dart  (318 Z.)
- L12 `Widget _wrap(Widget child, {double width = 700})`  — The header only ever gets the width its parent has, so every test states
- L21 `AgentsThreadAction _action(String tooltip, List<String> log)`
- L28 `void main()`

## test/widgets/agents_thread_table_test.dart  (541 Z.)
- L33 `class _NoopSaver implements AgentFileSaver`
  - L35 `Future<String> save(AgentsRelayFile file)`
- L38 `class _FakeSessionSource implements AccountSessionSource`
  - L39 `const _FakeSessionSource()`
  - L42 `AccountSession? current()`
  - L49 `Future<AccountSession?> refresh()`
- L52 `_wideTable = 'Hier sind die Bilder:\n\n' '| Datei | Titel | Quelle |\n' '|---|---|---|\n' '| 1-hamburg-yah-thecoffeemugs`
- L66 `_linux = TargetPlatformVariant.only( TargetPlatform.linux, )`  — A Linux desktop: a mouse, a wheel and a trackpad, and chuk's desktop
- L70 `_answerText = 'Alle Bilder stammen direkt von der Produktseite.'`
- L72 `_tableScroller = find.descendant( of: find.byType(ChukTableClassic), matching: find.byWidgetPredicate( (Widget w) => w i`
- L81 `ScrollPosition _tablePosition(WidgetTester tester)`  — The horizontal scroller inside the one table on screen.
- L84 `Rect _tableScrollbarRect(WidgetTester tester)`
- L92 `Map<String, Object?> _tableLook(WidgetTester tester)`  — Everything that decides how the table looks and pans, read off the tree.
- L120 `Future<void> _expectPansSideways(WidgetTester tester)`  — Drags the thumb, then shift + wheel, a sideways wheel and a trackpad pan:
- L180 `Widget _plainChat(String text, {double width = 760})`  — chuk_chat's plain desktop transcript around one answer: a selection area,
- L203 `void main()`

## test/widgets/agents_thread_view_notifications_test.dart  (208 Z.)
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

## test/widgets/agents_thread_view_test.dart  (1539 Z.)
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
- L1518 `Future<void> _flushIdleTimers(WidgetTester tester)`  — The imported chat screen schedules a 60 s idle-close timer for its
- L1524 `class _ProbingRelayController extends FakeRelayController implements AgentsLinkProbe`  — A fake whose socket can be asked whether it still answers.
  - L1526 `_ProbingRelayController(this.answers)`
  - L1528 `final bool answers`
  - L1529 `int probes = 0`
  - L1532 `Future<bool> probeLink({ Duration timeout = const Duration(milliseconds: 1500), })`

## test/widgets/agents_user_browser_test.dart  (747 Z.)
- L20 `Map<String, dynamic> _block({ bool installed = true, bool connected = true, bool inUse = false, Map<String, dynamic>? inUseBy, bool stopped = false, })`
- L39 `Map<String, dynamic> _reply( String agentId, Map<String, dynamic> block, { bool userBrowser = false, })`
- L51 `Map<String, dynamic> _push(Map<String, dynamic> block)`
- L56 `Widget _localized( Widget child, { Locale locale = const Locale('en'), double width = 800, double textScale = 1, })`
- L84 `extension on WidgetTester`
  - L86 `Future<void> pumpL(Widget widget)`  — The app's localisations load asynchronously: the first frame is empty.
- L92 `Finder _subtitleOf(String text)`
- L97 `Future<(FakeHost, AgentsPermissionsService)> _section( WidgetTester tester, { Locale locale = const Locale('en'), })`
- L114 `void main()`

## test/widgets/agents_user_browser_thread_test.dart  (234 Z.)
- L25 `class _NoopSaver implements AgentFileSaver`
  - L27 `Future<String> save(AgentsRelayFile file)`
- L30 `class _FakeSessionSource implements AccountSessionSource`
  - L31 `const _FakeSessionSource()`
  - L34 `AccountSession? current()`
  - L41 `Future<AccountSession?> refresh()`
- L44 `Map<String, dynamic> _push({ bool connected = true, bool stopped = false, Map<String, dynamic>? inUseBy, })`
- L63 `void main()`

## test/widgets/anchored_menu_test.dart  (181 Z.)
- L9 `_screen = Size(400, 800)`
- L11 `Future<void> _pumpAnchor( WidgetTester tester, { required double keyboardInset, required Alignment anchorAt, int itemCount = 3, bool preferAbove = false, })`
- L63 `void main()`

## test/widgets/answer_blocks_test.dart  (470 Z.)
- L11 `_text = Color(0xFF111111)`
- L12 `_bubble = Color(0xFFFFFFFF)`
- L14 `Future<void> _pump( WidgetTester tester, String markdown, { double width = 360, double textScale = 1, ValueChanged<String>? onFollowUp, })`
- L51 `String _allText(WidgetTester tester)`  — Every RichText's plain text, joined. Finds text inside nested messages.
- L56 `void main()`

## test/widgets/app_lifecycle_observer_test.dart  (43 Z.)
- L9 `void main()`  — `AppLifecycleService.handleLifecycleState` was called by NOBODY in

## test/widgets/app_mode_switch_test.dart  (1008 Z.)
- L50 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L51 `final Map<String, String> map = <String, String>{}`
  - L54 `Future<String?> read(String key)`
  - L57 `Future<void> write(String key, String value)`
  - L60 `Future<void> delete(String key)`
- L64 `class _EmptyMirror extends SupabasePairingSync`  — The encrypted mirror, with nothing in it.
  - L66 `Future<AgentsCloudPairingRead> readEncryptedPairing()`
  - L70 `Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing)`
  - L74 `Future<void> saveEncryptedPairing(AgentsStoredPairing pairing)`
  - L77 `Future<void> clearEncryptedPairing()`
- L81 `class _SlowMirror extends _EmptyMirror`  — A mirror whose read answers only when the test says so.
  - L82 `_SlowMirror(this._read)`
  - L84 `final Future<AgentsCloudPairingRead> _read`
  - L87 `Future<AgentsCloudPairingRead> readEncryptedPairing()`
- L90 `class _Session implements AccountSessionSource`
  - L91 `const _Session()`
  - L94 `AccountSession? current()`
  - L101 `Future<AccountSession?> refresh()`
- L107 `class _FakeChatHalf extends StatefulWidget`  — Stands in for chuk_chat's root wrapper: a top bar shaped like chuk's (a
  - L108 `const _FakeChatHalf({ required this.phone, required this.modeSwitch, this.onAddComputer, })`
  - L114 `final bool phone`
  - L117 `final Widget? modeSwitch`  — Null while the device has no computer.
  - L120 `final VoidCallback? onAddComputer`  — The install entry's action; null unless the device has no computer.
  - L123 `State<_FakeChatHalf> createState()`
- L126 `class _FakeChatHalfState extends State<_FakeChatHalf>`
  - L127 `int taps = 0`
  - L128 `final TextEditingController draft = TextEditingController()`
  - L131 `void dispose()`
  - L137 `Widget build(BuildContext context)`
- L202 `kPhone = Size(360, 800)`
- L206 `kSwitchOnPhone = Rect.fromLTWH( 10 + 42 + 8, 24 + 8, AppModeSwitch.width, AppModeSwitch.boxHeight, )`  — Where the switch sits on a 360 px phone with a 24 px status bar, over
- L215 `kWidePhone = Size(412, 800)`  — A phone wide enough for the "Add your computer" panel an unpaired device
- L216 `kPhoneInsets = EdgeInsets.only(top: 24)`
- L218 `void main()`

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

## test/widgets/automation_editor_sheet_test.dart  (348 Z.)
- L17 `void main()`

## test/widgets/browser_view_page_test.dart  (279 Z.)
- L14 `class _CountingRelay extends FakeRelayController`  — Counts the view start/stop the page sends the executor.
  - L15 `int starts = 0`
  - L16 `int stops = 0`
  - L19 `Future<void> startBrowserView({String? sessionKey})`
  - L24 `String? lastSessionKey`
  - L27 `Future<void> stopBrowserView()`
- L30 `void main()`
- L270 `double _luminance(Color c)`
- L272 `double _contrast(Color a, Color b)`

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

## test/widgets/chat_document_reading_test.dart  (417 Z.)
- L27 `_briefText = ''' # Wahlradar Ein eigener Beobachter für die **Landtagswahl Sachsen-Anhalt 2026** — läuft. - **Quelle:** `  — A saved document has to read like a document on the phone it is read on.
- L48 `Map<String, dynamic> _markdownDocument()`
- L56 `Map<String, dynamic> _tableDocument()`
- L79 `Map<String, dynamic> _chartDocument()`
- L99 `void _phone(WidgetTester tester)`  — Puts the tester on a Pixel 7 Pro at [scale], for the lifetime of one test.
- L105 `Widget _host(Widget child, {double scale = 1.0})`
- L115 `Future<void> _open( WidgetTester tester, Map<String, dynamic> document, { double scale = 1.0, })`  — Opens the document the way a reader does — through the dialog, so the test
- L142 `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- L153 `List<String> _pastRightEdge(WidgetTester tester, Finder root)`  — Every box inside [root] that paints past its right edge.
- L197 `void main()`

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

## test/widgets/chat_maintenance_gate_test.dart  (134 Z.)
- L18 `Widget _app(Widget child, {Locale locale = const Locale('en')})`
- L30 `void main()`

## test/widgets/chat_mode_selector_test.dart  (474 Z.)
- L22 `_fireworksLevels = <String>['none', 'low', 'high']`
- L24 `Future<void> _pump( WidgetTester tester, { ChatMode mode = ChatMode.thinking, ValueChanged<ChatMode>? onModeChanged, ValueChanged<String>? onModelSelected, String reasoningEffort = 'none', List<String> reasoningLevels = _fireworksLevels, ValueChanged<String>? onReasoningEffortChanged, VoidCallback? onOpenModelScreen, String? selectedModelId, String? modelLabel, List<ChatModelChoice> pickedModels = const <ChatModelChoice>[], })`
- L59 `void main()`

## test/widgets/chuk_table_classic_stacked_test.dart  (108 Z.)
- L7 `_shopTable = <String>[ '| Produkt | Preis | Bewertung |', '|---|---|---|', '| [CAMWAY DA-Wandler 192 kHz, optisch auf 3,`
- L14 `Future<void> _pump( WidgetTester tester, double width, { ValueChanged<String>? onTapLink, })`
- L42 `bool _tapLink(WidgetTester tester, String needle)`  — Taps the link span whose text contains [needle].
- L62 `void main()`

## test/widgets/chuk_table_golden_test.dart  (323 Z.)
- L28 `_shots = 'goldens/chuk_table'`  — Where the shots land: committed next to this file (relative to
- L32 `Map<String, dynamic> songs({int rows = 2})`  — The songs table, as the `chat_document` tool stores one: the reel it came
- L104 `Map<String, dynamic> labelledSongs()`  — A table the agent labelled itself: the cell carries `[label](url)`, so
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

## test/widgets/expressive_settings_test.dart  (89 Z.)
- L8 `Widget _host({required Widget child})`
- L14 `void main()`

## test/widgets/flag_off_parity_test.dart  (119 Z.)
- L18 `Widget _wrap(Widget child)`
- L31 `_sent = DateTime(2026, 9, 22, 14, 5)`
- L33 `Widget _turn({bool messengerMode = false})`
- L60 `Iterable<BoxDecoration> _decorations(WidgetTester tester)`  — Every decorated box the bubbles draw, by fill colour.
- L70 `void main()`

## test/widgets/floating_app_bar_test.dart  (66 Z.)
- L7 `void main()`

## test/widgets/html_artifact_view_test.dart  (113 Z.)
- L7 `_sampleHtml = ''' <!doctype html> <html><head><meta charset="utf-8"><title>Demo</title></head> <body><h1>Hello</h1><p>Pa`
- L13 `void main()`

## test/widgets/map_block_dedupe_test.dart  (72 Z.)
- L5 `void main()`

## test/widgets/markdown_message_test.dart  (541 Z.)
- L18 `kAccent = Color(0xFF1565C0)`
- L19 `kText = Color(0xFF111111)`
- L20 `kBubble = Color(0xFFFFFFFF)`
- L22 `ThemeData _theme()`
- L30 `Future<void> _pumpMarkdown( WidgetTester tester, String markdown, { double width = 360, double? fontSize, Color textColor = kText, })`
- L62 `Future<void> _settleCodeBlocks(WidgetTester tester)`  — Lets an `_AsyncCodeBlock` finish: the 50 ms highlight debounce and then the
- L69 `List<TextSpan> _leafSpans(WidgetTester tester)`  — Every leaf `TextSpan` in the widget tree, with its resolved style.
- L88 `TextSpan _span(WidgetTester tester, String text)`  — The leaf span whose text is exactly [text].
- L96 `void main()`

## test/widgets/markdown_table_list_bugs_test.dart  (231 Z.)
- L18 `kWideGermanTable = 'Hier der Vergleich:\n\n' '| Ansatz | Ablauf im Detail | Vor- und Nachteile |\n' '|---|---|---|\n' '|`
- L31 `kGoetheItem = '- **Goethe:** Faust I & II (Riesengeschichte – Mephisto-Wette, ' 'Gretchentragödie), Der Erlkönig, Die Le`
- L37 `Future<void> _pump(WidgetTester tester, String text, {double width = 360})`
- L61 `List<(String, bool)> _runs(WidgetTester tester)`  — Every piece of text on screen, with the bold state of each run.
- L85 `_tableScroller = find.descendant( of: find.byType(ChukTableClassic), matching: find.byWidgetPredicate( (Widget w) => w i`
- L93 `RenderParagraph _paragraphWith(WidgetTester tester, String text)`
- L105 `int _lines(RenderParagraph p)`  — Lines a laid-out paragraph takes, from its height and one line's height.
- L109 `void main()`

## test/widgets/measure_size_test.dart  (57 Z.)
- L5 `void main()`

## test/widgets/message_bubble_consecutive_tool_groups_test.dart  (96 Z.)
- L9 `void main()`

## test/widgets/message_bubble_dangling_lt_test.dart  (44 Z.)
- L7 `void main()`

## test/widgets/message_bubble_grouping_test.dart  (265 Z.)
- L21 `full = Radius.circular(16)`
- L22 `tail = Radius.circular(5)`
- L26 `gapInRun = 2 + 2`  — chuk_chat's bubble margins: 10 above the first bubble of a run, 2 above
- L27 `gapBetweenRuns = 2 + 10`
- L29 `Widget wrap(Widget child)`
- L44 `Widget threeMessageRun({required bool isUser})`  — A run of three messages from the same sender, followed by one message that
- L63 `decoratedBoxes = find.byWidgetPredicate( (Widget widget) => widget is Container && widget.decoration is BoxDecoration, )`
- L69 `Rect paintedBubble(WidgetTester tester, int index)`  — The painted rectangle of the bubble at [index] — the decorated box, not the
- L78 `BorderRadius radiusOf(WidgetTester tester, int index)`
- L86 `void main()`

## test/widgets/message_bubble_image_block_test.dart  (35 Z.)
- L5 `void main()`

## test/widgets/message_bubble_live_timer_gap_test.dart  (85 Z.)
- L7 `void main()`

## test/widgets/message_bubble_merge_junk_separated_test.dart  (94 Z.)
- L8 `void main()`

## test/widgets/message_bubble_no_tool_status_test.dart  (62 Z.)
- L6 `void main()`

## test/widgets/message_bubble_openui_test.dart  (197 Z.)
- L12 `Finder _rich(String text)`
- L14 `Widget _app(Widget child)`
- L18 `_closed = 'Intro text\n\n' '```openui-lang\n' 'root = Card([t, b])\n' 't = TextContent("Inside the view")\n' 'b = Button`
- L27 `void main()`

## test/widgets/message_bubble_pending_image_test.dart  (129 Z.)
- L7 `void main()`

## test/widgets/message_bubble_post_tool_reasoning_test.dart  (97 Z.)
- L7 `void main()`

## test/widgets/message_bubble_sources_test.dart  (88 Z.)
- L7 `void main()`

## test/widgets/message_bubble_test.dart  (242 Z.)
- L18 `_wakeText = '[automation a2f1d3d1 fired: Wahlradar LT Sachsen-Anhalt 2026]\n' 'check the seat projection and tell me wha`  — The exact text the host submits when an automation fires, header +
- L25 `_threadKey = 'amber-otter-2'`  — An Agents thread's id (a host session key) and a chuk_chat chat's (UUID).
- L26 `_chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b'`
- L28 `Widget _wrap(Widget child)`
- L39 `void main()`

## test/widgets/message_bubble_user_contrast_test.dart  (70 Z.)
- L12 `void main()`  — The user bubble's text keeps the reader's icon colour unless that falls

## test/widgets/message_bubble_variant_pager_test.dart  (89 Z.)
- L7 `void main()`

## test/widgets/messenger_context_menu_test.dart  (57 Z.)
- L5 `void main()`

## test/widgets/messenger_message_bubble_test.dart  (848 Z.)
- L19 `Widget wrap(Widget child)`
- L30 `void main()`

## test/widgets/messenger_shell_test.dart  (2190 Z.)
- L58 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L59 `final Map<String, String> map = <String, String>{}`
  - L62 `Future<String?> read(String key)`
  - L65 `Future<void> write(String key, String value)`
  - L68 `Future<void> delete(String key)`
- L73 `class _FakeRelayController implements AgentsRelayController`  — A controller the test drives: it can report itself paired, and it records
  - L74 `final ValueNotifier<AgentsRelayState> _state = ValueNotifier<AgentsRelayState>( const AgentsRelayState(phase: AgentsRelayPhase.idle), )`
  - L78 `final StreamController<AgentsRelayInbound> _inbound = StreamController<AgentsRelayInbound>.broadcast()`
  - L81 `final List<String> sessionKeys = <String>[]`
  - L84 `ValueListenable<AgentsRelayState> get state`
  - L87 `Stream<AgentsRelayInbound> get inbound`
  - L90 `Future<void> connect({ required Uri hostUrl, required String pairingCode, })`
  - L96 `Future<void> reconnect({ required Uri hostUrl, required AgentsStoredPairing pairing, })`
  - L104 `AgentsStoredPairing? get establishedTrust`
  - L107 `Future<void> provisionAccount(AccountSession session)`
  - L110 `Future<void> sendTask( String prompt, { String sessionKey = 'default', String? modelId, String? providerSlug, String? reasoningEffort, bool debug = false, bool regenerate = false, String? taskId, bool budgetOverride = false, })`
  - L122 `final List<(String, String)> roomTasks = <(String, String)>[]`
  - L123 `final List<String> createdRooms = <String>[]`
  - L124 `final List<bool> createdRoomPolicies = <bool>[]`
  - L125 `final List<(String, bool)> agentToAgentSets = <(String, bool)>[]`
  - L128 `Future<void> createRoom( String roomId, String name, List<Map<String, String>> members, { bool agentToAgent = true, })`
  - L139 `Future<void> setRoomAgentToAgent(String roomId, bool enabled)`
  - L143 `Future<void> sendRoomTask(String roomId, String message)`
  - L146 `final List<String> historyRequests = <String>[]`
  - L147 `final List<String> deletedRooms = <String>[]`
  - L150 `Future<void> requestRoomHistory(String roomId)`
  - L154 `Future<void> deleteRoom(String roomId)`
  - L156 `final List<(String, String)> renamedRooms = <(String, String)>[]`
  - L159 `Future<void> renameRoom(String roomId, String name)`
  - L162 `final List<(String, String)> createdAgents = <(String, String)>[]`
  - L163 `final List<(String, String)> renamedAgents = <(String, String)>[]`
  - L166 `final Map<String, Map<String, Object?>> createdTemplates = <String, Map<String, Object?>>{}`  — The `template` object of each `agent_create`, by agent id.
  - L170 `Future<void> createAgent( String agentId, String name, { Map<String, Object?>? template, })`
  - L180 `Future<void> renameAgent(String agentId, String name)`
  - L183 `int agentListRequests = 0`
  - L186 `Future<void> requestAgentList()`
  - L188 `final List<(String, String)> removedMembers = <(String, String)>[]`
  - L191 `Future<void> addRoomMember( String roomId, String agentId, String handle, )`
  - L198 `Future<void> removeRoomMember(String roomId, String agentId)`
  - L202 `Future<void> requestStop({String sessionKey = 'default'})`
  - L205 `Future<void> requestReplay({ String sessionKey = 'default', int afterId = 0, int beforeId = 0, int limit = 0, })`
  - L213 `Future<void> sendRunAck(String runId)`
  - L216 `Future<void> startBrowserView({String? sessionKey})`
  - L219 `Future<void> stopBrowserView()`
  - L222 `Future<void> sendBrowserData(Uint8List bytes)`
  - L225 `Future<void> sendApprovalDecision({ required String approvalId, required bool approved, String? scope, })`
  - L232 `Future<void> sendSecrets({ required Map<String, String> values, required int revision, String? requestId, })`
  - L239 `Future<void> dispose()`
  - L244 `void pair()`
  - L249 `void emit(AgentsRelayInbound event)`
- L252 `class _FakeSessionSource implements AccountSessionSource`
  - L253 `const _FakeSessionSource()`
  - L256 `AccountSession? current()`
  - L263 `Future<AccountSession?> refresh()`
- L272 `Future<void> settle(WidgetTester tester)`  — Pump a few frames without waiting for the tree to go quiet.
- L278 `void main()`
- L2171 `class _CountingReadMarks extends AgentReadMarks`
  - L2172 `int flushes = 0`
  - L2175 `Future<void> flush()`
- L2181 `class _CountingRoster extends LocalAgentRosterSource`
  - L2182 `int flushes = 0`
  - L2185 `void flushPendingPersist()`

## test/widgets/messenger_typing_indicator_test.dart  (48 Z.)
- L5 `void main()`

## test/widgets/model_logo_test.dart  (113 Z.)
- L12 `void main()`

## test/widgets/room_create_sheet_test.dart  (251 Z.)
- L8 `AgentsAgent _agent(String id, String name, {String? role})`
- L15 `void main()`

## test/widgets/room_faces_test.dart  (365 Z.)
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

## test/widgets/room_thread_page_test.dart  (805 Z.)
- L20 `void main()`
- L792 `class _FakeController implements AgentsRelayController`  — A minimal AgentsRelayController for the rebind test: only [inbound] is real;
  - L793 `final StreamController<AgentsRelayInbound> _c = StreamController<AgentsRelayInbound>.broadcast(sync: true)`
  - L797 `Stream<AgentsRelayInbound> get inbound`
  - L799 `void emit(AgentsRelayInbound e)`
  - L800 `Future<void> close()`
  - L803 `dynamic noSuchMethod(Invocation invocation)`

## test/widgets/room_thread_view_test.dart  (373 Z.)
- L11 `void main()`

## test/widgets/selection_copy_area_test.dart  (284 Z.)
- L9 `void main()`

## test/widgets/settings_list_view_test.dart  (51 Z.)
- L8 `Widget _host({required List<Widget> children})`
- L14 `void main()`

## test/widgets/status_answer_block_test.dart  (144 Z.)
- L10 `_payments = ''' Erledigt, Posteingang ist auf 0. ::: status 4 offene Zahlungen · 122,20 € + 50 \$ Hetzner | Kartenzahlun`
- L24 `Future<void> _pump( WidgetTester tester, String markdown, { required double width, double textScale = 1, bool dark = false, })`
- L68 `String _allText(WidgetTester tester)`
- L73 `void main()`

## test/widgets/turn_status_test.dart  (238 Z.)
- L16 `void main()`

## test/widgets/voice_message_bubble_test.dart  (135 Z.)
- L10 `_transcript = 'Okay so I was thinking about the trip next week and I would like to ' 'know what the weather will be like`
- L14 `void main()`

## test/widgets/web_search_sources_test.dart  (40 Z.)
- L4 `void main()`
