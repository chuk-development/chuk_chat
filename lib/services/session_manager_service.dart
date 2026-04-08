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
import 'package:chuk_chat/services/workspace_storage_service.dart';
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
  String? _revisionCheckedForUser;
  Future<void>? _revisionCheckInFlight;
  static const Duration _defaultThemeRefreshDelay = Duration(seconds: 4);
  static const Duration _linuxThemeRefreshDelay = Duration(seconds: 18);

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

    // Initialize user session (chat loading, sync, theme) — but only once
    // per user. Token refreshes re-trigger onAuthStateChange, so we guard
    // against redundant initialization. On failure, the guard is reset so
    // the next auth event retries.
    if (_sessionInitializedForUser != user.id) {
      _sessionInitializedForUser = user.id;
      unawaited(_initializeUserSessionAsync(user));
    }

    // Run password revision checks in background so startup remains responsive.
    // flutter_secure_storage can stall Linux startup when awaited inline.
    unawaited(_verifyPasswordRevisionInBackground(user));
  }

  /// Runs user session initialization with error handling.
  /// Resets the guard on failure so the next auth event retries.
  Future<void> _initializeUserSessionAsync(User user) async {
    try {
      await AppInitializationService.instance.initializeUserSession(user);
      final Duration themeDelay = defaultTargetPlatform == TargetPlatform.linux
          ? _linuxThemeRefreshDelay
          : _defaultThemeRefreshDelay;
      unawaited(
        Future<void>.delayed(themeDelay, () async {
          if (SupabaseService.auth.currentUser?.id != user.id) return;
          await AppThemeService.instance.loadFromSupabaseAsync(
            forceRefresh: false,
          );
        }),
      );
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

  Future<void> _verifyPasswordRevisionInBackground(User user) async {
    if (_revisionCheckedForUser == user.id) return;
    if (_revisionCheckInFlight != null) return;

    Future<void> run() async {
      try {
        if (defaultTargetPlatform == TargetPlatform.linux) {
          await Future<void>.delayed(const Duration(seconds: 12));
        }

        final activeUserId = SupabaseService.auth.currentUser?.id;
        if (activeUserId != user.id) return;

        final hasMismatch = await PasswordRevisionService.hasRevisionMismatch(
          user,
        );
        if (hasMismatch) {
          if (SupabaseService.auth.currentUser?.id == user.id) {
            await _handlePasswordRevisionMismatch(user);
          }
          return;
        }

        if (SupabaseService.auth.currentUser?.id != user.id) return;
        await PasswordRevisionService.ensureRevisionSeeded(user);
        _revisionCheckedForUser = user.id;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [SessionManager] Password revision check failed: $e');
        }
      }
    }

    final inFlight = run();
    _revisionCheckInFlight = inFlight;
    await inFlight.whenComplete(() {
      if (identical(_revisionCheckInFlight, inFlight)) {
        _revisionCheckInFlight = null;
      }
    });
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
    _revisionCheckedForUser = null;

    ChatSyncService.stop();

    await EncryptionService.clearKey();
    await ChatStorageService.reset();
    await WorkspaceStorageService.reset();
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
    _sessionInitializedForUser = null;
    _revisionCheckedForUser = null;
    _revisionCheckInFlight = null;
    super.dispose();
  }
}
