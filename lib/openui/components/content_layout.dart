// OpenUI components, group B1: content and layout.
//
// Owner: agent B1. Add each component as one OpenUiComponentDef to
// [contentLayoutComponents]. Do not edit the registry
// (lib/openui/openui_library.dart). Rules: docs/OPENUI.md.
//
// Components of this file (upstream chat library unless noted):
//   Card (the chat root, with `sources`)
//   CardHeader
//   TextContent      (inline [n] citations when the Card has sources)
//   MarkDownRenderer
//   Callout          (a `$visible` binding hides it after 3 s)
//   TextCallout
//   Image
//   ImageBlock
//   ImageGallery     (grid; a tap opens the app's image viewer)
//   CodeBlock        (the app's own markdown code block)
//   InlineHeader
//   Separator
//   Stack            (general library)
//   Tabs
//   TabItem          (data-only: Tabs reads it)
//   Accordion
//   AccordionItem    (data-only: Accordion reads it)
//   Steps
//   StepsItem        (data-only: Steps reads it)
//   Carousel
//   SectionBlock     (opens sections while they stream in)
//   SectionItem      (data-only: SectionBlock reads it)
//   Modal            (general library; a `$open` binding shows a dialog)
//
// The builders live in the part files under content_layout/. The
// exact signatures are in
// test/openui/fixtures/upstream/components-chat.json (Stack and Modal:
// components-general.json).

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:openui/openui.dart';

import 'package:chuk_chat/constants.dart' show kRadiusDialog;
import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_component.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/pill_geometry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/measure_size.dart';

part 'content_layout/containers.dart';
part 'content_layout/disclosure.dart';
part 'content_layout/media.dart';
part 'content_layout/text_blocks.dart';

// The content unions of the upstream signatures. They differ only in
// their tails, so they share one base.
const String _kContentBase =
    'TextContent | MarkDownRenderer | CardHeader | Callout | TextCallout | '
    'CodeBlock | Image | ImageBlock | ImageGallery | Separator | '
    'HorizontalBarChart | RadarChart | PieChart | RadialChart | '
    'SingleStackedBarChart | ScatterChart | AreaChart | BarChart | '
    'LineChart | Table | TagBlock | Form | Buttons | IconButton | Steps | '
    'InlineHeader | EntityList | EditableTable | SnippetCardBlock | '
    'OverviewCardBlock | ContextCardBlock | CompositeCardBlock | '
    'VisualCardBlock';
const String _kContentLists = '$_kContentBase | ListBlock | FollowUpBlock';

/// The B1 components: content and layout.
final List<OpenUiComponentDef> contentLayoutComponents = <OpenUiComponentDef>[
  const OpenUiComponentDef(
    name: 'Card',
    group: 'Layout',
    description:
        'Vertical container for all content in a chat response. Children '
        'stack top to bottom automatically. Optional sources '
        '([{ title, sourceName, url }]) render as a Sources strip at the '
        'bottom and back inline [n] citations in TextContent.',
    params: <OpenUiParam>[
      OpenUiParam(
        'children',
        '($_kContentLists | SectionBlock | Tabs | Carousel)[]',
      ),
      OpenUiParam.opt(
        'sources',
        '{url?: string, title: string, sourceName: string}[]',
      ),
    ],
    builder: _buildCard,
  ),
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
  const OpenUiComponentDef(
    name: 'TextContent',
    group: 'Content',
    description:
        'Text block. Supports markdown. Optional size: "small" | "default" '
        '| "large" | "small-heavy" | "large-heavy".',
    params: <OpenUiParam>[
      OpenUiParam('text', 'string'),
      OpenUiParam.opt(
        'size',
        '"small" | "default" | "large" | "small-heavy" | "large-heavy"',
      ),
    ],
    builder: _buildTextContent,
  ),
  const OpenUiComponentDef(
    name: 'MarkDownRenderer',
    group: 'Content',
    description: 'Renders markdown text with optional container variant',
    params: <OpenUiParam>[
      OpenUiParam('textMarkdown', 'string'),
      OpenUiParam.opt('variant', '"clear" | "card" | "sunk"'),
    ],
    builder: _buildMarkDownRenderer,
  ),
  const OpenUiComponentDef(
    name: 'Callout',
    group: 'Content',
    description:
        'Callout banner. Optional visible is a reactive \$boolean — '
        'auto-dismisses after 3s by setting \$visible to false.',
    params: <OpenUiParam>[
      OpenUiParam(
        'variant',
        '"info" | "warning" | "error" | "success" | "neutral"',
      ),
      OpenUiParam('title', 'string'),
      OpenUiParam('description', 'string'),
      OpenUiParam.opt('visible', r'$binding<boolean>'),
    ],
    builder: _buildCallout,
  ),
  const OpenUiComponentDef(
    name: 'TextCallout',
    group: 'Content',
    description: 'Text callout with variant, title, and description',
    params: <OpenUiParam>[
      OpenUiParam.opt(
        'variant',
        '"neutral" | "info" | "warning" | "success" | "danger"',
      ),
      OpenUiParam.opt('title', 'string'),
      OpenUiParam.opt('description', 'string'),
    ],
    builder: _buildTextCallout,
  ),
  const OpenUiComponentDef(
    name: 'Image',
    group: 'Content',
    description: 'Image with alt text and optional URL',
    params: <OpenUiParam>[
      OpenUiParam('alt', 'string'),
      OpenUiParam.opt('src', 'string'),
    ],
    builder: _buildImage,
  ),
  const OpenUiComponentDef(
    name: 'ImageBlock',
    group: 'Content',
    description: 'Image block with loading state',
    params: <OpenUiParam>[
      OpenUiParam('src', 'string'),
      OpenUiParam.opt('alt', 'string'),
    ],
    builder: _buildImageBlock,
  ),
  const OpenUiComponentDef(
    name: 'ImageGallery',
    group: 'Content',
    description: 'Gallery grid of images with modal preview',
    params: <OpenUiParam>[
      OpenUiParam('images', '{src: string, alt?: string, details?: string}[]'),
    ],
    builder: _buildImageGallery,
  ),
  const OpenUiComponentDef(
    name: 'CodeBlock',
    group: 'Content',
    description: 'Syntax-highlighted code block',
    params: <OpenUiParam>[
      OpenUiParam('language', 'string'),
      OpenUiParam('codeString', 'string'),
    ],
    builder: _buildCodeBlock,
  ),
  const OpenUiComponentDef(
    name: 'InlineHeader',
    group: 'Content',
    description:
        'Compact section heading with an optional one-line description, '
        'for use inside cards.',
    params: <OpenUiParam>[
      OpenUiParam('heading', 'string'),
      OpenUiParam.opt('description', 'string'),
    ],
    builder: _buildInlineHeader,
  ),
  const OpenUiComponentDef(
    name: 'Separator',
    group: 'Content',
    description: 'Visual divider between content sections',
    params: <OpenUiParam>[
      OpenUiParam.opt('orientation', '"horizontal" | "vertical"'),
      OpenUiParam.opt('decorative', 'boolean'),
    ],
    builder: _buildSeparator,
  ),
  const OpenUiComponentDef(
    name: 'Stack',
    group: 'Layout',
    description:
        'Flex container. direction: "row"|"column" (default "column"). '
        'gap: "none"|"xs"|"s"|"m"|"l"|"xl"|"2xl" (default "m"). align: '
        '"start"|"center"|"end"|"stretch"|"baseline". justify: '
        '"start"|"center"|"end"|"between"|"around"|"evenly".',
    params: <OpenUiParam>[
      OpenUiParam('children', 'any[]'),
      OpenUiParam.opt('direction', '"row" | "column"'),
      OpenUiParam.opt('gap', '"none" | "xs" | "s" | "m" | "l" | "xl" | "2xl"'),
      OpenUiParam.opt(
        'align',
        '"start" | "center" | "end" | "stretch" | "baseline"',
      ),
      OpenUiParam.opt(
        'justify',
        '"start" | "center" | "end" | "between" | "around" | "evenly"',
      ),
      OpenUiParam.opt('wrap', 'boolean'),
    ],
    builder: _buildStack,
  ),
  const OpenUiComponentDef(
    name: 'Tabs',
    group: 'Layout',
    description: 'Tabbed container',
    params: <OpenUiParam>[OpenUiParam('items', 'TabItem[]')],
    builder: _buildTabs,
  ),
  const OpenUiComponentDef.data(
    name: 'TabItem',
    group: 'Layout',
    description:
        'value is unique id, trigger is tab label, content is array of '
        'components',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('trigger', 'string'),
      OpenUiParam('content', '($_kContentLists | Accordion)[]'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'Accordion',
    group: 'Layout',
    description: 'Collapsible sections',
    params: <OpenUiParam>[OpenUiParam('items', 'AccordionItem[]')],
    builder: _buildAccordion,
  ),
  const OpenUiComponentDef.data(
    name: 'AccordionItem',
    group: 'Layout',
    description: 'value is unique id, trigger is section title',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('trigger', 'string'),
      OpenUiParam('content', '($_kContentLists)[]'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'Steps',
    group: 'Content',
    description: 'Step-by-step guide',
    params: <OpenUiParam>[OpenUiParam('items', 'StepsItem[]')],
    builder: _buildSteps,
  ),
  const OpenUiComponentDef.data(
    name: 'StepsItem',
    group: 'Content',
    description: 'title and details text for one step',
    params: <OpenUiParam>[
      OpenUiParam('title', 'string'),
      OpenUiParam('details', 'string'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'Carousel',
    group: 'Layout',
    description: 'Horizontal scrollable carousel',
    params: <OpenUiParam>[
      OpenUiParam('children', '($_kContentLists)[][]'),
      OpenUiParam.opt('variant', '"card" | "sunk"'),
    ],
    builder: _buildCarousel,
  ),
  const OpenUiComponentDef(
    name: 'SectionBlock',
    group: 'Layout',
    description:
        'Collapsible accordion sections. Auto-opens sections as they stream '
        'in. Use SectionItem for each section.',
    params: <OpenUiParam>[
      OpenUiParam('sections', 'SectionItem[]'),
      OpenUiParam.opt('isFoldable', 'boolean'),
    ],
    builder: _buildSectionBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'SectionItem',
    group: 'Layout',
    description:
        'Section with a label and collapsible content — used inside '
        'SectionBlock',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('trigger', 'string'),
      OpenUiParam('content', '($_kContentLists | Tabs | Accordion)[]'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'Modal',
    group: 'Layout',
    description:
        'Modal dialog. open is a reactive \$boolean binding — set to true to '
        'open, X/Escape/backdrop auto-closes. Put Form with buttons inside '
        'children.',
    params: <OpenUiParam>[
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('open', r'$binding<boolean>'),
      OpenUiParam('children', '($_kContentBase)[]'),
      OpenUiParam.opt('size', '"sm" | "md" | "lg"'),
    ],
    builder: _buildModal,
  ),
];

// ---------------------------------------------------------------------
// Shared helpers of the part files.
// ---------------------------------------------------------------------

/// Whether the renderer above [context] still receives the program.
/// It registers a dependency, so the caller rebuilds when it changes.
bool _isStreaming(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<RendererScope>()?.isStreaming ??
    false;

/// A `$binding<boolean>` value: `true` or the text `"true"`.
bool _truthy(Object? v) => v == true || v == 'true';

/// The rendered widgets of one raw value (a widget, a list of widgets,
/// text). It uses the flattening of [OpenUiProps.children].
List<Widget> _widgetsOf(Object? raw) => OpenUiProps(
  component: '',
  values: <String, Object?>{'v': raw},
).children('v');

/// [raw] as an http(s) URL, or `null`. Other schemes (file:, data:,
/// javascript:) are not loaded.
String? _webUrl(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  if (s.isEmpty || s.contains(RegExp(r'[\s<>]'))) return null;
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? s : null;
}

/// A vertical list of blocks with the default content gap.
Widget _blockColumn(List<Widget> children, {double? gap}) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: gap ?? OpenUiTokens.gapDefault,
  children: children,
);

/// The hairline between rows of a card.
Widget _hairline(OpenUiTheme t) =>
    Container(height: OpenUiTokens.borderWidth, color: t.hairline);

/// The app's markdown, in the chat font, so a block reads like the rest
/// of the answer.
Widget _markdown(
  BuildContext context,
  String text, {
  double? size,
  FontWeight? weight,
  Color? color,
  Color? background,
}) {
  final t = OpenUiTheme.of(context);
  return MarkdownMessage(
    text: text,
    textColor: color ?? t.textColor,
    backgroundColor: background ?? Theme.of(context).scaffoldBackgroundColor,
    wrapWithSelectionArea: false,
    fontFamily: t.chatFontFamily,
    paragraphFontSize: size ?? t.chatFontSize,
    paragraphFontWeight: weight,
  );
}

/// The open/closed state rule that Tabs, Accordion and SectionBlock
/// share: while the program streams, follow the newest item; when the
/// stream ends, go back to the first; after a user tap, never move.
class _FollowStream {
  int _count = 0;
  bool _streaming = false;

  /// Whether the user picked an item. Then nothing moves by itself.
  bool userPicked = false;

  /// Starts with [values]. Returns the value to show first.
  String? start(List<String> values, {required bool streaming}) {
    _count = values.length;
    _streaming = streaming;
    if (values.isEmpty) return null;
    return streaming ? values.last : values.first;
  }

  /// Takes a new frame of [values]. Returns a value to switch to, or
  /// `null` to keep the current one.
  String? update(List<String> values, {required bool streaming}) {
    final grew = values.length > _count;
    final ended = _streaming && !streaming;
    _count = values.length;
    _streaming = streaming;
    if (userPicked || values.isEmpty) return null;
    if (streaming && grew) return values.last;
    if (ended) return values.first;
    return null;
  }
}

/// One item of Tabs, Accordion or SectionBlock: an id, a label and
/// the rendered content.
typedef _Panel = ({String value, String trigger, List<Widget> content});

/// Reads the data children of [name] as panels. A missing or doubled
/// `value` gets a position id, so every panel has a unique key.
List<_Panel> _panels(OpenUiProps p, String name, String fallbackLabel) {
  final out = <_Panel>[];
  final seen = <String>{};
  final items = p.data(name);
  for (var i = 0; i < items.length; i++) {
    final d = items[i];
    var value = d.string('value').trim();
    if (value.isEmpty || seen.contains(value)) value = '#$i';
    seen.add(value);
    final trigger = d.string('trigger').trim();
    out.add((
      value: value,
      trigger: trigger.isEmpty ? '$fallbackLabel ${i + 1}' : trigger,
      content: d.children('content'),
    ));
  }
  return out;
}
