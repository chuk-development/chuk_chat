// lib/services/window_title_setter_io.dart
// Sets the title of the native desktop window. Phones have no window title.

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

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
