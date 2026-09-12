import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/app_notification.dart';

/// The old name for [AppNotifications], kept so the call sites that already
/// use it keep working.
///
/// Nothing is drawn here any more — every message in the app is the same
/// widget, [AppNotification]. Write new code against [AppNotifications]; this
/// only forwards.
class NiceSnackBar {
  NiceSnackBar._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
    Color? backgroundColor,
  }) {
    return AppNotifications.show(
      context,
      message,
      duration: duration,
      // The one thing callers used the colour for was "this is an error".
      kind: backgroundColor == null
          ? AppNotificationKind.info
          : AppNotificationKind.error,
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showOn(
    ScaffoldMessengerState messenger,
    String message, {
    Duration duration = const Duration(seconds: 2),
    Color? backgroundColor,
  }) {
    return AppNotifications.showOn(
      messenger,
      message,
      duration: duration,
      kind: backgroundColor == null
          ? AppNotificationKind.info
          : AppNotificationKind.error,
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showError(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    return AppNotifications.error(context, message, duration: duration);
  }
}
