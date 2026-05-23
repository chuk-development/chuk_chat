// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/utils/certificate_pinning_register.dart'
    as cert_register;
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/app_initialization_service.dart';
import 'package:chuk_chat/services/app_lifecycle_service.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/settings_sync_service.dart';
import 'package:chuk_chat/services/session_manager_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';
import 'package:chuk_chat/services/onboarding_tour_controller.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/system_tray_service.dart';
import 'package:chuk_chat/services/window_close_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/grain_overlay.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/set_new_password_page.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register certificate pinning for native platforms.
  // On web this is a no-op (browser handles TLS).
  cert_register.registerCertificatePinning();

  // Log which API server we're targeting (only visible in debug builds)
  if (kDebugMode) {
    debugPrint('[API] Using server: ${ApiConfigService.apiBaseUrl}');
  }

  // Keep chat storage cache deterministic to avoid early access races.
  await initChatStorageCache();

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

  // Initialize core services (Supabase, etc.) in background
  unawaited(AppInitializationService.instance.initializeCoreServices());

  // Use default theme immediately - load preferences async after first frame
  runApp(const ChukChatApp());
}

class ChukChatApp extends StatefulWidget {
  const ChukChatApp({super.key});

  @override
  State<ChukChatApp> createState() => _ChukChatAppState();
}

class _ChukChatAppState extends State<ChukChatApp> with WidgetsBindingObserver {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // Services
  final AppThemeService _themeService = AppThemeService.instance;
  final AppLifecycleService _lifecycleService = AppLifecycleService.instance;
  final SessionManagerService _sessionManager = SessionManagerService.instance;
  final AppInitializationService _initService =
      AppInitializationService.instance;
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
    WidgetsBinding.instance.addObserver(this);
    _lifecycleService.addOnResumeCallback(_syncSettingsInBackground);

    // Listen to theme changes
    _themeService.addListener(_onThemeChanged);

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
    if (mounted) setState(() {});
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
    if (!mounted) return;

    // Initialize session manager now that Supabase is ready and local
    // theme is loaded. This subscribes to onAuthStateChange and handles
    // user session initialization (chat loading, sync, theme from Supabase).
    _sessionManager.initialize(onPasswordMismatch: _onPasswordMismatch);

    // Defer non-critical startup work so first interaction stays responsive.
    _scheduleStartupSettingsSync();
    _initializeNotificationsInBackground();
  }

  @override
  void dispose() {
    _resumeSettingsSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleService.removeOnResumeCallback(_syncSettingsInBackground);
    _themeService.removeListener(_onThemeChanged);
    _lifecycleService.dispose();
    _sessionManager.dispose();
    _themeService.dispose();
    unawaited(SystemTrayService.instance.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lifecycleService.handleLifecycleState(state);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [OnboardingTourController.navigatorObserver],
      title: 'Chuk Chat',
      debugShowCheckedModeBanner: false,
      theme: _themeService.buildTheme(),
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
        final scaled = MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_themeService.uiScale),
          ),
          child: child,
        );

        // Linux: skip film-grain overlay to avoid startup and interaction jank.
        if (!_themeService.grainEnabled || _isLinuxDesktop) return scaled;

        return Stack(
          children: [
            scaled,
            const Positioned.fill(
              child: IgnorePointer(
                child: GrainOverlay(
                  opacity: 0.10,
                  speedMs: 160,
                  noiseSize: 140,
                  blendMode: BlendMode.overlay,
                ),
              ),
            ),
          ],
        );
      },
      home: AuthGate(
        loadingBuilder: (context) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        signedOutBuilder: (context) => const LoginPage(),
        signedInBuilder: (context) {
          final config = _buildShellConfig();
          return _OnboardingFirstLaunchGate(
            shellConfig: config,
            child: RootWrapper(config: config),
          );
        },
        passwordRecoveryBuilder: (context) => SetNewPasswordPage(
          onComplete: () {
            // Force rebuild of AuthGate to transition to signed-in view.
            // The auth state is already signed-in; we just need to clear
            // the password recovery flag by navigating.
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute<void>(builder: (_) => _buildRootWrapper()),
              (route) => false,
            );
          },
        ),
      ),
    );
  }

  Widget _buildRootWrapper() {
    return RootWrapper(config: _buildShellConfig());
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
        grainEnabled: _themeService.grainEnabled,
        setGrainEnabled: _themeService.setGrainEnabled,
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
        includeRecentImagesInHistory:
            _themeService.includeRecentImagesInHistory,
        setIncludeRecentImagesInHistory:
            _themeService.setIncludeRecentImagesInHistory,
        includeAllImagesInHistory: _themeService.includeAllImagesInHistory,
        setIncludeAllImagesInHistory:
            _themeService.setIncludeAllImagesInHistory,
        includeReasoningInHistory: _themeService.includeReasoningInHistory,
        setIncludeReasoningInHistory:
            _themeService.setIncludeReasoningInHistory,
        includeToolResultsInHistory:
            _themeService.includeToolResultsInHistory,
        setIncludeToolResultsInHistory:
            _themeService.setIncludeToolResultsInHistory,
        toolCallingEnabled: _themeService.toolCallingEnabled,
        setToolCallingEnabled: _themeService.setToolCallingEnabled,
        toolDiscoveryMode: _themeService.toolDiscoveryMode,
        setToolDiscoveryMode: _themeService.setToolDiscoveryMode,
        showToolCalls: _themeService.showToolCalls,
        setShowToolCalls: _themeService.setShowToolCalls,
        allowMarkdownToolCalls: _themeService.allowMarkdownToolCalls,
        setAllowMarkdownToolCalls: _themeService.setAllowMarkdownToolCalls,
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

/// Starts the interactive onboarding tour once per app launch if the user
/// hasn't completed it. Persists completion via
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

  void _maybeStart() {
    if (_didStartTour) return;
    if (AppThemeService.instance.onboardingCompleted) return;
    if (!mounted) return;
    _didStartTour = true;
    OnboardingTourController.instance.start(
      context,
      shellConfig: widget.shellConfig,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
