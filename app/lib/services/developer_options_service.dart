// lib/services/developer_options_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

/// Cross-device developer options toggle.
///
/// Storage strategy:
/// - Local: SharedPreferences for instant UI updates
/// - Remote: public.user_preferences.preferences JSONB under
///   `developer_options_enabled`
class DeveloperOptionsService {
  const DeveloperOptionsService._();

  static const String _localKey = 'developer_options_enabled';
  static const String _remotePreferencesColumn = 'preferences';
  static const String _remoteFlagKey = 'developer_options_enabled';
  static const String _selectedModelColumn = 'selected_model_id';
  static const String _fallbackSelectedModelId = 'moonshotai/kimi-k2.5';
  static const Duration _syncTtl = Duration(seconds: 20);

  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);

  static bool _initialized = false;
  static Future<void>? _initInFlight;
  static Future<void>? _syncInFlight;
  static DateTime? _lastSyncAt;

  static Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    if (_initInFlight != null) return _initInFlight!;

    Future<void> run() async {
      final prefs = await SharedPreferences.getInstance();
      enabledNotifier.value = prefs.getBool(_localKey) ?? false;
      _initialized = true;
    }

    _initInFlight = run();
    return _initInFlight!.whenComplete(() {
      _initInFlight = null;
    });
  }

  static Future<bool> isEnabled() async {
    await initialize();
    return enabledNotifier.value;
  }

  static Future<void> setEnabled(bool enabled) async {
    await initialize();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_localKey, enabled);
    if (enabledNotifier.value != enabled) {
      enabledNotifier.value = enabled;
    }

    await _saveRemote(enabled);
  }

  static Future<void> syncFromSupabase({bool forceRefresh = false}) async {
    await initialize();

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    if (!forceRefresh &&
        _lastSyncAt != null &&
        now.difference(_lastSyncAt!) < _syncTtl) {
      return;
    }

    if (_syncInFlight != null) {
      return _syncInFlight!;
    }

    Future<void> run() async {
      try {
        final row = await SupabaseService.client
            .from('user_preferences')
            .select(_remotePreferencesColumn)
            .eq('user_id', user.id)
            .maybeSingle();

        final remoteValue = _extractRemoteFlag(row?[_remotePreferencesColumn]);
        if (remoteValue == null) {
          _lastSyncAt = DateTime.now();
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_localKey, remoteValue);
        if (enabledNotifier.value != remoteValue) {
          enabledNotifier.value = remoteValue;
        }
        _lastSyncAt = DateTime.now();
      } on PostgrestException catch (error) {
        if (_isMissingPreferencesColumn(error)) {
          // Remote schema missing old preferences column; local still works.
          _lastSyncAt = DateTime.now();
          return;
        }
        rethrow;
      }
    }

    _syncInFlight = run();
    return _syncInFlight!.whenComplete(() {
      _syncInFlight = null;
    });
  }

  static Future<void> _saveRemote(bool enabled) async {
    final session = SupabaseService.auth.currentSession;
    if (session == null) return;

    final userId = session.user.id;

    try {
      final existingRow = await SupabaseService.client
          .from('user_preferences')
          .select('$_selectedModelColumn,$_remotePreferencesColumn')
          .eq('user_id', userId)
          .maybeSingle();

      final Map<String, dynamic> preferences = _extractPreferencesMap(
        existingRow?[_remotePreferencesColumn],
      );
      preferences[_remoteFlagKey] = enabled;

      final rawModelId = existingRow?[_selectedModelColumn];
      String? selectedModelId = rawModelId is String
          ? rawModelId.trim()
          : (rawModelId?.toString().trim());
      if (selectedModelId == null || selectedModelId.isEmpty) {
        try {
          selectedModelId = (await UserPreferencesService.loadSelectedModel())
              ?.trim();
        } catch (_) {
          selectedModelId = _fallbackSelectedModelId;
        }
      }
      if (selectedModelId == null || selectedModelId.isEmpty) {
        selectedModelId = _fallbackSelectedModelId;
      }

      await SupabaseService.client.from('user_preferences').upsert({
        'user_id': userId,
        _selectedModelColumn: selectedModelId,
        _remotePreferencesColumn: preferences,
      }, onConflict: 'user_id');
    } on PostgrestException catch (error) {
      if (_isMissingPreferencesColumn(error)) {
        // Some deployments may not have the legacy preferences JSONB column.
        // In that case we keep local behavior only.
        return;
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _extractPreferencesMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is Map) {
      final map = <String, dynamic>{};
      raw.forEach((key, value) {
        if (key is String) {
          map[key] = value;
        }
      });
      return map;
    }
    return <String, dynamic>{};
  }

  static bool? _extractRemoteFlag(dynamic rawPreferences) {
    final map = _extractPreferencesMap(rawPreferences);
    if (!map.containsKey(_remoteFlagKey)) {
      return null;
    }
    return _coerceBool(map[_remoteFlagKey]);
  }

  static bool? _coerceBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    return null;
  }

  static bool _isMissingPreferencesColumn(PostgrestException error) {
    final code = error.code?.toLowerCase() ?? '';
    final message = error.message.toLowerCase();
    return (code == '42703' || message.contains('does not exist')) &&
        message.contains(_remotePreferencesColumn);
  }
}
