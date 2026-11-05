/// Client for the server half of an inbound webhook (docs/WIRE_CONTRACT.md,
/// "Inbound webhooks"; api_server `CLAUDE.md`, "Agents webhooks").
///
/// The server makes the secret URL and pushes each call to the host. The app
/// creates the server row first, then the host's `automation_create` with
/// `kind: "webhook"`. When the host refuses the row, the server row is
/// deleted again, so no URL is left that starts nothing.
///
/// The URL is the credential. It comes back from `POST` only, once. It is
/// never logged here and never sent anywhere else.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/agents/agent_mail_service.dart'
    show AgentMailTokenSource, supabaseAgentMailToken;
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';

/// A failed webhook request. [statusCode] is 0 when the server was not
/// reached; [code] is the server's `detail` (`too_many_webhooks`,
/// `not_found`, `invalid_device_id`, ...) or a local code.
class AgentsWebhookException implements Exception {
  const AgentsWebhookException(this.statusCode, this.code);

  final int statusCode;
  final String code;

  static const String notSignedIn = 'not_signed_in';
  static const String network = 'network';
  static const String badResponse = 'bad_response';

  bool get tooMany => statusCode == 429 && code == 'too_many_webhooks';
  bool get notFound => statusCode == 404;

  @override
  String toString() => 'AgentsWebhookException($statusCode): $code';
}

/// One server webhook row (`GET /v1/agents/webhooks`). Never the secret.
@immutable
class AgentsWebhook {
  const AgentsWebhook({
    required this.id,
    this.secretPrefix,
    this.deviceId,
    this.agentId,
    this.enabled = true,
    this.createdAt,
    this.lastHitAt,
  });

  /// The row uuid. The host's automation spec names it as `webhook_id`.
  final String id;

  /// The first characters of the secret, for the user to tell rows apart.
  final String? secretPrefix;
  final String? deviceId;
  final String? agentId;
  final bool enabled;
  final DateTime? createdAt;
  final DateTime? lastHitAt;

  static AgentsWebhook? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    DateTime? time(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return AgentsWebhook(
      id: id.toLowerCase(),
      secretPrefix: text(raw['secret_prefix']),
      deviceId: text(raw['device_id']),
      agentId: text(raw['agent_id']),
      enabled: raw['enabled'] != false,
      createdAt: time(raw['created_at']),
      lastHitAt: time(raw['last_hit_at']),
    );
  }

  AgentsWebhook copyWith({bool? enabled}) => AgentsWebhook(
    id: id,
    secretPrefix: secretPrefix,
    deviceId: deviceId,
    agentId: agentId,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt,
    lastHitAt: lastHitAt,
  );
}

/// The answer of `POST /v1/agents/webhooks`: the row and, this one time,
/// the URL.
@immutable
class AgentsWebhookCreated {
  const AgentsWebhookCreated({required this.webhook, required this.url});

  final AgentsWebhook webhook;

  /// The secret URL. Shown to the user once; never logged.
  final String url;
}

/// `GET` / `POST` / `PATCH` / `DELETE` on `/v1/agents/webhooks`.
class AgentsWebhooksService {
  AgentsWebhooksService({
    this.client,
    this.baseUrl,
    AgentMailTokenSource? token,
    this.timeout = const Duration(seconds: 15),
  }) : _token = token ?? supabaseAgentMailToken;

  static final AgentsWebhooksService instance = AgentsWebhooksService();

  /// Injected by tests; null opens one client per call.
  final http.Client? client;

  /// Null = [ApiConfigService.apiBaseUrl].
  final String? baseUrl;
  final AgentMailTokenSource _token;
  final Duration timeout;

  static const String _root = '/v1/agents/webhooks';

  Uri _uri([String path = '']) =>
      Uri.parse('${baseUrl ?? ApiConfigService.apiBaseUrl}$_root$path');

  /// Makes a server webhook for [deviceId] (the host's relay executor id)
  /// and [agentId] (the roster agent). Either may be null.
  Future<AgentsWebhookCreated> create({
    String? deviceId,
    String? agentId,
  }) async {
    final Map<String, dynamic> json = _json(
      await _send(
        'POST',
        _uri(),
        body: <String, dynamic>{
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          if (agentId != null && agentId.isNotEmpty) 'agent_id': agentId,
        },
      ),
    );
    final AgentsWebhook? webhook = AgentsWebhook.fromJson(json);
    final Object? url = json['url'];
    if (webhook == null || url is! String || url.isEmpty) {
      throw const AgentsWebhookException(0, AgentsWebhookException.badResponse);
    }
    return AgentsWebhookCreated(webhook: webhook, url: url);
  }

  /// Every server webhook of the user, oldest first.
  Future<List<AgentsWebhook>> list() async {
    final Object? rows = _json(await _send('GET', _uri()))['webhooks'];
    return <AgentsWebhook>[
      if (rows is List)
        for (final Object? row in rows)
          if (AgentsWebhook.fromJson(row) case final AgentsWebhook hook) hook,
    ];
  }

  /// Turns a server webhook on or off. Off: the server answers the hook URL
  /// with 404 and pushes nothing.
  Future<AgentsWebhook> setEnabled(String id, bool enabled) async {
    final AgentsWebhook? hook = AgentsWebhook.fromJson(
      _json(
        await _send(
          'PATCH',
          _uri('/${Uri.encodeComponent(id)}'),
          body: <String, dynamic>{'enabled': enabled},
        ),
      ),
    );
    if (hook == null) {
      throw const AgentsWebhookException(0, AgentsWebhookException.badResponse);
    }
    return hook;
  }

  /// Deletes a server webhook. A row that is already gone (404) counts as
  /// deleted.
  Future<void> delete(String id) async {
    try {
      await _send('DELETE', _uri('/${Uri.encodeComponent(id)}'));
    } on AgentsWebhookException catch (error) {
      if (error.notFound) return;
      rethrow;
    }
  }

  Future<http.Response> _send(String method, Uri uri, {Object? body}) async {
    final String? token = await _token();
    if (token == null || token.isEmpty) {
      throw const AgentsWebhookException(
        401,
        AgentsWebhookException.notSignedIn,
      );
    }
    final http.Request request = http.Request(method, uri)
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
        debugPrint('agent webhooks: $method failed (${error.runtimeType})');
      }
      throw const AgentsWebhookException(0, AgentsWebhookException.network);
    } finally {
      if (owned) transport.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint('agent webhooks: $method -> ${response.statusCode}');
      }
      throw AgentsWebhookException(response.statusCode, _detail(response));
    }
    return response;
  }

  static String _detail(http.Response response) {
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map) {
        final Object? detail = data['detail'];
        if (detail is String && detail.isNotEmpty) return detail;
        if (detail is Map && detail['code'] is String) {
          return detail['code'] as String;
        }
      }
    } catch (_) {}
    return 'http_${response.statusCode}';
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    throw AgentsWebhookException(
      response.statusCode,
      AgentsWebhookException.badResponse,
    );
  }
}

/// The host's relay executor id: the `device_id` a server webhook routes to.
/// Null when no cloud pairing is stored.
Future<String?> agentsHostRelayDeviceId([AgentsPairingStore? store]) async {
  try {
    final AgentsStoredPairing? pairing = await (store ?? AgentsPairingStore())
        .loadPairing();
    if (pairing == null) return null;
    final String? id = AgentsCloudRelayAddress.tryParse(pairing.hostUrl)
        ?.targetDeviceId;
    if (id == null || id.isEmpty || id == 'cowork-host') return null;
    return id;
  } catch (_) {
    return null;
  }
}

/// The roster agent id a thread belongs to. One permanent session per agent:
/// its key IS the agent id; a forked thread (`<key>:fork:<hex>`) belongs to
/// the agent it was forked from. Null when the key cannot be an agent id
/// (the server's rule: 1-256 characters, no control characters, no `/`).
String? webhookAgentIdFor(String sessionKey) {
  String id = sessionKey.trim();
  final int fork = id.indexOf(':fork:');
  if (fork > 0) id = id.substring(0, fork);
  if (id.isEmpty || id.length > 256) return null;
  if (id.contains('/')) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) return null;
  return id;
}

/// What [createWebhookAutomation] ended with.
@immutable
class WebhookCreateResult {
  const WebhookCreateResult.saved({
    required AgentsAutomation this.automation,
    required String this.url,
    required String this.webhookId,
  }) : error = null,
       serverCode = null;

  const WebhookCreateResult.failed(this.error, {this.serverCode})
    : automation = null,
      url = null,
      webhookId = null;

  /// Set when the server webhook could not be made: the server's code
  /// (`too_many_webhooks`, `network`, ...). Null for a host refusal.
  final String? serverCode;

  final AgentsAutomation? automation;

  /// The secret URL, to show ONCE.
  final String? url;
  final String? webhookId;

  /// Why it failed: the host's own words, or a server code.
  final String? error;

  bool get ok => automation != null;
}

/// Sends `automation_create`; the default is [AutomationsSource.create].
typedef WebhookAutomationCreator = Future<AutomationSaveResult> Function({
  required String sessionKey,
  required String kind,
  required Object spec,
  required String prompt,
  String? name,
  bool notifyOnChange,
  bool allowChaining,
  Object? catchUp,
});

/// The two-step create of a webhook automation (docs/WIRE_CONTRACT.md,
/// "Inbound webhooks", App work 1 and 2): the server webhook first, then
/// the host's row with `spec.webhook_id` = the server's row id. A host
/// refusal (or no answer) deletes the server webhook again.
Future<WebhookCreateResult> createWebhookAutomation({
  required String sessionKey,
  required String prompt,
  String? name,
  bool notifyOnChange = false,
  bool allowChaining = false,
  Object? catchUp,
  Object? filter,
  int debounceSeconds = kWebhookDefaultDebounce,
  int maxWaitSeconds = kWebhookDefaultMaxWait,
  String? signingSecret,
  AgentsWebhooksService? service,
  Future<String?> Function()? deviceId,
  WebhookAutomationCreator? createAutomation,
}) async {
  final AgentsWebhooksService api = service ?? AgentsWebhooksService.instance;
  final AgentsWebhookCreated created;
  try {
    created = await api.create(
      deviceId: await (deviceId ?? agentsHostRelayDeviceId)(),
      agentId: webhookAgentIdFor(sessionKey),
    );
  } on AgentsWebhookException catch (error) {
    return WebhookCreateResult.failed(error.code, serverCode: error.code);
  }
  final String id = created.webhook.id.toLowerCase();
  final Object spec = webhookSpecFor(
    webhookId: id,
    filter: filter,
    debounceSeconds: debounceSeconds,
    maxWaitSeconds: maxWaitSeconds,
    signingSecret: signingSecret,
  );
  final WebhookAutomationCreator send =
      createAutomation ?? webhookCreatorFor(AutomationsSource.instance);
  AutomationSaveResult result;
  try {
    result = await send(
      sessionKey: sessionKey,
      kind: kWebhookKind,
      spec: spec,
      prompt: prompt,
      name: name,
      notifyOnChange: notifyOnChange,
      allowChaining: allowChaining,
      catchUp: catchUp,
    );
  } catch (error) {
    result = AutomationSaveResult.failed('Could not reach the host: $error');
  }
  final AgentsAutomation? saved = result.automation;
  if (saved == null) {
    // The host did not keep the row: the URL would start nothing.
    try {
      await api.delete(id);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('agent webhooks: rollback failed (${error.runtimeType})');
      }
    }
    return WebhookCreateResult.failed(result.error);
  }
  return WebhookCreateResult.saved(
    automation: saved,
    url: created.url,
    webhookId: id,
  );
}

/// [AutomationsSource.create] as a [WebhookAutomationCreator].
WebhookAutomationCreator webhookCreatorFor(AutomationsSource source) =>
    ({
      required String sessionKey,
      required String kind,
      required Object spec,
      required String prompt,
      String? name,
      bool notifyOnChange = false,
      bool allowChaining = false,
      Object? catchUp,
    }) => source.create(
      sessionKey: sessionKey,
      kind: kind,
      spec: spec,
      prompt: prompt,
      name: name,
      notifyOnChange: notifyOnChange,
      allowChaining: allowChaining,
      catchUp: catchUp,
    );
