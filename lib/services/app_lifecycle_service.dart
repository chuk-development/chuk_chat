// lib/services/app_lifecycle_service.dart
// Handles app lifecycle events (resume, pause, background/foreground)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';

/// Callback when app state changes
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
    if (_isDesktopPlatform &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.hidden)) {
      // Desktop focus changes can emit inactive/hidden frequently.
      // Ignore these to avoid sync churn and UI lag while alt-tabbing.
      return;
    }

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
    DiagnosticsLogService.setAppInForeground(true);
    unawaited(
      DiagnosticsLogService.info('lifecycle', 'App resumed to foreground'),
    );

    if (kDebugMode) {
      debugPrint('📱 [Lifecycle] App resumed');
    }

    // Reset network failure count so we don't carry stale offline state
    NetworkStatusService.resetFailureCount();

    if (_isDesktopPlatform) {
      // On desktop, avoid expensive network probing on every focus change.
      ChatSyncService.resume();
    } else {
      // Check network FIRST, then resume sync once we know the actual status.
      // This prevents ChatSyncService from seeing stale isOnline=false after
      // the user turns off flight mode.
      unawaited(_checkNetworkThenResume());
    }

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
  }

  void _handlePaused() {
    DiagnosticsLogService.setAppInForeground(false);
    unawaited(
      DiagnosticsLogService.info('lifecycle', 'App moved to background'),
    );

    if (kDebugMode) {
      debugPrint('📱 [Lifecycle] App paused/backgrounded');
    }

    // Pause sync on mobile to save battery. Keep desktop sync alive so
    // alt-tab/focus changes don't stall the app.
    if (!_isDesktopPlatform) {
      ChatSyncService.pause();
    }

    // Notify listeners
    StreamingManager().onAppLifecycleChanged(isInBackground: true);

    // Call registered callbacks
    for (final callback in _onPauseCallbacks) {
      callback();
    }
  }

  /// Dispose all resources
  @override
  void dispose() {
    _onResumeCallbacks.clear();
    _onPauseCallbacks.clear();
    super.dispose();
  }

  bool get _isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);
}
