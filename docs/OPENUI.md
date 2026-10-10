# OpenUI in chuk_chat

The model can write OpenUI Lang (spec v0.5, https://github.com/thesysdev/openui)
in a ```` ```openui-lang ```` fence. The app draws it as native Flutter
widgets in chuk_chat's design. No HTML, no web view.

Status (2026-10-10): all 86 upstream components are registered, and the
chat integration (message bubble, system prompt, skill) is done (section
12). Background: `docs/OPENUI_RESEARCH.md`.

## 1. Layout

| Path | What |
|---|---|
| `vendor/openui_core/` | Pure Dart: lexer, parser, streaming parser, evaluator, store, actions. Vendored from `mtwichel/openui_flutter` at `e1525eed`, patched for v0.5 (`NOTICE.md`). |
| `vendor/openui/` | The Flutter `Renderer` widget. Vendored and patched (`NOTICE.md`). |
| `lib/openui/openui.dart` | Barrel. Host code imports only this. |
| `lib/openui/openui_view.dart` | `OpenUiView`, the widget a host puts on screen. |
| `lib/openui/openui_component.dart` | `OpenUiComponentDef`, `OpenUiParam`. |
| `lib/openui/openui_props.dart` | `OpenUiProps` (typed readers), `OpenUiAction`, `OpenUiBinding`. |
| `lib/openui/openui_actions.dart` | `OpenUiActionHandler`, forms (`OpenUiFormScope`, `OpenUiFormState`), `OpenUiScope`. |
| `lib/openui/openui_theme.dart` | `OpenUiTokens`, `OpenUiTheme`. |
| `lib/openui/openui_library.dart` | `OpenUiLibrary`, `chukOpenUiLibrary` (the registry). |
| `lib/openui/components/*.dart` | The components, one file per group (section 2). |
| `lib/openui/dev/gallery_main.dart` | Gallery for visual checks. |
| `test/openui/` | Tests, fixtures, upstream signatures. |

## 2. Component files and owners

Each agent edits only its own file. Nobody edits `openui_library.dart`:
it already composes the four lists. Private helpers go in your file, or
in new files under `lib/openui/components/<your_file_name>/`.

| File | List | Agent | Components |
|---|---|---|---|
| `content_layout.dart` | `contentLayoutComponents` | B1 | Card, CardHeader, TextContent, MarkDownRenderer, Callout, TextCallout, Image, ImageBlock, ImageGallery, CodeBlock, InlineHeader, Separator, Stack, Tabs, TabItem, Accordion, AccordionItem, Steps, StepsItem, Carousel, SectionBlock, SectionItem, Modal |
| `tables_charts.dart` | `tablesChartsComponents` | B2 | Table, Col, EditableTable, BarChart, LineChart, AreaChart, RadarChart, HorizontalBarChart, Series, PieChart, RadialChart, SingleStackedBarChart, Slice, ScatterChart, ScatterSeries, Point |
| `forms_buttons.dart` | `formsButtonsComponents` | B3 | Form, FormControl, Label, Input, TextArea, Select, SelectItem, DatePicker, Slider, CheckBoxGroup, CheckBoxItem, RadioGroup, RadioItem, SwitchGroup, SwitchItem, ChipItem, Chips, OptionCard, OptionCards, Button, Buttons, IconButton, FollowUpBlock, FollowUpItem |
| `data_cards.dart` | `dataCardsComponents` | B4 | TagBlock, Tag, Icon, EntityList, ListBlock, ListItem, Text, BoldText, IconText, ImageText, ImageTextLarge, MetricIndicatorInline, MetricIndicatorWithStrikethrough, SnippetCardItem, SnippetCardBlock, OverviewCardItem, OverviewCardBlock, ContextCardItem, ContextCardBlock, CompositeCardItem, CompositeCardBlock, VisualCardItem, VisualCardBlock |

The reference components to copy: `Card` and `TextContent` in
`content_layout.dart`, `Button` (`OpenUiButton`) in `forms_buttons.dart`.

## 3. Add a component

The signature source of truth is
`test/openui/fixtures/upstream/components-chat.json` (Stack and Modal:
`components-general.json`). Copy the parameter names, their order and
their type text exactly. Use the upstream description.

```dart
const OpenUiComponentDef(
  name: 'CardHeader',
  group: 'Content',
  description: 'Header with optional title and subtitle',
  params: <OpenUiParam>[
    OpenUiParam.opt('title', 'string'),
    OpenUiParam.opt('subtitle', 'string'),
  ],
  builder: _buildCardHeader,
),

Widget _buildCardHeader(BuildContext context, OpenUiProps p) {
  final t = OpenUiTheme.of(context);
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (p.has('title')) Text(p.string('title'), style: t.titleStyle),
    if (p.has('subtitle')) Text(p.string('subtitle'), style: t.captionStyle),
  ]);
}
```

- `OpenUiParam(name, type)` is required, `OpenUiParam.opt(name, type)`
  is optional (`name?:` upstream).
- `test/openui/openui_signatures_test.dart` compares
  `def.signature` with upstream for every registered component. A wrong
  order or type text fails it.
- A type `ActionExpression` makes an action slot; a type that starts
  with `$binding` makes a two-way binding slot. A pure string union
  (`"a" | "b"`) gives the enum values for `props.choice`.
- The builder must not throw. If it throws anyway, the component draws
  nothing (and the error shows in debug logs).

## 4. Props helper (`OpenUiProps`)

All readers fall back; none throws.

| Reader | Returns |
|---|---|
| `string(n, fallback: '')`, `stringOrNull(n)` | text; numbers and bools are converted |
| `number(n, fallback: 0)`, `numberOrNull(n)`, `integer(n)` | `double` / `int`; numeric strings parse |
| `boolean(n, fallback: false)` | `bool`; `"true"`/`"false"` read too |
| `choice(n, fallback: 'x')` | an allowed enum value of the param, else the fallback |
| `list(n)` | `List<Object?>`; a single value becomes a one-item list |
| `stringList(n)`, `numberList(n)` | typed lists; a non-number is `0` so positions line up with labels |
| `map(n)`, `mapList(n)` | object literals (`{src, alt}` and lists of them) |
| `children(n)`, `child(n)` | rendered child widgets, flattened; text becomes `Text`; data nodes are skipped |
| `data(n, type: 'Series')`, `dataOne(n)` | data-only children as `OpenUiProps` (section 5) |
| `action(n)` | `OpenUiAction?`; `null` when empty, malformed, or still streaming |
| `binding(n)` | `OpenUiBinding?` when the argument was a `$variable` |
| `raw(n)`, `has(n)` | the raw value; whether it is non-null |

`props.statementId` is the OpenUI statement of the call.

## 5. Data-only components

`Series`, `Col`, `Slice`, `Point`, `ScatterSeries`, `SelectItem`,
`TabItem`, `AccordionItem`, `StepsItem`, `SectionItem`, `CheckBoxItem`,
`RadioItem`, `SwitchItem`, `ChipItem`, `OptionCard`, `FollowUpItem` and
the like hold data for a parent. Register them with
`OpenUiComponentDef.data(...)` (no builder). The renderer resolves their
props (child components inside them are rendered widgets) and passes a
`DataNode` to the parent. The parent reads them with `props.data`:

```dart
const OpenUiComponentDef.data(
  name: 'Series', group: 'Charts (2D)', description: 'One data series',
  params: <OpenUiParam>[
    OpenUiParam('category', 'string'),
    OpenUiParam('values', 'number[]'),
  ],
),

// In the BarChart builder:
final labels = p.stringList('labels');
for (final s in p.data('series', type: 'Series')) {
  final name = s.string('category');
  final values = s.numberList('values');
}
```

This works for inline calls, references (`[s1, s2]` with
`s1 = Series(...)`) and `@Each(rows, "r", Series(r.name, [r.v]))`. A
`DataNode` in a widget position draws nothing. When an item can also
stand alone (`ListItem`), give it a builder and let the parent use
`props.children`; decide per component.

## 6. Actions, forms, bindings

- Run an action slot: `props.action('action')?.run(context, label: label)`.
  `label` is the component's visible text: the object-literal form
  `{type: "continue_conversation", context: "..."}` sends it as the
  message.
- A component without an action that should talk to the assistant (a
  `Button` without action, a `FollowUpItem`) runs
  `OpenUiAction(implicitContinueConversationPlan(text))` (from
  `package:openui_core/openui_core.dart`). See `OpenUiButton._onTap`.
- Forms: the `Form` builder wraps its body in
  `OpenUiFormScope(formName: name, child: ...)`. A field writes its value
  on every change: `OpenUiFormScope.formOf(context)?.setValue(name, v)`
  (read it back with `.value(name)`). Any action run inside the form
  (including a Button without action, the upstream submit) sends the
  form values with the message.
- A `$binding` slot: `props.binding('value')` gives the current value
  and `binding.set(context, v)` writes the store. Write both the binding
  and the form state.
- Streaming: `RendererScope.maybeFind(context)` (from
  `package:openui/openui.dart`) has `isStreaming` and `incomplete` (the
  statement ids still being written). Disable taps while
  `isStreaming && incomplete.contains(props.statementId)`, as
  `OpenUiButton` does. The renderer already gives `null` for an action
  slot in that case.
- The host side: `OpenUiActionHandler` has `sendToAssistant(text,
  context:, formValues:)`, `openUrl(url)` and `onStateChanged(state)`.
  `OpenUiActionHandler.composeMessage` turns the three parts into one
  plain-text chat message. `OpenUiScope.maybeOf(context)?.handler` gives
  a component direct access (the Card sources strip uses it for URLs).

## 7. Theme tokens

Read everything from `lib/openui/openui_theme.dart`. Rules from
`docs/DESIGN.md`: Material 3 Expressive, one button family (`MorphTap`
pills, flat fill), no glow, no coloured `BoxShadow`, no gradient on a
control, icons from HugeIcons only.

| Token | Value |
|---|---|
| `OpenUiTokens.gap(name)` | none 0, xs 4, s 8, m 12, l 16, xl 24, 2xl 32 (default 12) |
| `OpenUiTokens.rootGap` | 14, between the blocks of the chat root `Card` |
| `radiusCard` / `radiusInner` / `radiusChip` / `radiusPill` | 16 / 12 / 8 / 999 |
| `cardPadding` / `innerPadding` | 14 all round / 12 x 10 |
| `OpenUiTheme.of(context)` | `cardColor`, `sunkColor`, `borderColor` (card outline), `hairline` (row dividers), `headerRule` (under a table header), `segmentStripColor` / `segmentSelectedColor` / `onSegmentSelectedColor` (Tabs), `textColor`, `mutedColor`, `accent`, `success`, `warning`, `danger`, `info`, `statusColor(v)`, `statusFill(v)`, `cardDecoration(variant:)`, `titleStyle`, `bodyStyle`, `captionStyle`, `chatFontFamily`, `chatFontSize` |

The root `Card` has no surface of its own (the AI answer has no
bubble). Inner blocks use `cardDecoration()`. For markdown text use
`MarkdownMessage` the way `TextContent` does. For charts and tables,
reuse `lib/widgets/charts/` and `lib/widgets/chuk_table.dart` where they
fit.

Light mode: `outlineVariant` is near black there, so never draw a line
with it directly. Use `borderColor`, `hairline` or `headerRule`.

Icons: `OpenUiIcon` takes its size and colour from, in order, its own
arguments, an `OpenUiIconStyle` above it, an `IconTheme` a parent set
(`IconTheme.merge` in a button), then 18 px in the text colour.
`OpenUiView` resets the icon theme at its root, so the chat around a
program does not change its icons.

Texts: fixed UI texts (placeholders, button labels, tooltips,
validation messages) come from the app l10n through
`openUiStrings(context)` (`lib/openui/openui_strings.dart`), keys
`openUi*` in `lib/l10n/strings_*.dart`. Without app localizations
(tests, the gallery) they are English. Texts the model writes are never
translated, and texts sent to the model (action labels, "Selected item")
stay English.

## 8. Gallery

```bash
# all canonical samples, dark/light switch, stream replay per sample
flutter run -d linux -t lib/openui/dev/gallery_main.dart
# one program from a file; edits reload by themselves
flutter run -d linux -t lib/openui/dev/gallery_main.dart \
  --dart-define=OPENUI_FILE=_scratch/my_view.oui
```

Run from the repository root. Put scratch programs in `_scratch/`.

## 9. Tests

RAM is tight on this host: always `--concurrency=1`, never the whole
suite. A run can fail to start with "Unable to connect to
flutter_tester process"; that is the host, run the file again.

```bash
flutter analyze lib/openui test/openui vendor/openui vendor/openui_core
flutter test --concurrency=1 test/openui
(cd vendor/openui_core && dart test)
(cd vendor/openui && flutter test --concurrency=1 test/src/<file>)
```

- `openui_test_helper.dart`: `pumpOpenUi(tester, source, ...)` returns a
  `RecordingOpenUiHandler` (`messages`, `urls`, `states`);
  `openUiTestApp`, `openUiTestTheme`, `readOpenUiFixtures`.
- `openui_fixtures_test.dart`: every fixture parses with zero errors and
  renders without an exception; it prints the unknown component names.
- `openui_signatures_test.dart`: signatures match upstream; it prints
  the missing components.
- "all fixtures render with no unknown component" and "all 86 upstream
  components are registered" must stay green.
- Add your own widget tests as `test/openui/components/<file>_test.dart`.

## 10. Language support (vendored core)

Statements `name = expr`, `$var = default`, `name = Query("tool", {args},
{defaults}, refreshSeconds?)` (interval clamped to 5 s .. 1 day, paused
while streaming), `name = Mutation("tool", {args})`;
positional arguments only; forward references; `//` and `#` comments;
fences with prose around them (inline mode), also an open fence while
streaming. Expressions: literals, arrays, objects, `a.b`, `a[i]`, array
pluck (`rows.title`), ternary, `+ - * / %`, comparisons, `&& || !`.
Builtins: `@Count @Sum @Avg @Min @Max @First @Last @Filter(array, field,
op, value) @Sort(array, field, dir?) @Round(n, decimals?) @Abs @Floor
@Ceil @Each(array, "name", template)`. Actions: `Action([...])` with
`@ToAssistant(msg, ctx?) @OpenUrl(url) @Run(ref) @Set($v, value)
@Reset($a, ...)`, a bare step, or `{type: "continue_conversation",
context}` / `{type: "open_url", url}`. A `Query` without a tool executor
shows its defaults. Details: `vendor/openui_core/NOTICE.md`.

## 11. Credits

- OpenUI Lang and the upstream component schemas, examples and prompts:
  thesysdev/openui, MIT, Copyright (c) 2011-2024 Thesys Inc. The
  fixtures in `test/openui/fixtures/` are upstream example programs.
- The Flutter port (`vendor/openui_core`, `vendor/openui`):
  mtwichel/openui_flutter, MIT, Copyright (c) 2026 Very Good Ventures.

## 12. Chat integration

The model writes normal markdown and puts a UI in ONE
```` ```openui-lang ```` fence (```` ```openui ```` works too). The
chat draws each program with `OpenUiView`; the text around it stays
markdown. Tools never make UI.

| Part | Where |
|---|---|
| Fence split (pure Dart) | `lib/utils/openui_fence.dart`: `splitOpenUiFences`, `stripOpenUiPrograms`, `hasOpenUiProgram` |
| Bubble | `lib/widgets/message_bubble/rich_blocks.dart`: `_openUiPartsOf`, `_buildOpenUiContent` |
| View + handler + memory | `lib/widgets/openui_message_block.dart`: `OpenUiMessageBlock`, `ChatOpenUiActionHandler`, `safeOpenUiUri`, `OpenUiViewMemory` |
| Send path | `_sendOpenUiMessage` in `chat_ui_desktop.dart` and `chat_ui_mobile.dart`, through `ChatMessageListItem.onOpenUiMessage` to `MessageBubble.onOpenUiMessage` |
| Prompt | skill `assets/skills/openui/SKILL.md` (generated), one line in `ToolPromptBuilder._visualOutputProtocol` |
| Licence | `lib/openui/openui_license.dart`, called in `main()` |

Rendering:

- A closed fence renders with `isStreaming: false`. An open fence (no
  closing line) runs to the end of the text; it renders with
  `isStreaming: true` while the message streams, else as a finished
  program (a model that forgot the closing line).
- While streaming, a last line that can still become an opener
  (```` ``` ````, ```` ```open ````) is hidden, so no half fence shows.
- An opener inside another code block (for example a ```` ```` ```` md
  block) is code, not a program.
- The markdown parts keep `<chart>`/`<map>`/`<email>`/`<weather>`/
  `<news>`/`<image>`/`<diff>`. Rich tags inside a fence are not parsed.

Actions:

- `sendToAssistant` composes the text with
  `OpenUiActionHandler.composeMessage` (label, context, form values) and
  sends it as a user message in the same chat. It uses the `voiceText`
  send path: no attachments, no reply quote, and the composer draft
  stays. While an answer is on the way, the chat shows "Please wait" and
  sends nothing. Old messages stay interactive.
- `openUrl` opens only `http`, `https` (with a host), `mailto` and `tel`
  (`safeOpenUiUri`), in an external application. The renderer applies
  the same rule (`safeOpenUrl` in `vendor/openui`) before it calls
  `onOpenUrl`, so both filter alike.

State across rebuilds: each program has the key
`openui:<message id>:<index>` (the index counts the programs of the
whole message). `OpenUiViewMemory` keeps the `OpenUiForms` and the last
`$state` snapshot per `<message id>#<index>` (the 64 most recent), and
`OpenUiView(forms:, initialState:)` gets them back after a scroll or a
layout change. A form field must read its start value from
`OpenUiFormScope.formOf(context)?.value(name)` for this to show.

Other text consumers:

| Consumer | What it does with a program |
|---|---|
| Copy, share, JSON export | Keeps the raw text (the program is the answer) |
| Chat search index | Keeps the raw text (titles and cells are searchable) |
| Completion notification, Android foreground notification | `stripOpenUiPrograms` |
| Voice call context, voice task result | `stripOpenUiPrograms`; a program-only result speaks `kVoiceOpenUiOnlyText` |
| Sidebar preview fallback (`StoredChat.previewText`) | `stripOpenUiPrograms` |
| Title generation | Reads the user message only; no change |
| Phone links (`phone_linkify.dart`) | The program never reaches markdown; no change |
| Reasoning / answer split | By protocol, not by text; no change |

Skill: `tool/gen_openui_skill.dart` builds the skill from
`chukOpenUiLibrary` (signatures by group, in positional order, with the
one-line descriptions) plus a hand-written header and three examples.
Long types that repeat are written once as type names (`Rules`,
`EntityRow`, `Content` = the shared start of the child unions) and the
signatures use the names. The freshness test expands the names again and
compares with the exact signature. It imports Flutter, so it runs under
`flutter test`:

```bash
flutter test tool/gen_openui_skill.dart   # writes SKILL.md, then runs gen_skills
```

`test/openui/openui_skill_freshness_test.dart` fails when SKILL.md is
stale. Run the tool again after a component change.
