// lib/services/system_tray_service_io.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chuk_chat/services/diagnostics_log_service.dart';

/// Desktop system tray integration for Linux, Windows, and macOS.
///
/// Closing the window hides the app to tray instead of exiting.
class SystemTrayService with TrayListener, WindowListener {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  static const String _kToggleWindowKey = 'toggle_window';
  static const String _kQuitKey = 'quit';

  bool _isInitialized = false;
  bool _isInitializing = false;
  bool _isWindowVisible = true;
  bool _isQuitting = false;
  int _linuxRetryAttempts = 0;
  Timer? _retryTimer;
  static const int _kMaxLinuxRetryAttempts = 3;
  static const Duration _kLinuxRetryBaseDelay = Duration(seconds: 3);

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
    if (!_isDesktop || _isInitialized || _isInitializing) return;
    _isInitializing = true;

    try {
      await DiagnosticsLogService.info(
        'tray',
        'Initializing system tray',
        data: {'platform': defaultTargetPlatform.name},
      );

      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      final iconPath = await _setTrayIconWithFallback();

      if (_supportsTooltip) {
        await trayManager.setToolTip('Chuk Chat');
      }

      trayManager.addListener(this);
      _isInitialized = true;
      _linuxRetryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;

      await _syncWindowVisibility();
      await _updateMenu();

      await DiagnosticsLogService.info(
        'tray',
        'System tray initialized',
        data: {'icon_path': iconPath},
      );

      if (kDebugMode) {
        debugPrint('[SystemTrayService] Initialized');
      }
    } catch (error) {
      await DiagnosticsLogService.error(
        'tray',
        'System tray initialization failed',
        error: error,
      );
      if (kDebugMode) {
        debugPrint('[SystemTrayService] Failed to initialize: $error');
      }
      await _rollbackInitialization();
      _scheduleRetry();
    } finally {
      _isInitializing = false;
    }
  }

  void _scheduleRetry() {
    if (defaultTargetPlatform != TargetPlatform.linux) return;
    if (_retryTimer != null || _isInitialized) return;
    if (_linuxRetryAttempts >= _kMaxLinuxRetryAttempts) return;

    _linuxRetryAttempts += 1;
    final delay = Duration(
      seconds: _kLinuxRetryBaseDelay.inSeconds * _linuxRetryAttempts,
    );

    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_isInitialized || _isInitializing) return;
      unawaited(initialize());
    });
  }

  Future<String> _setTrayIconWithFallback() async {
    final candidates = await _resolveTrayIconCandidates();
    Object? lastError;

    for (final iconPath in candidates) {
      try {
        await trayManager.setIcon(iconPath);
        return iconPath;
      } catch (error) {
        lastError = error;
        await DiagnosticsLogService.warning(
          'tray',
          'Tray icon candidate failed',
          data: {'icon_path': iconPath, 'error': error.toString()},
        );
      }
    }

    throw StateError('Unable to set tray icon. Last error: $lastError');
  }

  Future<List<String>> _resolveTrayIconCandidates() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      final candidates = <String>[];
      for (final candidate in _linuxTrayFallbackCandidates) {
        if (File(candidate).existsSync()) {
          candidates.add(candidate);
        }
      }

      // Last resort: use icon theme name so Linux can resolve from hicolor.
      if (candidates.isEmpty) {
        return const <String>['chuk-chat', 'application-default-icon'];
      }
      return candidates.toSet().toList(growable: false);
    }

    final bundledIcon = await _materializeBundledTrayIcon();
    if (bundledIcon == null) {
      throw StateError('No tray icon candidates available');
    }
    return <String>[bundledIcon];
  }

  Future<String?> _materializeBundledTrayIcon() async {
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
      await DiagnosticsLogService.warning(
        'tray',
        'Primary tray icon asset load failed',
        data: {'asset_path': assetPath, 'error': error.toString()},
      );

      if (kDebugMode) {
        debugPrint('[SystemTrayService] Failed to load icon asset: $error');
      }

      return null;
    }
  }

  List<String> get _linuxTrayFallbackCandidates {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    return <String>[
      '$executableDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}icons${Platform.pathSeparator}chuk_chat_tray_brand.png',
      '$executableDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}web${Platform.pathSeparator}icons${Platform.pathSeparator}Icon-512.png',
      '/opt/chuk-chat/data/flutter_assets/assets/icons/chuk_chat_tray_brand.png',
      '/opt/chuk-chat/data/flutter_assets/web/icons/Icon-512.png',
      '/usr/share/icons/hicolor/256x256/apps/chuk-chat.png',
      '/usr/share/icons/hicolor/512x512/apps/chuk-chat.png',
      '/usr/share/pixmaps/chuk-chat.png',
    ];
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
    _retryTimer?.cancel();
    _retryTimer = null;

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
    if (defaultTargetPlatform == TargetPlatform.linux) {
      // Linux AppIndicator shells often map left click to menu behavior.
      // Keep hide/show controlled via the explicit tray menu item.
      return;
    }
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
    _retryTimer?.cancel();
    _retryTimer = null;

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
