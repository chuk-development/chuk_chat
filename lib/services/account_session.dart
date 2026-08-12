import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import 'package:cowork/services/supabase_service.dart';

/// Immutable snapshot of the account's authenticated session.
///
/// This is the *authentication* the app hands to an executor: the pair of
/// Supabase tokens plus the user id. It is NEVER the login password. The
/// access token is short-lived and the whole session is revocable server-side,
/// so handing it over is safe in a way that handing over the password is not.
class AccountSession {
  const AccountSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
  });

  /// Short-lived JWT. Authorises API calls (`Authorization: Bearer <token>`).
  final String accessToken;

  /// Long-lived token used to mint a new access token when the old one expires.
  final String refreshToken;

  /// The Supabase user id that owns this session.
  final String userId;

  /// Maps a raw Supabase [Session] into the token snapshot the app hands out.
  factory AccountSession.fromSupabase(Session session) {
    return AccountSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken ?? '',
      userId: session.user.id,
    );
  }
}

/// Reads the current [AccountSession] and refreshes it on demand.
///
/// An interface so callers (and tests) do not depend on Supabase directly.
abstract interface class AccountSessionSource {
  /// The current session, without a network round-trip. Null when signed out.
  AccountSession? current();

  /// Forces a token refresh (used after a 401). Returns the refreshed session,
  /// or null if the refresh token has been revoked/invalidated.
  Future<AccountSession?> refresh();
}

/// [AccountSessionSource] backed by the live Supabase session.
class SupabaseAccountSession implements AccountSessionSource {
  const SupabaseAccountSession();

  @override
  AccountSession? current() {
    final session = SupabaseService.auth.currentSession;
    if (session == null || session.accessToken.isEmpty) return null;
    return AccountSession.fromSupabase(session);
  }

  @override
  Future<AccountSession?> refresh() async {
    final session = await SupabaseService.refreshSession();
    if (session == null || session.accessToken.isEmpty) return null;
    return AccountSession.fromSupabase(session);
  }
}
