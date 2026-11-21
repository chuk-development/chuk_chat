/// The cloud computer ("Cloud-Computer", CHAT-164): an Agents host that the
/// server runs for a paying user, so the user needs no computer of their own.
///
/// Server contract (api_server `routers/cloud_box.py`):
///
///  * `GET /v2/agents/cloud-box` answers
///    `{"state": "none"|"setting_up"|"running"|"suspended",
///      "last_backup_at": ISO-8601|null}`.
///    404 means the feature is off on the server: the app hides it.
///  * `POST /v2/agents/cloud-box` with `{"pairing_token": "<P>-<D>"}` answers
///    the same shape. It is idempotent. 402 means the user has no plan that
///    includes a cloud computer.
///
/// The pairing token is the same one-time token the install command carries
/// (`agents_install_ticket.dart`). The server hands it to the cloud host, the
/// host parks on the token's relay channel, and the app pairs exactly as it
/// does after the user ran the install command. The token is key material:
/// it is never logged and never put in an error text.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/agents/agent_mail_service.dart'
    show AgentMailTokenSource, supabaseAgentMailToken;
import 'package:chuk_chat/services/api_config_service.dart';

/// Where the user's cloud computer stands, as the server reports it.
enum AgentsCloudBoxState {
  /// No cloud computer exists yet.
  none,

  /// The server is preparing the computer.
  settingUp,

  /// The computer runs.
  running,

  /// The computer is stopped because of a payment problem.
  suspended;

  /// The state for the wire value [raw]. An unknown value reads as [none],
  /// so a newer server cannot crash an older app.
  static AgentsCloudBoxState parse(Object? raw) => switch (raw) {
    'setting_up' => AgentsCloudBoxState.settingUp,
    'running' => AgentsCloudBoxState.running,
    'suspended' => AgentsCloudBoxState.suspended,
    _ => AgentsCloudBoxState.none,
  };
}

/// One answer of the cloud computer endpoint.
@immutable
class AgentsCloudBoxStatus {
  const AgentsCloudBoxStatus({required this.state, this.lastBackupAt});

  static const AgentsCloudBoxStatus none = AgentsCloudBoxStatus(
    state: AgentsCloudBoxState.none,
  );

  final AgentsCloudBoxState state;

  /// When the server last saved a backup of the computer. Null when unknown.
  final DateTime? lastBackupAt;

  /// Reads a response body. A malformed body reads as [none].
  static AgentsCloudBoxStatus fromJson(Object? json) {
    if (json is! Map) return none;
    final Object? backup = json['last_backup_at'];
    return AgentsCloudBoxStatus(
      state: AgentsCloudBoxState.parse(json['state']),
      lastBackupAt: backup is String ? DateTime.tryParse(backup) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsCloudBoxStatus &&
      other.state == state &&
      other.lastBackupAt == lastBackupAt;

  @override
  int get hashCode => Object.hash(state, lastBackupAt);

  @override
  String toString() => 'AgentsCloudBoxStatus($state, backup: $lastBackupAt)';
}

/// Why a cloud computer call failed. The text never holds the token.
class AgentsCloudBoxException implements Exception {
  const AgentsCloudBoxException(this.statusCode, this.code);

  /// The HTTP status, or 0 when no answer came.
  final int statusCode;

  /// A short machine code (`network`, `not_signed_in`, `http_500`, ...).
  final String code;

  /// The server does not offer cloud computers (404).
  bool get unavailable => statusCode == 404;

  /// The user's plan does not include a cloud computer (402).
  bool get noPlan => statusCode == 402;

  @override
  String toString() => 'AgentsCloudBoxException($statusCode, $code)';
}

/// The two calls the app makes. An interface so the flow and the settings row
/// can be tested with a fake.
abstract interface class AgentsCloudBoxApi {
  /// The current state. Throws [AgentsCloudBoxException].
  Future<AgentsCloudBoxStatus> fetch();

  /// Asks for the computer and hands it [pairingToken]. Idempotent.
  /// Throws [AgentsCloudBoxException].
  Future<AgentsCloudBoxStatus> request(String pairingToken);
}

/// [AgentsCloudBoxApi] over HTTP to the API server.
class HttpAgentsCloudBoxApi implements AgentsCloudBoxApi {
  HttpAgentsCloudBoxApi({
    this.client,
    this.baseUrl,
    AgentMailTokenSource? token,
    this.timeout = const Duration(seconds: 20),
  }) : _token = token ?? supabaseAgentMailToken;

  /// The app's client: live token, default base URL.
  static final HttpAgentsCloudBoxApi instance = HttpAgentsCloudBoxApi();

  /// Injected by tests; null opens one client per call.
  final http.Client? client;

  /// Null = [ApiConfigService.apiBaseUrl].
  final String? baseUrl;
  final AgentMailTokenSource _token;
  final Duration timeout;

  static const String path = '/v2/agents/cloud-box';

  Uri get _uri => Uri.parse('${baseUrl ?? ApiConfigService.apiBaseUrl}$path');

  @override
  Future<AgentsCloudBoxStatus> fetch() => _send('GET');

  @override
  Future<AgentsCloudBoxStatus> request(String pairingToken) =>
      _send('POST', body: <String, dynamic>{'pairing_token': pairingToken});

  Future<AgentsCloudBoxStatus> _send(
    String method, {
    Map<String, dynamic>? body,
  }) async {
    final String? token = await _token();
    if (token == null || token.isEmpty) {
      throw const AgentsCloudBoxException(401, 'not_signed_in');
    }
    final http.Request request = http.Request(method, _uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final bool owned = client == null;
    final http.Client transport = client ?? http.Client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await transport.send(request).timeout(timeout),
      ).timeout(timeout);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('cloud box: $method failed (${error.runtimeType})');
      }
      throw const AgentsCloudBoxException(0, 'network');
    } finally {
      if (owned) transport.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint('cloud box: $method -> ${response.statusCode}');
      }
      throw AgentsCloudBoxException(
        response.statusCode,
        'http_${response.statusCode}',
      );
    }
    try {
      return AgentsCloudBoxStatus.fromJson(jsonDecode(response.body));
    } catch (_) {
      throw AgentsCloudBoxException(response.statusCode, 'bad_response');
    }
  }
}
