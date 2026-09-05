// lib/services/mcp/mcp_redirect_stub.dart
//
// Web has no loopback listener: a page cannot open a port. Connecting a
// server there needs a redirect page on our own origin, which is not built
// yet, so the flow refuses instead of failing halfway through.

class McpRedirectListener {
  McpRedirectListener._();

  static Future<McpRedirectListener> start() async {
    throw UnsupportedError(
      'Connecting an MCP server needs the app, not the website.',
    );
  }

  Uri get redirectUri => throw UnsupportedError('Not supported on the web');

  Future<Uri> get callback => throw UnsupportedError('Not supported on the web');

  Future<void> close() async {}
}
