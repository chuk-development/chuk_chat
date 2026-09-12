// lib/widgets/app_notification.dart
//
// The one thing the app uses to say something to the reader.
//
// Before this there were a hundred-odd bare `showSnackBar` calls, each
// building its own SnackBar, and they had drifted: some floating, some glued
// to the bottom edge as a full-bleed rectangle, different radii, different
// text weights. A shared *style* is not enough to stop that — the next call
// site writes its own SnackBar again. So the pill is a widget, and every
// message goes through it.
//
// The SnackBar underneath is only the mechanism: it is made transparent and
// flat, and [AppNotification] paints everything that is visible.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// What kind of thing happened. Picks the glyph and the accent down the side.
enum AppNotificationKind {
  /// Something happened, nothing is wrong.
  info,

  /// It worked.
  success,

  /// It did not work.
  error,
}

/// The floating pill the app talks to the reader in.
///
/// Same language as the rest of the floating chrome: a fill one step off the
/// page, a large radius, no border and no shadow. The only thing added is a
/// coloured glyph, because a message that reports a failure has to be
/// recognisable as one before it is read.
class AppNotification extends StatelessWidget {
  const AppNotification({
    super.key,
    required this.message,
    this.kind = AppNotificationKind.info,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final AppNotificationKind kind;

  /// The one thing the reader can do about it — "Undo", "Retry". Null for a
  /// message that is only a message.
  final String? actionLabel;
  final VoidCallback? onAction;

  IconData get _glyph => switch (kind) {
    AppNotificationKind.info => Icons.info_outline_rounded,
    AppNotificationKind.success => Icons.check_circle_outline_rounded,
    AppNotificationKind.error => Icons.error_outline_rounded,
  };

  Color _glyphColor(ThemeData theme) => switch (kind) {
    AppNotificationKind.info => theme.resolvedIconColor.withValues(alpha: 0.7),
    AppNotificationKind.success => theme.m3.success,
    AppNotificationKind.error => theme.colorScheme.error,
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FloatingChromeSurface(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(_glyph, size: 18, color: _glyphColor(theme)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              message,
              style: TextStyle(
                color: theme.resolvedIconColor,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: const StadiumBorder(),
              ),
              child: Text(actionLabel!),
            ),
          ] else
            const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// The SnackBar an [AppNotification] travels in.
///
/// Exposed for the handful of callers that hold a messenger captured before
/// an await and build the bar themselves. Everything else goes through
/// [AppNotifications].
SnackBar appNotificationSnackBar({
  required String message,
  AppNotificationKind kind = AppNotificationKind.info,
  Duration duration = const Duration(seconds: 2),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  return SnackBar(
    content: AppNotification(
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
    // The SnackBar is the mechanism, not the look: it contributes nothing
    // visible, so the pill is the whole of it.
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    duration: duration,
  );
}

/// How a message reaches the screen.
///
/// Always through here, never by building a SnackBar at the call site.
abstract final class AppNotifications {
  /// Show [message]. Anything already on screen is dismissed first, so two
  /// messages in a row do not queue up behind each other while the reader
  /// waits for the second one.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String message, {
    AppNotificationKind kind = AppNotificationKind.info,
    Duration duration = const Duration(seconds: 2),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return showOn(
      ScaffoldMessenger.of(context),
      message,
      kind: kind,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// [show] for a caller that captured the messenger before an await, where
  /// touching the [BuildContext] again would be unsafe.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showOn(
    ScaffoldMessengerState messenger,
    String message, {
    AppNotificationKind kind = AppNotificationKind.info,
    Duration duration = const Duration(seconds: 2),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(
      appNotificationSnackBar(
        message: message,
        kind: kind,
        duration: duration,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );
  }

  /// A failure. Longer on screen, because there is usually something to read.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> error(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onAction,
  }) => show(
    context,
    message,
    kind: AppNotificationKind.error,
    duration: duration,
    actionLabel: actionLabel,
    onAction: onAction,
  );

  /// It worked.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> success(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) => show(context, message, kind: AppNotificationKind.success,
      duration: duration);
}
