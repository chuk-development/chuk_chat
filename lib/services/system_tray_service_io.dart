// lib/services/system_tray_service_io.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/tray_action_bus.dart';
import 'package:chuk_chat/services/tray_menu_model.dart';

/// Desktop system tray integration for Linux, Windows, and macOS.
///
/// Closing the window hides the app to tray instead of exiting. The menu
/// content comes from [buildTrayMenu]; this class only draws it natively and
/// rebuilds it when the window, the chats, the locale or the app mode change.
class SystemTrayService with WindowListener {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  // Native handles. A TrayIcon that is garbage-collected removes the icon, so
  // every handle is held here until [dispose].
  TrayIcon? _trayIcon;
  Image? _iconImage;
  Menu? _menu;
  final List<MenuItem> _menuItems = <MenuItem>[];

  /// The Agents build's Chats/Agents state, set by the app before the tray
  /// starts. Null in the plain build.
  AppModeService? _appMode;
  StreamSubscription<String?>? _chatChanges;
  Timer? _menuRebuildDebounce;
  String? _menuLocale;
  static const Duration _kMenuRebuildDelay = Duration(milliseconds: 400);

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

      // The trigger also decides whether the menu exists at all on Linux:
      // nativeapi exports the dbusmenu to the StatusNotifierItem host only
      // when the trigger is clicked or rightClicked. With the default (none)
      // the item announces "/NO_DBUSMENU" and the panel shows an empty menu.
      // rightClicked keeps the primary click free for "show the window".
      trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      trayIcon.addListener(_onTrayIconEvent);
      trayIcon.setVisible(true);
      _isInitialized = true;
      _linuxRetryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;

      await _syncWindowVisibility();
      _rebuildMenu();
      _startMenuSources();

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

  /// Gives the tray the Agents build's Chats/Agents state. Call before or
  /// after [initialize]; the menu follows the mode from then on.
  void attachAppMode(AppModeService appMode) {
    if (identical(_appMode, appMode)) return;
    _appMode?.removeListener(_scheduleMenuRebuild);
    _appMode = appMode;
    appMode.addListener(_scheduleMenuRebuild);
    _scheduleMenuRebuild();
  }

  void _startMenuSources() {
    _chatChanges ??= ChatStorageService.changes.listen(
      (_) => _scheduleMenuRebuild(),
    );
    AppThemeService.instance.removeListener(_onThemeServiceChanged);
    AppThemeService.instance.addListener(_onThemeServiceChanged);
  }

  void _stopMenuSources() {
    _menuRebuildDebounce?.cancel();
    _menuRebuildDebounce = null;
    unawaited(_chatChanges?.cancel());
    _chatChanges = null;
    AppThemeService.instance.removeListener(_onThemeServiceChanged);
  }

  // The theme service notifies for every look setting; only a new UI
  // language changes the menu.
  void _onThemeServiceChanged() {
    if (AppThemeService.instance.uiLocale != _menuLocale) {
      _scheduleMenuRebuild();
    }
  }

  /// Rebuilds the menu after [_kMenuRebuildDelay] of quiet, so a sync that
  /// touches fifty chats rebuilds it once.
  void _scheduleMenuRebuild() {
    if (!_isInitialized) return;
    _menuRebuildDebounce?.cancel();
    _menuRebuildDebounce = Timer(_kMenuRebuildDelay, () {
      _menuRebuildDebounce = null;
      _rebuildMenu();
    });
  }

  /// Draws [buildTrayMenu] as a native menu and swaps it in. The old handles
  /// are released only after the new menu is set, so the tray is never left
  /// without one.
  void _rebuildMenu() {
    final TrayIcon? trayIcon = _trayIcon;
    if (trayIcon == null) return;

    final String locale = AppThemeService.instance.uiLocale;
    final AppModeService? appMode = _appMode;
    final List<TrayMenuEntry> entries = buildTrayMenu(
      l: AppLocalizations(Locale(locale)),
      chats: ChatStorageService.savedChats,
      windowVisible: _isWindowVisible,
      agentsBuild: kFeatureAgents && appMode != null,
      agentsInFront: appMode?.value == AppMode.agents,
    );

    final menu = Menu.create();
    if (menu == null) {
      throw StateError('Unable to create tray menu');
    }
    final List<MenuItem> items = <MenuItem>[];
    for (final TrayMenuEntry entry in entries) {
      if (entry.isSeparator) {
        menu.addSeparator();
        continue;
      }
      final bool isChoice =
          entry.action == TrayMenuAction.showChats ||
          entry.action == TrayMenuAction.showAgents;
      final item = MenuItem.createWithLabelAndType(
        entry.label,
        isChoice ? MenuItemType.radio : MenuItemType.normal,
      );
      if (item == null) {
        throw StateError('Unable to create tray menu item "${entry.label}"');
      }
      if (isChoice) {
        item.radioGroup = 1;
        item.state = entry.checked
            ? MenuItemState.checked
            : MenuItemState.unchecked;
      }
      if (!entry.enabled) item.isEnabled = false;
      item.addListener((event) {
        if (event is MenuItemClickedEvent && _isInitialized) {
          unawaited(_runMenuAction(entry));
        }
      });
      menu.addItem(item);
      items.add(item);
    }

    trayIcon.setContextMenu(menu);
    _menuLocale = locale;

    final Menu? oldMenu = _menu;
    final List<MenuItem> oldItems = List<MenuItem>.of(_menuItems);
    _menu = menu;
    _menuItems
      ..clear()
      ..addAll(items);
    for (final item in oldItems) {
      item.dispose();
    }
    oldMenu?.dispose();
  }

  Future<void> _runMenuAction(TrayMenuEntry entry) async {
    switch (entry.action) {
      case TrayMenuAction.newChat:
        await _startNewChat();
      case TrayMenuAction.openChat:
        final String? chatId = entry.chatId;
        if (chatId == null) return;
        _selectMode(AppMode.chats);
        await showWindow();
        TrayActionBus.instance.requestOpenChat(chatId);
      case TrayMenuAction.showChats:
        _selectMode(AppMode.chats);
        await showWindow();
      case TrayMenuAction.showAgents:
        _selectMode(AppMode.agents);
        await showWindow();
      case TrayMenuAction.toggleWindow:
        await _toggleWindowVisibility();
      case TrayMenuAction.settings:
        // Settings is drawn by chuk_chat's half, so bring that one forward.
        _selectMode(AppMode.chats);
        await showWindow();
        TrayActionBus.instance.requestSettings();
      case TrayMenuAction.quit:
        await _quitApplication();
      case null:
        return;
    }
  }

  void _selectMode(AppMode mode) {
    final AppModeService? appMode = _appMode;
    if (appMode != null) unawaited(appMode.select(mode));
  }

  void _setWindowVisible(bool visible) {
    if (_isWindowVisible == visible) return;
    _isWindowVisible = visible;
    _scheduleMenuRebuild();
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
    _setWindowVisible(true);
  }

  Future<void> hideWindow() async {
    if (!_isInitialized) return;

    await windowManager.hide();
    _setWindowVisible(false);
  }

  /// Brings the window to the front, then asks the running UI to start a fresh
  /// chat. The tray has no [BuildContext], so the actual new-chat action is
  /// performed by the desktop root wrapper listening on [TrayActionBus].
  Future<void> _startNewChat() async {
    _selectMode(AppMode.chats);
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
      // destroy() closes the window; if the engine keeps the process alive
      // (a plugin holding the main loop), end it so Quit always quits.
      Timer(const Duration(seconds: 2), () => exit(0));
    }
  }

  Future<void> _rollbackInitialization() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopMenuSources();

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
    // A primary click shows and focuses the window, as in the ChatGPT and
    // Claude apps. GNOME's AppIndicator extension opens the menu on a single
    // click itself and reports a double click, so take that too.
    if (event is TrayIconClickedEvent || event is TrayIconDoubleClickedEvent) {
      unawaited(showWindow());
    }
  }

  @override
  void onWindowEvent(String eventName) {
    if (!_isInitialized) return;
    if (eventName == 'show' || eventName == 'restore' || eventName == 'focus') {
      _setWindowVisible(true);
    } else if (eventName == 'hide' || eventName == 'minimize') {
      _setWindowVisible(false);
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

    _stopMenuSources();
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
