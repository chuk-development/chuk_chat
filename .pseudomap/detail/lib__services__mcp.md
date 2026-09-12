# lib/services/mcp · Signatures

## lib/services/mcp/mcp_availability.dart  (36 Z.)

- L16 `List<McpCatalogueEntry> unconnectedCatalogueEntries()`  — Every catalogue server (our own first-party ones plus the offered
- L27 `McpCatalogueEntry? catalogueEntryById(String id)`  — The catalogue entry with this [id], searching the first-party connectors

## lib/services/mcp/mcp_catalogue.dart  (1001 Z.)

- L24 `class McpCredentialField`  — One credential a server takes on its URL instead of through a browser
  - L25 `const McpCredentialField({ required this.key, required this.label, this.hint, this.secret = true, this.required = true, })`
  - L34 `final String key`  — The query-parameter name the server expects, e.g. `browserbaseApiKey`.
  - L37 `final String label`  — What the reader sees, e.g. "API key".
  - L40 `final String? hint`  — Placeholder text, e.g. "bb_live_…".
  - L44 `final bool secret`  — True for a value that must be obscured on screen and kept in secure
  - L47 `final bool required`  — Whether the connect form insists on a value.
- L51 `class McpCatalogueEntry`  — A connector as offered to the reader.
  - L52 `const McpCatalogueEntry({ required this.id, required this.name, required this.url, required this.category, this.description = '', this.iconUrl, this.publisher, this.websiteUrl, this.termsUrl, this.privacyUrl, this.auth = McpAuth.oauth, this.credentials = const <McpCredentialField>[], })`
  - L68 `final String id`  — Stable id, used as the tool-name prefix and the storage key.
  - L69 `final String name`
  - L70 `final String url`
  - L71 `final String category`
  - L72 `final String description`
  - L73 `final String? iconUrl`
  - L78 `final String? publisher`  — The domain that publishes this server, for entries that come out of the
  - L83 `final String? websiteUrl`  — The publisher's own page, where their terms and privacy policy live.
  - L91 `final String? termsUrl`  — The two documents the reader agrees to by connecting. Filled in by
  - L92 `final String? privacyUrl`
  - L98 `String? get legalUrl`  — Where to send a reader who wants the terms before signing in. The
  - L120 `final McpAuth auth`  — Where the token comes from. Everything in the catalogue signs in
  - L124 `final List<McpCredentialField> credentials`  — The credentials the reader must supply for an [McpAuth.apiKey] server.
  - L128 `String get icon`  — The logo. Servers rarely publish one in `serverInfo.icons`, so the
  - L130 `static String faviconFor(String url)`
  - L135 `static List<String> faviconCandidates(String url)`  — Places a logo can come from, best first. `mcp.figma.com` has no icon
  - L148 `static String brandDomain(String host)`  — `mcp.figma.com` → `figma.com`: the host without the part that only
- L170 `kBundledMcpIcons = { 'airtable', 'asana', 'atlassian', 'box', 'browserbase', 'buffer', 'calcom', 'canva', 'clickup', 'co`  — Catalogue ids whose real brand logo ships in the binary as
- L232 `String? bundledIconAsset(String id)`  — The bundled logo path for [id], or null when no logo ships for it. The
- L237 `kMcpCategories = [ 'Recommended', 'Productivity', 'Finance', 'Creative', 'Lifestyle', 'Developer', 'Registry', ]`  — Categories, in the order they are shown. Consumer-relevant groups lead;
- L260 `List<McpCatalogueEntry> firstPartyConnectors()`  — Connectors our own API server fronts.
- L284 `kMcpCatalogue = [ // ─── Recommended ─────────────────────────────────────────────────────── McpCatalogueEntry( id: 'exc`  — The offered connectors. Only servers that speak Streamable HTTP and sign
- L870 `String? namespaceDomain(String serverName)`  — The domain a registry namespace stands for: `com.notion` → `notion.com`.
- L886 `bool isFirstPartyRemote(String serverName, String remoteUrl)`  — Whether [remoteUrl] is served by the same domain that publishes
- L898 `bool _isCurrentRegistryEntry(Object? meta)`  — Whether the registry still stands behind this entry — `active`, and the
- L915 `Future<List<McpCatalogueEntry>> searchMcpRegistry( String query, { http.Client? httpClient, int limit = 20, bool firstPartyOnly = true, })`  — Search the official MCP registry for anything not in the catalogue.
- L990 `String slugFor(String nameOrUrl)`  — A short, stable id for a server: used to prefix its tool names, so two

## lib/services/mcp/mcp_client.dart  (352 Z.)

- L20 `kMcpProtocolVersion = '2025-06-18'`  — The revision this client speaks. Servers negotiate down if they must.
- L24 `class McpUnauthorized implements Exception`  — Thrown when the server wants a token. [wwwAuthenticate] carries the
  - L25 `const McpUnauthorized(this.wwwAuthenticate)`
  - L27 `final String? wwwAuthenticate`
  - L30 `String toString()`
- L34 `class McpException implements Exception`  — Any other failure: transport, HTTP status, or a JSON-RPC error.
  - L35 `const McpException(this.message)`
  - L37 `final String message`
  - L40 `String toString()`
- L44 `class McpServerInfo`  — What a server says about itself in the initialize result.
  - L45 `const McpServerInfo({ required this.name, this.title, this.version, this.iconUrl, this.websiteUrl, this.instructions, })`
  - L54 `final String name`
  - L55 `final String? title`
  - L56 `final String? version`
  - L57 `final String? iconUrl`
  - L58 `final String? websiteUrl`
  - L59 `final String? instructions`
  - L62 `String get displayName`  — The name to show a reader: the title if the server has one.
- L66 `class McpTool`  — One tool a server offers.
  - L67 `const McpTool({ required this.name, required this.description, required this.inputSchema, })`
  - L73 `final String name`
  - L74 `final String description`
  - L75 `final Map<String, dynamic> inputSchema`
  - L77 `Map<String, dynamic> toJson()`
  - L83 `static McpTool fromJson(Map<String, dynamic> json)`
- L94 `class McpCallResult`  — The outcome of a tools/call: the text the model gets, plus whether the
  - L95 `const McpCallResult({required this.text, required this.isError})`
  - L97 `final String text`
  - L98 `final bool isError`
- L101 `class McpClient`
  - L102 `McpClient({ required this.endpoint, this.accessToken, http.Client? httpClient, this.timeout = const Duration(seconds: 60), }) : _http = httpClient ?? http.Client()`
  - L109 `final Uri endpoint`
  - L110 `final String? accessToken`
  - L111 `final Duration timeout`
  - L112 `final http.Client _http`
  - L114 `int _nextId = 1`
  - L115 `String? _sessionId`
  - L116 `String _protocolVersion = kMcpProtocolVersion`
  - L119 `String? get sessionId`  — Set once the server answered initialize. Sent back on every request.
  - L122 `Future<McpServerInfo> initialize()`  — Handshake. Returns what the server says about itself.
  - L153 `Future<List<McpTool>> listTools()`  — Every tool the server offers, following `nextCursor` pages.
  - L175 `Future<McpCallResult> callTool( String name, Map<String, dynamic> arguments, )`  — Run a tool and flatten its content blocks to text.
  - L222 `void close()`
  - L226 `Map<String, String> _headers({required bool expectsReply})`
  - L237 `Future<void> _notify(String method)`
  - L251 `Future<Map<String, dynamic>> _request( String method, Map<String, dynamic> params, )`
  - L307 `Future<Map<String, dynamic>> _readSseReply( http.StreamedResponse response, int id, )`  — Read an SSE stream until the reply to [id] arrives. Anything else the
  - L344 `static String? _firstIcon(Object? icons)`

## lib/services/mcp/mcp_connection.dart  (109 Z.)

- L12 `enum McpAuth`  — How a connection proves who it is.
  - L15 `oauth`
  - L20 `appSession`
  - L27 `apiKey`
- L30 `class McpConnection`
  - L31 `const McpConnection({ required this.id, required this.name, required this.url, this.description = '', this.iconUrl, this.tools = const <McpTool>[], this.addedByHand = false, this.auth = McpAuth.oauth, })`
  - L42 `final String id`
  - L43 `final String name`
  - L44 `final String url`
  - L45 `final String description`
  - L46 `final String? iconUrl`
  - L50 `final List<McpTool> tools`  — The tools the server offered at connect time, cached so the list can
  - L53 `final bool addedByHand`  — True when the reader typed the URL instead of picking a connector.
  - L56 `final McpAuth auth`  — Where the token for this server comes from.
  - L58 `String get icon`
  - L60 `McpConnection copyWith({List<McpTool>? tools, String? name, String? iconUrl})`
  - L72 `Map<String, dynamic> toJson()`
  - L83 `static McpConnection fromJson(Map<String, dynamic> json)`
  - L103 `String toolNameFor(String tool)`  — The name a model sees for [tool] on this server. Prefixed, because two

## lib/services/mcp/mcp_icon_cache.dart  (120 Z.)

- L24 `class McpIconCache`
  - L25 `McpIconCache._()`
  - L27 `static const int _maxBytes = 256 * 1024`
  - L29 `static final Map<String, Uint8List> _memory = <String, Uint8List>{}`
  - L30 `static Directory? _directory`
  - L34 `static http.Client? httpClient`  — Injected in tests, so nothing is downloaded.
  - L38 `static Future<Uint8List?> load(String url)`  — The bytes of [url], from memory, then disk, then the network.
  - L69 `static Future<Uint8List?> _download(String url)`
  - L88 `static Future<File?> _fileFor(String url)`
  - L99 `static Future<Directory> _openDirectory()`
  - L107 `static Future<void> clear()`  — Forget everything, on disk and in memory.

## lib/services/mcp/mcp_oauth.dart  (506 Z.)

- L22 `class McpAuthServer`  — What a server's authorization looks like once discovered.
  - L23 `const McpAuthServer({ required this.issuer, required this.authorizationEndpoint, required this.tokenEndpoint, this.registrationEndpoint, this.scopesSupported = const <String>[], })`
  - L31 `final String issuer`
  - L32 `final Uri authorizationEndpoint`
  - L33 `final Uri tokenEndpoint`
  - L34 `final Uri? registrationEndpoint`
  - L35 `final List<String> scopesSupported`
- L39 `class McpClientCredentials`  — The client id (and secret, if the server insists on one) we registered.
  - L40 `const McpClientCredentials({required this.clientId, this.clientSecret})`
  - L42 `final String clientId`
  - L43 `final String? clientSecret`
  - L45 `Map<String, dynamic> toJson()`
  - L50 `static McpClientCredentials fromJson(Map<String, dynamic> json)`
- L58 `class McpTokens`  — The tokens a server issued.
  - L59 `const McpTokens({ required this.accessToken, this.refreshToken, this.expiresAt, this.scope, })`
  - L66 `final String accessToken`
  - L67 `final String? refreshToken`
  - L68 `final DateTime? expiresAt`
  - L69 `final String? scope`
  - L72 `bool get isExpired`  — True shortly before the real expiry, so a call does not race it.
  - L78 `Map<String, dynamic> toJson()`
  - L85 `static McpTokens fromJson(Map<String, dynamic> json)`
  - L92 `static McpTokens fromTokenResponse(Map<String, dynamic> json)`
- L108 `class McpAuthException implements Exception`
  - L109 `const McpAuthException(this.message)`
  - L111 `final String message`
  - L114 `String toString()`
- L119 `class McpAuthorizationRequest`  — One authorization attempt, kept together so the verifier, the state and
  - L120 `const McpAuthorizationRequest({ required this.url, required this.state, required this.codeVerifier, required this.server, required this.credentials, required this.redirectUri, required this.resource, required this.scope, })`
  - L131 `final Uri url`
  - L132 `final String state`
  - L133 `final String codeVerifier`
  - L134 `final McpAuthServer server`
  - L135 `final McpClientCredentials credentials`
  - L136 `final Uri redirectUri`
  - L137 `final String resource`
  - L138 `final String? scope`
- L141 `class McpOAuth`
  - L142 `McpOAuth({http.Client? httpClient}) : _http = httpClient ?? http.Client()`
  - L144 `final http.Client _http`
  - L146 `static const String clientName = 'Chuk Chat'`
  - L147 `static const String clientUri = 'https://chat.chuk.chat'`
  - L153 `static String canonicalResource(Uri serverUrl)`  — The canonical resource identifier of an MCP server, as RFC 8707 wants
  - L164 `static Uri? resourceMetadataUrl(String? wwwAuthenticate)`  — Pull `resource_metadata="…"` out of a `WWW-Authenticate` challenge.
  - L174 `static List<String> challengeScopes(String? wwwAuthenticate)`  — The scopes the challenge asks for, if it says.
  - L183 `static List<Uri> resourceMetadataCandidates( Uri serverUrl, String? wwwAuthenticate, )`  — Well-known locations for protected resource metadata: the one the
  - L201 `static List<Uri> authServerMetadataCandidates(Uri issuer)`  — Well-known locations for authorization server metadata, in the order
  - L212 `Future<McpAuthServer> discover( Uri serverUrl, { String? wwwAuthenticate, })`  — Find the authorization server behind an MCP endpoint.
  - L274 `Future<McpClientCredentials> register( McpAuthServer server, Uri redirectUri, { String? scope, })`  — Register this app with the authorization server (RFC 7591), so no
  - L341 `McpAuthorizationRequest buildAuthorizationRequest({ required McpAuthServer server, required McpClientCredentials credentials, required Uri redirectUri, required String resource, List<String> scopes = const [], })`  — Build the URL to open in the browser, with PKCE and the resource the
  - L383 `Future<McpTokens> exchange( McpAuthorizationRequest request, Uri callback, )`  — Swap the code from the callback for tokens. Rejects a callback whose
  - L420 `Future<McpTokens?> refresh({ required McpAuthServer server, required McpClientCredentials credentials, required String refreshToken, required String resource, String? scope, })`  — Trade a refresh token for a fresh access token. Returns null when the
  - L448 `Future<McpTokens> _token( McpAuthServer server, McpClientCredentials credentials, Map<String, String> body, )`
  - L478 `Future<Map<String, dynamic>?> _getJson(Uri url)`
  - L492 `static Uri? _uriOrNull(Object? value)`  — An absolute URI, or null for anything that is not one.
  - L499 `static final Random _random = Random.secure()`
  - L501 `static String _randomString(int length)`

## lib/services/mcp/mcp_redirect.dart  (13 Z.)

- conditional export: 'mcp_redirect_stub.dart' if (dart.library.io) 'mcp_redirect_io.dart'

## lib/services/mcp/mcp_redirect_io.dart  (59 Z.)

- L9 `class McpRedirectListener`  — A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
  - L10 `McpRedirectListener._(this._server)`
  - L12 `final HttpServer _server`
  - L13 `final Completer<Uri> _result = Completer<Uri>()`
  - L16 `static Future<McpRedirectListener> start()`  — Open a port and start listening.
  - L24 `Uri get redirectUri`  — The address to hand the authorization server.
  - L28 `Future<Uri> get callback`  — Completes with the full callback URL, including code and state.
  - L30 `void _listen()`
  - L48 `Future<void> close()`
  - L52 `static String _page(bool ok)`

## lib/services/mcp/mcp_redirect_stub.dart  (22 Z.)

- L7 `class McpRedirectListener`
  - L8 `McpRedirectListener._()`
  - L10 `static Future<McpRedirectListener> start()`
  - L16 `Uri get redirectUri`
  - L18 `Future<Uri> get callback`
  - L20 `Future<void> close()`

## lib/services/mcp/mcp_service.dart  (830 Z.)

- L28 `enum McpConnectStatus`  — What a connect attempt ended in, for the UI to show.
  - L28 `connected`
  - L28 `cancelled`
  - L28 `failed`
- L34 `class McpConnectCanceler`  — A handle the screen keeps so it can stop a connect while the browser
  - L35 `final Completer<void> _canceled = Completer<void>()`
  - L37 `void cancel()`
  - L41 `bool get isCanceled`
  - L42 `Future<void> get whenCanceled`
- L47 `class _ConnectCanceled implements Exception`  — Thrown inside [McpService] when the reader cancels the sign-in. Private:
  - L48 `const _ConnectCanceled()`
- L51 `class McpConnectResult`
  - L52 `const McpConnectResult(this.status, {this.message, this.connection})`
  - L54 `final McpConnectStatus status`
  - L55 `final String? message`
  - L56 `final McpConnection? connection`
- L60 `class _McpSecrets`  — The secrets of one connection. Never written to shared preferences.
  - L61 `const _McpSecrets({ this.credentials = const McpClientCredentials(clientId: ''), this.tokens = const McpTokens(accessToken: ''), this.issuer, this.authorizationEndpoint, this.tokenEndpoint, this.scope, this.apiCredentials = const <String, String>{}, })`
  - L71 `final McpClientCredentials credentials`
  - L72 `final McpTokens tokens`
  - L73 `final String? issuer`
  - L74 `final String? authorizationEndpoint`
  - L75 `final String? tokenEndpoint`
  - L76 `final String? scope`
  - L80 `final Map<String, String> apiCredentials`  — Reader-supplied API credentials for an [McpAuth.apiKey] server, keyed by
  - L82 `Map<String, dynamic> toJson()`
  - L92 `static _McpSecrets fromJson(Map<String, dynamic> json)`
  - L109 `McpAuthServer? get authServer`
  - L120 `_McpSecrets withTokens(McpTokens next)`
- L130 `class McpService`
  - L131 `McpService._()`
  - L133 `static const String _prefsKey = 'mcp_connections_v1'`
  - L134 `static const FlutterSecureStorage _secure = FlutterSecureStorage()`
  - L136 `static final ValueNotifier<List<McpConnection>> connections = ValueNotifier<List<McpConnection>>(const <McpConnection>[])`
  - L141 `static Future<bool> Function(Uri url)? launcher`  — Injected in tests so no browser opens and no real server is called.
  - L143 `static bool _loaded = false`
  - L147 `static Future<void> load()`
  - L168 `static Future<String?> _readConnectionsRaw()`
  - L180 `static Future<void> _persist()`
  - L187 `static Future<_McpSecrets?> _readSecrets(String id)`
  - L200 `static Future<void> _writeSecrets(String id, _McpSecrets secrets)`
  - L207 `static Future<McpConnectResult> connect({ required String id, required String name, required String url, String description = '', String? iconUrl, bool addedByHand = false, McpAuth auth = McpAuth.oauth, McpConnectCanceler? canceler, })`  — Connect [url] and remember it. Opens the browser when the server asks
  - L321 `static Future<McpConnectResult> connectWithCredentials({ required String id, required String name, required String url, required Map<String, String> credentials, String description = '', String? iconUrl, bool addedByHand = false, })`  — Connect a server that takes the reader's own credentials on its URL
  - L392 `static Uri _endpointWithCredentials(Uri base, Map<String, String> creds)`  — The endpoint the server is actually called on: the base URL with the
  - L400 `static Uri endpointWithCredentialsForTest( Uri base, Map<String, String> creds, )`  — The credentialed endpoint, exposed for tests: the reader's key must land
  - L407 `static Future<String?> _authorize({ required String id, required Uri endpoint, String? wwwAuthenticate, McpConnectCanceler? canceler, })`  — Run the OAuth flow and store what came out of it. Returns the access
  - L489 `static Future<bool> _launch(Uri url)`  — Opens the sign-in inside the app: a Custom Tab on Android, a Safari
  - L498 `static Future<void> _closeBrowser()`
  - L510 `static Future<void> disconnect(String id)`  — Forget a server: its tokens, its tools and its entry — here and on the
  - L527 `static Future<void> _forgetLocal(String id)`  — Forget a server on this device only: entry, tools and stored token. Used
  - L551 `static final ValueNotifier<Set<String>> unreachable = ValueNotifier<Set<String>>(<String>{})`  — Ask a connected server for its tools again.
  - L559 `static Future<bool> verifyReachable(String id)`  — Ask the server whether it is still there.
  - L581 `static Future<void> verifyAllReachable()`  — Check every connection. Used when the connectors page opens, so the
  - L587 `static void _recordReachable(String id, bool alive)`
  - L593 `static Future<McpConnection?> refreshTools(String id)`
  - L616 `static McpConnection? connectionFor(String id)`
  - L624 `static ({McpConnection connection, String tool})? resolve(String toolName)`  — Which connection and which remote tool a model-facing tool name means.
  - L636 `static Future<McpCallResult> call( String toolName, Map<String, dynamic> arguments, )`  — Run a tool on the server it belongs to.
  - L679 `static bool _isAcceptableEndpoint(Uri endpoint)`  — https everywhere, except a server on this machine.
  - L696 `static Future<String?> _appSessionToken()`  — The app's own session token, refreshed when it is about to lapse.
  - L707 `static Future<McpClient?> _clientFor(McpConnection connection)`  — A client carrying a valid token, refreshing it first when it is stale.
  - L753 `static Future<McpConnectResult> connectByUrl( String url, { String? name, McpConnectCanceler? canceler, })`  — Add a server the reader typed in by hand.
  - L782 `static bool internalIsAcceptableUrl(String url)`  — True when [url] is one this device will send a token to — https, or a
  - L788 `static Future<Map<String, dynamic>?> internalReadSecretsJson(String id)`  — The connection's secrets as a plain map, or null when it has none.
  - L794 `static Future<void> internalWriteSecretsJson( String id, Map<String, dynamic> json, )`  — Write a connection's secrets from a plain map (from a synced blob).
  - L801 `static Future<void> internalUpsertConnection(McpConnection connection)`  — Add or replace [connection] in the live list and persist. Registers its
  - L811 `static Future<void> internalForgetLocal(String id)`  — Forget a connection on this device without touching the remote row —
  - L816 `static Future<List<McpTool>?> internalFetchTools( McpConnection connection, )`  — List a connection's tools live, building a client from its stored token

## lib/services/mcp/mcp_sync_service.dart  (763 Z.)

- L38 `@immutable class McpSyncBlob`  — One connection as it travels between devices: its metadata without the
  - L40 `const McpSyncBlob({required this.connection, this.secrets})`
  - L44 `final McpConnection connection`  — The connection to recreate. Its [McpConnection.tools] is always empty
  - L49 `final Map<String, dynamic>? secrets`  — The decrypted secrets map (`_McpSecrets.toJson`), or null for connectors
  - L52 `static McpSyncBlob fromConnection( McpConnection connection, Map<String, dynamic>? secrets, )`  — Pack a live connection, stripping its cached tools.
  - L60 `Map<String, dynamic> toJson()`
  - L65 `static McpSyncBlob fromJson(Map<String, dynamic> json)`
  - L83 `String? get accessToken`  — The access token inside the secrets, if any. Used only to notice a token
  - L87 `DateTime? get expiresAt`  — When the access token expires, if the secrets say. Used to keep an older
- L93 `@visibleForTesting String? accessTokenOf(Map<String, dynamic>? secrets)`  — The access token buried in a `_McpSecrets.toJson` map, or null. Public only
- L104 `@visibleForTesting DateTime? expiresAtOf(Map<String, dynamic>? secrets)`  — The access token's expiry from a `_McpSecrets.toJson` map, or null. Public
- L112 `@immutable class McpSyncPlan`  — What one reconcile pass decided to do.
  - L114 `const McpSyncPlan({ required this.toAdd, required this.toUpdate, required this.toRemove, required this.nextKnownSyncedIds, })`
  - L122 `final Set<String> toAdd`  — Remote connections that are not here yet: add them and connect them.
  - L127 `final Set<String> toUpdate`  — Connections here whose remote token rotated to a strictly newer one:
  - L131 `final Set<String> toRemove`  — Connections here that were synced before but whose remote row is gone:
  - L137 `final Set<String> nextKnownSyncedIds`  — The known-synced set to persist for the next pass — the ids confirmed to
- L146 `McpSyncPlan reconcileMcpSync({ required Set<String> localIds, required Set<String> knownSyncedIds, required Set<String> remoteIds, required Map<String, String?> localAccessTokens, required Map<String, String?> remoteAccessTokens, Map<String, DateTime?> localTokenExpiries = const {}, Map<String, DateTime?> remoteTokenExpiries = const {}, })`  — Decide the sync actions. Pure: no IO, no clock, no globals.
- L187 `@visibleForTesting bool metadataDiffers(McpConnection a, McpConnection b)`  — True when two connections differ in any synced metadata field. Tools are
- L198 `bool _remoteTokenIsNewer({ required String? remoteToken, required String? localToken, required DateTime? remoteExpiry, required DateTime? localExpiry, })`  — True when the remote token should replace the local one: it exists, it
- L211 `class McpSyncService`  — The IO around [reconcileMcpSync]: push on change, delete on disconnect,
  - L212 `McpSyncService._()`
  - L216 `static const String _servicePrefix = 'mcp_'`  — `service_name` prefix in the `service_credentials` table. One row per
  - L219 `static const String _knownKey = 'mcp_synced_ids_v1'`  — Where the known-synced ids live between passes.
  - L223 `static const String _pendingDeleteKey = 'mcp_pending_delete_v1'`  — Ids whose remote row a disconnect could not delete yet. Kept so the next
  - L228 `static const Duration _minPullInterval = Duration(minutes: 2)`  — Connectors change rarely, so a pull need not run on every 30 s chat tick.
  - L230 `static bool _pulling = false`
  - L231 `static DateTime? _lastPullAt`
  - L237 `static final Map<String, int> _deleteEpochs = <String, int>{}`  — A monotonic arm counter per id. Every arm (a disconnect) and every disarm
  - L239 `static String _serviceName(String id)`
  - L244 `static String get pendingDeleteKeyForTest`  — The persisted tombstone-set key, exposed so tests read the same key the
  - L248 `static void resetForTests()`  — Clears in-memory pull and tombstone-arm state so tests start clean.
  - L259 `static Future<void> push(McpConnection connection)`  — Encrypt and upload one connection's blob. Called after a connect and
  - L283 `static Future<bool> delete(String id)`  — Delete the remote row for [id] so the disconnect propagates, and drop it
  - L309 `static Future<int> markPendingDelete(String id)`  — Remember that [id] must still be deleted remotely. Honoured by the next
  - L321 `static Future<void> clearPendingDelete(String id)`  — Forget any pending delete for [id]. Called when the reader reconnects a
  - L331 `static Future<void> deleteIfStillPending(String id, int epoch)`  — Delete the remote row only while the tombstone from *this* disconnect
  - L354 `static Future<void> _isolate( String what, String id, Future<void> Function() op, )`  — Run one id's reconcile step, swallowing and logging any failure so a
  - L369 `static Future<void> _repairAfterLateDelete(String id)`  — A background delete for one arm can land after a reconnect wrote a fresh
  - L382 `static Future<void> pullAndReconcile()`  — Fetch every remote blob, decide what changed and apply it: add and
  - L624 `static Future<void> _retryPendingDeletes( Set<String> pending, Set<String> remoteIds, )`  — Retry the remote delete for every tombstoned id, dropping the ones that
  - L667 `static Future<void> _applyAdd(McpSyncBlob blob)`  — Recreate a remote connection here and connect it: write its secrets, list
  - L712 `static Future<void> _healEmptyTools(Set<String> remoteIds)`  — Refetch tools for synced connections that have none yet (added offline).
  - L728 `static Future<Set<String>> _loadKnownSyncedIds()`
  - L729 `static Future<void> _saveKnownSyncedIds(Set<String> ids)`
  - L732 `static Future<Set<String>> _loadIdSet(String key)`
  - L741 `static Future<void> _saveIdSet(String key, Set<String> ids)`
  - L754 `static Future<void> _idSetGate = Future<void>.value()`
  - L756 `static Future<T> _locked<T>(Future<T> Function() action)`

## lib/services/mcp/mcp_tool_bridge.dart  (59 Z.)

- L17 `void syncMcpTools(ToolExecutor executor)`  — Register the tools of every connected server, replacing whatever was
- L41 `void watchMcpConnections(ToolExecutor executor)`  — Keep an executor in step with the connections for as long as it lives.
- L46 `List<String> _tagsFor(String serverName, String id, String toolName)`  — What `find_tools` matches on: the server, and the words of the tool name.
