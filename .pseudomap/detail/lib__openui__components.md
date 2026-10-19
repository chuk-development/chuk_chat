# lib/openui/components · Signaturen

## lib/openui/components/content_layout.dart  (479 Z.)
- part 'content_layout/containers.dart' · part 'content_layout/disclosure.dart' · part 'content_layout/media.dart' · part 'content_layout/text_blocks.dart'
- L70 `_kContentBase = 'TextContent | MarkDownRenderer | CardHeader | Callout | TextCallout | ' 'CodeBlock | Image | ImageBlock`
- L79 `_kContentLists = '$_kContentBase | ListBlock | FollowUpBlock'`
- L82 `contentLayoutComponents = <OpenUiComponentDef>[ const OpenUiComponentDef( name: 'Card', group: 'Layout', description: 'V`  — The B1 components: content and layout.
- L363 `bool _isStreaming(BuildContext context)`  — Whether the renderer above [context] still receives the program.
- L368 `bool _truthy(Object? v)`  — A `$binding<boolean>` value: `true` or the text `"true"`.
- L372 `List<Widget> _widgetsOf(Object? raw)`  — The rendered widgets of one raw value (a widget, a list of widgets,
- L379 `String? _webUrl(Object? raw)`  — [raw] as an http(s) URL, or `null`. Other schemes (file:, data:,
- L390 `Widget _blockColumn(List<Widget> children, {double? gap})`  — A vertical list of blocks with the default content gap.
- L398 `Widget _hairline(OpenUiTheme t)`  — The hairline between rows of a card.
- L403 `Widget _markdown( BuildContext context, String text, { double? size, FontWeight? weight, Color? color, Color? background, })`  — The app's markdown, in the chat font, so a block reads like the rest
- L426 `class _FollowStream`  — The open/closed state rule that Tabs, Accordion and SectionBlock
  - L427 `int _count = 0`
  - L428 `bool _streaming = false`
  - L431 `bool userPicked = false`  — Whether the user picked an item. Then nothing moves by itself.
  - L434 `String? start(List<String> values, {required bool streaming})`  — Starts with [values]. Returns the value to show first.
  - L443 `String? update(List<String> values, {required bool streaming})`  — Takes a new frame of [values]. Returns a value to switch to, or
- L457 `typedef _Panel = ({String value, String trigger, List<Widget> content})`  — One item of Tabs, Accordion or SectionBlock: an id, a label and
- L461 `List<_Panel> _panels(OpenUiProps p, String name, String fallbackLabel)`  — Reads the data children of [name] as panels. A missing or doubled

## lib/openui/components/data_cards.dart  (423 Z.)
- part 'data_cards/card_blocks.dart' · part 'data_cards/shared.dart' · part 'data_cards/text_blocks.dart'
- L53 `_blockModes = '"grid" | "carousel"'`
- L54 `_textVariant = '"text" | "number"'`
- L55 `_subtextVariant = '"text" | "number" | "metric"'`
- L56 `_textSize = '"xs" | "sm" | "md" | "lg"'`
- L57 `_status = '"neutral" | "info" | "success" | "warning" | "danger"'`
- L58 `_entityRow = '{left: string, right: string, rightVariant?: "text" | "number"}'`
- L60 `_trendType = '{direction: "up" | "down", value: number}'`
- L63 `dataCardsComponents = <OpenUiComponentDef>[ // -- Icons and tags ------------------------------------------------ const `  — The B4 components: data display and cards.

## lib/openui/components/forms_buttons.dart  (507 Z.)
- reicht weiter: 'package:chuk_chat/openui/components/forms_buttons/field.dart' show OpenUiFormValidationScope, OpenUiFormValidator · 'package:chuk_chat/openui/components/forms_buttons/rules.dart' show OpenUiRule, OpenUiRules
- L50 `_sizes = '"extra-small" | "small" | "medium" | "large"'`
- L51 `_variants = '"primary" | "secondary" | "tertiary"'`
- L52 `_selectionType = '"single" | "multiple"'`
- L55 `formsButtonsComponents = <OpenUiComponentDef>[ // -- Forms ---------------------------------------------------------- co`  — The B3 components: forms, buttons and follow-ups.
- L368 `Widget _buildButton(BuildContext context, OpenUiProps props)`
- L383 `class OpenUiButton extends StatelessWidget`  — The OpenUI button. Reuse it for `Buttons`, `IconButton` and the
  - L389 `const OpenUiButton({ required this.label, this.action, this.variant = 'primary', this.destructive = false, this.size = 'medium', this.statementId = '', super.key, })`  — Creates a button.
  - L400 `final String label`  — The visible text and the message of a label action.
  - L403 `final OpenUiAction? action`  — The action, or `null`.
  - L407 `final String variant`  — `primary` (accent fill), `secondary` (tonal fill) or `tertiary`
  - L410 `final bool destructive`  — The `destructive` type: error colours.
  - L413 `final String size`  — `extra-small`, `small`, `medium` or `large`.
  - L416 `final String statementId`  — The statement of the button, to detect a still-streaming one.
  - L419 `Widget build(BuildContext context)`
  - L486 `void _onTap(BuildContext context)`
  - L500 `static bool _submits(OpenUiAction? action)`  — Whether the action sends something on: a message to the assistant

## lib/openui/components/tables_charts.dart  (252 Z.)
- L42 `_tables = 'Tables'`
- L43 `_charts2d = 'Charts (2D)'`
- L44 `_charts1d = 'Charts (1D)'`
- L45 `_scatter = 'Charts (Scatter)'`
- L47 `_params2d = <OpenUiParam>[ OpenUiParam('labels', 'string[]'), OpenUiParam('series', 'Series[]'), ]`
- L52 `_params1d = <OpenUiParam>[ OpenUiParam('labels', 'string[]'), OpenUiParam('values', 'number[]'), ]`
- L58 `tablesChartsComponents = <OpenUiComponentDef>[ // -------------------------------------------------------------- Tables `  — The B2 components: tables and charts.
