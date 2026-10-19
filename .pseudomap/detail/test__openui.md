# test/openui · Signaturen

## test/openui/b1_layout_test.dart  (375 Z.)
- L14 `Finder _rich(String text)`
- L17 `Future<void> _pumpAt( WidgetTester tester, String source, { double width = 360, bool isStreaming = false, bool settle = true, })`  — Pumps [source] at [width] (phone 360, desktop chat 720).
- L41 `void main()`

## test/openui/b1_media_test.dart  (91 Z.)
- L13 `void main()`

## test/openui/b1_text_blocks_test.dart  (232 Z.)
- L11 `Finder _rich(String text)`
- L14 `List<String> _linkSpanTexts(WidgetTester tester)`  — The texts of every tappable span (a link) on screen.
- L27 `void main()`

## test/openui/b2_charts_test.dart  (293 Z.)
- L15 `Future<void> _pump( WidgetTester tester, String source, { double width = 360, Brightness brightness = Brightness.dark, bool isStreaming = false, })`
- L38 `_samples = <String, (String, Finder Function())>{ 'BarChart grouped': ( 'root = BarChart(["Jan", "Feb", "Mar"], [Series(`  — One sample per chart, with the widget type that must appear.
- L99 `void main()`

## test/openui/b2_tables_test.dart  (305 Z.)
- L14 `Future<RecordingOpenUiHandler> _pump( WidgetTester tester, String source, { double width = 360, Brightness brightness = Brightness.dark, bool isStreaming = false, })`
- L33 `Text _text(WidgetTester tester, String s)`
- L36 `_roster = ''' root = EditableTable("roster", [colName, colAge, colRole, colStart, colSite], [row1, row2]) colName = { ty`
- L49 `void main()`

## test/openui/b3_buttons_test.dart  (255 Z.)
- L13 `_all = ''' root = Card([title, f, icons, followUps]) title = TextContent("Plan a trip", "large-heavy") f = Form("trip", `  — Every B3 component in one program.
- L33 `Future<RecordingOpenUiHandler> _pump( WidgetTester tester, String source, { double width = OpenUiTokens.chatColumnWidth, Brightness brightness = Brightness.dark, double textScale = 1, bool isStreaming = false, bool settle = true, })`
- L63 `void main()`

## test/openui/b3_choices_test.dart  (328 Z.)
- L10 `Finder _rich(String text)`
- L13 `String _form(String input, {String state = ''})`  — A form called "f" with one control, and a Send button.
- L17 `Future<Map<String, Object?>?> _submit( WidgetTester tester, RecordingOpenUiHandler h, )`
- L26 `String _iso(DateTime d)`
- L31 `void main()`

## test/openui/b3_forms_test.dart  (370 Z.)
- L12 `Finder _field(String placeholder)`
- L15 `Finder _rich(String text)`
- L17 `_contact = ''' root = Card([f]) f = Form("contact", Buttons([submit, later]), [nameField, emailField, ageField]) nameFie`
- L27 `void main()`

## test/openui/b4_data_cards_test.dart  (345 Z.)
- L13 `Future<RecordingOpenUiHandler> pumpAt( WidgetTester tester, String source, { double width = OpenUiTokens.chatColumnWidth, Brightness brightness = Brightness.dark, bool isStreaming = false, })`  — Pumps [source] at [width] (the chat column) and settles.
- L34 `_all = ''' root = Card([tags, tagOne, el, lb, t1, t2, it, imt, imtl, m1, m2, snip, ov, ctx, comp, vis]) tags = TagBlock(`
- L54 `void main()`

## test/openui/b4_icons_test.dart  (173 Z.)
- L13 `void main()`

## test/openui/openui_fixtures_test.dart  (113 Z.)
- L14 `Set<String> componentNames(String source)`  — The component names a program calls (not `Action` and `Query`).
- L65 `Map<String, List<String>> unknownComponents()`  — Unknown component names per fixture.
- L74 `void main()`

## test/openui/openui_gallery_test.dart  (39 Z.)
- L8 `void main()`

## test/openui/openui_l10n_test.dart  (107 Z.)
- L19 `_form = ''' root = Card([f]) f = Form("f", Button("Send"), [a, b, c]) a = FormControl("Name", Input("name", "Your name",`
- L27 `Future<void> _pump(WidgetTester tester, String source, Locale? locale)`
- L53 `void main()`

## test/openui/openui_license_test.dart  (19 Z.)
- L6 `void main()`

## test/openui/openui_nested_values_test.dart  (65 Z.)
- L13 `Finder _rich(String text)`
- L15 `Future<void> _pump(WidgetTester tester, String source)`
- L25 `void main()`

## test/openui/openui_props_test.dart  (309 Z.)
- L11 `_def = OpenUiComponentDef( name: 'Demo', group: 'Test', description: 'A demo.', params: <OpenUiParam>[ OpenUiParam('labe`
- L25 `Widget _noop(BuildContext context, OpenUiProps props)`
- L27 `OpenUiProps _props(Map<String, Object?> values)`
- L34 `void main()`

## test/openui/openui_signatures_test.dart  (60 Z.)
- L15 `Map<String, String> _signatures(String file)`
- L26 `Map<String, String> upstreamSignatures()`  — The 86 upstream components chuk_chat ports, with their signatures.
- L35 `void main()`

## test/openui/openui_skill_freshness_test.dart  (90 Z.)
- L19 `void main()`

## test/openui/openui_test_helper.dart  (126 Z.)
- L13 `typedef SentMessage = ({ String text, String? context, Map<String, Object?>? formValues, })`  — One recorded [OpenUiActionHandler.sendToAssistant] call.
- L20 `class RecordingOpenUiHandler extends OpenUiActionHandler`  — An [OpenUiActionHandler] that records every call.
  - L22 `final List<SentMessage> messages = <SentMessage>[]`  — The messages sent to the assistant, in order.
  - L25 `final List<String> urls = <String>[]`  — The URLs opened, in order.
  - L28 `final List<Map<String, Object?>> states = <Map<String, Object?>>[]`  — The store snapshots, in order.
  - L31 `void sendToAssistant( String text, { String? context, Map<String, Object?>? formValues, })`
  - L40 `void openUrl(String url)`
  - L43 `void onStateChanged(Map<String, Object?> state)`
- L47 `ThemeData openUiTestTheme(Brightness brightness)`  — The app theme the gallery and the tests use.
- L57 `Widget openUiTestApp( Widget child, { Brightness brightness = Brightness.dark, double width = OpenUiTokens.chatColumnWidth, })`  — Wraps [child] in the app theme, in a chat-bubble-wide column.
- L79 `Future<RecordingOpenUiHandler> pumpOpenUi( WidgetTester tester, String source, { bool isStreaming = false, Brightness brightness = Brightness.dark, OpenUiLibrary? library, Map<String, ToolExecutor>? tools, RecordingOpenUiHandler? handler, bool settle = true, })`  — Pumps [source] in an [OpenUiView] and settles. Returns the handler
- L111 `openUiFixtureDir = 'test/openui/fixtures'`  — The fixture directory (canonical upstream example programs).
- L114 `Map<String, String> readOpenUiFixtures()`  — Every `*.oui` fixture, by file name, sorted.

## test/openui/openui_view_test.dart  (305 Z.)
- L14 `_formLibrary = OpenUiLibrary(<OpenUiComponentDef>[ ...chukOpenUiLibrary.components, OpenUiComponentDef( name: 'Form', gr`
- L53 `class _TestField extends StatelessWidget`
  - L54 `const _TestField({required this.name})`
  - L56 `final String name`
  - L59 `Widget build(BuildContext context)`
- L67 `Finder _rich(String text)`
- L69 `void main()`
