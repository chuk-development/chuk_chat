// lib/services/mcp/mcp_connection.dart
//
// One connected server, as it is stored and shown.
//
// Only what is not secret lives here. Tokens and the registered client id
// stay in secure storage, keyed by the same id — see McpService.

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_client.dart';

class McpConnection {
  const McpConnection({
    required this.id,
    required this.name,
    required this.url,
    this.description = '',
    this.iconUrl,
    this.tools = const <McpTool>[],
    this.addedByHand = false,
  });

  final String id;
  final String name;
  final String url;
  final String description;
  final String? iconUrl;

  /// The tools the server offered at connect time, cached so the list can
  /// be shown and registered without a round trip on every start.
  final List<McpTool> tools;

  /// True when the reader typed the URL instead of picking a connector.
  final bool addedByHand;

  String get icon => iconUrl ?? McpCatalogueEntry.faviconFor(url);

  McpConnection copyWith({List<McpTool>? tools, String? name, String? iconUrl}) =>
      McpConnection(
        id: id,
        name: name ?? this.name,
        url: url,
        description: description,
        iconUrl: iconUrl ?? this.iconUrl,
        tools: tools ?? this.tools,
        addedByHand: addedByHand,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'description': description,
    'icon_url': iconUrl,
    'added_by_hand': addedByHand,
    'tools': tools.map((t) => t.toJson()).toList(),
  };

  static McpConnection fromJson(Map<String, dynamic> json) => McpConnection(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    url: (json['url'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    iconUrl: json['icon_url']?.toString(),
    addedByHand: json['added_by_hand'] == true,
    tools: [
      for (final tool in (json['tools'] as List? ?? const []))
        if (tool is Map) McpTool.fromJson(Map<String, dynamic>.from(tool)),
    ],
  );

  /// The name a model sees for [tool] on this server. Prefixed, because two
  /// servers may both offer `search`, and capped at the 64 characters the
  /// chat API allows for a tool name.
  String toolNameFor(String tool) {
    final sanitized = tool.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final full = '${id}_$sanitized';
    return full.length <= 64 ? full : full.substring(0, 64);
  }
}
