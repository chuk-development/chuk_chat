// lib/ui/components/page_header.dart
//
// The material behind every page header, and the header's title style.
//
// The header row itself is FloatingAppBar (lib/widgets/floating_app_bar.dart):
// the back chip, the title pill, the actions and, inside a settings surface,
// the close chip. This file holds what the row sits on.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

/// How strongly the header blurs what scrolls under it.
const double kPageHeaderBlur = 18;

/// How much of the page colour lies over the blur. High enough that text
/// under the header is never legible, low enough that the header still
/// shows that something moves under it.
const double kPageHeaderTint = 0.82;

/// The style of every page title: in the header pill of a settings page, a
/// full-screen viewer and a pane page. 15 px, weight 800, the app's UI font.
///
/// The font family comes from the theme's text theme. A bare `TextStyle`
/// has no family, and then the title fell back to the platform font while
/// the rest of the page used the app font.
TextStyle pageHeaderTitleStyle(ThemeData theme) {
  final TextStyle? base = theme.textTheme.titleMedium;
  return TextStyle(
    fontFamily: base?.fontFamily,
    fontFamilyFallback: base?.fontFamilyFallback,
    color: theme.resolvedIconColor.withValues(alpha: 0.92),
    fontSize: 15,
    fontWeight: FontWeight.w800,
  );
}

/// The frosted material behind a page header.
///
/// It fills its box: the status bar and the header row. What scrolls under
/// it is blurred and covered with the page colour at [kPageHeaderTint], so
/// a line of text never runs legibly into the title or a chip. With nothing
/// under it, it is the page colour and draws nothing that can be seen.
///
/// It takes the taps on its area, so a miss next to a chip never presses a
/// row hidden under the header.
class PageHeaderBackdrop extends StatelessWidget {
  const PageHeaderBackdrop({super.key, this.color});

  /// The page colour under the header. Null takes the scaffold colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color page = color ?? Theme.of(context).scaffoldBackgroundColor;
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: kPageHeaderBlur,
            sigmaY: kPageHeaderBlur,
          ),
          child: SizedBox.expand(
            child: ColoredBox(
              color: page.withValues(alpha: page.a * kPageHeaderTint),
            ),
          ),
        ),
      ),
    );
  }
}
