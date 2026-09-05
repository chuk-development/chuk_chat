import 'package:flutter/foundation.dart';

/// Human-readable name of the current client platform.
///
/// Stamped into Supabase `user_metadata` (as `pw_change_client`) when the
/// password changes, so the "password changed" notification email can show
/// where the change originated. Web-safe — uses [defaultTargetPlatform], no
/// `dart:io`.
String clientPlatformName() {
  if (kIsWeb) return 'Web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Android';
    case TargetPlatform.iOS:
      return 'iOS';
    case TargetPlatform.linux:
      return 'Linux';
    case TargetPlatform.windows:
      return 'Windows';
    case TargetPlatform.macOS:
      return 'macOS';
    default:
      return defaultTargetPlatform.name;
  }
}
