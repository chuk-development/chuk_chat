// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/utils/certificate_pinning_register.dart'
    as cert_register;
import 'package:chuk_chat/services/app_initialization_service.dart';
import 'package:chuk_chat/services/app_lifecycle_service.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/session_manager_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart'
    show initChatStorageCache;
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
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

  // Pre-initialize SharedPreferences BEFORE runApp for instant cache access
  await initChatStorageCache();

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen to theme changes
    _themeService.addListener(_onThemeChanged);

    // Initialize session management
    _sessionManager.initialize(
      onSessionRevoked: _onSessionRevoked,
      onPasswordMismatch: _onPasswordMismatch,
    );

    // Initialize after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeApp());
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onSessionRevoked() {
    if (mounted) {
      // UI will automatically update via AuthGate
      if (kDebugMode) {
        debugPrint('🔐 [Main] Session revoked - UI updating');
      }
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

  Future<void> _initializeApp() async {
    // Wait for Supabase to be ready
    await _initService.waitForSupabase();
    if (!mounted) return;

    // Initialize notifications
    await NotificationService.initialize(navigatorKey);
    await NotificationService.checkLaunchNotification();

    // Load theme preferences
    await _themeService.loadFromPrefs();

    // Handle auth state for existing sessions
    final currentUser = SupabaseService.auth.currentUser;
    if (currentUser != null) {
      if (kDebugMode) {
        debugPrint(
          '✨ [Main] Existing session found - initializing user session',
        );
      }
      unawaited(_initService.initializeUserSession(currentUser));
      unawaited(_themeService.loadFromSupabaseAsync());

      if (kFeatureSessionManagement) {
        unawaited(ModelPrefetchService.prefetch());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeService.removeListener(_onThemeChanged);
    _lifecycleService.dispose();
    _sessionManager.dispose();
    _themeService.dispose();
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
        if (!_themeService.grainEnabled) return child;

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
        signedOutBuilder: (context) => const LoginPage(),
        signedInBuilder: (context) => _buildRootWrapper(),
      ),
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
      ),
    );
  }
}
