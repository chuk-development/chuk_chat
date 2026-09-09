// lib/utils/app_snack_bar.dart

import 'package:flutter/material.dart';

/// The app's one snack bar: floating, inset from the edges, rounded, and
/// swipeable sideways.
///
/// Every screen used to spell this out again, which is how three of them ended
/// up with the same shape and a different corner radius. Pass [backgroundColor]
/// or [duration] where a screen genuinely needs its own.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Color? backgroundColor,
  Duration duration = const Duration(seconds: 2),
}) {
  // maybeOf, not of: this is called from async continuations that may outlive
  // the route, and a missing messenger must not throw.
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      backgroundColor: backgroundColor,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      duration: duration,
      dismissDirection: DismissDirection.horizontal,
    ),
  );
}
