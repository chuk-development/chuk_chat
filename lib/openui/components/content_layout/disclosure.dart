// B1 disclosure: Tabs, Accordion, SectionBlock, Steps.
//
// The three folding containers share one rule (_FollowStream): while
// the program streams, the newest item opens; when it ends, the first
// item opens again; after a user tap nothing moves by itself.

part of '../content_layout.dart';

// ---------------------------------------------------------------------
// Tabs: the app's connected button group (the switch above a list)
// over the content. Labels that do not fit side by side scroll in a
// strip of the same shape.
// ---------------------------------------------------------------------

Widget _buildTabs(BuildContext context, OpenUiProps props) {
  final panels = _panels(props, 'items', 'Tab');
  if (panels.isEmpty) return const SizedBox.shrink();
  return _Tabs(panels: panels, streaming: _isStreaming(context));
}

class _Tabs extends StatefulWidget {
  const _Tabs({required this.panels, required this.streaming});

  final List<_Panel> panels;
  final bool streaming;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  final _FollowStream _follow = _FollowStream();
  String? _selected;

  List<String> get _values => [for (final p in widget.panels) p.value];

  @override
  void initState() {
    super.initState();
    _selected = _follow.start(_values, streaming: widget.streaming);
  }

  @override
  void didUpdateWidget(covariant _Tabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _follow.update(_values, streaming: widget.streaming);
    if (next != null) _selected = next;
  }

  void _pick(int index) {
    if (index < 0 || index >= widget.panels.length) return;
    setState(() {
      _follow.userPicked = true;
      _selected = widget.panels[index].value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final panels = widget.panels;
    var index = panels.indexWhere((p) => p.value == _selected);
    if (index < 0) index = 0;
    final panel = panels[index];
    return _blockColumn(<Widget>[
      _TabStrip(
        labels: [for (final p in panels) p.trigger],
        selected: index,
        onSelected: _pick,
      ),
      AnimatedSize(
        duration: kExpressiveShort,
        curve: kExpressiveDecelerate,
        alignment: Alignment.topCenter,
        child: KeyedSubtree(
          key: ValueKey<String>(panel.value),
          child: _blockColumn(panel.content),
        ),
      ),
    ]);
  }
}

/// The tab switch. [ConnectedGroup] when every label fits in an equal
/// segment; else a scrolling strip with the same shell and capsule.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  static const TextStyle _labelStyle = TextStyle(
    fontWeight: FontWeight.w700,
    fontSize: 14,
  );

  /// The side padding of a segment label in [ConnectedGroup].
  static const double _segmentPadding = 12;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // The strip and the selected capsule take the OpenUI segment
    // colours, so the selection reads clearly in light mode too.
    final theme = Theme.of(context);
    final t = OpenUiTheme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          surfaceContainerHighest: t.segmentStripColor,
          primary: t.segmentSelectedColor,
          onPrimary: t.onSegmentSelectedColor,
        ),
      ),
      child: _strip(scaler),
    );
  }

  Widget _strip(TextScaler scaler) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width.isFinite && _fits(width, scaler)) {
          return ConnectedGroup(
            labels: labels,
            selected: selected,
            onSelected: onSelected,
            margin: EdgeInsets.zero,
          );
        }
        return _ScrollingTabStrip(
          labels: labels,
          selected: selected,
          onSelected: onSelected,
        );
      },
    );
  }

  bool _fits(double width, TextScaler scaler) {
    final n = labels.length;
    if (n == 0 || n > 4) return false;
    const inset = PillGeometry.filterInset;
    final segment = (width - inset * 2 - inset * (n - 1)) / n;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: _labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final needed = painter.width + _segmentPadding * 2 + 4;
      painter.dispose();
      if (needed > segment) return false;
    }
    return true;
  }
}

class _ScrollingTabStrip extends StatefulWidget {
  const _ScrollingTabStrip({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  State<_ScrollingTabStrip> createState() => _ScrollingTabStripState();
}

class _ScrollingTabStripState extends State<_ScrollingTabStrip> {
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void didUpdateWidget(covariant _ScrollingTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      // Keep the selected capsule on screen when it moves by itself.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _selectedKey.currentContext;
        if (ctx == null || !mounted) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: kExpressiveShort,
          curve: kExpressiveDecelerate,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const inset = PillGeometry.filterInset;
    const segmentHeight = PillGeometry.filterSegmentHeight;
    return SizedBox(
      height: PillGeometry.filterHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(PillGeometry.filterRadius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PillGeometry.filterRadius),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(inset),
            child: Row(
              spacing: inset,
              children: <Widget>[
                for (var i = 0; i < widget.labels.length; i++)
                  MorphTap(
                    key: i == widget.selected ? _selectedKey : null,
                    onTap: () => widget.onSelected(i),
                    color: i == widget.selected
                        ? scheme.primary
                        : Colors.transparent,
                    shape: const StadiumBorder(),
                    pressedShape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(
                      height: segmentHeight,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            widget.labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _TabStrip._labelStyle.copyWith(
                              color: i == widget.selected
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Fold row: the tappable header of an Accordion or SectionBlock item.
// ---------------------------------------------------------------------

class _FoldHeader extends StatelessWidget {
  const _FoldHeader({
    required this.label,
    required this.open,
    required this.onTap,
    required this.style,
    required this.padding,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;
  final TextStyle style;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return Semantics(
      expanded: open,
      child: MorphTap(
        onTap: onTap,
        pressedScale: 0.99,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
        ),
        pressedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
        ),
        padding: padding,
        child: Row(
          spacing: 10,
          children: <Widget>[
            Expanded(child: Text(label, style: style)),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: kExpressiveShort,
              curve: kExpressiveDecelerate,
              child: HugeIcon(
                HugeIcons.arrowDown01,
                size: 18,
                color: t.mutedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The body of a fold: grows and shrinks with the expressive curve.
Widget _foldBody({
  required bool open,
  required List<Widget> content,
  required EdgeInsets padding,
}) {
  return AnimatedSize(
    duration: kExpressiveShort,
    curve: kExpressiveDecelerate,
    alignment: Alignment.topCenter,
    child: open && content.isNotEmpty
        ? Padding(padding: padding, child: _blockColumn(content))
        : const SizedBox(width: double.infinity),
  );
}

// ---------------------------------------------------------------------
// Accordion: one card, one item open at a time, hairlines between.
// ---------------------------------------------------------------------

Widget _buildAccordion(BuildContext context, OpenUiProps props) {
  final panels = _panels(props, 'items', 'Section');
  if (panels.isEmpty) return const SizedBox.shrink();
  return _Accordion(panels: panels, streaming: _isStreaming(context));
}

class _Accordion extends StatefulWidget {
  const _Accordion({required this.panels, required this.streaming});

  final List<_Panel> panels;
  final bool streaming;

  @override
  State<_Accordion> createState() => _AccordionState();
}

class _AccordionState extends State<_Accordion> {
  final _FollowStream _follow = _FollowStream();
  String? _open;

  List<String> get _values => [for (final p in widget.panels) p.value];

  @override
  void initState() {
    super.initState();
    _open = _follow.start(_values, streaming: widget.streaming);
  }

  @override
  void didUpdateWidget(covariant _Accordion oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _follow.update(_values, streaming: widget.streaming);
    if (next != null) _open = next;
  }

  void _toggle(String value) {
    setState(() {
      _follow.userPicked = true;
      _open = _open == value ? null : value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final style = t.bodyStyle.copyWith(
      fontFamily: t.chatFontFamily,
      fontSize: t.chatFontSize,
      fontWeight: FontWeight.w600,
    );
    return DecoratedBox(
      decoration: t.cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < widget.panels.length; i++) ...<Widget>[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: _hairline(t),
                ),
              _FoldHeader(
                label: widget.panels[i].trigger,
                open: _open == widget.panels[i].value,
                onTap: () => _toggle(widget.panels[i].value),
                style: style,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
              ),
              _foldBody(
                open: _open == widget.panels[i].value,
                content: widget.panels[i].content,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// SectionBlock: headed sections on the page (no card), several can be
// open. isFoldable false: plain headed sections.
// ---------------------------------------------------------------------

Widget _buildSectionBlock(BuildContext context, OpenUiProps props) {
  final panels = _panels(props, 'sections', 'Section');
  if (panels.isEmpty) return const SizedBox.shrink();
  final foldable = props.boolean('isFoldable', fallback: true);
  if (!foldable) {
    final t = OpenUiTheme.of(context);
    return _blockColumn(gap: 20, <Widget>[
      for (final p in panels)
        _blockColumn(<Widget>[
          Text(p.trigger, style: t.titleStyle),
          ...p.content,
        ]),
    ]);
  }
  return _SectionBlock(panels: panels, streaming: _isStreaming(context));
}

class _SectionBlock extends StatefulWidget {
  const _SectionBlock({required this.panels, required this.streaming});

  final List<_Panel> panels;
  final bool streaming;

  @override
  State<_SectionBlock> createState() => _SectionBlockState();
}

class _SectionBlockState extends State<_SectionBlock> {
  final _FollowStream _follow = _FollowStream();
  final Set<String> _open = <String>{};

  List<String> get _values => [for (final p in widget.panels) p.value];

  @override
  void initState() {
    super.initState();
    final first = _follow.start(_values, streaming: widget.streaming);
    if (first != null) _open.add(first);
  }

  @override
  void didUpdateWidget(covariant _SectionBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasStreaming = oldWidget.streaming;
    final next = _follow.update(_values, streaming: widget.streaming);
    if (next == null) return;
    // While streaming, sections pile up open; at the end only the
    // first stays open (upstream behaviour).
    if (wasStreaming && !widget.streaming) _open.clear();
    _open.add(next);
  }

  void _toggle(String value) {
    setState(() {
      _follow.userPicked = true;
      if (!_open.remove(value)) _open.add(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final style = t.titleStyle.copyWith(fontSize: t.chatFontSize + 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < widget.panels.length; i++) ...<Widget>[
          if (i > 0) _hairline(t),
          _FoldHeader(
            label: widget.panels[i].trigger,
            open: _open.contains(widget.panels[i].value),
            onTap: () => _toggle(widget.panels[i].value),
            style: style,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
          ),
          _foldBody(
            open: _open.contains(widget.panels[i].value),
            content: widget.panels[i].content,
            padding: const EdgeInsets.only(bottom: 16),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Steps: a numbered list on a thin rail. The number sits in a tonal
// circle; a line joins the circles.
// ---------------------------------------------------------------------

Widget _buildSteps(BuildContext context, OpenUiProps props) {
  final items = <({String title, String details})>[
    for (final d in props.data('items'))
      (title: d.string('title').trim(), details: d.string('details').trim()),
  ].where((s) => s.title.isNotEmpty || s.details.isNotEmpty).toList();
  if (items.isEmpty) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  const dot = 26.0;
  final circleFill = t.accent.withValues(alpha: t.isDark ? 0.22 : 0.16);
  final numberColor = Theme.of(context)
      .accentForegroundOn(Color.alphaBlend(circleFill, t.scheme.surface));
  final titleStyle = t.bodyStyle.copyWith(
    fontFamily: t.chatFontFamily,
    fontSize: t.chatFontSize,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );
  final lineHeight = t.chatFontSize * 1.35;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (var i = 0; i < items.length; i++)
        Stack(
          children: <Widget>[
            // The rail to the next step. A Positioned line needs no
            // intrinsic height, which markdown cannot give.
            if (i < items.length - 1)
              Positioned(
                left: dot / 2 - 1,
                top: math.max(dot, lineHeight) + 4,
                bottom: 4,
                child: Container(width: 2, color: t.borderColor),
              ),
            Padding(
              padding: EdgeInsets.only(bottom: i < items.length - 1 ? 16 : 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: <Widget>[
                  SizedBox(
                    width: dot,
                    height: math.max(dot, lineHeight),
                    child: Center(
                      child: Container(
                        width: dot,
                        height: dot,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: circleFill,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: numberColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: math.max(0, (dot - lineHeight) / 2),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 2,
                        children: <Widget>[
                          if (items[i].title.isNotEmpty)
                            Text(items[i].title, style: titleStyle),
                          if (items[i].details.isNotEmpty)
                            _markdown(
                              context,
                              items[i].details,
                              size: t.chatFontSize - 1,
                              color: t.mutedColor,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
    ],
  );
}
