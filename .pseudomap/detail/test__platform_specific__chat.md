# test/platform_specific/chat · Signatures

## test/platform_specific/chat/chat_scroll_mixin_test.dart  (194 Z.)

- L13 `void main()`  — Auto-scroll during streaming.
- L141 `Matcher moveTo(double target)`  — `pixels` lands on the extent within a sub-pixel of it.
- L143 `class _Harness extends StatefulWidget`
  - L144 `const _Harness({super.key, required this.initialRows})`
  - L146 `final int initialRows`
  - L149 `State<_Harness> createState()`
- L152 `class _HarnessState extends State<_Harness> with ChatScrollMixin<_Harness>`
  - L153 `late int rows = widget.initialRows`
  - L156 `void initState()`
  - L162 `void dispose()`
  - L169 `void streamOneMoreRow()`  — One more token's worth of content, then the same pin the chat screens do.
  - L174 `void jumpToEnd()`
  - L179 `Widget build(BuildContext context)`

## test/platform_specific/chat/chat_ui_helpers_test.dart  (438 Z.)

- L13 `void main()`

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
