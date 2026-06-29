import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chuk_chat/services/diagnostics_log_service.dart';

/// Shared message-list scroll behaviour for the desktop and mobile chat UIs.
///
/// Both screens drive an identical non-reversed [ListView] whose "bottom" is
/// [ScrollPosition.maxScrollExtent]. This mixin owns the scroll controller, the
/// sticky-to-bottom tracking, the scroll-to-bottom button visibility, and the
/// composer-height feedback — previously copy-pasted into both State classes.
///
/// Members are public (not `_`-prefixed) so they're reachable from the host
/// State, its build method, and any `part`/extension code in the host library.
mixin ChatScrollMixin<T extends StatefulWidget> on State<T> {
  /// Show the scroll-to-bottom FAB once the user is this far from the bottom.
  static const double showScrollButtonDistance = 260.0;

  /// Hide the FAB again once back within this distance of the bottom.
  static const double hideScrollButtonDistance = 140.0;

  final ScrollController scrollController = ScrollController();

  /// Whether the scroll-to-bottom FAB is currently visible.
  bool showScrollToBottom = false;

  /// Whether the view is pinned to the bottom. When true, new content and a
  /// growing composer keep the latest message in view; when false the user has
  /// scrolled up and is left alone.
  bool isStickyBottom = true;

  /// Real measured height of the composer (search bar + disclaimer + banners),
  /// fed by a `MeasureSize` wrapper so the list's reserved bottom space tracks
  /// the composer as it grows multi-line. 0 until the first layout pass.
  double composerHeight = 0;

  /// Recomputes FAB visibility and sticky-bottom state from current scroll
  /// metrics. Safe to call from a scroll listener or a layout-metrics
  /// notification.
  void onScrollChanged() {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final distanceToBottom = position.maxScrollExtent - position.pixels;
    // If the whole chat fits on screen (nothing to scroll) the button is
    // always useless — hide it unconditionally. Without this guard, a short
    // chat whose maxScrollExtent briefly grows during layout (e.g. when an
    // AI message finishes streaming and the input shifts) can leave the
    // button stuck visible even though the user is already at the end.
    final hasScrollableContent = position.maxScrollExtent > 0;

    bool nextShowScrollButton = showScrollToBottom;
    if (!hasScrollableContent) {
      nextShowScrollButton = false;
    } else if (!showScrollToBottom &&
        distanceToBottom > showScrollButtonDistance) {
      nextShowScrollButton = true;
    } else if (showScrollToBottom &&
        distanceToBottom < hideScrollButtonDistance) {
      nextShowScrollButton = false;
    }

    bool nextStickyBottom = isStickyBottom;
    if (distanceToBottom > 100) {
      nextStickyBottom = false;
    } else if (distanceToBottom < 8) {
      nextStickyBottom = true;
    }

    final buttonChanged = nextShowScrollButton != showScrollToBottom;
    final stickyChanged = nextStickyBottom != isStickyBottom;
    if (!buttonChanged && !stickyChanged) return;

    if (buttonChanged) {
      setState(() {
        showScrollToBottom = nextShowScrollButton;
      });
      unawaited(
        DiagnosticsLogService.info(
          'chat_ui',
          'Scroll threshold toggled',
          data: {
            'show_scroll_button': nextShowScrollButton,
            'distance_to_bottom': distanceToBottom.round(),
            'pixels': position.pixels.round(),
            'max_scroll_extent': position.maxScrollExtent.round(),
            'show_threshold': showScrollButtonDistance.round(),
            'hide_threshold': hideScrollButtonDistance.round(),
          },
        ),
      );
    }
    if (stickyChanged) {
      isStickyBottom = nextStickyBottom;
    }
  }

  /// Fed by `MeasureSize` wrapping the composer. When the input grows
  /// (multi-line text, attachments, banners) the reserved bottom space must
  /// grow with it, and if we're pinned to the bottom we re-scroll so the last
  /// message stays visible above the larger composer.
  void onComposerHeightChanged(Size size) {
    if (!mounted) return;
    if ((size.height - composerHeight).abs() < 0.5) return;
    final bool grew = size.height > composerHeight;
    setState(() {
      composerHeight = size.height;
    });
    if (grew && isStickyBottom) {
      scrollChatToBottom();
    }
  }

  /// Lightweight per-token pin used during streaming. Unlike
  /// [scrollChatToBottom] (which animates and would stack/jank when fired on
  /// every token) this does a single coalesced post-frame jump to the
  /// freshly-grown bottom, and bails out if the user has scrolled away or is
  /// actively dragging the list.
  void pinToBottomDuringStream() {
    if (!isStickyBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      if (!isStickyBottom) return;
      final position = scrollController.position;
      if (position.isScrollingNotifier.value) return;
      if ((position.maxScrollExtent - position.pixels).abs() > 0.5) {
        scrollController.jumpTo(position.maxScrollExtent);
      }
    });
  }

  void scrollChatToBottom({bool animate = true, bool force = false}) {
    if (!mounted) return;
    if (!force && !isStickyBottom) return;

    // Instant jump (e.g. opening an existing chat): ListView.builder only
    // reports an *estimated* maxScrollExtent from the items laid out so far,
    // and async-sized content (images, code blocks) can grow it over several
    // frames. A single post-frame jump lands short of the real bottom, so
    // settle across a few frames until the extent stops growing.
    if (force && !animate) {
      settleScrollToBottom();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      // Honour an in-progress scroll only for passive (non-forced) calls; a
      // forced scroll-to-bottom (button press, chat open) must win regardless.
      if (!force && scrollController.position.isScrollingNotifier.value) return;

      final position = scrollController.position;
      final isNearBottom = position.maxScrollExtent - position.pixels < 100;

      if (force || isNearBottom) {
        if (animate) {
          scrollController.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        } else {
          scrollController.jumpTo(position.maxScrollExtent);
        }
      }
    });
  }

  /// Jump to the bottom, then keep re-jumping on subsequent frames until the
  /// scroll extent stabilises. ListView.builder grows its *estimated*
  /// maxScrollExtent as it lays out more items / async-sized content, so a
  /// single jump on chat open often stops short of the real bottom.
  void settleScrollToBottom({double lastExtent = -1, int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      final position = scrollController.position;
      final target = position.maxScrollExtent;

      if ((target - position.pixels).abs() > 0.5) {
        scrollController.jumpTo(target);
      }

      // Stop once the extent stops growing (or after a bounded number of
      // frames, to avoid looping forever on pathological layouts).
      final bool stable = (target - lastExtent).abs() < 0.5;
      if (stable || attempt >= 10) return;
      settleScrollToBottom(lastExtent: target, attempt: attempt + 1);
    });
  }
}
