// lib/services/mcp/mcp_connection.dart
//
// One MCP server the user has configured, as it is stored and shown.
//
// Only what is not secret lives here. The bearer token stays in secure
// storage, keyed by the same id — see [McpStore]. Ported in shape from
// chuk_chat's McpConnection so the connectors UI is identical, but trimmed to
// what CoWork forwards to the Python agent: the live client, the OAuth sign-in
// and tool discovery all run host-side, not on the device.

import 'package:cowork/services/mcp/mcp_catalogue.dart';

/// How a connection proves who it is.
enum McpAuth {
  /// The server signs the user in through the browser and hands back a token
  /// of its own. Every third-party connector works this way. On CoWork the
  /// host runs that sign-in; the device only records that the server is
  /// wanted. When a token is present it is forwarded to the host.
  oauth,

  /// The server is fronted by our own API, so the account is already signed
  /// in: the app session is the credential, resolved host-side. No
  /// per-connection token is stored on the device.
  appSession,

  /// The user supplies their own credentials — an API key, a project id — and
  /// the server takes them as query parameters on the endpoint URL, not
  /// through a browser sign-in. The values are secret, so they live in secure
  /// storage keyed by the connection id; the stored [McpConnection.url] stays
  /// the plain base URL. [McpStore.forwardPayloads] adds them to the URL only
  /// in the frame it forwards to the host.
  apiKey;

  static McpAuth parse(String? raw) {
    for (final value in McpAuth.values) {
      if (value.name == raw) return value;
    }
    return McpAuth.oauth;
  }
}

/// One tool a server offers. Kept minimal because CoWork discovers the live
/// tool list host-side; this only carries what the connectors UI shows.
class McpTool {
  const McpTool({required this.name, this.description = ''});

  final String name;
  final String description;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
      };

  static McpTool fromJson(Map<String, dynamic> json) => McpTool(
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
      );
}

/// A configured MCP server. The non-secret config; the token or the API
/// credentials live in secure storage under `mcp_secrets_<id>`.
class McpConnection {
  const McpConnection({
    required this.id,
    required this.name,
    required this.url,
    this.description = '',
    this.iconUrl,
    this.tools = const <McpTool>[],
    this.addedByHand = false,
    this.auth = McpAuth.oauth,
    this.checkedAt,
    this.lastError,
  });

  final String id;
  final String name;
  final String url;
  final String description;

  /// An icon the catalogue entry named, if any. Falls back to a favicon.
  final String? iconUrl;

  /// The tools the server offered, as the host reported them (`mcp_tools`).
  /// This device never dials the server itself.
  final List<McpTool> tools;

  /// When the host last answered about this connector. Null means nobody has
  /// asked yet — which is NOT the same as a server with no tools, and the list
  /// must not show those two the same way.
  final DateTime? checkedAt;

  /// Why the host could not use this connector, as it reported it. Null when
  /// the last check succeeded.
  final String? lastError;

  /// True when the user typed the URL instead of picking a connector.
  final bool addedByHand;

  /// Where the token for this server comes from.
  final McpAuth auth;

  /// The icon to show: the named icon, else the site favicon.
  String get icon => iconUrl ?? McpCatalogueEntry.faviconFor(url);

  McpConnection copyWith({
    String? name,
    String? url,
    String? description,
    String? iconUrl,
    List<McpTool>? tools,
    McpAuth? auth,
    DateTime? checkedAt,
    // Explicit, because "no error any more" is a value and `null` cannot say
    // it through the usual `?? this.lastError`.
    bool clearError = false,
    String? lastError,
  }) =>
      McpConnection(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        description: description ?? this.description,
        iconUrl: iconUrl ?? this.iconUrl,
        tools: tools ?? this.tools,
        addedByHand: addedByHand,
        auth: auth ?? this.auth,
        checkedAt: checkedAt ?? this.checkedAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'description': description,
        'icon_url': iconUrl,
        'added_by_hand': addedByHand,
        'auth': auth.name,
        'tools': <Map<String, dynamic>>[for (final t in tools) t.toJson()],
        if (checkedAt != null) 'checked_at': checkedAt!.toIso8601String(),
        if (lastError != null) 'last_error': lastError,
      };

  static McpConnection fromJson(Map<String, dynamic> json) => McpConnection(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        iconUrl: json['icon_url']?.toString(),
        addedByHand: json['added_by_hand'] == true,
        auth: McpAuth.parse(json['auth']?.toString()),
        tools: <McpTool>[
          for (final tool in (json['tools'] as List? ?? const []))
            if (tool is Map) McpTool.fromJson(Map<String, dynamic>.from(tool)),
        ],
        checkedAt: DateTime.tryParse('${json['checked_at'] ?? ''}'),
        lastError: (json['last_error'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['last_error'] as String,
      );

  /// The name a model sees for [tool] on this server. Prefixed, because two
  /// servers may both offer `search`, and capped at 64 characters.
  String toolNameFor(String tool) {
    final sanitized = tool.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final full = '${id}_$sanitized';
    return full.length <= 64 ? full : full.substring(0, 64);
  }

  /// The shape the Python agent needs to reach this server (WS-D forwards it
  /// inside the sealed task frame): `{id, name, url, auth, access_token?}`.
  ///
  /// [id] is carried so the host can name this exact connector when it sends
  /// credentials back (`mcp_credentials`, docs/WIRE_CONTRACT.md). [name] is a
  /// display name and two connectors may share one; the id cannot collide.
  ///
  /// [accessToken] is the resolved bearer for an [McpAuth.oauth] connection,
  /// read from secure storage by [McpStore]. An [McpAuth.appSession]
  /// connection carries no token — the host resolves the account credential.
  ///
  /// An [McpAuth.apiKey] connection is not forwarded through this method; the
  /// store builds its frame from the credentialed URL instead — see
  /// [McpStore.forwardPayloads].
  Map<String, dynamic> toForwardJson({String? accessToken}) {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'url': url,
      'auth': auth.name,
      if (auth == McpAuth.oauth &&
          accessToken != null &&
          accessToken.isNotEmpty)
        'access_token': accessToken,
    };
  }
}
