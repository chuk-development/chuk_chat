# MCP Connectors

Remote MCP servers, connected from the app. A connector is a URL and a
sign-in — nothing is installed, so the same connector works on a phone and
on a laptop. Local (stdio) MCP servers are deliberately not supported.

## What happens when the reader taps Connect

1. `POST` an `initialize` request to the server URL (Streamable HTTP,
   spec revision `2025-06-18`).
2. A `401` carries `WWW-Authenticate`. Its `resource_metadata` URL leads to
   the protected resource metadata (RFC 9728), which names the
   authorization server.
3. The authorization server metadata is read from
   `/.well-known/oauth-authorization-server` or the OpenID equivalent
   (RFC 8414).
4. The app registers itself (RFC 7591, `POST /register`) and gets a
   `client_id`. **Nothing is pre-registered per service** — this is what
   makes "paste any MCP URL" work.
5. The browser opens the authorization URL with PKCE (S256) and the
   `resource` parameter (RFC 8707). A loopback listener on `127.0.0.1`
   catches the redirect (RFC 8252), so no custom URL scheme and no
   manifest entry is needed on any **native** platform — Android, iOS,
   Linux, Windows and macOS all take the same path. Web cannot open that
   port, which is why it is excluded (see "Feature flag" below).
6. The code is exchanged for tokens. `state` and `iss` are checked first.
7. `tools/list` is called, and every tool is registered with the ordinary
   `ToolExecutor` as `ToolType.mcp`.

Tokens, refresh tokens and the registered client id live in
`FlutterSecureStorage`, keyed `mcp_secrets_<id>`. The connection itself
(name, URL, cached tool list) is plain SharedPreferences — it holds no
secret.

## Cost in the prompt

Zero until used. MCP tools register like every other tool, so they are
found through `find_tools` rather than listed in every prompt. A server
with forty tools costs nothing on a turn that does not need it.

## Tool names

`<server-id>_<tool>`, sanitized and capped at 64 characters, so two servers
that both offer `search` stay apart. `McpConnection.toolNameFor` is the
single definition; `McpService.resolve` maps a name back to its server.

## Files

| File | What |
|------|------|
| `lib/services/mcp/mcp_client.dart` | Streamable HTTP transport: initialize, tools/list, tools/call, SSE replies, session id |
| `lib/services/mcp/mcp_oauth.dart` | Discovery, dynamic registration, PKCE, token exchange and refresh |
| `lib/services/mcp/mcp_redirect*.dart` | The loopback listener that catches the browser redirect |
| `lib/services/mcp/mcp_service.dart` | Connect, disconnect, store, call |
| `lib/services/mcp/mcp_catalogue.dart` | The offered connectors and the registry search |
| `lib/services/mcp/mcp_tool_bridge.dart` | Registers connected tools with the executor |
| `lib/pages/mcp_connectors_page.dart` | The Connectors screen and one connector's detail |

## What cannot be listed

A catalogue entry must support **dynamic client registration** (RFC 7591).
The app carries no client id, so a server whose authorization server has no
`registration_endpoint` cannot be connected at all. GitHub is the known
case: `api.githubcopilot.com` points at `github.com/login/oauth`, which
expects a pre-registered OAuth app. Listing it only produces an error at
Connect, so it is not listed. GitHub tools stay available through
`FEATURE_SERVER_TOOLS` instead.

`test/mcp/mcp_endpoints_live_test.dart` checks every catalogue entry against
the real server and fails on exactly this. It is skipped unless run with
`--dart-define=MCP_LIVE=true`.

## Adding a connector to the catalogue

Add an entry to `kMcpCatalogue` with an `id`, a name, the endpoint and a
category from `kMcpCategories`. The logo needs no work: the site's favicon
is used unless the server publishes `serverInfo.icons`.

Anything not in the catalogue is still reachable: search queries the
official registry at `registry.modelcontextprotocol.io`, and "Add by URL"
needs no entry at all.

## Feature flag

`FEATURE_MCP`, default **on**. Web is excluded in the settings entry: a web
page cannot open a loopback port, so connecting there would fail halfway
through. Supporting web needs a redirect page on our own origin.
