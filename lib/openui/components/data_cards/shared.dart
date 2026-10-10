// Shared parts of the B4 components: text styles, the slot scope that
// lets a card block set the size of its children and read their text,
// network images, the equal-height row and the item action.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

part of '../data_cards.dart';

// ---------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------

/// Tabular figures, so numbers line up in columns and do not jump.
const List<FontFeature> _tabular = <FontFeature>[FontFeature.tabularFigures()];

/// [v] as display text. Numbers drop a `.0`; maps and lists give ''.
String _str(Object? v) {
  if (v is String) return v;
  if (v is int) return v.toString();
  if (v is double) {
    if (!v.isFinite) return '';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }
  if (v is bool) return v.toString();
  return '';
}

/// [v] as a number, or `null`.
double? _num(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final n = double.tryParse(v.trim().replaceAll('%', ''));
    return n != null && n.isFinite ? n : null;
  }
  return null;
}

/// [url] when it is an http or https URL, else `null`.
///
/// Image URLs come from model output. Only http and https are fetched,
/// as in the news cards: another scheme could reach a local file or an
/// unexpected handler.
String? _httpUrl(Object? url) {
  final s = _str(url).trim();
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s);
  if (uri == null || !uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? s : null;
}

/// The colour of a `metric` subtext: green for a leading `+`, red for a
/// leading `-` (or the minus sign), else `null`.
Color? _metricTone(OpenUiTheme t, String variant, String subtext) {
  if (variant != 'metric') return null;
  final s = subtext.trimLeft();
  if (s.startsWith('+')) return t.success;
  if (s.startsWith('-') || s.startsWith('−')) return t.danger;
  return null;
}

/// The gap of a card block: a number (pixels), a gap name of the
/// upstream scale (`s`, `m`, ...) or a CSS length (`12px`, `1rem`).
double _blockGap(OpenUiProps p, double fallback) {
  final raw = p.raw('gap');
  final n = _num(raw);
  if (n != null) return n.clamp(0, 48).toDouble();
  final s = _str(raw).trim().toLowerCase();
  if (s.isEmpty) return fallback;
  if (s.endsWith('px')) {
    final v = double.tryParse(s.substring(0, s.length - 2));
    if (v != null && v.isFinite) return v.clamp(0, 48).toDouble();
  }
  if (s.endsWith('rem')) {
    final v = double.tryParse(s.substring(0, s.length - 3));
    if (v != null && v.isFinite) return (v * 16).clamp(0, 48).toDouble();
  }
  const names = <String>{'none', 'xs', 's', 'm', 'l', 'xl', '2xl'};
  if (names.contains(s)) return OpenUiTokens.gap(s);
  return fallback;
}

// ---------------------------------------------------------------------
// Text styles
// ---------------------------------------------------------------------

/// A text style of the B4 components, from the app theme.
TextStyle _style(
  OpenUiTheme t, {
  required double size,
  FontWeight weight = FontWeight.w400,
  Color? color,
  bool number = false,
  double height = 1.35,
}) {
  return (t.text.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: size,
    fontWeight: weight,
    color: color ?? t.textColor,
    height: height,
    fontFeatures: number ? _tabular : null,
  );
}

// ---------------------------------------------------------------------
// Slot scope
// ---------------------------------------------------------------------

/// What the children of one card wrote about themselves while they were
/// built: titles, values, tag text. A card block reads it when the card
/// is tapped, for the label and the item context of the action.
class _CardInfo {
  final Map<String, Map<String, String>> _slots =
      <String, Map<String, String>>{};

  void report(String slot, Map<String, String?> fields) {
    final target = _slots.putIfAbsent(slot, () => <String, String>{});
    for (final e in fields.entries) {
      final v = e.value?.trim();
      if (v != null && v.isNotEmpty) target[e.key] = v;
    }
  }

  /// The first non-empty [field] of [slot], else of the [fallbacks] in
  /// order, or `null`.
  String? read(String slot, String field, [List<String> fallbacks = const []]) {
    final s = _slots[slot];
    if (s == null) return null;
    final v = s[field];
    if (v != null) return v;
    for (final f in fallbacks) {
      final w = s[f];
      if (w != null) return w;
    }
    return null;
  }
}

/// Puts the children of one slot of a card (the `lhs`, the `body`, the
/// `tag`) in context: the sizes the card wants for them, whether they
/// sit on a photo, and where they write their text.
class _SlotScope extends InheritedWidget {
  const _SlotScope({
    required super.child,
    this.info,
    this.slot = '',
    this.textSize,
    this.tagSize,
    this.compact = false,
    this.onImage = false,
  });

  /// Where the children write their text, or `null`.
  final _CardInfo? info;

  /// The slot name in [info].
  final String slot;

  /// The size `Text`, `BoldText` and the icon and image rows take, or
  /// `null` for their own.
  final String? textSize;

  /// The size a `Tag` takes, or `null` for its own.
  final String? tagSize;

  /// Lists (`EntityList`, `ListBlock`) draw small.
  final bool compact;

  /// The children sit on a photo: tags draw dark and see-through.
  final bool onImage;

  static _SlotScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SlotScope>();

  /// Writes [fields] to the card of the nearest slot, if any.
  static void report(BuildContext context, Map<String, String?> fields) {
    final s = maybeOf(context);
    s?.info?.report(s.slot, fields);
  }

  @override
  bool updateShouldNotify(_SlotScope old) =>
      !identical(info, old.info) ||
      slot != old.slot ||
      textSize != old.textSize ||
      tagSize != old.tagSize ||
      compact != old.compact ||
      onImage != old.onImage;
}

// ---------------------------------------------------------------------
// Network image
// ---------------------------------------------------------------------

/// A network image with a calm placeholder while it loads and a quiet
/// tile when it fails. Only http and https URLs load.
class _NetImage extends StatelessWidget {
  const _NetImage({required this.src, this.alt, this.iconSize = 20});

  final String? src;
  final String? alt;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final url = _httpUrl(src);
    Widget tile(HugeIconData icon) => ColoredBox(
      color: t.sunkColor,
      child: Center(
        child: HugeIcon(
          icon,
          size: iconSize,
          color: t.mutedColor.withValues(alpha: 0.7),
        ),
      ),
    );
    if (url == null) return tile(HugeIcons.image01);
    final label = alt?.trim();
    return Semantics(
      image: true,
      label: label == null || label.isEmpty ? null : label,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSync) {
          if (wasSync || frame != null) {
            return Stack(
              fit: StackFit.passthrough,
              children: <Widget>[
                Positioned.fill(child: ColoredBox(color: t.sunkColor)),
                AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: child,
                ),
              ],
            );
          }
          return ColoredBox(color: t.sunkColor);
        },
        errorBuilder: (context, error, stack) =>
            tile(HugeIcons.imageNotFound01),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Pressable card
// ---------------------------------------------------------------------

/// A card surface that springs when pressed (the app's MorphTap), or a
/// plain one when [onTap] is `null`.
class _Pressable extends StatelessWidget {
  const _Pressable({
    required this.child,
    required this.onTap,
    this.radius = OpenUiTokens.radiusCard,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return Semantics(
      button: true,
      label: semanticLabel,
      child: MorphTap(
        onTap: onTap,
        shape: shape,
        pressedShape: shape,
        pressedScale: 0.98,
        child: child,
      ),
    );
  }
}

/// The small chevron that marks a clickable card.
class _Chevron extends StatelessWidget {
  const _Chevron({this.onImage = false, this.size = 16});

  final bool onImage;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final icon = HugeIcon(
      HugeIcons.arrowRight01,
      size: size,
      color: onImage ? Colors.white : t.mutedColor,
    );
    if (!onImage) return icon;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(OpenUiTokens.radiusChip),
      ),
      child: Padding(padding: const EdgeInsets.all(3), child: icon),
    );
  }
}

// ---------------------------------------------------------------------
// Equal-height row
// ---------------------------------------------------------------------

/// A row whose children all get the height of the tallest one, without
/// intrinsic measuring (a chart or a markdown child may not support it).
///
/// Each child is laid out twice: once to find its natural height, then
/// with the shared height. With [itemWidth] the row takes the width the
/// children need (for a horizontal scroll view); without it, the
/// children share the given width equally.
class _EqualRow extends MultiChildRenderObjectWidget {
  const _EqualRow({required super.children, this.gap = 0, this.itemWidth});

  final double gap;
  final double? itemWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEqualRow(gap, itemWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderEqualRow renderObject) {
    renderObject
      ..gap = gap
      ..itemWidth = itemWidth;
  }
}

class _EqualRowData extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualRowData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualRowData> {
  _RenderEqualRow(this._gap, this._itemWidth);

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double? _itemWidth;
  set itemWidth(double? v) {
    if (v == _itemWidth) return;
    _itemWidth = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualRowData) child.parentData = _EqualRowData();
  }

  double _childWidth(BoxConstraints c) {
    final fixed = _itemWidth;
    if (fixed != null) return fixed;
    final n = childCount;
    if (n == 0 || !c.hasBoundedWidth) return 0;
    return ((c.maxWidth - _gap * (n - 1)) / n).clamp(0, double.infinity);
  }

  @override
  void performLayout() {
    final c = constraints;
    final w = _childWidth(c);
    var tallest = 0.0;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: w), parentUsesSize: true);
      if (child.size.height > tallest) tallest = child.size.height;
      child = childAfter(child);
    }
    if (c.hasBoundedHeight && tallest > c.maxHeight) tallest = c.maxHeight;
    var x = 0.0;
    child = firstChild;
    while (child != null) {
      child.layout(
        BoxConstraints.tightFor(width: w, height: tallest),
        parentUsesSize: true,
      );
      (child.parentData! as _EqualRowData).offset = Offset(x, 0);
      x += w + _gap;
      child = childAfter(child);
    }
    final used = childCount == 0 ? 0.0 : x - _gap;
    size = c.constrain(
      Size(
        _itemWidth != null || !c.hasBoundedWidth ? used : c.maxWidth,
        tallest,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
}

// ---------------------------------------------------------------------
// Card block layout (grid or carousel)
// ---------------------------------------------------------------------

/// How many cards go in each row: at most [maxPerRow] (2 or 3), and
/// never a lonely last card when that can be avoided (upstream rule).
List<int> _rowConfiguration(int n, int maxPerRow) {
  if (n <= 0) return const <int>[];
  if (n == 1) return const <int>[1];
  if (maxPerRow <= 2) {
    return <int>[for (var i = 0; i < n ~/ 2; i++) 2, if (n.isOdd) 1];
  }
  if (n % 3 == 0) return <int>[for (var i = 0; i < n ~/ 3; i++) 3];
  if (n % 3 == 2) {
    final rows = <int>[for (var i = 0; i < n ~/ 3; i++) 3];
    rows.insert((rows.length / 2).ceil(), 2);
    return rows;
  }
  return <int>[for (var i = 0; i < (n - 4) ~/ 3; i++) 3, 2, 2];
}

/// The grid or the carousel of a card block.
///
/// Grid, as upstream: when [responsive], a width under 480 gives one
/// column and a width under 768 two (an odd last card spans the row);
/// wider, the rows of [_rowConfiguration]. Carousel: a horizontal
/// scroll of cards [carouselWidth] wide (narrower on a phone).
class _CardBlockLayout extends StatelessWidget {
  const _CardBlockLayout({
    required this.cards,
    required this.maxPerRow,
    required this.carousel,
    required this.responsive,
    required this.gap,
    required this.carouselWidth,
    required this.carouselWidthNarrow,
  });

  final List<Widget> cards;
  final int maxPerRow;
  final bool carousel;
  final bool responsive;
  final double gap;
  final double carouselWidth;
  final double carouselWidthNarrow;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : OpenUiTokens.chatColumnWidth;
        if (carousel) {
          final itemWidth = responsive && width < 480
              ? carouselWidthNarrow
              : carouselWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: _EqualRow(
              gap: gap,
              itemWidth: itemWidth.clamp(120, width).toDouble(),
              children: cards,
            ),
          );
        }
        final List<int> rows;
        if (responsive && width < 480) {
          rows = <int>[for (final _ in cards) 1];
        } else if (responsive && width < 768) {
          rows = _rowConfiguration(cards.length, 2);
        } else {
          rows = _rowConfiguration(cards.length, maxPerRow);
        }
        final out = <Widget>[];
        var start = 0;
        for (final count in rows) {
          final end = (start + count).clamp(0, cards.length);
          final slice = cards.sublist(start, end);
          out.add(
            slice.length == 1
                ? slice.first
                : _EqualRow(gap: gap, children: slice),
          );
          start = end;
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: out,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Item action
// ---------------------------------------------------------------------

/// Runs the shared [action] of a card block for one card.
///
/// As upstream (`withItemContext`): every message step to the assistant
/// gets the card as context (`Selected item: {...}`), so the model knows
/// which card was tapped. [label] is the message of an action without
/// its own message text.
void _runItemAction(
  BuildContext context,
  OpenUiAction action, {
  required String label,
  required Map<String, Object?> item,
}) {
  final clean = <String, Object?>{
    for (final e in item.entries)
      if (e.value != null &&
          !(e.value is String && (e.value! as String).isEmpty))
        e.key: e.value,
  };
  if (clean.isEmpty) {
    action.run(context, label: label);
    return;
  }
  final suffix = 'Selected item: ${jsonEncode(clean)}';
  final steps = <ActionStep>[
    for (final step in action.plan.steps)
      if (step is ContinueConversationStep)
        ContinueConversationStep(
          messageAst: step.messageAst,
          contextAst: switch (step.contextAst) {
            null => Literal(suffix, offset: 0),
            Literal(:final value) when value is String && value.isNotEmpty =>
              Literal('$value\n$suffix', offset: 0),
            Literal() || NullLiteral() => Literal(suffix, offset: 0),
            final AstNode other => BinaryOp(
              '+',
              other,
              Literal('\n$suffix', offset: 0),
              offset: other.offset,
            ),
          },
        )
      else
        step,
  ];
  OpenUiAction(ActionPlan(steps: steps)).run(context, label: label);
}

/// Whether the statement [statementId] is still being streamed. A card
/// block does not take taps then, like a button.
bool _streamingHere(BuildContext context, String statementId) {
  final renderer = RendererScope.maybeFind(context);
  return renderer != null &&
      renderer.isStreaming &&
      renderer.incomplete.contains(statementId);
}

// ---------------------------------------------------------------------
// Inline markdown (the body of a context card)
// ---------------------------------------------------------------------

/// Inline markdown as text spans: `**bold**`, `*italic*` / `_italic_`,
/// `` `code` `` and `[label](url)`. Block syntax is shown as text, as
/// the upstream inline renderer does.
List<InlineSpan> _inlineMarkdown(String text, TextStyle base, Color link) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(
    r'\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)',
  );
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    if (m.group(1) != null || m.group(2) != null) {
      spans.add(
        TextSpan(
          text: m.group(1) ?? m.group(2),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    } else if (m.group(3) != null || m.group(4) != null) {
      spans.add(
        TextSpan(
          text: m.group(3) ?? m.group(4),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else if (m.group(5) != null) {
      spans.add(
        TextSpan(
          text: m.group(5),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) * 0.92,
          ),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m.group(6),
          style: TextStyle(color: link, decoration: TextDecoration.underline),
        ),
      );
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}
