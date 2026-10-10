// The B4 card blocks: SnippetCardBlock, OverviewCardBlock,
// ContextCardBlock, CompositeCardBlock and VisualCardBlock. Each item
// component is data-only; its block reads it and draws the cards.

part of '../data_cards.dart';

/// The shared settings of one card block call.
class _BlockSettings {
  _BlockSettings(BuildContext context, OpenUiProps p, {required double gap})
    : action = p.action('action'),
      carousel = p.choice('layout', fallback: 'grid') == 'carousel',
      responsive = p.boolean('responsive', fallback: true),
      gap = _blockGap(p, gap),
      streaming = _streamingHere(context, p.statementId);

  final OpenUiAction? action;
  final bool carousel;
  final bool responsive;
  final double gap;
  final bool streaming;

  /// Whether the cards take a tap.
  bool get clickable => action != null && !streaming;
}

/// Wraps [child] in a slot of a card.
Widget _slot(
  Widget? child,
  _CardInfo info,
  String slot, {
  String? textSize,
  String? tagSize,
  bool compact = false,
  bool onImage = false,
}) {
  if (child == null) return const SizedBox.shrink();
  return _SlotScope(
    info: info,
    slot: slot,
    textSize: textSize,
    tagSize: tagSize,
    compact: compact,
    onImage: onImage,
    child: child,
  );
}

/// The tap handler of card [index], or `null` when not clickable.
VoidCallback? _cardTap(
  BuildContext context,
  _BlockSettings s,
  String Function() label,
  Map<String, Object?> Function() item,
) {
  final action = s.action;
  if (!s.clickable || action == null) return null;
  return () => _runItemAction(context, action, label: label(), item: item());
}

// ---------------------------------------------------------------------
// SnippetCardBlock: compact label/value cards, two per row
// ---------------------------------------------------------------------

Widget _buildSnippetBlock(BuildContext context, OpenUiProps p) {
  final items = p.data('items', type: 'SnippetCardItem');
  final s = _BlockSettings(context, p, gap: 10);
  final t = OpenUiTheme.of(context);
  final cards = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final lhs = item.child('lhs');
    final rhs = item.child('rhs');
    if (lhs == null && rhs == null) continue;
    final info = _CardInfo();
    final id = item.stringOrNull('id');
    final index = i;
    final onTap = _cardTap(
      context,
      s,
      () =>
          info.read('lhs', 'title', const <String>['value']) ??
          id ??
          'Snippet card ${index + 1}',
      () => <String, Object?>{
        'itemIndex': index,
        'itemId': id,
        'itemTitle': info.read('lhs', 'title'),
        'itemSubtitle': info.read('lhs', 'subtitle'),
        'itemValue': info.read('rhs', 'value'),
      },
    );
    cards.add(
      _Pressable(
        onTap: onTap,
        child: DecoratedBox(
          decoration: t.cardDecoration(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 10,
              children: <Widget>[
                Expanded(child: _slot(lhs, info, 'lhs', textSize: 'sm')),
                if (rhs != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: _slot(rhs, info, 'rhs', textSize: 'xs'),
                  ),
                if (onTap != null) const _Chevron(size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return _CardBlockLayout(
    cards: cards,
    maxPerRow: 2,
    carousel: false,
    responsive: s.responsive,
    gap: s.gap,
    carouselWidth: 240,
    carouselWidthNarrow: 200,
  );
}

// ---------------------------------------------------------------------
// OverviewCardBlock: heading on top, inline metric below
// ---------------------------------------------------------------------

Widget _buildOverviewBlock(BuildContext context, OpenUiProps p) {
  final items = p.data('items', type: 'OverviewCardItem');
  final s = _BlockSettings(context, p, gap: 10);
  final t = OpenUiTheme.of(context);
  final cards = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final top = item.child('top');
    final bottom = item.child('bottom');
    if (top == null && bottom == null) continue;
    final info = _CardInfo();
    final id = item.stringOrNull('id');
    final index = i;
    final onTap = _cardTap(
      context,
      s,
      () =>
          info.read('top', 'title', const <String>['value']) ??
          id ??
          'Overview card ${index + 1}',
      () => <String, Object?>{
        'itemIndex': index,
        'itemId': id,
        'itemTitle': info.read('top', 'title', const <String>['value']),
        'itemSubtitle': info.read('top', 'subtitle', const <String>['subtext']),
        'itemMetricValue': info.read('bottom', 'value'),
      },
    );
    cards.add(
      _Pressable(
        onTap: onTap,
        child: DecoratedBox(
          decoration: t.cardDecoration(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              spacing: 10,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: <Widget>[
                    Expanded(child: _slot(top, info, 'top', textSize: 'sm')),
                    if (onTap != null) const _Chevron(size: 14),
                  ],
                ),
                if (bottom != null)
                  _slot(bottom, info, 'bottom', textSize: 'xs'),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return _CardBlockLayout(
    cards: cards,
    maxPerRow: 3,
    carousel: s.carousel,
    responsive: s.responsive,
    gap: s.gap,
    carouselWidth: 240,
    carouselWidthNarrow: 200,
  );
}

// ---------------------------------------------------------------------
// ContextCardBlock: tinted cards with a title or tag and a short body
// ---------------------------------------------------------------------

Widget _buildContextBlock(BuildContext context, OpenUiProps p) {
  final items = p.data('items', type: 'ContextCardItem');
  final s = _BlockSettings(context, p, gap: 10);
  final cards = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final titleText = item.stringOrNull('title')?.trim() ?? '';
    final titleWidget = titleText.isEmpty ? item.child('title') : null;
    final body = item.string('body').trim();
    if (titleText.isEmpty && titleWidget == null && body.isEmpty) continue;
    final info = _CardInfo();
    final id = item.stringOrNull('id');
    final bgColor = item.choice('bgColor', fallback: '');
    final image = _httpUrl(item.raw('bgImageSrc'));
    final alt = item.stringOrNull('bgImageAlt');
    final index = i;
    String? title() =>
        titleText.isNotEmpty ? titleText : info.read('title', 'tag');
    final onTap = _cardTap(
      context,
      s,
      () => title() ?? id ?? 'Context card ${index + 1}',
      () => <String, Object?>{
        'itemIndex': index,
        'itemId': id,
        'itemTitle': title(),
        'itemBody': body,
        'itemBgColor': bgColor.isEmpty ? null : bgColor,
        'itemBgImageSrc': image,
        'itemBgImageAlt': alt,
      },
    );
    cards.add(
      _Pressable(
        onTap: onTap,
        semanticLabel: titleText.isEmpty ? null : titleText,
        child: _ContextCard(
          info: info,
          titleText: titleText,
          titleWidget: titleWidget,
          body: body,
          gray: bgColor == 'gray',
          image: image,
          alt: alt,
          clickable: onTap != null,
        ),
      ),
    );
  }
  return _CardBlockLayout(
    cards: cards,
    maxPerRow: 3,
    carousel: s.carousel,
    responsive: s.responsive,
    gap: s.gap,
    carouselWidth: 240,
    carouselWidthNarrow: 200,
  );
}

class _ContextCard extends StatelessWidget {
  const _ContextCard({
    required this.info,
    required this.titleText,
    required this.titleWidget,
    required this.body,
    required this.gray,
    required this.image,
    required this.alt,
    required this.clickable,
  });

  final _CardInfo info;
  final String titleText;
  final Widget? titleWidget;
  final String body;
  final bool gray;
  final String? image;
  final String? alt;
  final bool clickable;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final onImage = image != null;
    final fg = onImage ? Colors.white : t.textColor;
    final muted = onImage ? Colors.white.withValues(alpha: 0.85) : t.mutedColor;
    final bodyStyle = _style(t, size: 14.5, weight: FontWeight.w600, color: fg);
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 10,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: <Widget>[
              Expanded(
                child: titleText.isNotEmpty
                    ? Text(
                        titleText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _style(
                          t,
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: muted,
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: _slot(
                          titleWidget,
                          info,
                          'title',
                          tagSize: 'sm',
                          onImage: onImage,
                        ),
                      ),
              ),
              if (clickable) _Chevron(onImage: onImage),
            ],
          ),
          if (body.isNotEmpty)
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: _inlineMarkdown(
                  body,
                  bodyStyle,
                  onImage
                      ? Colors.white
                      : Theme.of(context).accentForegroundOn(t.cardColor),
                ),
              ),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    final radius = BorderRadius.circular(OpenUiTokens.radiusCard);
    if (!onImage) {
      return DecoratedBox(
        decoration: gray
            ? BoxDecoration(color: t.sunkColor, borderRadius: radius)
            : t.cardDecoration(),
        child: content,
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: _NetImage(src: image, alt: alt),
          ),
          const Positioned.fill(child: _PhotoScrim()),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: content,
          ),
        ],
      ),
    );
  }
}

/// A neutral dark wash over a photo so white text on it stays legible.
class _PhotoScrim extends StatelessWidget {
  const _PhotoScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x2E000000), Color(0x8F000000)],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// CompositeCardBlock: header, body stack, price and button footer
// ---------------------------------------------------------------------

Widget _buildCompositeBlock(BuildContext context, OpenUiProps p) {
  final items = p.data('items', type: 'CompositeCardItem');
  final s = _BlockSettings(context, p, gap: 12);
  final t = OpenUiTheme.of(context);
  final cards = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final header = item.child('header');
    final body = item.children('body');
    final footer = item.map('footer');
    final price = _footerPart(footer['price'], bold: true);
    final button = _footerPart(footer['button'], bold: false);
    if (header == null && body.isEmpty && price == null && button == null) {
      continue;
    }
    final info = _CardInfo();
    final id = item.stringOrNull('id');
    final index = i;
    final onTap = _cardTap(
      context,
      s,
      () =>
          info.read('header', 'title', const <String>['value', 'alt']) ??
          id ??
          'Composite card ${index + 1}',
      () => <String, Object?>{
        'itemIndex': index,
        'itemId': id,
        'itemHeaderTitle': info.read('header', 'title', const <String>[
          'value',
        ]),
        'itemHeaderSubtitle': info.read('header', 'subtitle', const <String>[
          'subtext',
        ]),
        'itemHeaderAlt': info.read('header', 'alt'),
        'itemBodyCount': body.length,
        'itemFooterPrice': info.read('price', 'value'),
      },
    );
    cards.add(
      _Pressable(
        onTap: onTap,
        child: DecoratedBox(
          decoration: t.cardDecoration(),
          child: Padding(
            padding: OpenUiTokens.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              spacing: 12,
              children: <Widget>[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: <Widget>[
                    if (header != null) _slot(header, info, 'header'),
                    for (final b in body)
                      _slot(
                        b,
                        info,
                        'body',
                        textSize: 'sm',
                        tagSize: 'sm',
                        compact: true,
                      ),
                  ],
                ),
                if (price != null || button != null)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    spacing: 10,
                    children: <Widget>[
                      Expanded(
                        child: price == null
                            ? const SizedBox.shrink()
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: _slot(price, info, 'price'),
                              ),
                      ),
                      ?button,
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return _CardBlockLayout(
    cards: cards,
    maxPerRow: 2,
    carousel: s.carousel,
    responsive: s.responsive,
    gap: s.gap,
    carouselWidth: 320,
    carouselWidthNarrow: 280,
  );
}

/// A footer part: a rendered child, or plain text for a price.
Widget? _footerPart(Object? v, {required bool bold}) {
  if (v is Widget) return v;
  if (v is List) {
    for (final x in v) {
      if (x is Widget) return x;
    }
    return null;
  }
  final s = _str(v).trim();
  if (s.isEmpty || !bold) return null;
  return _PlainPrice(text: s);
}

class _PlainPrice extends StatelessWidget {
  const _PlainPrice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    _SlotScope.report(context, <String, String?>{'value': text});
    final t = OpenUiTheme.of(context);
    return Text(
      text,
      style: _style(t, size: 17, weight: FontWeight.w700, number: true),
    );
  }
}

// ---------------------------------------------------------------------
// VisualCardBlock: photo-first cards
// ---------------------------------------------------------------------

Widget _buildVisualBlock(BuildContext context, OpenUiProps p) {
  final items = p.data('items', type: 'VisualCardItem');
  final s = _BlockSettings(context, p, gap: 12);
  final t = OpenUiTheme.of(context);
  final cards = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final body = item.child('body');
    final tag = item.child('tag');
    final image = _httpUrl(item.raw('bgImageSrc'));
    final alt = item.stringOrNull('bgImageAlt');
    if (body == null && tag == null && image == null) continue;
    final info = _CardInfo();
    final id = item.stringOrNull('id');
    final index = i;
    final onTap = _cardTap(
      context,
      s,
      () =>
          info.read('body', 'value') ??
          info.read('tag', 'tag') ??
          id ??
          'Visual card ${index + 1}',
      () => <String, Object?>{
        'itemIndex': index,
        'itemId': id,
        'itemTag': info.read('tag', 'tag'),
        'itemBody': info.read('body', 'value'),
        'itemBodySubtext': info.read('body', 'subtext'),
        'itemBgImageSrc': image,
        'itemBgImageAlt': alt,
      },
    );
    final radius = BorderRadius.circular(OpenUiTokens.radiusCard);
    cards.add(
      _Pressable(
        onTap: onTap,
        semanticLabel: alt,
        child: SizedBox(
          height: 260,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: t.borderColor,
                width: OpenUiTokens.borderWidth,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _NetImage(src: image, alt: alt, iconSize: 28),
                  const _PhotoScrim(),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _slot(
                                  tag,
                                  info,
                                  'tag',
                                  tagSize: 'sm',
                                  onImage: true,
                                ),
                              ),
                            ),
                            if (onTap != null) const _Chevron(onImage: true),
                          ],
                        ),
                        if (body != null)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: t.cardColor,
                              borderRadius: BorderRadius.circular(
                                OpenUiTokens.radiusInner,
                              ),
                              border: Border.all(
                                color: t.borderColor,
                                width: OpenUiTokens.borderWidth,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: _slot(body, info, 'body', textSize: 'sm'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  return _CardBlockLayout(
    cards: cards,
    maxPerRow: 3,
    carousel: s.carousel,
    responsive: s.responsive,
    gap: s.gap,
    carouselWidth: 280,
    carouselWidthNarrow: 240,
  );
}
