# test/mcp · Signaturen

## test/mcp/mcp_apikey_test.dart  (69 Z.)
- L12 `void main()`

## test/mcp/mcp_awareness_test.dart  (169 Z.)
- L13 `McpConnection _connection(String id)`
- L16 `void main()`

## test/mcp/mcp_bundled_icons_test.dart  (121 Z.)
- L14 `_pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]`  — PNG magic bytes — every bundled asset must be a real PNG, never an HTML
- L16 `void main()`

## test/mcp/mcp_catalogue_test.dart  (306 Z.)
- L14 `void main()`

## test/mcp/mcp_client_test.dart  (208 Z.)
- L11 `http.Response _json(Object body, {Map<String, String> headers = const {}})`
- L17 `void main()`

## test/mcp/mcp_connect_cancel_test.dart  (104 Z.)
- L20 `void main()`

## test/mcp/mcp_endpoints_live_test.dart  (151 Z.)
- L25 `_live = bool.fromEnvironment('MCP_LIVE')`
- L28 `class _Probe`  — What a live probe found out about one server.
  - L29 `const _Probe({required this.open, this.challenge})`
  - L32 `final bool open`  — True when the server answered initialize without a token.
  - L35 `final String? challenge`  — The `WWW-Authenticate` challenge, when it asked for one.
- L38 `Future<_Probe> _probe(String url, http.Client client)`
- L68 `void main()`

## test/mcp/mcp_first_party_test.dart  (131 Z.)
- L14 `void main()`

## test/mcp/mcp_legal_links_live_test.dart  (102 Z.)
- L23 `_live = bool.fromEnvironment('MCP_LIVE')`
- L27 `_userAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' 'Chrome/139.0.0.0 Safari/537.36'`  — A browser user agent. Several of these sites answer a bare Dart client
- L31 `Future<int> _statusOf(String url)`
- L43 `void main()`

## test/mcp/mcp_oauth_test.dart  (341 Z.)
- L12 `_issuer = 'https://auth.example.com'`
- L14 `http.Response _json(Object body)`
- L20 `MockClient _server({bool withRegistration = true})`
- L53 `void main()`

## test/mcp/mcp_sync_service_test.dart  (410 Z.)
- L12 `McpSyncBlob _remoteBlob(String id, {String? accessToken, McpAuth auth = McpAuth.oauth})`
- L31 `void main()`
