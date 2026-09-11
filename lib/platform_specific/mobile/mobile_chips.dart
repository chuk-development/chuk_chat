/// The soft fade a floating bar sits on, and the shadow its targets carry.
///
/// The targets themselves are [ExpressiveIconButton]s now (they spring and
/// morph like every other button in the app); what is left here is the fade
/// under the bar, which is what lets the chat scroll under the chrome and
/// dissolve.
///
/// No `BackdropFilter`: the fade already takes the content out, and a blur per
/// target costs a full-screen readback on a phone.
library;

import 'package:flutter/material.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

/// The soft shadow under a chip or pill. Lighter in dark mode, where a hard
/// shadow reads as a black halo.
List<BoxShadow> mobileChipShadow(ThemeData theme) {
  final bool dark = theme.brightness == Brightness.dark;
  return <BoxShadow>[
    BoxShadow(
      color: theme.colorScheme.shadow.withValues(alpha: dark ? 0.35 : 0.10),
      blurRadius: 10,
      offset: const Offset(0, 2),
    ),
  ];
}

/// The fade behind a floating bar: solid at the top, transparent at the
/// bottom, so the content scrolls under the chips and dissolves.
///
/// [height] is the bar's content height; the fade adds [MobileLayout.barFade]
/// below it. The status-bar inset is padded by the caller's `SafeArea`, so
/// this box covers it too.
class MobileBarFade extends StatelessWidget {
  const MobileBarFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const <double>[0.0, 0.72, 1.0],
          colors: <Color>[
            bg.withValues(alpha: 0.96),
            bg.withValues(alpha: 0.88),
            bg.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: MobileLayout.barFade),
        child: child,
      ),
    );
  }
}
