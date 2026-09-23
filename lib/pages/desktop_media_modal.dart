// lib/pages/desktop_media_modal.dart
//
// The media library on the desktop: a floating panel over the app, the same
// shape and weight as the settings modal.
//
// It used to be a column bolted to the right edge of the window, which gave
// a wall of square thumbnails a 320 px slot and made the chat next to it
// narrower every time someone looked at a picture. A library is something you
// open, look through, and close — not a permanent third column.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Corner radius of the panel. The settings modal's.
const double _kRadius = 28;

/// Opens the media library over the current page.
Future<void> showDesktopMediaModal(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 180),
    routeSettings: const RouteSettings(name: 'media'),
    pageBuilder: (dialogContext, anim, secondaryAnim) =>
        const DesktopMediaModal(),
    transitionBuilder: (dialogContext, animation, secondaryAnim, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The panel itself: a header row, then the library.
class DesktopMediaModal extends StatelessWidget {
  const DesktopMediaModal({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    final AppLocalizations l = AppLocalizations.of(context)!;
    final Size size = MediaQuery.of(context).size;

    final double margin = size.width < 560 || size.height < 560 ? 8 : 24;
    final double panelWidth = math.min(1180.0, size.width - margin * 2);
    final double panelHeight = math.min(800.0, size.height - margin * 2);

    // One Material draws the rounded edge AND clips to it, so the corners
    // stay clean — the same reason the settings modal is built this way.
    return Center(
      child: Padding(
        padding: EdgeInsets.all(margin),
        child: Material(
          color: theme.scaffoldBackgroundColor,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              panelWidth < 720 ? 20 : _kRadius,
            ),
            side: BorderSide(color: m3.outlineVariant),
          ),
          child: SizedBox(
            width: panelWidth,
            height: panelHeight,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
                  child: Row(
                    children: [
                      Text(
                        l.mediaManager,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: m3.surfaceContainerHigh,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).maybePop(),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: AppIcon(
                              Icons.close_rounded,
                              size: 20,
                              color: theme.resolvedIconColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Expanded(child: MediaManagerPage(embedded: true)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
