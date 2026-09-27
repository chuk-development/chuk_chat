# test/widgets/charts · Signaturen

## test/widgets/charts/chart_fixtures.dart  (145 Z.)
- L6 `kSachsenAnhalt = <String, Object?>{ 'kind': 'bar', 'title': 'Landtagswahl Sachsen-Anhalt', 'subtitle': 'Vorläufiges Erge`  — The picture he showed: Sachsen-Anhalt, party colours, a 5 % rule.
- L31 `kGainsAndLosses = <String, Object?>{ 'kind': 'column_delta', 'title': 'Gewinne und Verluste', 'subtitle': 'Veränderung g`  — The other half of his picture: what each party won or lost.
- L52 `kCryptoWeek = <String, Object?>{ 'kind': 'line', 'title': 'BTC und ETH, 7 Tage', 'subtitle': 'Schlusskurs je Tag', 'unit`  — A crypto week: one coin up, one down, the theme's pair doing the talking.
- L90 `kMalformed = <String, Object?>{ 'kind': 'bar', 'title': 'Umsatz nach Quartal', 'points': <Map<String, Object?>>[ <String`  — A malformed spec: the right idea, none of it usable.
- L101 `kGrouped = <String, Object?>{ 'kind': 'grouped', 'title': 'Downloads je Plattform', 'unit': 'k', 'series': <Map<String, `  — Two series side by side — the cheap kind that fell out of the same model.
- L132 `kHighReference = <String, Object?>{ ...kSachsenAnhalt, 'title': 'Landtagswahl Sachsen-Anhalt', 'subtitle': 'Zweitstimmen`  — The same election with the rule high up: at 40 % only the winner's bar is
- L141 `kGainsAndLossesWithRule = <String, Object?>{ ...kGainsAndLosses, 'reference_line': <String, Object?>{'value': -2, 'label`  — Gains and losses with a rule BELOW zero: the label has the whole upper

## test/widgets/charts/chart_spec_test.dart  (228 Z.)
- L10 `void main()`

## test/widgets/charts/chart_test_support.dart  (150 Z.)
- L19 `Future<void> loadChartFonts()`  — Loads Roboto from the SDK so a golden shows real glyphs instead of the
- L38 `Directory? _findMaterialFonts()`
- L66 `ThemeData chartTheme(Brightness brightness)`  — The app's own scheme shape: a neutral seed, so the chart's colours come
- L75 `kChartGoldenDir = 'goldens'`  — Where the tests write the PNGs. Relative to `test/widgets/charts/`.
- L79 `Future<Finder> pumpChart( WidgetTester tester, Widget chart, { double width = 366, Brightness brightness = Brightness.dark, double textScale = 1.0, double surfaceHeight = 900, })`  — Pumps [chart] into a bubble-width column on a themed background and
- L128 `Future<void> shootChart( WidgetTester tester, Object? json, String name, { double width = 366, Brightness brightness = Brightness.dark, double textScale = 1.0, })`  — Renders [spec] finished (no entrance) and writes `<name>.png`.

## test/widgets/charts/chuk_chart_golden_test.dart  (147 Z.)
- L14 `void main()`

## test/widgets/charts/chuk_chart_test.dart  (416 Z.)
- L14 `void main()`
- L378 `ChukChartPainter _painterOf(WidgetTester tester)`
- L392 `class _Rebuildable extends StatefulWidget`  — A host that rebuilds its chart without changing the spec.
  - L393 `const _Rebuildable()`
  - L396 `State<_Rebuildable> createState()`
- L399 `class _RebuildableState extends State<_Rebuildable>`
  - L400 `int _n = 0`
  - L402 `void bump()`
  - L405 `Widget build(BuildContext context)`

## test/widgets/charts/document_chart_golden_test.dart  (190 Z.)
- L27 `Map<String, dynamic> specDocument()`  — A chart document as the `chat_document` tool writes one now: the spec
- L60 `Map<String, dynamic> legacyDocument()`  — A chart document as the tool wrote one before the renderer landed: rows of
- L77 `Future<void> _shoot( WidgetTester tester, Widget child, String name, { Brightness brightness = Brightness.dark, double height = 900, })`  — Shoots [child] on a 360 dp phone column.
- L120 `Widget _inline(Map<String, dynamic> document)`  — The thread block: the bubble, the title, the meta line and the chart.
- L127 `void _nothing()`
- L130 `Widget _reader(Map<String, dynamic> document)`  — The reader, as the phone screen shows it minus its floating bar.
- L135 `void main()`
