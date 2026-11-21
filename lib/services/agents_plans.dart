/// The Sidekicks (Agents) plans (CHAT-164): 20, 30 and 40 EUR a month; a
/// higher plan carries more model credit. The cloud computer is an optional
/// add-on with its own monthly price and four sizes (S, M, L, XL). Checkout
/// pre-selects it; without it the user runs Agents on their own computer.
///
/// The app never holds a Stripe price id. It names a plan by its id
/// (`agents_20`, ...) in the checkout request, and the server maps the id to
/// the price id from its own configuration.
///
/// Server contract:
///
///  * `GET /v1/stripe/plans?product=agents` answers
///    `{"plans": [{"id": "agents_20", "price_eur": 20, "credit_eur": 12,
///      "cloud_box": false}, ...],
///      "cloud_box_sizes": [{"id": "s", "label": "S", "vcpu": 4, "ram_gb": 8,
///      "disk_gb": 100, "price_eur": 7.55, "recommended": true}, ...]}`.
///    `credit_eur` may be null. Any failure falls back to
///    [kAgentsPlanDefaults] and [kAgentsCloudBoxSizeDefaults].
///  * `POST /v1/stripe/create-checkout-session` with
///    `{"plan": "agents_20", "cloud_box_size": "s"|null}` opens the checkout
///    (see [agentsCheckoutBody]). Box only: `{"cloud_box_size": "s"}`.
///    Without a body it stays the Plus plan.
///  * `GET /v1/user/status` adds `"cloud_box_included": true|false` (the user
///    has the add-on), which [agentsPlanIncludesCloudBox] reads to start the
///    zero-click setup.
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
    this.includesCloudBox = false,
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
      includesCloudBox: json['cloud_box'] == true,
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

/// One size of the cloud computer add-on.
@immutable
class AgentsCloudBoxSize {
  const AgentsCloudBoxSize({
    required this.id,
    required this.label,
    required this.vcpu,
    required this.ramGb,
    required this.diskGb,
    required this.priceEur,
    this.recommended = false,
  });

  /// The id the server takes (`s`, `m`, ...). Never a Stripe price id.
  final String id;
  final String label;
  final int vcpu;
  final int ramGb;
  final int diskGb;

  /// Monthly price in euros (may have cents, e.g. 7.55). Monthly only,
  /// cancellable every month.
  final num priceEur;
  final bool recommended;

  static AgentsCloudBoxSize? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['id'];
    final Object? price = json['price_eur'];
    if (id is! String || id.isEmpty || price is! num) return null;
    final Object? label = json['label'];
    int whole(Object? v) => v is num ? v.round() : 0;
    return AgentsCloudBoxSize(
      id: id,
      label: label is String && label.isNotEmpty ? label : id.toUpperCase(),
      vcpu: whole(json['vcpu']),
      ramGb: whole(json['ram_gb']),
      diskGb: whole(json['disk_gb']),
      priceEur: price,
      recommended: json['recommended'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsCloudBoxSize &&
      other.id == id &&
      other.label == label &&
      other.vcpu == vcpu &&
      other.ramGb == ramGb &&
      other.diskGb == diskGb &&
      other.priceEur == priceEur &&
      other.recommended == recommended;

  @override
  int get hashCode =>
      Object.hash(id, label, vcpu, ramGb, diskGb, priceEur, recommended);

  @override
  String toString() => 'AgentsCloudBoxSize($id, $priceEur)';
}

/// The sizes the page shows when the server has no list yet.
const List<AgentsCloudBoxSize> kAgentsCloudBoxSizeDefaults =
    <AgentsCloudBoxSize>[
      AgentsCloudBoxSize(
        id: 's',
        label: 'S',
        vcpu: 4,
        ramGb: 8,
        diskGb: 100,
        priceEur: 7.55,
        recommended: true,
      ),
      AgentsCloudBoxSize(
        id: 'm',
        label: 'M',
        vcpu: 6,
        ramGb: 12,
        diskGb: 200,
        priceEur: 9.93,
      ),
      AgentsCloudBoxSize(
        id: 'l',
        label: 'L',
        vcpu: 8,
        ramGb: 24,
        diskGb: 300,
        priceEur: 17.66,
      ),
      AgentsCloudBoxSize(
        id: 'xl',
        label: 'XL',
        vcpu: 12,
        ramGb: 48,
        diskGb: 400,
        priceEur: 30.75,
      ),
    ];

/// The size checkout pre-selects: the recommended one, else the cheapest.
AgentsCloudBoxSize defaultCloudBoxSize(List<AgentsCloudBoxSize> sizes) {
  final List<AgentsCloudBoxSize> list = sizes.isEmpty
      ? kAgentsCloudBoxSizeDefaults
      : sizes;
  for (final AgentsCloudBoxSize size in list) {
    if (size.recommended) return size;
  }
  return list.first;
}

/// The size with [id] in [sizes], or null.
AgentsCloudBoxSize? cloudBoxSizeById(
  List<AgentsCloudBoxSize> sizes,
  String? id,
) {
  if (id == null) return null;
  for (final AgentsCloudBoxSize size in sizes) {
    if (size.id == id) return size;
  }
  return null;
}

/// The plans and the cloud computer sizes, as one answer of the server.
@immutable
class AgentsPlanCatalog {
  const AgentsPlanCatalog({required this.plans, required this.cloudBoxSizes});

  static const AgentsPlanCatalog defaults = AgentsPlanCatalog(
    plans: kAgentsPlanDefaults,
    cloudBoxSizes: kAgentsCloudBoxSizeDefaults,
  );

  final List<AgentsPlan> plans;
  final List<AgentsCloudBoxSize> cloudBoxSizes;

  /// Reads a response body. Each half that is missing or empty falls back
  /// to its defaults on its own.
  static AgentsPlanCatalog fromJson(Object? data) {
    if (data is! Map) return defaults;
    final Object? planRows = data['plans'];
    final Object? sizeRows = data['cloud_box_sizes'];
    final List<AgentsPlan> plans = <AgentsPlan>[
      if (planRows is List)
        for (final Object? row in planRows)
          if (AgentsPlan.fromJson(row) case final AgentsPlan plan) plan,
    ]..sort((a, b) => a.priceEur.compareTo(b.priceEur));
    final List<AgentsCloudBoxSize> sizes = <AgentsCloudBoxSize>[
      if (sizeRows is List)
        for (final Object? row in sizeRows)
          if (AgentsCloudBoxSize.fromJson(row)
              case final AgentsCloudBoxSize size)
            size,
    ]..sort((a, b) => a.priceEur.compareTo(b.priceEur));
    return AgentsPlanCatalog(
      plans: plans.isEmpty ? kAgentsPlanDefaults : plans,
      cloudBoxSizes: sizes.isEmpty ? kAgentsCloudBoxSizeDefaults : sizes,
    );
  }
}

/// Reads the plans and the cloud computer sizes from the server, cheapest
/// first. Any failure gives [AgentsPlanCatalog.defaults], so the page always
/// has something to show.
Future<AgentsPlanCatalog> fetchAgentsPlanCatalog({
  http.Client? client,
  String? baseUrl,
  AgentMailTokenSource? token,
}) async {
  final bool owned = client == null;
  final http.Client transport = client ?? http.Client();
  try {
    final String? bearer = await (token ?? supabaseAgentMailToken)();
    final Uri uri = Uri.parse(
      '${baseUrl ?? ApiConfigService.apiBaseUrl}/v1/stripe/plans',
    ).replace(queryParameters: const <String, String>{'product': 'agents'});
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
    if (response.statusCode != 200) return AgentsPlanCatalog.defaults;
    return AgentsPlanCatalog.fromJson(jsonDecode(response.body));
  } catch (error) {
    if (kDebugMode) {
      debugPrint('agents plans: fetch failed (${error.runtimeType})');
    }
    return AgentsPlanCatalog.defaults;
  } finally {
    if (owned) transport.close();
  }
}

/// Reads only the plan list. See [fetchAgentsPlanCatalog].
Future<List<AgentsPlan>> fetchAgentsPlans({
  http.Client? client,
  String? baseUrl,
  AgentMailTokenSource? token,
}) async => (await fetchAgentsPlanCatalog(
  client: client,
  baseUrl: baseUrl,
  token: token,
)).plans;

/// The checkout request body. Null means no body (the Plus plan).
///
/// `{"plan": "agents_20", "cloud_box_size": "s"}`, `{"plan": "agents_20",
/// "cloud_box_size": null}` (the add-on unticked) or, box only,
/// `{"cloud_box_size": "s"}`.
Map<String, dynamic>? agentsCheckoutBody({
  String? planId,
  String? cloudBoxSize,
}) {
  if (planId == null && cloudBoxSize == null) return null;
  return <String, dynamic>{'plan': ?planId, 'cloud_box_size': cloudBoxSize};
}

/// The monthly total of [plan] plus [box] (null = no add-on), in euros.
num agentsMonthlyTotal(AgentsPlan plan, AgentsCloudBoxSize? box) =>
    plan.priceEur + (box?.priceEur ?? 0);

/// A euro amount for the price strings: `20`, or `9.90` / `9,90` with cents
/// (comma for the languages that write one).
String formatEuroAmount(num amount, String languageCode) {
  final num cents = (amount * 100).round();
  if (cents % 100 == 0) return (cents ~/ 100).toString();
  final String text = (cents / 100).toStringAsFixed(2);
  const Set<String> comma = <String>{'de', 'fr', 'es', 'pt'};
  return comma.contains(languageCode) ? text.replaceAll('.', ',') : text;
}

/// Whether the user status says the user has the cloud computer add-on. Null
/// when the status is not loaded or the server does not send the field.
bool? agentsPlanIncludesCloudBox(Map<String, dynamic>? status) {
  if (status == null) return null;
  final Object? flag = status['cloud_box_included'];
  return flag is bool ? flag : null;
}
