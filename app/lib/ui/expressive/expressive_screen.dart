/// The frame every screen of this app wears.
///
/// Before this, each page brought its own: one had a Material `AppBar` with the
/// default round back arrow, another a filled-tonal one, the chat had a
/// floating pill and the roster had a transparent sliver. Four screens, four
/// back buttons, four ideas of what the top of a screen looks like — and every
/// new page added a fifth.
///
/// So there is one: a bar that floats on the shared veil (see [TopVeil]), a
/// square back target from the app's own set, a title, and optional actions on
/// the right. The content scrolls up behind it. An optional bar at the bottom
/// sits on the mirrored veil.
///
/// Scrolling content gets the room it needs through the media query, not through
/// padding on the page: a list padded from the outside stops at the bar, and
/// then there is nothing to see through the veil. Its own padding uses
/// `MediaQuery.paddingOf(context)`, which this widget grows by the height of the
/// bars — the same trick the home uses for its navigation.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';

class ExpressiveScreen extends StatelessWidget {
  const ExpressiveScreen({
    super.key,
    required this.builder,
    this.title,
    this.titleWidget,
    this.actions = const <Widget>[],
    this.onBack,
    this.showBack = true,
    this.bottomBar,
    this.backgroundColor,
  });

  /// The page itself, built BELOW the media query this widget grows.
  ///
  /// A builder, not a widget: a page that reads `MediaQuery.paddingOf(context)`
  /// in its own `build` would read the window's inset, not the one with the bars
  /// added, and its first row would sit under the title. The context handed in
  /// here already carries the room.
  final WidgetBuilder builder;

  final String? title;

  /// A title that is not a plain string (a search field, say). Wins over
  /// [title].
  final Widget? titleWidget;

  /// Trailing targets. Use [ExpressiveIconButton] so they match the back one.
  final List<Widget> actions;

  /// What the back target does. Defaults to popping the route.
  final VoidCallback? onBack;

  final bool showBack;

  /// A bar pinned to the bottom, on the mirrored veil.
  final Widget? bottomBar;

  final Color? backgroundColor;

  /// The height of the bar itself, without the status bar above it.
  static const double barHeight = 64;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MediaQueryData media = MediaQuery.of(context);
    final double top = media.padding.top + barHeight;
    final double bottom = bottomBar == null
        ? media.padding.bottom
        : media.padding.bottom + barHeight;
    return Scaffold(
      backgroundColor: backgroundColor ?? theme.colorScheme.surface,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: MediaQuery(
              data: media.copyWith(
                padding: media.padding.copyWith(top: top, bottom: bottom),
              ),
              child: Builder(builder: builder),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopVeil(
              fadeBelow: 14,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: <Widget>[
                      if (showBack) ...<Widget>[
                        ExpressiveIconButton(
                          hugeIcon: HugeIcons.arrowLeft02,
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          color: theme.colorScheme.surfaceContainerHighest,
                          semanticsId: 'screen_back',
                          onTap:
                              onBack ?? () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child:
                            titleWidget ??
                            Text(
                              title ?? '',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      ),
                      for (final Widget action in actions) ...<Widget>[
                        const SizedBox(width: 8),
                        action,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (bottomBar != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomVeil(child: bottomBar!),
            ),
        ],
      ),
    );
  }
}
