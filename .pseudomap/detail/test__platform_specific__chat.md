# test/platform_specific/chat · Signaturen

## test/platform_specific/chat/agents_thread_composer_test.dart  (197 Z.)
- L30 `Finder findId(String id)`  — The composer's targets carry a semantics identifier, not a label.
- L35 `class _NoopSaver implements AgentFileSaver`
  - L37 `Future<String> save(AgentsRelayFile file)`
- L40 `class _FakeSessionSource implements AccountSessionSource`
  - L41 `const _FakeSessionSource()`
  - L44 `AccountSession? current()`
  - L51 `Future<AccountSession?> refresh()`
- L54 `Widget _app(Widget child)`
- L65 `void main()`

## test/platform_specific/chat/anchored_transcript_test.dart  (340 Z.)
- L13 `void main()`  — The bottom-anchored transcript (Agents).
- L223 `Matcher moveTo(double target)`
- L225 `class _Harness extends StatefulWidget`
  - L226 `const _Harness({ super.key, required this.initialRows, required this.anchored, required this.rowHeight, required this.textLength, required this.bottomInset, })`
  - L235 `final int initialRows`
  - L236 `final bool anchored`
  - L237 `final double rowHeight`
  - L238 `final int textLength`
  - L239 `final double bottomInset`
  - L242 `State<_Harness> createState()`
- L245 `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - L246 `late final List<Map<String, String>> rows = <Map<String, String>>[ for (var i = 0; i < widget.initialRows; i++) _row(), ]`
  - L249 `bool streaming = false`
  - L250 `final List<int> built = <int>[]`
  - L252 `Map<String, String> _row()`
  - L258 `bool get anchoredTranscript`
  - L261 `List<Map<String, String>> get transcriptRows`
  - L264 `bool get transcriptStreaming`
  - L267 `void initState()`
  - L273 `void dispose()`
  - L280 `void open()`  — What the chat screens do once a thread's rows are in place.
  - L285 `void appendRow({bool streaming = false})`
  - L293 `void setStreaming(bool value)`
  - L295 `void truncateAndAppend({required int keep})`
  - L303 `Widget _item(BuildContext context, int index)`
  - L309 `Widget build(BuildContext context)`

## test/platform_specific/chat/chat_scroll_mixin_test.dart  (242 Z.)
- L13 `void main()`  — Auto-scroll during streaming.
- L178 `Matcher moveTo(double target)`  — `pixels` lands on the extent within a sub-pixel of it.
- L180 `class _Harness extends StatefulWidget`
  - L181 `const _Harness({super.key, required this.initialRows})`
  - L183 `final int initialRows`
  - L186 `State<_Harness> createState()`
- L189 `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - L190 `late int rows = widget.initialRows`
  - L193 `void initState()`
  - L199 `void dispose()`
  - L206 `void streamOneMoreRow()`  — One more token's worth of content, then the same pin the chat screens do.
  - L213 `void growWithoutPinning()`  — More content without the streaming pin — what async-sized children do
  - L218 `void finishStream()`  — The end of the answer, as the chat screens handle it.
  - L222 `void jumpToEnd()`
  - L227 `Widget build(BuildContext context)`

## test/platform_specific/chat/chat_ui_helpers_test.dart  (701 Z.)
- L14 `void main()`

## test/platform_specific/chat/composer_send_target_test.dart  (129 Z.)
- L27 `Finder findId(String id)`  — The composer's targets carry a semantics identifier, not a label.
- L32 `class _NoopSaver implements AgentFileSaver`
  - L34 `Future<String> save(AgentsRelayFile file)`
- L37 `class _FakeSessionSource implements AccountSessionSource`
  - L38 `const _FakeSessionSource()`
  - L41 `AccountSession? current()`
  - L48 `Future<AccountSession?> refresh()`
- L51 `Widget _app(Widget child)`
- L62 `void main()`

## test/platform_specific/chat/message_render_cache_shared_test.dart  (91 Z.)
- L13 `List<Map<String, String>> _messages()`
- L30 `void main()`

## test/platform_specific/chat/mode_provider_resolution_test.dart  (146 Z.)
- L12 `class _Host extends StatefulWidget`
  - L13 `const _Host()`
  - L16 `State<_Host> createState()`
- L19 `class _HostState extends State<_Host> with ModelProviderResolutionMixin<_Host>`
  - L21 `String selectedModelId = ''`
  - L24 `String? selectedProviderSlug`
  - L27 `ChatMode chatMode = ChatMode.fast`
  - L30 `Widget build(BuildContext context)`
- L33 `_model = 'z-ai/glm-5.3-flash'`
- L34 `_modeProvider = 'wafer'`
- L36 `void main()`

## test/platform_specific/chat/queued_messages_restore_test.dart  (18 Z.)
- L6 `void main()`

## test/platform_specific/chat/regen_variant_seed_test.dart  (187 Z.)
- L10 `class _Host extends StatefulWidget`
  - L11 `const _Host()`
  - L13 `State<_Host> createState()`
- L16 `class _HostState extends State<_Host> with RegenVariantSeedMixin<_Host>`
  - L17 `String? activeChat`
  - L20 `String? get variantActiveChatId`
  - L23 `Widget build(BuildContext context)`
- L26 `Future<_HostState> _pump(WidgetTester tester)`
- L31 `List<Map<String, dynamic>> _seed()`
- L35 `void main()`
