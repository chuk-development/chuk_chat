// lib/services/app_lifecycle_service.dart
// Handles app lifecycle events (resume, pause, background/foreground)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/session_tracking_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Callback when app state changes
typedef AppStateCallback = void Function(AppLifecycleState state);

/// Service for managing app lifecycle events and related operations
class AppLifecycleService extends ChangeNotifier {
  AppLifecycleService._();

  static final AppLifecycleService _instance = AppLifecycleService._();
  static AppLifecycleService get instance => _instance;

  /// Callbacks for lifecycle events
  final List<VoidCallback> _onResumeCallbacks = [];
  final List<VoidCallback> _onPauseCallbacks = [];

  /// Add a callback to be called when app resumes
  void addOnResumeCallback(VoidCallback callback) {
    _onResumeCallbacks.add(callback);
  }

  /// Remove a resume callback
  void removeOnResumeCallback(VoidCallback callback) {
    _onResumeCallbacks.remove(callback);
  }

  /// Add a callback to be called when app pauses
  void addOnPauseCallback(VoidCallback callback) {
    _onPauseCallbacks.add(callback);
  }

  /// Remove a pause callback
  void removeOnPauseCallback(VoidCallback callback) {
    _onPauseCallbacks.remove(callback);
  }

  /// Handle app lifecycle state changes
  void handleLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _handleResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _handlePaused();
    }
  }

  void _handleResumed() {
    if (kDebugMode) {
      debugPrint('📱 [Lifecycle] App resumed');
    }

    // Reset network failure count so we don't carry stale offline state
    NetworkStatusService.resetFailureCount();

    // Check network FIRST, then resume sync once we know the actual status.
    // This prevents ChatSyncService from seeing stale isOnline=false after
    // the user turns off flight mode.
    unawaited(_checkNetworkThenResume());

    // Notify listeners
    StreamingManager().onAppLifecycleChanged(isInBackground: false);

    // Call registered callbacks
    for (final callback in _onResumeCallbacks) {
      callback();
    }
  }

  Future<void> _checkNetworkThenResume() async {
    // Probe network with a fresh (non-cached) check
    final isOnline = await NetworkStatusService.hasInternetConnection(
      useCache: false,
      timeout: const Duration(seconds: 5),
    );

    if (kDebugMode) {
      debugPrint(
        '📱 [Lifecycle] Network probe: ${isOnline ? "ONLINE" : "OFFLINE"}',
      );
    }

    // Now that network status is up-to-date, resume sync
    ChatSyncService.resume();

    // Validate session if online
    if (kFeatureSessionManagement &&
        isOnline &&
        SupabaseService.auth.currentSession != null) {
      unawaited(_validateSession());
      unawaited(SessionTrackingService.updateLastSeen());
    }
  }

  void _handlePaused() {
    if (kDebugMode) {
      debugPrint('📱 [Lifecycle] App paused/backgrounded');
    }

    // Pause sync to save battery
    ChatSyncService.pause();

    // Notify listeners
    StreamingManager().onAppLifecycleChanged(isInBackground: true);

    // Call registered callbacks
    for (final callback in _onPauseCallbacks) {
      callback();
    }
  }

  Future<void> _validateSession() async {
    try {
      final session = await SupabaseService.forceRefreshSession();
      if (session == null && SupabaseService.auth.currentSession != null) {
        if (kDebugMode) {
          debugPrint('🔐 [Lifecycle] Session revoked during validation');
        }
        // Note: Actual logout is handled by SessionManagerService
        notifyListeners();
      }
    } catch (_) {
      // Network error - session remains valid
    }
  }

  /// Dispose all resources
  @override
  void dispose() {
    _onResumeCallbacks.clear();
    _onPauseCallbacks.clear();
    super.dispose();
  }
}
