# test/services/mcp · Signaturen

## test/services/mcp/chuk_mcp_mirror_test.dart  (390 Z.)
- L13 `class _MemorySecrets implements AgentsSecureKeyValueStore`  — Keychain stand-in.
  - L14 `final Map<String, String> map = <String, String>{}`
  - L17 `Future<String?> read(String key)`
  - L20 `Future<void> write(String key, String value)`
  - L23 `Future<void> delete(String key)`
- L27 `class _OwnMirror implements McpConnectorSync`  — Agents's own mirror, in memory.
  - L28 `Map<String, dynamic>? blob`
  - L31 `Future<void> save(Map<String, dynamic> payload)`
  - L34 `Future<Map<String, dynamic>?> load()`
  - L37 `Future<void> clear()`
- L41 `class _ChukTable implements ChukMcpMirror`  — chuk_chat's `service_credentials` rows, in memory, by catalogue id.
  - L42 `_ChukTable({this.rows})`
  - L45 `Map<String, ChukMcpRow>? rows`  — Null = table unreadable (no user, no key, no table).
  - L46 `final List<String> saved = <String>[]`
  - L47 `final List<String> deleted = <String>[]`
  - L48 `Object? saveError`
  - L51 `Future<Map<String, ChukMcpRow>?> load()`
  - L55 `Future<void> save(ChukMcpRow row)`
  - L62 `Future<void> delete(String id)`
- L68 `Map<String, dynamic> _connectionJson( String id, { String auth = 'oauth', String? url, })`
- L88 `Map<String, dynamic> _secretsJson({ String access = 'at-chuk', String? refresh = 'rt-chuk', Duration ttl = const Duration(hours: 1), Map<String, String>? apiCredentials, })`  — chuk's `_McpSecrets.toJson` as it lands in the blob.
- L108 `ChukMcpRow _row(String id, {Map<String, dynamic>? secrets, String auth = 'oauth'})`
- L111 `void main()`

## test/services/mcp/mcp_adoption_test.dart  (234 Z.)
- L26 `class _MemorySecrets implements AgentsSecureKeyValueStore`  — Keychain stand-in.
  - L27 `final Map<String, String> map = <String, String>{}`
  - L30 `Future<String?> read(String key)`
  - L33 `Future<void> write(String key, String value)`
  - L36 `Future<void> delete(String key)`
- L41 `class _OwnMirror implements McpConnectorSync`  — Agents's own mirror, in memory. Always readable, always empty here — these
  - L43 `Future<void> save(Map<String, dynamic> payload)`
  - L46 `Future<Map<String, dynamic>?> load()`
  - L49 `Future<void> clear()`
- L53 `class _ChukTable implements ChukMcpMirror`  — chuk_chat's `service_credentials` rows, in memory, counting every read.
  - L54 `_ChukTable({this.rows})`
  - L58 `Map<String, ChukMcpRow>? rows`  — Null = the table could not be read at all (no Supabase, no signed-in
  - L59 `int loads = 0`
  - L62 `Future<Map<String, ChukMcpRow>?> load()`
  - L68 `Future<void> save(ChukMcpRow row)`
  - L71 `Future<void> delete(String id)`
- L74 `Map<String, dynamic> _connectionJson(String id)`
- L87 `Map<String, dynamic> _secretsJson()`
- L101 `ChukMcpRow _row(String id)`
- L107 `void main()`

## test/services/mcp/mcp_oauth_test.dart  (321 Z.)
- L9 `http.Response _json(Map<String, dynamic> body)`
- L17 `MockClient _compliantServer({ List<String> scopes = const <String>['read', 'write'], void Function(Map<String, String> body)? onToken, Map<String, dynamic> Function()? tokenResponse, List<String>? registeredRedirectUris, })`  — A server that publishes protected-resource metadata pointing at its own
- L66 `void main()`

## test/services/mcp/mcp_service_test.dart  (728 Z.)
- L17 `class _MemorySecrets implements AgentsSecureKeyValueStore`
  - L18 `final Map<String, String> map = <String, String>{}`
  - L21 `Future<String?> read(String key)`
  - L24 `Future<void> write(String key, String value)`
  - L27 `Future<void> delete(String key)`
- L31 `class _FakeSync implements McpConnectorSync`  — An in-memory stand-in for the encrypted Supabase mirror.
  - L32 `Map<String, dynamic>? blob`
  - L35 `Future<void> save(Map<String, dynamic> payload)`
  - L38 `Future<Map<String, dynamic>?> load()`
  - L41 `Future<void> clear()`
- L44 `http.Response _json(Map<String, dynamic> body)`
- L54 `MockClient _challengingServer({String scope = 'read'})`  — The server's answer to an unauthenticated request: a 401 that names both
- L67 `MockClient _authServer({bool refuseRegistration = false})`  — A compliant authorization server for `https://srv.example/mcp`.
- L107 `Future<bool> _signIn(Uri authorizationUrl)`  — Stands in for the browser: takes the authorization URL, hands the loopback
- L126 `void main()`

## test/services/mcp/mcp_store_test.dart  (564 Z.)
- L19 `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure backend so secrets round-trip with no platform channel.
  - L20 `final Map<String, String> map = <String, String>{}`
  - L23 `Future<String?> read(String key)`
  - L26 `Future<void> write(String key, String value)`
  - L29 `Future<void> delete(String key)`
- L33 `McpSecrets _record({ String accessToken = 'at-1', String? refreshToken = 'rt-1', DateTime? expiresAt, String tokenEndpoint = 'https://auth.example/token', })`  — A full record, as `_authorize` writes one after a real sign-in.
- L52 `void main()`
