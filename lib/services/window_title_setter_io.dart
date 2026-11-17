// lib/services/window_title_setter_io.dart
// Sets the title of the native desktop window. Phones have no window title.

import 'package:flutter/foundation.dart';
// The 0.5.x API lives in legacy.dart since window_manager 0.6.
import 'package:window_manager/legacy.dart';

Future<void> setNativeWindowTitle(String title) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      await windowManager.setTitle(title);
    default:
      return;
  }
}
