// lib/services/session_manager_service.dart
// Handles authentication session management, validation, and security checks

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/app_initialization_service.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Callback for session-related events
typedef SessionEventCallback = void Function();

/// Service for managing user authentication sessions and security
class SessionManagerService extends ChangeNotifier {
  SessionManagerService._();

  static final SessionManagerService _instance = SessionManagerService._();
  static SessionManagerService get instance => _instance;

  /// Callbacks for session events
  final List<SessionEventCallback> _onPasswordMismatchCallbacks = [];

  StreamSubscription<AuthState>? _authSubscription;
  bool _isInitialized = false;
  String? _sessionInitializedForUser;

  bool get isInitialized => _isInitialized;

  /// Initialize session management and listen to auth state changes
  void initialize({SessionEventCallback? onPasswordMismatch}) {
    if (_isInitialized) return;

    if (onPasswordMismatch != null) {
      _onPasswordMismatchCallbacks.add(onPasswordMismatch);
    }

    _authSubscription = SupabaseService.auth.onAuthStateChange.listen(
      _handleAuthStateChange,
    );

    _isInitialized = true;
  }

  void _handleAuthStateChange(AuthState event) async {
    if (event.session != null) {
      await _handleSessionActive(event.session!.user);
    } else {
      await _handleSessionInactive();
    }
  }

  Future<void> _handleSessionActive(User user) async {
    if (kDebugMode) {
      debugPrint('🔐 [SessionManager] Session active for user: ${user.id}');
    }

    // Check for password revision mismatch
    try {
      final hasMismatch = await PasswordRevisionService.hasRevisionMismatch(
        user,
      );
      if (hasMismatch) {
        await _handlePasswordRevisionMismatch(user);
        return;
      }

      // Ensure revision is seeded for new sessions
      await PasswordRevisionService.ensureRevisionSeeded(user);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [SessionManager] Password revision check failed: $e');
      }
    }

    // Initialize user session (chat loading, sync, theme) — but only once
    // per user. Token refreshes re-trigger onAuthStateChange, so we guard
    // against redundant initialization. On failure, the guard is reset so
    // the next auth event retries.
    if (_sessionInitializedForUser != user.id) {
      _sessionInitializedForUser = user.id;
      unawaited(_initializeUserSessionAsync(user));
    }
  }

  /// Runs user session initialization with error handling.
  /// Resets the guard on failure so the next auth event retries.
  Future<void> _initializeUserSessionAsync(User user) async {
    try {
      await Future.wait([
        AppInitializationService.instance.initializeUserSession(user),
        AppThemeService.instance.loadFromSupabaseAsync(),
      ]);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [SessionManager] User session init failed: $e');
      }
      // Reset guard so next auth event retries initialization
      if (_sessionInitializedForUser == user.id) {
        _sessionInitializedForUser = null;
      }
    }
  }

  Future<void> _handleSessionInactive() async {
    if (kDebugMode) {
      debugPrint('🔐 [SessionManager] Session became inactive');
    }

    // Stop sync immediately
    ChatSyncService.stop();

    // Check if this is a real logout or just offline
    final isOnline = await _checkNetworkStatus();

    if (isOnline) {
      // Real logout - clear all data
      await _performLogoutCleanup();
    } else {
      // Just offline - keep cached data
      if (kDebugMode) {
        debugPrint('📴 [SessionManager] Offline mode - keeping cache');
      }
    }
  }

  Future<void> _handlePasswordRevisionMismatch(User user) async {
    if (kDebugMode) {
      debugPrint('🔐 [SessionManager] Password revision mismatch detected');
    }

    // Clear cached revision
    await PasswordRevisionService.clearCachedRevision(userId: user.id);

    // Perform full logout
    await performFullLogout();

    // Notify listeners
    for (final callback in _onPasswordMismatchCallbacks) {
      callback();
    }
  }

  Future<bool> _checkNetworkStatus() async {
    try {
      return await NetworkStatusService.hasInternetConnection(
        useCache: false,
        timeout: const Duration(seconds: 3),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _performLogoutCleanup() async {
    if (kDebugMode) {
      debugPrint('🔐 [SessionManager] Performing logout cleanup');
    }

    // Reset session guard so next login re-initializes
    _sessionInitializedForUser = null;

    ChatSyncService.stop();

    await EncryptionService.clearKey();
    await ChatStorageService.reset();
    await ProjectStorageService.reset();
    await PasswordRevisionService.clearCachedRevision();

    // Reset theme to local prefs
    AppThemeService.instance.resetSupabaseThemeFlag();
    await AppThemeService.instance.loadFromPrefs();
  }

  /// Perform a full logout with cleanup
  Future<void> performFullLogout() async {
    try {
      await SupabaseService.auth.signOut();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [SessionManager] Error during sign out: $e');
      }
    }

    await _performLogoutCleanup();
  }

  /// Add callback for password mismatch events
  void addOnPasswordMismatchCallback(SessionEventCallback callback) {
    _onPasswordMismatchCallbacks.add(callback);
  }

  /// Remove password mismatch callback
  void removeOnPasswordMismatchCallback(SessionEventCallback callback) {
    _onPasswordMismatchCallbacks.remove(callback);
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _onPasswordMismatchCallbacks.clear();
    _isInitialized = false;
    super.dispose();
  }
}
