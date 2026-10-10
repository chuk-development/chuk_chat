# OpenUI research for chuk_chat

Status: research only. No code in `lib/` uses OpenUI yet.
Date: 2026-10-10.

## 1. Summary

- Upstream OpenUI has **86 distinct components** in two built-in libraries.
  The general library (`openuiLibrary`, root `Stack`) has 82.
  The chat library (`openuiChatLibrary`, root `Card`) has 84.
  The number "about 45" in the Flutter port's comparison document is old.
- The full chat-library system prompt is **about 14,000 tokens** (54 KB).
  That is too large to send with every chuk_chat request.
  A 30-component subset without examples is about 2,200 tokens.
- The Flutter port (`openui_flutter`) has a **good parser and a weak
  component library**. The lexer and the statement parser read all 11
  canonical upstream examples with zero syntax errors. The evaluator and
  the 17 components do not match the canonical language and schemas.
- The pub.dev packages (`0.0.1-dev.2`, 2026-05-18) are **older than** the
  positional-argument and `Action([...])` work in git (2026-05-25/26).
  The pub.dev release does not read canonical positional output.
- All four port packages resolve together with the chuk_chat lock
  (Flutter 3.47.0, Dart 3.13.0). No current chuk_chat version changes.
- Recommendation: **(b)**. Vendor `openui_core` and `openui` under
  `vendor/`, fix the language gaps there, and write our own component
  library with chuk_chat widgets. See section 9.

## 2. Sources and versions

| Item | Value |
|---|---|
| Upstream repo | https://github.com/thesysdev/openui, HEAD `99888a5b15c1` (2026-10-10) |
| Upstream npm packages used for generation | `@openuidev/react-ui@0.17.1`, `@openuidev/react-lang@0.4.0`, `@openuidev/lang-core@0.4.0` |
| Upstream library sources | `packages/react-ui/src/genui-lib/openuiLibrary.tsx`, `openuiChatLibrary.tsx`, `unions.ts`, `rules.ts`, `prompt-options/index.ts`, `Charts/*.ts` |
| Upstream language sources | `packages/lang-core/src/parser/{lexer,parser,statements,builtins,prompt}.ts`, `packages/lang-core/src/runtime/evaluator.ts` |
| Upstream spec | `docs/content/docs/openui-lang/specification-v05.mdx` |
| Flutter port repo | https://github.com/mtwichel/openui_flutter, HEAD `e1525eed` (2026-05-26), 63 commits |
| Flutter port pub.dev | `openui_core`, `openui`, `openui_components`, `openui_mcp`, all `0.0.1-dev.2`, published 2026-05-18, no verified publisher |
| Local clones | `_scratch/openui`, `_scratch/openui_flutter` (gitignored) |
| Generated artifacts | `_scratch/openui_npm/prompt-*.txt`, `components-*.json`, `table_fixed.md` |
| Parser probe | `_scratch/openui_probe/test/probe_test.dart`, samples in `_scratch/openui_probe/samples/` |

Method: the component list and the prompt sizes come from the real
library objects. A Node script imports `@openuidev/react-ui/genui-lib` and
calls `library.toSpec()` and `library.prompt(options)`
(`_scratch/openui_npm/gen.mjs`). The signatures are therefore the Zod
schemas in their positional order, not the documentation.

Note: the checked-in upstream file `docs/generated/chat-system-prompt.spec.json`
is stale. It has 58 components and has no `sources` argument on `Card`.
Do not use it as a reference.

## 3. Upstream component catalogue

"In" column: G = general library (`openuiLibrary`), C = chat library
(`openuiChatLibrary`). The argument order is the positional order.
`?` marks an optional argument. Long child unions are shortened to
"union of N components".

Differences between the two libraries:

- Only in G: `Stack`, `Modal`.
- Only in C: `FollowUpBlock`, `FollowUpItem`, `SectionBlock`, `SectionItem`.
- Different signature:
  - `Card` in G is `Card(children, variant?, direction?, gap?, align?, justify?, wrap?)`
    (a styled flex box).
  - `Card` in C is `Card(children, sources?)`. It is the locked root of
    every chat answer. It is always vertical. `sources` is
    `{url?, title, sourceName}[]`. It shows a sources strip and backs
    inline `[n]` citations in `TextContent`.
  - `TabItem`, `AccordionItem`, `Carousel` in C accept more child types
    (the chat blocks).
- The Lang names `BarChart`, `LineChart`, `AreaChart` map to the React
  components `BarChartCondensed`, `LineChartCondensed`, `AreaChartCondensed`.
- Form fields share one `rules` object:
  `{required?, email?, url?, numeric?, min?, max?, minLength?, maxLength?, pattern?}`
  (`genui-lib/rules.ts`).

| # | Component | Positional args (order) | Renders | In |
|---|---|---|---|---|
| 1 | `Card` | `children: union of 36 components[], variant?: "card" / "sunk" / "clear", direction?: "row" / "column", gap?: "none" / "xs" / "s" / "m" / "l" / "xl" / "2xl", align?: "start" / "center" / "end" / "stretch" / "baseline", justify?: "start" / "center" / "end" / "between" / "around" / "evenly", wrap?: boolean` | Styled container. variant: "card" (default, elevated) / "sunk" (recessed) / "clear" (transparent). Always full width. Accepts all Stack flex params... | G+C |
| 2 | `CardHeader` | `title?: string, subtitle?: string` | Header with optional title and subtitle | G+C |
| 3 | `TextContent` | `text: string, size?: "small" / "default" / "large" / "small-heavy" / "large-heavy"` | Text block. Supports markdown. Optional size: "small" / "default" / "large" / "small-heavy" / "large-heavy". | G+C |
| 4 | `MarkDownRenderer` | `textMarkdown: string, variant?: "clear" / "card" / "sunk"` | Renders markdown text with optional container variant | G+C |
| 5 | `Callout` | `variant: "info" / "warning" / "error" / "success" / "neutral", title: string, description: string, visible?: $binding<boolean>` | Callout banner. Optional visible is a reactive $boolean — auto-dismisses after 3s by setting $visible to false. | G+C |
| 6 | `TextCallout` | `variant?: "neutral" / "info" / "warning" / "success" / "danger", title?: string, description?: string` | Text callout with variant, title, and description | G+C |
| 7 | `Image` | `alt: string, src?: string` | Image with alt text and optional URL | G+C |
| 8 | `ImageBlock` | `src: string, alt?: string` | Image block with loading state | G+C |
| 9 | `ImageGallery` | `images: {src: string, alt?: string, details?: string}[]` | Gallery grid of images with modal preview | G+C |
| 10 | `CodeBlock` | `language: string, codeString: string` | Syntax-highlighted code block | G+C |
| 11 | `InlineHeader` | `heading: string, description?: string` | Compact section heading with an optional one-line description, for use inside cards. | G+C |
| 12 | `Table` | `columns: Col[]` | Data table — column-oriented. Each Col holds its own data array. | G+C |
| 13 | `Col` | `label: string, data: any, type?: "string" / "number" / "action"` | Column definition — holds label + data array | G+C |
| 14 | `EditableTable` | `name?: string, columns?: {type: "text"/"number"/"date-single"/"select"/"url", key?, header?, width?, options?: {value, label}[]}[], data?: {id: string, values: (string/number)[]}[]` | Spreadsheet-like table whose cells the user can edit inline (text, number, url, date, select columns); edits are saved back as a form field | G+C |
| 15 | `BarChart` | `labels: string[], series: Series[], variant?: "grouped" / "stacked", xLabel?: string, yLabel?: string, height?: number` | Vertical bars; use for comparing values across categories with one or more series | G+C |
| 16 | `LineChart` | `labels: string[], series: Series[], variant?: "linear" / "natural" / "step", xLabel?: string, yLabel?: string, height?: number` | Lines over categories; use for trends and continuous data over time | G+C |
| 17 | `AreaChart` | `labels: string[], series: Series[], variant?: "linear" / "natural" / "step", xLabel?: string, yLabel?: string, height?: number` | Filled area under lines; use for cumulative totals or volume trends over time | G+C |
| 18 | `RadarChart` | `labels: string[], series: Series[]` | Spider/web chart; use for comparing multiple variables across one or more entities | G+C |
| 19 | `HorizontalBarChart` | `labels: string[], series: Series[], variant?: "grouped" / "stacked", xLabel?: string, yLabel?: string` | Horizontal bars; prefer when category labels are long or for ranked lists | G+C |
| 20 | `Series` | `category: string, values: number[]` | One data series | G+C |
| 21 | `PieChart` | `labels: string[], values: number[], variant?: "pie" / "donut", appearance?: "circular" / "semiCircular"` | Circular slices; use plucked arrays: PieChart(data.categories, data.values) | G+C |
| 22 | `RadialChart` | `labels: string[], values: number[]` | Radial bars; use plucked arrays: RadialChart(data.categories, data.values) | G+C |
| 23 | `SingleStackedBarChart` | `labels: string[], values: number[]` | Single horizontal stacked bar; use plucked arrays: SingleStackedBarChart(data.categories, data.values) | G+C |
| 24 | `Slice` | `category: string, value: number` | One slice with label and numeric value | G+C |
| 25 | `ScatterChart` | `datasets: ScatterSeries[], xLabel?: string, yLabel?: string` | X/Y scatter plot; use for correlations, distributions, and clustering | G+C |
| 26 | `ScatterSeries` | `name: string, points: Point[]` | Named dataset | G+C |
| 27 | `Point` | `x: number, y: number, z?: number` | Data point with numeric coordinates | G+C |
| 28 | `Form` | `name: string, buttons: Buttons, fields?: FormControl[]` | Form container with fields and explicit action buttons | G+C |
| 29 | `FormControl` | `label: string, input: union of 9 components, hint?: string` | Field with label, input component, and optional hint text | G+C |
| 30 | `Label` | `text: string` | Text label | G+C |
| 31 | `Input` | `name: string, placeholder?: string, type?: "text" / "email" / "password" / "number" / "url", rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<string>` |  | G+C |
| 32 | `TextArea` | `name: string, placeholder?: string, rows?: number, rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<string>` |  | G+C |
| 33 | `Select` | `name: string, items: SelectItem[], placeholder?: string, rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<string>, size?: "small" / "medium" / "large"` |  | G+C |
| 34 | `SelectItem` | `value: string, label: string` | Option for Select | G+C |
| 35 | `DatePicker` | `name: string, mode?: "single" / "range", rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<any>` |  | G+C |
| 36 | `Slider` | `name: string, variant: "continuous" / "discrete", min: number, max: number, step?: number, defaultValue?: number[], label?: string, rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<number[]>` | Numeric slider input; supports continuous and discrete (stepped) variants | G+C |
| 37 | `CheckBoxGroup` | `name: string, items: CheckBoxItem[], rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<Record<string, boolean>>` |  | G+C |
| 38 | `CheckBoxItem` | `label: string, description: string, name: string, defaultChecked?: boolean` |  | G+C |
| 39 | `RadioGroup` | `name: string, items: RadioItem[], defaultValue?: string, rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., value?: $binding<string>` |  | G+C |
| 40 | `RadioItem` | `label: string, description: string, value: string` |  | G+C |
| 41 | `SwitchGroup` | `name: string, items: SwitchItem[], variant?: "clear" / "card" / "sunk", value?: $binding<Record<string, boolean>>` | Group of switch toggles | G+C |
| 42 | `SwitchItem` | `label?: string, description?: string, name: string, defaultChecked?: boolean` | Individual switch toggle | G+C |
| 43 | `ChipItem` | `value: string, label: string, icon?: Icon, disabled?: boolean` | A single selectable chip inside a Chips group, with a value, label and optional icon. | G+C |
| 44 | `Chips` | `name: string, type?: "single" / "multiple", items?: ChipItem[], rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., defaultValue?: string / string[]` | A form field of compact selectable chips for choosing one or many short options; the selection is stored under `name`. | G+C |
| 45 | `OptionCard` | `value: string, title: string, subtitle?: string, topContent?: Icon / Image, disabled?: boolean` | A single selectable card inside an OptionCards group, with a value, title, optional subtitle and an optional Icon or Image on top. | G+C |
| 46 | `OptionCards` | `name: string, type?: "single" / "multiple", items?: OptionCard[], rules?: {required?: boolean, email?: boolean, url?: boolean, numeric?: bool..., defaultValue?: string / string[]` | A form field of selectable cards (title, optional subtitle, optional icon or image) laid out in a responsive grid for choosing one or many options;... | G+C |
| 47 | `Button` | `label: string, action?: ActionExpression, variant?: "primary" / "secondary" / "tertiary", type?: "normal" / "destructive", size?: "extra-small" / "small" / "medium" / "large"` | Clickable button | G+C |
| 48 | `Buttons` | `buttons: Button[], direction?: "row" / "column"` | Group of Button components. direction: "row" (default) / "column". | G+C |
| 49 | `IconButton` | `name: string, icon: Icon, action?: ActionExpression, variant?: "primary" / "secondary" / "tertiary", size?: "extra-small" / "small" / "medium" / "large", shape?: "square" / "circle"` | Icon-only button. name is the accessible label and the action label; icon is an Icon; action fires on click. | G+C |
| 50 | `Stack` | `children: any[], direction?: "row" / "column", gap?: "none" / "xs" / "s" / "m" / "l" / "xl" / "2xl", align?: "start" / "center" / "end" / "stretch" / "baseline", justify?: "start" / "center" / "end" / "between" / "around" / "evenly", wrap?: boolean` | Flex container. direction: "row"/"column" (default "column"). gap: "none"/"xs"/"s"/"m"/"l"/"xl"/"2xl" (default "m"). align: "start"/"center"/"end"/... | G |
| 51 | `Tabs` | `items: TabItem[]` | Tabbed container | G+C |
| 52 | `TabItem` | `value: string, trigger: string, content: union of 33 components[]` | value is unique id, trigger is tab label, content is array of components | G+C |
| 53 | `Accordion` | `items: AccordionItem[]` | Collapsible sections | G+C |
| 54 | `AccordionItem` | `value: string, trigger: string, content: union of 33 components[]` | value is unique id, trigger is section title | G+C |
| 55 | `Steps` | `items: StepsItem[]` | Step-by-step guide | G+C |
| 56 | `StepsItem` | `title: string, details: string` | title and details text for one step | G+C |
| 57 | `Carousel` | `children: (union of 33 components)[][] (array of slides), variant?: "card" / "sunk"` | Horizontal scrollable carousel | G+C |
| 58 | `Separator` | `orientation?: "horizontal" / "vertical", decorative?: boolean` | Visual divider between content sections | G+C |
| 59 | `TagBlock` | `tags: string[], size?: "sm" / "md" / "lg"` | tags is an array of strings; optional size sm / md / lg | G+C |
| 60 | `Tag` | `text: string, icon?: Icon, size?: "sm" / "md" / "lg", variant?: "neutral" / "info" / "success" / "warning" / "danger"` | Styled tag/badge with optional Icon and variant | G+C |
| 61 | `Icon` | `name: string, category?: string` | A lucide icon by kebab-case name (e.g. 'circle-check'). Optional category picks a topical fallback when the name doesn't resolve. | G+C |
| 62 | `EntityList` | `rows?: {left: string, right: string, rightVariant?: "text" / "number"}[], size?: "small" / "default", header?: {left: string, right: string, rightVariant?: "text" / "number"}, footer?: {left: string, right: string, rightVariant?: "text" / "number"}` | Two-column key/value rows (left label, right value). size 'default' supports optional header and footer rows; rightVariant 'number' uses tabular nu... | G+C |
| 63 | `ListBlock` | `items: ListItem[], variant?: "number" / "image", size?: "default" / "small"` | A list of items with number or image indicators. Each item can optionally have an action. size small renders a compact list. | G+C |
| 64 | `ListItem` | `title: string, subtitle?: string, image?: {src: string, alt: string}, actionLabel?: string, action?: ActionExpression` | Item in a ListBlock — displays a title with an optional subtitle and image. When action is provided, the item becomes clickable. | G+C |
| 65 | `Text` | `variant?: "text" / "number", value: string, subtext?: string, subtextVariant?: "text" / "number" / "metric", size?: "xs" / "sm" / "md" / "lg"` | Plain text line with optional subtext. variant 'number' uses tabular number styling; subtextVariant 'metric' colors a leading +/- subtext green/red. | G+C |
| 66 | `BoldText` | `variant?: "text" / "number", value: string, subtext?: string, subtextVariant?: "text" / "number" / "metric", size?: "xs" / "sm" / "md" / "lg"` | Emphasized (bold) text line with optional subtext. variant 'number' uses tabular number styling; subtextVariant 'metric' colors a leading +/- subte... | G+C |
| 67 | `IconText` | `icon: Icon, iconVariant?: "neutral" / "info" / "success" / "warning" / "danger" / "inverted" ..., iconSize?: "xs" / "s" / "m" / "l" / "xl" / "sm" / "md" / "lg", title: string, subtitle?: string, bold?: boolean, layout?: "horizontal" / "vertical"` | An icon badge with a title and optional subtitle, laid out horizontally or vertically. iconVariant sets the badge color. | G+C |
| 68 | `ImageText` | `src: string, alt?: string, title: string, subtitle?: string, bold?: boolean, layout?: "horizontal" / "vertical", imageSize?: number` | A small square image (thumbnail/avatar) with a title and optional subtitle. src must be a real image URL. | G+C |
| 69 | `ImageTextLarge` | `src: string, alt?: string, title: string, subtitle?: string, bold?: boolean` | A full-width banner image above a bold title and optional subtitle. src must be a real image URL. | G+C |
| 70 | `MetricIndicatorInline` | `value: string, subtext?: string, trend?: {direction: "up" / "down", value: number}` | Headline metric value with an optional +/- percentage trend and subtext, all on one line. | G+C |
| 71 | `MetricIndicatorWithStrikethrough` | `value: string, subtext?: string, previousValue?: string, trend?: {direction: "up" / "down", value: number}` | Headline metric value with an optional struck-through previousValue, a +/- percentage trend, and subtext below. | G+C |
| 72 | `SnippetCardItem` | `id?: string, lhs: IconText / ImageText, rhs?: Text / BoldText` | One row-style snippet card: a label on the left (IconText or ImageText) and an optional value on the right (Text or BoldText). | G+C |
| 73 | `SnippetCardBlock` | `items: SnippetCardItem[], layout?: "grid", responsive?: boolean, action?: ActionExpression, gap?: number / string` | A responsive grid of compact label/value cards (2 per row) for showing several short facts side by side; optionally clickable with a shared action. | G+C |
| 74 | `OverviewCardItem` | `id?: string, top: IconText / ImageText / Text, bottom?: MetricIndicatorInline` | One overview card: a heading slot at the top (IconText, ImageText or Text) and an optional MetricIndicatorInline at the bottom. | G+C |
| 75 | `OverviewCardBlock` | `items: OverviewCardItem[], layout?: "grid" / "carousel", responsive?: boolean, action?: ActionExpression, gap?: number / string` | A grid or horizontal carousel of compact overview cards, each with a heading (icon/image/text) on top and an inline metric below; optionally clicka... | G+C |
| 76 | `ContextCardItem` | `id?: string, title: string / Tag, body?: string, bgColor?: "gray", bgImageSrc?: string, bgImageAlt?: string` | A single card inside a ContextCardBlock: a title (plain string or Tag), an optional markdown body, and an optional gray tint or background image. | G+C |
| 77 | `ContextCardBlock` | `items: ContextCardItem[], layout?: "grid" / "carousel", responsive?: boolean, action?: ActionExpression, gap?: number / string` | A grid or carousel of compact tinted context cards (title or tag plus a short bold body); an optional action makes every card clickable. | G+C |
| 78 | `CompositeCardItem` | `id?: string, header?: IconText / ImageText / ImageTextLarge / Text / Image, body?: union of 11 components[], footer?: {price?: BoldText / MetricIndicatorWithStrikethrough, button?: Button}` | A single card inside a CompositeCardBlock: an optional header (icon/image/text), a stack of body elements (text, metrics, charts, lists, tags), and... | G+C |
| 79 | `CompositeCardBlock` | `items: CompositeCardItem[], layout?: "grid" / "carousel", responsive?: boolean, action?: ActionExpression, gap?: number / string` | A two-per-row grid or carousel of rich cards, each with an optional header, stacked body content (text, metrics, charts, lists, tags) and a price/b... | G+C |
| 80 | `VisualCardItem` | `body: BoldText, id?: string, bgImageSrc?: string, tag?: Tag, bgImageAlt?: string` | A single photo-first card inside a VisualCardBlock: a BoldText body panel, an optional Tag, and a background image (bgImageSrc must be a real URL; ... | G+C |
| 81 | `VisualCardBlock` | `items: VisualCardItem[], layout?: "grid" / "carousel", responsive?: boolean, action?: ActionExpression, gap?: number / string` | A grid or carousel of photo-first cards: a full-bleed background image with a tag on top and a bold text panel at the bottom; an optional action ma... | G+C |
| 82 | `Modal` | `title: string, open?: $binding<boolean>, children: union of 33 components[], size?: "sm" / "md" / "lg"` | Modal dialog. open is a reactive $boolean binding — set to true to open, X/Escape/backdrop auto-closes. Put Form with buttons inside children. | G |
| 83 | `FollowUpBlock` | `items: FollowUpItem[]` | List of clickable follow-up suggestions placed at the end of a response | C |
| 84 | `FollowUpItem` | `text: string` | Clickable follow-up suggestion — when clicked, sends text as user message | C |
| 85 | `SectionBlock` | `sections: SectionItem[], isFoldable?: boolean` | Collapsible accordion sections. Auto-opens sections as they stream in. Use SectionItem for each section. | C |
| 86 | `SectionItem` | `value: string, trigger: string, content: union of 37 components[]` | Section with a label and collapsible content — used inside SectionBlock | C |

### 3.1 Component groups (as the prompt shows them)

General library groups: Layout (Stack, Tabs, TabItem, Accordion,
AccordionItem, Steps, StepsItem, Carousel, Separator, Modal), Content,
Tables, Charts (2D), Charts (1D), Charts (Scatter), Forms, Buttons,
Data Display, Cards.

Chat library groups: Content, Tables, Charts (2D), Charts (1D),
Charts (Scatter), Forms, Buttons, Lists & Follow-ups, Sections, Layout
(no Stack), Data Display, Cards.

## 4. OpenUI Lang v0.5 essentials

Source: `specification-v05.mdx`, `lang-core/src/parser/builtins.ts`,
`lang-core/src/parser/prompt.ts`.

### 4.1 Statements

One statement per line. Three kinds:

| Kind | Syntax | Example |
|---|---|---|
| Component / value | `name = Expression` | `header = CardHeader("Title")` |
| State | `$name = default` | `$days = "7"` |
| Data | `name = Query(...)` / `name = Mutation(...)` | `data = Query("tool", {}, {rows: []})` |

- `root = Root(...)` is the entry point. The root name comes from the
  library (`Stack` or `Card`). Without `root`, nothing renders.
- Forward references are allowed (hoisting). The parser resolves
  references after the full input.
- Every statement except `root` must be reachable from `root`. The
  renderer drops unreachable statements.
- Comments are not part of the language. The parser strips `//` and `#`
  line comments outside strings, because models sometimes write them.

### 4.2 Expressions

Strings (double quotes, backslash escapes), numbers, `true`/`false`,
`null`, arrays, objects `{key: value}`, component calls `Type(a, b)`,
builtin calls `@Name(...)`, references, `$state` references, member access
`a.b.c`, index access, ternary `c ? a : b`, binary operators
`+ - * / %`, `== != > < >= <=`, `&& ||`, unary `! -`.

**Array pluck:** `data.rows.title` on an array returns the `title` of each
element. `Table` columns and chart series use this a lot
(`lang-core/src/runtime/evaluator.ts`).

### 4.3 Positional arguments

Arguments are positional only. The position maps to the prop by the Zod
key order of the component schema. Named arguments (`gap: "l"`) are not
supported. Trailing optional arguments can be left out. A `null` fills a
skipped middle slot.

### 4.4 Reactive state

`$name = default` declares a variable. A form input that receives `$name`
in its `value` slot binds two ways. A change re-evaluates every expression
and every `Query` that reads the variable. The prompt teaches `$state` only
when the `bindings` flag is on (default: on when tools are on).

Caution: the spec text shows `Select("days", $days, [...])`. The current
`Select` schema puts `value` in slot 5:
`Select("days", [items], null, null, $days)`. The upstream parser reports
a `type-mismatch` for the spec form. Trust the generated signatures, not
the spec examples.

### 4.5 Query and Mutation

- `data = Query("tool", {args}, {defaults}, refreshSeconds?)`. It runs on
  load. It renders the defaults until the data arrives. It fetches again
  when a `$variable` in `args` changes, and on the refresh interval.
- `result = Mutation("tool", {args})`. It does not run on load. `@Run(result)`
  runs it.

### 4.6 Builtins

All builtins use the `@` prefix. A bare `Count(...)` is not supported.

| Builtin | Signature |
|---|---|
| `@Count` | `(array) -> number` |
| `@Sum`, `@Avg`, `@Min`, `@Max` | `(numbers[]) -> number` |
| `@First`, `@Last` | `(array) -> element` |
| `@Filter` | `(array, field, op, value)`; op is `== != > < >= <= contains` |
| `@Sort` | `(array, field, direction?)` |
| `@Round` | `(number, decimals?)` |
| `@Abs`, `@Floor`, `@Ceil` | `(number)` |
| `@Each` | `(array, varName, template)`; lazy; the loop variable is only valid inline |

### 4.7 Actions

`Action([step, step, ...])` is the value of an `action` slot (for example
`Button("Save", Action([...]), "primary")`). Steps run in order. If
`@Run(mutation)` fails, the remaining steps do not run. A `Button` without
an action sends its label to the assistant.

| Step | Effect | Runtime type |
|---|---|---|
| `@ToAssistant("msg")` | Send a message to the LLM | `continue_conversation` |
| `@OpenUrl("url")` | Open the URL | `open_url` |
| `@Run(ref)` | Run a Mutation or fetch a Query again | `run` |
| `@Set($var, value)` | Set a variable | `set` |
| `@Reset($a, $b)` | Restore declared defaults | `reset` |

Some components take an action as an object literal instead, for example
`ListItem(..., { type: "continue_conversation", context: "Option A" })`.

### 4.8 Streaming rules

- The parser runs again on every chunk (`createStreamingParser`).
- `autoClose` closes open strings and brackets in the last, incomplete
  statement, so a partial statement still renders.
- References that are not yet defined stay unresolved and appear when
  their definition arrives.
- The prompt asks for this order: `root` first, then components, then data
  (leaf values) last. The UI shell appears at once and fills in.
- The chat prompt asks for one `FormControl` per statement, so a form
  streams field by field.

### 4.9 Prompt feature flags

`library.prompt(options)` takes: `preamble`, `additionalRules`, `examples`,
`toolExamples`, `tools`, `toolCalls` (Query/Mutation/@Run), `bindings`
($state/@Set/@Reset), `editMode` (output only changed statements, merged
with `mergeStatements`), `inlineMode` (prose plus fenced code).

## 5. How a chat answer carries OpenUI Lang

There are two modes upstream.

1. **Whole message (default chat mode).** The chat prompt starts with:
   "Your ENTIRE response must be valid openui-lang code - no markdown, no
   explanations". Prose goes inside the UI, in `TextContent` (it accepts
   markdown) or `MarkDownRenderer`. The answer is one `root = Card([...])`.
   `GenUIAssistantMessage.tsx` passes the full message to `<Renderer>`.
2. **Inline mode (`inlineMode: true`).** The model writes normal text and
   puts OpenUI Lang in a ```` ```openui-lang ```` fence. For a question it
   writes text only. `stripFences` in `lang-core/src/parser/parser.ts`
   takes the code from all fences (it also handles an open fence while
   streaming) and joins the blocks. The host shows the text outside the
   fences as chat. In edit mode the fence holds only the changed statements.

Message storage upstream (`react-ui/src/utils/sentinelParser.ts`): the
stored message uses the markers `]]>openui:content`, `]]>openui:context`
(JSON form state) and `]]>openui:end` (stream finished). `hasLangSyntax`
detects OpenUI Lang by the text ```` ```openui-lang ```` or a line that
starts with `root =`.

For chuk_chat, inline mode is the better fit. Most answers are markdown.
A fenced `openui-lang` block is a natural extension of the present
`<chart>`/`<map>` tags, and `message_bubble.dart` already splits a message
into text and special blocks.

## 6. System prompt size

Generated with the real libraries (`_scratch/openui_npm/gen.mjs`,
`gen2.mjs`, `subset.mjs`). Tokens counted with `js-tiktoken`. The two
encodings (o200k, cl100k) give almost the same numbers.

| Prompt | Characters | Tokens (o200k) |
|---|---:|---:|
| Chat library, default options (5 examples, rules) | 53,975 | 14,041 |
| Chat library, default options + `inlineMode` | 54,939 | 14,259 |
| Chat library, no options (signatures and syntax only) | 26,591 | 6,295 |
| Chat library, signatures section only | 23,480 | 5,647 |
| Chat library, the 5 examples only | 20,782 | 6,322 |
| General library, default options (6 examples) | 36,063 | 9,125 |
| General library, no options | 28,652 | 7,012 |
| General library + 2 tools + `editMode` + `inlineMode` | 48,024 | 12,115 |
| Subset of 30 chat components, no examples | 9,304 | 2,194 |
| Same subset + `inlineMode` | 10,264 | 2,412 |
| Upstream `benchmarks/system-prompt.txt` (small benchmark library) | 13,194 | about 3,300 |

Conclusion: do not send the full library prompt each turn. chuk_chat moved
blocks into skills to save about 1,100 tokens per round. A full OpenUI
prompt would add 14,000. Use a small subset, and put the long part
(signatures and examples) behind the `skill` tool, so the model loads it
only when it wants to draw UI.

Caveat: in the subset test, the chat `Card` signature still lists all 38
child types, because its Zod union is fixed. Our own library must define
its own root with only the components we ship.

## 7. The Flutter port

### 7.1 Packages

| Package | Kind | Lib lines | Test lines | Tests | Purpose |
|---|---|---:|---:|---:|---|
| `openui_core` | pure Dart | 5,491 | 6,423 | 536 | lexer, parser, streaming parser, evaluator, store, actions, library DSL, prompt |
| `openui` | Flutter | 1,332 | 2,000 | 66 | `Renderer` widget, query manager, error boundary, form-state cache |
| `openui_components` | Flutter | 1,858 | 633 | 35 | 17 components |
| `openui_mcp` | pure Dart | 76 | 215 | n/a | MCP `ToolProvider` on `mcp_dart` |

Line counts exclude generated `*.mapper.dart`.

### 7.2 Quality of `openui_core` and the `Renderer`

Tested here with Flutter 3.47.0 / Dart 3.13.0 at port HEAD `e1525eed`:

- `openui_core`: 536 tests pass. Line coverage of `lib/` is **100 %**
  (1,915 of 1,915 lines, 8 `coverage:ignore` markers). `dart analyze`:
  no issues.
- `openui`: 66 tests pass (each file run alone; a parallel run sometimes
  fails to start `flutter_tester` on this host, which is a host problem).
  `flutter analyze`: no issues.
- `openui_components`: 35 tests pass. Line coverage is **38 %** (245 of
  642). `flutter analyze`: no issues.
- The code is clean and well documented. The whole public API is marked
  `@experimental`. The project has one author and no commits since
  2026-05-26.

**Probe: canonical upstream output through the port.** The probe feeds the
11 upstream prompt examples (6 general, 5 chat) and 3 hand-written v0.5
programs into the port (`_scratch/openui_probe`). The upstream parser reads
all 14 with 0 errors (control run, `_scratch/openui_npm/ctrl.mjs`).

| Check | Result in the port |
|---|---|
| `parseProgram` (lexer + statements) | 11 of 11 upstream examples: **0 syntax errors** (up to 74 statements, 7 KB) |
| Streaming, one character per `push` | Final result equals the full parse, 0 errors. Speed is the same as upstream (7.2 KB: 1.9 s in the port, 1.7 s upstream, both reparse the full buffer on each chunk) |
| `Query("tool", {...}, {...}, 30)` statement | **Parse error.** The port only accepts its own `$var = @Query(tool, name: value)` |
| Fenced `openui-lang` with prose (inline mode) | **`StreamParser` fails** (4 errors). Only the one-shot `parse()` strips fences |
| `Action([...])` in a `Button` | The `Renderer` path accepts it (commit #18). The integration `parse()` still reports `Action` as an unknown component |
| Array pluck `data.rows.day` | **Not supported.** `_evalMember` returns `null` for a field of a list (`openui_core/lib/src/eval/evaluator.dart:298`) |
| Builtins | Only `@Count`, `@Filter` (other signature), `@Each`, plus port-only `@Map` and `@Query`. Missing: `@Sum @Avg @Min @Max @First @Last @Sort @Round @Abs @Floor @Ceil` |
| `@OpenUrl` | Missing |
| Query lifecycle | No defaults object, no fetch again on `$var` change, no refresh interval |
| Form validation `rules` | Not ported |
| Components | 5 to 17 unknown components per chat example. The port has 17 of 86 |

So: the syntax layer is close to v0.5. The evaluator, data layer and
components are not. Canonical chat output parses, but most of it does not
render.

### 7.3 Components in the port

The 17 registered components (`openui_components/lib/src/openui_library.dart`)
and their schema order compared with upstream:

| Port component | Port positional order | Upstream order | Match |
|---|---|---|---|
| `Stack` | children, direction, gap, align, justify, wrap | same | yes (gap enum is shorter) |
| `Card` | children, variant | chat: children, sources | partial |
| `CardHeader` | title, subtitle | same | yes |
| `Separator` | (none) | orientation, decorative | partial |
| `Callout` | text, variant | variant, title, description, visible | **no** |
| `TextContent` | text, size | same | yes |
| `MarkDownRenderer` | source | textMarkdown, variant | partial |
| `Image` | src, alt | alt, src | **no (swapped)** |
| `Input` | name, value, placeholder | name, placeholder, type, rules, value | **no** |
| `Select` | options, value | name, items, placeholder, rules, value, size | **no** |
| `Button` | label, action, variant | label, action, variant, type, size | yes |
| `Table` | columns, rows (row-oriented) | columns: Col[] (column-oriented) | **no** |
| `Col` | name, label | label, data, type | **no** |
| `Tabs` | children | items | partial |
| `TabItem` | label, content | value, trigger, content | **no** |
| `BarChart` | series, labels | labels, series, variant, ... | **no** |
| `LineChart` | series, name, values, labels | labels, series, variant, ... | **no** |

The port has no `Series`, `Form`, `FormControl`, `Buttons`, `CodeBlock`,
`Tag`, `ListBlock`, `FollowUpBlock`, `SectionBlock`, card blocks, or any
1D/scatter chart. The port's markdown uses `flutter_markdown_plus`.
chuk_chat uses `markdown_widget` and has its own theme, code blocks and
math. The port components would look different from the rest of the app.

### 7.4 SDK constraints and dependencies

| Package | Constraint | chuk_chat today | Resolved together |
|---|---|---|---|
| Dart SDK | `^3.9.0` (all packages) | `^3.13.0` | ok |
| Flutter SDK | `^3.35.0` (`openui`, `openui_components`) | 3.47.0 | ok |
| `fl_chart` | `^1.2.0` (components) | `^1.1.1`, locked 1.2.0 | ok, same version |
| `flutter_markdown_plus` | `^1.0.7` (components) | not used (chuk uses `markdown_widget` 2.3.2+8, `markdown` 7.3.1) | adds 1.0.12 |
| `url_launcher` | `^6.3.2` (components) | locked 6.3.2 | ok |
| `json_schema_builder` | `^0.1.3` (core) | not used | adds 0.1.7 (publisher `labs.flutter.dev`, from `flutter/genui`, 0.x, needs Dart >=3.10) |
| `dart_mappable` | `^4.5.0` (core, git HEAD only) | not used | adds 4.10.0 + `type_plus` 2.1.1 |
| `collection`, `meta` | `^1.19.1`, `^1.16.0` | locked 1.19.1, 1.19.0 | ok |
| `mcp_dart` | `^2.1.1` (`openui_mcp` only) | not used | not needed |

Resolution test (`_scratch/resolve_test`, a copy of chuk_chat's
`pubspec.yaml` and `pubspec.lock`):

- With the pub.dev packages: `flutter pub get` adds 8 packages
  (`openui`, `openui_core`, `openui_components`, `flutter_markdown_plus`,
  `json_schema_builder`, `decimal`, `email_validator`, `rational`).
  **No locked chuk_chat version changes.**
- With the git HEAD packages as path dependencies: the same, plus
  `dart_mappable` and `type_plus`. **No locked chuk_chat version changes.**
- `--enforce-lockfile` fails, as expected, because new packages are added.

The published `openui_core 0.0.1-dev.2` does not depend on `dart_mappable`.
The git HEAD does (`library/definitions.mapper.dart`, generated with
`build_runner`).

## 8. Licenses

Both projects use the MIT license. Keep the copyright line and the license
text in any copy.

| Project | File | Copyright line |
|---|---|---|
| thesysdev/openui | `LICENSE` (also in the npm package `@openuidev/react-ui`) | `Copyright (c) 2011-2024 Thesys Inc.` |
| mtwichel/openui_flutter | `LICENSE` and each `packages/*/LICENSE` | `Copyright (c) 2026 Very Good Ventures` |

If we vendor port code, put its `LICENSE` file in each vendored package
folder and add both lines to the in-app open-source licenses list. If we
copy upstream prompt text, rules or example programs, credit Thesys Inc.
the same way.

## 9. Recommendation

**Choose (b): vendor `openui_core` and `openui` under `vendor/`, and write
our own component library.**

Reasons against (a), depend on the pub packages:

- The pub release (2026-05-18) does not read canonical positional output.
  The positional and `Action` fixes exist only in git.
- The project has had no commit for 4.5 months, has one author, and marks
  the whole API `@experimental`. We cannot wait for upstream fixes.
- Only 4 of the 17 components match the canonical schema order. 9 are
  clearly different and 4 match in part. A model that follows the
  canonical prompt sends wrong props to them.
- `openui_components` adds `flutter_markdown_plus`, a second markdown
  renderer that does not use chuk_chat's markdown look.

Reasons for (b) and against (c), write everything from scratch:

- The parser layer is the hard part, and it is good: 536 tests, 100 % line
  coverage, 0 syntax errors on all canonical examples, correct streaming
  with `autoClose`. Writing this again costs weeks for no gain.
- It resolves with our lock today. Its only new direct dependencies are
  `json_schema_builder` and `dart_mappable`.

Work to do in the vendored copy (each item is a small, testable change):

1. Accept the canonical `name = Query("tool", {args}, {defaults}, refresh?)`
   and positional `Mutation("tool", {args})` statements.
2. Add array pluck in `_evalMember`.
3. Add the missing builtins and the canonical `@Filter(array, field, op, value)`.
4. Add `@OpenUrl`.
5. Strip fences in `StreamParser` (inline mode), as upstream `stripFences` does.
6. Optional: remove the `dart_mappable` dependency. Only
   `library/definitions.dart` uses it. This keeps `build_runner` out of
   chuk_chat.

Then write `lib/openui/` components with chuk_chat widgets (our markdown,
`chart_widget.dart` on `fl_chart`, our cards and buttons, M3 Expressive
per `docs/DESIGN.md`). Copy the upstream Zod schemas in the same
positional order, so the canonical prompt text stays valid. Start with a
subset of about 30 chat components (section 6), use inline mode, and load
the signatures through a skill. Replace `<chart>`, `<weather>`, `<news>`
step by step after that, not at once.
