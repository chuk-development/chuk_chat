/// The full-width bar under the mode switch that names the chat in view.
///
/// It is the swipe surface of the phone (owner, 2026-11-05): no chevron, no
/// dropdown, no list, and no peek at the neighbours. A sideways drag on the
/// bar drives the [SwipeChatPager] below through its
/// [SwipeChatPagerController]. The chat itself stays still; only the name
/// here moves: it follows the finger out and fades, and the new name slides
/// in from the other side. A row of dots at the foot of the bar shows where
/// in the list the chat is, Instagram style: a window of at most [_kMaxDots]
/// dots that shrink towards its ends when the list goes on.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

/// Height of the strip, without its outer margin.
const double kChatTitleStripHeight = 58;

/// Corner radius of the strip: a full pill.
const double kChatTitleStripRadius = kChatTitleStripHeight / 2;

/// Size of the leading face or icon slot.
const double _kLeadingSize = 30;

/// Distance between two titles on the track, as a fraction of the width.
const double _kSlotFraction = 0.6;

/// The widest a title may be, as a fraction of the width.
const double _kItemFraction = 0.66;

/// How small a peeking title gets.
const double _kPeekScale = 0.88;

/// The most dots the position row shows at once.
const int _kMaxDots = 7;

/// The bar that names the entry in view.
class ChatTitleStrip extends StatelessWidget {
  const ChatTitleStrip({
    super.key,
    required this.entries,
    required this.selectedId,
    this.controller,
    this.progress,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.semanticsHint = 'Swipe to switch chats',
    this.workingLabel = 'working',
    this.emptyTitle = '',
    this.showPosition = true,
  });

  final List<SwipeChatEntry> entries;
  final String? selectedId;

  /// The pager below. A sideways drag on the strip moves it, a tap on a
  /// peeking title steps it, and its [SwipeChatPagerController.carousel]
  /// moves the titles. Null makes the strip a still label.
  final SwipeChatPagerController? controller;

  /// Overrides the controller's carousel value (tests).
  final ValueListenable<double>? progress;

  /// A tap on the title in the middle.
  final VoidCallback? onTap;

  /// Room around the bar. The default leaves 16 px on each side.
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
    final String title = index >= 0 ? entries[index].title : emptyTitle;
    final SwipeChatPagerController? pager = controller;
    final ValueListenable<double>? motion = progress ?? pager?.progress;
    final bool dots = showPosition && index >= 0 && entries.length > 1;

    Widget track(double p) => _Track(
      entries: entries,
      index: index,
      progress: p,
      workingLabel: workingLabel,
      emptyTitle: emptyTitle,
      dots: dots,
    );

    final Widget content = motion == null
        ? track(0)
        : ValueListenableBuilder<double>(
            valueListenable: motion,
            builder: (BuildContext context, double p, Widget? _) => track(p),
          );

    final bool hasNext = index >= 0 && index < entries.length - 1;
    final bool hasPrev = index > 0;

    Widget bar = Container(
      height: kChatTitleStripHeight,
      decoration: ShapeDecoration(
        color: FloatingChromeSurface.fillOf(context),
        shape: const StadiumBorder(),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    if (pager != null) {
      final Widget plain = bar;
      // The bar's own width (inside the margin), so it matches the tap's
      // `localPosition`.
      bar = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            GestureDetector(
              key: const ValueKey<String>('chat_title_strip_swipe'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => pager.dragStart(),
              onHorizontalDragUpdate: (DragUpdateDetails d) =>
                  pager.dragUpdate(d.delta.dx),
              onHorizontalDragEnd: (DragEndDetails d) =>
                  pager.dragEnd(d.primaryVelocity ?? 0),
              onHorizontalDragCancel: pager.dragCancel,
              onTap: onTap,
              child: plain,
            ),
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

/// The titles on their track, and the dots under them.
class _Track extends StatelessWidget {
  const _Track({
    required this.entries,
    required this.index,
    required this.progress,
    required this.workingLabel,
    required this.emptyTitle,
    required this.dots,
  });

  final List<SwipeChatEntry> entries;
  final int index;

  /// [SwipeChatPagerController.carousel]: < 0 moves towards index + 1.
  final double progress;
  final String workingLabel;
  final String emptyTitle;
  final bool dots;

  @override
  Widget build(BuildContext context) {
    final double p = progress.clamp(-1.0, 1.0);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double slot = w * _kSlotFraction;
        final double itemWidth = w * _kItemFraction;
        final List<Widget> items = <Widget>[];
        if (index < 0) {
          items.add(
            _place(
              key: const ValueKey<String>('chat_title_strip_current'),
              entry: null,
              position: 0,
              slot: slot,
              width: w,
              itemWidth: itemWidth,
            ),
          );
        } else {
          // Only the chat in view: its name rides the finger out, and the
          // next name comes in from the other side once the switch is made
          // (the pager's progress runs to ±1, then from ∓1 back to 0). No
          // neighbour is shown (owner, 2026-11-05).
          items.add(
            _place(
              key: const ValueKey<String>('chat_title_strip_current'),
              entry: entries[index],
              position: p,
              slot: slot,
              width: w,
              itemWidth: itemWidth,
            ),
          );
        }
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fill(
              bottom: dots ? 8 : 0,
              child: ShaderMask(
                // Fades the peeking titles into the bar's ends.
                shaderCallback: (Rect r) => const LinearGradient(
                  colors: <Color>[
                    Color(0x00000000),
                    Color(0xFF000000),
                    Color(0xFF000000),
                    Color(0x00000000),
                  ],
                  stops: <double>[0, 0.14, 0.86, 1],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: Stack(children: items),
              ),
            ),
            if (dots)
              Positioned(
                left: 0,
                right: 0,
                bottom: 7,
                height: 5,
                child: _PositionDots(
                  key: const ValueKey<String>('chat_title_strip_position'),
                  count: entries.length,
                  position: index.toDouble(),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _place({
    required Key key,
    required SwipeChatEntry? entry,
    required double position,
    required double slot,
    required double width,
    required double itemWidth,
  }) {
    final double t = position.abs().clamp(0.0, 1.0);
    final double scale = 1 - (1 - _kPeekScale) * t;
    final double opacity = 1 - t;
    final double left = (width - itemWidth) / 2 + position * slot;
    return Positioned(
      key: key,
      left: left,
      top: 0,
      bottom: 0,
      width: itemWidth,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: _EntryLine(
              entry: entry,
              fallbackTitle: emptyTitle,
              workingLabel: workingLabel,
              detail: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// Face · title over subtitle (or the working dots), centred.
class _EntryLine extends StatelessWidget {
  const _EntryLine({
    required this.entry,
    required this.fallbackTitle,
    required this.workingLabel,
    required this.detail,
  });

  final SwipeChatEntry? entry;
  final String fallbackTitle;
  final String workingLabel;

  /// 1 in the middle, 0 at a peek: the second line fades out as the title
  /// moves aside, so a peek is one quiet line.
  final double detail;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final SwipeChatEntry? e = entry;
    final String? subtitle = e?.subtitle;
    final bool hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    final bool working = e != null && e.working;
    final bool secondLine = (working || hasSubtitle) && detail > 0.02;

    final Widget title = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            e?.title ?? fallbackTitle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: (text.titleSmall ?? const TextStyle()).copyWith(
              fontSize: 15.5,
              height: 1.2,
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

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (e?.leading != null) ...<Widget>[
            SizedBox.square(
              dimension: _kLeadingSize,
              child: Center(child: e!.leading),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                title,
                if (secondLine)
                  ClipRect(
                    child: Align(
                      alignment: Alignment.topLeft,
                      heightFactor: detail,
                      child: Opacity(
                        opacity: detail,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: working
                              ? WorkingDots(
                                  color: scheme.primary,
                                  label: workingLabel,
                                )
                              : Text(
                                  subtitle!,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                    fontSize: 12,
                                    height: 1.25,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The position row: a window of dots around the current one. The current
/// dot is a short pill in the accent colour; the dots at a window end that
/// has more beyond it get smaller.
class _PositionDots extends StatelessWidget {
  const _PositionDots({super.key, required this.count, required this.position});

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
    final double x0 = (size.width - totalWidth) / 2 + _pill / 2;
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
