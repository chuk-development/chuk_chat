import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/supabase_config.dart';

// Reconciled for chuk_chat: the provisioning payload reads chuk_chat's existing
// `SupabaseConfig` (supabaseUrl / supabaseAnonKey) rather than a lifted copy, so
// the executor is handed the same backend the app is already configured with.

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
/// This is the transport seam. The real implementation (the CoWork multiplex /
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
/// login credentials; the token is revocable. The access + refresh tokens are
/// short-lived and can be cut off server-side, so a compromised or retired
/// executor can be locked out without touching the password. The password
/// never leaves the phone.
///
/// The real network work lives behind [ExecutorTransport]; this class only
/// shapes the authentication payload and hands it to the transport. Swap in the
/// real transport when the relay milestone lands — no change is needed here.
class ExecutorProvisioning {
  const ExecutorProvisioning(this._transport);

  final ExecutorTransport _transport;

  /// Provisions [target] with the account [session] token pair.
  Future<void> provision(ExecutorHandle target, AccountSession session) {
    final payload = <String, dynamic>{
      'type': 'account_authentication',
      'access_token': session.accessToken,
      'refresh_token': session.refreshToken,
      'user_id': session.userId,
      // The host needs these to refresh the token; the anon key is public and
      // travels inside the E2E channel. Provided in the token so any host works
      // without being pre-configured with Supabase credentials.
      'supabase_url': SupabaseConfig.supabaseUrl,
      'anon_key': SupabaseConfig.supabaseAnonKey,
    };
    return _transport.sendAuthentication(target, payload);
  }
}
