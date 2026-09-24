// lib/widgets/answer_blocks.dart
//
// Part of markdown_message.dart: the native widgets for the static answer
// blocks (`::: steps`, `::: timeline`, `::: scale`) and the GitHub alerts.
// The parse is in `lib/utils/answer_blocks_parser.dart`; the look follows
// docs/answer_formats/index.html. No glow and no coloured shadow
// (docs/DESIGN.md §8): rules, hairlines and flat fills only.

part of 'markdown_message.dart';

/// Colours and type the blocks share, taken from the surrounding message.
class _AnswerBlockStyle {
  _AnswerBlockStyle({
    required this.textColor,
    required this.backgroundColor,
    required this.accent,
    required this.fontFamily,
    required this.baseFontSize,
  }) : dark =
           ThemeData.estimateBrightnessForColor(backgroundColor) ==
           Brightness.dark;

  final Color textColor;
  final Color backgroundColor;
  final Color accent;
  final String? fontFamily;
  final double baseFontSize;
  final bool dark;

  Color get muted => textColor.withValues(alpha: 0.62);
  Color get secondary => textColor.withValues(alpha: 0.82);
  Color get hairline => textColor.withValues(alpha: 0.16);

  Color get warn => dark ? const Color(0xFFFFC860) : const Color(0xFF8A5A00);
  Color get warnSoft =>
      dark ? const Color(0xFF3A2D0E) : const Color(0xFFFBE7BF);
  Color get bad => dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E);

  Color get termBg => dark ? const Color(0xFF0E0D0C) : const Color(0xFF1C1B19);
  static const Color termText = Color(0xFFE8E4DC);
  Color get termDim => dark ? const Color(0xFF7C766D) : const Color(0xFF8E887E);

  /// Inline Markdown (bold, code, links) inside a block. Blocks do not nest,
  /// so the nested message never sees a `:::` line of its own.
  Widget markdown(
    String text, {
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? height,
  }) {
    return MarkdownMessage(
      text: text,
      textColor: color ?? textColor,
      backgroundColor: backgroundColor,
      wrapWithSelectionArea: false,
      paragraphFontSize: fontSize ?? baseFontSize,
      paragraphFontWeight: fontWeight,
      paragraphHeight: height,
      fontFamily: fontFamily,
    );
  }
}

/// Builds the widget for one block. Throws only on a programming error; the
/// caller falls back to plain text then.
Widget _buildAnswerBlock(AnswerBlockSegment block, _AnswerBlockStyle s) {
  switch (block.kind) {
    case AnswerBlockKind.steps:
      return _StepsBlock(spec: parseSteps(block.arg, block.lines), s: s);
    case AnswerBlockKind.timeline:
      return _TimelineBlock(
        title: block.arg,
        entries: parseTimeline(block.lines),
        s: s,
      );
    case AnswerBlockKind.scale:
      final ScaleSpec? spec = parseScale(block.arg, block.lines);
      if (spec == null) {
        // Not drawable (yet): the lines as text, never an empty hole.
        final String text = block.lines
            .where((l) => l.trim().isNotEmpty)
            .join('\n\n');
        return text.isEmpty ? const SizedBox.shrink() : s.markdown(text);
      }
      return _ScaleBlock(spec: spec, s: s);
    case AnswerBlockKind.alert:
      return _AlertBlock(type: block.arg, lines: block.lines, s: s);
  }
}

/// The frame of a block: a rule on top and an optional small-caps title.
class _BlockFrame extends StatelessWidget {
  const _BlockFrame({
    required this.title,
    required this.s,
    required this.child,
  });

  final String title;
  final _AnswerBlockStyle s;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 9),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: s.textColor.withValues(alpha: 0.85), width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: s.muted,
                  fontSize: s.baseFontSize * 0.75,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  height: 1.2,
                  fontFamily: s.fontFamily,
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// steps

class _StepsBlock extends StatelessWidget {
  const _StepsBlock({required this.spec, required this.s});

  final StepsSpec spec;
  final _AnswerBlockStyle s;

  static const double _circle = 26;
  static const double _gutter = 12;

  @override
  Widget build(BuildContext context) {
    final List<StepItem> steps = spec.steps;
    return _BlockFrame(
      title: spec.title,
      s: s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < steps.length; i++)
            _step(steps[i], last: i == steps.length - 1),
        ],
      ),
    );
  }

  Widget _step(StepItem step, {required bool last}) {
    final Widget circle = Container(
      width: _circle,
      height: _circle,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: s.accent, width: 2),
      ),
      child: SelectionContainer.disabled(
        child: Text(
          step.label,
          maxLines: 1,
          style: TextStyle(
            color: s.accent,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            height: 1,
            fontFamily: s.fontFamily,
          ),
        ),
      ),
    );

    return Stack(
      children: <Widget>[
        if (!last)
          Positioned(
            left: _circle / 2 - 1,
            top: _circle + 4,
            bottom: 2,
            child: Container(width: 2, color: s.hairline),
          ),
        Padding(
          padding: EdgeInsets.only(bottom: last ? 2 : 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              circle,
              const SizedBox(width: _gutter),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (step.title.isNotEmpty)
                      s.markdown(
                        step.title,
                        fontSize: s.baseFontSize * 1.07,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    for (final StepPart part in step.parts) _part(part),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _part(StepPart part) {
    switch (part.kind) {
      case StepPartKind.text:
        return s.markdown(
          part.text,
          color: s.secondary,
          fontSize: s.baseFontSize * 0.96,
        );
      case StepPartKind.command:
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: _TerminalLines(commands: part.text.split('\n'), s: s),
        );
      case StepPartKind.warning:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _WarningLine(text: part.text, s: s),
        );
    }
  }
}

/// Command lines on a dark terminal card, with the code block's copy button.
/// The `$ ` prompt is not selectable, so a selection copies the commands only.
class _TerminalLines extends StatelessWidget {
  const _TerminalLines({required this.commands, required this.s});

  final List<String> commands;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    const TextStyle mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.5,
      color: _AnswerBlockStyle.termText,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
      decoration: BoxDecoration(
        color: s.termBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final String cmd in commands)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SelectionContainer.disabled(
                        child: Text(
                          r'$ ',
                          style: mono.copyWith(color: s.termDim),
                        ),
                      ),
                      Expanded(child: Text(cmd, style: mono)),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _CopyButton(
            code: commands.join('\n'),
            textColor: _AnswerBlockStyle.termText,
          ),
        ],
      ),
    );
  }
}

class _WarningLine extends StatelessWidget {
  const _WarningLine({required this.text, required this.s});

  final String text;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    final double size = s.baseFontSize * 0.93;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          // Centre the badge on the first line: the nested message carries 4
          // of padding above its text.
          padding: EdgeInsets.only(top: 4 + (size * 1.45 - 16) / 2),
          child: SelectionContainer.disabled(
            child: Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.warnSoft,
                shape: BoxShape.circle,
              ),
              child: Text(
                '!',
                style: TextStyle(
                  color: s.warn,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: s.markdown(text, color: s.warn, fontSize: size),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// timeline

class _TimelineBlock extends StatelessWidget {
  const _TimelineBlock({
    required this.title,
    required this.entries,
    required this.s,
  });

  final String title;
  final List<TimelineEntry> entries;
  final _AnswerBlockStyle s;

  static const double _rail = 22;
  static const double _dot = 9;

  @override
  Widget build(BuildContext context) {
    final double labelWidth = MediaQuery.textScalerOf(context).scale(74);
    final double lineHeight = s.baseFontSize * 1.45;
    // The nested message puts 4 of padding above the first line.
    final double dotTop = 4 + (lineHeight - _dot) / 2;
    return _BlockFrame(
      title: title,
      s: s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < entries.length; i++)
            _entry(
              entries[i],
              last: i == entries.length - 1,
              labelWidth: labelWidth,
              dotTop: dotTop,
              lineHeight: lineHeight,
            ),
        ],
      ),
    );
  }

  Widget _entry(
    TimelineEntry e, {
    required bool last,
    required double labelWidth,
    required double dotTop,
    required double lineHeight,
  }) {
    final double railCentre = labelWidth + _rail / 2;
    return Stack(
      children: <Widget>[
        if (!last)
          Positioned(
            left: railCentre - 0.75,
            top: dotTop + _dot,
            bottom: 0,
            child: Container(width: 1.5, color: s.hairline),
          ),
        Positioned(
          left: railCentre - _dot / 2,
          top: dotTop,
          child: Container(
            width: _dot,
            height: _dot,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: e.highlight ? s.accent : s.backgroundColor,
              border: Border.all(
                color: e.highlight ? s.accent : s.muted,
                width: 2,
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: last ? 2 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: labelWidth,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: 4 + (lineHeight - 12 * 1.6) / 2,
                  ),
                  child: Text(
                    e.label,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.6,
                      color: e.highlight ? s.accent : s.muted,
                      fontWeight: e.highlight
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: _rail),
              Expanded(
                child: s.markdown(
                  e.text,
                  fontWeight: e.highlight ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// scale (experimental)

/// A labelled band with ticks and a marker. Experimental: the prompt offers
/// it only for one value on a known range (colour temperature, pH, a grade).
class _ScaleBlock extends StatelessWidget {
  const _ScaleBlock({required this.spec, required this.s});

  final ScaleSpec spec;
  final _AnswerBlockStyle s;

  static const double _stripHeight = 14;
  static const double _shortLine = 6;

  LinearGradient _gradient() {
    if (spec.isKelvin) {
      const List<Color> colors = <Color>[
        Color(0xFFFF8A1F),
        Color(0xFFFFB86B),
        Color(0xFFFFE4C2),
        Color(0xFFFFF6EC),
        Color(0xFFE9F0FF),
      ];
      final List<double> stops = <double>[
        for (final double k in <double>[1800, 2700, 3500, 4500, 6500])
          spec.fraction(k),
      ];
      return LinearGradient(colors: colors, stops: stops);
    }
    return LinearGradient(
      colors: <Color>[s.textColor.withValues(alpha: 0.08), s.accent],
    );
  }

  String _withUnit(String raw) => spec.unit.isEmpty ? raw : '$raw ${spec.unit}';

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double pillHeight = scaler.scale(11) * 1.2 + 10;
    final double markerArea = spec.markers.isEmpty ? 6 : pillHeight + 20;
    final double tickText = scaler.scale(11.5) * 1.25 + scaler.scale(11) * 1.3;
    final bool twoRows = spec.ticks.length > 1;
    // Every other tick hangs its label one text block lower, so neighbours
    // that sit close on the band do not print over each other.
    final double lowLine = _shortLine + tickText + 4;
    final double tickArea = spec.ticks.isEmpty
        ? 0
        : 4 + (twoRows ? lowLine : _shortLine) + 3 + tickText + 2;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        return Container(
          padding: const EdgeInsets.only(top: 9),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: s.textColor.withValues(alpha: 0.85),
                width: 2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: markerArea,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    for (final ScalePoint m in spec.markers)
                      ..._marker(m, w, pillHeight, markerArea),
                  ],
                ),
              ),
              Container(
                height: _stripHeight,
                decoration: BoxDecoration(
                  gradient: _gradient(),
                  borderRadius: BorderRadius.circular(_stripHeight / 2),
                  border: Border.all(color: s.hairline),
                ),
              ),
              if (spec.ticks.isNotEmpty)
                SizedBox(
                  height: tickArea,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      for (int k = 0; k < spec.ticks.length; k++)
                        ..._tick(
                          spec.ticks[k],
                          w,
                          lineHeight: twoRows && k.isOdd ? lowLine : _shortLine,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _marker(ScalePoint m, double w, double pill, double area) {
    final double f = spec.fraction(m.value);
    final double x = f * w;
    final String label = m.label.isEmpty ? _withUnit(m.raw) : m.label;
    return <Widget>[
      // The pill slides with the value so it never leaves the band: at 0 it
      // starts at the left edge, at 1 it ends at the right one.
      Positioned(
        left: x,
        top: 0,
        child: FractionalTranslation(
          translation: Offset(-f, 0),
          child: Container(
            height: pill,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: s.textColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: s.backgroundColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                height: 1.2,
                fontFamily: s.fontFamily,
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: x - 1,
        top: pill,
        bottom: -1,
        child: Container(width: 2, color: s.textColor),
      ),
    ];
  }

  List<Widget> _tick(ScalePoint p, double w, {required double lineHeight}) {
    final double f = spec.fraction(p.value);
    final double x = f * w;
    final TextAlign align = f < 0.08
        ? TextAlign.left
        : (f > 0.92 ? TextAlign.right : TextAlign.center);
    return <Widget>[
      Positioned(
        left: x - 0.5,
        top: 4,
        child: Container(width: 1, height: lineHeight, color: s.muted),
      ),
      Positioned(
        left: x,
        top: 4 + lineHeight + 3,
        child: FractionalTranslation(
          translation: Offset(-f, 0),
          child: Column(
            crossAxisAlignment: align == TextAlign.left
                ? CrossAxisAlignment.start
                : (align == TextAlign.right
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.center),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (p.label.isNotEmpty)
                Text(
                  p.label,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: align,
                  style: TextStyle(
                    color: s.secondary,
                    fontSize: 11.5,
                    height: 1.2,
                    fontFamily: s.fontFamily,
                  ),
                ),
              Text(
                _withUnit(p.raw),
                maxLines: 1,
                softWrap: false,
                textAlign: align,
                style: TextStyle(
                  color: s.muted,
                  fontSize: 11,
                  height: 1.3,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// GitHub alerts: `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`,
// `> [!CAUTION]`.

class _AlertBlock extends StatelessWidget {
  const _AlertBlock({required this.type, required this.lines, required this.s});

  final String type;
  final List<String> lines;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    final Color color = switch (type) {
      'WARNING' => s.warn,
      'CAUTION' => s.bad,
      _ => s.accent,
    };
    final String body = lines.join('\n').trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            type,
            style: TextStyle(
              color: color,
              fontSize: s.baseFontSize * 0.75,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              height: 1.2,
              fontFamily: s.fontFamily,
            ),
          ),
          if (body.isNotEmpty) s.markdown(body, color: s.secondary),
        ],
      ),
    );
  }
}
