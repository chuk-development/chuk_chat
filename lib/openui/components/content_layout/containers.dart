// B1 containers: Stack, Carousel, Modal.

part of '../content_layout.dart';

// ---------------------------------------------------------------------
// Stack: a flex box. A column stretches its children (CSS default). A
// row gives each child a loose flex share, so text wraps instead of
// overflowing; `stretch` in a row falls back to `start`, because a
// chat row has no fixed height to stretch to.
// ---------------------------------------------------------------------

Widget _buildStack(BuildContext context, OpenUiProps props) {
  final children = props.children('children');
  if (children.isEmpty) return const SizedBox.shrink();
  final row = props.choice('direction', fallback: 'column') == 'row';
  final gap = OpenUiTokens.gap(props.choice('gap', fallback: 'm'));
  final align = props.choice('align', fallback: row ? 'start' : 'stretch');
  var justify = props.choice('justify', fallback: 'start');
  final wrap = props.boolean('wrap');
  if (wrap) {
    if (justify == 'between') justify = 'start';
    return Wrap(
      direction: row ? Axis.horizontal : Axis.vertical,
      spacing: gap,
      runSpacing: gap,
      alignment: switch (justify) {
        'center' => WrapAlignment.center,
        'end' => WrapAlignment.end,
        'around' => WrapAlignment.spaceAround,
        'evenly' => WrapAlignment.spaceEvenly,
        _ => WrapAlignment.start,
      },
      crossAxisAlignment: switch (align) {
        'center' => WrapCrossAlignment.center,
        'end' => WrapCrossAlignment.end,
        _ => WrapCrossAlignment.start,
      },
      children: children,
    );
  }
  if (!row) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: switch (align) {
        'start' || 'baseline' => CrossAxisAlignment.start,
        'center' => CrossAxisAlignment.center,
        'end' => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.stretch,
      },
      spacing: gap,
      children: children,
    );
  }
  return Row(
    mainAxisAlignment: switch (justify) {
      'center' => MainAxisAlignment.center,
      'end' => MainAxisAlignment.end,
      'between' => MainAxisAlignment.spaceBetween,
      'around' => MainAxisAlignment.spaceAround,
      'evenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    },
    crossAxisAlignment: switch (align) {
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      'baseline' => CrossAxisAlignment.baseline,
      _ => CrossAxisAlignment.start,
    },
    textBaseline: align == 'baseline' ? TextBaseline.alphabetic : null,
    spacing: gap,
    children: <Widget>[for (final c in children) Flexible(child: c)],
  );
}

// ---------------------------------------------------------------------
// Carousel: slides side by side, scrolled by hand or by the two arrow
// buttons. All slides take the height of the tallest one.
// ---------------------------------------------------------------------

Widget _buildCarousel(BuildContext context, OpenUiProps props) {
  final slides = <List<Widget>>[
    for (final s in props.list('children')) _widgetsOf(s),
  ].where((s) => s.isNotEmpty).toList();
  if (slides.isEmpty) return const SizedBox.shrink();
  return _Carousel(
    slides: slides,
    variant: props.choice('variant', fallback: 'card'),
  );
}

class _Carousel extends StatefulWidget {
  const _Carousel({required this.slides, required this.variant});

  final List<List<Widget>> slides;
  final String variant;

  /// The gap between two slides.
  static const double gap = 10;

  /// The widest a slide gets (desktop); on a phone it is 82 % of the
  /// width, so the next slide peeks in.
  static const double maxSlideWidth = 320;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final ScrollController _scroll = ScrollController();
  final Map<int, double> _heights = <int, double>{};
  double _tallest = 0;
  bool _canBack = false;
  bool _canForward = false;
  double _slideWidth = _Carousel.maxSlideWidth;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateArrows);
  }

  @override
  void didUpdateWidget(covariant _Carousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.slides.length < oldWidget.slides.length) {
      _heights.removeWhere((i, _) => i >= widget.slides.length);
      _tallest = _heights.values.fold(0, math.max);
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_updateArrows)
      ..dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    final back = p.extentBefore > 0.5;
    final forward = p.extentAfter > 0.5;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  void _measured(int index, double height) {
    _heights[index] = height;
    final tallest = _heights.values.fold<double>(0, math.max);
    if ((tallest - _tallest).abs() > 0.5 && mounted) {
      setState(() => _tallest = tallest);
    }
    _updateArrows();
  }

  void _step(int direction) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = (p.pixels + direction * (_slideWidth + _Carousel.gap)).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: kExpressiveDecelerate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final padding = OpenUiTokens.cardPadding;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : OpenUiTokens.chatColumnWidth;
        _slideWidth = widget.slides.length == 1
            ? width
            : math.min(width * 0.82, _Carousel.maxSlideWidth);
        final minHeight = _tallest > 0 ? _tallest + padding.vertical : 0.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                SchedulerBinding.instance.addPostFrameCallback(
                  (_) => _updateArrows(),
                );
                return false;
              },
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: _Carousel.gap,
                  children: <Widget>[
                    for (var i = 0; i < widget.slides.length; i++)
                      SizedBox(
                        width: _slideWidth,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: minHeight),
                          child: DecoratedBox(
                            decoration: t.cardDecoration(
                              variant: widget.variant,
                            ),
                            child: Padding(
                              padding: padding,
                              child: Align(
                                alignment: Alignment.topCenter,
                                heightFactor: 1,
                                child: MeasureSize(
                                  onChange: (s) => _measured(i, s.height),
                                  child: _blockColumn(
                                    widget.slides[i],
                                    gap: 10,
                                  ),
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
            if (_canBack || _canForward)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: <Widget>[
                  ExpressiveIconButton(
                    hugeIcon: HugeIcons.arrowLeft01,
                    size: 36,
                    color: t.sunkColor,
                    tooltip: openUiStrings(context).openUiPrevious,
                    onTap: _canBack ? () => _step(-1) : null,
                  ),
                  ExpressiveIconButton(
                    hugeIcon: HugeIcons.arrowRight01,
                    size: 36,
                    color: t.sunkColor,
                    tooltip: openUiStrings(context).openUiNext,
                    onTap: _canForward ? () => _step(1) : null,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Modal: a dialog over the app. `open` is a `$binding<boolean>`; true
// shows it, the close button, Escape and a tap on the scrim write
// false. The dialog sits in the root overlay through an OverlayPortal,
// so its children keep the renderer, form and action scopes of the
// place where the Modal is written. In the chat it draws nothing.
// ---------------------------------------------------------------------

Widget _buildModal(BuildContext context, OpenUiProps props) {
  final binding = props.binding('open');
  return _Modal(
    title: props.string('title').trim(),
    binding: binding,
    literalOpen: binding == null && _truthy(props.raw('open')),
    size: props.choice('size', fallback: 'md'),
    children: props.children('children'),
  );
}

class _Modal extends StatefulWidget {
  const _Modal({
    required this.title,
    required this.binding,
    required this.literalOpen,
    required this.size,
    required this.children,
  });

  final String title;
  final OpenUiBinding? binding;

  /// `open: true` written as a literal: the dialog shows once.
  final bool literalOpen;
  final String size;
  final List<Widget> children;

  bool get wantsOpen => binding != null ? _truthy(binding!.value) : literalOpen;

  double get maxWidth => switch (size) {
    'sm' => 400,
    'lg' => 800,
    _ => 560,
  };

  @override
  State<_Modal> createState() => _ModalState();
}

class _ModalState extends State<_Modal> with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: kExpressiveShort,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _anim,
    curve: kExpressiveDecelerate,
    reverseCurve: Curves.easeIn,
  );
  bool _dismissedLiteral = false;
  bool _syncScheduled = false;

  bool get _shouldShow =>
      widget.wantsOpen && !(widget.binding == null && _dismissedLiteral);

  @override
  void initState() {
    super.initState();
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant _Modal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleSync();
  }

  @override
  void dispose() {
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  // The portal is shown or hidden after the frame: a show() during
  // build would mark the overlay dirty while it builds.
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      if (_shouldShow && !_portal.isShowing) {
        _portal.show();
        _anim.forward(from: 0);
      } else if (!_shouldShow && _portal.isShowing) {
        _anim.reverse().whenCompleteOrCancel(() {
          if (mounted && !_shouldShow) _portal.hide();
        });
      }
    });
  }

  void _close() {
    if (widget.binding != null) {
      widget.binding!.set(context, false);
    } else {
      setState(() => _dismissedLiteral = true);
    }
    _scheduleSync();
  }

  @override
  Widget build(BuildContext context) {
    // Without an overlay (a bare test host) there is nowhere to draw.
    if (Overlay.maybeOf(context, rootOverlay: true) == null) {
      return const SizedBox.shrink();
    }
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: _buildDialog,
      child: const SizedBox.shrink(),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final media = MediaQuery.of(context);
    final width = math.min(widget.maxWidth, media.size.width - 32);
    final maxHeight = media.size.height * 0.85;
    final surface = t.scheme.surfaceContainerHigh;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Focus(
        autofocus: true,
        child: FadeTransition(
          opacity: _curve,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Semantics(
                  label: openUiStrings(context).openUiClose,
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: ColoredBox(
                      color: t.scheme.scrim.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Center(
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1).animate(_curve),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(0, width),
                        maxHeight: maxHeight,
                      ),
                      child: Material(
                        color: surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(kRadiusDialog),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(22, 14, 12, 4),
                              child: Row(
                                spacing: 8,
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: (t.text.titleLarge ?? t.titleStyle)
                                          .copyWith(
                                            color: t.textColor,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ),
                                  ExpressiveIconButton(
                                    hugeIcon: HugeIcons.cancel01,
                                    size: 40,
                                    color: t.sunkColor,
                                    tooltip: openUiStrings(context).openUiClose,
                                    onTap: _close,
                                  ),
                                ],
                              ),
                            ),
                            Flexible(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  8,
                                  22,
                                  22,
                                ),
                                child: _blockColumn(widget.children),
                              ),
                            ),
                          ],
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
    );
  }
}
