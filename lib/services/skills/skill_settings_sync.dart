/// The Supabase mirror of the user's skill switches.
///
/// The host keeps the truth (its `skill_settings` table, docs/WIRE_CONTRACT.md
/// "Skills"). This mirror exists for the reinstall case, the same reason the
/// secrets have one: a fresh install, or a host whose state database was
/// reset, gets the user's switches back from the account instead of from
/// memory. One row per (user, skill name): a name is a label, not a secret,
/// so it is stored in plaintext under owner-only RLS
/// (`supabase/migrations/20260905150000_cowork_skill_settings.sql`).
library;

import 'package:flutter/foundation.dart';

import 'package:cowork/services/supabase_service.dart';

abstract interface class SkillSettingsMirror {
  /// Records one switch. Best-effort: a failure is logged, never thrown.
  Future<void> save(String name, bool enabled);

  /// Every switch the account holds, or null when the mirror cannot be read
  /// (signed out, no network). An empty map means "nothing stored".
  Future<Map<String, bool>?> load();
}

class NoopSkillSettingsMirror implements SkillSettingsMirror {
  const NoopSkillSettingsMirror();

  @override
  Future<void> save(String name, bool enabled) async {}

  @override
  Future<Map<String, bool>?> load() async => null;
}

class SkillSettingsSync implements SkillSettingsMirror {
  const SkillSettingsSync();

  static const String table = 'cowork_skill_settings';
  static const String columnUserId = 'user_id';
  static const String columnName = 'name';
  static const String columnEnabled = 'enabled';
  static const String columnUpdatedAt = 'updated_at';

  @override
  Future<void> save(String name, bool enabled) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      await SupabaseService.client.from(table).upsert(
        <String, dynamic>{
          columnUserId: user.id,
          columnName: name,
          columnEnabled: enabled,
          columnUpdatedAt: DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: '$columnUserId,$columnName',
      );
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [SkillSettingsSync] save skipped: $error');
    }
  }

  @override
  Future<Map<String, bool>?> load() async {
    try {
      if (!SupabaseService.isInitialized) return null;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return null;
      final rows = await SupabaseService.client
          .from(table)
          .select('$columnName, $columnEnabled')
          .eq(columnUserId, user.id);
      final out = <String, bool>{};
      for (final row in rows) {
        final name = row[columnName];
        final enabled = row[columnEnabled];
        if (name is String && name.isNotEmpty && enabled is bool) {
          out[name] = enabled;
        }
      }
      return out;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [SkillSettingsSync] load returned null: $error');
      }
      return null;
    }
  }
}
