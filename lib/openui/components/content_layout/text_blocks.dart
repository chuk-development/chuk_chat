// B1 text blocks: Card (with sources and citations), CardHeader,
// TextContent, MarkDownRenderer, Callout, TextCallout, CodeBlock,
// InlineHeader, Separator.

part of '../content_layout.dart';

// ---------------------------------------------------------------------
// Card: the chat root. No surface of its own (the AI answer has no
// bubble, docs/DESIGN.md section 9); its blocks stack with the root gap.
// The sources go to the TextContent blocks below it for [n] citations.
// ---------------------------------------------------------------------

Widget _buildCard(BuildContext context, OpenUiProps props) {
  final children = props.children('children');
  final sources = props.mapList('sources');
  return _CardSources(
    sources: sources,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: OpenUiTokens.rootGap,
      children: <Widget>[
        ...children,
        if (sources.isNotEmpty) _SourcesStrip(sources: sources),
      ],
    ),
  );
}

/// Gives the `sources` of the nearest Card to the text blocks in it.
class _CardSources extends InheritedWidget {
  const _CardSources({required this.sources, required super.child});

  final List<Map<String, Object?>> sources;

  static List<Map<String, Object?>> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CardSources>()?.sources ??
      const <Map<String, Object?>>[];

  @override
  bool updateShouldNotify(_CardSources oldWidget) {
    if (oldWidget.sources.length != sources.length) return true;
    for (var i = 0; i < sources.length; i++) {
      if (oldWidget.sources[i]['url'] != sources[i]['url']) return true;
    }
    return false;
  }
}

class _SourcesStrip extends StatelessWidget {
  const _SourcesStrip({required this.sources});

  final List<Map<String, Object?>> sources;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final handler = OpenUiScope.maybeOf(context)?.handler;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (var i = 0; i < sources.length; i++)
          _SourcePill(
            index: i + 1,
            label: _sourceLabel(
              sources[i],
              openUiStrings(context).openUiSource,
            ),
            onTap: switch (_webUrl(sources[i]['url'])) {
              final String url when handler != null => () => handler.openUrl(
                url,
              ),
              _ => null,
            },
            theme: t,
          ),
      ],
    );
  }

  static String _sourceLabel(Map<String, Object?> s, String fallback) {
    final name = s['sourceName'];
    if (name is String && name.trim().isNotEmpty) return name.trim();
    final title = s['title'];
    if (title is String && title.trim().isNotEmpty) return title.trim();
    return fallback;
  }
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({
    required this.index,
    required this.label,
    required this.onTap,
    required this.theme,
  });

  final int index;
  final String label;
  final VoidCallback? onTap;
  final OpenUiTheme theme;

  @override
  Widget build(BuildContext context) {
    return MorphTap(
      onTap: onTap,
      color: theme.sunkColor,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '$index',
            style: theme.captionStyle.copyWith(
              color: Theme.of(context).accentForegroundOn(theme.sunkColor),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.captionStyle,
            ),
          ),
        ],
      ),
    );
  }
}

// Inline citations. `[1]` or `[1][2]` in the text of a Card with
// sources becomes a link to that source. Code spans and fenced code
// stay as they are. A marker with no matching source is removed, as
// upstream does. Without sources the text does not change.
final RegExp _codeSpans = RegExp(r'(`{3,}[\s\S]*?(?:`{3,}|$))|(`[^`\n]*`)');
// A run of markers (`[1]` or `[1][2][3]`). The run as a whole must not
// touch a markdown link (`[a][1]`, `[1](url)`, `[1]: url`); the markers
// inside it are linked one by one.
final RegExp _citationRun = RegExp(
  r'(?<![\]!\\\w])((?:\[\d{1,3}\])+)(?![(\[:])',
);
final RegExp _citationMarker = RegExp(r'\[(\d{1,3})\]');

String _linkCitations(String text, List<Map<String, Object?>> sources) {
  if (sources.isEmpty || !text.contains('[')) return text;
  final out = StringBuffer();
  var last = 0;
  for (final m in _codeSpans.allMatches(text)) {
    out
      ..write(_linkCitationsInProse(text.substring(last, m.start), sources))
      ..write(m.group(0));
    last = m.end;
  }
  out.write(_linkCitationsInProse(text.substring(last), sources));
  return out.toString();
}

String _linkCitationsInProse(String s, List<Map<String, Object?>> sources) {
  return s.replaceAllMapped(
    _citationRun,
    (run) => (run.group(1) ?? '').replaceAllMapped(_citationMarker, (m) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n < 1 || n > sources.length) return '';
      final url = _webUrl(sources[n - 1]['url']);
      // No backslash escapes: the app's markdown reads `\[...\]` as math.
      if (url == null) return '[$n]';
      return '[[$n]](<$url>)';
    }),
  );
}

// ---------------------------------------------------------------------
// TextContent: markdown through the app's own MarkdownMessage, in the
// user's chat font, so it reads like the rest of the answer.
// ---------------------------------------------------------------------

Widget _buildTextContent(BuildContext context, OpenUiProps props) {
  final text = props.string('text');
  if (text.trim().isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  final base = t.chatFontSize;
  final (double size, FontWeight? weight) = switch (props.choice(
    'size',
    fallback: 'default',
  )) {
    'small' => (base - 2, null),
    'small-heavy' => (base - 2, FontWeight.w600),
    'large' => (base + 2, null),
    'large-heavy' => (base + 4, FontWeight.w700),
    _ => (base, null),
  };
  return _markdown(
    context,
    _linkCitations(text, _CardSources.of(context)),
    size: size,
    weight: weight,
  );
}

// ---------------------------------------------------------------------
// MarkDownRenderer: the same markdown, bare (clear) or on a card or
// sunk surface.
// ---------------------------------------------------------------------

Widget _buildMarkDownRenderer(BuildContext context, OpenUiProps props) {
  final text = props.string('textMarkdown');
  if (text.trim().isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  final variant = props.choice('variant', fallback: 'clear');
  final body = _markdown(
    context,
    _linkCitations(text, _CardSources.of(context)),
    background: variant == 'card' ? t.cardColor : null,
  );
  if (variant == 'clear') return body;
  return DecoratedBox(
    decoration: t.cardDecoration(variant: variant),
    child: Padding(padding: OpenUiTokens.cardPadding, child: body),
  );
}

// ---------------------------------------------------------------------
// CardHeader and InlineHeader: the title of a card and the small
// heading of a section inside one.
// ---------------------------------------------------------------------

Widget _buildCardHeader(BuildContext context, OpenUiProps props) {
  final title = props.string('title').trim();
  final subtitle = props.string('subtitle').trim();
  if (title.isEmpty && subtitle.isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: <Widget>[
      if (title.isNotEmpty)
        Text(
          title,
          style: (t.text.titleLarge ?? t.titleStyle).copyWith(
            color: t.textColor,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            height: 1.2,
          ),
        ),
      if (subtitle.isNotEmpty)
        Text(subtitle, style: t.bodyStyle.copyWith(color: t.mutedColor)),
    ],
  );
}

Widget _buildInlineHeader(BuildContext context, OpenUiProps props) {
  final heading = props.string('heading').trim();
  final description = props.string('description').trim();
  if (heading.isEmpty && description.isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: <Widget>[
      if (heading.isNotEmpty) Text(heading, style: t.titleStyle),
      if (description.isNotEmpty)
        Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: t.captionStyle,
        ),
    ],
  );
}

// ---------------------------------------------------------------------
// Callout: a tinted tile with a status icon. With a `$visible` binding
// it closes itself after 3 s by writing false to the binding.
// ---------------------------------------------------------------------

Widget _buildCallout(BuildContext context, OpenUiProps props) {
  final binding = props.binding('visible');
  return _Callout(
    variant: props.choice('variant', fallback: 'info'),
    title: props.string('title').trim(),
    description: props.string('description').trim(),
    binding: binding,
    literalVisible: binding == null && props.has('visible')
        ? _truthy(props.raw('visible'))
        : true,
  );
}

class _Callout extends StatefulWidget {
  const _Callout({
    required this.variant,
    required this.title,
    required this.description,
    required this.binding,
    required this.literalVisible,
  });

  final String variant;
  final String title;
  final String description;
  final OpenUiBinding? binding;
  final bool literalVisible;

  /// How long a callout with a `$visible` binding stays.
  static const Duration autoDismiss = Duration(seconds: 3);

  bool get visible =>
      binding != null ? _truthy(binding!.value) : literalVisible;

  @override
  State<_Callout> createState() => _CalloutState();
}

class _CalloutState extends State<_Callout> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant _Callout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasReactive = oldWidget.binding != null;
    final isReactive = widget.binding != null;
    if (wasReactive != isReactive || oldWidget.visible != widget.visible) {
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (widget.binding == null || !widget.visible) return;
    _timer = Timer(_Callout.autoDismiss, () {
      if (!mounted) return;
      widget.binding?.set(context, false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final show =
        widget.visible &&
        (widget.title.isNotEmpty || widget.description.isNotEmpty);
    return AnimatedSize(
      duration: kExpressiveShort,
      curve: kExpressiveDecelerate,
      alignment: Alignment.topCenter,
      child: show ? _tile(context) : const SizedBox(width: double.infinity),
    );
  }

  Widget _tile(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final v = widget.variant == 'neutral' ? null : widget.variant;
    final titleStyle = t.bodyStyle.copyWith(
      fontFamily: t.chatFontFamily,
      fontSize: t.chatFontSize,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
    // The icon box is as high as one title line, so the icon sits on
    // the middle of the first line (docs/DESIGN.md, icons).
    final lineHeight = t.chatFontSize * 1.35;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.statusFill(v),
        borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
      ),
      child: Padding(
        padding: OpenUiTokens.innerPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: <Widget>[
            SizedBox(
              height: lineHeight,
              child: Center(
                child: HugeIcon(
                  _calloutIcon(widget.variant),
                  size: 18,
                  // A pale accent on its own tint must still read.
                  color: v == null
                      ? t.mutedColor
                      : accentForegroundFor(
                          t.statusColor(v),
                          Color.alphaBlend(
                            t.statusFill(v),
                            Theme.of(context).scaffoldBackgroundColor,
                          ),
                        ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 2,
                children: <Widget>[
                  if (widget.title.isNotEmpty)
                    Text(widget.title, style: titleStyle),
                  if (widget.description.isNotEmpty)
                    _markdown(
                      context,
                      widget.description,
                      size: t.chatFontSize - 1,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static HugeIconData _calloutIcon(String variant) => switch (variant) {
    'success' => HugeIcons.checkmarkCircle02,
    'warning' => HugeIcons.alert02,
    'error' => HugeIcons.alertCircle,
    _ => HugeIcons.informationCircle,
  };
}

// ---------------------------------------------------------------------
// TextCallout: a quote-like note with a 2 px status bar on the left,
// no fill (upstream look).
// ---------------------------------------------------------------------

Widget _buildTextCallout(BuildContext context, OpenUiProps props) {
  final title = props.string('title').trim();
  final description = props.string('description').trim();
  if (title.isEmpty && description.isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  final variant = props.choice('variant', fallback: 'neutral');
  final barColor = variant == 'neutral' ? t.accent : t.statusColor(variant);
  // A status colour as text must still read on the page (3 : 1).
  final titleColor = variant == 'neutral'
      ? t.textColor
      : accentForegroundFor(
          t.statusColor(variant),
          Theme.of(context).scaffoldBackgroundColor,
        );
  return DecoratedBox(
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: barColor, width: 2)),
    ),
    child: Padding(
      padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: <Widget>[
          if (title.isNotEmpty)
            Text(
              title,
              style: t.bodyStyle.copyWith(
                fontFamily: t.chatFontFamily,
                fontSize: t.chatFontSize,
                fontWeight: FontWeight.w700,
                color: titleColor,
              ),
            ),
          if (description.isNotEmpty)
            _markdown(context, description, size: t.chatFontSize - 1),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------
// CodeBlock: a fenced block through MarkdownMessage, so it is the app's
// own code block (header with the language, copy button, highlight).
// ---------------------------------------------------------------------

Widget _buildCodeBlock(BuildContext context, OpenUiProps props) {
  final code = props.string('codeString');
  if (code.trim().isEmpty) return const SizedBox.shrink();
  final language = props
      .string('language')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_+#.\-]'), '');
  return _markdown(context, _fence(code, language));
}

/// Wraps [code] in a fence longer than any backtick run inside it.
String _fence(String code, String language) {
  var longest = 0;
  for (final m in RegExp('`+').allMatches(code)) {
    longest = math.max(longest, m.end - m.start);
  }
  final fence = '`' * math.max(3, longest + 1);
  final body = code.endsWith('\n') ? code : '$code\n';
  return '$fence$language\n$body$fence';
}

// ---------------------------------------------------------------------
// Separator: a hairline. Vertical inside a row Stack.
// ---------------------------------------------------------------------

Widget _buildSeparator(BuildContext context, OpenUiProps props) {
  final t = OpenUiTheme.of(context);
  final vertical =
      props.choice('orientation', fallback: 'horizontal') == 'vertical';
  final line = vertical
      ? ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 20),
          child: SizedBox(
            width: OpenUiTokens.borderWidth,
            child: ColoredBox(color: t.hairline),
          ),
        )
      : _hairline(t);
  if (props.boolean('decorative', fallback: true)) {
    return ExcludeSemantics(child: line);
  }
  return Semantics(
    label: openUiStrings(context).openUiSeparator,
    child: line,
  );
}
