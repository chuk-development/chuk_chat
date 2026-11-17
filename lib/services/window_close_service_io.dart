// lib/services/window_close_service_io.dart
// Ensures clean window close on Linux desktop.
//
// The window_manager plugin unconditionally replaces Flutter engine's
// GTK delete_event handler with its own. When FEATURE_SYSTEM_TRAY is off
// (the default), no Dart code initializes window_manager, so the close
// event goes unhandled and the engine crashes on shutdown — producing a
// delayed close and a crash dialog from the desktop environment.
//
// This service initializes window_manager with preventClose enabled and
// handles the close event by calling exit(0) for a clean shutdown.

import 'dart:io' show exit;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chuk_chat/platform_config.dart';

Future<void> initializeWindowCloseHandler() async {
  // Only needed on Linux desktop when system tray is not handling close.
  if (kIsWeb || kFeatureSystemTray) return;
  if (defaultTargetPlatform != TargetPlatform.linux) return;

  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  windowManager.addListener(_CloseListener());
}

class _CloseListener extends WindowListener {
  bool _isClosing = false;

  @override
  void onWindowClose() {
    if (_isClosing) return;
    _isClosing = true;
    exit(0);
  }
}
