// lib/widgets/chat_turn_rail.dart
//
// A thin rail on the right of a long desktop chat: one tick per message the
// user wrote, placed where that message sits in the thread. A tooltip shows
// the message's first line; a tap scrolls to it. Hidden when the chat column
// is narrower than [kChatTurnRailMinColumnWidth] — there it would crowd the
// text, and a short window has little to navigate.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

/// Narrower than this, the rail is not drawn.
const double kChatTurnRailMinColumnWidth = 900;

/// Width of the rail's hit strip.
const double kChatTurnRailWidth = 16;

/// Longest tooltip line before it is cut.
const int _kTooltipChars = 80;

/// One user message on the rail.
@immutable
class ChatTurnRailTick {
  const ChatTurnRailTick({required this.index, required this.label});

  /// Its row in the message list.
  final int index;

  /// Its first line, already clipped.
  final String label;
}

/// The ticks for [messages]: every row whose sender is `user`, in order.
List<ChatTurnRailTick> chatTurnRailTicks(List<Map<String, String>> messages) {
  final List<ChatTurnRailTick> ticks = <ChatTurnRailTick>[];
  for (int i = 0; i < messages.length; i++) {
    if (messages[i]['sender'] != 'user') continue;
    ticks.add(
      ChatTurnRailTick(index: i, label: firstLineOf(messages[i]['text'] ?? '')),
    );
  }
  return ticks;
}

/// The first non-empty line of [text], clipped with an ellipsis.
String firstLineOf(String text, {int max = _kTooltipChars}) {
  String line = '';
  for (final String part in text.split('\n')) {
    if (part.trim().isNotEmpty) {
      line = part.trim();
      break;
    }
  }
  if (line.length <= max) return line;
  return '${line.substring(0, max - 1).trimRight()}…';
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

  /// Scroll [controller] until the row at [index] is in view.
  ///
  /// A lazily built list has no widget for a row far off screen, so the
  /// first jump is an estimate (the row's share of the whole list); then the
  /// row is built and [Scrollable.ensureVisible] places it exactly.
  Future<void> scrollTo({
    required int index,
    required int itemCount,
    required ScrollController controller,
  }) async {
    for (int attempt = 0; attempt < 6; attempt++) {
      final BuildContext? rowContext = _keys[index]?.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: 0.05,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (!controller.hasClients) return;
      final ScrollPosition position = controller.position;
      final double share = itemCount <= 1 ? 0 : index / (itemCount - 1);
      controller.jumpTo(
        (position.maxScrollExtent * share).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }
}

class ChatTurnRail extends StatelessWidget {
  const ChatTurnRail({
    super.key,
    required this.messages,
    required this.onTickTap,
    this.topPadding = 0,
    this.bottomPadding = 0,
  });

  /// The chat's rows, as the list draws them.
  final List<Map<String, String>> messages;

  /// Called with the row index of the tapped tick.
  final ValueChanged<int> onTickTap;

  /// Space kept free above and below the ticks (the header, the composer).
  final double topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < kChatTurnRailMinColumnWidth) {
          return const SizedBox.shrink();
        }
        final List<ChatTurnRailTick> ticks = chatTurnRailTicks(messages);
        // One message has nowhere to go.
        if (ticks.length < 2) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(
              top: topPadding,
              bottom: bottomPadding,
              right: 4,
            ),
            child: SizedBox(
              width: kChatTurnRailWidth,
              child: Semantics(
                container: true,
                label: AppLocalizations.of(context)?.chatTurnRailLabel,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints rail) =>
                      _buildTicks(context, ticks, rail.maxHeight),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTicks(
    BuildContext context,
    List<ChatTurnRailTick> ticks,
    double height,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double tickHit = 10;
    final double span = (height - tickHit).clamp(0, double.infinity);
    final int last = messages.length <= 1 ? 1 : messages.length - 1;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        for (final ChatTurnRailTick tick in ticks)
          Positioned(
            key: ValueKey<String>('turn-rail-tick-${tick.index}'),
            top: span * (tick.index / last),
            right: 0,
            width: kChatTurnRailWidth,
            height: tickHit,
            child: Tooltip(
              message: tick.label,
              preferBelow: false,
              waitDuration: const Duration(milliseconds: 200),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTickTap(tick.index),
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 3,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Fire-and-forget helper for the tap handler.
void scrollToTurn(
  ChatTurnRailController rail, {
  required int index,
  required int itemCount,
  required ScrollController controller,
}) {
  unawaited(
    rail.scrollTo(index: index, itemCount: itemCount, controller: controller),
  );
}
