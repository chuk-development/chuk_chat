// lib/main.dart
//
// Merge note (Agents into chuk_chat). Both sides had written their own app
// entry, so this file is neither side's copy: it is upstream's startup with
// the Agents startup and the Agents home grafted onto it.
//   * upstream keeps: the log deduper, certificate pinning, the offline retry
//     manager, the window-close handler, developer options, diagnostics, the
//     core-service init, the session manager, the settings sync on resume and
//     at startup, the system tray, the completion notifications, the
//     onboarding gate, the navigator key and tour observer, ProviderScope,
//     and the dynamic_color 2.x `material_ui` conversion.
//   * Agents keeps: setting an expired session aside before gotrue sees it,
//     the awaited Supabase init, the local chat-storage bootstrap, the verbose
//     flag, its own notifications, the ThemeController bridge with the
//     `theme_mode_v1` migration, AppLifecycleObserver, and its AuthGate ->
//     MessengerShell home.
// One thing could not be kept as it stood, and is commented at its site: the
// app state's own WidgetsBindingObserver (AppLifecycleObserver does that job
// now, and registering both would fire every lifecycle callback twice).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dynamic_color/dynamic_color.dart';
// dynamic_color 2.x hands its DynamicColorBuilder callback a ColorScheme from
// the `material_ui` package, not Flutter's material ColorScheme. We only read
// primary/surface/onSurface downstream, so convert to a Flutter ColorScheme at
// the callsite and keep the rest of the app on the framework type.
import 'package:material_ui/material_ui.dart' as mui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/assistant/assistant_overlay.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/certificate_pinning_register.dart'
    as cert_register;
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/app_initialization_service.dart';
import 'package:chuk_chat/services/app_lifecycle_service.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';
import 'package:chuk_chat/services/onboarding_tour_controller.dart';
import 'package:chuk_chat/services/session_manager_service.dart';
import 'package:chuk_chat/services/session_recovery.dart';
import 'package:chuk_chat/services/settings/theme_controller.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/settings_sync_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_storage_bootstrap.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/system_tray_service.dart';
import 'package:chuk_chat/services/window_close_service.dart';
import 'package:chuk_chat/widgets/app_lifecycle_observer.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';

/// Collapse consecutive identical debug log lines into a single line with a
/// `(×N)` count, so spammy repeats (e.g. "[Lifecycle] App resumed" firing
/// dozens of times) don't drown the console. Debug-only — release builds emit
/// no logs at all. Wraps (not replaces) the throttling default so throttling
/// is preserved.
void _installLogDeduper() {
  final original = debugPrint;
  String? lastMessage;
  int repeatCount = 0;
  Timer? flushTimer;

  void flush() {
    flushTimer?.cancel();
    flushTimer = null;
    if (repeatCount > 1 && lastMessage != null) {
      original('$lastMessage  (×$repeatCount)');
    }
    repeatCount = 0;
  }

  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message == lastMessage) {
      // Suppress the duplicate; schedule a trailing flush so the final count
      // still prints even when no different line follows.
      repeatCount++;
      flushTimer?.cancel();
      flushTimer = Timer(const Duration(milliseconds: 250), flush);
      return;
    }
    flush();
    lastMessage = message;
    repeatCount = 1;
    original(message, wrapWidth: wrapWidth);
  };
}

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Dedupe spammy repeated log lines (debug only).
  if (kDebugMode) {
    _installLogDeduper();
  }

  // Register certificate pinning for native platforms.
  // On web this is a no-op (browser handles TLS).
  cert_register.registerCertificatePinning();

  // Log which API server we're targeting (only visible in debug builds)
  if (kDebugMode) {
    debugPrint('[API] Using server: ${ApiConfigService.apiBaseUrl}');
  }

  // Bead cowork-2n1: an expired persisted session is set aside BEFORE gotrue
  // sees it. Refreshing it blindly would fail (and log the user out) when the
  // paired host rotated the pair while the app was away; AuthGate recovers
  // the session through the host instead. Must run before any Supabase init.
  // Agents only: without a paired host there is nobody to recover through,
  // and upstream chuk_chat lets gotrue refresh the expired session itself.
  if (kFeatureAgents) await SessionStash.setAsideExpiredSession();

  // Agents awaits the Supabase init here so the stash decision above is in
  // force before the first frame. The call is idempotent, so upstream's
  // background `initializeCoreServices()` below still does the rest of its
  // work (model capabilities, encryption key preload) and just skips this.
  //
  // This await is also what lets the merged app keep ONE auth gate. Upstream's
  // gate began with `AppInitializationService.waitForSupabase()` because its
  // main() started Supabase unawaited, so the gate could mount before there
  // was an auth client to read; the Agents gate reads
  // `SupabaseService.isInitialized` once in initState and would take "not
  // ready" for "signed out". Initialising before runApp removes that window,
  // so the Agents gate is safe here and keeps its own extra behaviour (the
  // expired-pair recovery above).
  //
  // The failure mode upstream's gate also covered — Supabase never comes up,
  // e.g. a build with no credentials — is covered by this catch instead: the
  // app still starts, and the gate finds no session and shows the login page,
  // which is exactly what upstream's `ready == false` branch did. Crashing
  // here would leave a black app.
  try {
    await SupabaseService.initialize();
  } catch (error) {
    if (kDebugMode) {
      debugPrint('⚠️ [Main] Supabase init failed: $error');
    }
  }

  // Keep chat storage cache deterministic to avoid early access races.
  await initChatStorageCache();

  // Chat storage as in chuk_chat (bead cowork-sha): follow the auth session to
  // load the local chat cache and start the cloud sync. Agents only: with the
  // flag off upstream's SessionManager / AppInitializationService do this,
  // and upstream's main has no such call.
  if (agentsChatCore) AgentsChatStorageBootstrap.start();

  // Load the verbose-view flag once at startup, so the first frame shows the
  // right view. The service is safe to read before this, but an early load
  // avoids a flip on the first paint.
  await VerboseService.instance.load();

  // Persistent offline queue + retry manager. Await init before wiring
  // retry/executor so the drain loop never observes an uninitialized queue.
  // If queue init fails, skip retry/executor entirely.
  var offlineQueueReady = false;
  try {
    await OfflineQueueService.instance.init();
    offlineQueueReady = true;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('⚠️ [Main] Offline queue init failed: $error');
    }
  }
  if (offlineQueueReady) {
    OfflineRetryManager.instance.init();
    OfflineSendExecutor.register();
  }

  // Ensure clean window close on Linux desktop (see window_close_service_io.dart).
  unawaited(initializeWindowCloseHandler());

  // Non-critical startup work can run in background.
  unawaited(
    DeveloperOptionsService.initialize().catchError((error) {
      if (kDebugMode) {
        debugPrint('⚠️ [Main] Developer options init failed: $error');
      }
    }),
  );
  unawaited(
    DiagnosticsLogService.initialize().catchError((error) {
      if (kDebugMode) {
        debugPrint('⚠️ [Main] Diagnostics init failed: $error');
      }
    }),
  );
  unawaited(
    DiagnosticsLogService.info(
      'startup',
      'App main() started',
      data: {
        'platform': defaultTargetPlatform.name,
        'release_mode': kReleaseMode,
      },
    ),
  );

  // WS-7: "answer ready" toasts (local plugin, Linux included) and the push
  // token row. Best-effort: without Firebase keys push stays off, the app is
  // unchanged.
  unawaited(AgentsNotifications.instance.initialize());

  // Initialize core services (model capabilities, encryption preload, …) in
  // background.
  unawaited(AppInitializationService.instance.initializeCoreServices());

  // Use default theme immediately - load preferences async after first frame.
  // ProviderScope hosts the Riverpod container for the chat runtime / streaming
  // state introduced by the chat-UI performance re-architecture.
  runApp(const ProviderScope(child: AgentsApp()));
}

class AgentsApp extends StatefulWidget {
  const AgentsApp({super.key});

  @override
  State<AgentsApp> createState() => _AgentsAppState();
}

class _AgentsAppState extends State<AgentsApp> {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // Services
  /// The single source of truth for theme, accent, fonts, UI scale and the
  /// customization switches.
  final AppThemeService _themeService = AppThemeService.instance;
  final AppLifecycleService _lifecycleService = AppLifecycleService.instance;
  final SessionManagerService _sessionManager = SessionManagerService.instance;
  final AppInitializationService _initService =
      AppInitializationService.instance;

  /// Kept alive only as a bridge: the settings pages that are still Agents's
  /// own (`settings_page`, `theme_settings_page`) read and write the theme
  /// through this notifier. It is fed from [_themeService] in both directions,
  /// so either surface can drive the theme.
  // TODO(WS-2): delete `services/settings/theme_controller.dart` with the old
  // settings pages, once chuk_chat's `theme_page` replaces them.
  final ThemeController _theme = ThemeController();

  /// Guards the two-way bridge against feeding a change straight back.
  bool _bridging = false;

  late final DateTime _appStartedAt;
  Timer? _resumeSettingsSyncTimer;
  DateTime? _lastResumeSettingsSyncAt;
  static const Duration _linuxResumeSyncCooldown = Duration(seconds: 90);
  static const Duration _linuxResumeSyncDelay = Duration(seconds: 2);

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    _appStartedAt = DateTime.now();
    // Merge note: upstream made this state a WidgetsBindingObserver and fed
    // `handleLifecycleState` from `didChangeAppLifecycleState`. The Agents
    // side moved that wire into the AppLifecycleObserver widget in `build`
    // (testable without booting the app), so the state no longer observes the
    // binding itself — registering both would fire every callback twice.
    _lifecycleService.addOnResumeCallback(_syncSettingsInBackground);

    // Listen to theme changes
    _themeService.addListener(_onThemeChanged);
    _theme.addListener(_onThemeControllerChanged);

    // Initialize after first frame (session manager needs Supabase ready)
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeApp());
    // Delay tray setup slightly to avoid contending with first paint/startup.
    unawaited(_initializeDesktopTrayInBackground());
  }

  Future<void> _initializeDesktopTrayInBackground() async {
    try {
      if (!kFeatureSystemTray) {
        return;
      }
      if (_isLinuxDesktop) {
        await Future<void>.delayed(const Duration(seconds: 6));
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      if (!mounted) return;
      await SystemTrayService.instance.initialize();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [Main] System tray init failed: $error');
      }
    }
  }

  void _onThemeChanged() {
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

  void _onPasswordMismatch() {
    if (mounted) {
      // UI will automatically update via AuthGate
      if (kDebugMode) {
        debugPrint('🔐 [Main] Password mismatch - UI updating');
      }
    }
  }

  void _syncSettingsInBackground() {
    final now = DateTime.now();
    if (_isLinuxDesktop) {
      final uptime = DateTime.now().difference(_appStartedAt);
      // Avoid heavy settings pull during Linux startup warmup.
      if (uptime < const Duration(seconds: 20)) {
        return;
      }
      if (_lastResumeSettingsSyncAt != null &&
          now.difference(_lastResumeSettingsSyncAt!) <
              _linuxResumeSyncCooldown) {
        return;
      }

      _resumeSettingsSyncTimer?.cancel();
      _resumeSettingsSyncTimer = Timer(_linuxResumeSyncDelay, () {
        if (!mounted) return;
        _lastResumeSettingsSyncAt = DateTime.now();
        unawaited(
          SettingsSyncService.syncAllFromSupabase(
            forceRefresh: false,
          ).catchError((error) {
            if (kDebugMode) {
              debugPrint('⚠️ [Main] Settings background sync failed: $error');
            }
          }),
        );
      });
      return;
    }

    unawaited(
      SettingsSyncService.syncAllFromSupabase(forceRefresh: false).catchError((
        error,
      ) {
        if (kDebugMode) {
          debugPrint('⚠️ [Main] Settings background sync failed: $error');
        }
      }),
    );
  }

  void _scheduleStartupSettingsSync() {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 12), () async {
        if (!mounted) return;
        await SettingsSyncService.syncAllFromSupabase(forceRefresh: false);
      }).catchError((error) {
        if (kDebugMode) {
          debugPrint('⚠️ [Main] Startup settings sync failed: $error');
        }
      }),
    );
  }

  void _initializeNotificationsInBackground() {
    // Completion notifications are used on Android/iOS only.
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }

    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        if (!mounted) return;
        await NotificationService.initialize(navigatorKey);
        await NotificationService.checkLaunchNotification();
      }).catchError((error) {
        if (kDebugMode) {
          debugPrint('⚠️ [Main] Notification init failed: $error');
        }
      }),
    );
  }

  Future<void> _initializeApp() async {
    // Wait for Supabase to be ready
    await _initService.waitForSupabase();
    if (!mounted) return;

    // Load local theme FIRST so the UI has correct colors immediately.
    // This must complete BEFORE SessionManager subscribes to auth events,
    // because the initial auth event fires synchronously and triggers
    // loadFromSupabaseAsync() — which would race with loadFromPrefs().
    await _themeService.loadFromPrefs();
    // Agents's one-shot `theme_mode_v1` migration rides here, in the same
    // window: after the prefs are in, before anything cross-device lands.
    await _migrateLegacyThemeMode();
    if (!mounted) return;
    _pushServiceIntoController();

    // Initialize session manager now that Supabase is ready and local
    // theme is loaded. This subscribes to onAuthStateChange and handles
    // user session initialization (chat loading, sync, theme from Supabase).
    // Its auth event is what pulls the cross-device theme; Agents called
    // `loadFromSupabaseAsync()` here itself, which would now be a second,
    // racing pull of the same values.
    _sessionManager.initialize(onPasswordMismatch: _onPasswordMismatch);

    // Defer non-critical startup work so first interaction stays responsive.
    _scheduleStartupSettingsSync();
    _initializeNotificationsInBackground();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _resumeSettingsSyncTimer?.cancel();
    _lifecycleService.removeOnResumeCallback(_syncSettingsInBackground);
    _themeService.removeListener(_onThemeChanged);
    _theme.removeListener(_onThemeControllerChanged);
    _theme.dispose();
    _lifecycleService.dispose();
    _sessionManager.dispose();
    _themeService.dispose();
    unawaited(SystemTrayService.instance.dispose());
    super.dispose();
  }

  /// True when this Flutter engine was started by the Android assist
  /// activity rather than the launcher.
  ///
  /// Each `FlutterActivity` gets its own engine and root isolate, so this is
  /// per-activity even though both live in one process.
  bool get _isAssistantLaunch =>
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
      assistantOverlayRouteName;

  /// The app home: auth gate, onboarding gate, then the shell.
  ///
  /// Two merge decisions live here.
  ///
  /// The gate: one gate, the Agents one. Upstream's gate did two things —
  /// wait for a background Supabase init before reading the session, and show
  /// the signed-out UI when that init failed. main() now awaits the init (and
  /// catches its failure), so neither is left for the gate to do, and the
  /// Agents gate adds the expired-pair recovery on top. A user with no host
  /// paired is unaffected: with nothing set aside the gate reads gotrue and
  /// goes straight to the shell or the login page, and if their stored session
  /// HAD expired the recovery finds no pairing, refreshes the stored token
  /// against gotrue directly — what gotrue would have done anyway — and falls
  /// through to the login page when gotrue refuses it. No host is ever
  /// required to reach the app.
  ///
  /// The shell: Agents's MessengerShell when the app is built with
  /// `--dart-define=FEATURE_AGENTS=true`, upstream's RootWrapper otherwise —
  /// the split the runbook asks for. The onboarding tour is chuk_chat's and
  /// walks chuk_chat's screens; the Agents app never had one, so it wraps only
  /// the chuk_chat shell.
  Widget _buildHome(AppShellConfig shellConfig) => AuthGate(
    themeController: _theme,
    buildLogin: (_) => const LoginPage(),
    buildShell: (_) => kFeatureAgents
        ? MessengerShell(themeController: _theme, shellConfig: shellConfig)
        : _OnboardingFirstLaunchGate(
            shellConfig: shellConfig,
            child: RootWrapper(config: shellConfig),
          ),
  );

  @override
  Widget build(BuildContext context) {
    // The app-level lifecycle wire. The chat UI registers resume and pause
    // callbacks on `AppLifecycleService`, and nothing in Agents ever called
    // `handleLifecycleState` — no widget observed the binding at app level, so
    // those callbacks never fired.
    return AppLifecycleObserver(
      // DynamicColorBuilder exposes the platform's Material You palette (when
      // available) and rebuilds automatically when the system colours change,
      // so the app follows wallpaper/accent changes live when the user has
      // enabled dynamic colour.
      child: DynamicColorBuilder(
        builder: (mui.ColorScheme? lightDynamic, mui.ColorScheme? darkDynamic) {
          // chuk_chat hands its shell config straight to the shell
          // (`RootWrapper(config: …)`); so does Agents, through AuthGate's
          // shell builder (bead cowork-8y2). Rebuilt with the app, so a theme
          // change reaches the shell like any other rebuild.
          final AppShellConfig shellConfig = _buildShellConfig();
          return MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [OnboardingTourController.navigatorObserver],
            title: 'Chuk Chat',
            debugShowCheckedModeBanner: false,
            theme: _themeService.buildTheme(
              lightDynamic: _toFlutterScheme(lightDynamic, Brightness.light),
              darkDynamic: _toFlutterScheme(darkDynamic, Brightness.dark),
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

              // Apply user-chosen UI scale to all text in the app via
              // MediaQuery. This is the safest scaling approach — it doesn't
              // break layout calculations the way Transform.scale would.
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(_themeService.uiScale),
                ),
                child: child,
              );
            },
            // The Android assist activity starts this engine on
            // [assistantOverlayRouteName] and the surface has to be the ONLY
            // route: `SystemNavigator.pop()` then finishes the activity and the
            // app underneath comes back, instead of popping to a page below.
            //
            // Reading the engine's initial route and swapping `home` does that.
            // Routing it through `onGenerateInitialRoutes` does NOT — `home:`
            // and `onGenerateInitialRoutes:` are mutually exclusive, and moving
            // the app home into the latter renders a permanently black app (a
            // release build on a Pixel showed nothing but the system bars).
            home: _isAssistantLaunch
                ? const AssistantOverlayPage()
                : _buildHome(shellConfig),
          );
        },
      ),
    );
  }

  /// Maps a `material_ui` [mui.ColorScheme] (what dynamic_color 2.x provides) to
  /// a Flutter [ColorScheme]. Only the roles the theme reads are relevant, but
  /// we fill every required constructor field so the result is a valid scheme.
  ColorScheme? _toFlutterScheme(
    mui.ColorScheme? scheme,
    Brightness brightness,
  ) {
    if (scheme == null) return null;
    return ColorScheme(
      brightness: brightness,
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      error: scheme.error,
      onError: scheme.onError,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
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

/// Starts the interactive onboarding tour if the signed-in user has never
/// completed it. Completion is per-user (synced via Supabase), so the gate
/// waits for the server value before showing — a fresh install for an
/// existing user must not re-show the tour. Persists completion via
/// [AppThemeService.setOnboardingCompleted]. Also tears the tour down if the
/// user signs out mid-tour so the overlay can't leak.
class _OnboardingFirstLaunchGate extends StatefulWidget {
  const _OnboardingFirstLaunchGate({
    required this.child,
    required this.shellConfig,
  });

  final Widget child;
  final AppShellConfig shellConfig;

  @override
  State<_OnboardingFirstLaunchGate> createState() =>
      _OnboardingFirstLaunchGateState();
}

class _OnboardingFirstLaunchGateState
    extends State<_OnboardingFirstLaunchGate> {
  bool _didStartTour = false;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());

    // Defensive: if the user signs out while the tour is up, drop the overlay
    // so it doesn't end up rendered on top of the LoginPage.
    _authSub = SupabaseService.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedOut &&
          OnboardingTourController.instance.isActive) {
        OnboardingTourController.instance.cancel();
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _maybeStart() async {
    if (_didStartTour) return;
    final themeService = AppThemeService.instance;
    if (themeService.onboardingCompleted) return;
    // Local prefs can't know about completion on other devices — wait for the
    // per-user Supabase value before deciding. Errors are swallowed inside
    // loadFromSupabaseAsync; offline first launches still get the tour.
    await themeService.loadFromSupabaseAsync();
    if (!mounted || _didStartTour) return;
    if (themeService.onboardingCompleted) return;
    _didStartTour = true;
    OnboardingTourController.instance.start(
      context,
      shellConfig: widget.shellConfig,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
