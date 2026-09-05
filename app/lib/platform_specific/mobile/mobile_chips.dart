/// The round chips of the floating mobile bars.
///
/// Grok Bot's chrome is a row of free-standing circles on a soft fade: a
/// surface-coloured chip with a light shadow for secondary actions and a
/// filled accent chip for the one primary action. Both are 48 dp so they
/// meet the Material touch target; Grok Bot's 44 pt is the smaller of the two.
///
/// No `BackdropFilter`: the bar under the chips already fades the content
/// out, and a blur per chip costs a full-screen readback on phones.
library;

import 'package:flutter/material.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

/// A round, surface-coloured chip with a soft shadow.
class MobileRoundChip extends StatelessWidget {
  const MobileRoundChip({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.semanticsId,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final String? semanticsId;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = iconColor ?? theme.colorScheme.onSurface;
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: MobileLayout.chipDiameter,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: mobileChipShadow(theme),
            ),
            child: Material(
              color: theme.colorScheme.surface,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Center(
                  child: Icon(
                    icon,
                    size: 22,
                    color: onTap == null ? fg.withValues(alpha: 0.38) : fg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round chip filled with the accent colour, for the one primary action of
/// a bar (add a coworker, send).
class MobileAccentChip extends StatelessWidget {
  const MobileAccentChip({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.semanticsId,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final String? semanticsId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: MobileLayout.chipDiameter,
          child: Material(
            color: theme.colorScheme.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(
                child: Icon(icon, size: 22, color: theme.colorScheme.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The soft shadow under a chip or pill. Lighter in dark mode, where a hard
/// shadow reads as a black halo.
List<BoxShadow> mobileChipShadow(ThemeData theme) {
  final bool dark = theme.brightness == Brightness.dark;
  return <BoxShadow>[
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
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
