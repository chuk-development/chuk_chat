// lib/widgets/chat_turn_rail.dart
//
// The message minimap on the left of a desktop chat, built after T3 Code's
// TimelineMinimap (pingdotgg/t3code, apps/web/src/components/chat/
// MessagesTimeline.tsx + MessagesTimeline.logic.ts). Same numbers, same
// behaviour:
//
// - One strip per message the user wrote, evenly spaced (8 px), at most the
//   window height minus 288 px. The strips stand on the axis of the left
//   icon column (the folded sidebar's icons, 31 px from the edge), and the
//   rail is centred in the free part of that column: below the header and
//   the column's icons, above the settings gear. It never reaches the
//   composer.
// - The strips of rows on screen are bright and follow the scroll.
// - Hover: the strip under the pointer grows to 24 px, its neighbours to 16
//   and 10 px; a card shows the message (one line) and the end of the answer
//   (three lines). A click jumps to the message (24 px below the top).
// - Keys: focus, then Up/Down/Home/End to move, Enter or Space to jump.
// - Drawn from two messages on. With a side gutter of 48 px or more it always
//   shows; with less, it fades in only while the pointer is on it, and its
//   hit strip never reaches over the text column.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_context_rows.dart';
import 'package:chuk_chat/utils/automation_message.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart'
    show kSbNavIconCentre;

/// Space between two strips (T3: TIMELINE_MINIMAP_ITEM_SPACING).
const double kChatTurnRailItemSpacing = 8;

/// Fewer messages than this draw no rail (T3: TIMELINE_MINIMAP_MIN_ITEMS).
const int kChatTurnRailMinItems = 2;

/// The rail is at most the window height minus this (T3: 100vh - 18rem).
const double kChatTurnRailHeightReserve = 288;

/// A side gutter at least this wide shows the rail all the time.
const double kChatTurnRailPersistentGutter = 48;

/// The vertical axis the strips are centred on, from the pane's left edge:
/// the axis of the left icon column ([kSbNavIconCentre]), so a folded
/// sidebar's icons, the strips and the gear stand on one line.
const double kChatTurnRailColumnCentre = kSbNavIconCentre;

/// Widest collapsed hit strip, centred on the axis.
const double kChatTurnRailHitStripMaxWidth = 40;

/// Widest strip (the hovered one, see [chatTurnRailStripWidth]).
const double kChatTurnRailStripMaxWidth = 24;

/// Left edge of the hit strip for a column axis at [centre].
double chatTurnRailHitLeft(double centre) =>
    math.max(0, centre - kChatTurnRailHitStripMaxWidth / 2);

/// Preview card: gap right of the widest strip, and width (T3: w-80).
const double kChatTurnRailPreviewGap = 9;
const double kChatTurnRailPreviewWidth = 320;

/// Gap between the target row and the top edge after a jump (T3: viewOffset).
const double kChatTurnRailJumpOffset = 24;

const Duration _kTransition = Duration(milliseconds: 150);

/// One user message on the rail.
///
/// The texts are read when first asked for (the hover card), not when the
/// ticks are made: the ticks are made on every rebuild of the chat screen,
/// and collapsing the whitespace of every answer of a long chat there cost
/// about 10 ms per rebuild (330 rows, 139 000 characters).
class ChatTurnRailTick {
  ChatTurnRailTick({
    required this.index,
    required String userText,
    String? assistantText,
  }) : _user = <String, String>{'text': userText},
       _turn = <Map<String, String>>[
         if (assistantText != null) <String, String>{'text': assistantText},
       ];

  ChatTurnRailTick._rows(this.index, this._user, this._turn);

  /// Its row in the message list.
  final int index;

  final Map<String, String> _user;
  final List<Map<String, String>> _turn;

  /// The message, whitespace collapsed to single spaces.
  late final String userText = compactPreview(_user['text']) ?? '';

  /// The last answer of its turn, collapsed the same way; null if none yet.
  late final String? assistantText = () {
    for (int j = _turn.length - 1; j >= 0; j--) {
      final String? text = compactPreview(_turn[j]['text']);
      if (text != null) return text;
    }
    return null;
  }();
}

/// Whitespace runs to one space, trimmed; null when nothing is left.
String? compactPreview(String? text) {
  final String compact = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return compact.isEmpty ? null : compact;
}

/// At most this many strips: more than that no longer reads as strips but as
/// one grey bar (a Mail thread had 450). The newest ones are kept.
const int kChatTurnRailMaxTicks = 80;

/// The ticks for [messages]: every row a person wrote, in order, with the
/// last non-user text before the next user row as its answer. A prompt
/// nobody typed (a fired schedule, a job wake, a mail: `agentsRowSource`, or
/// an automation wake text) is not a strip, like it is not a bubble.
List<ChatTurnRailTick> chatTurnRailTicks(
  List<Map<String, String>> messages, {
  int maxTicks = kChatTurnRailMaxTicks,
}) {
  final List<int> rows = <int>[];
  for (int i = 0; i < messages.length; i++) {
    if (messages[i]['sender'] != 'user') continue;
    if (agentsRowSource(messages[i]) != null ||
        parseAutomationWake(messages[i]['text'] ?? '') != null) {
      continue;
    }
    rows.add(i);
  }
  final int first = math.max(0, rows.length - maxTicks);
  return <ChatTurnRailTick>[
    for (int k = first; k < rows.length; k++)
      ChatTurnRailTick._rows(rows[k], messages[rows[k]], <Map<String, String>>[
        for (
          int j = rows[k] + 1;
          j < messages.length && messages[j]['sender'] != 'user';
          j++
        )
          messages[j],
      ]),
  ];
}

/// Top of strip [index] as a share of the rail (0..1).
double chatTurnRailTopFraction(int index, int count) {
  if (count <= 1) return 0;
  return index.clamp(0, count - 1) / (count - 1);
}

/// The strip nearest to [pointerY] on a rail of [railHeight], or null.
int? chatTurnRailIndexFromPointer({
  required int count,
  required double railHeight,
  required double pointerY,
}) {
  if (count <= 0 || railHeight <= 0) return null;
  if (count == 1) return 0;
  final double progress = (pointerY / railHeight).clamp(0.0, 1.0);
  return (progress * (count - 1)).round().clamp(0, count - 1);
}

/// Room kept free above and below the rail inside its band.
const double kChatTurnRailBandMargin = 16;

/// The rail's height for [count] strips in a window of [windowHeight].
///
/// [bandHeight] is the room the rail may fill around its centre without
/// touching the header or the composer (see [chatTurnRailBand]). T3 Code
/// only caps by the window; here the composer is taller, and a long chat's
/// rail (window minus 288 px) ran 29 px into the composer.
double chatTurnRailHeight(
  int count,
  double windowHeight, {
  double bandHeight = double.infinity,
}) {
  final double natural = math.max(1, (count - 1) * kChatTurnRailItemSpacing);
  final double cap = math.max(1, windowHeight - kChatTurnRailHeightReserve);
  final double band = math.max(1, bandHeight - 2 * kChatTurnRailBandMargin);
  return math.min(natural, math.min(cap, band));
}

/// The room for a rail centred between the header line ([top]) and the
/// window's bottom edge, in a pane [paneHeight] tall whose lowest [bottom]
/// px are the composer. The rail must stay clear of the composer, and it is
/// centred, so it gets twice the smaller distance from the centre.
///
/// Centred on the whole pane below the header, not on the band above the
/// composer: the list runs behind the composer, and the composer here
/// reserves about 240 px (chip, field, hint line). Centred above it, the
/// rail stood about 110 px above the middle of the chat (owner's 1035 px
/// window: strips 280..597, middle 438, chat middle about 550).
///
/// [columnTop] and [columnBottom] are what else stands in the rail's column
/// (the folded sidebar's icons at the top, its settings gear at the
/// bottom): the rail is centred in the part of the column they leave free,
/// [chatTurnRailArea].
double chatTurnRailBand({
  required double paneHeight,
  required double top,
  required double bottom,
  double columnTop = 0,
  double columnBottom = 0,
}) {
  if (!paneHeight.isFinite) return double.infinity;
  final (double areaTop, double areaBottom) = chatTurnRailArea(
    paneHeight: paneHeight,
    top: top,
    columnTop: columnTop,
    columnBottom: columnBottom,
  );
  final double centre = (areaTop + areaBottom) / 2;
  final double above = centre - areaTop;
  final double below = math.min(areaBottom, paneHeight - bottom) - centre;
  return math.max(0, 2 * math.min(above, below));
}

/// The stretch of the pane the rail is centred in: from below the header
/// ([top]) or the column's icons ([columnTop]), whichever is lower, to above
/// the column's foot ([columnBottom] px from the bottom).
(double, double) chatTurnRailArea({
  required double paneHeight,
  required double top,
  double columnTop = 0,
  double columnBottom = 0,
}) {
  final double areaTop = math.max(top, columnTop);
  return (areaTop, math.max(areaTop, paneHeight - columnBottom));
}

/// Side gutter between the pane edge and a centred column.
double chatTurnRailGutter(double paneWidth, double contentMaxWidth) {
  if (!paneWidth.isFinite || paneWidth <= 0) return 0;
  final double content = math.min(paneWidth, contentMaxWidth);
  return math.max(0, (paneWidth - content) / 2);
}

/// Collapsed hit strip around the axis at [centre]: never past the gutter
/// into the text; 0 = inert (the widest strip would not fit beside the text).
double chatTurnRailHitStripWidth(
  double gutter, {
  double centre = kChatTurnRailColumnCentre,
}) {
  final double left = chatTurnRailHitLeft(centre);
  final double room = gutter.floorToDouble() - left;
  if (room < centre - left + kChatTurnRailStripMaxWidth / 2) return 0;
  return math.min(kChatTurnRailHitStripMaxWidth, room);
}

/// Strip width by distance from the hovered strip (T3: w-6 / w-4 / w-2.5 / w-2).
double chatTurnRailStripWidth(int? distance) => switch (distance) {
  0 => 24,
  1 => 16,
  2 => 10,
  _ => 8,
};

/// Where the top of row [index] lies in the list, as a share (0..1) of all
/// rows: by [extentOf] (row heights) when given, else by count.
double chatTurnRailRowShare({
  required int index,
  required int itemCount,
  double Function(int index)? extentOf,
}) {
  if (itemCount <= 1 || index <= 0) return 0;
  if (extentOf == null) return index.clamp(0, itemCount) / itemCount;
  double before = 0;
  double total = 0;
  for (int i = 0; i < itemCount; i++) {
    final double h = extentOf(i);
    if (i < index) before += h;
    total += h;
  }
  return total <= 0 ? 0 : before / total;
}

/// Holds one key per user row so the rail can find a row that is built, and
/// walks the list to one that is not.
class ChatTurnRailController {
  final Map<int, GlobalKey> _keys = <int, GlobalKey>{};

  /// The key for the row at [index]. The list wraps each user row in it.
  GlobalKey keyFor(int index) =>
      _keys.putIfAbsent(index, () => GlobalKey(debugLabel: 'turn $index'));

  /// Forget every key (a different chat opened).
  void reset() => _keys.clear();

  /// Whether the row at [index] is built and overlaps its scroll viewport.
  bool isInView(int index) {
    final BuildContext? rowContext = _keys[index]?.currentContext;
    if (rowContext == null || !rowContext.mounted) return false;
    final RenderObject? row = rowContext.findRenderObject();
    final ScrollableState? scrollable = Scrollable.maybeOf(rowContext);
    final RenderObject? viewport = scrollable?.context.findRenderObject();
    if (row is! RenderBox || !row.attached || !row.hasSize) return false;
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return false;
    }
    final double top = row.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final double bottom = top + math.max(1, row.size.height);
    return top < viewport.size.height && bottom > 0;
  }

  /// Scroll [controller] until the row at [index] sits
  /// [kChatTurnRailJumpOffset] below the top.
  ///
  /// A lazily built list has no widget for a row far off screen, so the
  /// first jump is an estimate (the row's share of the whole list, by
  /// [extentOf] when given: the measured row heights); then the row is built
  /// and its exact offset is used.
  Future<void> scrollTo({
    required int index,
    required int itemCount,
    required ScrollController controller,
    double Function(int index)? extentOf,
  }) async {
    for (int attempt = 0; attempt < 6; attempt++) {
      if (!controller.hasClients) return;
      final ScrollPosition position = controller.position;
      final BuildContext? rowContext = _keys[index]?.currentContext;
      final RenderObject? row = rowContext != null && rowContext.mounted
          ? rowContext.findRenderObject()
          : null;
      if (row != null && row.attached) {
        final RenderAbstractViewport viewport = RenderAbstractViewport.of(row);
        final double target =
            (viewport.getOffsetToReveal(row, 0).offset -
                    kChatTurnRailJumpOffset)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        await position.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      // The content runs from minScrollExtent (an anchored list grows
      // upwards past 0) to maxScrollExtent plus one viewport; the row's top
      // sits at its share of that.
      final double share = chatTurnRailRowShare(
        index: index,
        itemCount: itemCount,
        extentOf: extentOf,
      );
      final double content =
          position.maxScrollExtent +
          position.viewportDimension -
          position.minScrollExtent;
      position.jumpTo(
        (position.minScrollExtent + content * share).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }
}

/// The minimap. Place it with [Positioned.fill] over the chat pane; it lays
/// itself out on the left edge, centred between [topPadding] and the pane's
/// bottom edge, and keeps clear of the lowest [bottomPadding] px.
class ChatTurnRail extends StatefulWidget {
  const ChatTurnRail({
    super.key,
    required this.messages,
    required this.onTickTap,
    this.rail,
    this.scrollController,
    this.contentMaxWidth = 760,
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.columnCentre = kChatTurnRailColumnCentre,
    this.columnTop = 0,
    this.columnBottom = 0,
  });

  /// The chat's rows, as the list draws them.
  final List<Map<String, String>> messages;

  /// Called with the row index of the chosen strip.
  final ValueChanged<int> onTickTap;

  /// Finds rows on screen for the bright strips. Null: no strip is bright.
  final ChatTurnRailController? rail;

  /// The list's controller; the bright strips follow its scroll.
  final ScrollController? scrollController;

  /// Widest text column of the chat; the gutter is measured beside it.
  final double contentMaxWidth;

  /// Space kept free above and below the rail (the header, the composer).
  final double topPadding;
  final double bottomPadding;

  /// The axis the strips stand on, from the pane's left edge.
  final double columnCentre;

  /// What else stands in the rail's column, from the pane's top and bottom
  /// edges (a folded sidebar's icons and its gear). 0 when nothing does.
  final double columnTop;
  final double columnBottom;

  @override
  State<ChatTurnRail> createState() => _ChatTurnRailState();
}

class _ChatTurnRailState extends State<ChatTurnRail> {
  int? _active;
  bool _hovered = false;
  final FocusNode _focus = FocusNode(debugLabel: 'chat-turn-rail');
  final GlobalKey _previewKey = GlobalKey(debugLabel: 'turn-rail-preview');
  Set<int> _inView = <int>{};
  bool _inViewScheduled = false;

  List<ChatTurnRailTick> _ticks = const <ChatTurnRailTick>[];

  @override
  void initState() {
    super.initState();
    _ticks = chatTurnRailTicks(widget.messages);
    widget.scrollController?.addListener(_scheduleInView);
    _scheduleInView();
  }

  @override
  void didUpdateWidget(ChatTurnRail old) {
    super.didUpdateWidget(old);
    if (old.scrollController != widget.scrollController) {
      old.scrollController?.removeListener(_scheduleInView);
      widget.scrollController?.addListener(_scheduleInView);
    }
    _ticks = chatTurnRailTicks(widget.messages);
    final int? active = _active;
    if (active != null && active >= _ticks.length) _active = null;
    _scheduleInView();
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_scheduleInView);
    _focus.dispose();
    super.dispose();
  }

  /// Recompute the bright strips after the next layout, once per frame.
  void _scheduleInView() {
    if (_inViewScheduled) return;
    _inViewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inViewScheduled = false;
      if (!mounted) return;
      final ChatTurnRailController? rail = widget.rail;
      final Set<int> next = <int>{
        if (rail != null)
          for (final ChatTurnRailTick t in _ticks)
            if (rail.isInView(t.index)) t.index,
      };
      if (!_sameSet(next, _inView)) setState(() => _inView = next);
    });
  }

  static bool _sameSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  void _select(int tickIndex) {
    if (tickIndex < 0 || tickIndex >= _ticks.length) return;
    widget.onTickTap(_ticks[tickIndex].index);
  }

  bool _overPreview(Offset global) {
    final RenderObject? card = _previewKey.currentContext?.findRenderObject();
    if (card is! RenderBox || !card.attached || !card.hasSize) return false;
    final Offset local = card.globalToLocal(global);
    return card.size.contains(local);
  }

  void _hover(PointerEvent event, double railHeight, double railTop) {
    if (_overPreview(event.position)) return;
    final int? next = chatTurnRailIndexFromPointer(
      count: _ticks.length,
      railHeight: railHeight,
      pointerY: event.localPosition.dy - railTop,
    );
    if (next != _active) setState(() => _active = next);
  }

  void _move(int delta) => setState(() {
    final int base = _active ?? 0;
    _active = (base + delta).clamp(0, _ticks.length - 1);
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.home) {
      setState(() => _active = 0);
    } else if (key == LogicalKeyboardKey.end) {
      setState(() => _active = _ticks.length - 1);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      final int? active = _active;
      if (active != null) _select(active);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (_ticks.length < kChatTurnRailMinItems) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints pane) {
        final double gutter = chatTurnRailGutter(
          pane.maxWidth,
          widget.contentMaxWidth,
        );
        final bool persistent = gutter >= kChatTurnRailPersistentGutter;
        final double centre = widget.columnCentre;
        final double hitLeft = chatTurnRailHitLeft(centre);
        final double hitStrip = chatTurnRailHitStripWidth(
          gutter,
          centre: centre,
        );
        final double windowHeight = MediaQuery.sizeOf(context).height;
        final double paneH = pane.maxHeight;
        final (double areaTop, double areaBottom) = paneH.isFinite
            ? chatTurnRailArea(
                paneHeight: paneH,
                top: widget.topPadding,
                columnTop: widget.columnTop,
                columnBottom: widget.columnBottom,
              )
            : (widget.topPadding, double.infinity);
        final double railHeight = chatTurnRailHeight(
          _ticks.length,
          windowHeight,
          bandHeight: chatTurnRailBand(
            paneHeight: paneH,
            top: widget.topPadding,
            bottom: widget.bottomPadding,
            columnTop: widget.columnTop,
            columnBottom: widget.columnBottom,
          ),
        );
        final bool open = _active != null;
        // While the card is open the hit box spans the rail's whole area,
        // so a card that hangs past the (short) rail still keeps the hover.
        // In the browser an overflowing child keeps it by itself; Flutter
        // only hit-tests inside a box's own size. Same centre as the closed
        // box, so the strips do not move.
        final double areaHeight = math.max(railHeight, areaBottom - areaTop);
        final bool visible = persistent || _hovered || _focus.hasFocus;
        return Padding(
          padding: EdgeInsets.only(
            top: areaTop,
            bottom: paneH.isFinite ? paneH - areaBottom : 0,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: _kTransition,
              child: Semantics(
                container: true,
                label: AppLocalizations.of(context)?.chatTurnRailLabel,
                child: Padding(
                  padding: EdgeInsets.only(left: hitLeft),
                  child: IgnorePointer(
                    // No usable gutter: the strip would cover the text.
                    ignoring: hitStrip <= 0,
                    child: _buildRail(
                      context,
                      railHeight: railHeight,
                      // Closed, the box reaches one strip gap past the end
                      // strips: a click on the first or last strip's line
                      // sat on the box's edge and could miss it.
                      boxHeight: open && areaHeight.isFinite
                          ? areaHeight
                          : railHeight + 2 * kChatTurnRailItemSpacing,
                      axis: centre - hitLeft,
                      // From the box's top: the composer's top edge.
                      composerTop: paneH.isFinite
                          ? paneH - widget.bottomPadding - areaTop
                          : double.infinity,
                      width: open ? _expandedWidth(centre - hitLeft) : hitStrip,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Hit box width while the preview is open: up to the card's right edge.
  static double _expandedWidth(double axis) =>
      _previewLeft(axis) + kChatTurnRailPreviewWidth;

  /// The card's left edge in the hit box: right of the widest strip.
  static double _previewLeft(double axis) =>
      axis + kChatTurnRailStripMaxWidth / 2 + kChatTurnRailPreviewGap;

  Widget _buildRail(
    BuildContext context, {
    required double railHeight,
    required double boxHeight,
    required double axis,
    required double composerTop,
    required double width,
  }) {
    // The box is centred on the rail, so the rail starts this far down.
    final double railTop = (boxHeight - railHeight) / 2;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int count = _ticks.length;
    final int? active = _active;
    final ChatTurnRailTick? activeTick = active == null ? null : _ticks[active];

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (bool focused) => setState(() {
        _active = focused ? (_active ?? 0) : null;
      }),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onHover: (PointerHoverEvent e) => _hover(e, railHeight, railTop),
        onExit: (_) => setState(() {
          _hovered = false;
          _active = null;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (TapUpDetails d) {
            if (_overPreview(d.globalPosition)) return;
            final int? i = chatTurnRailIndexFromPointer(
              count: count,
              railHeight: railHeight,
              pointerY: d.localPosition.dy - railTop,
            );
            if (i != null) _select(i);
            _focus.unfocus();
          },
          child: SizedBox(
            key: const ValueKey<String>('turn-rail-hit-strip'),
            width: math.max(width, 1),
            height: boxHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // The guide line (T3: w-px bg-border/15 at left-3 of the strip).
                Positioned(
                  key: const ValueKey<String>('turn-rail-guide'),
                  left: axis,
                  top: railTop,
                  height: railHeight,
                  width: 1,
                  child: ColoredBox(
                    color: scheme.outlineVariant.withValues(alpha: 0.15),
                  ),
                ),
                for (int i = 0; i < count; i++)
                  _strip(
                    scheme,
                    axis: axis,
                    tick: _ticks[i],
                    top:
                        railTop +
                        railHeight * chatTurnRailTopFraction(i, count),
                    distance: active == null ? null : (i - active).abs(),
                  ),
                // The card's first line (the message) sits on its strip,
                // pushed back inside the box where the strip is near an
                // edge. T3 centres the whole card on the strip, which put
                // the message 32 px above the strip it names.
                if (activeTick != null && active != null)
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: _PreviewPlacement(
                        left: _previewLeft(axis),
                        // Above the composer.
                        bottomLimit: composerTop,
                        stripY:
                            railTop +
                            railHeight * chatTurnRailTopFraction(active, count),
                      ),
                      child: _PreviewCard(
                        key: _previewKey,
                        tick: activeTick,
                        fallback:
                            AppLocalizations.of(context)?.chatTurnRailLabel ??
                            'Your messages',
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

  Widget _strip(
    ColorScheme scheme, {
    required double axis,
    required ChatTurnRailTick tick,
    required double top,
    required int? distance,
  }) {
    final bool inView = _inView.contains(tick.index);
    // In view wins over hover, as in T3 (data-[in-view] beats the hover tint).
    final Color color = inView
        ? scheme.onSurface.withValues(alpha: 0.9)
        : distance == 0
        ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant.withValues(alpha: 0.35);
    // The strip grows both ways from the column's axis.
    return Positioned(
      key: ValueKey<String>('turn-rail-tick-${tick.index}'),
      left: axis - kChatTurnRailStripMaxWidth / 2,
      width: kChatTurnRailStripMaxWidth,
      top: top - 1,
      height: 2,
      child: Center(
        child: AnimatedContainer(
          duration: _kTransition,
          width: chatTurnRailStripWidth(distance),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}

/// From the card's top edge to the centre of its first line: the 1 px
/// border, the 12 px padding and half a 20 px line.
const double kChatTurnRailPreviewFirstLine = 1 + 12 + 10;

/// Puts the preview card so its first line's centre is on [stripY], kept
/// inside the box and above [bottomLimit].
class _PreviewPlacement extends SingleChildLayoutDelegate {
  const _PreviewPlacement({
    required this.left,
    required this.stripY,
    required this.bottomLimit,
  });

  final double left;
  final double stripY;
  final double bottomLimit;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen().copyWith(maxHeight: double.infinity);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double wanted = stripY - kChatTurnRailPreviewFirstLine;
    final double floor = math.min(size.height, bottomLimit);
    final double maxTop = math.max(0.0, floor - childSize.height);
    return Offset(left, wanted.clamp(0.0, maxTop));
  }

  @override
  bool shouldRelayout(_PreviewPlacement old) =>
      old.left != left ||
      old.stripY != stripY ||
      old.bottomLimit != bottomLimit;
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({super.key, required this.tick, required this.fallback});

  final ChatTurnRailTick tick;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle base = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontSize: 14, height: 20 / 14);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const ValueKey<String>('turn-rail-preview'),
        width: kChatTurnRailPreviewWidth,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 25,
              offset: Offset(0, 20),
              spreadRadius: -5,
            ),
          ],
        ),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                tick.userText.isEmpty ? fallback : tick.userText,
                key: const ValueKey<String>('turn-rail-preview-first-line'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              if (tick.assistantText case final String answer) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  answer,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Fire-and-forget helper for the tap handler.
void scrollToTurn(
  ChatTurnRailController rail, {
  required int index,
  required int itemCount,
  required ScrollController controller,
  double Function(int index)? extentOf,
}) {
  unawaited(
    rail.scrollTo(
      index: index,
      itemCount: itemCount,
      controller: controller,
      extentOf: extentOf,
    ),
  );
}
