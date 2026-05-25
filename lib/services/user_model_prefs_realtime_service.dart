// lib/services/user_model_prefs_realtime_service.dart
//
// Cross-device sync for model-related preferences. Subscribes to Supabase
// Postgres changes on:
//   * user_model_providers — list of "active" models (those with a saved
//     provider) and the chosen provider per model.
//   * user_preferences      — currently selected model id.
//
// On any change for the signed-in user, the local caches in
// [UserPreferencesService] are invalidated and the [ModelSelectionEventBus]
// fires so open dropdowns and the model selector page reload immediately.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

class UserModelPrefsRealtimeService {
  UserModelPrefsRealtimeService._();
  static final UserModelPrefsRealtimeService instance =
      UserModelPrefsRealtimeService._();

  RealtimeChannel? _channel;
  String? _subscribedUserId;

  /// Start listening for cross-device changes for [userId]. Idempotent — a
  /// repeated call for the same user is a no-op; a call for a different user
  /// tears the old channel down first.
  Future<void> start(String userId) async {
    if (_subscribedUserId == userId && _channel != null) return;
    await stop();

    final client = SupabaseService.client;
    final channel = client.channel('user_model_prefs:$userId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_model_providers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) => _handleProviderChange(payload),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_preferences',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) => _handleSelectedModelChange(payload),
      )
      ..subscribe();

    _channel = channel;
    _subscribedUserId = userId;
    if (kDebugMode) {
      debugPrint(
        '🔄 [UserModelPrefsRealtime] Subscribed for user $userId',
      );
    }
  }

  /// Tear down the active subscription, if any.
  Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    _subscribedUserId = null;
    if (channel == null) return;
    try {
      await SupabaseService.client.removeChannel(channel);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [UserModelPrefsRealtime] removeChannel failed: $e');
      }
    }
  }

  void _handleProviderChange(PostgresChangePayload payload) {
    if (kDebugMode) {
      debugPrint(
        '🔄 [UserModelPrefsRealtime] user_model_providers ${payload.eventType}',
      );
    }
    UserPreferencesService.invalidateProviderPreferencesCache();
    ModelSelectionEventBus().notifyRefresh();
  }

  void _handleSelectedModelChange(PostgresChangePayload payload) {
    if (kDebugMode) {
      debugPrint(
        '🔄 [UserModelPrefsRealtime] user_preferences ${payload.eventType}',
      );
    }
    UserPreferencesService.invalidateSelectedModelCache();
    final newRow = payload.newRecord;
    if (newRow.isNotEmpty) {
      final dynamic modelId = newRow['selected_model_id'];
      if (modelId is String && modelId.isNotEmpty) {
        ModelSelectionEventBus().notifyModelSelected(modelId);
      }
    }
    ModelSelectionEventBus().notifyRefresh();
  }
}
