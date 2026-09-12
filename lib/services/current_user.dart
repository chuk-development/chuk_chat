// lib/services/current_user.dart

import 'package:chuk_chat/services/supabase_service.dart';
import 'package:flutter/foundation.dart';

/// Who is signed in, for the static caches that are keyed on it.
///
/// Several services keep a process-wide cache of one user's settings. Every
/// one of them needs the same two answers: who is signed in now, and is the
/// user an in-flight async call started as still the owner of what it is about
/// to write. Both answers used to be copied into each service.
abstract final class CurrentUser {
  /// Replaces the live auth lookup used by [id] and [stillOwns], so a test can
  /// flip the signed-in user *while an async operation is suspended* — the
  /// only way to reproduce the sign-out-mid-flight race without a live
  /// backend. Null (the default) outside tests.
  @visibleForTesting
  static String? Function()? debugIdOverride;

  /// The active user id, or null when signed out or before Supabase is up
  /// (`SupabaseService.auth` throws before initialization).
  static String? get id {
    // Gated on kDebugMode so the override is tree-shaken out of release
    // builds: it is a mutable static that decides ownership, and
    // @visibleForTesting is a lint, not a runtime guard. Tests run in debug.
    if (kDebugMode) {
      final override = debugIdOverride;
      if (override != null) return override();
    }
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// True while [userId] is *still the live signed-in user* and still owns the
  /// cache, so an async continuation that started as [userId] may keep its
  /// result.
  ///
  /// This deliberately consults live auth and not just [cacheOwnerUserId].
  /// That field only advances when a public entry point re-syncs the cache, so
  /// between a sign-out and the next entry point it still names the *previous*
  /// user — comparing against it alone would answer "yes, A still owns this"
  /// while B is already signed in, which is exactly the leak being guarded.
  static bool stillOwns(String? userId, String? cacheOwnerUserId) =>
      userId != null && cacheOwnerUserId == userId && id == userId;
}
