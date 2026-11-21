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
/// The add-on (booked on its own, with a size):
///
///  * `GET /v2/agents/cloud-box` also carries `size`, `pending_size`,
///    `pending_effective_at` and `sizes_available`.
///  * `POST /v2/agents/cloud-box/subscription` `{"size": "s"}` books it on the
///    existing subscription (charged pro rata now). 402: no subscription,
///    409: already booked.
///  * `DELETE /v2/agents/cloud-box/subscription` cancels it at period end.
///  * `POST /v2/agents/cloud-box/resize` `{"size": "m"}`: a bigger size now
///    (pro rata, one short restart), a smaller one at period end; 409
///    `does_not_fit` when the data would not fit.
///  * Book and resize charge at once. 402 `payment_failed`: the card was
///    declined. 402 `payment_action_required` with `hosted_invoice_url`: the
///    bank wants a confirmation (3-D Secure); the app opens that Stripe page,
///    and the change takes effect once it is paid.
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
import 'package:chuk_chat/services/agents_plans.dart'
    show AgentsCloudBoxSize, cloudBoxSizeById, kAgentsCloudBoxSizeDefaults;
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
  const AgentsCloudBoxStatus({
    required this.state,
    this.lastBackupAt,
    this.size,
    this.pendingSize,
    this.pendingEffectiveAt,
    this.sizesAvailable = const <AgentsCloudBoxSize>[],
  });

  static const AgentsCloudBoxStatus none = AgentsCloudBoxStatus(
    state: AgentsCloudBoxState.none,
  );

  final AgentsCloudBoxState state;

  /// When the server last saved a backup of the computer. Null when unknown.
  final DateTime? lastBackupAt;

  /// The booked size id (`s`, `m`, ...), or null when the add-on is not
  /// booked.
  final String? size;

  /// A size change that waits for the end of the billing period.
  final String? pendingSize;
  final DateTime? pendingEffectiveAt;

  /// The sizes the user can change to. Empty when the server did not say.
  final List<AgentsCloudBoxSize> sizesAvailable;

  /// True when the add-on is booked (a size is set, or a computer exists).
  bool get booked => size != null || state != AgentsCloudBoxState.none;

  /// Reads a response body. A malformed body reads as [none].
  static AgentsCloudBoxStatus fromJson(Object? json) {
    if (json is! Map) return none;
    final Object? backup = json['last_backup_at'];
    final Object? size = json['size'];
    final Object? pending = json['pending_size'];
    final Object? pendingAt = json['pending_effective_at'];
    final Object? available = json['sizes_available'];
    return AgentsCloudBoxStatus(
      state: AgentsCloudBoxState.parse(json['state']),
      lastBackupAt: backup is String ? DateTime.tryParse(backup) : null,
      size: size is String && size.isNotEmpty ? size : null,
      pendingSize: pending is String && pending.isNotEmpty ? pending : null,
      pendingEffectiveAt: pendingAt is String
          ? DateTime.tryParse(pendingAt)
          : null,
      sizesAvailable: <AgentsCloudBoxSize>[
        if (available is List)
          for (final Object? row in available)
            // Either full size objects or bare ids of the known sizes.
            if (row is String
                    ? cloudBoxSizeById(kAgentsCloudBoxSizeDefaults, row)
                    : AgentsCloudBoxSize.fromJson(row)
                case final AgentsCloudBoxSize s)
              s,
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsCloudBoxStatus &&
      other.state == state &&
      other.lastBackupAt == lastBackupAt &&
      other.size == size &&
      other.pendingSize == pendingSize &&
      other.pendingEffectiveAt == pendingEffectiveAt &&
      listEquals(other.sizesAvailable, sizesAvailable);

  @override
  int get hashCode => Object.hash(
    state,
    lastBackupAt,
    size,
    pendingSize,
    pendingEffectiveAt,
    Object.hashAll(sizesAvailable),
  );

  @override
  String toString() =>
      'AgentsCloudBoxStatus($state, size: $size, pending: $pendingSize, '
      'backup: $lastBackupAt)';
}

/// Why a cloud computer call failed. The text never holds the token.
class AgentsCloudBoxException implements Exception {
  const AgentsCloudBoxException(
    this.statusCode,
    this.code, {
    this.hostedInvoiceUrl,
  });

  /// The HTTP status, or 0 when no answer came.
  final int statusCode;

  /// A short machine code (`network`, `not_signed_in`, `http_500`, ...).
  final String code;

  /// The Stripe page where the user confirms the payment. Only with
  /// [paymentActionRequired].
  final String? hostedInvoiceUrl;

  /// The server does not offer cloud computers (404).
  bool get unavailable => statusCode == 404;

  /// The bank wants the user to confirm the payment (402
  /// `payment_action_required` with a page to open).
  bool get paymentActionRequired =>
      statusCode == 402 &&
      code == 'payment_action_required' &&
      hostedInvoiceUrl != null;

  /// The charge was declined (402 `payment_failed`, or an action was asked
  /// for without a page to open).
  bool get paymentFailed =>
      statusCode == 402 &&
      (code == 'payment_failed' ||
          (code == 'payment_action_required' && hostedInvoiceUrl == null));

  /// The user's plan does not include a cloud computer (402). For a booking
  /// it means: no subscription yet, go to checkout.
  bool get noPlan =>
      statusCode == 402 &&
      code != 'payment_failed' &&
      code != 'payment_action_required';

  /// The add-on is already booked (409).
  bool get alreadyBooked => statusCode == 409 && code != 'does_not_fit';

  /// A smaller size would not hold the data (409 `does_not_fit`).
  bool get doesNotFit => code == 'does_not_fit';

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

/// The add-on's billing calls. Apart from [AgentsCloudBoxApi], so the flow's
/// fakes need not know them.
abstract interface class AgentsCloudBoxBillingApi {
  /// The current state. Throws [AgentsCloudBoxException].
  Future<AgentsCloudBoxStatus> fetch();

  /// Books the add-on in [size] on the existing subscription.
  Future<AgentsCloudBoxStatus> book(String size);

  /// Cancels the add-on at the end of the billing period.
  Future<AgentsCloudBoxStatus> cancel();

  /// Changes the size: bigger now, smaller at period end.
  Future<AgentsCloudBoxStatus> resize(String size);
}

/// The machine code in an error body: `{"code": ...}`, `{"error": ...}`,
/// `{"detail": "..."}` or `{"detail": {"code": ...}}`. Null when none.
String? cloudBoxErrorCode(String body) {
  Object? data;
  try {
    data = jsonDecode(body);
  } catch (_) {
    return null;
  }
  String? pick(Object? map) {
    if (map is! Map) return null;
    for (final String key in const <String>['code', 'error', 'detail']) {
      final Object? v = map[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is Map) {
        final String? inner = pick(v);
        if (inner != null) return inner;
      }
    }
    return null;
  }

  return pick(data);
}

/// The `hosted_invoice_url` of a 402 body, when it is an https link to
/// Stripe's invoice pages. Null otherwise.
String? cloudBoxHostedInvoiceUrl(String body) {
  Object? data;
  try {
    data = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (data is! Map) return null;
  final Object? raw = data['hosted_invoice_url'];
  if (raw is! String) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'invoice.stripe.com') {
    return null;
  }
  return raw;
}

/// [AgentsCloudBoxApi] over HTTP to the API server.
class HttpAgentsCloudBoxApi
    implements AgentsCloudBoxApi, AgentsCloudBoxBillingApi {
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

  Uri _uri([String suffix = '']) =>
      Uri.parse('${baseUrl ?? ApiConfigService.apiBaseUrl}$path$suffix');

  @override
  Future<AgentsCloudBoxStatus> fetch() => _send('GET');

  @override
  Future<AgentsCloudBoxStatus> request(String pairingToken) =>
      _send('POST', body: <String, dynamic>{'pairing_token': pairingToken});

  @override
  Future<AgentsCloudBoxStatus> book(String size) => _send(
    'POST',
    suffix: '/subscription',
    body: <String, dynamic>{'size': size},
  );

  @override
  Future<AgentsCloudBoxStatus> cancel() =>
      _send('DELETE', suffix: '/subscription');

  @override
  Future<AgentsCloudBoxStatus> resize(String size) =>
      _send('POST', suffix: '/resize', body: <String, dynamic>{'size': size});

  Future<AgentsCloudBoxStatus> _send(
    String method, {
    String suffix = '',
    Map<String, dynamic>? body,
  }) async {
    final String? token = await _token();
    if (token == null || token.isEmpty) {
      throw const AgentsCloudBoxException(401, 'not_signed_in');
    }
    final http.Request request = http.Request(method, _uri(suffix))
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
        cloudBoxErrorCode(response.body) ?? 'http_${response.statusCode}',
        hostedInvoiceUrl: response.statusCode == 402
            ? cloudBoxHostedInvoiceUrl(response.body)
            : null,
      );
    }
    // A billing answer may come without a body; that is a success too.
    if (response.body.trim().isEmpty && suffix.isNotEmpty) {
      return AgentsCloudBoxStatus.none;
    }
    try {
      return AgentsCloudBoxStatus.fromJson(jsonDecode(response.body));
    } catch (_) {
      throw AgentsCloudBoxException(response.statusCode, 'bad_response');
    }
  }
}
