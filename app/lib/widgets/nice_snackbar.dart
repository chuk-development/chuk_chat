import 'package:flutter/material.dart';

/// Floating, rounded, pill-style SnackBar to replace Flutter's default fat
/// rectangular one. Matches the look already used by the Share/Export flow
/// in [SettingsPage].
class NiceSnackBar {
  NiceSnackBar._();

  /// Dismiss anything currently visible and show [message] in the shared
  /// floating pill style. Returns the controller so callers can await close.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(
      _build(message, duration, backgroundColor, foregroundColor),
    );
  }

  /// Same as [show] but colored for errors.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showError(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return show(
      context,
      message,
      duration: duration,
      backgroundColor: cs.error,
      // The error ground is `error`, so the words on it must be `onError` —
      // the default snack bar foreground is unreadable there.
      foregroundColor: cs.onError,
    );
  }

  static SnackBar _build(
    String message,
    Duration duration,
    Color? bg,
    Color? fg,
  ) {
    return SnackBar(
      content: Text(
        message,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: fg),
      ),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      // The doc says pill; a pill is a stadium, not a 12 dp rectangle.
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      duration: duration,
      dismissDirection: DismissDirection.horizontal,
    );
  }
}
