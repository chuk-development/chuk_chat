import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_host_session.dart';
import 'package:chuk_chat/supabase_config.dart';

/// Identifies one executor the app can hand its session to.
///
/// In the relay milestone this will carry the executor's device id and public
/// key. Here it is a thin identity so the provisioning seam has a concrete
/// target type to accept.
class ExecutorHandle {
  const ExecutorHandle({required this.deviceId, this.label});

  /// Stable id of the paired executor device.
  final String deviceId;

  /// Optional human-readable name (e.g. "My laptop").
  final String? label;
}

/// The encrypted connect channel the app uses to reach an executor.
///
/// This is the transport seam. The real implementation (the Agents multiplex /
/// relay, a later milestone) carries the payload over the end-to-end encrypted
/// device channel. Nothing in this file opens a socket.
abstract interface class ExecutorTransport {
  /// Delivers the authentication [payload] to [target] over the encrypted
  /// channel. Implementations MUST NOT log or persist the payload.
  Future<void> sendAuthentication(
    ExecutorHandle target,
    Map<String, dynamic> payload,
  );
}

/// Placeholder transport used until the encrypted relay is built. It throws so
/// that any accidental attempt to provision before the relay milestone fails
/// loudly instead of silently doing nothing.
class UnimplementedExecutorTransport implements ExecutorTransport {
  const UnimplementedExecutorTransport();

  @override
  Future<void> sendAuthentication(
    ExecutorHandle target,
    Map<String, dynamic> payload,
  ) {
    throw UnimplementedError(
      'The encrypted executor relay is not built yet (relay milestone).',
    );
  }
}

/// Hands an executor the account authentication so it can spend the account's
/// models and credits on the user's behalf.
///
/// IMPORTANT: this hands the executor the authentication (token), NEVER the
/// login credentials; the token is revocable. The password never leaves the
/// phone.
///
/// The app's own refresh token never leaves the app either. Supabase rotates
/// refresh tokens, so an app and a host that share one family refuse each
/// other in turn: a host that sat offline came back with a dead token and
/// could not be reached any more. So [provision] hands over only the app's
/// short-lived access token, and the host's long-lived credential is a session
/// of its own, minted through the API and sent by [provisionHostSession].
///
/// The real network work lives behind [ExecutorTransport]; this class only
/// shapes the authentication payload and hands it to the transport. Swap in the
/// real transport when the relay milestone lands — no change is needed here.
class ExecutorProvisioning {
  const ExecutorProvisioning(this._transport);

  final ExecutorTransport _transport;

  /// Provisions [target] with the app's short-lived access token. A host that
  /// holds a session of its own keeps it; one that does not asks for one with
  /// `host_session_request`.
  Future<void> provision(ExecutorHandle target, AccountSession session) {
    final payload = <String, dynamic>{
      'type': 'account_authentication',
      'access_token': session.accessToken,
      'user_id': session.userId,
      // The host needs these to refresh the token; the anon key is public and
      // travels inside the E2E channel. Provided in the token so any host works
      // without being pre-configured with Supabase credentials.
      'supabase_url': SupabaseConfig.supabaseUrl,
      'anon_key': SupabaseConfig.supabaseAnonKey,
      // So the host can refresh before the token lapses, not after a 401.
      if (session.expiresAt != null) 'expires_at': session.expiresAt,
    };
    return _transport.sendAuthentication(target, payload);
  }

  /// Provisions [target] with a session minted for the host alone. Marked
  /// `session_kind: host` so the host stores it and refreshes it on its own.
  Future<void> provisionHostSession(
    ExecutorHandle target,
    AgentsHostSession grant,
  ) {
    final payload = <String, dynamic>{
      'type': 'account_authentication',
      'session_kind': 'host',
      'access_token': grant.accessToken,
      'refresh_token': grant.refreshToken,
      'user_id': grant.userId,
      'supabase_url': SupabaseConfig.supabaseUrl,
      'anon_key': SupabaseConfig.supabaseAnonKey,
      if (grant.expiresAt != null) 'expires_at': grant.expiresAt,
    };
    return _transport.sendAuthentication(target, payload);
  }
}
