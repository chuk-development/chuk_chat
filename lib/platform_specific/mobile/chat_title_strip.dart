/// The full-width bar under the mode switch that names the chat in view.
///
/// It is the swipe surface of the phone (owner, 2026-11-05): a sideways
/// drag on the bar drives the [SwipeChatPager] below through its
/// [SwipeChatPagerController], and chat and title move together.
///
/// Shape (redesign 2026-11-10, owner: "no big gap on the left, no big
/// animations, quick to work with"): one search-bar-sized pill, content
/// left-aligned like the M3 Expressive app bar title.
///
/// ```
/// ( face )  Title of the chat                 • ━ • •
///           last line or status
/// ```
///
/// The neighbours do not peek in any more: a centred carousel pushed the
/// title to the middle and left a wide empty band on the left. The position
/// dots on the right say "there is more this way" instead. During a swipe
/// the title slides a little with the finger and fades; the next one fades
/// in from the other side. A tap opens the list of chats ([onTap]).
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

/// Size of the leading face or icon slot.
const double _kLeadingSize = 36;

/// How far the title travels with a full page of swipe progress.
const double _kTitleTravel = 56;

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
    this.margin = const EdgeInsets.symmetric(horizontal: 13),
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

  /// Room around the bar. The default lines its edges up with the round
  /// chips of the row above (10 px row padding + 3 px chip slop).
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

    final Widget line = _EntryLine(
      entry: entry,
      fallbackTitle: emptyTitle,
      workingLabel: workingLabel,
    );

    Widget moving(double p) {
      final double t = p.clamp(-1.0, 1.0);
      // Gone by a third of a page: the swipe is short and so is the fade.
      final double opacity = (1 - t.abs() * 3).clamp(0.0, 1.0);
      return Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(t * _kTitleTravel, 0),
          child: line,
        ),
      );
    }

    final Widget content = Row(
      children: <Widget>[
        Expanded(
          child: ClipRect(
            child: motion == null
                ? line
                : ValueListenableBuilder<double>(
                    valueListenable: motion,
                    builder: (BuildContext context, double p, Widget? _) =>
                        moving(p),
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
                          // During the "in" half the index has changed
                          // already; the dots then simply rest on it.
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

    Widget bar = Container(
      height: kChatTitleStripHeight,
      padding: EdgeInsetsDirectional.only(
        start: entry?.leading != null ? 10 : 20,
        end: 18,
      ),
      decoration: ShapeDecoration(
        color: FloatingChromeSurface.fillOf(context),
        shape: const StadiumBorder(),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
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
      bar = GestureDetector(onTap: onTap, child: bar);
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
    final TextTheme text = Theme.of(context).textTheme;
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
            // Title medium, emphasized: the one key element of the bar.
            style: (text.titleMedium ?? const TextStyle()).copyWith(
              fontSize: 16,
              height: 1.25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
              color: scheme.onSurface,
            ),
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
            child: Center(child: e!.leading),
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
                    style: text.bodySmall?.copyWith(
                      fontSize: 12.5,
                      height: 1.25,
                      color: scheme.onSurfaceVariant,
                    ),
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
