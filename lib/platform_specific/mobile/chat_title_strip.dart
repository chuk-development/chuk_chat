/// The pill in the phone's top bar that names the chat in view.
///
/// It is the swipe surface of the phone (owner, 2026-11-05): a sideways
/// drag on the bar drives the [SwipeChatPager] below through its
/// [SwipeChatPagerController], and chat and title move together.
///
/// Shape (redesign 2026-11-13, owner: "too long, bigger face"): one pill
/// at the left edge that is only as wide as its content, with a large face
/// that fills the round start of the pill.
///
/// ```
/// (( face ) Title of the chat   • ━ • • )
///           last line or status
/// ```
///
/// The title sets the width. A long last line does not: it gets at most
/// [_kSubtitleShare] of the row and is cut with an ellipsis.
///
/// At rest the neighbours are not drawn: a centred carousel pushed the
/// title to the middle and left a wide empty band on the left. The position
/// dots on the right say "there is more this way" instead. During a swipe
/// the titles are a carousel that follows the finger 1:1 (owner, CHAT-18):
/// the title in view slides out under the finger and the neighbour slides in
/// right behind it, with no fade. The strip tells the pager how wide its
/// page is ([SwipeChatPagerController.pageExtent]), so a swipe on the chat
/// below moves the titles exactly as far as the finger. A tap opens the list
/// of chats ([onTap]).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

/// Height of the strip, without its outer margin. The M3 search bar height.
const double kChatTitleStripHeight = 56;

/// Corner radius of the strip: a full pill.
const double kChatTitleStripRadius = kChatTitleStripHeight / 2;

/// Size of the leading face or icon slot. The face is drawn to fill it,
/// whatever size its builder gave it.
const double _kLeadingSize = 44;

/// Room between the pill's edge and the face: the face sits concentric in
/// the round start of the pill.
const double _kLeadingInset = (kChatTitleStripHeight - _kLeadingSize) / 2;

/// The most of the row a pill takes when only its last line is long.
const double _kSubtitleShare = 0.72;

/// How long the pill takes to grow or shrink to the next entry's width.
const Duration _kResize = Duration(milliseconds: 180);

/// The gap between two titles of the carousel, in logical pixels.
const double _kTitleGap = 24;

/// The most dots the position row shows at once.
const int _kMaxDots = 5;

/// The bar that names the entry in view.
class ChatTitleStrip extends StatelessWidget {
  const ChatTitleStrip({
    super.key,
    required this.entries,
    required this.selectedId,
    this.controller,
    this.progress,
    this.onTap,
    this.margin = EdgeInsets.zero,
    this.semanticsHint = 'Swipe to switch chats',
    this.workingLabel = 'working',
    this.emptyTitle = '',
    this.showPosition = true,
  });

  final List<SwipeChatEntry> entries;
  final String? selectedId;

  /// The pager below. A sideways drag on the strip moves it, and its
  /// [SwipeChatPagerController.progress] moves the title. Null makes the
  /// strip a still label.
  final SwipeChatPagerController? controller;

  /// Overrides the controller's progress value (tests).
  final ValueListenable<double>? progress;

  /// A tap on the strip: the list of chats.
  final VoidCallback? onTap;

  /// Room around the bar. None by default: the top bar's row places it.
  final EdgeInsetsGeometry margin;
  final String semanticsHint;

  /// The word next to the working dots of an entry with a run in flight.
  final String workingLabel;

  /// Shown when [selectedId] names no entry.
  final String emptyTitle;

  /// Draws the row of position dots.
  final bool showPosition;

  @override
  Widget build(BuildContext context) {
    final int index = swipeChatIndexOf(entries, selectedId);
    final SwipeChatEntry? entry = index >= 0 ? entries[index] : null;
    final String title = entry?.title ?? emptyTitle;
    final SwipeChatPagerController? pager = controller;
    final ValueListenable<double>? motion = progress ?? pager?.progress;
    final bool dots = showPosition && index >= 0 && entries.length > 1;

    // One title of the carousel, keyed by its entry: when a switch moves an
    // entry from the neighbour's slot to the middle, its widgets (the
    // working dots) keep their State.
    Widget lineFor(SwipeChatEntry? e) => KeyedSubtree(
      key: ValueKey<String>('chat_title_strip_line_${e?.id ?? ''}'),
      child: Padding(
        // The start padding belongs to the title, not to the bar: a face
        // needs less of it than a bare title, and each title brings its own
        // as it slides in.
        padding: EdgeInsetsDirectional.only(
          start: e?.leading != null ? _kLeadingInset : 20,
        ),
        child: _EntryLine(
          entry: e,
          fallbackTitle: emptyTitle,
          workingLabel: workingLabel,
        ),
      ),
    );

    // The titles at progress [p]: the one in view at p pages, the neighbour
    // on the side the finger pulls from one page beyond it. A page is the
    // title area plus a small gap.
    Widget carousel(double p, double pitch) {
      final double t = p.clamp(-1.0, 1.0);
      Widget at(SwipeChatEntry? e, double pages) => Positioned.fill(
        child: Transform.translate(
          offset: Offset(pages * pitch, 0),
          child: lineFor(e),
        ),
      );
      return Stack(
        children: <Widget>[
          if (t > 0 && index > 0) at(entries[index - 1], t - 1),
          at(entry, t),
          if (t < 0 && index >= 0 && index < entries.length - 1)
            at(entries[index + 1], t + 1),
        ],
      );
    }

    final Widget content = Row(
      children: <Widget>[
        Expanded(
          child: ClipRect(
            child: motion == null
                ? lineFor(entry)
                : LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints box) {
                      final double pitch = box.maxWidth + _kTitleGap;
                      // The pager divides the finger's travel by this, so
                      // the titles move exactly as far as the finger.
                      pager?.pageExtent = pitch;
                      return ValueListenableBuilder<double>(
                        valueListenable: motion,
                        builder: (BuildContext context, double p, Widget? _) =>
                            carousel(p, pitch),
                      );
                    },
                  ),
          ),
        ),
        if (dots) ...<Widget>[
          const SizedBox(width: 12),
          SizedBox(
            width: _PositionDots.widthFor(entries.length),
            height: 8,
            child: motion == null
                ? _PositionDots(
                    key: const ValueKey<String>('chat_title_strip_position'),
                    count: entries.length,
                    position: index.toDouble(),
                  )
                : ValueListenableBuilder<double>(
                    valueListenable: motion,
                    builder: (BuildContext context, double p, Widget? _) =>
                        _PositionDots(
                          key: const ValueKey<String>(
                            'chat_title_strip_position',
                          ),
                          count: entries.length,
                          // The progress is relative to the selected
                          // entry, so this runs on without a jump when a
                          // switch commits.
                          position: (index - p.clamp(-1.0, 1.0)).clamp(
                            0.0,
                            (entries.length - 1).toDouble(),
                          ),
                        ),
                  ),
          ),
        ],
      ],
    );

    final Color fill = FloatingChromeSurface.fillOf(context);
    final double natural = _naturalWidth(
      context,
      entry,
      dots ? entries.length : 0,
    );
    Widget bar = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => Align(
        alignment: AlignmentDirectional.centerStart,
        heightFactor: 1,
        child: AnimatedContainer(
          duration: _kResize,
          curve: Curves.easeOutCubic,
          width: _fitWidth(natural, box.maxWidth),
          height: kChatTitleStripHeight,
          padding: const EdgeInsetsDirectional.only(end: _kEndPadding),
          decoration: ShapeDecoration(
            color: fill,
            shape: const StadiumBorder(),
          ),
          clipBehavior: Clip.antiAlias,
          child: content,
        ),
      ),
    );

    final bool hasNext = index >= 0 && index < entries.length - 1;
    final bool hasPrev = index > 0;

    if (pager != null) {
      bar = GestureDetector(
        key: const ValueKey<String>('chat_title_strip_swipe'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => pager.dragStart(),
        onHorizontalDragUpdate: (DragUpdateDetails d) =>
            pager.dragUpdate(d.delta.dx),
        onHorizontalDragEnd: (DragEndDetails d) =>
            pager.dragEnd(d.primaryVelocity ?? 0),
        onHorizontalDragCancel: pager.dragCancel,
        onTap: onTap,
        child: bar,
      );
    } else if (onTap != null) {
      bar = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: bar,
      );
    }

    return Padding(
      padding: margin,
      child: Semantics(
        container: true,
        label: title,
        hint: semanticsHint,
        value: dots ? '${index + 1}/${entries.length}' : null,
        increasedValue: dots && hasNext
            ? '${index + 2}/${entries.length}'
            : null,
        decreasedValue: dots && hasPrev ? '$index/${entries.length}' : null,
        onTap: onTap,
        // A screen reader swipes up and down to step through the chats.
        onIncrease: pager != null && hasNext ? pager.next : null,
        onDecrease: pager != null && hasPrev ? pager.previous : null,
        excludeSemantics: true,
        child: bar,
      ),
    );
  }
}

const double _kEndPadding = 18;

/// The width the pill takes in a row of [available] pixels.
double _fitWidth(double natural, double available) {
  if (!available.isFinite) return natural;
  return math.min(natural, available);
}

TextStyle _titleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  // Title medium, emphasized: the one key element of the bar.
  return (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    color: theme.colorScheme.onSurface,
  );
}

TextStyle _subtitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
    fontSize: 12.5,
    height: 1.25,
    color: theme.colorScheme.onSurfaceVariant,
  );
}

double _textWidth(BuildContext context, String text, TextStyle style) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

/// The width the pill wants for [entry]: its face, its title, and as much
/// of the last line as [_kSubtitleShare] of the screen allows.
double _naturalWidth(
  BuildContext context,
  SwipeChatEntry? entry,
  int dotCount,
) {
  final double start = entry?.leading != null
      ? _kLeadingInset + _kLeadingSize + 12
      : 20;
  final double end =
      _kEndPadding + (dotCount > 0 ? 12 + _PositionDots.widthFor(dotCount) : 0);
  double title = _textWidth(context, entry?.title ?? '', _titleStyle(context));
  if (entry != null && entry.unread) title += 13;
  double second = 0;
  if (entry != null && entry.working) {
    // Three dots, a gap and the word.
    second = 28 + _textWidth(context, 'working', _subtitleStyle(context));
  } else if (entry?.subtitle case final String subtitle
      when subtitle.isNotEmpty) {
    second = _textWidth(context, subtitle, _subtitleStyle(context));
  }
  // One pixel of slack: a width measured here and laid out again must not
  // cut the last glyph.
  final double titleWidth = start + title + end + 1;
  final double capped = MediaQuery.sizeOf(context).width * _kSubtitleShare;
  final double secondWidth = math.min(start + second + end + 1, capped);
  return math.max(titleWidth, secondWidth);
}

/// Face · title over subtitle (or the working dots), left-aligned.
class _EntryLine extends StatelessWidget {
  const _EntryLine({
    required this.entry,
    required this.fallbackTitle,
    required this.workingLabel,
  });

  final SwipeChatEntry? entry;
  final String fallbackTitle;
  final String workingLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SwipeChatEntry? e = entry;
    final String? subtitle = e?.subtitle;
    final bool hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    final bool working = e != null && e.working;

    final Widget title = Row(
      children: <Widget>[
        Flexible(
          child: Text(
            e?.title ?? fallbackTitle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle(context),
          ),
        ),
        if (e != null && e.unread) ...<Widget>[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );

    return Row(
      children: <Widget>[
        if (e?.leading != null) ...<Widget>[
          SizedBox.square(
            dimension: _kLeadingSize,
            // The builders hand in faces of their own size; the strip
            // draws each one as large as its slot.
            child: FittedBox(child: e!.leading),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              title,
              if (working)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: WorkingDots(
                    color: scheme.primary,
                    label: workingLabel,
                  ),
                )
              else if (hasSubtitle)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _subtitleStyle(context),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The position row: a window of dots around the current one. The current
/// dot is a short pill in the accent colour; the dots at a window end that
/// has more beyond it get smaller.
class _PositionDots extends StatelessWidget {
  const _PositionDots({super.key, required this.count, required this.position});

  /// The width the row needs for [count] entries.
  static double widthFor(int count) {
    final int shown = math.min(count, _kMaxDots);
    return (shown - 1) * (_DotsPainter._dot + _DotsPainter._gap) +
        _DotsPainter._pill;
  }

  final int count;

  /// The fractional index in view (it moves during a swipe).
  final double position;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _DotsPainter(
        count: count,
        position: position,
        active: scheme.primary,
        idle: scheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter({
    required this.count,
    required this.position,
    required this.active,
    required this.idle,
  });

  final int count;
  final double position;
  final Color active;
  final Color idle;

  static const double _dot = 4;
  static const double _gap = 6;
  static const double _pill = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final int shown = math.min(count, _kMaxDots);
    // The window follows the position, held so the current dot is in its
    // middle where it can be.
    final double maxStart = (count - shown).toDouble();
    final double start = (position - (shown - 1) / 2).clamp(0.0, maxStart);
    final int first = start.floor();
    final double shift = start - first;
    final double pitch = _dot + _gap;
    final double totalWidth = (shown - 1) * pitch + _pill;
    // Right-aligned: the row ends where the strip's content ends.
    final double x0 = size.width - totalWidth + _pill / 2;
    final double cy = size.height / 2;
    final Paint paint = Paint()..isAntiAlias = true;

    for (int k = 0; k <= shown; k++) {
      final int i = first + k;
      if (i >= count) break;
      final double slotPos = k - shift; // 0 .. shown-1 inside the window
      if (slotPos < -0.5 || slotPos > shown - 0.5) continue;
      // Shrink towards a window end that has more dots beyond it.
      double edge = 1;
      final double fromLeft = slotPos;
      final double fromRight = (shown - 1) - slotPos;
      if (start > 0.01 && fromLeft < 1.5) {
        edge = math.min(edge, 0.5 + fromLeft.clamp(0.0, 1.5) / 3);
      }
      if (start < maxStart - 0.01 && fromRight < 1.5) {
        edge = math.min(edge, 0.5 + fromRight.clamp(0.0, 1.5) / 3);
      }
      // How much this dot is the current one: 1 at the position, 0 a dot away.
      final double near = (1 - (i - position).abs()).clamp(0.0, 1.0);
      final double s = edge + (1 - edge) * near;
      final double h = _dot * s;
      final double w = h + (_pill - _dot) * near;
      final double cx = x0 + slotPos * pitch;
      paint.color = Color.lerp(idle, active, near)!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
          Radius.circular(h / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) =>
      old.count != count ||
      old.position != position ||
      old.active != active ||
      old.idle != idle;
}
