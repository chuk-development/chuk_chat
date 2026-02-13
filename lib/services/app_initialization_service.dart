// lib/services/app_initialization_service.dart
// Handles application initialization, service setup, and user session startup

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_preload_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
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

  bool get isInitializing => _isInitializing;
  bool get isSupabaseReady => _isSupabaseReady;

  /// Initialize core services (call from main())
  Future<void> initializeCoreServices() async {
    if (_isInitializing) return;
    _isInitializing = true;

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
    } catch (error) {
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

    if (kDebugMode) {
      debugPrint('🚀 [AppInit] Starting user session init for ${user.id}...');
    }

    try {
      // Ensure encryption key is loaded
      final hasKey = await EncryptionService.tryLoadKey();

      if (kDebugMode) {
        debugPrint(
          '🔑 [AppInit] Encryption key loaded in ${stopwatch.elapsedMilliseconds}ms',
        );
      }

      if (hasKey) {
        await _loadUserData(stopwatch);
      } else {
        if (kDebugMode) {
          debugPrint('⚠️ [AppInit] Encryption key not available');
        }
        ChatSyncService.stop();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('❌ [AppInit] User session init failed: $error');
        debugPrint('$stackTrace');
      }
      ChatSyncService.stop();
    }
  }

  Future<void> _loadUserData(Stopwatch stopwatch) async {
    // Load chats from cache first (fast)
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (kDebugMode) {
        debugPrint(
          '📦 [AppInit] Sidebar chats loaded in ${stopwatch.elapsedMilliseconds}ms',
        );
      }

      // Start sync after cache is loaded
      ChatSyncService.start();

      // Preload all messages in background
      unawaited(ChatPreloadService.startBackgroundPreload());
    } catch (error, stackTrace) {
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
