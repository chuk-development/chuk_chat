// OpenUI components, group B4: data display and cards.
//
// Owner: agent B4. Add each component as one OpenUiComponentDef to
// [dataCardsComponents]. Do not edit the registry
// (lib/openui/openui_library.dart). Rules: docs/OPENUI.md.
//
// Components of this file (upstream chat library):
//   TagBlock, Tag, Icon, EntityList          (data_cards/text_blocks.dart)
//   ListBlock, ListItem (data-only: ListBlock reads it)
//   Text, BoldText, IconText, ImageText, ImageTextLarge
//   MetricIndicatorInline, MetricIndicatorWithStrikethrough
//   SnippetCardBlock, SnippetCardItem        (data_cards/card_blocks.dart)
//   OverviewCardBlock, OverviewCardItem
//   ContextCardBlock, ContextCardItem
//   CompositeCardBlock, CompositeCardItem
//   VisualCardBlock, VisualCardItem
//   (every *Item is data-only: its block reads it)
//
// Icons come from the app's own set (HugeIcons, docs/DESIGN.md section
// 5): lib/openui/openui_icons.dart maps the upstream lucide names.
//
// How a card block talks to its children: the children are rendered
// widgets, so the block cannot read their props. It puts each slot in a
// `_SlotScope`; a child reads the size the card wants from it, and
// writes its own title or value into it while it builds. A tap then
// sends that text with the item context, as upstream does.
//
// The exact signatures are in
// test/openui/fixtures/upstream/components-chat.json.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui_component.dart';
import 'package:chuk_chat/openui/openui_icons.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

part 'data_cards/card_blocks.dart';
part 'data_cards/shared.dart';
part 'data_cards/text_blocks.dart';

const String _blockModes = '"grid" | "carousel"';
const String _textVariant = '"text" | "number"';
const String _subtextVariant = '"text" | "number" | "metric"';
const String _textSize = '"xs" | "sm" | "md" | "lg"';
const String _status = '"neutral" | "info" | "success" | "warning" | "danger"';
const String _entityRow =
    '{left: string, right: string, rightVariant?: "text" | "number"}';
const String _trendType = '{direction: "up" | "down", value: number}';

/// The B4 components: data display and cards.
final List<OpenUiComponentDef> dataCardsComponents = <OpenUiComponentDef>[
  // -- Icons and tags ------------------------------------------------
  const OpenUiComponentDef(
    name: 'Icon',
    group: 'Buttons',
    description:
        "A lucide icon by kebab-case name (e.g. 'circle-check'). Optional "
        "category picks a topical fallback when the name doesn't resolve.",
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('category', 'string'),
    ],
    builder: _buildIcon,
  ),
  const OpenUiComponentDef(
    name: 'TagBlock',
    group: 'Data Display',
    description: 'tags is an array of strings; optional size sm | md | lg',
    params: <OpenUiParam>[
      OpenUiParam('tags', 'string[]'),
      OpenUiParam.opt('size', '"sm" | "md" | "lg"'),
    ],
    builder: _buildTagBlock,
  ),
  const OpenUiComponentDef(
    name: 'Tag',
    group: 'Data Display',
    description: 'Styled tag/badge with optional Icon and variant',
    params: <OpenUiParam>[
      OpenUiParam('text', 'string'),
      OpenUiParam.opt('icon', 'Icon'),
      OpenUiParam.opt('size', '"sm" | "md" | "lg"'),
      OpenUiParam.opt('variant', _status),
    ],
    builder: _buildTag,
  ),
  const OpenUiComponentDef(
    name: 'EntityList',
    group: 'Data Display',
    description:
        "Two-column key/value rows (left label, right value). size 'default' "
        "supports optional header and footer rows; rightVariant 'number' "
        'uses tabular numbers.',
    params: <OpenUiParam>[
      OpenUiParam.opt('rows', '$_entityRow[]'),
      OpenUiParam.opt('size', '"small" | "default"'),
      OpenUiParam.opt('header', _entityRow),
      OpenUiParam.opt('footer', _entityRow),
    ],
    builder: _buildEntityList,
  ),
  // -- Lists ------------------------------------------------------------
  const OpenUiComponentDef(
    name: 'ListBlock',
    group: 'Lists & Follow-ups',
    description:
        'A list of items with number or image indicators. Each item can '
        'optionally have an action. size small renders a compact list.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'ListItem[]'),
      OpenUiParam.opt('variant', '"number" | "image"'),
      OpenUiParam.opt('size', '"default" | "small"'),
    ],
    builder: _buildListBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'ListItem',
    group: 'Lists & Follow-ups',
    description:
        'Item in a ListBlock — displays a title with an optional '
        'subtitle and image. When action is provided, the item becomes '
        'clickable.',
    params: <OpenUiParam>[
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('subtitle', 'string'),
      OpenUiParam.opt('image', '{src: string, alt: string}'),
      OpenUiParam.opt('actionLabel', 'string'),
      OpenUiParam.opt('action', 'ActionExpression'),
    ],
  ),
  // -- Inline building blocks of the cards ------------------------------
  const OpenUiComponentDef(
    name: 'Text',
    group: 'Cards',
    description:
        "Plain text line with optional subtext. variant 'number' uses "
        "tabular number styling; subtextVariant 'metric' colors a leading "
        '+/- subtext green/red.',
    params: <OpenUiParam>[
      OpenUiParam.opt('variant', _textVariant),
      OpenUiParam('value', 'string'),
      OpenUiParam.opt('subtext', 'string'),
      OpenUiParam.opt('subtextVariant', _subtextVariant),
      OpenUiParam.opt('size', _textSize),
    ],
    builder: _buildText,
  ),
  const OpenUiComponentDef(
    name: 'BoldText',
    group: 'Cards',
    description:
        "Emphasized (bold) text line with optional subtext. variant 'number' "
        "uses tabular number styling; subtextVariant 'metric' colors a "
        'leading +/- subtext green/red.',
    params: <OpenUiParam>[
      OpenUiParam.opt('variant', _textVariant),
      OpenUiParam('value', 'string'),
      OpenUiParam.opt('subtext', 'string'),
      OpenUiParam.opt('subtextVariant', _subtextVariant),
      OpenUiParam.opt('size', _textSize),
    ],
    builder: _buildBoldText,
  ),
  const OpenUiComponentDef(
    name: 'IconText',
    group: 'Cards',
    description:
        'An icon badge with a title and optional subtitle, laid out '
        'horizontally or vertically. iconVariant sets the badge color.',
    params: <OpenUiParam>[
      OpenUiParam('icon', 'Icon'),
      OpenUiParam.opt(
        'iconVariant',
        '"neutral" | "info" | "success" | "warning" | "danger" | '
            '"inverted" | "filled" | "soft"',
      ),
      OpenUiParam.opt(
        'iconSize',
        '"xs" | "s" | "m" | "l" | "xl" | "sm" | "md" | "lg"',
      ),
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('subtitle', 'string'),
      OpenUiParam.opt('bold', 'boolean'),
      OpenUiParam.opt('layout', '"horizontal" | "vertical"'),
    ],
    builder: _buildIconText,
  ),
  const OpenUiComponentDef(
    name: 'ImageText',
    group: 'Cards',
    description:
        'A small square image (thumbnail/avatar) with a title and optional '
        'subtitle. src must be a real image URL.',
    params: <OpenUiParam>[
      OpenUiParam('src', 'string'),
      OpenUiParam.opt('alt', 'string'),
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('subtitle', 'string'),
      OpenUiParam.opt('bold', 'boolean'),
      OpenUiParam.opt('layout', '"horizontal" | "vertical"'),
      OpenUiParam.opt('imageSize', 'number'),
    ],
    builder: _buildImageText,
  ),
  const OpenUiComponentDef(
    name: 'ImageTextLarge',
    group: 'Cards',
    description:
        'A full-width banner image above a bold title and optional '
        'subtitle. src must be a real image URL.',
    params: <OpenUiParam>[
      OpenUiParam('src', 'string'),
      OpenUiParam.opt('alt', 'string'),
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('subtitle', 'string'),
      OpenUiParam.opt('bold', 'boolean'),
    ],
    builder: _buildImageTextLarge,
  ),
  const OpenUiComponentDef(
    name: 'MetricIndicatorInline',
    group: 'Cards',
    description:
        'Headline metric value with an optional +/- percentage trend and '
        'subtext, all on one line.',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam.opt('subtext', 'string'),
      OpenUiParam.opt('trend', _trendType),
    ],
    builder: _buildMetricInline,
  ),
  const OpenUiComponentDef(
    name: 'MetricIndicatorWithStrikethrough',
    group: 'Cards',
    description:
        'Headline metric value with an optional struck-through '
        'previousValue, a +/- percentage trend, and subtext below.',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam.opt('subtext', 'string'),
      OpenUiParam.opt('previousValue', 'string'),
      OpenUiParam.opt('trend', _trendType),
    ],
    builder: _buildMetricStrike,
  ),
  // -- Card blocks -------------------------------------------------------
  const OpenUiComponentDef.data(
    name: 'SnippetCardItem',
    group: 'Cards',
    description:
        'One row-style snippet card: a label on the left (IconText or '
        'ImageText) and an optional value on the right (Text or BoldText).',
    params: <OpenUiParam>[
      OpenUiParam.opt('id', 'string'),
      OpenUiParam('lhs', 'IconText | ImageText'),
      OpenUiParam.opt('rhs', 'Text | BoldText'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'SnippetCardBlock',
    group: 'Cards',
    description:
        'A responsive grid of compact label/value cards (2 per row) for '
        'showing several short facts side by side; optionally clickable '
        'with a shared action.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'SnippetCardItem[]'),
      OpenUiParam.opt('layout', '"grid"'),
      OpenUiParam.opt('responsive', 'boolean'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('gap', 'number | string'),
    ],
    builder: _buildSnippetBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'OverviewCardItem',
    group: 'Cards',
    description:
        'One overview card: a heading slot at the top (IconText, ImageText '
        'or Text) and an optional MetricIndicatorInline at the bottom.',
    params: <OpenUiParam>[
      OpenUiParam.opt('id', 'string'),
      OpenUiParam('top', 'IconText | ImageText | Text'),
      OpenUiParam.opt('bottom', 'MetricIndicatorInline'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'OverviewCardBlock',
    group: 'Cards',
    description:
        'A grid or horizontal carousel of compact overview cards, each with '
        'a heading (icon/image/text) on top and an inline metric below; '
        'optionally clickable with a shared action.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'OverviewCardItem[]'),
      OpenUiParam.opt('layout', _blockModes),
      OpenUiParam.opt('responsive', 'boolean'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('gap', 'number | string'),
    ],
    builder: _buildOverviewBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'ContextCardItem',
    group: 'Cards',
    description:
        'A single card inside a ContextCardBlock: a title (plain string or '
        'Tag), an optional markdown body, and an optional gray tint or '
        'background image.',
    params: <OpenUiParam>[
      OpenUiParam.opt('id', 'string'),
      OpenUiParam('title', 'string | Tag'),
      OpenUiParam.opt('body', 'string'),
      OpenUiParam.opt('bgColor', '"gray"'),
      OpenUiParam.opt('bgImageSrc', 'string'),
      OpenUiParam.opt('bgImageAlt', 'string'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'ContextCardBlock',
    group: 'Cards',
    description:
        'A grid or carousel of compact tinted context cards (title or tag '
        'plus a short bold body); an optional action makes every card '
        'clickable.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'ContextCardItem[]'),
      OpenUiParam.opt('layout', _blockModes),
      OpenUiParam.opt('responsive', 'boolean'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('gap', 'number | string'),
    ],
    builder: _buildContextBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'CompositeCardItem',
    group: 'Cards',
    description:
        'A single card inside a CompositeCardBlock: an optional header '
        '(icon/image/text), a stack of body elements (text, metrics, '
        'charts, lists, tags), and an optional price/button footer.',
    params: <OpenUiParam>[
      OpenUiParam.opt('id', 'string'),
      OpenUiParam.opt(
        'header',
        'IconText | ImageText | ImageTextLarge | Text | Image',
      ),
      OpenUiParam.opt(
        'body',
        '(Text | BoldText | MetricIndicatorInline | IconText | Image | '
            'AreaChart | BarChart | LineChart | ListBlock | TagBlock | '
            'EntityList)[]',
      ),
      OpenUiParam.opt(
        'footer',
        '{price?: BoldText | MetricIndicatorWithStrikethrough, '
            'button?: Button}',
      ),
    ],
  ),
  const OpenUiComponentDef(
    name: 'CompositeCardBlock',
    group: 'Cards',
    description:
        'A two-per-row grid or carousel of rich cards, each with an '
        'optional header, stacked body content (text, metrics, charts, '
        'lists, tags) and a price/button footer; an optional action makes '
        'every card clickable.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'CompositeCardItem[]'),
      OpenUiParam.opt('layout', _blockModes),
      OpenUiParam.opt('responsive', 'boolean'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('gap', 'number | string'),
    ],
    builder: _buildCompositeBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'VisualCardItem',
    group: 'Cards',
    description:
        'A single photo-first card inside a VisualCardBlock: a BoldText '
        'body panel, an optional Tag, and a background image (bgImageSrc '
        'must be a real URL; bgImageAlt is its alt text).',
    params: <OpenUiParam>[
      OpenUiParam('body', 'BoldText'),
      OpenUiParam.opt('id', 'string'),
      OpenUiParam.opt('bgImageSrc', 'string'),
      OpenUiParam.opt('tag', 'Tag'),
      OpenUiParam.opt('bgImageAlt', 'string'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'VisualCardBlock',
    group: 'Cards',
    description:
        'A grid or carousel of photo-first cards: a full-bleed background '
        'image with a tag on top and a bold text panel at the bottom; an '
        'optional action makes every card clickable.',
    params: <OpenUiParam>[
      OpenUiParam('items', 'VisualCardItem[]'),
      OpenUiParam.opt('layout', _blockModes),
      OpenUiParam.opt('responsive', 'boolean'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('gap', 'number | string'),
    ],
    builder: _buildVisualBlock,
  ),
];
