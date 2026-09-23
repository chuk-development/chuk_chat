/// An account session of the host's own, minted through the API.
///
/// The host used to run on this app's own Supabase session. Supabase rotates
/// refresh tokens, so the app and the host shared one refresh-token family and
/// whoever refreshed second was refused: a host that sat offline came back
/// with a dead token, and a host that refreshed could sign the app out.
///
/// Now the host asks for a session of its own (`host_session_request`). This
/// app calls `POST /v2/agents/host-session` with its own access token; the
/// server signs the same account in once more and returns a new, independent
/// pair. The app hands that pair to the host in `account_authentication`
/// marked `"session_kind": "host"` and never keeps it. The app's own refresh
/// token never leaves the app again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/api_config_service.dart';

/// The path of the minting route on the API server.
const String kAgentsHostSessionPath = '/v2/agents/host-session';

/// A session minted for the host. Key material: never logged, never stored.
class AgentsHostSession {
  const AgentsHostSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final int? expiresAt;

  /// Reads the route's answer. Null when it is not a complete session.
  static AgentsHostSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    final user = json['user_id'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    if (user is! String || user.isEmpty) return null;
    final expires = json['expires_at'];
    return AgentsHostSession(
      accessToken: access,
      refreshToken: refresh,
      userId: user,
      expiresAt: expires is int
          ? expires
          : (expires is num ? expires.toInt() : null),
    );
  }

  /// The tokens are key material, so they are not in here.
  @override
  String toString() => 'AgentsHostSession(user: $userId)';
}

/// Mints a host session for the signed-in account. Null when it could not.
typedef AgentsHostSessionMinter =
    Future<AgentsHostSession?> Function(AccountSession appSession);

/// The production minter: one POST with the app's own bearer token.
///
/// Returns null on any failure. The host then keeps what it has and asks
/// again later, so there is nothing to show the user.
Future<AgentsHostSession?> mintAgentsHostSession(
  AccountSession appSession, {
  http.Client? client,
  String? baseUrl,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (appSession.accessToken.isEmpty) return null;
  final base = baseUrl ?? ApiConfigService.apiBaseUrl;
  final uri = Uri.parse('$base$kAgentsHostSessionPath');
  final owned = client == null;
  final http.Client effective = client ?? http.Client();
  try {
    final response = await effective
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer ${appSession.accessToken}',
            'Content-Type': 'application/json',
          },
        )
        .timeout(timeout);
    if (response.statusCode != 200) return null;
    final grant = AgentsHostSession.fromJson(jsonDecode(response.body));
    // Minted for someone else: never hand that to the host.
    if (grant == null ||
        (appSession.userId.isNotEmpty && grant.userId != appSession.userId)) {
      return null;
    }
    return grant;
  } catch (_) {
    return null;
  } finally {
    if (owned) effective.close();
  }
}
