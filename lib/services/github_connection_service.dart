// lib/services/github_connection_service.dart
//
// Thin client for /v1/user/github/* — the per-user OAuth Device Flow
// that lets the AI use `git` / `gh` inside the sandbox under the
// user's GitHub identity.
//
// The actual access token lives encrypted on the api-server, NOT on
// the client. The client only ever sees connection state (login name,
// scopes, connected_at) via the redacted status endpoint. This file
// is separate from the existing `github_oauth.dart`, which is the
// local-callback OAuth web flow that powers the client-side GitHub
// tools — they serve different purposes and we keep them apart so a
// future refactor can unify them without breaking either today.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:chuk_chat/services/api_config_service.dart';

class GitHubConnectionStatus {
  const GitHubConnectionStatus({
    required this.connected,
    this.githubLogin,
    this.githubUserId,
    this.scopes,
    this.connectedAt,
    this.lastUsedAt,
  });

  final bool connected;
  final String? githubLogin;
  final int? githubUserId;
  final String? scopes;
  final String? connectedAt;
  final String? lastUsedAt;

  factory GitHubConnectionStatus.fromJson(Map<String, dynamic> json) {
    return GitHubConnectionStatus(
      connected: json['connected'] == true,
      githubLogin: json['github_login'] as String?,
      githubUserId: json['github_user_id'] is int
          ? json['github_user_id'] as int
          : (json['github_user_id'] is num
              ? (json['github_user_id'] as num).toInt()
              : null),
      scopes: json['scopes'] as String?,
      connectedAt: json['connected_at'] as String?,
      lastUsedAt: json['last_used_at'] as String?,
    );
  }

  static const GitHubConnectionStatus disconnected =
      GitHubConnectionStatus(connected: false);
}

class GitHubConnectInit {
  const GitHubConnectInit({
    required this.state,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  /// Opaque token we send back to /poll. Bound to the caller's
  /// Supabase user — re-use across users is rejected server-side.
  final String state;

  /// Code the user types into github.com/login/device.
  final String userCode;

  /// URL the user opens to enter the code (always
  /// `https://github.com/login/device`).
  final String verificationUri;

  /// Seconds until the code becomes invalid.
  final int expiresIn;

  /// Recommended poll interval in seconds.
  final int interval;

  factory GitHubConnectInit.fromJson(Map<String, dynamic> json) {
    return GitHubConnectInit(
      state: json['state'] as String,
      userCode: json['user_code'] as String,
      verificationUri: json['verification_uri'] as String,
      expiresIn: (json['expires_in'] as num).toInt(),
      interval: (json['interval'] as num).toInt(),
    );
  }
}

/// Poll result from /connect/poll. ``success`` means the token is
/// now stored server-side and the sandbox will pick it up on the
/// next /create call.
enum GitHubConnectPollState { pending, success, expired, denied }

class GitHubConnectPollResult {
  const GitHubConnectPollResult({required this.state, this.githubLogin});
  final GitHubConnectPollState state;
  final String? githubLogin;

  factory GitHubConnectPollResult.fromJson(Map<String, dynamic> json) {
    final raw = (json['state'] as String?)?.toLowerCase() ?? 'pending';
    final state = switch (raw) {
      'success' => GitHubConnectPollState.success,
      'expired' => GitHubConnectPollState.expired,
      'denied' => GitHubConnectPollState.denied,
      _ => GitHubConnectPollState.pending,
    };
    return GitHubConnectPollResult(
      state: state,
      githubLogin: json['github_login'] as String?,
    );
  }
}

class GitHubConnectionException implements Exception {
  GitHubConnectionException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'GitHubConnectionException($statusCode): $message';
}

class GitHubConnectionService {
  GitHubConnectionService._();

  static const Duration _httpTimeout = Duration(seconds: 15);

  static Future<Map<String, String>> _headers(String accessToken) async => {
        'Content-Type': 'application/json',
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
      };

  static Uri _uri(String path) =>
      Uri.parse('${ApiConfigService.apiBaseUrl}$path');

  /// Fetch the current connection state.
  static Future<GitHubConnectionStatus> status({
    required String accessToken,
  }) async {
    final r = await http
        .get(_uri('/v1/user/github/status'), headers: await _headers(accessToken))
        .timeout(_httpTimeout);
    if (r.statusCode == 200) {
      return GitHubConnectionStatus.fromJson(
        jsonDecode(r.body) as Map<String, dynamic>,
      );
    }
    if (r.statusCode == 503) {
      // OAuth not configured on this deployment.
      return GitHubConnectionStatus.disconnected;
    }
    throw GitHubConnectionException(r.statusCode, _detail(r.body));
  }

  /// Start the Device Flow. Returns the user-facing code + the opaque
  /// state to use with [poll].
  static Future<GitHubConnectInit> startConnect({
    required String accessToken,
  }) async {
    final r = await http
        .post(
          _uri('/v1/user/github/connect/init'),
          headers: await _headers(accessToken),
        )
        .timeout(_httpTimeout);
    if (r.statusCode != 200) {
      throw GitHubConnectionException(r.statusCode, _detail(r.body));
    }
    return GitHubConnectInit.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Poll once. Caller is responsible for spacing — start with the
  /// ``interval`` returned by [startConnect] and call this repeatedly
  /// until state != pending.
  static Future<GitHubConnectPollResult> poll({
    required String accessToken,
    required String state,
  }) async {
    final r = await http
        .post(
          _uri('/v1/user/github/connect/poll'),
          headers: await _headers(accessToken),
          body: jsonEncode({'state': state}),
        )
        .timeout(_httpTimeout);
    if (r.statusCode != 200) {
      throw GitHubConnectionException(r.statusCode, _detail(r.body));
    }
    return GitHubConnectPollResult.fromJson(
      jsonDecode(r.body) as Map<String, dynamic>,
    );
  }

  /// Revoke + drop the stored connection.
  static Future<void> disconnect({required String accessToken}) async {
    final r = await http
        .delete(
          _uri('/v1/user/github/disconnect'),
          headers: await _headers(accessToken),
        )
        .timeout(_httpTimeout);
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw GitHubConnectionException(r.statusCode, _detail(r.body));
    }
  }

  /// Convenience: poll in a loop until terminal state or timeout.
  /// Caller passes a callback that gets invoked every successful poll
  /// (so the UI can show "still waiting…" feedback).
  static Future<GitHubConnectPollResult> pollUntilTerminal({
    required String accessToken,
    required String state,
    required int intervalSeconds,
    required int expiresIn,
    void Function(GitHubConnectPollState)? onTick,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: expiresIn + 5));
    var interval = Duration(seconds: intervalSeconds.clamp(2, 30));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      final result = await poll(accessToken: accessToken, state: state);
      onTick?.call(result.state);
      if (result.state != GitHubConnectPollState.pending) {
        return result;
      }
      // GitHub's slow_down maps to "pending" on our side but we
      // gently back off the polling cadence so we don't get
      // rate-limited.
      if (interval.inSeconds < 15) {
        interval = Duration(seconds: interval.inSeconds + 1);
      }
    }
    return const GitHubConnectPollResult(
      state: GitHubConnectPollState.expired,
    );
  }

  static String _detail(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map && data['detail'] is String) {
        return data['detail'] as String;
      }
    } catch (_) {}
    return body.isEmpty ? 'request failed' : body;
  }
}
