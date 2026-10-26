// lib/widgets/visual_answer_blocks_more.dart
//
// Part of markdown_message.dart: the answer modules that came in with the
// Figma "KI-Chat" visual library (file "Untitled", Page 1) — `::: check`,
// `::: term`, `::: grid`, `::: sizes`, `::: quote` and `::: more`. The parse
// half is in `lib/utils/answer_blocks_parser.dart`. Same rules as the other
// modules (visual_answer_blocks.dart): colours from the surrounding message,
// flat fills and hairlines, HugeIcons for every glyph, no glow and no
// coloured shadow (docs/DESIGN.md §8).

part of 'markdown_message.dart';

// ---------------------------------------------------------------------------
// check — checklist

class _CheckBlock extends StatefulWidget {
  const _CheckBlock({required this.spec, required this.s});

  final CheckSpec spec;
  final _AnswerBlockStyle s;

  @override
  State<_CheckBlock> createState() => _CheckBlockState();
}

class _CheckBlockState extends State<_CheckBlock> {
  /// Ticks the reader set or cleared, by index. Local only: the list is a
  /// reading aid, not a document the answer is rewritten with.
  final Map<int, bool> _override = <int, bool>{};

  @override
  void didUpdateWidget(covariant _CheckBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A streaming block grows; a changed item list resets the reader's ticks
    // only when an existing item changed, not when one was appended.
    final List<CheckItem> a = oldWidget.spec.items;
    final List<CheckItem> b = widget.spec.items;
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i].label != b[i].label) {
        _override.clear();
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final _AnswerBlockStyle s = widget.s;
    final CheckSpec spec = widget.spec;
    if (spec.items.isEmpty && spec.title.isEmpty) {
      return const SizedBox.shrink();
    }
    return _ModuleCard(
      s: s,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _moduleHead(spec.tag, spec.title, s),
            ),
          for (int i = 0; i < spec.items.length; i++) _row(i, spec.items[i]),
        ],
      ),
    );
  }

  Widget _row(int i, CheckItem item) {
    final _AnswerBlockStyle s = widget.s;
    final bool done = _override[i] ?? item.done;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _override[i] = !done),
        child: Semantics(
          checked: done,
          label: item.label,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // The box is one text line high, so it sits on the first line
                // of a wrapped label (CLAUDE.md: icon box = one line).
                SizedBox(
                  height: s.baseFontSize * 1.4,
                  child: Center(
                    child: _CheckBox(done: done, s: s),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      color: done ? s.muted : s.textColor,
                      fontSize: s.baseFontSize,
                      height: 1.4,
                      fontFamily: s.fontFamily,
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

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.done, required this.s});

  final bool done;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: done ? s.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: done
              ? null
              : Border.all(
                  color: s.textColor.withValues(alpha: 0.55),
                  width: 1.6,
                ),
        ),
        child: done
            ? HugeIcon(HugeIcons.tick02, size: 14, color: s.onAccent)
            : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// term — big word, acronym or etymology

class _TermBlock extends StatelessWidget {
  const _TermBlock({required this.spec, required this.s});

  final TermSpec spec;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    if (spec.entries.isEmpty) return const SizedBox.shrink();
    return _ModuleCard(
      s: s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (spec.tag.isNotEmpty) ...<Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: _TagChip(tag: spec.tag, s: s),
            ),
            const SizedBox(height: 12),
          ],
          for (int i = 0; i < spec.entries.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 10),
            _entry(spec.entries[i], first: i == 0),
          ],
          if (spec.note.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: s.chipFill,
                borderRadius: BorderRadius.circular(14),
              ),
              child: s.markdown(
                spec.note,
                color: s.secondary,
                fontSize: s.baseFontSize * 0.9,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _entry(TermEntry e, {required bool first}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        // The first entry lifts off the card like the Figma "ARD" tile; the
        // ones after it take the tint, so two terms read as a pair.
        color: first ? s.chipFill : s.tileFill,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            e.term,
            style: TextStyle(
              color: s.accent,
              fontSize: s.baseFontSize * 2.3,
              fontWeight: FontWeight.w800,
              height: 1.1,
              fontFamily: s.fontFamily,
            ),
          ),
          if (e.meaning.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            s.markdown(e.meaning, color: s.secondary, height: 1.4),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// grid — cells with marked and filled states

class _GridBlock extends StatelessWidget {
  const _GridBlock({required this.spec, required this.s});

  final GridSpec spec;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    final int cols = spec.columns;
    if (cols == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Tighter gaps for wide grids, so twelve columns still fit a phone.
        final double gap = cols > 7 ? 4 : 8;
        // The module card's padding takes 28 of the width.
        final double cell = ((c.maxWidth - 28 - gap * (cols - 1)) / cols).clamp(
          8.0,
          64.0,
        );
        return _ModuleCard(
          s: s,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _moduleHead(spec.tag, spec.title, s),
                ),
              for (int r = 0; r < spec.rows.length; r++) ...<Widget>[
                if (r > 0) SizedBox(height: gap),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int k = 0; k < spec.rows[r].length; k++) ...<Widget>[
                      if (k > 0) SizedBox(width: gap),
                      _cell(spec.rows[r][k], cell),
                    ],
                  ],
                ),
              ],
              if (spec.legend.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                for (final GridLegend l in spec.legend)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          height: s.baseFontSize * 0.88 * 1.35,
                          child: Center(child: _swatch(l.kind)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.label,
                            style: TextStyle(
                              color: l.kind == GridCellKind.plain
                                  ? s.muted
                                  : s.accent,
                              fontSize: s.baseFontSize * 0.88,
                              height: 1.35,
                              fontFamily: s.fontFamily,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _cell(GridCell cell, double size) {
    final bool marked = cell.kind == GridCellKind.marked;
    final bool filled = cell.kind == GridCellKind.filled;
    final Color fg = (marked || filled) ? s.accent : s.muted;
    final Widget label = Text(
      cell.label,
      maxLines: 1,
      overflow: TextOverflow.clip,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: fg,
        fontSize: (size * 0.36).clamp(10.0, s.baseFontSize * 1.1),
        fontWeight: (marked || filled) ? FontWeight.w800 : FontWeight.w500,
        height: 1.1,
        fontFamily: s.fontFamily,
      ),
    );
    final double radius = size * 0.28;
    final Widget box = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: marked
            ? s.chipFill
            : filled
            ? s.accent.withValues(alpha: s.dark ? 0.28 : 0.2)
            : s.tileFill,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: label),
    );
    if (!marked) return box;
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(color: s.accent, radius: radius),
      child: box,
    );
  }

  Widget _swatch(GridCellKind kind) {
    const double size = 13;
    switch (kind) {
      case GridCellKind.marked:
        return CustomPaint(
          foregroundPainter: _DashedRRectPainter(
            color: s.accent,
            radius: 3.5,
            dash: 2.5,
            gap: 2,
            stroke: 1.2,
          ),
          child: const SizedBox(width: size, height: size),
        );
      case GridCellKind.filled:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: s.accent.withValues(alpha: s.dark ? 0.28 : 0.2),
            borderRadius: BorderRadius.circular(3.5),
          ),
        );
      case GridCellKind.plain:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: s.tileFill,
            borderRadius: BorderRadius.circular(3.5),
          ),
        );
    }
  }
}

/// A dashed rounded-rectangle outline, the "marked" state of a grid cell.
class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({
    required this.color,
    required this.radius,
    this.dash = 4,
    this.gap = 3,
    this.stroke = 1.6,
  });

  final Color color;
  final double radius;
  final double dash;
  final double gap;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Path path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.dash != dash ||
      old.gap != gap ||
      old.stroke != stroke;
}

// ---------------------------------------------------------------------------
// sizes — circles side by side

class _SizesBlock extends StatelessWidget {
  const _SizesBlock({required this.spec, required this.s});

  final SizesSpec spec;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    if (spec.items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final int n = spec.items.length;
        // Card padding 28, panel padding 32, 12 between the columns.
        final double column = (c.maxWidth - 28 - 32 - 12 * (n - 1)) / n;
        final double maxD = column.clamp(40.0, 112.0);
        return _ModuleCard(
          s: s,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _moduleHead(spec.tag, spec.title, s),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                decoration: BoxDecoration(
                  color: s.tileFill,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    for (int i = 0; i < n; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(
                        child: _item(spec.items[i], maxD * spec.fraction(i)),
                      ),
                    ],
                  ],
                ),
              ),
              if (spec.note.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                s.markdown(
                  spec.note,
                  color: s.secondary,
                  fontSize: s.baseFontSize * 0.92,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _item(SizeItem item, double d) {
    final HugeIconData? icon = _blockIcon(item.icon);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SelectionContainer.disabled(
          child: Container(
            width: d,
            height: d,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: s.chipFill,
              shape: BoxShape.circle,
              border: Border.all(
                color: s.textColor.withValues(alpha: 0.22),
                width: 1.4,
              ),
            ),
            child: icon == null
                ? null
                : HugeIcon(
                    icon,
                    size: (d * 0.38).clamp(12.0, 44.0),
                    color: s.accent,
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          item.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: s.textColor,
            fontSize: s.baseFontSize * 0.95,
            fontWeight: FontWeight.w600,
            height: 1.3,
            fontFamily: s.fontFamily,
          ),
        ),
        if (item.valueText.isNotEmpty)
          Text(
            item.valueText,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: s.muted,
              fontSize: s.baseFontSize * 0.85,
              height: 1.3,
              fontFamily: s.fontFamily,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// quote — price, change and a small line chart

class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.spec, required this.s});

  final QuoteSpec spec;
  final _AnswerBlockStyle s;

  Color get _up => s.dark ? const Color(0xFF7DD8A0) : const Color(0xFF1B6E3A);

  @override
  Widget build(BuildContext context) {
    if (spec.symbol.isEmpty && spec.price.isEmpty) {
      return const SizedBox.shrink();
    }
    final int dir = spec.direction;
    final Color changeFg = dir < 0 ? s.bad : (dir > 0 ? _up : s.secondary);
    return _ModuleCard(
      s: s,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: s.chipFill,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        spec.symbol,
                        style: TextStyle(
                          color: s.textColor,
                          fontSize: s.baseFontSize * 0.95,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          fontFamily: s.fontFamily,
                        ),
                      ),
                      if (spec.note.isNotEmpty)
                        Text(
                          spec.note,
                          style: TextStyle(
                            color: s.muted,
                            fontSize: s.baseFontSize * 0.82,
                            height: 1.3,
                            fontFamily: s.fontFamily,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (spec.price.isNotEmpty)
                        Text(
                          spec.price,
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: s.textColor,
                            fontSize: s.baseFontSize * 1.45,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                            fontFamily: s.fontFamily,
                          ),
                        ),
                      if (spec.change.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: changeFg.withValues(
                              alpha: s.dark ? 0.16 : 0.1,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            spec.change,
                            style: TextStyle(
                              color: changeFg,
                              fontSize: s.baseFontSize * 0.8,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              fontFamily: s.fontFamily,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (spec.points.length >= 2) ...<Widget>[
              const SizedBox(height: 12),
              SelectionContainer.disabled(
                child: Container(
                  height: 96,
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                  decoration: BoxDecoration(
                    color: s.cardFill,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: CustomPaint(
                    painter: _SparklinePainter(
                      points: spec.points,
                      line: s.accent,
                      grid: s.hairline,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
              if (spec.labels.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    for (final String l in spec.labels)
                      Flexible(
                        child: Text(
                          l,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: s.muted,
                            fontSize: s.baseFontSize * 0.75,
                            height: 1.2,
                            fontFamily: s.fontFamily,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.line,
    required this.grid,
  });

  final List<double> points;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.width <= 0 || size.height <= 0) return;
    final Paint gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (int i = 0; i < 3; i++) {
      final double y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    double lo = points.first;
    double hi = points.first;
    for (final double p in points) {
      if (p < lo) lo = p;
      if (p > hi) hi = p;
    }
    final double span = hi - lo == 0 ? 1 : hi - lo;
    final Path path = Path();
    for (int i = 0; i < points.length; i++) {
      final double x = size.width * i / (points.length - 1);
      final double y = size.height - (points[i] - lo) / span * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      !listEquals(old.points, points) || old.line != line || old.grid != grid;
}

// ---------------------------------------------------------------------------
// more — collapsed section

class _MoreBlock extends StatefulWidget {
  const _MoreBlock({required this.spec, required this.s});

  final MoreSpec spec;
  final _AnswerBlockStyle s;

  @override
  State<_MoreBlock> createState() => _MoreBlockState();
}

class _MoreBlockState extends State<_MoreBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final _AnswerBlockStyle s = widget.s;
    final MoreSpec spec = widget.spec;
    if (spec.title.isEmpty && spec.body.isEmpty) return const SizedBox.shrink();
    final String title = spec.title.isEmpty ? 'More' : spec.title;
    return Container(
      decoration: BoxDecoration(
        color: s.tileFill,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: spec.body.isEmpty
                  ? null
                  : () => setState(() => _open = !_open),
              child: Semantics(
                button: true,
                expanded: _open,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: <Widget>[
                      SelectionContainer.disabled(
                        child: HugeIcon(
                          HugeIcons.helpCircle,
                          size: 18,
                          color: s.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: s.textColor,
                            fontSize: s.baseFontSize * 0.95,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                            fontFamily: s.fontFamily,
                          ),
                        ),
                      ),
                      if (spec.body.isNotEmpty)
                        SelectionContainer.disabled(
                          child: AnimatedRotation(
                            turns: _open ? 0.5 : 0,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: HugeIcon(
                              HugeIcons.arrowDown01,
                              size: 18,
                              color: s.secondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: s.markdown(spec.body),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
