// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

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
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/settings_sync_service.dart';
import 'package:chuk_chat/services/session_manager_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/system_tray_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/grain_overlay.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';

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
  Timer? _linuxStartupOverlayPollTimer;
  Timer? _linuxStartupOverlayTimeoutTimer;
  DateTime? _linuxStartupOverlayShownAt;
  bool _showLinuxStartupOverlay = false;
  bool _linuxOverlaySessionArmed = false;

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
      if (_isLinuxDesktop && !kFeatureLinuxTray) {
        return;
      }
      final delay = _isLinuxDesktop
          ? const Duration(seconds: 3)
          : const Duration(milliseconds: 1200);
      await Future<void>.delayed(delay);
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
    if (_isLinuxDesktop) {
      final uptime = DateTime.now().difference(_appStartedAt);
      // Avoid heavy settings pull during Linux startup warmup.
      if (uptime < const Duration(seconds: 20)) {
        return;
      }
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

  void _armLinuxStartupOverlayForSignedInSession() {
    if (!_isLinuxDesktop || _linuxOverlaySessionArmed) return;
    _linuxOverlaySessionArmed = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startLinuxStartupOverlay();
    });
  }

  void _resetLinuxStartupOverlayForSignedOutSession() {
    _linuxOverlaySessionArmed = false;
    _hideLinuxStartupOverlay();
  }

  void _startLinuxStartupOverlay() {
    if (!_isLinuxDesktop) return;
    if (SupabaseService.auth.currentSession == null) return;

    _linuxStartupOverlayPollTimer?.cancel();
    _linuxStartupOverlayTimeoutTimer?.cancel();
    _linuxStartupOverlayShownAt = DateTime.now();

    if (!_showLinuxStartupOverlay && mounted) {
      setState(() => _showLinuxStartupOverlay = true);
    }

    const minVisible = Duration(milliseconds: 900);
    _linuxStartupOverlayTimeoutTimer = Timer(const Duration(seconds: 12), () {
      _hideLinuxStartupOverlay();
    });

    _linuxStartupOverlayPollTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        if (!mounted || !_showLinuxStartupOverlay) return;
        if (SupabaseService.auth.currentSession == null) {
          _hideLinuxStartupOverlay();
          return;
        }

        final shownAt = _linuxStartupOverlayShownAt ?? DateTime.now();
        final enoughTimeVisible =
            DateTime.now().difference(shownAt) >= minVisible;
        final startupReady =
            ChatStorageState.cacheLoaded && EncryptionService.hasKey;
        if (enoughTimeVisible && startupReady) {
          _hideLinuxStartupOverlay();
        }
      },
    );
  }

  void _hideLinuxStartupOverlay() {
    _linuxStartupOverlayPollTimer?.cancel();
    _linuxStartupOverlayPollTimer = null;
    _linuxStartupOverlayTimeoutTimer?.cancel();
    _linuxStartupOverlayTimeoutTimer = null;

    if (_showLinuxStartupOverlay && mounted) {
      setState(() => _showLinuxStartupOverlay = false);
    }
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
    _linuxStartupOverlayPollTimer?.cancel();
    _linuxStartupOverlayTimeoutTimer?.cancel();
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
      title: 'Chuk Chat',
      debugShowCheckedModeBanner: false,
      theme: _themeService.buildTheme(),
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // Linux: skip film-grain overlay to avoid startup and interaction jank.
        if (!_themeService.grainEnabled || _isLinuxDesktop) return child;

        return Stack(
          children: [
            child,
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
        signedOutBuilder: (context) {
          if (_linuxOverlaySessionArmed || _showLinuxStartupOverlay) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _resetLinuxStartupOverlayForSignedOutSession();
            });
          }
          return const LoginPage();
        },
        signedInBuilder: (context) {
          _armLinuxStartupOverlayForSignedInSession();
          return _buildSignedInShell();
        },
      ),
    );
  }

  Widget _buildSignedInShell() {
    final root = _buildRootWrapper();
    if (!_isLinuxDesktop || !_showLinuxStartupOverlay) {
      return root;
    }

    final theme = Theme.of(context);
    return Stack(
      children: [
        root,
        Positioned.fill(
          child: ColoredBox(
            color: theme.colorScheme.surface.withValues(alpha: 0.48),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Starting Chuk Chat...',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRootWrapper() {
    return RootWrapper(
      config: AppShellConfig(
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
        toolCallingEnabled: _themeService.toolCallingEnabled,
        setToolCallingEnabled: _themeService.setToolCallingEnabled,
        toolDiscoveryMode: _themeService.toolDiscoveryMode,
        setToolDiscoveryMode: _themeService.setToolDiscoveryMode,
        showToolCalls: _themeService.showToolCalls,
        setShowToolCalls: _themeService.setShowToolCalls,
        allowMarkdownToolCalls: _themeService.allowMarkdownToolCalls,
        setAllowMarkdownToolCalls: _themeService.setAllowMarkdownToolCalls,
      ),
    );
  }
}
