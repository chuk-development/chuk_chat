/// The Sidekicks (Agents) plans (CHAT-164): 20, 30 and 40 EUR a month. Each
/// one includes the cloud computer; a higher plan carries more model credit.
///
/// The app never holds a Stripe price id. It names a plan by its id
/// (`agents_20`, ...) in the checkout request, and the server maps the id to
/// the price id from its own configuration.
///
/// Server contract:
///
///  * `GET /v1/stripe/plans?product=agents` answers
///    `{"plans": [{"id": "agents_20", "price_eur": 20, "credit_eur": 12,
///      "cloud_box": true}, ...]}`. `credit_eur` may be null. 404 (an older
///    server) falls back to [kAgentsPlanDefaults].
///  * `POST /v1/stripe/create-checkout-session` with `{"plan": "agents_20"}`
///    opens the checkout for that plan. Without a body it stays the Plus plan.
///  * `GET /v1/user/status` adds `"cloud_box_included": true|false`, which
///    [agentsPlanIncludesCloudBox] reads to start the zero-click setup.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/agents/agent_mail_service.dart'
    show AgentMailTokenSource, supabaseAgentMailToken;
import 'package:chuk_chat/services/api_config_service.dart';

/// One Sidekicks plan as the pricing page shows it.
@immutable
class AgentsPlan {
  const AgentsPlan({
    required this.id,
    required this.priceEur,
    this.creditEur,
    this.includesCloudBox = true,
  });

  /// The id the checkout request names. Never a Stripe price id.
  final String id;

  /// Monthly price in whole euros.
  final int priceEur;

  /// Monthly model credit in euros, or null when the server did not say.
  final num? creditEur;

  final bool includesCloudBox;

  static AgentsPlan? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['id'];
    final Object? price = json['price_eur'];
    final Object? credit = json['credit_eur'];
    if (id is! String || id.isEmpty || price is! num) return null;
    return AgentsPlan(
      id: id,
      priceEur: price.round(),
      creditEur: credit is num ? credit : null,
      includesCloudBox: json['cloud_box'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsPlan &&
      other.id == id &&
      other.priceEur == priceEur &&
      other.creditEur == creditEur &&
      other.includesCloudBox == includesCloudBox;

  @override
  int get hashCode => Object.hash(id, priceEur, creditEur, includesCloudBox);
}

/// What the page shows when the server has no plan list yet.
const List<AgentsPlan> kAgentsPlanDefaults = <AgentsPlan>[
  AgentsPlan(id: 'agents_20', priceEur: 20),
  AgentsPlan(id: 'agents_30', priceEur: 30),
  AgentsPlan(id: 'agents_40', priceEur: 40),
];

/// Reads the plan list from the server, cheapest first. Any failure gives
/// [kAgentsPlanDefaults], so the page always has something to show.
Future<List<AgentsPlan>> fetchAgentsPlans({
  http.Client? client,
  String? baseUrl,
  AgentMailTokenSource? token,
}) async {
  final String? bearer = await (token ?? supabaseAgentMailToken)();
  final Uri uri = Uri.parse(
    '${baseUrl ?? ApiConfigService.apiBaseUrl}/v1/stripe/plans',
  ).replace(queryParameters: const <String, String>{'product': 'agents'});
  final bool owned = client == null;
  final http.Client transport = client ?? http.Client();
  try {
    final http.Response response = await transport
        .get(
          uri,
          headers: <String, String>{
            'Accept': 'application/json',
            if (bearer != null && bearer.isNotEmpty)
              'Authorization': 'Bearer $bearer',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return kAgentsPlanDefaults;
    final Object? data = jsonDecode(response.body);
    final Object? rows = data is Map ? data['plans'] : null;
    if (rows is! List) return kAgentsPlanDefaults;
    final List<AgentsPlan> plans = <AgentsPlan>[
      for (final Object? row in rows)
        if (AgentsPlan.fromJson(row) case final AgentsPlan plan) plan,
    ]..sort((a, b) => a.priceEur.compareTo(b.priceEur));
    return plans.isEmpty ? kAgentsPlanDefaults : plans;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('agents plans: fetch failed (${error.runtimeType})');
    }
    return kAgentsPlanDefaults;
  } finally {
    if (owned) transport.close();
  }
}

/// Whether the user status says the plan includes a cloud computer. Null
/// when the status is not loaded or the server does not send the field.
bool? agentsPlanIncludesCloudBox(Map<String, dynamic>? status) {
  if (status == null) return null;
  final Object? flag = status['cloud_box_included'];
  return flag is bool ? flag : null;
}
