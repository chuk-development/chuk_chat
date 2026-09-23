// lib/services/system_tray_service_io.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/tray_action_bus.dart';

/// Desktop system tray integration for Linux, Windows, and macOS.
///
/// Closing the window hides the app to tray instead of exiting.
class SystemTrayService with WindowListener {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  // Native handles. A TrayIcon that is garbage-collected removes the icon, so
  // every handle is held here until [dispose].
  TrayIcon? _trayIcon;
  Image? _iconImage;
  Menu? _menu;
  final List<MenuItem> _menuItems = <MenuItem>[];

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
    if (!kFeatureSystemTray) {
      return;
    }
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

      final trayIcon = TrayIcon.create();
      if (trayIcon == null) {
        throw StateError('Unable to create tray icon');
      }
      _trayIcon = trayIcon;

      final iconPath = await _setTrayIconWithFallback(trayIcon);

      if (_supportsTooltip) {
        trayIcon.setTooltip('Chuk Chat');
      }

      // Linux reports no tray icon clicks: the panel keeps them and opens the
      // context menu itself. Elsewhere a left click toggles the window and a
      // right click opens the menu.
      if (defaultTargetPlatform != TargetPlatform.linux) {
        trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      }
      trayIcon.addListener(_onTrayIconEvent);
      trayIcon.setVisible(true);
      _isInitialized = true;
      _linuxRetryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;

      await _syncWindowVisibility();
      // Install the same context menu on every desktop platform. The labels
      // are static (they do not depend on window visibility), so a single
      // install works everywhere — including the Linux StatusNotifierItem,
      // whose panel opens the menu on click and reports no click event.
      _installMenu(trayIcon);

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

  Future<String> _setTrayIconWithFallback(TrayIcon trayIcon) async {
    final candidates = await _resolveTrayIconCandidates();

    for (final iconPath in candidates) {
      final image = Image.fromFile(iconPath);
      if (image == null) {
        await DiagnosticsLogService.warning(
          'tray',
          'Tray icon candidate failed',
          data: {'icon_path': iconPath},
        );
        continue;
      }
      trayIcon.icon = image;
      _iconImage?.dispose();
      _iconImage = image;
      return iconPath;
    }

    throw StateError(
      'Unable to set tray icon from ${candidates.length} candidates',
    );
  }

  Future<List<String>> _resolveTrayIconCandidates() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      final candidates = <String>[];
      final bundledIcon = await _materializeBundledTrayIcon();
      if (bundledIcon != null) {
        candidates.add(bundledIcon);
      }
      for (final candidate in _linuxTrayFallbackCandidates) {
        if (File(candidate).existsSync()) {
          candidates.add(candidate);
        }
      }

      if (candidates.isEmpty) {
        throw StateError('No tray icon candidates available');
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
    final fileName = isWindows
        ? 'chuk_chat_tray.ico'
        : 'chuk_chat_tray_color.png';

    try {
      ByteData iconBytes;
      iconBytes = await rootBundle.load(assetPath);
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
      '$executableDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}web${Platform.pathSeparator}icons${Platform.pathSeparator}Icon-512.png',
      '/opt/chuk-chat/data/flutter_assets/web/icons/Icon-512.png',
      '$executableDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}icons${Platform.pathSeparator}chuk_chat_tray_brand.png',
      '/opt/chuk-chat/data/flutter_assets/assets/icons/chuk_chat_tray_brand.png',
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

  void _installMenu(TrayIcon trayIcon) {
    final menu = Menu.create();
    if (menu == null) {
      throw StateError('Unable to create tray menu');
    }

    void addItem(String label, Future<void> Function() onClick) {
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) {
        throw StateError('Unable to create tray menu item "$label"');
      }
      item.addListener((event) {
        if (event is MenuItemClickedEvent && _isInitialized) {
          unawaited(onClick());
        }
      });
      menu.addItem(item);
      _menuItems.add(item);
    }

    addItem('Open Chuk Chat', showWindow);
    addItem('New Chat', _startNewChat);
    menu.addSeparator();
    addItem('Quit Chuk Chat', _quitApplication);

    trayIcon.setContextMenu(menu);
    _menu = menu;
  }

  /// Releases every native tray handle. Safe to call when none exist.
  void _destroyTray() {
    final trayIcon = _trayIcon;
    _trayIcon = null;
    if (trayIcon != null) {
      trayIcon.setVisible(false);
      trayIcon.setContextMenu(null);
      trayIcon.dispose();
    }
    for (final item in _menuItems) {
      item.dispose();
    }
    _menuItems.clear();
    _menu?.dispose();
    _menu = null;
    _iconImage?.dispose();
    _iconImage = null;
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
  }

  Future<void> hideWindow() async {
    if (!_isInitialized) return;

    await windowManager.hide();
    _isWindowVisible = false;
  }

  /// Brings the window to the front, then asks the running UI to start a fresh
  /// chat. The tray has no [BuildContext], so the actual new-chat action is
  /// performed by the desktop root wrapper listening on [TrayActionBus].
  Future<void> _startNewChat() async {
    await showWindow();
    TrayActionBus.instance.requestNewChat();
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
      _destroyTray();
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

  void _onTrayIconEvent(TrayIconEvent event) {
    if (!_isInitialized) return;
    if (event is TrayIconClickedEvent) {
      unawaited(_toggleWindowVisibility());
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
      _destroyTray();
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
