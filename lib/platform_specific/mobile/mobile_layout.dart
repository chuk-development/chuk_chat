/// Phone layout rules for the Agents mobile layer.
///
/// The mobile layer sits ABOVE the verbatim chuk_chat screens
/// (`platform_specific/chat/**`) and never edits them. It decides when the
/// phone layout applies and how much room the floating chrome takes, so the
/// shell, the chat page and the tests all read one number.
///
/// Design source: the Material 3 Expressive messenger this UI was rebuilt
/// after — see `docs/EXPRESSIVE_UI_REDESIGN.md`. (The first phone layer
/// followed Grok Bot, `docs/MOBILE_GROKBOT_STRUCTURE.md`; the geometry below is
/// what survived of it.)
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_config.dart';

class MobileLayout {
  MobileLayout._();

  /// Below this width the phone layout applies on EVERY platform. A narrow
  /// desktop window therefore shows the phone layout too, which is how the
  /// layout is checked on Linux without an emulator.
  static const double phoneBreakpoint = 600;

  /// Material's minimum touch target. The reference uses 44 pt targets; the
  /// larger of the two wins so nothing is hard to hit.
  static const double minTouchTarget = 48;

  /// Diameter of the round chips in the floating bars.
  static const double chipDiameter = minTouchTarget;

  /// The height of one control in a header row: an icon button, the contact
  /// pill, the roster's All/Unread switch, the search field. One number,
  /// because a row whose controls do not agree on their height reads as
  /// controls borrowed from three screens.
  static const double controlHeight = 52;

  /// Height at normal text size: 8 padding + the contact pill + 10 padding.
  /// [chromeInset] also accounts for accessible larger text sizes.
  static const double barHeight = 8 + controlHeight + 10;

  /// Grow the contact bar with accessibility text sizing rather than clip it.
  /// At normal size the two text lines and the border come to just under
  /// [controlHeight], so the pill takes exactly the height of the buttons
  /// beside it; larger text pushes past that and the whole row grows.
  static double headerContentHeight(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return (scaler.scale(16) * 1.5 + scaler.scale(11) * 1.45 + 8 + 2.4).clamp(
      controlHeight,
      double.infinity,
    );
  }

  /// The soft fade under the bar. It overlaps the first list row on purpose:
  /// the messages scroll under the chips and fade out, like Grok Bot.
  static const double barFade = 14;

  /// Left-edge width that starts a swipe-back. Same value iOS uses.
  static const double edgeSwipeWidth = 24;

  /// Horizontal velocity (px/s) that counts as a swipe. Same threshold chuk
  /// uses for its sidebar swipe, so the two gestures feel alike.
  static const double swipeVelocity = 500;

  /// Material's "expanded" window class starts here. At this width and more,
  /// a tablet shows everything side by side; between [phoneBreakpoint] and
  /// this width (a tablet in portrait, "medium") the wide layout folds its
  /// side panes to rails or overlays by its own width rules.
  static const double expandedBreakpoint = 840;

  /// True on a touch device that is not forced to the desktop build: Android
  /// or iOS, not the web. The wide layout on such a device is a tablet: it
  /// has no hover, its targets are fingers, and it has a system back.
  static bool get isTouchPlatform {
    if (kPlatformDesktop || kIsWeb) return false;
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  /// The one rule for "phone layout or wide layout", from the window size.
  ///
  /// * A phone build (`PLATFORM_MOBILE=true`) is always the phone layout.
  /// * Android and iOS: the window's SHORTEST side decides (Material window
  ///   size classes: below [phoneBreakpoint] is a phone). A rotation never
  ///   changes the answer, so a phone in landscape stays the phone layout and
  ///   a tablet in portrait stays the wide one. Only a split-screen or
  ///   freeform window that crosses [phoneBreakpoint] changes it.
  /// * Desktop and web: the WIDTH decides, as before. A narrow desktop window
  ///   therefore shows the phone layout, which is how the layout is checked
  ///   on Linux without an emulator.
  static bool isPhoneSize(Size size) {
    if (kPlatformMobile) return true;
    if (isTouchPlatform) return size.shortestSide < phoneBreakpoint;
    return size.width < phoneBreakpoint;
  }

  /// [isPhoneSize] for the window of [context].
  ///
  /// Reads `MediaQuery.sizeOf`, never `MediaQuery.of`: the latter subscribes
  /// to `viewInsets` and would rebuild the caller on every keyboard frame.
  static bool isPhone(BuildContext context) =>
      isPhoneSize(MediaQuery.sizeOf(context));

  /// True when the wide layout runs on a touch device: a tablet.
  static bool isTablet(BuildContext context) =>
      isTouchPlatform && !isPhone(context);

  /// The width-only rule, for a caller that has a `LayoutBuilder` constraint
  /// and no window: a phone build, or anything narrower than
  /// [phoneBreakpoint]. Prefer [isPhoneSize] when the window is known.
  static bool isPhoneWidth(double width) =>
      kPlatformMobile || width < phoneBreakpoint;

  /// Space the chat body reserves at the top so its first row starts below
  /// the floating bar: status-bar inset + the bar's content.
  ///
  /// `viewPaddingOf`, not `of` or `paddingOf`: `padding` changes while the
  /// keyboard rises, `viewPadding` does not. See [isPhone].
  static double chromeInset(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top +
      8 +
      headerContentHeight(context) +
      10;
}
