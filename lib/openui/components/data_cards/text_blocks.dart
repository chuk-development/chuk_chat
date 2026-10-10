// The B4 data display components: Icon, Tag, TagBlock, EntityList,
// ListBlock, Text, BoldText, IconText, ImageText, ImageTextLarge and the
// two metric indicators.

part of '../data_cards.dart';

// ---------------------------------------------------------------------
// Icon
// ---------------------------------------------------------------------

Widget _buildIcon(BuildContext context, OpenUiProps p) {
  final name = p.string('name').trim();
  if (name.isEmpty) return const SizedBox.shrink();
  return OpenUiIcon(name, category: p.stringOrNull('category'));
}

/// The icon of an `icon` slot: an `Icon(...)` child, or a bare lucide
/// name when the model wrote a string. `null` when there is none.
Widget? _iconSlot(OpenUiProps p, String name) {
  final child = p.child(name);
  if (child != null && child is! Text) return child;
  final s = p.stringOrNull(name)?.trim();
  if (s != null && s.isNotEmpty) return OpenUiIcon(s);
  return null;
}

// ---------------------------------------------------------------------
// Tag and TagBlock
// ---------------------------------------------------------------------

Widget _buildTag(BuildContext context, OpenUiProps p) {
  final text = p.string('text').trim();
  final icon = _iconSlot(p, 'icon');
  if (text.isEmpty && icon == null) return const SizedBox.shrink();
  _SlotScope.report(context, <String, String?>{'tag': text});
  final scope = _SlotScope.maybeOf(context);
  // A tag keeps its own width, also in a stretching column.
  return Align(
    alignment: AlignmentDirectional.centerStart,
    widthFactor: 1,
    heightFactor: 1,
    child: _TagView(
      text: text,
      icon: icon,
      size: scope?.tagSize ?? p.choice('size', fallback: 'md'),
      variant: p.choice('variant', fallback: 'neutral'),
      onImage: scope?.onImage ?? false,
    ),
  );
}

Widget _buildTagBlock(BuildContext context, OpenUiProps p) {
  final tags = p.stringList('tags').where((s) => s.trim().isNotEmpty);
  if (tags.isEmpty) return const SizedBox.shrink();
  final size =
      _SlotScope.maybeOf(context)?.tagSize ?? p.choice('size', fallback: 'md');
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: <Widget>[
      for (final tag in tags) _TagView(text: tag.trim(), size: size),
    ],
  );
}

/// The text and glyph colour on the soft fill of a status [variant].
/// Info is the accent, moved darker or lighter until it reads on the
/// fill (docs/DESIGN.md section 7); the other states keep their colour.
Color _statusInk(BuildContext context, OpenUiTheme t, String variant) {
  if (variant != 'info') return t.statusColor(variant);
  return Theme.of(context)
      .accentForegroundOn(Color.alphaBlend(t.statusFill(variant), t.cardColor));
}

/// A tag or badge: a small rounded label in a status colour.
class _TagView extends StatelessWidget {
  const _TagView({
    required this.text,
    this.icon,
    this.size = 'md',
    this.variant = 'neutral',
    this.onImage = false,
  });

  final String text;
  final Widget? icon;
  final String size;
  final String variant;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final (Color fill, Color fg) = onImage
        ? (Colors.black.withValues(alpha: 0.45), Colors.white)
        : variant == 'neutral'
        ? (t.sunkColor, t.textColor)
        : (t.statusFill(variant), _statusInk(context, t, variant));
    final (
      EdgeInsets padding,
      double font,
      double iconSize,
      double radius,
    ) = switch (size) {
      'sm' => (
        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        11.5,
        13.0,
        OpenUiTokens.radiusChip - 2,
      ),
      'lg' => (
        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        14.0,
        16.0,
        OpenUiTokens.radiusChip + 2,
      ),
      _ => (
        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        12.5,
        14.0,
        OpenUiTokens.radiusChip,
      ),
    };
    final style = _style(
      t,
      size: font,
      weight: FontWeight.w600,
      color: fg,
      height: 1.2,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 4,
          children: <Widget>[
            if (icon != null)
              OpenUiIconStyle(size: iconSize, color: fg, child: icon!),
            if (text.isNotEmpty)
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// EntityList: key/value rows
// ---------------------------------------------------------------------

Widget _buildEntityList(BuildContext context, OpenUiProps p) {
  // As upstream: only the default size has a header and a footer row.
  final small =
      (_SlotScope.maybeOf(context)?.compact ?? false) ||
      p.choice('size', fallback: 'default') == 'small';
  final rows = p.mapList('rows');
  final header = small ? const <String, Object?>{} : p.map('header');
  final footer = small ? const <String, Object?>{} : p.map('footer');
  bool usable(Map<String, Object?> r) =>
      _str(r['left']).trim().isNotEmpty || _str(r['right']).trim().isNotEmpty;
  final body = rows.where(usable).toList();
  if (body.isEmpty && !usable(header) && !usable(footer)) {
    return const SizedBox.shrink();
  }
  final t = OpenUiTheme.of(context);
  final all = <(Map<String, Object?>, String)>[
    if (usable(header)) (header, 'header'),
    for (final r in body) (r, 'row'),
    if (usable(footer)) (footer, 'footer'),
  ];
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (var i = 0; i < all.length; i++)
        DecoratedBox(
          decoration: BoxDecoration(
            border: i == all.length - 1
                ? null
                : Border(
                    bottom: BorderSide(
                      color: t.hairline,
                      width: OpenUiTokens.borderWidth,
                    ),
                  ),
          ),
          child: _EntityRow(row: all[i].$1, kind: all[i].$2, small: small),
        ),
    ],
  );
}

class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.row,
    required this.kind,
    required this.small,
  });

  final Map<String, Object?> row;
  final String kind;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final number = _str(row['rightVariant']) == 'number';
    final base = small ? 13.0 : 14.0;
    final leftStyle = _style(
      t,
      size: base,
      color: kind == 'header' ? t.mutedColor : t.textColor,
    );
    final rightStyle = switch (kind) {
      'header' => _style(t, size: base, color: t.mutedColor, number: number),
      'footer' => _style(
        t,
        size: small ? base + 1 : base + 3,
        weight: FontWeight.w700,
        number: number,
      ),
      _ => _style(t, size: base, weight: FontWeight.w600, number: number),
    };
    return Padding(
      padding: EdgeInsets.symmetric(vertical: small ? 8 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: <Widget>[
          Expanded(child: Text(_str(row['left']), style: leftStyle)),
          Expanded(
            child: Text(
              _str(row['right']),
              textAlign: TextAlign.right,
              style: rightStyle,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// ListBlock and ListItem
// ---------------------------------------------------------------------

Widget _buildListBlock(BuildContext context, OpenUiProps p) {
  final items = p
      .data('items', type: 'ListItem')
      .where((i) => i.string('title').trim().isNotEmpty)
      .toList();
  if (items.isEmpty) return const SizedBox.shrink();
  final small =
      (_SlotScope.maybeOf(context)?.compact ?? false) ||
      p.choice('size', fallback: 'default') == 'small';
  final image = p.choice('variant', fallback: 'number') == 'image';
  final anySubtitle = items.any((i) => i.string('subtitle').trim().isNotEmpty);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: small ? 8 : 10,
    children: <Widget>[
      for (var i = 0; i < items.length; i++)
        _ListRow(
          item: items[i],
          index: i,
          image: image,
          small: small,
          anySubtitle: anySubtitle,
          last: i == items.length - 1,
        ),
    ],
  );
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.item,
    required this.index,
    required this.image,
    required this.small,
    required this.anySubtitle,
    required this.last,
  });

  final OpenUiProps item;
  final int index;
  final bool image;
  final bool small;
  final bool anySubtitle;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final title = item.string('title').trim();
    final subtitle = item.string('subtitle').trim();
    final action = item.action('action');
    final actionLabel = item.string('actionLabel').trim();
    final img = item.map('image');
    final src = _httpUrl(img['src']);
    final box = anySubtitle ? (small ? 36.0 : 40.0) : (small ? 24.0 : 28.0);
    final radius = anySubtitle ? 10.0 : 7.0;

    final Widget indicator = SizedBox.square(
      dimension: box,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: image && src != null
            ? _NetImage(src: src, alt: _str(img['alt']), iconSize: box * 0.45)
            : ColoredBox(
                color: t.sunkColor,
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: _style(
                      t,
                      size: anySubtitle ? 13 : 12,
                      weight: FontWeight.w600,
                      color: t.mutedColor,
                      number: true,
                      height: 1,
                    ),
                  ),
                ),
              ),
      ),
    );

    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: <Widget>[
        Text(
          title,
          style: _style(t, size: small ? 13.5 : 14.5, weight: FontWeight.w600),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: _style(t, size: small ? 12.5 : 13, color: t.mutedColor),
          ),
      ],
    );

    final row = Row(
      crossAxisAlignment: subtitle.isNotEmpty
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      spacing: 12,
      children: <Widget>[
        indicator,
        Expanded(child: text),
        if (action != null) ...<Widget>[
          if (actionLabel.isNotEmpty)
            Text(
              actionLabel,
              style: _style(
                t,
                size: 13,
                weight: FontWeight.w600,
                color: Theme.of(context).accentForegroundOn(t.scheme.surface),
              ),
            ),
          const _Chevron(),
        ],
      ],
    );

    if (action == null) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Pressable(
          radius: OpenUiTokens.radiusInner,
          semanticLabel: title,
          onTap: () => action.run(context, label: title),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: row,
          ),
        ),
        if (!last) ...<Widget>[
          SizedBox(height: small ? 4 : 6),
          Divider(height: 1, thickness: 1, color: t.hairline),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Text and BoldText
// ---------------------------------------------------------------------

Widget _buildText(BuildContext context, OpenUiProps p) =>
    _buildTextLine(context, p, bold: false);

Widget _buildBoldText(BuildContext context, OpenUiProps p) =>
    _buildTextLine(context, p, bold: true);

Widget _buildTextLine(
  BuildContext context,
  OpenUiProps p, {
  required bool bold,
}) {
  var value = p.string('value').trim();
  // `Text("Hello")` binds the text to the first slot, `variant`. Show it.
  final first = p.string('variant').trim();
  if (value.isEmpty && first != 'text' && first != 'number') value = first;
  final subtext = p.string('subtext').trim();
  if (value.isEmpty && subtext.isEmpty) return const SizedBox.shrink();
  _SlotScope.report(context, <String, String?>{
    'value': value,
    'subtext': subtext,
  });
  final t = OpenUiTheme.of(context);
  final size =
      _SlotScope.maybeOf(context)?.textSize ?? p.choice('size', fallback: 'md');
  final number = p.choice('variant', fallback: 'text') == 'number';
  final subVariant = p.choice('subtextVariant', fallback: 'text');
  final (double main, double sub) = bold
      ? switch (size) {
          'xs' => (14.0, 12.0),
          'sm' => (15.0, 12.5),
          'lg' => (22.0, 13.5),
          _ => (17.0, 13.0),
        }
      : switch (size) {
          'xs' => (12.5, 11.5),
          'sm' => (13.5, 12.0),
          'lg' => (16.0, 13.5),
          _ => (14.5, 12.5),
        };
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: <Widget>[
      if (value.isNotEmpty)
        Text(
          value,
          style: _style(
            t,
            size: main,
            weight: bold ? FontWeight.w700 : FontWeight.w400,
            number: number,
            height: bold && size == 'lg' ? 1.2 : 1.35,
          ),
        ),
      if (subtext.isNotEmpty)
        Text(
          subtext,
          style: _style(
            t,
            size: sub,
            color: _metricTone(t, subVariant, subtext) ?? t.mutedColor,
            weight: subVariant == 'metric' ? FontWeight.w600 : FontWeight.w400,
            number: subVariant != 'text',
          ),
        ),
    ],
  );
}

// ---------------------------------------------------------------------
// IconText, ImageText, ImageTextLarge
// ---------------------------------------------------------------------

/// The title and subtitle beside an icon badge or a thumbnail.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.title,
    required this.subtitle,
    required this.bold,
    this.size,
  });

  final String title;
  final String subtitle;
  final bool bold;
  final String? size;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final (double main, double sub) = switch (size) {
      'xs' => (13.0, 12.0),
      'sm' => (13.5, 12.0),
      'lg' => (16.0, 13.5),
      _ => (14.5, 13.0),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 1,
      children: <Widget>[
        if (title.isNotEmpty)
          Text(
            title,
            style: _style(
              t,
              size: main,
              weight: bold ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: _style(t, size: sub, color: t.mutedColor),
          ),
      ],
    );
  }
}

/// A leading picture (badge or thumbnail) with a title block, side by
/// side or stacked.
Widget _leadingWithTitle({
  required Widget leading,
  required _TitleBlock text,
  required bool vertical,
  required double gap,
}) {
  if (vertical) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: gap,
      children: <Widget>[leading, text],
    );
  }
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    spacing: gap,
    children: <Widget>[
      leading,
      Flexible(child: text),
    ],
  );
}

Widget _buildIconText(BuildContext context, OpenUiProps p) {
  final title = p.string('title').trim();
  final subtitle = p.string('subtitle').trim();
  final icon = _iconSlot(p, 'icon');
  if (title.isEmpty && subtitle.isEmpty && icon == null) {
    return const SizedBox.shrink();
  }
  _SlotScope.report(context, <String, String?>{
    'title': title,
    'subtitle': subtitle,
  });
  final scope = _SlotScope.maybeOf(context);
  final iconSize = switch (p.choice('iconSize', fallback: 'm')) {
    'xs' => 'xs',
    's' || 'sm' => 's',
    'l' || 'lg' => 'l',
    'xl' => 'xl',
    _ => 'm',
  };
  final badge = _IconBadge(
    icon: icon ?? const OpenUiIcon(kOpenUiDefaultIcon),
    variant: p.choice('iconVariant', fallback: 'neutral'),
    size: scope?.textSize == 'xs' && iconSize != 'xs' ? 's' : iconSize,
  );
  return _leadingWithTitle(
    leading: badge,
    text: _TitleBlock(
      title: title,
      subtitle: subtitle,
      bold: p.boolean('bold'),
      size: scope?.textSize,
    ),
    vertical: p.choice('layout', fallback: 'horizontal') == 'vertical',
    gap: iconSize == 'xs' || iconSize == 's' ? 8 : 12,
  );
}

/// An icon in a rounded tinted square (upstream IconTag).
class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    required this.variant,
    required this.size,
  });

  final Widget icon;
  final String variant;
  final String size;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    final (double box, double glyph) = switch (size) {
      'xs' => (20.0, 12.0),
      's' => (24.0, 14.0),
      'l' => (36.0, 18.0),
      'xl' => (40.0, 20.0),
      _ => (32.0, 16.0),
    };
    final (Color fill, Color fg) = switch (variant) {
      'info' ||
      'success' ||
      'warning' ||
      'danger' => (t.statusFill(variant), _statusInk(context, t, variant)),
      'inverted' => (scheme.onSurface, scheme.surface),
      'filled' => (scheme.primary, scheme.onPrimary),
      'soft' => (
        scheme.primary.withValues(alpha: t.isDark ? 0.18 : 0.14),
        Theme.of(context).accentForegroundOn(
          Color.alphaBlend(
            scheme.primary.withValues(alpha: t.isDark ? 0.18 : 0.14),
            t.cardColor,
          ),
        ),
      ),
      _ => (t.sunkColor, t.textColor),
    };
    return SizedBox.square(
      dimension: box,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(box * 0.3),
        ),
        child: Center(
          child: OpenUiIconStyle(size: glyph, color: fg, child: icon),
        ),
      ),
    );
  }
}

Widget _buildImageText(BuildContext context, OpenUiProps p) {
  final title = p.string('title').trim();
  final subtitle = p.string('subtitle').trim();
  final src = p.stringOrNull('src');
  if (title.isEmpty && subtitle.isEmpty && _httpUrl(src) == null) {
    return const SizedBox.shrink();
  }
  _SlotScope.report(context, <String, String?>{
    'title': title,
    'subtitle': subtitle,
    'alt': p.stringOrNull('alt'),
  });
  final scope = _SlotScope.maybeOf(context);
  final fallbackSize = scope?.textSize == 'xs' ? 32.0 : 40.0;
  final size = p.number('imageSize', fallback: fallbackSize).clamp(16, 160);
  final dim = size.toDouble();
  return _leadingWithTitle(
    leading: SizedBox.square(
      dimension: dim,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          (dim * 0.22).clamp(4, OpenUiTokens.radiusInner),
        ),
        child: _NetImage(
          src: src,
          alt: p.stringOrNull('alt'),
          iconSize: dim * 0.45,
        ),
      ),
    ),
    text: _TitleBlock(
      title: title,
      subtitle: subtitle,
      bold: p.boolean('bold'),
      size: scope?.textSize,
    ),
    vertical: p.choice('layout', fallback: 'horizontal') == 'vertical',
    gap: dim <= 32 ? 8 : 12,
  );
}

Widget _buildImageTextLarge(BuildContext context, OpenUiProps p) {
  final title = p.string('title').trim();
  final subtitle = p.string('subtitle').trim();
  final src = p.stringOrNull('src');
  if (title.isEmpty && subtitle.isEmpty && _httpUrl(src) == null) {
    return const SizedBox.shrink();
  }
  _SlotScope.report(context, <String, String?>{
    'title': title,
    'subtitle': subtitle,
    'alt': p.stringOrNull('alt'),
  });
  final t = OpenUiTheme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 10,
    children: <Widget>[
      ClipRRect(
        borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: _NetImage(
              src: src,
              alt: p.stringOrNull('alt'),
              iconSize: 28,
            ),
          ),
        ),
      ),
      if (title.isNotEmpty || subtitle.isNotEmpty)
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: <Widget>[
            if (title.isNotEmpty)
              Text(
                title,
                style: _style(
                  t,
                  size: 16,
                  weight: p.boolean('bold', fallback: true)
                      ? FontWeight.w700
                      : FontWeight.w600,
                  height: 1.25,
                ),
              ),
            if (subtitle.isNotEmpty)
              Text(subtitle, style: _style(t, size: 13.5, color: t.mutedColor)),
          ],
        ),
    ],
  );
}

// ---------------------------------------------------------------------
// Metric indicators
// ---------------------------------------------------------------------

/// The `{direction, value}` trend of a metric, or `null`.
({bool up, String text})? _trend(OpenUiProps p) {
  final m = p.map('trend');
  if (m.isEmpty) return null;
  final dir = _str(m['direction']).trim().toLowerCase();
  final value = _num(m['value']);
  if (value == null || (dir != 'up' && dir != 'down')) return null;
  final abs = value.abs();
  final digits = abs == abs.roundToDouble() ? 0 : (abs < 10 ? 2 : 1);
  var text = abs.toStringAsFixed(digits);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return (up: dir == 'up', text: '${dir == 'up' ? '+' : '−'}$text%');
}

/// A trend: an arrow and the signed percentage, green up, red down.
class _TrendView extends StatelessWidget {
  const _TrendView({required this.up, required this.text});

  static const double size = 13;

  final bool up;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final color = up ? t.success : t.danger;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: <Widget>[
        HugeIcon(
          up ? HugeIcons.arrowUpRight01 : HugeIcons.arrowDownRight01,
          size: size + 1,
          color: color,
        ),
        Text(
          text,
          style: _style(
            t,
            size: size,
            weight: FontWeight.w600,
            color: color,
            number: true,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

Widget _buildMetricInline(BuildContext context, OpenUiProps p) {
  final value = p.string('value').trim();
  final subtext = p.string('subtext').trim();
  final trend = _trend(p);
  if (value.isEmpty && subtext.isEmpty && trend == null) {
    return const SizedBox.shrink();
  }
  _SlotScope.report(context, <String, String?>{
    'value': value,
    'subtext': subtext,
  });
  final t = OpenUiTheme.of(context);
  final compact = _SlotScope.maybeOf(context)?.textSize == 'xs';
  return Wrap(
    spacing: 6,
    runSpacing: 2,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: <Widget>[
      if (value.isNotEmpty)
        Text(
          value,
          style: _style(
            t,
            size: compact ? 16 : 18,
            weight: FontWeight.w700,
            number: true,
            height: 1.2,
          ),
        ),
      if (trend != null) _TrendView(up: trend.up, text: trend.text),
      if (subtext.isNotEmpty)
        Text(
          subtext,
          style: _style(t, size: 12.5, color: t.mutedColor, height: 1.2),
        ),
    ],
  );
}

Widget _buildMetricStrike(BuildContext context, OpenUiProps p) {
  final value = p.string('value').trim();
  final previous = p.string('previousValue').trim();
  final subtext = p.string('subtext').trim();
  final trend = _trend(p);
  if (value.isEmpty && previous.isEmpty && subtext.isEmpty && trend == null) {
    return const SizedBox.shrink();
  }
  _SlotScope.report(context, <String, String?>{
    'value': value,
    'subtext': subtext,
  });
  final t = OpenUiTheme.of(context);
  final compact = _SlotScope.maybeOf(context)?.textSize == 'xs';
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: <Widget>[
      Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          if (value.isNotEmpty)
            Text(
              value,
              style: _style(
                t,
                size: compact ? 17 : 20,
                weight: FontWeight.w700,
                number: true,
                height: 1.15,
              ),
            ),
          if (previous.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Text(
                previous,
                style: _style(
                  t,
                  size: 13,
                  color: t.mutedColor,
                  number: true,
                  height: 1.2,
                ).copyWith(decoration: TextDecoration.lineThrough),
              ),
            ),
          if (trend != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: _TrendView(up: trend.up, text: trend.text),
            ),
        ],
      ),
      if (subtext.isNotEmpty)
        Text(subtext, style: _style(t, size: 12.5, color: t.mutedColor)),
    ],
  );
}
