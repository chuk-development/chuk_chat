// lib/services/mcp/mcp_connection.dart
//
// One MCP server the user has configured, as it is stored and shown.
//
// Only what is not secret lives here. The bearer token stays in secure
// storage, keyed by the same id — see [McpStore]. Ported in shape from
// chuk_chat's McpConnection, trimmed to what CoWork forwards to the Python
// agent: the live client and tool discovery run host-side, not on the device.

/// How a connection proves who it is.
enum McpAuth {
  /// The server signs the user in through the browser and hands back a token
  /// of its own. Every third-party connector works this way. The device holds
  /// the token; CoWork forwards it to the host at task launch.
  oauth,

  /// The server is fronted by our own API, so the account is already signed
  /// in: the app's session token is the credential, resolved host-side. No
  /// per-connection token is stored on the device.
  appSession;

  static McpAuth parse(String? raw) =>
      raw == McpAuth.appSession.name ? McpAuth.appSession : McpAuth.oauth;
}

/// A configured MCP server. The non-secret config; the token lives in secure
/// storage under `mcp_secrets_<id>`.
class McpConnection {
  const McpConnection({
    required this.id,
    required this.name,
    required this.url,
    this.description = '',
    this.auth = McpAuth.oauth,
  });

  final String id;
  final String name;
  final String url;
  final String description;

  /// Where the token for this server comes from.
  final McpAuth auth;

  McpConnection copyWith({
    String? name,
    String? url,
    String? description,
    McpAuth? auth,
  }) =>
      McpConnection(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        description: description ?? this.description,
        auth: auth ?? this.auth,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'description': description,
        'auth': auth.name,
      };

  static McpConnection fromJson(Map<String, dynamic> json) => McpConnection(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        auth: McpAuth.parse(json['auth']?.toString()),
      );

  /// The shape the Python agent needs to reach this server (WS-D forwards it
  /// inside the sealed task frame): `{name, url, auth, access_token?}`.
  ///
  /// [accessToken] is the resolved bearer for an [McpAuth.oauth] connection,
  /// read from secure storage by [McpStore]. An [McpAuth.appSession]
  /// connection carries no token — the host resolves the account credential —
  /// so the field is left off.
  Map<String, dynamic> toForwardJson({String? accessToken}) {
    return <String, dynamic>{
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
