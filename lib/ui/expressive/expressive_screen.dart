/// The frame of a full-screen viewer (document, image, browser view, the
/// install page).
///
/// Its header is the app's one page header, [FloatingAppBar], on the frosted
/// [PageHeaderBackdrop]: the same back chip, title pill, actions and close
/// chip as every settings page. The content scrolls up behind it. An
/// optional bar at the bottom sits on the mirrored veil.
///
/// Scrolling content gets the room it needs through the media query, not through
/// padding on the page: a list padded from the outside stops at the bar, and
/// then there is nothing to see through the veil. Its own padding uses
/// `MediaQuery.paddingOf(context)`, which this widget grows by the height of the
/// bars — the same trick the home uses for its navigation.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/top_veil.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

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

  /// Trailing targets. Use [FloatingHeaderButton] so they match the back one.
  final List<Widget> actions;

  /// What the back target does. Defaults to popping the route.
  final VoidCallback? onBack;

  final bool showBack;

  /// A bar pinned to the bottom, on the mirrored veil.
  final Widget? bottomBar;

  final Color? backgroundColor;

  /// The height of the bar itself, without the status bar above it: the
  /// height of every page header.
  static const double barHeight = kFloatingAppBarHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MediaQueryData media = MediaQuery.of(context);
    final double top = media.padding.top + barHeight;
    final double bottom = bottomBar == null
        ? media.padding.bottom
        : media.padding.bottom + barHeight;
    final Color page = backgroundColor ?? theme.scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: page,
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
            height: top,
            child: FloatingAppBar(
              backgroundColor: page,
              backSemanticsId: 'screen_back',
              automaticallyImplyLeading: showBack,
              leading: showBack && onBack != null
                  ? FloatingHeaderButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: MaterialLocalizations.of(context)
                          .backButtonTooltip,
                      semanticsId: 'screen_back',
                      onPressed: onBack,
                    )
                  : null,
              title: titleWidget ?? (title == null ? null : Text(title ?? '')),
              actions: actions.isEmpty ? null : actions,
            ),
          ),
          if (bottomBar case final Widget bar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomVeil(child: bar),
            ),
        ],
      ),
    );
  }
}
