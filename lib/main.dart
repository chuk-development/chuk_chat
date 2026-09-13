import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart'
    show initChatStorageCache;
import 'package:chuk_chat/services/settings/theme_controller.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/session_recovery.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_storage_bootstrap.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/app_lifecycle_observer.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bead cowork-2n1: an expired persisted session is set aside BEFORE gotrue
  // sees it. Refreshing it blindly would fail (and log the user out) when the
  // paired host rotated the pair while the app was away; AuthGate recovers
  // the session through the host instead.
  await SessionStash.setAsideExpiredSession();
  await SupabaseService.initialize();
  // Chat storage as in chuk_chat (bead cowork-sha): pre-warm the preferences
  // the sidebar-title cache reads, then follow the auth session to load the
  // local chat cache and start the cloud sync.
  await initChatStorageCache();
  AgentsChatStorageBootstrap.start();
  // Load the verbose-view flag once at startup, so the first frame shows the
  // right view. The service is safe to read before this, but an early load
  // avoids a flip on the first paint.
  await VerboseService.instance.load();
  // WS-7: "answer ready" toasts (local plugin, Linux included) and the push
  // token row. Best-effort: without Firebase keys push stays off, the app is
  // unchanged.
  unawaited(AgentsNotifications.instance.initialize());
  runApp(const AgentsApp());
}

class AgentsApp extends StatefulWidget {
  const AgentsApp({super.key});

  @override
  State<AgentsApp> createState() => _AgentsAppState();
}

class _AgentsAppState extends State<AgentsApp> {
  /// The single source of truth for theme, accent, fonts, UI scale and the
  /// customization switches — chuk_chat's service, imported verbatim.
  final AppThemeService _themeService = AppThemeService.instance;

  /// Kept alive only as a bridge: the settings pages that are still Agents's
  /// own (`settings_page`, `theme_settings_page`) read and write the theme
  /// through this notifier. It is fed from [_themeService] in both directions,
  /// so either surface can drive the theme.
  // TODO(WS-2): delete `services/settings/theme_controller.dart` with the old
  // settings pages, once chuk_chat's `theme_page` replaces them.
  final ThemeController _theme = ThemeController();

  /// Guards the two-way bridge against feeding a change straight back.
  bool _bridging = false;

  @override
  void initState() {
    super.initState();
    _themeService.addListener(_onThemeServiceChanged);
    _theme.addListener(_onThemeControllerChanged);
    _bootstrapTheme();
  }

  @override
  void dispose() {
    _themeService.removeListener(_onThemeServiceChanged);
    _theme.removeListener(_onThemeControllerChanged);
    _theme.dispose();
    super.dispose();
  }

  Future<void> _bootstrapTheme() async {
    await _themeService.loadFromPrefs();
    await _migrateLegacyThemeMode();
    // Pull the cross-device values in the background; the local prefs already
    // painted the first frame.
    unawaited(_themeService.loadFromSupabaseAsync());
    _pushServiceIntoController();
    if (mounted) setState(() {});
  }

  /// One-shot migration off Agents's own `theme_mode_v1` preference.
  ///
  /// The old key holds a [ThemeMode] name (`system` / `light` / `dark`).
  /// [AppThemeService] stores a [Brightness], so `system` is resolved once
  /// against the platform brightness at migration time. The key is deleted
  /// afterwards so the migration never runs twice.
  Future<void> _migrateLegacyThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const legacyKey = 'theme_mode_v1';
      final raw = prefs.getString(legacyKey);
      if (raw == null) return;

      final Brightness resolved;
      switch (raw) {
        case 'light':
          resolved = Brightness.light;
        case 'dark':
          resolved = Brightness.dark;
        default:
          resolved = PlatformDispatcher.instance.platformBrightness;
      }
      _themeService.setThemeMode(resolved);
      await prefs.remove(legacyKey);
    } catch (_) {
      // A failed migration just leaves the imported default in place.
    }
  }

  void _onThemeServiceChanged() {
    _pushServiceIntoController();
    if (mounted) setState(() {});
  }

  void _pushServiceIntoController() {
    final mode = _themeService.themeMode == Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light;
    if (_theme.value == mode) return;
    _bridging = true;
    _theme.value = mode;
    _bridging = false;
  }

  void _onThemeControllerChanged() {
    if (_bridging) return;
    final brightness = switch (_theme.value) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => PlatformDispatcher.instance.platformBrightness,
    };
    if (_themeService.themeMode == brightness) return;
    _themeService.setThemeMode(brightness);
  }

  @override
  Widget build(BuildContext context) {
    // DynamicColorBuilder exposes the platform's Material You palette (when
    // available) and rebuilds automatically when the system colours change,
    // so the app follows wallpaper/accent changes live when the user has
    // enabled dynamic colour.
    // The app-level lifecycle wire. The imported chat UI registers resume and
    // pause callbacks on `AppLifecycleService`, and nothing in Agents ever
    // called `handleLifecycleState` — no widget observed the binding at app
    // level, so those callbacks never fired. chuk_chat does this from its own
    // `main.dart`; Agents does it here.
    return AppLifecycleObserver(
      child: DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
          // chuk_chat hands its shell config straight to the shell
          // (`RootWrapper(config: …)`); so does Agents, through AuthGate's shell
          // builder (bead cowork-8y2). Rebuilt with the app, so a theme change
          // reaches the shell like any other rebuild.
          final AppShellConfig shellConfig = _buildShellConfig();
          return MaterialApp(
            title: 'Chuk Chat',
            debugShowCheckedModeBanner: false,
            theme: _themeService.buildTheme(
              lightDynamic: lightDynamic,
              darkDynamic: darkDynamic,
            ),
            locale: Locale(_themeService.uiLocale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) {
              if (child == null) return const SizedBox.shrink();

              // Apply user-chosen UI scale to all text in the app via MediaQuery.
              // This is the safest scaling approach — it doesn't break layout
              // calculations the way Transform.scale would.
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(_themeService.uiScale),
                ),
                child: child,
              );
            },
            home: AuthGate(
              themeController: _theme,
              buildShell: (_) => MessengerShell(
                themeController: _theme,
                shellConfig: shellConfig,
              ),
            ),
          );
        },
      ),
    );
  }

  AppShellConfig _buildShellConfig() {
    return AppShellConfig(
      currentThemeMode: _themeService.themeMode,
      currentAccentColor: _themeService.accentColor,
      currentIconFgColor: _themeService.iconFgColor,
      currentBgColor: _themeService.bgColor,
      setThemeMode: _themeService.setThemeMode,
      setAccentColor: _themeService.setAccentColor,
      setIconFgColor: _themeService.setIconFgColor,
      setBgColor: _themeService.setBgColor,
      dynamicColorEnabled: _themeService.dynamicColorEnabled,
      setDynamicColorEnabled: _themeService.setDynamicColorEnabled,
      contrast: _themeService.contrast,
      setContrast: _themeService.setContrast,
      uiFontFamily: _themeService.uiFontFamily,
      setUiFontFamily: _themeService.setUiFontFamily,
      showReasoningTokens: _themeService.showReasoningTokens,
      setShowReasoningTokens: _themeService.setShowReasoningTokens,
      showModelInfo: _themeService.showModelInfo,
      setShowModelInfo: _themeService.setShowModelInfo,
      showTps: _themeService.showTps,
      setShowTps: _themeService.setShowTps,
      autoSendVoiceTranscription: _themeService.autoSendVoiceTranscription,
      setAutoSendVoiceTranscription:
          _themeService.setAutoSendVoiceTranscription,
      imageGenEnabled: _themeService.imageGenEnabled,
      setImageGenEnabled: _themeService.setImageGenEnabled,
      imageGenDefaultSize: _themeService.imageGenDefaultSize,
      setImageGenDefaultSize: _themeService.setImageGenDefaultSize,
      imageGenCustomWidth: _themeService.imageGenCustomWidth,
      setImageGenCustomWidth: _themeService.setImageGenCustomWidth,
      imageGenCustomHeight: _themeService.imageGenCustomHeight,
      setImageGenCustomHeight: _themeService.setImageGenCustomHeight,
      imageGenUseCustomSize: _themeService.imageGenUseCustomSize,
      setImageGenUseCustomSize: _themeService.setImageGenUseCustomSize,
      includeRecentImagesInHistory: _themeService.includeRecentImagesInHistory,
      setIncludeRecentImagesInHistory:
          _themeService.setIncludeRecentImagesInHistory,
      includeAllImagesInHistory: _themeService.includeAllImagesInHistory,
      setIncludeAllImagesInHistory: _themeService.setIncludeAllImagesInHistory,
      includeReasoningInHistory: _themeService.includeReasoningInHistory,
      setIncludeReasoningInHistory: _themeService.setIncludeReasoningInHistory,
      includeToolResultsInHistory: _themeService.includeToolResultsInHistory,
      setIncludeToolResultsInHistory:
          _themeService.setIncludeToolResultsInHistory,
      toolCallingEnabled: _themeService.toolCallingEnabled,
      setToolCallingEnabled: _themeService.setToolCallingEnabled,
      toolDiscoveryMode: _themeService.toolDiscoveryMode,
      setToolDiscoveryMode: _themeService.setToolDiscoveryMode,
      showToolCalls: _themeService.showToolCalls,
      setShowToolCalls: _themeService.setShowToolCalls,
      uiLocale: _themeService.uiLocale,
      setUiLocale: _themeService.setUiLocale,
      chatFontSize: _themeService.chatFontSize,
      setChatFontSize: _themeService.setChatFontSize,
      chatFontFamily: _themeService.chatFontFamily,
      setChatFontFamily: _themeService.setChatFontFamily,
      uiScale: _themeService.uiScale,
      setUiScale: _themeService.setUiScale,
    );
  }
}
