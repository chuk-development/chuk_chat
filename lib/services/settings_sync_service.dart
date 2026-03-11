// lib/services/settings_sync_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/tool_handlers/notes_tools.dart' as notes_tools;

/// Central coordinator for cross-device settings sync.
///
/// Keeps all settings pull logic in one place so startup/resume/page-entry
/// can reuse a single sync call without duplicating code.
class SettingsSyncService {
  const SettingsSyncService._();

  static DateTime? _lastSyncAt;
  static Future<void>? _syncInFlight;
  static const Duration _syncTtl = Duration(seconds: 15);

  /// Sync all known settings from Supabase into local caches/prefs.
  static Future<void> syncAllFromSupabase({bool forceRefresh = false}) {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return Future<void>.value();
    }

    final now = DateTime.now();
    if (!forceRefresh &&
        _lastSyncAt != null &&
        now.difference(_lastSyncAt!) < _syncTtl) {
      return Future<void>.value();
    }

    if (_syncInFlight != null) {
      return _syncInFlight!;
    }

    Future<void> run() async {
      await Future.wait<void>([
        notes_tools.syncIdentityFromSupabase(forceRefresh: forceRefresh),
        DeveloperOptionsService.syncFromSupabase(forceRefresh: forceRefresh),
        TitleGenerationService.syncSettingsFromSupabase(
          forceRefresh: forceRefresh,
        ),
        AppThemeService.instance.loadFromSupabaseAsync(
          forceRefresh: forceRefresh,
        ),
      ]);
      _lastSyncAt = DateTime.now();

      if (kDebugMode) {
        debugPrint('✅ [SettingsSync] Synced settings from Supabase');
      }
    }

    _syncInFlight = run();
    return _syncInFlight!.whenComplete(() {
      _syncInFlight = null;
    });
  }
}
