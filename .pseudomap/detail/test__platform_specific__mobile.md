# test/platform_specific/mobile · Signaturen

## test/platform_specific/mobile/mobile_agent_list_test.dart  (313 Z.)
- L11 `void main()`

## test/platform_specific/mobile/mobile_agent_sheet_test.dart  (82 Z.)
- L9 `void main()`

## test/platform_specific/mobile/mobile_chat_chrome_test.dart  (526 Z.)
- L16 `void main()`

## test/platform_specific/mobile/mobile_chat_screen_test.dart  (129 Z.)
- L9 `void main()`

## test/platform_specific/mobile/mobile_preview_test.dart  (295 Z.)
- L24 `_out = '../../../docs/screenshots/c6'`
- L26 `void main()`
- L210 `class _PlaceholderChat extends StatelessWidget`  — Stands in for the verbatim chuk_chat phone screen in the preview: a
  - L211 `const _PlaceholderChat({required this.topInset})`
  - L213 `final double topInset`
  - L216 `Widget build(BuildContext context)`

## test/platform_specific/mobile/mobile_support.dart  (111 Z.)
- L14 `kPhoneSize = Size(390, 844)`  — A phone-sized window (iPhone 14: 390 × 844 logical px) with a 47 px status
- L15 `kPhonePadding = EdgeInsets.only(top: 47, bottom: 34)`
- L19 `Finder findId(String id)`  — Finds the `Semantics(identifier: id)` widget the mobile layer wraps each
- L25 `Future<void> pumpPhone( WidgetTester tester, Widget child, { ThemeData? theme, })`  — Pumps [child] into a phone-shaped, localised app.
- L54 `AgentsAgent agent({ required String id, required String name, String? role, String? brief, bool running = false, DateTime? lastActivity, List<AgentsThreadInfo>? threads, bool onHost = false, })`
- L78 `LocalAgentRosterSource rosterWith(List<AgentsAgent> agents)`
- L84 `Future<void> loadRealFonts()`  — Loads Roboto and the Material icon font from the Flutter SDK so a golden

## test/platform_specific/mobile/touch_target_walk_test.dart  (140 Z.)
- L27 `bool _isTarget(Widget w)`  — True for a widget that takes a tap and is therefore a touch target.
- L40 `void expectAllTargetsAreBigEnough(WidgetTester tester, Finder root)`  — Measures every target under [root] and fails on the first one that is
- L65 `void main()`
