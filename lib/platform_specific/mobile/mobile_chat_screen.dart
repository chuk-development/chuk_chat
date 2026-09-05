/// The phone chat page: Grok Bot chrome floating over the chat body.
///
/// The body is whatever the shell already renders for a thread (the
/// `CoworkThreadView`, which holds the verbatim chuk_chat phone screen). This
/// page only adds what a messenger needs around it:
///
///  * the floating [MobileChatChrome] on top, and the `topInset` the body
///    must reserve so its first row scrolls under the chips;
///  * back: Android back / predictive back through `PopScope`, and an iOS-style
///    swipe from the left edge — both call [onBack], the shell flips its flag;
///  * a tap on empty space closes the keyboard.
///
/// It returns no `Scaffold`. The shell's `Scaffold` hosts it and resizes the
/// body with the keyboard, which is what chuk's phone screen expects (it uses
/// `resizeToAvoidBottomInset: false` inside and measures its composer).
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

/// Builds the chat body. [topInset] is the space the body must leave at the
/// top; pass it to `CoworkThreadView.topInset` → `ChukChatUIMobile.topInset`.
typedef MobileChatBodyBuilder = Widget Function(
  BuildContext context,
  double topInset,
);

class MobileChatScreen extends StatefulWidget {
  const MobileChatScreen({
    super.key,
    required this.agent,
    required this.onBack,
    required this.bodyBuilder,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.onMore,
  });

  final CoworkAgent agent;
  final VoidCallback onBack;
  final MobileChatBodyBuilder bodyBuilder;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onOpenBrowser;
  final VoidCallback? onMore;

  @override
  State<MobileChatScreen> createState() => _MobileChatScreenState();
}

class _MobileChatScreenState extends State<MobileChatScreen> {
  /// Where the current horizontal drag started. Only a drag that starts at
  /// the left edge can become a swipe-back, so a horizontal fling in the
  /// middle of the chat (a table, a code block) never pops the page.
  double? _dragStartX;

  void _onDragStart(DragStartDetails details) {
    _dragStartX = details.globalPosition.dx;
  }

  void _onDragEnd(DragEndDetails details) {
    final double? startX = _dragStartX;
    _dragStartX = null;
    if (startX == null || startX > MobileLayout.edgeSwipeWidth) return;
    final double? velocity = details.primaryVelocity;
    if (velocity == null || velocity < MobileLayout.swipeVelocity) return;
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final double topInset = MobileLayout.chromeInset(context);
    return PopScope(
      // The page is not a route: the shell swaps it in and out. So the pop
      // is always intercepted and turned into [onBack]; the shell decides.
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        widget.onBack();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragEnd: _onDragEnd,
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.bodyBuilder(context, topInset),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MobileChatChrome(
                agent: widget.agent,
                onBack: widget.onBack,
                onOpenProfile: widget.onOpenProfile,
                onOpenBrowser: widget.onOpenBrowser,
                onMore: widget.onMore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
