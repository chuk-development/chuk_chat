// lib/services/system_tray_service_io.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop system tray integration for Linux, Windows, and macOS.
///
/// Closing the window hides the app to tray instead of exiting.
class SystemTrayService with TrayListener, WindowListener {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  static const String _kToggleWindowKey = 'toggle_window';
  static const String _kQuitKey = 'quit';

  bool _isInitialized = false;
  bool _isWindowVisible = true;
  bool _isQuitting = false;

  bool get _isDesktop {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux => true,
      TargetPlatform.windows => true,
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  bool get _supportsTooltip => defaultTargetPlatform != TargetPlatform.linux;

  Future<void> initialize() async {
    if (!_isDesktop || _isInitialized) return;

    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      final iconPath = await _resolveTrayIconPath();
      await trayManager.setIcon(iconPath);

      if (_supportsTooltip) {
        await trayManager.setToolTip('Chuk Chat');
      }

      trayManager.addListener(this);
      _isInitialized = true;

      await _syncWindowVisibility();
      await _updateMenu();

      if (kDebugMode) {
        debugPrint('[SystemTrayService] Initialized');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Failed to initialize: $error');
      }
      await _rollbackInitialization();
    }
  }

  Future<String> _resolveTrayIconPath() async {
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final assetPath = isWindows
        ? 'windows/runner/resources/app_icon.ico'
        : 'web/icons/Icon-512.png';
    final fileName = isWindows ? 'chuk_chat_tray.ico' : 'chuk_chat_tray.png';

    try {
      final iconBytes = await rootBundle.load(assetPath);
      final bytes = iconBytes.buffer.asUint8List(
        iconBytes.offsetInBytes,
        iconBytes.lengthInBytes,
      );

      final iconPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}$fileName';
      final iconFile = File(iconPath);
      await iconFile.writeAsBytes(bytes, flush: true);
      return iconFile.path;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Failed to load icon asset: $error');
      }

      if (defaultTargetPlatform == TargetPlatform.linux) {
        const fallbackIcon =
            '/usr/share/icons/hicolor/512x512/apps/chuk-chat.png';
        if (File(fallbackIcon).existsSync()) {
          return fallbackIcon;
        }
      }

      rethrow;
    }
  }

  Future<void> _syncWindowVisibility() async {
    try {
      _isWindowVisible = await windowManager.isVisible();
    } catch (_) {
      // Ignore visibility sync failures.
    }
  }

  Future<void> _updateMenu() async {
    if (!_isInitialized) return;

    await _syncWindowVisibility();

    final menu = Menu(
      items: [
        MenuItem(
          key: _kToggleWindowKey,
          label: _isWindowVisible ? 'Hide Chuk Chat' : 'Open Chuk Chat',
        ),
        MenuItem.separator(),
        MenuItem(key: _kQuitKey, label: 'Quit Chuk Chat'),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  Future<void> _toggleWindowVisibility() async {
    await _syncWindowVisibility();

    if (_isWindowVisible) {
      await hideWindow();
      return;
    }

    await showWindow();
  }

  Future<void> showWindow() async {
    if (!_isInitialized) return;

    await windowManager.show();
    await windowManager.focus();
    _isWindowVisible = true;
    await _updateMenu();
  }

  Future<void> hideWindow() async {
    if (!_isInitialized) return;

    await windowManager.hide();
    _isWindowVisible = false;
    await _updateMenu();
  }

  Future<void> _quitApplication() async {
    if (!_isInitialized) return;

    _isQuitting = true;

    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Error disabling prevent close: $error');
      }
    }

    try {
      await dispose(resetQuitFlag: false);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Error during quit dispose: $error');
      }
    } finally {
      await windowManager.destroy();
    }
  }

  Future<void> _rollbackInitialization() async {
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {
      // Ignore rollback failures.
    }

    try {
      windowManager.removeListener(this);
      await windowManager.setPreventClose(false);
    } catch (_) {
      // Ignore rollback failures.
    }

    _isInitialized = false;
    _isQuitting = false;
  }

  @override
  void onTrayIconMouseDown() {
    if (!_isInitialized) return;
    unawaited(_toggleWindowVisibility());
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_isInitialized || defaultTargetPlatform == TargetPlatform.linux) {
      return;
    }
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!_isInitialized) return;

    switch (menuItem.key) {
      case _kToggleWindowKey:
        unawaited(_toggleWindowVisibility());
        break;
      case _kQuitKey:
        unawaited(_quitApplication());
        break;
    }
  }

  @override
  void onWindowClose() {
    if (!_isInitialized || _isQuitting) return;
    unawaited(hideWindow());
  }

  Future<void> dispose({bool resetQuitFlag = true}) async {
    if (!_isInitialized) return;

    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Error destroying tray: $error');
      }
    }

    try {
      windowManager.removeListener(this);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[SystemTrayService] Error removing window listener: $error',
        );
      }
    }

    _isInitialized = false;
    _isWindowVisible = true;
    if (resetQuitFlag) {
      _isQuitting = false;
    }
  }
}
