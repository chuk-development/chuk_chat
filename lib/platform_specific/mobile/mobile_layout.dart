/// Phone layout rules for the CoWork mobile layer.
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

import 'package:cowork/constants.dart' show kTabletBreakpoint;
import 'package:cowork/platform_config.dart';

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

  /// True when the phone layout applies: a real phone, or any window narrower
  /// than [phoneBreakpoint].
  ///
  /// Reads `MediaQuery.sizeOf`, never `MediaQuery.of`: the latter subscribes
  /// to `viewInsets` and would rebuild the caller on every keyboard frame.
  static bool isPhone(BuildContext context) {
    if (kPlatformMobile) return true;
    final double width = MediaQuery.sizeOf(context).width;
    if (width < phoneBreakpoint) return true;
    if (kPlatformDesktop || kIsWeb) return false;
    final platform = defaultTargetPlatform;
    final bool mobilePlatform =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    return mobilePlatform && width < kTabletBreakpoint;
  }

  /// The same rule for a width the caller already has (a `LayoutBuilder`
  /// constraint): a real phone, or anything narrower than [phoneBreakpoint].
  static bool isPhoneWidth(double width) =>
      kPlatformMobile || width < phoneBreakpoint;

  /// Space the chat body reserves at the top so its first row starts below
  /// the floating bar: status-bar inset + the bar's content.
  ///
  /// `paddingOf`, not `of`: see [isPhone].
  static double chromeInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top + 8 + headerContentHeight(context) + 10;
}
