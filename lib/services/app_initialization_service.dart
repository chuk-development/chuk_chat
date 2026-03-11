// lib/services/app_initialization_service.dart
// Handles application initialization, service setup, and user session startup

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_preload_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/services/settings_sync_service.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Callback for initialization events
typedef InitProgressCallback = void Function(String stage, int progressPercent);

/// Service for managing app initialization and user session startup
class AppInitializationService {
  AppInitializationService._();

  static final AppInitializationService _instance =
      AppInitializationService._();
  static AppInitializationService get instance => _instance;

  bool _isInitializing = false;
  bool _isSupabaseReady = false;
  Timer? _deferredPreloadTimer;

  // Gives startup/session init time to settle before background decrypt work.
  static const Duration _deferredPreloadDelay = Duration(seconds: 45);

  bool get isInitializing => _isInitializing;
  bool get isSupabaseReady => _isSupabaseReady;

  /// Initialize core services (call from main())
  Future<void> initializeCoreServices() async {
    if (_isInitializing) return;
    _isInitializing = true;
    final stopwatch = Stopwatch()..start();

    unawaited(
      DiagnosticsLogService.info('startup', 'Initializing core services'),
    );

    try {
      // Initialize foreground service (non-blocking, platform-specific)
      unawaited(StreamingForegroundService.initialize());

      // Initialize Supabase (blocking - required for app to function)
      await SupabaseService.initialize();
      _isSupabaseReady = true;

      // If already logged in, pre-load encryption key.
      // Full session init (chat loading, sync, model prefetch) is handled
      // by SessionManagerService once it receives the auth state event.
      if (SupabaseService.auth.currentSession != null) {
        unawaited(_preloadEncryptionKey());
      }

      unawaited(
        DiagnosticsLogService.timing(
          'startup',
          'initialize_core_services',
          stopwatch.elapsedMilliseconds,
          data: {'supabase_ready': _isSupabaseReady},
        ),
      );
    } catch (error) {
      unawaited(
        DiagnosticsLogService.error(
          'startup',
          'Core service initialization failed',
          error: error,
        ),
      );
      if (kDebugMode) {
        debugPrint('❌ [AppInit] Service initialization failed: $error');
      }
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _preloadEncryptionKey() async {
    try {
      await EncryptionService.tryLoadKey().catchError((
        error,
        stackTrace,
      ) async {
        if (kDebugMode) {
          debugPrint('⚠️ [AppInit] Initial encryption key load failed: $error');
        }
        await EncryptionService.clearKey();
        return false;
      });
    } catch (e) {
      // Non-critical - will be loaded on demand
    }
  }

  /// Initialize user session after authentication
  /// Call this when user signs in or when app starts with existing session
  Future<void> initializeUserSession(User user) async {
    final stopwatch = Stopwatch()..start();

    unawaited(
      DiagnosticsLogService.info(
        'startup',
        'Initializing user session',
        data: {'user_id_len': user.id.length},
      ),
    );

    if (kDebugMode) {
      debugPrint('🚀 [AppInit] Starting user session init for ${user.id}...');
    }

    try {
      // Load cached sidebar data first so startup UI is responsive even if
      // secure storage takes time on Linux.
      await _loadUserData(stopwatch, startSync: false);

      // Ensure encryption key is loaded before starting network sync.
      final hasKey = await EncryptionService.tryLoadKey();
      if (kDebugMode) {
        debugPrint(
          '🔑 [AppInit] Encryption key loaded in ${stopwatch.elapsedMilliseconds}ms',
        );
      }

      if (hasKey) {
        _startSyncAfterKey(stopwatch);
      } else {
        unawaited(
          DiagnosticsLogService.warning(
            'startup',
            'Encryption key unavailable during user session init',
          ),
        );
        if (kDebugMode) {
          debugPrint('⚠️ [AppInit] Encryption key not available');
        }
        ChatSyncService.stop();
      }
    } catch (error, stackTrace) {
      unawaited(
        DiagnosticsLogService.error(
          'startup',
          'User session initialization failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (kDebugMode) {
        debugPrint('❌ [AppInit] User session init failed: $error');
        debugPrint('$stackTrace');
      }
      ChatSyncService.stop();
    }
  }

  Future<void> _loadUserData(
    Stopwatch stopwatch, {
    required bool startSync,
  }) async {
    // Load chats from cache first (fast)
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (kDebugMode) {
        debugPrint(
          '📦 [AppInit] Sidebar chats loaded in ${stopwatch.elapsedMilliseconds}ms',
        );
      }

      if (startSync) {
        _startSyncAfterKey(stopwatch);
      }
    } catch (error, stackTrace) {
      unawaited(
        DiagnosticsLogService.error(
          'startup',
          'Loading user data failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (kDebugMode) {
        debugPrint('⚠️ [AppInit] Chat loading failed: $error');
        debugPrint('$stackTrace');
      }
    }

    // Load projects in parallel
    unawaited(
      ProjectStorageService.loadProjects().catchError((error) {
        if (kDebugMode) {
          debugPrint('⚠️ [AppInit] Project loading failed: $error');
        }
      }),
    );

    // Keep cross-device settings synced in background, but avoid competing
    // with startup rendering and chat hydration.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 10), () async {
        await SettingsSyncService.syncAllFromSupabase(forceRefresh: false);
      }).catchError((error) {
        if (kDebugMode) {
          debugPrint('⚠️ [AppInit] Settings sync failed: $error');
        }
      }),
    );
  }

  void _startSyncAfterKey(Stopwatch stopwatch) {
    // Start sync after cache and encryption key are ready.
    ChatSyncService.start();

    // Delay preload to keep startup/input smooth, then run in background.
    _startDeferredPreload();

    unawaited(
      DiagnosticsLogService.timing(
        'startup',
        'load_sidebar_and_start_sync',
        stopwatch.elapsedMilliseconds,
        data: {'sidebar_chat_count': ChatStorageService.savedChats.length},
      ),
    );
  }

  void _startDeferredPreload() {
    _deferredPreloadTimer?.cancel();
    _deferredPreloadTimer = Timer(_deferredPreloadDelay, () {
      unawaited(ChatPreloadService.startBackgroundPreload());
    });
  }

  /// Wait for Supabase to be initialized
  /// Returns true if ready, false if timeout
  Future<bool> waitForSupabase({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_isSupabaseReady) return true;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        // Try to access auth - if it doesn't throw, we're initialized
        SupabaseService.auth;
        _isSupabaseReady = true;
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    return false;
  }

  /// Reset all services (call on logout)
  Future<void> resetServices() async {
    _deferredPreloadTimer?.cancel();
    _deferredPreloadTimer = null;
    ChatSyncService.stop();
    ChatPreloadService.reset();
    // Clear encryption key first, then reset storage services in parallel
    await EncryptionService.clearKey();
    await Future.wait([
      ChatStorageService.reset(),
      ProjectStorageService.reset(),
    ]);
  }
}
