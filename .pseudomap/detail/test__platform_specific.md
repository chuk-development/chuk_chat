# test/platform_specific · Signatures

## test/platform_specific/sidebar_blocks_test.dart  (467 Z.)

- L21 `DateTime _localMidnight()`  — Midnight at the start of the current local day — the anchor every seeded
- L28 `void _seedChats()`  — Seeds the store the sidebars read from. Returns nothing — the sidebars
- L49 `StoredChat _seedChat({ required String id, required DateTime at, required String title, bool starred = false, })`
- L64 `Widget _host(Widget child)`
- L74 `void _tallWindow(WidgetTester tester)`  — Gives the test a window tall enough that a whole sidebar — account card,
- L83 `Future<void> _settleStartupWork(WidgetTester tester)`  — The background update check starts a 5 s timeout timer. Tearing the tree
- L88 `void main()`
