/// The phone chat page: the messenger's floating chrome over the chat body.
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
import 'package:flutter/gestures.dart' show DragStartBehavior;

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/ui/expressive/agent_theme.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/motion.dart';

/// Builds the chat body. [topInset] is the space the body must leave at the
/// top; pass it to `CoworkThreadView.topInset` → `ChukChatUIMobile.topInset`.
typedef MobileChatBodyBuilder =
    Widget Function(BuildContext context, double topInset);

class MobileChatScreen extends StatefulWidget {
  const MobileChatScreen({
    super.key,
    required this.agent,
    required this.onBack,
    required this.bodyBuilder,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.browserAvailable = false,
    this.onOpenFiles,
    this.onReconnect,
    this.onMore,
    this.active = true,
  });

  final CoworkAgent agent;
  final VoidCallback onBack;
  final MobileChatBodyBuilder bodyBuilder;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onOpenBrowser;

  /// Is a screen open to take over? Drives the chrome's screen target.
  final bool browserAvailable;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onReconnect;
  final VoidCallback? onMore;

  /// Is this page the one in front? The shell keeps the page mounted behind
  /// the inbox (it owns the socket), so "the coworker changed" means two
  /// different things: while the inbox is in front the shell's own open
  /// transition carries the change, and only a change that happens with the
  /// thread already on screen earns the cross-fade below.
  final bool active;

  @override
  State<MobileChatScreen> createState() => _MobileChatScreenState();
}

class _MobileChatScreenState extends State<MobileChatScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _entrance,
    curve: Curves.easeOutCubic,
  );

  /// The coworker swap. There is exactly ONE thread view in the app (it holds
  /// the socket), so two threads can never be on screen at the same time and a
  /// true two-layer cross-fade is not on offer. What is on offer is the other
  /// half of Material's fade-through: the page fades up from the chat
  /// background, which the shell paints behind it, and grows the last two
  /// percent back to size. The reader sees a dissolve, not a cut.
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final Animation<double> _swapped = CurvedAnimation(
    parent: _swap,
    curve: kExpressiveDecelerate,
  );

  /// Built once: a fresh [Listenable.merge] on every build would make the
  /// [AnimatedBuilder] re-subscribe on every frame.
  late final Listenable _motion = Listenable.merge(<Listenable>[
    _progress,
    _swapped,
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
      _swap.value = 1;
    } else if (_entrance.isDismissed) {
      _entrance.forward();
    }
  }

  @override
  void didUpdateWidget(MobileChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.id == widget.agent.id) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _swap.value = 1;
      return;
    }
    // Opened from the inbox: the shell is already sliding this page in, and a
    // dissolve on top of a slide reads as a stutter.
    if (!widget.active || !oldWidget.active) return;
    _swap.forward(from: 0);
  }

  @override
  void dispose() {
    _entrance.dispose();
    _swap.dispose();
    super.dispose();
  }

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
    // The open thread wears the colour of the coworker it belongs to, so two
    // conversations are told apart before a single name is read.
    return AgentTheme(
      agentId: widget.agent.id,
      child: PopScope(
        // The page is not a route: the shell swaps it in and out. So the pop
        // is always intercepted and turned into [onBack]; the shell decides.
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (didPop) return;
          widget.onBack();
        },
        child: AnimatedBuilder(
          animation: _motion,
          builder: (context, child) => Opacity(
            opacity:
                (0.65 + 0.35 * _progress.value) *
                _swapped.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.98 + 0.02 * _swapped.value,
              child: Transform.translate(
                offset: Offset(12 * (1 - _progress.value), 0),
                child: child,
              ),
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(child: widget.bodyBuilder(context, topInset)),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: MobileChatChrome(
                  agent: widget.agent,
                  onBack: widget.onBack,
                  onOpenProfile: widget.onOpenProfile,
                  onOpenBrowser: widget.onOpenBrowser,
                  browserAvailable: widget.browserAvailable,
                  onOpenFiles: widget.onOpenFiles,
                  onReconnect: widget.onReconnect,
                  onMore: widget.onMore,
                ),
              ),
              // Only this narrow edge participates in the gesture arena. A
              // horizontal table/code scroll elsewhere belongs to the body.
              Positioned(
                left: 0,
                top: topInset,
                bottom: 0,
                width: MobileLayout.edgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: () => _dragStartX = null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
