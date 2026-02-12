// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_preload_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/grain_overlay.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/session_tracking_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-initialize SharedPreferences BEFORE runApp for instant cache access
  await initChatStorageCache();

  // Initialize Supabase in background - don't block UI
  unawaited(_initializeServicesAsync());

  // Use default theme immediately - load preferences async after first frame
  runApp(const ChukChatApp());
}

Future<void> _initializeServicesAsync() async {
  try {
    unawaited(StreamingForegroundService.initialize());
    await SupabaseService.initialize();

    if (SupabaseService.auth.currentSession != null) {
      unawaited(
        EncryptionService.tryLoadKey().catchError((error, stackTrace) async {
          debugPrint('Initial encryption key load failed: $error');
          debugPrint('$stackTrace');
          await EncryptionService.clearKey();
          return false;
        }),
      );
      unawaited(ModelPrefetchService.prefetch());
    }
  } catch (error) {
    debugPrint('Service initialization failed: $error');
  }
}

class ChukChatApp extends StatefulWidget {
  const ChukChatApp({super.key});

  @override
  State<ChukChatApp> createState() => _ChukChatAppState();
}

class _ChukChatAppState extends State<ChukChatApp> with WidgetsBindingObserver {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  final AppThemeService _themeService = AppThemeService.instance;

  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeService.addListener(_onThemeChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAfterSupabase();
    });
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initializeAfterSupabase() async {
    await _waitForSupabase();
    if (!mounted) return;

    await NotificationService.initialize(navigatorKey);
    await NotificationService.checkLaunchNotification();

    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((
      event,
    ) async {
      if (event.session != null) {
        final user = event.session!.user;
        debugPrint('✨ [Auth] Session active - starting background init');

        unawaited(_initUserSession(user));
        unawaited(_themeService.loadFromSupabaseAsync());

        if (kFeatureSessionManagement) {
          unawaited(_verifySessionStillValid());
          unawaited(SessionTrackingService.registerSession());
        }
        unawaited(_checkPasswordRevision(user));
        unawaited(ModelPrefetchService.prefetch());

        debugPrint('✨ [Auth] All background tasks launched - UI is FREE');
      } else {
        final isOnline = await NetworkStatusService.hasInternetConnection(
          useCache: false,
        );

        if (isOnline) {
          debugPrint('🔐 [Auth] User logged out (online) - clearing data');
          ChatSyncService.stop();
          ChatPreloadService.reset();
          await EncryptionService.clearKey();
          await ChatStorageService.reset();
          await ProjectStorageService.reset();
          _themeService.resetSupabaseThemeFlag();
          await _themeService.loadFromPrefs();
          await PasswordRevisionService.clearCachedRevision();
        } else {
          debugPrint(
            '📴 [Auth] Session unavailable but offline - keeping cache',
          );
          ChatSyncService.stop();
        }
      }
    });

    await _themeService.loadFromPrefs();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _themeService.removeListener(_onThemeChanged);
    _themeService.dispose();
    ChatSyncService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_onAppResumed());
        StreamingManager().onAppLifecycleChanged(isInBackground: false);
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        ChatSyncService.pause();
        StreamingManager().onAppLifecycleChanged(isInBackground: true);
    }
  }

  Future<void> _onAppResumed() async {
    NetworkStatusService.resetFailureCount();

    unawaited(
      NetworkStatusService.hasInternetConnection(
        useCache: false,
        timeout: const Duration(seconds: 3),
      ).then((isOnline) {
        debugPrint(
          '📱 [Lifecycle] App resumed, network: ${isOnline ? "ONLINE" : "OFFLINE"}',
        );
        if (kFeatureSessionManagement &&
            isOnline &&
            SupabaseService.auth.currentSession != null) {
          unawaited(_verifySessionStillValid());
          unawaited(SessionTrackingService.updateLastSeen());
        }
      }),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ChatSyncService.resume();
    });
  }

  Future<void> _verifySessionStillValid() async {
    try {
      final session = await SupabaseService.forceRefreshSession();
      if (session == null && SupabaseService.auth.currentSession != null) {
        debugPrint('🔐 [Auth] Session revoked remotely - forcing logout');
        if (kFeatureSessionManagement) {
          await SessionTrackingService.setRemotelySignedOut();
        }
        await SupabaseService.auth.signOut();
        await EncryptionService.clearKey();
        await ChatStorageService.reset();
        await ProjectStorageService.reset();
      }
    } catch (_) {
      // Network error - don't force logout
    }
  }

  Future<void> _initUserSession(User user) async {
    final stopwatch = Stopwatch()..start();
    debugPrint('🚀 [Init] Starting user session init...');

    try {
      final hasKey = await EncryptionService.tryLoadKey();
      debugPrint(
        '🔑 [Init] Encryption key loaded in ${stopwatch.elapsedMilliseconds}ms',
      );

      if (hasKey) {
        unawaited(
          ChatStorageService.loadSavedChatsForSidebar()
              .then((_) {
                debugPrint(
                  '📦 [Init] Chats loaded in ${stopwatch.elapsedMilliseconds}ms',
                );
                ChatSyncService.start();
                unawaited(ChatPreloadService.startBackgroundPreload());
              })
              .catchError((error, stackTrace) {
                debugPrint('Chat loading failed: $error');
                debugPrint('$stackTrace');
              }),
        );

        unawaited(ProjectStorageService.loadProjects());
      } else {
        debugPrint('Encryption key not available');
        ChatSyncService.stop();
      }
    } catch (error, stackTrace) {
      debugPrint('Encryption key load failed: $error');
      debugPrint('$stackTrace');
      ChatSyncService.stop();
    }
  }

  Future<void> _checkPasswordRevision(User user) async {
    try {
      final shouldForceLogout =
          await PasswordRevisionService.hasRevisionMismatch(user);
      if (shouldForceLogout) {
        debugPrint('🔐 [Auth] Password revision mismatch - forcing logout');
        if (kFeatureSessionManagement) {
          await SessionTrackingService.setRemotelySignedOut();
        }
        await PasswordRevisionService.clearCachedRevision(userId: user.id);
        await SupabaseService.auth.signOut();
        await EncryptionService.clearKey();
        await ChatStorageService.reset();
        await ProjectStorageService.reset();
        _themeService.resetSupabaseThemeFlag();
        await _themeService.loadFromPrefs();
        return;
      }
      await PasswordRevisionService.ensureRevisionSeeded(user);
    } catch (error, stackTrace) {
      debugPrint('Password revision sync failed: $error');
      debugPrint('$stackTrace');
      await PasswordRevisionService.clearCachedRevision(userId: user.id);
    }
  }

  Future<void> _waitForSupabase() async {
    for (int i = 0; i < 50; i++) {
      try {
        SupabaseService.auth;
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
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
        signedInBuilder: (context) {
          return RootWrapper(
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
            autoSendVoiceTranscription:
                _themeService.autoSendVoiceTranscription,
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
          );
        },
      ),
    );
  }
}
